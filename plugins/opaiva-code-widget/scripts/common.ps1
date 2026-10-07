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
