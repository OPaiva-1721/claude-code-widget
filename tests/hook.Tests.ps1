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
