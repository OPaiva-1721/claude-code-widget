# Test harness: runs hook.ps1 as a real process (the way Claude Code does) against a temporary data
# folder. The test holds the widget's mutex, so hook.ps1 believes the widget is running and never
# starts the real one; Wait-HookRequest / Send-WidgetResponse play the widget's part.
# Needs common.ps1 loaded first (Get-MutexName, Write-JsonAtomic).

function New-HookSandbox {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('ccw-e2e-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    # The same normalization hook.ps1 applies to CLAUDE_PLUGIN_DATA, so both compute the same mutex
    $dir = [IO.Path]::GetFullPath($dir).TrimEnd('\')
    return [pscustomobject]@{
        Data      = $dir
        Queue     = Join-Path $dir 'queue'
        Hook      = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\plugins\opaiva-code-widget\scripts\hook.ps1'))
        Mutex     = New-Object System.Threading.Mutex($true, (Get-MutexName $dir))
        MutexHeld = $true
    }
}

# Widget processes started for this sandbox: the hook starts a new widget when it replaces an old one
function Get-SandboxWidgets($Sandbox) {
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($Sandbox.Data, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

# While the test holds the mutex, such a widget finds it taken and exits on its own
function Wait-SandboxWidgetsExit($Sandbox, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    # @() at the call site: a single process comes back unwrapped, and a CimInstance has no Count
    while (@(Get-SandboxWidgets $Sandbox).Count -gt 0) {
        if ((Get-Date) -gt $deadline) { return $false }
        Start-Sleep -Milliseconds 250
    }
    return $true
}

function Remove-HookSandbox($Sandbox) {
    # Never release the mutex while a widget started for this sandbox is still starting up: it would
    # take the free mutex and stay on screen, pointing at a deleted data folder
    if (-not (Wait-SandboxWidgetsExit $Sandbox)) {
        Get-SandboxWidgets $Sandbox | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if ($Sandbox.MutexHeld) { $Sandbox.Mutex.ReleaseMutex() }
    $Sandbox.Mutex.Dispose()
    Remove-Item -LiteralPath $Sandbox.Data -Recurse -Force -ErrorAction SilentlyContinue
}

# "Closes the widget": hook.ps1 stops finding the mutex. Releasing is not enough: OpenExisting
# succeeds while any handle is open, so the handle is closed too (as when the widget process exits).
function Close-FakeWidget($Sandbox) {
    $Sandbox.Mutex.ReleaseMutex()
    $Sandbox.Mutex.Dispose()
    $Sandbox.MutexHeld = $false
}

# A hook event like Claude Code sends, with a unique session id
function New-HookEvent([string]$Name, [string]$Cwd, [hashtable]$Extra = @{}) {
    $e = [ordered]@{ hook_event_name = $Name; session_id = ('test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)); cwd = $Cwd }
    foreach ($k in $Extra.Keys) { $e[$k] = $Extra[$k] }
    return $e
}

# Starts hook.ps1 with the event as UTF-8 JSON on stdin (or -RawInput as is). Returns at once.
function Start-Hook {
    param($Sandbox, $HookInput, [hashtable]$Env = @{}, [string[]]$Arguments = @(), [string]$RawInput)
    $psi = New-Object System.Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $Sandbox.Hook)) + $Arguments) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.EnvironmentVariables['CLAUDE_PLUGIN_DATA'] = $Sandbox.Data
    $psi.EnvironmentVariables['CLAUDE_WIDGET_LANG'] = 'pt'
    # Far above any uptime: a CI machine that has had no input since boot is never "away"
    $psi.EnvironmentVariables['CLAUDE_WIDGET_AWAY_SECS'] = '2000000000'
    foreach ($k in $Env.Keys) { $psi.EnvironmentVariables[$k] = [string]$Env[$k] }
    $proc = [Diagnostics.Process]::Start($psi)
    $text = if ($PSBoundParameters.ContainsKey('RawInput')) { $RawInput } else { $HookInput | ConvertTo-Json -Depth 10 -Compress }
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text)
    $proc.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
    $proc.StandardInput.Close()
    return [pscustomobject]@{
        Process = $proc
        Stdout  = $proc.StandardOutput.ReadToEndAsync()
        Stderr  = $proc.StandardError.ReadToEndAsync()
        Clock   = [Diagnostics.Stopwatch]::StartNew()
    }
}

# Waits for hook.ps1 to exit
function Complete-Hook($Run, [int]$TimeoutSec = 60) {
    if (-not $Run.Process.WaitForExit($TimeoutSec * 1000)) {
        $Run.Process.Kill()
        throw "hook.ps1 did not exit within $TimeoutSec s"
    }
    $Run.Clock.Stop()
    return [pscustomobject]@{
        ExitCode = $Run.Process.ExitCode
        Stdout   = $Run.Stdout.Result.Trim()
        Stderr   = $Run.Stderr.Result.Trim()
        Seconds  = $Run.Clock.Elapsed.TotalSeconds
    }
}

# Plays the widget: waits for the hook's request file and returns it
function Wait-HookRequest($Sandbox, [int]$TimeoutSec = 30) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $f = Get-ChildItem -LiteralPath $Sandbox.Queue -Filter 'req-*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { return [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json }
        Start-Sleep -Milliseconds 100
    }
    throw "no request file after $TimeoutSec s"
}

function Send-WidgetResponse($Sandbox, [string]$Id, $Response) {
    Write-JsonAtomic (Join-Path $Sandbox.Queue "res-$Id.json") $Response
}
