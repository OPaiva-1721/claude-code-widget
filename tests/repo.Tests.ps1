# Repository rules: ASCII-only scripts, valid JSON manifests, plugin version matches the changelog.
BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $scripts = @(Get-ChildItem -Path (Join-Path $repo 'plugins'), (Join-Path $repo 'tools'), (Join-Path $repo 'tests') -Filter '*.ps1' -File -Recurse |
        ForEach-Object { @{ name = $_.FullName.Substring($repo.Length + 1); path = $_.FullName } })
    $manifests = @('.claude-plugin\marketplace.json', 'plugins\claude-code-widget\.claude-plugin\plugin.json',
        'plugins\claude-code-widget\hooks\hooks.json', 'plugins\claude-code-widget\scripts\strings.json') |
        ForEach-Object { @{ name = $_; path = Join-Path $repo $_ } }
    $workflows = @(Get-ChildItem -Path (Join-Path $repo '.github\workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue |
        ForEach-Object { @{ name = $_.FullName.Substring($repo.Length + 1); path = $_.FullName } })
}

Describe 'repository rules' {
    BeforeAll { $repo = Split-Path -Parent $PSScriptRoot }

    # Windows PowerShell 5.1 reads BOM-less files as ANSI: any non-ASCII byte turns into garbage
    It '<name> is ASCII-only' -ForEach $scripts {
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($path))
        $text | Should -Not -Match '[^\x00-\x7F]'
    }

    It '<name> is valid JSON' -ForEach $manifests {
        { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } | Should -Not -Throw
    }

    # GitHub runs a PowerShell step to the end and only fails on the LAST command's exit code, so a
    # failing earlier command passes silently: one command per PowerShell step (or use shell: bash)
    It '<name> has no multi-command PowerShell steps' -ForEach $workflows {
        $offending = @()
        $steps = ([IO.File]::ReadAllText($path) -replace "`r", '') -split '(?m)^(?=\s*- )'
        foreach ($step in $steps) {
            if ($step -match '(?m)^\s*shell:\s*bash\s*$') { continue }
            $m = [regex]::Match($step, '(?ms)^( *)run:\s*\|[ \t]*\n(.*)')
            if (-not $m.Success) { continue }
            $indent = $m.Groups[1].Value.Length
            $commands = @($m.Groups[2].Value -split '\n' | Where-Object {
                    $_.Trim() -and -not $_.Trim().StartsWith('#') -and ($_.Length - $_.TrimStart().Length) -gt $indent })
            if ($commands.Count -gt 1) { $offending += ($step.Trim() -split '\n')[0] }
        }
        $offending | Should -BeNullOrEmpty
    }

    # Installed copies only update when the version number changes
    It 'plugin.json version matches the latest CHANGELOG entry' {
        $plugin = [IO.File]::ReadAllText((Join-Path $repo 'plugins\claude-code-widget\.claude-plugin\plugin.json')) | ConvertFrom-Json
        $latest = Select-String -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Pattern '^## (\d+\.\d+\.\d+)' | Select-Object -First 1
        $latest | Should -Not -BeNullOrEmpty
        $latest.Matches[0].Groups[1].Value | Should -Be $plugin.version
    }
}
