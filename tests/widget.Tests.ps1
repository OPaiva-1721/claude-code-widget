# widget.ps1 tests. They run the real widget code, so they carry the Desktop tag:
#   rendering draws every card to PNG (no window is shown);
#   the queue test starts a real widget for a few seconds (an idle pill appears in a corner).
BeforeAll {
    # No tray icon for the widgets these tests start (and kill): they would leave ghost icons behind
    $savedNoTray = $env:CLAUDE_WIDGET_NO_TRAY
    $env:CLAUDE_WIDGET_NO_TRAY = '1'
    $repo = Split-Path -Parent $PSScriptRoot
    $widget = Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'
    $samples = Join-Path $repo 'tools\samples.json'
    . (Join-Path $repo 'plugins\opaiva-code-widget\scripts\common.ps1')
    [void](Get-ScreenAreas)   # compiles ClaudeWidget.Monitors (pixels, same DPI mode as GetWindowRect here)
    if (-not ('CcwTest.Windows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Windows {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        // Rects (pixels: left, top, right, bottom) of the visible top-level windows of one process
        public static List<int[]> Rects(int pid) {
            var list = new List<int[]>();
            EnumWindows((h, l) => {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                RECT r;
                if (owner == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) list.Add(new int[] { r.Left, r.Top, r.Right, r.Bottom });
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
    if (-not ('CcwTest.Keys' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Keys {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        // Presses the keys together (down in order, up in reverse)
        public static void Chord(byte[] vks) {
            foreach (var k in vks) keybd_event(k, 0, 0, UIntPtr.Zero);
            for (int i = vks.Length - 1; i >= 0; i--) keybd_event(vks[i], 0, 2, UIntPtr.Zero);
        }
    }
}
'@
    }
}
AfterAll { $env:CLAUDE_WIDGET_NO_TRAY = $savedNoTray }

Describe 'widget.ps1 rendering' -Tag 'Desktop' {
    It 'draws every card in <lang>' -ForEach @(@{ lang = 'en' }, @{ lang = 'pt' }) {
        $out = Join-Path $TestDrive $lang
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang $lang
        $LASTEXITCODE | Should -Be 0
        foreach ($name in 'idle', 'sessions', 'permission', 'edit', 'question', 'done') {
            $png = Join-Path $out "$name.png"
            $png | Should -Exist
            (Get-Item -LiteralPath $png).Length | Should -BeGreaterThan 1024
        }
    }
    It 'draws the light theme with a light card and the dark theme with a dark card' {
        Add-Type -AssemblyName System.Drawing
        function Get-CardPixel([string]$theme) {
            $out = Join-Path $TestDrive "t-$theme"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang en -Theme $theme
            $LASTEXITCODE | Should -Be 0
            $bmp = New-Object System.Drawing.Bitmap (Join-Path $out 'permission.png')
            try {
                # 2x render: x = 50 px is inside the card's left padding, at mid height there is no content
                $c = $bmp.GetPixel(50, [int]($bmp.Height / 2))
                return [int](($c.R + $c.G + $c.B) / 3)
            }
            finally { $bmp.Dispose() }
        }
        (Get-CardPixel 'light') | Should -BeGreaterThan 200
        (Get-CardPixel 'dark') | Should -BeLessThan 80
    }
}

Describe 'widget.ps1 queue loop' -Tag 'Desktop' {
    It 'removes orphaned requests and stale notices from its queue' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $orphan = [ordered]@{ id = 'orphan'; pid = 2147483640; kind = 'permission'; created = $now; timeout = 300; cwd = '' }
        [IO.File]::WriteAllText((Join-Path $queue 'req-orphan.json'), ($orphan | ConvertTo-Json -Compress))
        $stale = $now - 13 * 3600 * 1000
        $notice = [ordered]@{ session = 's1'; created = $stale; cwd = ''; message = 'x'; hwnd = 0; kind = '' }
        [IO.File]::WriteAllText((Join-Path $queue "done-s1-$stale.json"), ($notice | ConvertTo-Json -Compress))

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and @(Get-ChildItem -LiteralPath $queue -File).Count -gt 0) { Start-Sleep -Milliseconds 250 }
            @(Get-ChildItem -LiteralPath $queue -File).Count | Should -Be 0
            Join-Path $data 'widget.json' | Should -Exist
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 position' -Tag 'Desktop' {
    # With one monitor the old check already sent such a spot to the corner: this guards the wiring
    # of the new per-monitor check (the gap between monitors is covered by Resolve-Anchor's tests)
    It 'opens in the main screen corner when the saved spot is on no screen, keeping state.json' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $state = '{"right":-50000,"bottom":-50000}'
        $statePath = Join-Path $data 'state.json'
        [IO.File]::WriteAllText($statePath, $state)
        $work = $null
        foreach ($m in [ClaudeWidget.Monitors]::List()) { if ($m[5] -eq 1) { $work = $m } }

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $inCorner = $false
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $inCorner -and (Get-Date) -lt $deadline) {
                foreach ($r in [CcwTest.Windows]::Rects($proc.Id)) {
                    if ([math]::Abs($r[2] - $work[2]) -le 2 -and [math]::Abs($r[3] - $work[3]) -le 2) { $inCorner = $true }
                }
                if (-not $inCorner) { Start-Sleep -Milliseconds 250 }
            }
            $inCorner | Should -BeTrue
            [IO.File]::ReadAllText($statePath) | Should -BeExactly $state
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 do not disturb' -Tag 'Desktop' {
    It 'hides its window while dnd.flag exists and shows it again when removed' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        Set-Dnd $data $true
        function Get-VisibleCount($ProcessId) { @([CcwTest.Windows]::Rects($ProcessId)).Count }
        function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
            Start-Sleep -Seconds 3
            Get-VisibleCount $proc.Id | Should -Be 0
            Set-Dnd $data $false
            (Wait-Until { (Get-VisibleCount $proc.Id) -gt 0 }) | Should -BeTrue
            Set-Dnd $data $true
            (Wait-Until { (Get-VisibleCount $proc.Id) -eq 0 }) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 quit request' -Tag 'Desktop' {
    It 'closes by itself when quit.flag appears, and removes the flag' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $data 'widget.json'))) { Start-Sleep -Milliseconds 250 }
            Join-Path $data 'widget.json' | Should -Exist
            [IO.File]::WriteAllText((Join-Path $data 'quit.flag'), '')
            $proc.WaitForExit(10000) | Should -BeTrue
            Join-Path $data 'quit.flag' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'ignores a quit.flag left over from before it started' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        [IO.File]::WriteAllText((Join-Path $data 'quit.flag'), '')
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath (Join-Path $data 'widget.json'))) { Start-Sleep -Milliseconds 250 }
            Start-Sleep -Seconds 3
            $proc.HasExited | Should -BeFalse
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'widget.ps1 global hotkeys' -Tag 'Desktop' {
    BeforeAll {
        function New-PermissionRequestFile([string]$Queue, [string]$Id) {
            $req = [ordered]@{ id = $Id; pid = $PID; kind = 'permission'; created = (Get-NowMs); timeout = 300; cwd = 'C:\dev\app'
                tool = 'Bash'; description = 'x'; detail = 'ls'; title = ''; change = $null; suggestions = @() }
            Write-JsonAtomic (Join-Path $Queue "req-$Id.json") $req
        }
        function Start-HotkeyWidget([string]$Data, [bool]$Enabled) {
            # In the top-left corner, away from where the real widget shows its cards: a person who sees a
            # test card there must not mistake it for a real request
            [IO.File]::WriteAllText((Join-Path $Data 'state.json'), '{"right":520,"bottom":330}')
            $saved = @{}
            foreach ($n in 'CLAUDE_WIDGET_HOTKEYS', 'CLAUDE_WIDGET_KEY_APPROVE', 'CLAUDE_WIDGET_KEY_DENY', 'CLAUDE_WIDGET_KEY_DND') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_HOTKEYS', $(if ($Enabled) { '1' } else { $null }))
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_APPROVE', 'Ctrl+Alt+F13')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DENY', 'Ctrl+Alt+F14')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DND', 'Ctrl+Alt+F15')
            try {
                return Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $Data), '-Lang', 'en'
            }
            finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        }
        function Wait-ForFile([string]$Path, [int]$Seconds = 10) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $Path) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $CTRL = [byte]0x11
        $ALT = [byte]0x12
    }
    It 'approves, denies and toggles do not disturb with the configured keys' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            (Wait-ForFile (Join-Path $queue 'res-r1.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r1.json')) | ConvertFrom-Json).decision | Should -BeExactly 'allow'

            New-PermissionRequestFile $queue 'r2'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7D))
            (Wait-ForFile (Join-Path $queue 'res-r2.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r2.json')) | ConvertFrom-Json).decision | Should -BeExactly 'deny'

            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            (Wait-ForFile (Join-Path $data 'dnd.flag')) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'does nothing when the hotkeys are not turned on' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $false
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            Start-Sleep -Seconds 3
            Join-Path $queue 'res-r1.json' | Should -Not -Exist
            Join-Path $data 'dnd.flag' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'does not approve when there is no permission card on screen' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            Start-Sleep -Seconds 2
            $proc.HasExited | Should -BeFalse
            @(Get-ChildItem -LiteralPath $queue -Filter 'res-*.json').Count | Should -Be 0
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
