# widget.ps1 tests. They run the real widget code, so they carry the Desktop tag:
#   rendering draws every card to PNG (no window is shown);
#   the queue test starts a real widget for a few seconds (an idle pill appears in a corner).
BeforeAll {
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
}

Describe 'widget.ps1 rendering' -Tag 'Desktop' {
    It 'draws every card in <lang>' -ForEach @(@{ lang = 'en' }, @{ lang = 'pt' }) {
        $out = Join-Path $TestDrive $lang
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang $lang
        $LASTEXITCODE | Should -Be 0
        foreach ($name in 'idle', 'permission', 'question', 'done') {
            $png = Join-Path $out "$name.png"
            $png | Should -Exist
            (Get-Item -LiteralPath $png).Length | Should -BeGreaterThan 1024
        }
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
