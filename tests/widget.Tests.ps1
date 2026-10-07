# widget.ps1 tests. They run the real widget code, so they carry the Desktop tag:
#   rendering draws every card to PNG (no window is shown);
#   the queue test starts a real widget for a few seconds (an idle pill appears in a corner).
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $widget = Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'
    $samples = Join-Path $repo 'tools\samples.json'
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
