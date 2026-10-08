# Unit tests for the functions in plugins/opaiva-code-widget/scripts/hook.ps1. The file is
# dot-sourced: its entry point does not run.
BeforeAll {
    $savedData = $env:CLAUDE_PLUGIN_DATA
    $tmpData = Join-Path ([IO.Path]::GetTempPath()) ('ccw-unit-' + [guid]::NewGuid().ToString('N'))
    $env:CLAUDE_PLUGIN_DATA = $tmpData
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\hook.ps1')
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
}
AfterAll {
    $env:CLAUDE_PLUGIN_DATA = $savedData
    Remove-Item -LiteralPath $tmpData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'loading hook.ps1' {
    It 'defines Invoke-Hook without running the entry point' {
        Get-Command Invoke-Hook -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Join-Path $tmpData 'hook.log' | Should -Not -Exist
    }
}

Describe 'Format-Snippet' {
    It 'removes code blocks' {
        Format-Snippet 'Run ```npm test``` now' | Should -BeExactly 'Run now'
    }
    It 'keeps link text and drops markdown symbols' {
        Format-Snippet '## Done: **tests** pass, see [the log](http://x/y).' | Should -BeExactly 'Done: tests pass, see the log.'
    }
    It 'cuts long text at 300 characters' {
        $out = Format-Snippet ('a' * 400)
        $out.Length | Should -Be 303
        $out | Should -BeLike '*...'
    }
    It 'returns an empty string for empty input' {
        Format-Snippet '' | Should -BeExactly ''
    }
}

Describe 'ConvertTo-AsciiJson' {
    It 'escapes non-ASCII characters and round-trips' {
        $text = 'Op' + [char]0x00E7 + [char]0x00E3 + 'o'
        $json = ConvertTo-AsciiJson ([ordered]@{ text = $text })
        $json | Should -Not -Match '[^\x00-\x7F]'
        $json | Should -Match '\\u00e7'
        ($json | ConvertFrom-Json).text | Should -BeExactly $text
    }
}

Describe 'Get-LastAssistantText' {
    It 'prefers last_assistant_message' {
        $evt = [pscustomobject]@{ last_assistant_message = 'From the event'; transcript_path = (Join-Path $fixtures 'transcript.jsonl') }
        Get-LastAssistantText $evt | Should -BeExactly 'From the event'
    }
    It 'falls back to the last assistant text in the transcript' {
        Get-LastAssistantText ([pscustomobject]@{ transcript_path = (Join-Path $fixtures 'transcript.jsonl') }) | Should -BeExactly 'Final answer'
    }
    It 'returns an empty string without message or transcript' {
        Get-LastAssistantText ([pscustomobject]@{ transcript_path = (Join-Path $tmpData 'missing.jsonl') }) | Should -BeExactly ''
    }
}

Describe 'Get-PermissionDetail' {
    It 'shows <expected> for <case>' -ForEach @(
        @{ case = 'command first'; json = '{"command":"npm test","file_path":"C:\\a.txt"}'; expected = 'npm test' }
        @{ case = 'file_path'; json = '{"file_path":"C:\\a.txt","content":"x"}'; expected = 'C:\a.txt' }
        @{ case = 'notebook_path'; json = '{"notebook_path":"C:\\n.ipynb"}'; expected = 'C:\n.ipynb' }
        @{ case = 'url'; json = '{"url":"https://example.com","prompt":"x"}'; expected = 'https://example.com' }
        @{ case = 'query'; json = '{"query":"widget docs"}'; expected = 'widget docs' }
        @{ case = 'anything else'; json = '{"pattern":"*.ps1"}'; expected = '{"pattern":"*.ps1"}' }
    ) {
        Get-PermissionDetail ($json | ConvertFrom-Json) | Should -BeExactly $expected
    }
    It 'cuts details longer than 2000 characters' {
        $out = Get-PermissionDetail ([pscustomobject]@{ command = 'x' * 2500 })
        $out.Length | Should -Be 2004
        $out | Should -BeLike '* ...'
    }
}

Describe 'New-PermissionOutput' {
    It 'allow has no message' {
        New-PermissionOutput 'allow' 'ignored' | ConvertTo-Json -Depth 5 -Compress |
            Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    }
    It 'deny carries the message' {
        New-PermissionOutput 'deny' 'No.' | ConvertTo-Json -Depth 5 -Compress |
            Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"No."}}}'
    }
}

Describe 'New-AnswerOutput' {
    It 'allows the tool and adds the answers to the original input' {
        $in = '{"questions":[{"question":"Which DB?","options":[{"label":"A"},{"label":"B"}]}]}' | ConvertFrom-Json
        $answers = [pscustomobject]@{ 'Which DB?' = 'B' }
        $out = (New-AnswerOutput $in $answers 'Answered').hookSpecificOutput
        $out.hookEventName | Should -Be 'PreToolUse'
        $out.permissionDecision | Should -Be 'allow'
        $out.permissionDecisionReason | Should -Be 'Answered'
        $out.updatedInput.answers.'Which DB?' | Should -Be 'B'
        $out.updatedInput.questions[0].question | Should -Be 'Which DB?'
    }
}

Describe 'Write-HookLog' {
    # Already true before 2.0.1 (hook.ps1 had its own rotation); guards the switch to Write-LogLine
    It 'moves hook.log to hook.log.old once it passes 256 KB' {
        New-Item -ItemType Directory -Force -Path $Data | Out-Null
        [IO.File]::WriteAllText($LogPath, ('x' * 300KB))
        Write-HookLog 'after rotation'
        "$LogPath.old" | Should -Exist
        @([IO.File]::ReadAllLines($LogPath)).Count | Should -Be 1
        Remove-Item -LiteralPath $LogPath, "$LogPath.old" -Force
    }
}

Describe 'Get-WindowKind' {
    It 'is <kind> for "<process>"' -ForEach @(
        @{ process = 'Code.exe'; kind = 'vscode' }
        @{ process = 'Code - Insiders.exe'; kind = 'vscode' }
        @{ process = 'WindowsTerminal.exe'; kind = 'terminal' }
        @{ process = 'explorer.exe'; kind = 'other' }
        @{ process = ''; kind = 'other' }
    ) {
        Get-WindowKind $process | Should -BeExactly $kind
    }
}

Describe 'Get-SessionTitle' {
    BeforeAll { $titles = Join-Path $fixtures 'titles.jsonl' }
    It 'prefers the name given with /rename over the automatic title' {
        Get-SessionTitle $titles 's-1' | Should -BeExactly 'Named with rename'
    }
    It 'uses the latest automatic title when there is no /rename' {
        Get-SessionTitle $titles 's-3' | Should -BeExactly 'Only automatic'
    }
    It 'ignores titles of other sessions' {
        Get-SessionTitle $titles 's-9' | Should -BeExactly ''
    }
    It 'is empty without a transcript' {
        Get-SessionTitle '' 's-1' | Should -BeExactly ''
        Get-SessionTitle (Join-Path $TestDrive 'missing.jsonl') 's-1' | Should -BeExactly ''
    }
    It 'only reads the last 512 KB' {
        $path = Join-Path $TestDrive 'long.jsonl'
        $filler = '{"type":"user","message":"' + ('x' * 1000) + '"}'
        $lines = @('{"type":"ai-title","aiTitle":"Too far back","sessionId":"s-1"}') + @($filler) * 600
        [IO.File]::WriteAllLines($path, [string[]]$lines)
        Get-SessionTitle $path 's-1' | Should -BeExactly ''
        [IO.File]::AppendAllText($path, '{"type":"ai-title","aiTitle":"Near the end","sessionId":"s-1"}' + "`n")
        Get-SessionTitle $path 's-1' | Should -BeExactly 'Near the end'
    }
}

Describe 'busy sessions and all done' {
    BeforeEach {
        Remove-Item -LiteralPath $Busy, $RoundPath -Recurse -Force -ErrorAction SilentlyContinue
        function Set-FakeBusy([string]$Sid, [int]$ProcessId, [int64]$AgeMs = 0) {
            New-Item -ItemType Directory -Force -Path $Busy | Out-Null
            Remove-Item -LiteralPath (Join-Path $Busy "$Sid.json") -Force -ErrorAction SilentlyContinue
            Write-JsonAtomic (Join-Path $Busy "$Sid.json") @{ pid = $ProcessId; since = (Get-NowMs) - $AgeMs }
        }
    }
    It 'finds the Claude process or 0, without error' {
        Get-ClaudePid | Should -BeGreaterOrEqual 0
    }
    It 'is not "all done" for a session working alone' {
        Set-SessionBusy 'a'
        Join-Path $Busy 'a.json' | Should -Exist
        Complete-SessionBusy 'a' | Should -BeFalse
        Join-Path $Busy 'a.json' | Should -Not -Exist
    }
    It 'is "all done" when the last of two sessions finishes' {
        Set-SessionBusy 'a'
        Set-FakeBusy 'a' $PID
        Set-SessionBusy 'b'
        Set-FakeBusy 'b' $PID
        Complete-SessionBusy 'a' | Should -BeFalse
        Complete-SessionBusy 'b' | Should -BeTrue
        $RoundPath | Should -Not -Exist
    }
    It 'does not count a session whose Claude process is gone, and removes its file' {
        Set-SessionBusy 'a'
        Set-FakeBusy 'a' $PID
        Set-SessionBusy 'dead'
        Set-FakeBusy 'dead' 2147483640
        Complete-SessionBusy 'a' | Should -BeTrue
        Join-Path $Busy 'dead.json' | Should -Not -Exist
    }
    It 'does not count a session working for more than 12 hours' {
        Set-SessionBusy 'a'
        Set-FakeBusy 'a' $PID
        Set-SessionBusy 'old'
        Set-FakeBusy 'old' 0 (13 * 3600 * 1000)
        Complete-SessionBusy 'a' | Should -BeTrue
    }
    It 'counts a recent session with an unknown Claude process' {
        Set-SessionBusy 'a'
        Set-FakeBusy 'a' $PID
        Set-SessionBusy 'unknown'
        Set-FakeBusy 'unknown' 0
        Complete-SessionBusy 'a' | Should -BeFalse
    }
    It 'starts a new round once nothing is working' {
        Set-SessionBusy 'a'
        Set-FakeBusy 'a' $PID
        Set-SessionBusy 'b'
        Set-FakeBusy 'b' $PID
        [void](Complete-SessionBusy 'a')
        [void](Complete-SessionBusy 'b')
        Set-SessionBusy 'c'
        Complete-SessionBusy 'c' | Should -BeFalse
    }
    It 'records the project of the session in the busy file' {
        Set-SessionBusy 'a' '' 'C:\dev\app'
        ([IO.File]::ReadAllText((Join-Path $Busy 'a.json')) | ConvertFrom-Json).cwd | Should -BeExactly 'C:\dev\app'
    }
}

Describe 'busy sessions whose turn was interrupted' {
    BeforeEach { Remove-Item -LiteralPath $Busy, $RoundPath -Recurse -Force -ErrorAction SilentlyContinue }
    # Esc fires no Stop: the process lives on, but the transcript stops growing
    It 'does not count a session whose transcript has been quiet for 20 minutes' {
        $quiet = Join-Path $TestDrive 'quiet.jsonl'
        [IO.File]::WriteAllText($quiet, '{}')
        (Get-Item -LiteralPath $quiet).LastWriteTime = (Get-Date).AddMinutes(-20)
        Set-SessionBusy 'a'
        Set-SessionBusy 'b' $quiet
        Remove-Item -LiteralPath (Join-Path $Busy 'a.json'), (Join-Path $Busy 'b.json') -Force
        Write-JsonAtomic (Join-Path $Busy 'a.json') @{ pid = $PID; since = Get-NowMs }
        Write-JsonAtomic (Join-Path $Busy 'b.json') @{ pid = $PID; since = Get-NowMs; transcript = $quiet }
        Complete-SessionBusy 'a' | Should -BeTrue
        Join-Path $Busy 'b.json' | Should -Not -Exist
    }
    It 'counts a session whose transcript was written a minute ago' {
        $live = Join-Path $TestDrive 'live.jsonl'
        [IO.File]::WriteAllText($live, '{}')
        Set-SessionBusy 'a'
        Set-SessionBusy 'b' $live
        Remove-Item -LiteralPath (Join-Path $Busy 'a.json'), (Join-Path $Busy 'b.json') -Force
        Write-JsonAtomic (Join-Path $Busy 'a.json') @{ pid = $PID; since = Get-NowMs }
        Write-JsonAtomic (Join-Path $Busy 'b.json') @{ pid = $PID; since = Get-NowMs; transcript = $live }
        Complete-SessionBusy 'a' | Should -BeFalse
    }
    It 'records the transcript path in the busy file' {
        Set-SessionBusy 'a' 'C:\x\t.jsonl'
        ([IO.File]::ReadAllText((Join-Path $Busy 'a.json')) | ConvertFrom-Json).transcript | Should -BeExactly 'C:\x\t.jsonl'
    }
}

Describe 'New-ChangeInfo' {
    It 'describes an Edit' {
        $c = New-ChangeInfo 'Edit' ([pscustomobject]@{ file_path = 'C:\a.ps1'; old_string = 'x'; new_string = 'y' })
        $c.kind | Should -BeExactly 'edit'
        @($c.edits).Count | Should -Be 1
        $c.edits[0].old | Should -BeExactly 'x'
        $c.edits[0].new | Should -BeExactly 'y'
    }
    It 'describes a Write' {
        $c = New-ChangeInfo 'Write' ([pscustomobject]@{ file_path = 'C:\a.ps1'; content = 'hello' })
        $c.kind | Should -BeExactly 'write'
        $c.content | Should -BeExactly 'hello'
    }
    It 'describes a MultiEdit, at most 5 edits' {
        $edits = 1..8 | ForEach-Object { [pscustomobject]@{ old_string = "o$_"; new_string = "n$_" } }
        $c = New-ChangeInfo 'MultiEdit' ([pscustomobject]@{ file_path = 'C:\a.ps1'; edits = $edits })
        $c.kind | Should -BeExactly 'edit'
        @($c.edits).Count | Should -Be 5
        $c.edits[4].new | Should -BeExactly 'n5'
    }
    It 'cuts long texts at 4000 characters' {
        $c = New-ChangeInfo 'Write' ([pscustomobject]@{ content = 'x' * 9000 })
        $c.content.Length | Should -Be 4000
    }
    It 'is null for other tools and for empty input' {
        New-ChangeInfo 'Bash' ([pscustomobject]@{ command = 'ls' }) | Should -BeNullOrEmpty
        New-ChangeInfo 'MultiEdit' ([pscustomobject]@{ edits = @() }) | Should -BeNullOrEmpty
        New-ChangeInfo 'Edit' $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-OfferedSuggestions' {
    It 'keeps allow rules, safe modes and directories, with their original index' {
        $list = '[
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"npm test *"}],"behavior":"allow","destination":"session","mode":null},
          {"type":"setMode","behavior":"allow","destination":"session","mode":"acceptEdits"},
          {"type":"addDirectories","directories":["C:\\other"],"destination":"session"}]' | ConvertFrom-Json
        $out = @(Get-OfferedSuggestions $list)
        $out.Count | Should -Be 3
        ($out | ForEach-Object { $_.index }) -join ',' | Should -BeExactly '0,1,2'
        $out[0].rules[0].toolName | Should -BeExactly 'Bash'
        $out[0].rules[0].ruleContent | Should -BeExactly 'npm test *'
        $out[1].mode | Should -BeExactly 'acceptEdits'
        $out[2].directories[0] | Should -BeExactly 'C:\other'
    }
    It 'drops removeRules, replaceRules, deny, ask, defer and bypassPermissions' {
        $list = '[
          {"type":"removeRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"userSettings"},
          {"type":"replaceRules","rules":[{"toolName":"Bash"}],"behavior":"allow","destination":"userSettings"},
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"rm *"}],"behavior":"deny","destination":"session"},
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls"}],"behavior":"ask","destination":"session"},
          {"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"pwd"}],"behavior":"defer","destination":"session"},
          {"type":"setMode","behavior":"allow","destination":"session","mode":"bypassPermissions"},
          {"type":"addRules","rules":[{"toolName":"Read"}],"behavior":"allow","destination":"session"}]' | ConvertFrom-Json
        $out = @(Get-OfferedSuggestions $list)
        $out.Count | Should -Be 1
        $out[0].index | Should -Be 6
    }
    It 'drops rules without rules and directories without directories' {
        $list = '[{"type":"addRules","rules":[],"behavior":"allow"},{"type":"addDirectories","directories":[]}]' | ConvertFrom-Json
        @(Get-OfferedSuggestions $list).Count | Should -Be 0
    }
    It 'returns nothing without suggestions' {
        @(Get-OfferedSuggestions $null).Count | Should -Be 0
    }
}

Describe 'ConvertTo-UpdatedPermission and New-PermissionOutput' {
    It 'keeps the suggestion as it came, without a null mode' {
        $s = '{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git *"}],"behavior":"allow","destination":"projectSettings","mode":null}' | ConvertFrom-Json
        ConvertTo-UpdatedPermission $s | ConvertTo-Json -Compress |
            Should -BeExactly '{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git *"}],"behavior":"allow","destination":"projectSettings"}'
    }
    It 'keeps the mode of a setMode suggestion' {
        $s = '{"type":"setMode","behavior":"allow","destination":"session","mode":"acceptEdits"}' | ConvertFrom-Json
        (ConvertTo-UpdatedPermission $s).mode | Should -BeExactly 'acceptEdits'
    }
    It 'adds updatedPermissions to the allow decision' {
        $s = '{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git *"}],"behavior":"allow","destination":"session"}' | ConvertFrom-Json
        $out = New-PermissionOutput 'allow' '' @(ConvertTo-UpdatedPermission $s)
        ConvertTo-AsciiJson $out | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git *"}],"behavior":"allow","destination":"session"}]}}}'
    }
}
