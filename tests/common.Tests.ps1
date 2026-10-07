# Unit tests for plugins/opaiva-code-widget/scripts/common.ps1
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\common.ps1')
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

Describe 'Get-PendingRequests' {
    BeforeAll {
        $deadPid = 2147483640   # no process has this id
        function New-TestRequest([string]$Queue, [string]$Id, [int64]$Created, [int]$OwnerPid = $PID, [int]$Timeout = 300) {
            $req = [ordered]@{ id = $Id; pid = $OwnerPid; kind = 'permission'; created = $Created; timeout = $Timeout; cwd = 'C:\dev\app' }
            [IO.File]::WriteAllText((Join-Path $Queue "req-$Id.json"), ($req | ConvertTo-Json -Compress))
        }
        function Get-Ids($Items) { (@($Items) | ForEach-Object { $_.id }) -join ',' }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns live requests oldest first' {
        New-TestRequest $queue 'newer' ($now - 1000)
        New-TestRequest $queue 'older' ($now - 2000)
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'older,newer'
    }
    It 'deletes expired requests' {
        New-TestRequest $queue 'old' ($now - 400 * 1000) -Timeout 300
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-old.json' | Should -Not -Exist
    }
    It 'deletes requests whose hook process is gone' {
        New-TestRequest $queue 'orphan' $now -OwnerPid $deadPid
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-orphan.json' | Should -Not -Exist
    }
    It 'skips answered requests without deleting them' {
        New-TestRequest $queue 'answered' $now
        [IO.File]::WriteAllText((Join-Path $queue 'res-answered.json'), '{"decision":"allow"}')
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-answered.json' | Should -Exist
    }
    It 'ignores files that are not valid JSON' {
        [IO.File]::WriteAllText((Join-Path $queue 'req-bad.json'), '{not json')
        New-TestRequest $queue 'good' $now
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'good'
    }
    It 'forgets cached requests whose file is gone' {
        New-TestRequest $queue 'gone' $now
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $queue 'req-gone.json')
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeFalse
    }
    It 'returns nothing when the queue folder does not exist' {
        @(Get-PendingRequests (Join-Path $TestDrive 'missing') $cache).Count | Should -Be 0
    }
}

Describe 'Get-DoneNotices' {
    BeforeAll {
        $maxAge = 12 * 3600 * 1000
        function New-TestNotice([string]$Queue, [string]$Session, [int64]$Created) {
            $path = Join-Path $Queue "done-$Session-$Created.json"
            $notice = [ordered]@{ session = $Session; created = $Created; cwd = 'C:\dev\app'; message = 'hi'; hwnd = 0; kind = '' }
            [IO.File]::WriteAllText($path, ($notice | ConvertTo-Json -Compress))
            return $path
        }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns notices newest first, with key and file' {
        [void](New-TestNotice $queue 's1' ($now - 60000))
        $newest = New-TestNotice $queue 's2' ($now - 1000)
        $list = @(Get-DoneNotices $queue $cache $maxAge)
        (($list | ForEach-Object { $_.session }) -join ',') | Should -BeExactly 's2,s1'
        $list[0].key | Should -BeExactly (Split-Path -Leaf $newest)
        Split-Path -Leaf $list[0].file | Should -BeExactly (Split-Path -Leaf $newest)
        $list[0].file | Should -Exist
    }
    It 'deletes notices older than the maximum age' {
        $stale = New-TestNotice $queue 'stale' ($now - $maxAge - 60000)
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $stale | Should -Not -Exist
    }
}

Describe 'Write-LogLine' {
    It 'appends a dated line, creating the folder' {
        $path = Join-Path $TestDrive 'logs\a.log'
        Write-LogLine $path 'first'
        Write-LogLine $path 'second'
        $lines = [IO.File]::ReadAllLines($path)
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d second$'
    }
    It 'moves the log to .old once it passes the limit, keeping a single .old' {
        $path = Join-Path $TestDrive 'r.log'
        [IO.File]::WriteAllText("$path.old", 'oldest')
        [IO.File]::WriteAllText($path, ('x' * 200))
        Write-LogLine $path 'new' 100
        [IO.File]::ReadAllText("$path.old") | Should -BeExactly ('x' * 200)
        $lines = @([IO.File]::ReadAllLines($path))
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match ' new$'
    }
    It 'keeps appending while under the limit' {
        $path = Join-Path $TestDrive 'u.log'
        [IO.File]::WriteAllText($path, "line`r`n")
        Write-LogLine $path 'more' 100
        "$path.old" | Should -Not -Exist
        @([IO.File]::ReadAllLines($path)).Count | Should -Be 2
    }
    It 'writes UTF-8 without BOM' {
        $path = Join-Path $TestDrive 'utf.log'
        $text = 'a' + [char]0x00E7 + [char]0x00E3 + 'o'
        Write-LogLine $path $text
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | Should -Match ([regex]::Escape($text))
    }
    It 'never throws, even when the log cannot be written' {
        { Write-LogLine (Join-Path $TestDrive 'bad<>|.log') 'x' } | Should -Not -Throw
    }
}
