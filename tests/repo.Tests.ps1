# Repository rules: ASCII-only scripts, valid JSON manifests, plugin version matches the changelog.
BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $scripts = @(Get-ChildItem -Path (Join-Path $repo 'plugins'), (Join-Path $repo 'tools'), (Join-Path $repo 'tests') -Filter '*.ps1' -File -Recurse |
        ForEach-Object { @{ name = $_.FullName.Substring($repo.Length + 1); path = $_.FullName } })
    $manifests = @('.claude-plugin\marketplace.json', 'plugins\opaiva-code-widget\.claude-plugin\plugin.json',
        'plugins\opaiva-code-widget\hooks\hooks.json', 'plugins\opaiva-code-widget\scripts\strings.json') |
        ForEach-Object { @{ name = $_; path = Join-Path $repo $_ } }
    $workflows = @(Get-ChildItem -Path (Join-Path $repo '.github\workflows') -Filter '*.yml' -File -ErrorAction SilentlyContinue |
        ForEach-Object { @{ name = $_.FullName.Substring($repo.Length + 1); path = $_.FullName } })
    $readmes = @(
        @{ name = 'README.md'; path = Join-Path $repo 'README.md'; updateHeading = 'Update'; anchor = '#renamed-in-200' }
        @{ name = 'README.pt-BR.md'; path = Join-Path $repo 'README.pt-BR.md'; updateHeading = 'Atualizar'; anchor = '#renomeado-na-200' }
    )
}

Describe 'repository rules' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        # Each line of a markdown file with the ##/### heading it sits under ({ section; text }).
        # Lines inside ``` code blocks never start a section, even when they begin with #.
        function Get-MarkdownLines([string]$Path) {
            $section = ''
            $code = $false
            foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
                if ($line -match '^\s*```') { $code = -not $code }
                elseif (-not $code -and $line -match '^#{2,3} (.+)$') { $section = $Matches[1] }
                [pscustomobject]@{ section = $section; text = $line }
            }
        }
        # Lines of a markdown file under the ##/### headings whose title matches $Heading
        function Get-MarkdownSection([string]$Path, [string]$Heading) {
            Get-MarkdownLines $Path | Where-Object { $_.section -match $Heading } | ForEach-Object { $_.text }
        }
        # Lines outside the 2.0.0 migration section that still name the old plugin, with or without
        # "@<marketplace>". The marketplace keeps the old name, so "marketplace update claude-code-widget" is fine.
        function Get-OldPluginIdLines([string]$Path) {
            Get-MarkdownLines $Path | Where-Object {
                $_.section -notmatch '2\.0\.0' -and
                $_.text -match '(?<![\w-])claude-code-widget@|plugin (install|uninstall|update|enable|disable) claude-code-widget(?![\w@-])'
            } | ForEach-Object { $_.text }
        }
    }

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

    # The workflow only reads the repository: its token should not be able to write to it
    It '<name> limits the token permissions' -ForEach $workflows {
        [IO.File]::ReadAllText($path) | Should -Match '(?m)^permissions:'
    }

    # Claude Code 2.1.292+ rejects third-party plugin names that pass as Anthropic's own and warns
    # about any "claude" in a plugin name. A local CLI may be older and not check, so check here too.
    It 'marketplace plugin names are not reserved for Anthropic' {
        $market = [IO.File]::ReadAllText((Join-Path $repo '.claude-plugin\marketplace.json')) | ConvertFrom-Json
        foreach ($entry in @($market.plugins)) {
            $entry.name | Should -Not -Match 'claude|anthropic|cc-plugin-'
        }
    }

    # A half-done rename (folder, marketplace entry and plugin.json disagreeing) breaks installs
    It 'each marketplace entry matches its plugin folder and plugin.json name' {
        $market = [IO.File]::ReadAllText((Join-Path $repo '.claude-plugin\marketplace.json')) | ConvertFrom-Json
        foreach ($entry in @($market.plugins)) {
            $manifest = Join-Path (Join-Path $repo $entry.source) '.claude-plugin\plugin.json'
            $manifest | Should -Exist
            $plugin = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
            $entry.name | Should -BeExactly $plugin.name
            Split-Path -Leaf $entry.source | Should -BeExactly $plugin.name
        }
    }

    # After the rename the old plugin id only belongs in the migration steps ("2.0.0" section), and
    # there the old plugin is uninstalled before the new one is installed (both at once = two widgets)
    It '<name> uses the old plugin id only in the 2.0.0 section, uninstalling first' -ForEach $readmes {
        @(Get-OldPluginIdLines $path) | Should -BeNullOrEmpty
        $text = @(Get-MarkdownSection $path '2\.0\.0') -join "`n"
        $uninstall = $text.IndexOf('claude plugin uninstall claude-code-widget@claude-code-widget')
        $install = $text.IndexOf('claude plugin install opaiva-code-widget@claude-code-widget')
        $uninstall | Should -BeGreaterOrEqual 0
        $install | Should -BeGreaterThan $uninstall
    }

    # On 1.1.1, the usual Update commands make the old plugin stop loading (it is no longer in the
    # marketplace): the Update section must send those users to the migration steps
    It '<name> points from the Update section to the migration steps' -ForEach $readmes {
        (@(Get-MarkdownSection $path "^$updateHeading$") -join "`n") | Should -Match ([regex]::Escape("]($anchor)"))
    }

    # Sessions that are still open keep the old hooks and reopen the old widget on their next request:
    # the migration reloads them before the new plugin is installed
    It '<name> reloads open sessions before installing the new plugin' -ForEach $readmes {
        $text = @(Get-MarkdownSection $path '2\.0\.0') -join "`n"
        $reload = $text.IndexOf('/reload-plugins')
        $install = $text.IndexOf('claude plugin install opaiva-code-widget@claude-code-widget')
        $reload | Should -BeGreaterOrEqual 0
        $reload | Should -BeLessThan $install
    }

    # PowerShell variable names ignore letter case, and scope is dynamic: an event handler with
    # param($s, ...) hides the strings table $S for everything it calls (the tray tooltip went blank)
    It 'widget.ps1 has no handler parameter named like the strings table ($S)' {
        $text = [IO.File]::ReadAllText((Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'))
        [regex]::Matches($text, '(?i)param\(([^)]*)\)') | ForEach-Object {
            $_.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Should -Not -BeIn @('$s')
        }
    }

    # Claude Code follows "renames" when an installed plugin is missing from the marketplace and moves
    # the user's settings to the new name: the 1.1.1 name must keep pointing at the current plugin
    It 'marketplace maps the 1.1.1 plugin name to the current one' {
        $market = [IO.File]::ReadAllText((Join-Path $repo '.claude-plugin\marketplace.json')) | ConvertFrom-Json
        $market.renames.'claude-code-widget' | Should -BeExactly @($market.plugins)[0].name
    }

    # Installed copies only update when the version number changes
    It 'plugin.json version matches the latest CHANGELOG entry' {
        $plugin = [IO.File]::ReadAllText((Join-Path $repo 'plugins\opaiva-code-widget\.claude-plugin\plugin.json')) | ConvertFrom-Json
        $latest = Select-String -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Pattern '^## (\d+\.\d+\.\d+)' | Select-Object -First 1
        $latest | Should -Not -BeNullOrEmpty
        $latest.Matches[0].Groups[1].Value | Should -Be $plugin.version
    }

    Context 'markdown helpers' {
        BeforeAll {
            $sample = Join-Path $TestDrive 'sample.md'
            $fence = '```'
            [IO.File]::WriteAllLines($sample, [string[]]@(
                    '## Install'
                    'Run /plugin install claude-code-widget now.'
                    'claude plugin marketplace update claude-code-widget'
                    'claude plugin install opaiva-code-widget@claude-code-widget'
                    '### Renamed in 2.0.0'
                    $fence
                    '## not a heading'
                    'claude plugin uninstall claude-code-widget@claude-code-widget'
                    $fence
                    'after the block'
                ))
        }
        It 'ignores # lines inside code blocks' {
            @(Get-MarkdownSection $sample '2\.0\.0') -contains 'after the block' | Should -BeTrue
        }
        It 'finds the old plugin id without "@" outside the migration section' {
            (@(Get-OldPluginIdLines $sample) -join '|') | Should -BeExactly 'Run /plugin install claude-code-widget now.'
        }
    }
}
