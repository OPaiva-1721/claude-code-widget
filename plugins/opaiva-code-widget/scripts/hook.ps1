# opaiva-code-widget: Claude Code hook (Windows PowerShell 5.1).
# One script for every event; Invoke-Hook routes on hook_event_name:
#   PermissionRequest            -> queue\req-<id>.json (kind=permission), waits for queue\res-<id>.json,
#                                   prints allow/deny.
#   PreToolUse (AskUserQuestion) -> queue\req-<id>.json (kind=question), waits for the answers,
#                                   prints permissionDecision=allow + updatedInput.answers.
#   Stop                         -> queue\done-<session>-<ms>.json ("Claude finished"), unless you are
#                                   already looking at that session's window.
#   UserPromptSubmit             -> removes that session's "finished" notice (you are back in it) and
#                                   remembers the window in front (sessions\<session>.json) when it
#                                   belongs to this Claude Code session: VS Code or a terminal.
#   SessionStart / -EnsureWidget -> only makes sure the widget is running.
# Computer idle (no mouse/keyboard for $AwaySecs): requests and questions skip the widget and go
# straight to VS Code (and to your phone/browser when Remote Control is on).
# No answer ("in VS Code", widget closed, idle or timeout) = no output -> Claude Code's normal flow.
# Stop/UserPromptSubmit/SessionStart never print anything (it would end up in Claude's context).
# Dot-sourcing this file (tests) only defines the functions; see the end of the file.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. UI text lives in
# strings.json (read explicitly as UTF-8).
param([switch]$EnsureWidget)
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'common.ps1')

$WidgetScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'widget.ps1'))
# Plugin data dir survives plugin updates; fallback for running the scripts outside a plugin
$Data = if ($env:CLAUDE_PLUGIN_DATA) { $env:CLAUDE_PLUGIN_DATA } else { Join-Path $env:USERPROFILE '.claude\opaiva-code-widget' }
$Data = [IO.Path]::GetFullPath($Data).TrimEnd('\')
$Queue = Join-Path $Data 'queue'
$Sessions = Join-Path $Data 'sessions'
# Sessions working right now (busy\<session>.json) and the sessions of the current round
$Busy = Join-Path $Data 'busy'
$RoundPath = Join-Path $Data 'busy-round.json'
$BusyMaxAgeMs = 12 * 3600 * 1000
$LogPath = Join-Path $Data 'hook.log'
# Processes that own a terminal window (classic console, Windows Terminal and common alternatives)
$TerminalHosts = @('windowsterminal.exe', 'openconsole.exe', 'conhost.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe',
    'wezterm-gui.exe', 'alacritty.exe', 'mintty.exe', 'tabby.exe', 'hyper.exe')
# Processes that own a VS Code window
$VsCodeProcesses = @('code.exe', 'code - insiders.exe')
$TimeoutSecs = 300
$AwaySecs = 120
if ($env:CLAUDE_WIDGET_AWAY_SECS) { $AwaySecs = [int]$env:CLAUDE_WIDGET_AWAY_SECS }

$Lang = Resolve-Lang $env:CLAUDE_WIDGET_LANG
$S = Get-Strings $Lang

# One widget per data dir; the widget computes the same name
$MutexName = Get-MutexName $Data
$script:waitEnd = $null

function Write-HookLog([string]$msg) { Write-LogLine $LogPath $msg }

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

function Initialize-Win32 {
    if ('ClaudeWidget.Win' -as [type]) { return }
    Add-Type -Namespace ClaudeWidget -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
'@
}

function Get-WindowTitle([IntPtr]$h) {
    $sb = New-Object System.Text.StringBuilder 512
    [void][ClaudeWidget.Win]::GetWindowText($h, $sb, 512)
    return $sb.ToString()
}

# This hook's ancestors (Claude Code, its shell, the terminal or VS Code) + a pid -> process map
function Get-ProcessTree {
    $map = @{}
    foreach ($p in Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name) { $map[[int]$p.ProcessId] = $p }
    $ancestors = @{}
    $cur = [int]$PID
    for ($i = 0; $i -lt 16 -and $map.ContainsKey($cur); $i++) {
        $parent = [int]$map[$cur].ParentProcessId
        if ($parent -eq 0 -or $ancestors.ContainsKey($parent)) { break }
        $ancestors[$parent] = $true
        $cur = $parent
    }
    return @{ map = $map; ancestors = $ancestors }
}

# vscode / terminal / other, from the name of the process that owns the window
function Get-WindowKind([string]$ProcessName) {
    $name = $ProcessName.ToLowerInvariant()
    if ($VsCodeProcesses -contains $name) { return 'vscode' }
    if ($TerminalHosts -contains $name) { return 'terminal' }
    return 'other'
}

# On UserPromptSubmit the window in front is almost always where you typed. Remember it, but only
# if it really belongs to this session: its owner (or the owner's parent, for a classic console
# whose window belongs to conhost.exe) must be one of this hook's ancestors. A prompt sent from
# your phone (Remote Control) leaves some unrelated window in front and is ignored.
function Save-SessionWindow([string]$sid, [string]$logTag) {
    if (-not $sid) { return }
    try {
        Initialize-Win32
        $fg = [ClaudeWidget.Win]::GetForegroundWindow()
        if ($fg -eq [IntPtr]::Zero) { return }
        $ownerPid = [uint32]0
        [void][ClaudeWidget.Win]::GetWindowThreadProcessId($fg, [ref]$ownerPid)
        $tree = Get-ProcessTree
        $owner = $tree.map[[int]$ownerPid]
        $ownerParent = if ($owner) { [int]$owner.ParentProcessId } else { 0 }
        if (-not ($tree.ancestors.ContainsKey([int]$ownerPid) -or $tree.ancestors.ContainsKey($ownerParent))) {
            Write-HookLog "$logTag window in front is not this session's, not saved"
            return
        }
        $name = if ($owner) { ([string]$owner.Name).ToLowerInvariant() } else { '' }
        $kind = Get-WindowKind $name
        New-Item -ItemType Directory -Force -Path $Sessions | Out-Null
        [IO.File]::WriteAllText((Join-Path $Sessions "$sid.json"), (@{ hwnd = $fg.ToInt64(); kind = $kind; process = $name } | ConvertTo-Json -Compress), $Utf8)
        Write-HookLog "$logTag session window saved ($kind, $name)"
        # Forget sessions untouched for a week
        Get-ChildItem -LiteralPath $Sessions -File | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch { Write-HookLog "$logTag session window: $($_.Exception.Message)" }
}

# This session's Claude Code process: the first ancestor named claude.exe, else node.exe (npm
# install), else 0 (unknown)
function Get-ClaudePid {
    try {
        $map = (Get-ProcessTree).map
        $node = 0
        $cur = [int]$PID
        for ($i = 0; $i -lt 16 -and $map.ContainsKey($cur); $i++) {
            $parent = [int]$map[$cur].ParentProcessId
            if ($parent -eq 0 -or -not $map.ContainsKey($parent)) { break }
            $name = ([string]$map[$parent].Name).ToLowerInvariant()
            if ($name -eq 'claude.exe') { return $parent }
            if ($name -eq 'node.exe' -and $node -eq 0) { $node = $parent }
            $cur = $parent
        }
        return $node
    } catch { return 0 }
}

# Ids of the sessions still working: their Claude process runs (or is unknown) and they started less
# than 12 hours ago. Files of the other sessions are removed.
function Get-WorkingSessions {
    $now = Get-NowMs
    foreach ($f in @(Get-ChildItem -LiteralPath $Busy -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $alive = $false
        try {
            $b = [IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json
            $alive = (($now - [int64]$b.since) -lt $BusyMaxAgeMs) -and
                ([int]$b.pid -eq 0 -or $null -ne (Get-Process -Id ([int]$b.pid) -ErrorAction SilentlyContinue))
        } catch {}
        if ($alive) { $f.BaseName } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# UserPromptSubmit: this session is working. With nothing else working, a new round starts.
function Set-SessionBusy([string]$Sid) {
    if (-not $Sid) { return }
    try {
        $others = @(Get-WorkingSessions | Where-Object { $_ -ne $Sid })
        $round = @()
        if ($others.Count -gt 0 -and (Test-Path -LiteralPath $RoundPath)) {
            try { $round = @(([IO.File]::ReadAllText($RoundPath, $Utf8) | ConvertFrom-Json).sessions) } catch {}
        }
        if ($round -notcontains $Sid) { $round += $Sid }
        New-Item -ItemType Directory -Force -Path $Busy | Out-Null
        $file = Join-Path $Busy "$Sid.json"
        Remove-Item -LiteralPath $file, $RoundPath -Force -ErrorAction SilentlyContinue
        Write-JsonAtomic $file ([ordered]@{ pid = Get-ClaudePid; since = Get-NowMs })
        Write-JsonAtomic $RoundPath @{ sessions = @($round) }
    } catch {}
}

# Stop: this session is done. $true ("all done") when nothing else is working and the round had at
# least two sessions; with a single session the usual "finished" sound stays.
function Complete-SessionBusy([string]$Sid) {
    try {
        if ($Sid) { Remove-Item -LiteralPath (Join-Path $Busy "$Sid.json") -Force -ErrorAction SilentlyContinue }
        if (@(Get-WorkingSessions).Count -gt 0) { return $false }
        $round = @()
        try { $round = @(([IO.File]::ReadAllText($RoundPath, $Utf8) | ConvertFrom-Json).sessions) } catch {}
        Remove-Item -LiteralPath $RoundPath -Force -ErrorAction SilentlyContinue
        return @($round | Select-Object -Unique).Count -ge 2
    } catch { return $false }
}

# The session's remembered window, if it still exists
function Get-SessionWindow([string]$sid) {
    if (-not $sid) { return $null }
    $path = Join-Path $Sessions "$sid.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        $w = [IO.File]::ReadAllText($path, $Utf8) | ConvertFrom-Json
        Initialize-Win32
        if ([ClaudeWidget.Win]::IsWindow([IntPtr]::new([int64]$w.hwnd))) { return $w }
    } catch {}
    return $null
}

# Are you already looking at this session? Then no "finished" notice is needed.
# With a remembered window: is it in front? Without one: is this project's VS Code window in front?
function Test-UserWatching([string]$cwd, $sessionWindow) {
    try {
        Initialize-Win32
        $fg = [ClaudeWidget.Win]::GetForegroundWindow()
        if ($sessionWindow) { return $fg.ToInt64() -eq [int64]$sessionWindow.hwnd }
        if (-not $cwd) { return $false }
        $title = Get-WindowTitle $fg
        $project = Split-Path -Leaf $cwd
        return ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
               (Test-TitleHasProject $title $project)
    } catch { return $false }
}

# The session's title as Claude Code shows it: the name given with /rename (custom-title), else the
# automatic one (ai-title). Both are repeated in the transcript every few turns, so the last 512 KB
# are enough. Empty when there is none or the transcript cannot be read.
function Get-SessionTitle([string]$TranscriptPath, [string]$SessionId) {
    if (-not $TranscriptPath) { return '' }
    try {
        $fs = [IO.File]::Open($TranscriptPath, 'Open', 'Read', 'ReadWrite')
        try {
            $start = [math]::Max([int64]0, $fs.Length - [int64]512KB)
            [void]$fs.Seek($start, 'Begin')
            $buf = New-Object byte[] ([int]($fs.Length - $start))
            $n = 0
            while ($n -lt $buf.Length) {
                $read = $fs.Read($buf, $n, $buf.Length - $n)
                if ($read -le 0) { break }
                $n += $read
            }
        }
        finally { $fs.Dispose() }
        $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $n) -split "`n"
        # Reading from the middle of the file: the first line is cut
        if ($start -gt 0) { $lines = @($lines | Select-Object -Skip 1) }
        $custom = ''
        $auto = ''
        foreach ($line in $lines) {
            if ($line.IndexOf('"custom-title"') -lt 0 -and $line.IndexOf('"ai-title"') -lt 0) { continue }
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if ($o.sessionId -and $SessionId -and [string]$o.sessionId -ne $SessionId) { continue }
            if ($o.type -eq 'custom-title' -and $o.customTitle) { $custom = [string]$o.customTitle }
            elseif ($o.type -eq 'ai-title' -and $o.aiTitle) { $auto = [string]$o.aiTitle }
        }
        if ($custom) { return $custom.Trim() }
        return $auto.Trim()
    } catch { return '' }
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

function New-Request([string]$kind, [string]$cwd, [hashtable]$fields) {
    New-Item -ItemType Directory -Force -Path $Queue | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $req = [ordered]@{
        id      = $id
        pid     = $PID
        kind    = $kind
        created = Get-NowMs
        timeout = $TimeoutSecs
        cwd     = $cwd
    }
    foreach ($k in $fields.Keys) { $req[$k] = $fields[$k] }
    Write-JsonAtomic (Join-Path $Queue "req-$id.json") $req
    return $id
}

function Remove-Request([string]$id) {
    Remove-Item -LiteralPath (Join-Path $Queue "req-$id.json"), (Join-Path $Queue "res-$id.json") -Force -ErrorAction SilentlyContinue
}

# What the permission card shows: the command, file, URL or query; otherwise the raw input
function Get-PermissionDetail($ToolInput) {
    if ($ToolInput.command) { $detail = [string]$ToolInput.command }
    elseif ($ToolInput.file_path) { $detail = [string]$ToolInput.file_path }
    elseif ($ToolInput.notebook_path) { $detail = [string]$ToolInput.notebook_path }
    elseif ($ToolInput.url) { $detail = [string]$ToolInput.url }
    elseif ($ToolInput.query) { $detail = [string]$ToolInput.query }
    else { $detail = [string]($ToolInput | ConvertTo-Json -Depth 4 -Compress) }
    if ($detail.Length -gt 2000) { $detail = $detail.Substring(0, 2000) + ' ...' }
    return $detail
}

# PermissionRequest answer in Claude Code's hook format; deny carries a message for Claude
function New-PermissionOutput([string]$Behavior, [string]$Message) {
    $decision = [ordered]@{ behavior = $Behavior }
    if ($Behavior -eq 'deny') { $decision.message = $Message }
    return [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $decision } }
}

# AskUserQuestion answered: allow the tool with updatedInput = the original input + answers
# (question text -> chosen label, or free text)
function New-AnswerOutput($ToolInput, $Answers, [string]$Reason) {
    $ToolInput | Add-Member -NotePropertyName answers -NotePropertyValue $Answers -Force
    return [ordered]@{
        hookSpecificOutput = [ordered]@{
            hookEventName            = 'PreToolUse'
            permissionDecision       = 'allow'
            permissionDecisionReason = $Reason
            updatedInput             = $ToolInput
        }
    }
}

# Routes one hook event. Returns the JSON to print, or $null = no output (Claude Code's normal flow).
# Nothing in here may write to the pipeline except the return value: Claude Code reads stdout.
function Invoke-Hook($evt) {
    $hookEvent = [string]$evt.hook_event_name
    $sid = ([string]$evt.session_id) -replace '[^A-Za-z0-9-]', ''
    $logTag = '{0} {1}' -f $hookEvent, $sid.Substring(0, [math]::Min(8, $sid.Length))
    $tool = [string]$evt.tool_name
    $in = $evt.tool_input
    $cwd = [string]$evt.cwd
    $transcript = [string]$evt.transcript_path

    if ($hookEvent -eq 'SessionStart') { Write-HookLog $logTag; [void](Start-Widget); return $null }

    if ($hookEvent -eq 'UserPromptSubmit') {
        Write-HookLog $logTag
        Remove-Done $sid
        Set-SessionBusy $sid
        Save-SessionWindow $sid $logTag
        return $null
    }

    if ($hookEvent -eq 'Stop') {
        if (-not $sid) { return $null }
        Remove-Done $sid
        # Before deciding on the notice: the session stops counting as working even without one
        $allDone = Complete-SessionBusy $sid
        $sessionWindow = Get-SessionWindow $sid
        if (Test-UserWatching $cwd $sessionWindow) { Write-HookLog "$logTag no notice (session window in front)"; return $null }
        $msg = Format-Snippet (Get-LastAssistantText $evt)
        if (-not $msg) { $msg = $S.readyNext }
        New-Item -ItemType Directory -Force -Path $Queue | Out-Null
        $now = Get-NowMs
        Write-JsonAtomic (Join-Path $Queue "done-$sid-$now.json") ([ordered]@{
            session = $sid
            created = $now
            cwd     = $cwd
            message = $msg
            title   = Get-SessionTitle $transcript $sid
            allDone = [bool]$allDone
            # Lets the widget's button go back to that exact window (VS Code or terminal)
            hwnd    = $(if ($sessionWindow) { [int64]$sessionWindow.hwnd } else { 0 })
            kind    = $(if ($sessionWindow) { [string]$sessionWindow.kind } else { '' })
        })
        Write-HookLog "$logTag notice created"
        [void](Start-Widget)
        return $null
    }

    # ---------------- PreToolUse: multiple-choice questions ----------------
    if ($hookEvent -eq 'PreToolUse') {
        if ($tool -ne 'AskUserQuestion') { return $null }
        $questions = @($in.questions)
        if ($questions.Count -eq 0) { return $null }
        if (Test-Away) { Write-HookLog "$logTag idle: question goes to VS Code"; return $null }
        if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; return $null }
        Remove-Done $sid

        $id = New-Request 'question' $cwd @{
            tool        = $tool
            description = [string]$questions[0].question
            questions   = $questions
            title       = Get-SessionTitle $transcript $sid
        }
        try { $res = Wait-Response $id } finally { Remove-Request $id }

        if ($res -and $res.decision -eq 'answer' -and $res.answers) {
            Write-HookLog "$logTag answered in the widget"
            return ConvertTo-AsciiJson (New-AnswerOutput $in $res.answers $S.answeredReason)
        }
        $why = if ($res) { [string]$res.decision } else { $script:waitEnd }
        Write-HookLog "$logTag goes to VS Code ($why)"
        return $null
    }

    # ---------------- PermissionRequest ----------------
    if ($hookEvent -eq 'PermissionRequest') {
        # These already need the screen (questions, plan approval) -> normal flow
        if ($tool -in @('AskUserQuestion', 'ExitPlanMode')) { return $null }
        if (Test-Away) { Write-HookLog "$logTag $tool idle: goes to VS Code"; return $null }

        $detail = Get-PermissionDetail $in
        $desc = [string]$in.description
        if (-not $desc) { $desc = $S.wantsTool -f $tool }

        # Widget did not come up -> don't keep Claude Code waiting for nobody
        if (-not (Start-Widget)) { Write-HookLog "$logTag widget did not start"; return $null }
        # The session is working again: its previous "finished" notice is stale
        Remove-Done $sid

        $id = New-Request 'permission' $cwd @{
            tool        = $tool
            description = $desc
            detail      = $detail
            title       = Get-SessionTitle $transcript $sid
        }
        try { $res = Wait-Response $id } finally { Remove-Request $id }

        $decision = if ($res) { [string]$res.decision } else { $null }
        Write-HookLog ("$logTag $tool -> " + $(if ($decision) { $decision } else { $script:waitEnd }))
        if ($decision -in @('allow', 'deny')) { return ConvertTo-AsciiJson (New-PermissionOutput $decision $S.deniedMessage) }
        return $null
    }

    return $null
}

# Loaded with dot-source (tests): stop here, only the functions above are wanted
if ($MyInvocation.InvocationName -eq '.') { return }

if ($EnsureWidget) { [void](Start-Widget); exit 0 }

[Console]::InputEncoding = [Text.Encoding]::UTF8
# Not "$data": PowerShell variable names are case-insensitive and $Data is the data folder
try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
$out = Invoke-Hook $evt
if ($out) { $out }
exit 0
