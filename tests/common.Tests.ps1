# Unit tests for plugins/claude-code-widget/scripts/common.ps1
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\claude-code-widget\scripts\common.ps1')
}

Describe 'Get-MutexName' {
    # Pinned: hook.ps1 finds a widget started by an older version through this exact name
    It 'matches the name computed by version 1.1.0' {
        Get-MutexName 'C:\Users\Test\.claude\plugins\data\claude-code-widget-claude-code-widget' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
    It 'ignores letter case in the path' {
        Get-MutexName 'C:\USERS\TEST\.CLAUDE\PLUGINS\DATA\CLAUDE-CODE-WIDGET-CLAUDE-CODE-WIDGET' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
}

Describe 'Write-JsonAtomic' {
    BeforeAll { $accented = 'a' + [char]0x00E7 + [char]0x00E3 + 'o' }

    It 'writes UTF-8 without BOM, keeps accents and leaves no .tmp' {
        $path = Join-Path $TestDrive 'x.json'
        Write-JsonAtomic $path ([ordered]@{ text = $accented })
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json).text | Should -BeExactly $accented
        "$path.tmp" | Should -Not -Exist
    }
    It 'keeps objects nested deeper than 5 levels' {
        $path = Join-Path $TestDrive 'deep.json'
        Write-JsonAtomic $path @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = 'deep' } } } } } }
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).a.b.c.d.e.f | Should -Be 'deep'
    }
}

Describe 'Resolve-Lang' {
    It 'maps <requested> to <expected>' -ForEach @(
        @{ requested = 'pt'; expected = 'pt' }
        @{ requested = 'PT'; expected = 'pt' }
        @{ requested = 'en'; expected = 'en' }
        @{ requested = 'es'; expected = 'en' }
    ) {
        Resolve-Lang $requested | Should -BeExactly $expected
    }
    It 'falls back to the Windows display language when empty' {
        $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        $expected = if ($ui -eq 'pt') { 'pt' } else { 'en' }
        Resolve-Lang '' | Should -BeExactly $expected
    }
}

Describe 'Get-Strings' {
    It 'pt and en define the same keys' {
        $en = @((Get-Strings 'en').PSObject.Properties.Name | Sort-Object)
        $pt = @((Get-Strings 'pt').PSObject.Properties.Name | Sort-Object)
        $en.Count | Should -BeGreaterThan 0
        ($pt -join ',') | Should -BeExactly ($en -join ',')
    }
    It 'reads strings.json as UTF-8' {
        (Get-Strings 'pt').deniedMessage | Should -Match ([string][char]0x00E1)
    }
}

Describe 'Get-NowMs' {
    It 'returns the current Unix time in milliseconds' {
        $expected = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        [math]::Abs((Get-NowMs) - $expected) | Should -BeLessThan 5000
    }
}
