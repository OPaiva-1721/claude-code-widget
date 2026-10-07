# End-to-end tests: hook.ps1 as a real process, JSON in on stdin, JSON out on stdout.
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\claude-code-widget\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'helpers\HookHarness.ps1')
    $pt = Get-Strings 'pt'
    function Get-QueueFiles($Sandbox, [string]$Filter = '*') {
        @(Get-ChildItem -LiteralPath $Sandbox.Queue -Filter $Filter -File -ErrorAction SilentlyContinue)
    }
}

Describe 'hook.ps1 end to end' {
    BeforeEach { $box = New-HookSandbox }
    AfterEach { Remove-HookSandbox $box }

    Context 'PermissionRequest' {
        BeforeAll {
            function New-BashEvent($Sandbox, [string]$Command) {
                New-HookEvent 'PermissionRequest' $Sandbox.Data @{ tool_name = 'Bash'; tool_input = @{ command = $Command } }
            }
        }

        It 'prints allow when the widget approves' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'permission'
            $req.tool | Should -Be 'Bash'
            $req.detail | Should -BeExactly 'npm test'
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            (Get-QueueFiles $box).Count | Should -Be 0
        }
        It 'prints deny with the localized message when the widget denies' {
            $run = Start-Hook $box (New-BashEvent $box 'rm -rf build')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'deny' }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $decision = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.decision
            $decision.behavior | Should -Be 'deny'
            $decision.message | Should -BeExactly $pt.deniedMessage
        }
        It 'prints nothing when the widget hands the request back' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It 'sends non-ASCII input to the widget intact' {
            $command = 'echo ' + [char]0x00E7 + [char]0x00E3 + 'o'
            $run = Start-Hook $box (New-BashEvent $box $command)
            $req = Wait-HookRequest $box
            $req.detail | Should -BeExactly $command
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
        It 'never routes plan approval (ExitPlanMode) to the widget' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
        It 'gives up within 5 s when the widget closes while waiting' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            [void](Wait-HookRequest $box)
            $closedAt = $run.Clock.Elapsed.TotalSeconds
            Close-FakeWidget $box
            $r = Complete-Hook $run
            $r.Stdout | Should -BeNullOrEmpty
            ($r.Seconds - $closedAt) | Should -BeLessThan 5
        }
        It 'skips the widget when the user is away' {
            $r = Complete-Hook (Start-Hook $box (New-BashEvent $box 'npm test') -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' })
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'AskUserQuestion' {
        It 'returns the answers in updatedInput and keeps the questions' {
            $question = 'Qual banco usar?'
            $answer = 'Op' + [char]0x00E7 + [char]0x00E3 + 'o B'
            $questions = @(@{ question = $question; header = 'Banco'; multiSelect = $false
                    options = @(@{ label = 'A'; description = 'a' }, @{ label = 'B'; description = 'b' }) })
            $run = Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = $questions } })
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'question'
            $req.description | Should -BeExactly $question
            Send-WidgetResponse $box $req.id @{ decision = 'answer'; answers = @{ $question = $answer } }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $out = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput
            $out.hookEventName | Should -Be 'PreToolUse'
            $out.permissionDecision | Should -Be 'allow'
            $out.permissionDecisionReason | Should -BeExactly $pt.answeredReason
            $out.updatedInput.answers.$question | Should -BeExactly $answer
            $out.updatedInput.questions[0].question | Should -BeExactly $question
        }
        It 'ignores PreToolUse for other tools' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }))
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'finished notices' {
        It 'Stop creates a notice and the next prompt removes it, printing nothing' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'Pronto: **testes** passaram. Veja [o log](http://x/y).' }
            $sid = $stop.session_id
            $r = Complete-Hook (Start-Hook $box $stop)
            $r.Stdout | Should -BeNullOrEmpty
            $notices = Get-QueueFiles $box "done-$sid-*.json"
            $notices.Count | Should -Be 1
            $notice = [IO.File]::ReadAllText($notices[0].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $notice.message | Should -BeExactly 'Pronto: testes passaram. Veja o log.'
            $notice.cwd | Should -BeExactly $box.Data

            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'next' }
            $prompt.session_id = $sid
            $r2 = Complete-Hook (Start-Hook $box $prompt)
            $r2.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box "done-$sid-*.json").Count | Should -Be 0
        }
    }

    # After a plugin update the old widget keeps running from the old folder; the hook finds it through
    # the shared mutex name and widget.json, and replaces it. The test keeps holding the mutex, so the
    # widget the hook starts in its place finds the mutex taken and exits at once (no window).
    Context 'widget from another version' {
        BeforeEach {
            $fake = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep 120'
        }
        AfterEach {
            if (-not $fake.HasExited) { $fake.Kill() }
        }

        It 'replaces a widget started from another script path' {
            Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $fake.Id; script = 'C:\old\1.1.0\scripts\widget.ps1' }
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $fake.WaitForExit(5000) | Should -BeTrue
            [IO.File]::ReadAllText((Join-Path $box.Data 'hook.log')) | Should -Match 'restarting widget from an older version'
            # The widget started in its place sees the mutex still taken (by the test) and steps aside
            Wait-SandboxWidgetsExit $box | Should -BeTrue
        }
        It 'keeps a widget started from this version' {
            $current = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $box.Hook) 'widget.ps1'))
            Write-JsonAtomic (Join-Path $box.Data 'widget.json') @{ pid = $fake.Id; script = $current }
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.Stdout | Should -BeNullOrEmpty
            $fake.HasExited | Should -BeFalse
            [IO.File]::ReadAllText((Join-Path $box.Data 'hook.log')) | Should -Not -Match 'restarting'
        }
    }

    Context 'robustness' {
        It 'SessionStart prints nothing' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It '-EnsureWidget prints nothing when the widget is running' {
            $r = Complete-Hook (Start-Hook $box $null -Arguments @('-EnsureWidget') -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $r.Seconds | Should -BeLessThan 15
        }
        It 'exits quietly on input that is not JSON' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput 'not json')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It 'exits quietly on empty input' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
    }
}
