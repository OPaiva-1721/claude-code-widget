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
    It 'forgets cached notices whose file is gone' {
        $path = New-TestNotice $queue 's1' ($now - 1000)
        [void](Get-DoneNotices $queue $cache $maxAge)
        $cache.Count | Should -Be 1
        Remove-Item -LiteralPath $path
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $cache.Count | Should -Be 0
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

Describe 'Test-TitleHasProject' {
    It 'matches "<title>"' -ForEach @(
        @{ title = 'x.ps1 - widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget (Workspace) - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget [WSL: Ubuntu] - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - WIDGET - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - my - app - Visual Studio Code'; project = 'my - app' }
        @{ title = 'x.ps1 - c++ (x86) - Visual Studio Code'; project = 'c++ (x86)' }
    ) {
        Test-TitleHasProject $title $project | Should -BeTrue
    }
    It 'does not match "<title>"' -ForEach @(
        @{ title = 'x.ps1 - claude-code-widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget.ps1 - other - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widgets - Visual Studio Code'; project = 'widget' }
    ) {
        Test-TitleHasProject $title $project | Should -BeFalse
    }
    It 'matches a title that starts with the unsaved-file dot' {
        $dot = [string][char]0x25CF
        Test-TitleHasProject "$dot widget - Visual Studio Code" 'widget' | Should -BeTrue
        Test-TitleHasProject "$dot x.ps1 - widget - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'matches a translated workspace suffix' {
        $suffix = ' (Espa' + [char]0x00E7 + 'o de Trabalho)'
        Test-TitleHasProject "x.ps1 - widget$suffix - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'is false for an empty title or project' {
        Test-TitleHasProject '' 'widget' | Should -BeFalse
        Test-TitleHasProject 'x.ps1 - widget - Visual Studio Code' '' | Should -BeFalse
    }
}

Describe 'Get-ScreenAreas' {
    It 'lists at least one screen, exactly one of them the main one' {
        $areas = @(Get-ScreenAreas)
        $areas.Count | Should -BeGreaterThan 0
        @($areas | Where-Object { $_.primary }).Count | Should -Be 1
        foreach ($a in $areas) {
            $a.right | Should -BeGreaterThan $a.left
            $a.bottom | Should -BeGreaterThan $a.top
        }
    }
    It 'uses the same units as WPF' {
        $main = @(Get-ScreenAreas | Where-Object { $_.primary })[0]
        $wa = [System.Windows.SystemParameters]::WorkArea
        [math]::Abs($main.right - $wa.Right) | Should -BeLessOrEqual 1
        [math]::Abs($main.bottom - $wa.Bottom) | Should -BeLessOrEqual 1
    }
}

Describe 'Get-ScreenKey' {
    BeforeAll { $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true } }
    It 'is the same for the same screens' {
        Get-ScreenKey @($main) | Should -BeExactly (Get-ScreenKey @($main.Clone()))
    }
    It 'changes when a screen changes' {
        $moved = $main.Clone()
        $moved.bottom = 1440
        Get-ScreenKey @($moved) | Should -Not -BeExactly (Get-ScreenKey @($main))
    }
}

Describe 'Resolve-Anchor' {
    BeforeAll {
        # Main screen 2560 x 1440 with a 40-pixel taskbar; a smaller screen on its left, bottom-aligned
        $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true }
        $side = @{ left = -1920; top = 360; right = 0; bottom = 1400; primary = $false }
    }
    It 'keeps a saved spot on the main screen' {
        $a = Resolve-Anchor @{ right = 2000; bottom = 900 } @($main, $side)
        $a.right | Should -Be 2000
        $a.bottom | Should -Be 900
        $a.saved | Should -BeTrue
    }
    It 'keeps a saved spot on another screen' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main, $side)
        $a.right | Should -Be -300
        $a.saved | Should -BeTrue
    }
    It 'moves a spot between screens of different sizes to the main corner' {
        # Above the smaller screen: inside the box around both screens, but on neither of them
        $a = Resolve-Anchor @{ right = -300; bottom = 200 } @($main, $side)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
        $a.saved | Should -BeFalse
    }
    It 'moves to the main corner when the saved screen is gone' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'goes back to the saved spot when its screen is back' {
        $saved = @{ right = -300; bottom = 1200 }
        (Resolve-Anchor $saved @($main)).saved | Should -BeFalse
        $back = Resolve-Anchor $saved @($main, $side)
        $back.right | Should -Be -300
        $back.saved | Should -BeTrue
    }
    It 'uses the main corner without a saved spot' {
        $a = Resolve-Anchor $null @($side, $main)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
    }
    It 'uses the main corner when the saved spot lacks fields' {
        $a = Resolve-Anchor ('{"x":5}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'reads a saved spot as loaded from state.json' {
        $a = Resolve-Anchor ('{"right":2371.09,"bottom":878.6}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2371.09
        $a.saved | Should -BeTrue
    }
    It 'uses the first screen when none is marked main' {
        $a = Resolve-Anchor $null @(@{ left = 0; top = 0; right = 1920; bottom = 1040; primary = $false })
        $a.right | Should -Be 1920
    }
    It 'returns nothing without screens' {
        Resolve-Anchor @{ right = 2000; bottom = 900 } @() | Should -BeNullOrEmpty
    }
}

Describe 'Get-BusySessions' {
    BeforeEach {
        $busy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $busy | Out-Null
        function Add-Busy([string]$Id, [int]$ProcessId, [int64]$AgeMs = 0, [string]$Cwd = 'C:\dev\app', [string]$Transcript = '') {
            Write-JsonAtomic (Join-Path $busy "$Id.json") ([ordered]@{ pid = $ProcessId; since = (Get-NowMs) - $AgeMs; cwd = $Cwd; transcript = $Transcript })
        }
        $maxAge = 12 * 3600 * 1000
        $quiet = 15 * 60 * 1000
    }
    It 'lists live sessions with id, cwd and transcript' {
        Add-Busy 's1' $PID 1000 'C:\dev\one' 'C:\t\one.jsonl'
        $list = @(Get-BusySessions $busy $maxAge $quiet)
        $list.Count | Should -Be 1
        $list[0].id | Should -BeExactly 's1'
        $list[0].cwd | Should -BeExactly 'C:\dev\one'
        $list[0].transcript | Should -BeExactly 'C:\t\one.jsonl'
        $list[0].since | Should -BeGreaterThan 0
    }
    It 'removes sessions whose process is gone' {
        Add-Busy 'dead' 2147483640
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
        Join-Path $busy 'dead.json' | Should -Not -Exist
    }
    It 'removes sessions older than the maximum age' {
        Add-Busy 'old' 0 ($maxAge + 60000)
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'removes sessions whose transcript has been quiet too long' {
        $t = Join-Path $TestDrive 'quiet.jsonl'
        [IO.File]::WriteAllText($t, '{}')
        (Get-Item -LiteralPath $t).LastWriteTime = (Get-Date).AddMinutes(-20)
        Add-Busy 'quiet' $PID 0 'C:\dev\app' $t
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'counts a session with an unknown process (pid 0)' {
        Add-Busy 'unknown' 0
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 1
    }
    It 'returns nothing when the folder does not exist' {
        @(Get-BusySessions (Join-Path $TestDrive 'nope') $maxAge $quiet).Count | Should -Be 0
    }
}

Describe 'Test-Dnd and Set-Dnd' {
    It 'is off by default, on after Set-Dnd and off again' {
        $dir = Join-Path $TestDrive 'dnd'
        Test-Dnd $dir | Should -BeFalse
        Set-Dnd $dir $true
        Test-Dnd $dir | Should -BeTrue
        Join-Path $dir 'dnd.flag' | Should -Exist
        Set-Dnd $dir $false
        Test-Dnd $dir | Should -BeFalse
    }
    It 'turning it off twice is harmless' {
        $dir = Join-Path $TestDrive 'dnd2'
        { Set-Dnd $dir $false; Set-Dnd $dir $false } | Should -Not -Throw
    }
}

Describe 'Format-SessionLine' {
    BeforeAll { $dot = [string][char]0x00B7 }
    It 'joins project and title' {
        Format-SessionLine 'C:\dev\my-app' 'Fix the login' | Should -BeExactly "my-app $dot Fix the login"
    }
    It 'shows only the project without a title' {
        Format-SessionLine 'C:\dev\my-app' '' | Should -BeExactly 'my-app'
        Format-SessionLine 'C:\dev\my-app' $null | Should -BeExactly 'my-app'
    }
    It 'shows only the title without a project' {
        Format-SessionLine '' 'Fix the login' | Should -BeExactly 'Fix the login'
    }
    It 'is empty without both' {
        Format-SessionLine '' '' | Should -BeExactly ''
    }
    It 'cuts a long title at 40 characters' {
        $title = 'x' * 60
        (Format-SessionLine 'C:\dev\a' $title) | Should -BeExactly ("a $dot " + ('x' * 39) + '...')
    }
    It 'does not split a surrogate pair when cutting' {
        $title = ('x' * 38) + [char]::ConvertFromUtf32(0x1F600) + 'yyyy'
        $line = Format-SessionLine '' $title
        $line | Should -BeExactly (('x' * 38) + '...')
    }
}

Describe 'Get-DiffLines' {
    BeforeAll {
        function New-Edit([string]$Old, [string]$New) { @{ kind = 'edit'; edits = @(@{ old = $Old; new = $New }) } }
    }
    It 'shows only the lines that changed, without the equal start and end' {
        $lines = @(Get-DiffLines (New-Edit "a`nb`nc" "a`nX`nc"))
        $lines.Count | Should -Be 2
        $lines[0].kind | Should -BeExactly 'del'
        $lines[0].text | Should -BeExactly 'b'
        $lines[1].kind | Should -BeExactly 'add'
        $lines[1].text | Should -BeExactly 'X'
    }
    It 'shows every line when nothing is in common' {
        $lines = @(Get-DiffLines (New-Edit "x`ny" "z"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:x,del:y,add:z'
    }
    It 'treats an empty old text as a pure addition' {
        $lines = @(Get-DiffLines (New-Edit '' "new1`nnew2"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:new1,add:new2'
    }
    It 'shows nothing when the edit changes nothing' {
        @(Get-DiffLines (New-Edit "same`nlines" "same`nlines")).Count | Should -Be 0
    }
    It 'handles Windows line endings' {
        $lines = @(Get-DiffLines (New-Edit "a`r`nb" "a`r`nc"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:b,add:c'
    }
    It 'shows a written file as added lines' {
        $lines = @(Get-DiffLines @{ kind = 'write'; content = "one`ntwo`nthree" })
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:one,add:two,add:three'
    }
    It 'keeps 14 lines and says how many were left out' {
        $content = (1..20 | ForEach-Object { "line $_" }) -join "`n"
        $lines = @(Get-DiffLines @{ kind = 'write'; content = $content })
        $lines.Count | Should -Be 15
        @($lines | Where-Object { $_.kind -eq 'add' }).Count | Should -Be 14
        $lines[14].kind | Should -BeExactly 'more'
        $lines[14].text | Should -BeExactly '6'
    }
    It 'follows several edits in order' {
        $change = @{ kind = 'edit'; edits = @(@{ old = 'a'; new = 'b' }, @{ old = 'c'; new = 'd' }) }
        $lines = @(Get-DiffLines $change)
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:a,add:b,del:c,add:d'
    }
    It 'returns nothing without a change' {
        @(Get-DiffLines $null).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'edit'; edits = @() }).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'write' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-Hotkey' {
    It 'parses <text>' -ForEach @(
        @{ text = 'Ctrl+Alt+Y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'ctrl + alt + y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'Shift+Win+F13'; mod = 0x400C; vk = 0x7C }
        @{ text = 'Ctrl+5'; mod = 0x4002; vk = 0x35 }
        @{ text = 'Alt+F1'; mod = 0x4001; vk = 0x70 }
    ) {
        $hk = ConvertTo-Hotkey $text
        $hk.mod | Should -Be $mod
        $hk.vk | Should -Be $vk
    }
    It 'rejects <text>' -ForEach @(
        @{ text = '' }
        @{ text = 'Y' }
        @{ text = 'Ctrl+Alt' }
        @{ text = 'Ctrl+Alt+Yes' }
        @{ text = 'Ctrl+Y+N' }
        @{ text = 'Ctrl+F25' }
        @{ text = 'Hyper+Y' }
    ) {
        ConvertTo-Hotkey $text | Should -BeNullOrEmpty
    }
}

Describe 'Format-RuleText' {
    It 'writes a rule object as Tool(content) or just Tool' {
        Format-RuleText ([pscustomobject]@{ toolName = 'Bash'; ruleContent = 'npm test *' }) | Should -BeExactly 'Bash(npm test *)'
        Format-RuleText ([pscustomobject]@{ toolName = 'Read' }) | Should -BeExactly 'Read'
        Format-RuleText ([pscustomobject]@{ toolName = 'Read'; ruleContent = '' }) | Should -BeExactly 'Read'
    }
    It 'keeps a rule that is already a string' {
        Format-RuleText 'Bash(git *)' | Should -BeExactly 'Bash(git *)'
    }
    It 'never throws on odd input' {
        { Format-RuleText $null; Format-RuleText 42; Format-RuleText @(1, 2); Format-RuleText ([pscustomobject]@{ other = 1 }) } | Should -Not -Throw
        Format-RuleText $null | Should -BeExactly ''
    }
}
