# opaiva-code-widget: helpers shared by hook.ps1 and widget.ps1 (Windows PowerShell 5.1).
# Both load it with:  . (Join-Path $PSScriptRoot 'common.ps1')
# Loading it only defines functions: no files, folders or preferences are touched.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI.

function Get-Utf8NoBom { New-Object System.Text.UTF8Encoding $false }

# One widget per data dir. hook.ps1 checks this name to know whether the widget is running, also
# one started by an older version: never change how it is computed.
function Get-MutexName([string]$Dir) {
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hash = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir.ToLowerInvariant())) } finally { $sha.Dispose() }
    return 'Local\ClaudeCodeWidget-' + (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}

# Write to .tmp, then rename: readers never see a half-written file
function Write-JsonAtomic([string]$Path, $Object) {
    [IO.File]::WriteAllText("$Path.tmp", ($Object | ConvertTo-Json -Depth 10 -Compress), (Get-Utf8NoBom))
    [IO.File]::Move("$Path.tmp", $Path)
}

# 'pt' or 'en'. Empty = the Windows display language; anything that is not Portuguese is English.
function Resolve-Lang([string]$Requested) {
    $lang = if ($Requested) { $Requested } else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
    if ($lang -eq 'pt') { return 'pt' }
    return 'en'
}

# UI text for one language, from strings.json next to this file (read explicitly as UTF-8)
function Get-Strings([string]$Lang) {
    $json = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'strings.json'), (Get-Utf8NoBom))
    return ($json | ConvertFrom-Json).$Lang
}

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

# Requests waiting for an answer, oldest first. Deletes orphans: expired, or the hook that wrote
# them is gone (session interrupted). Skips requests already answered (res-<id>.json), waiting for
# the hook to pick the answer up. $Cache (file name -> request) avoids re-reading files.
function Get-PendingRequests([string]$Queue, [hashtable]$Cache) {
    $now = Get-NowMs
    $list = New-Object System.Collections.ArrayList
    $names = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter 'req-*.json' -File -ErrorAction SilentlyContinue)) {
        $names[$f.Name] = $true
        $r = $Cache[$f.Name]
        if (-not $r) {
            try { $r = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json } catch { continue }
            $Cache[$f.Name] = $r
        }
        $expired = ($now - [int64]$r.created) -gt (([int64]$r.timeout + 5) * 1000)
        $alive = $null -ne (Get-Process -Id ([int]$r.pid) -ErrorAction SilentlyContinue)
        if ($expired -or -not $alive) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        if (Test-Path -LiteralPath (Join-Path $Queue "res-$($r.id).json")) { continue }
        [void]$list.Add($r)
    }
    foreach ($k in @($Cache.Keys)) { if (-not $names.ContainsKey($k)) { $Cache.Remove($k) } }
    return $list | Sort-Object { [int64]$_.created }
}

# "Claude finished" notices, newest first, each with key (file name) and file (full path).
# Deletes notices older than $MaxAgeMs. $Cache (file name -> notice) avoids re-reading files.
function Get-DoneNotices([string]$Queue, [hashtable]$Cache, [int64]$MaxAgeMs) {
    $now = Get-NowMs
    $list = New-Object System.Collections.ArrayList
    $names = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $Queue -Filter 'done-*.json' -File -ErrorAction SilentlyContinue)) {
        $names[$f.Name] = $true
        $d = $Cache[$f.Name]
        if (-not $d) {
            try { $d = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json } catch { continue }
            $d | Add-Member -NotePropertyName key -NotePropertyValue $f.Name -Force
            $d | Add-Member -NotePropertyName file -NotePropertyValue $f.FullName -Force
            $Cache[$f.Name] = $d
        }
        if (($now - [int64]$d.created) -gt $MaxAgeMs) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            continue
        }
        [void]$list.Add($d)
    }
    foreach ($k in @($Cache.Keys)) { if (-not $names.ContainsKey($k)) { $Cache.Remove($k) } }
    return $list | Sort-Object -Property { [int64]$_.created } -Descending
}

# Appends "<date>T<time> <text>" to a log file (UTF-8). Past $MaxBytes the file first becomes
# <file>.old (replacing the previous one), so a log never grows past about twice $MaxBytes.
# Never throws: a log that cannot be written must not stop the hook or the widget.
function Write-LogLine([string]$Path, [string]$Text, [int64]$MaxBytes = 256KB) {
    try {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir) { [void][IO.Directory]::CreateDirectory($dir) }
        $file = [IO.FileInfo]::new($Path)
        if ($file.Exists -and $file.Length -gt $MaxBytes) {
            [IO.File]::Delete("$Path.old")
            [IO.File]::Move($Path, "$Path.old")
        }
        [IO.File]::AppendAllText($Path, ('{0:s} {1}' -f (Get-Date), $Text) + "`r`n", (Get-Utf8NoBom))
    } catch {}
}

# Does a window title name this project as a whole part of it? VS Code titles read
# "[<dot> ]file - folder[ (Workspace)][ [WSL: Ubuntu]] - Visual Studio Code", so "widget" matches the
# folder "widget" but not "claude-code-widget" nor a file "widget.ps1". Letter case is ignored.
# (The unsaved-file dot goes in as the character itself: its regex escape (backslash, u, 25CF) does not match in .NET here.)
function Test-TitleHasProject([string]$Title, [string]$Project) {
    if (-not $Title -or -not $Project) { return $false }
    $dot = [regex]::Escape([string][char]0x25CF)
    $pattern = '(?i)(^|\s-\s)(' + $dot + '\s*)?' + [regex]::Escape($Project) + '(\s[(\[][^)\]]*[)\]])*(\s-\s|$)'
    return [regex]::IsMatch($Title, $pattern)
}

# Work area (screen minus taskbar) of each monitor, in WPF units, read fresh on every call:
# @{ left; top; right; bottom; primary }. Used by widget.ps1. Pixels are converted with the main
# monitor's width in pixels against WPF's width for it, both read now, so the areas match WPF's
# coordinates whether or not this process is DPI aware. (System.Windows.Forms.Screen is not used:
# it keeps the main screen's bounds from its first use and can disagree with its own work areas.)
function Get-ScreenAreas {
    Add-Type -AssemblyName PresentationFramework
    $dips = [System.Windows.SystemParameters]::PrimaryScreenWidth
    if (-not ('ClaudeWidget.Monitors' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace ClaudeWidget {
    public static class Monitors {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        // One entry per monitor, in pixels: work area left, top, right, bottom; monitor width; 1 = main screen
        public static List<int[]> List() {
            var list = new List<int[]>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, hdc, r, d) => {
                var info = new MONITORINFO();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(m, ref info)) {
                    list.Add(new int[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom,
                        info.rcMonitor.Right - info.rcMonitor.Left, (info.dwFlags & 1) != 0 ? 1 : 0 });
                }
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
    $monitors = [ClaudeWidget.Monitors]::List()
    $mainWidth = 0
    foreach ($m in $monitors) { if ($m[5] -eq 1) { $mainWidth = $m[4] } }
    $scale = if ($mainWidth -gt 0 -and $dips -gt 0) { $mainWidth / $dips } else { 1.0 }
    foreach ($m in $monitors) {
        @{ left = $m[0] / $scale; top = $m[1] / $scale; right = $m[2] / $scale; bottom = $m[3] / $scale; primary = ($m[5] -eq 1) }
    }
}

# Text that changes whenever a monitor is added, removed, moved or resized, or the taskbar moves
function Get-ScreenKey($Areas) {
    return (@($Areas | Where-Object { $_ }) | ForEach-Object {
            '{0},{1},{2},{3},{4}' -f $_.left, $_.top, $_.right, $_.bottom, [bool]$_.primary }) -join ';'
}

# Where the widget's bottom-right corner goes: the saved spot (@{ right; bottom }, e.g. from
# state.json) while it is on one of the screens, else the main screen's bottom-right corner.
# Returns @{ right; bottom; saved }, or $null without any screen.
function Resolve-Anchor($Saved, $Areas) {
    $list = @($Areas | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($Saved -and $null -ne $Saved.right -and $null -ne $Saved.bottom) {
        $r = [double]$Saved.right
        $b = [double]$Saved.bottom
        foreach ($a in $list) {
            # At least a 120 x 60 corner of the widget on that screen
            if ($r -gt $a.left + 120 -and $r -le $a.right + 1 -and $b -gt $a.top + 60 -and $b -le $a.bottom + 1) {
                return @{ right = $r; bottom = $b; saved = $true }
            }
        }
    }
    $main = $list[0]
    foreach ($a in $list) { if ($a.primary) { $main = $a; break } }
    return @{ right = [double]$main.right; bottom = [double]$main.bottom; saved = $false }
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

# Sessions working right now, read from the busy\<session>.json files the hook keeps: those whose
# Claude process runs (or is unknown, pid 0), that started less than $MaxAgeMs ago and whose
# transcript (when known) was written in the last $QuietMs. Files of the others are removed.
# Returns { id; pid; since; cwd; transcript } objects.
function Get-BusySessions([string]$BusyDir, [int64]$MaxAgeMs, [int64]$QuietMs) {
    $now = Get-NowMs
    foreach ($f in @(Get-ChildItem -LiteralPath $BusyDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $alive = $false
        $b = $null
        try {
            $b = [IO.File]::ReadAllText($f.FullName, (Get-Utf8NoBom)) | ConvertFrom-Json
            $alive = (($now - [int64]$b.since) -lt $MaxAgeMs) -and
                ([int]$b.pid -eq 0 -or $null -ne (Get-Process -Id ([int]$b.pid) -ErrorAction SilentlyContinue))
            $transcript = [string]$b.transcript
            if ($alive -and $transcript -and (Test-Path -LiteralPath $transcript)) {
                # (not $quietMs: variable names are case-insensitive, it would replace the parameter)
                $silentMs = ([DateTime]::UtcNow - (Get-Item -LiteralPath $transcript).LastWriteTimeUtc).TotalMilliseconds
                if ($silentMs -gt $QuietMs) { $alive = $false }
            }
        } catch {}
        if ($alive) {
            [pscustomobject]@{ id = $f.BaseName; pid = [int]$b.pid; since = [int64]$b.since; cwd = [string]$b.cwd; transcript = [string]$b.transcript }
        }
        else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
    }
}

# "Do not disturb" is the file dnd.flag in the data folder: hook.ps1 reads it to send requests to
# VS Code, and the widget reads it to hide itself
function Test-Dnd([string]$Dir) { Test-Path -LiteralPath (Join-Path $Dir 'dnd.flag') }

function Set-Dnd([string]$Dir, [bool]$On) {
    try {
        $path = Join-Path $Dir 'dnd.flag'
        if ($On) {
            [void][IO.Directory]::CreateDirectory($Dir)
            [IO.File]::WriteAllText($path, '')
        }
        else { [IO.File]::Delete($path) }
    } catch {}
}

# "project . session title" for chips and the sessions list: the title is cut at 40 characters
# (without splitting an emoji); either part may be missing
function Format-SessionLine([string]$Cwd, [string]$Title) {
    $text = if ($Cwd) { Split-Path -Leaf $Cwd } else { '' }
    $title = if ($Title) { $Title.Trim() } else { '' }
    if ($title.Length -gt 40) {
        $cut = 39
        if ([char]::IsHighSurrogate($title[$cut - 1])) { $cut = 38 }
        $title = $title.Substring(0, $cut) + '...'
    }
    if ($title) { $text = if ($text) { $text + ' ' + [char]0x00B7 + ' ' + $title } else { $title } }
    return $text
}
