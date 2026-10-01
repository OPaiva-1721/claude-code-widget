# claude-code-widget: Claude Code hook (Windows PowerShell 5.1).
# One script for every event; the route comes from hook_event_name:
#   PermissionRequest            -> queue\req-<id>.json (kind=permission), waits for queue\res-<id>.json,
#                                   prints allow/deny.
#   PreToolUse (AskUserQuestion) -> queue\req-<id>.json (kind=question), waits for the answers,
#                                   prints permissionDecision=allow + updatedInput.answers.
#   Stop                         -> queue\done-<session>-<ms>.json ("Claude finished"), unless you are
#                                   already looking at that project's VS Code window.
#   UserPromptSubmit             -> removes that session's "finished" notice (you are back in it).
#   SessionStart / -EnsureWidget -> only makes sure the widget is running.
# Computer idle (no mouse/keyboard for $AwaySecs): requests and questions skip the widget and go
# straight to VS Code (and to your phone/browser when Remote Control is on).
# No answer ("in VS Code", widget closed, idle or timeout) = no output -> Claude Code's normal flow.
# Stop/UserPromptSubmit/SessionStart never print anything (it would end up in Claude's context).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. UI text lives in
# strings.json (read explicitly as UTF-8).
param([switch]$EnsureWidget)
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false

$WidgetScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'widget.ps1'))
# Plugin data dir survives plugin updates; fallback for running the scripts outside a plugin
$Data = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { Join-Path $env:USERPROFILE '.claude\claude-code-widget' }
$Data = [IO.Path]::GetFullPath($Data).TrimEnd('\')
$Queue = Join-Path $Data 'queue'
$LogPath = Join-Path $Data 'hook.log'
$TimeoutSecs = 300
$AwaySecs = 120
if ($env:CLAUDE_WIDGET_AWAY_SECS) { $AwaySecs = [int]$env:CLAUDE_WIDGET_AWAY_SECS }

$Lang = if ($env:CLAUDE_WIDGET_LANG) { $env:CLAUDE_WIDGET_LANG } else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
if ($Lang -ne 'pt') { $Lang = 'en' }
$S = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'strings.json'), $Utf8) | ConvertFrom-Json).$Lang

# One widget per data dir; the widget computes the same name
function Get-MutexName([string]$dir) {
    $hash = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($dir.ToLowerInvariant()))
    return 'Local\ClaudeCodeWidget-' + (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}
$MutexName = Get-MutexName $Data
$script:waitEnd = $null

function Write-HookLog([string]$msg) {
    try {
        New-Item -ItemType Directory -Force -Path $Data | Out-Null
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 256KB) {
            Remove-Item -LiteralPath "$LogPath.old" -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $LogPath -NewName 'hook.log.old'
        }
        Add-Content -LiteralPath $LogPath -Value ('{0:s} {1}' -f (Get-Date), $msg)
    } catch {}
}

function Test-Widget {
    try { [System.Threading.Mutex]::OpenExisting($MutexName).Dispose(); return $true } catch { return $false }
}

function Start-Widget {
    if (Test-Widget) {
        # After a plugin update the old widget keeps running from the old folder: replace it
        $info = $null
        try { $info = [IO.File]::ReadAllText((Join-Path $Data 'widget.json'), $Utf8) | ConvertFrom-Json } catch {}
        if (-not $info -or -not $info.script -or
            [string]::Equals([IO.Path]::GetFullPath([string]$info.script), $WidgetScript, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
        Write-HookLog "restarting widget from an older version ($($info.script))"
        try { Stop-Process -Id ([int]$info.pid) -Force } catch {}
        for ($i = 0; $i -lt 30 -and (Test-Widget); $i++) { Start-Sleep -Milliseconds 100 }
    }
    New-Item -ItemType Directory -Force -Path $Data | Out-Null
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -DataDir "{1}" -Lang {2}' -f $WidgetScript, $Data, $Lang
    # Through WMI the widget is created outside Claude Code's process tree, so it outlives the session
    $si = New-CimInstance -ClassName Win32_ProcessStartup -ClientOnly -Property @{ ShowWindow = [uint16]0 }
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd; ProcessStartupInformation = $si } | Out-Null
    # The very first start of new scripts can take ~10 s (antivirus scan); later starts take ~1-2 s
    for ($i = 0; $i -lt 200; $i++) {
        if (Test-Widget) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

# Write to .tmp, then rename: the widget never reads a half-written file
function Write-JsonAtomic($path, $obj) {
    [IO.File]::WriteAllText("$path.tmp", ($obj | ConvertTo-Json -Depth 10 -Compress), $Utf8)
    [IO.File]::Move("$path.tmp", $path)
}

# Hook output as pure ASCII (\uXXXX), independent of the PowerShell 5.1 console encoding
function ConvertTo-AsciiJson($obj) {
    $json = $obj | ConvertTo-Json -Depth 12 -Compress
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
}

function Remove-Done([string]$sid) {
    if (-not $sid) { return }
    Get-ChildItem -LiteralPath $Queue -Filter "done-$sid-*.json" -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function Get-IdleSeconds {
    try {
        if (-not ('ClaudeWidget.Idle' -as [type])) {
            Add-Type -Namespace ClaudeWidget -Name Idle -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
[DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
public static uint Seconds() {
    var info = new LASTINPUTINFO();
    info.cbSize = (uint)Marshal.SizeOf(info);
    if (!GetLastInputInfo(ref info)) return 0;
    return ((uint)Environment.TickCount - info.dwTime) / 1000;
}
'@
        }
        return [int][ClaudeWidget.Idle]::Seconds()
    } catch { return 0 }
}

function Test-Away { return (Get-IdleSeconds) -ge $AwaySecs }

# Is this project's VS Code window in front? Then no "finished" notice is needed.
function Test-UserWatching([string]$cwd) {
    if (-not $cwd) { return $false }
    try {
        Add-Type -Namespace ClaudeWidget -Name Fg -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
'@
        $sb = New-Object System.Text.StringBuilder 512
        [void][ClaudeWidget.Fg]::GetWindowText([ClaudeWidget.Fg]::GetForegroundWindow(), $sb, 512)
        $title = $sb.ToString()
        $project = Split-Path -Leaf $cwd
        return ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
               ($title.IndexOf($project, [StringComparison]::OrdinalIgnoreCase) -ge 0)
    } catch { return $false }
}

# Text of Claude's last reply: the event field when present, otherwise the end of the transcript
function Get-LastAssistantText($evt) {
    if ($evt.last_assistant_message) { return [string]$evt.last_assistant_message }
    $tp = [string]$evt.transcript_path
    if (-not $tp -or -not (Test-Path -LiteralPath $tp)) { return '' }
    try {
        $lines = @(Get-Content -LiteralPath $tp -Tail 80 -Encoding UTF8)
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -notlike '*"assistant"*') { continue }
            try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
            if ($o.type -ne 'assistant') { continue }
            $texts = @($o.message.content | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text })
            if ($texts.Count -gt 0) { return ($texts -join ' ') }
        }
    } catch {}
    return ''
}

# Markdown -> short plain text
function Format-Snippet([string]$text) {
    $t = $text -replace '(?s)```.*?```', ' '
    $t = $t -replace '\[([^\]]+)\]\([^)]*\)', '$1'
    $t = $t -replace '[`*_#>|]', '' -replace '\s+', ' '
    $t = $t.Trim()
    if ($t.Length -gt 300) { $t = $t.Substring(0, 300).TrimEnd() + '...' }
    return $t
}

# Waits for the widget's queue\res-<id>.json. $null = gave up ($script:waitEnd says why).
function Wait-Response([string]$id) {
    $resPath = Join-Path $Queue "res-$id.json"
    $parentPid = $null
    try { $parentPid = (Get-CimInstance Win32_Process -Filter "ProcessId=$PID").ParentProcessId } catch {}
    $deadline = (Get-Date).AddSeconds($TimeoutSecs)
    $tick = 0
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $resPath) {
            try { return ([IO.File]::ReadAllText($resPath, $Utf8) | ConvertFrom-Json) } catch { return $null }
        }
        $tick++
        if ($tick % 5 -eq 0) {
            if (-not (Test-Widget)) { $script:waitEnd = 'widget closed'; return $null }
            if ($parentPid -and -not (Get-Process -Id $parentPid -ErrorAction SilentlyContinue)) { $script:waitEnd = 'session ended'; return $null }
            # You walked away with the card on screen: hand it to VS Code / your phone
            if (Test-Away) { $script:waitEnd = 'idle'; return $null }
        }
        Start-Sleep -Milliseconds 300
    }
    $script:waitEnd = 'timeout'
    return $null
}

function New-Request([string]$kind, [hashtable]$fields) {
    New-Item -ItemType Directory -Force -Path $Queue | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $req = [ordered]@{
        id      = $id
        pid     = $PID
        kind    = $kind
        created = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        timeout = $TimeoutSecs
        cwd     = [string]$evt.cwd
    }
    foreach ($k in $fields.Keys) { $req[$k] = $fields[$k] }
    Write-JsonAtomic (Join-Path $Queue "req-$id.json") $req
    return $id
}

function Remove-Request([string]$id) {
    Remove-Item -LiteralPath (Join-Path $Queue "req-$id.json"), (Join-Path $Queue "res-$id.json") -Force -ErrorAction SilentlyContinue
}

if ($EnsureWidget) { [void](Start-Widget); exit 0 }

[Console]::InputEncoding = [Text.Encoding]::UTF8
# Not "$data": PowerShell variable names are case-insensitive and $Data is the data folder
try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }

$hookEvent = [string]$evt.hook_event_name
$sid = ([string]$evt.session_id) -replace '[^A-Za-z0-9-]', ''
$logTag = '{0} {1}' -f $hookEvent, $sid.Substring(0, [math]::Min(8, $sid.Length))
$tool = [string]$evt.tool_name
$in = $evt.tool_input

if ($hookEvent -eq 'SessionStart') { Write-HookLog $logTag; [void](Start-Widget); exit 0 }

if ($hookEvent -eq 'UserPromptSubmit') { Write-HookLog $logTag; Remove-Done $sid; exit 0 }

if ($hookEvent -eq 'Stop') {
    if (-not $sid) { exit 0 }
    Remove-Done $sid
    $cwd = [string]$evt.cwd
    if (Test-UserWatching $cwd) { Write-HookLog "$logTag no notice (project's VS Code window in front)"; exit 0 }
    $msg = Format-Snippet (Get-LastAssistantText $evt)
    if (-not $msg) { $msg = $S.readyNext }
    New-Item -ItemType Directory -Force -Path $Queue | Out-Null
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Write-JsonAtomic (Join-Path $Queue "done-$sid-$now.json") ([ordered]@{
        session = $sid
        created = $now
        cwd     = $cwd
        message = $msg
    })
    Write-HookLog "$logTag notice created"
    [void](Start-Widget)
    exit 0
}

# ---------------- PreToolUse: multiple-choice questions ----------------
if ($hookEvent -eq 'PreToolUse') {
    if ($tool -ne 'AskUserQuestion') { exit 0 }
    $questions = @($in.questions)
    if ($questions.Count -eq 0) { exit 0 }
    if (Test-Away) { Write-HookLog "$logTag idle: question goes to VS Code"; exit 0 }
    if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; exit 0 }
    Remove-Done $sid

    $id = New-Request 'question' @{
        tool        = $tool
        description = [string]$questions[0].question
        questions   = $questions
    }
    try { $res = Wait-Response $id } finally { Remove-Request $id }

    if ($res -and $res.decision -eq 'answer' -and $res.answers) {
        # updatedInput = original input + answers (question text -> chosen label, or free text)
        $in | Add-Member -NotePropertyName answers -NotePropertyValue $res.answers -Force
        Write-HookLog "$logTag answered in the widget"
        ConvertTo-AsciiJson ([ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName            = 'PreToolUse'
                permissionDecision       = 'allow'
                permissionDecisionReason = $S.answeredReason
                updatedInput             = $in
            }
        })
    }
    else {
        $why = if ($res) { [string]$res.decision } else { $script:waitEnd }
        Write-HookLog "$logTag goes to VS Code ($why)"
    }
    exit 0
}

# ---------------- PermissionRequest ----------------
if ($hookEvent -eq 'PermissionRequest') {
    # These already need the screen (questions, plan approval) -> normal flow
    if ($tool -in @('AskUserQuestion', 'ExitPlanMode')) { exit 0 }
    if (Test-Away) { Write-HookLog "$logTag $tool idle: goes to VS Code"; exit 0 }

    if ($in.command) { $detail = [string]$in.command }
    elseif ($in.file_path) { $detail = [string]$in.file_path }
    elseif ($in.notebook_path) { $detail = [string]$in.notebook_path }
    elseif ($in.url) { $detail = [string]$in.url }
    elseif ($in.query) { $detail = [string]$in.query }
    else { $detail = $in | ConvertTo-Json -Depth 4 -Compress }
    if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + ' ...' }

    $desc = [string]$in.description
    if (-not $desc) { $desc = $S.wantsTool -f $tool }

    # Widget did not come up -> don't keep Claude Code waiting for nobody
    if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; exit 0 }
    # The session is working again: its previous "finished" notice is stale
    Remove-Done $sid

    $id = New-Request 'permission' @{
        tool        = $tool
        description = $desc
        detail      = $detail
    }
    try { $res = Wait-Response $id } finally { Remove-Request $id }

    $decision = if ($res) { [string]$res.decision } else { $null }
    Write-HookLog ("$logTag $tool -> " + $(if ($decision) { $decision } else { $script:waitEnd }))
    if ($decision -eq 'allow') {
        ConvertTo-AsciiJson ([ordered]@{
            hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = [ordered]@{ behavior = 'allow' } }
        })
    }
    elseif ($decision -eq 'deny') {
        ConvertTo-AsciiJson ([ordered]@{
            hookSpecificOutput = [ordered]@{
                hookEventName = 'PermissionRequest'
                decision      = [ordered]@{ behavior = 'deny'; message = $S.deniedMessage }
            }
        })
    }
    exit 0
}

exit 0
