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
