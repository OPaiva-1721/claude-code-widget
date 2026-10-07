# Título da sessão, som de "tudo pronto" e duplo clique: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** versão 2.1.0: o chip do projeto mostra o título da sessão, o último aviso de uma rodada com várias sessões toca um som de "tudo pronto", e duplo clique no widget traz a janela da sessão.

**Architecture:** o hook lê o título no fim do transcript e o grava nos pedidos e avisos (`title`). Ele também mantém `busy\<sessão>.json` (quem está trabalhando) e `busy-round.json` (quem trabalhou na rodada), para marcar o aviso com `allDone`. O widget só lê esses campos e trata o duplo clique.

**Tech Stack:** Windows PowerShell 5.1, WPF, Pester ≥ 5.5.

**Spec:** `docs/superpowers/specs/2026-10-07-session-title-all-done-design.md`

## Global Constraints

- Todo `.ps1` só com ASCII (`·` entra como `[char]0x00B7`, `...` como três pontos ASCII).
- O hook nunca escreve no stdout além da decisão; as funções novas engolem as próprias falhas.
- Título: últimos 512 KB do transcript; `custom-title` vale mais que `ai-title`; cortado em 40 caracteres no chip (39 + `...`).
- "Tudo pronto": nenhuma outra sessão viva **e** rodada com 2 sessões ou mais. Viva = `pid` rodando (ou `pid` 0) **e** `since` com menos de 12 horas.
- Som: `%WINDIR%\Media\tada.wav`; sem ele, `SystemSounds.Exclamation`.
- Versão `2.1.0` no `plugin.json` e no topo do `CHANGELOG.md`.
- Branch: `feat/session-title-all-done`. Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Suíte: `powershell -NoProfile -File tools\test.ps1` (hoje 128 passando). Mande a saída para um arquivo e leia o fim.
- Não escreva `\u` seguido de dígitos hexadecimais em heredocs nem no Edit: a ferramenta converte no caractere. Prefira a ferramenta Write para trechos novos.

## Review Focus

1. **Transcript grande ou travado pelo Claude Code** (milhões de bytes, aberto para escrita): o hook não pode ficar lento nem falhar. Coberto na Task 1: leitura só do fim, `FileShare.ReadWrite`, e o teste de título além dos 512 KB.
2. **Duas sessões terminando quase juntas:** as duas podem achar que ainda existe outra trabalhando, e nenhuma toca "tudo pronto". É aceitável (só perde um som), mas nenhuma pode lançar erro. Coberto na Task 2 pela ordem dos testes de rodada; o caso concorrente não tem teste.
3. **Sessão que morreu sem `Stop`:** não pode impedir o "tudo pronto" para sempre. Coberto na Task 2: `pid` morto e `since` velho.
4. **Duplo clique em botão ou opção:** não pode trazer o VS Code nem ignorar o clique no botão. Sem teste automático (verificação à mão na Task 3); os controles marcam o clique como tratado.
5. **Pedido sem `transcript_path`** (versões antigas do Claude Code ou eventos sem transcript): o pedido segue sem título. Coberto na Task 1: caminho vazio dá título vazio.

---

### Task 1: Título da sessão no hook

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1` (função nova `Get-SessionTitle`; `title` no `Stop`, no `PreToolUse` e no `PermissionRequest`)
- Create: `tests/fixtures/titles.jsonl`
- Test: `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Produces: `Get-SessionTitle([string]$TranscriptPath, [string]$SessionId)` → `[string]` (vazio se não houver). Campo `title` nos `req-*.json` e `done-*.json`.

- [ ] **Step 1: Fixture**

Crie `tests/fixtures/titles.jsonl` (LF, UTF-8) com:

```
{"type":"ai-title","aiTitle":"First automatic title","sessionId":"s-1"}
{"type":"user","message":{"role":"user","content":"hi"}}
{"type":"custom-title","customTitle":"Named with rename","sessionId":"s-1"}
{"type":"ai-title","aiTitle":"Later automatic title","sessionId":"s-1"}
{"type":"custom-title","customTitle":"Other session","sessionId":"s-2"}
{"type":"ai-title","aiTitle":"Only automatic","sessionId":"s-3"}
{"type":"ai-title", broken line
```

- [ ] **Step 2: Testes de unidade**

No fim de `tests/hook.Tests.ps1`:

```powershell
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
```

- [ ] **Step 3: Teste e2e**

Em `tests/hook.e2e.Tests.ps1`, no `Context 'finished notices'`, depois do teste existente:

```powershell
        It 'Stop and PermissionRequest carry the session title' {
            $transcript = Join-Path $box.Data 'transcript.jsonl'
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok'; transcript_path = $transcript }
            [IO.File]::WriteAllText($transcript, ('{"type":"ai-title","aiTitle":"Fix the login","sessionId":"' + $stop.session_id + '"}' + "`n"))
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).title | Should -BeExactly 'Fix the login'

            $perm = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' }; transcript_path = $transcript }
            $perm.session_id = $stop.session_id
            $run = Start-Hook $box $perm
            $req = Wait-HookRequest $box
            $req.title | Should -BeExactly 'Fix the login'
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
```

- [ ] **Step 4: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a1.txt; Get-Content $env:TEMP\a1.txt -Tail 15`
Esperado: 5 testes de `Get-SessionTitle` FAIL (`is not recognized`) e o e2e FAIL (`title` vazio). Total: 128 passed, 6 failed.

- [ ] **Step 5: Implementar**

Em `hook.ps1`, logo antes do comentário `# Text of Claude's last reply`, acrescente (com a ferramenta Write num arquivo temporário e concatenação, ou Edit):

```powershell
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

```

Em `Invoke-Hook`, logo depois de `$cwd = [string]$evt.cwd`, acrescente:

```powershell
    $transcript = [string]$evt.transcript_path
```

No `Stop`, no `[ordered]@{` do aviso, depois de `message = $msg`, acrescente:

```powershell
            title   = Get-SessionTitle $transcript $sid
```

No `PreToolUse`, no `@{` de `New-Request 'question'`, depois de `questions   = $questions`, acrescente:

```powershell
            title       = Get-SessionTitle $transcript $sid
```

No `PermissionRequest`, no `@{` de `New-Request 'permission'`, depois de `detail      = $detail`, acrescente:

```powershell
            title       = Get-SessionTitle $transcript $sid
```

- [ ] **Step 6: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a1.txt; Get-Content $env:TEMP\a1.txt -Tail 15`
Esperado: 134 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/hook.ps1 tests/fixtures/titles.jsonl tests/hook.Tests.ps1 tests/hook.e2e.Tests.ps1
git commit -m "feat: requests and notices carry the session title

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Sessões trabalhando e "tudo pronto" no hook

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1` (`$Busy`, `$RoundPath`, `$BusyMaxAgeMs`; `Get-ClaudePid`, `Get-WorkingSessions`, `Set-SessionBusy`, `Complete-SessionBusy`; `UserPromptSubmit` e `Stop`)
- Test: `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Consumes: `Get-ProcessTree` (já existe: `@{ map; ancestors }`), `Write-JsonAtomic`, `Get-NowMs`.
- Produces: `Get-ClaudePid` → `[int]`; `Get-WorkingSessions` → ids; `Set-SessionBusy([string]$Sid)`; `Complete-SessionBusy([string]$Sid)` → `[bool]`. Campo `allDone` (`[bool]`) no `done-*.json`.

- [ ] **Step 1: Testes de unidade**

No fim de `tests/hook.Tests.ps1`:

```powershell
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
}
```

(`Set-FakeBusy` troca o `pid` gravado por um conhecido: o `Get-ClaudePid` do teste pode devolver o Claude Code que está rodando os testes, ou 0.)

- [ ] **Step 2: Testes e2e**

Em `tests/hook.e2e.Tests.ps1`, no `Context 'finished notices'`:

```powershell
        It 'UserPromptSubmit marks the session as working and Stop clears it' {
            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'go' }
            [void](Complete-Hook (Start-Hook $box $prompt))
            $busyFile = Join-Path $box.Data "busy\$($prompt.session_id).json"
            $busyFile | Should -Exist
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            $stop.session_id = $prompt.session_id
            [void](Complete-Hook (Start-Hook $box $stop))
            $busyFile | Should -Not -Exist
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).allDone | Should -BeFalse
        }
        It 'Stop marks "all done" when it ends a round of several sessions' {
            $busy = Join-Path $box.Data 'busy'
            New-Item -ItemType Directory -Force -Path $busy | Out-Null
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            Write-JsonAtomic (Join-Path $box.Data 'busy-round.json') @{ sessions = @('other', $stop.session_id) }
            Write-JsonAtomic (Join-Path $busy "$($stop.session_id).json") @{ pid = $PID; since = Get-NowMs }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).allDone | Should -BeTrue
        }
        It 'Stop does not mark "all done" while another session is working' {
            $busy = Join-Path $box.Data 'busy'
            New-Item -ItemType Directory -Force -Path $busy | Out-Null
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            Write-JsonAtomic (Join-Path $box.Data 'busy-round.json') @{ sessions = @('other', $stop.session_id) }
            Write-JsonAtomic (Join-Path $busy 'other.json') @{ pid = $PID; since = Get-NowMs }
            [void](Complete-Hook (Start-Hook $box $stop))
            $notice = (Get-QueueFiles $box "done-$($stop.session_id)-*.json")[0]
            ([IO.File]::ReadAllText($notice.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json).allDone | Should -BeFalse
            Join-Path $busy 'other.json' | Should -Exist
        }
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a2.txt; Get-Content $env:TEMP\a2.txt -Tail 15`
Esperado: os 7 testes de unidade FAIL (`$Busy` vazio / `is not recognized`) e os 3 e2e FAIL (sem `busy\` / sem `allDone`). Total: 134 passed, 10 failed.

- [ ] **Step 4: Implementar**

Em `hook.ps1`, logo depois de `$Sessions = Join-Path $Data 'sessions'`:

```powershell
# Sessions working right now (busy\<session>.json) and the sessions of the current round
$Busy = Join-Path $Data 'busy'
$RoundPath = Join-Path $Data 'busy-round.json'
$BusyMaxAgeMs = 12 * 3600 * 1000
```

Logo antes do comentário `# The session's remembered window, if it still exists`:

```powershell
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

```

No `UserPromptSubmit`, depois de `Remove-Done $sid`:

```powershell
        Set-SessionBusy $sid
```

No `Stop`, troque:

```powershell
        Remove-Done $sid
        $sessionWindow = Get-SessionWindow $sid
```

por:

```powershell
        Remove-Done $sid
        # Before deciding on the notice: the session stops counting as working even without one
        $allDone = Complete-SessionBusy $sid
        $sessionWindow = Get-SessionWindow $sid
```

E no `[ordered]@{` do aviso, depois de `title   = ...`:

```powershell
            allDone = [bool]$allDone
```

- [ ] **Step 5: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a2.txt; Get-Content $env:TEMP\a2.txt -Tail 15`
Esperado: 144 passed, 0 failed.

- [ ] **Step 6: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/hook.ps1 tests/hook.Tests.ps1 tests/hook.e2e.Tests.ps1
git commit -m "feat: mark the notice that ends a round of several sessions as all done

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Widget: título no chip, som de "tudo pronto" e duplo clique

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Modify: `tools/samples.json`, `docs/images/en/*.png`, `docs/images/pt/*.png` (gerados)

**Interfaces:**
- Consumes: campos `title` e `allDone` (Tasks 1 e 2); `Find-VsCodeWindow`, `Close-DoneNotice`, `[ClaudeWidget.WinFocus]::FocusHandle` (já existem).

- [ ] **Step 1: Amostras com título**

Em `tools/samples.json`, acrescente `"title"` aos três exemplos de cada idioma:
- en: permission `"title": "Login form validation"`, question `"title": "New billing service"`, done `"title": "Login form validation"`;
- pt: permission `"title": "Validação do login"`, question `"title": "Serviço de cobrança"`, done `"title": "Validação do login"`.

- [ ] **Step 2: Chip com o título**

Troque a função inteira:

```powershell
    function Set-ProjectChip($chip, $textBlock, [string]$cwd) {
        if ($cwd) {
            $textBlock.Text = Split-Path -Leaf $cwd
            $chip.Visibility = 'Visible'
        }
        else { $chip.Visibility = 'Collapsed' }
    }
```

por:

```powershell
    # "project . session title" (the title cut at 40 characters); either part may be missing
    function Set-ProjectChip($chip, $textBlock, $item) {
        $text = if ($item.cwd) { Split-Path -Leaf ([string]$item.cwd) } else { '' }
        $title = ([string]$item.title).Trim()
        if ($title.Length -gt 40) { $title = $title.Substring(0, 39) + '...' }
        if ($title) { $text = if ($text) { $text + ' ' + [char]0x00B7 + ' ' + $title } else { $title } }
        $textBlock.Text = $text
        $chip.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    }
```

E troque as três chamadas: `Set-ProjectChip $ui.ProjectChip $ui.Project ([string]$r.cwd)` → `Set-ProjectChip $ui.ProjectChip $ui.Project $r`; `Set-ProjectChip $ui.QProjectChip $ui.QProject ([string]$r.cwd)` → `Set-ProjectChip $ui.QProjectChip $ui.QProject $r`; `Set-ProjectChip $ui.DoneProjectChip $ui.DoneProject ([string]$d.cwd)` → `Set-ProjectChip $ui.DoneProjectChip $ui.DoneProject $d`.

- [ ] **Step 3: Som de "tudo pronto"**

Logo depois do bloco que carrega `$script:doneSound` (termina em `catch { $script:doneSound = $null }` e `}`), acrescente:

```powershell
    # "All done" sound: the last session of a round with several sessions finished
    $script:allDoneSound = $null
    $tada = Join-Path $env:WINDIR 'Media\tada.wav'
    if (Test-Path -LiteralPath $tada) {
        try { $script:allDoneSound = New-Object System.Media.SoundPlayer $tada; $script:allDoneSound.Load() } catch { $script:allDoneSound = $null }
    }
```

Em `Show-Done`, troque:

```powershell
            Invoke-Attention $d.key {
                if ($script:doneSound) { $script:doneSound.Play() } else { [System.Media.SystemSounds]::Beep.Play() }
            }
```

por:

```powershell
            $allDone = [bool]$d.allDone
            Invoke-Attention $d.key {
                if ($allDone) {
                    if ($script:allDoneSound) { $script:allDoneSound.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
                }
                elseif ($script:doneSound) { $script:doneSound.Play() }
                else { [System.Media.SystemSounds]::Beep.Play() }
            }
```

- [ ] **Step 4: Duplo clique**

Logo antes de `function Close-DoneNotice([switch]$GoToSession) {` (depois de `Find-VsCodeWindow`), acrescente:

```powershell
    # Brings the window remembered for the session you typed in last, if it still exists
    function Show-LatestSessionWindow {
        $dir = Join-Path $Data 'sessions'
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            try {
                $w = [IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json
                if ([ClaudeWidget.WinFocus]::FocusHandle([int64]$w.hwnd)) { return $true }
            } catch {}
        }
        return $false
    }

    # Double click outside buttons: the finished notice's session; otherwise the latest session's
    # window, else the VS Code window of the project on screen (or any VS Code window)
    function Invoke-DoubleClick {
        if (-not $script:canFocus) { return }
        if ($script:currentDone) { Close-DoneNotice -GoToSession; return }
        if (Show-LatestSessionWindow) { return }
        $project = if ($script:current -and $script:current.cwd) { Split-Path -Leaf ([string]$script:current.cwd) } else { '' }
        $h = Find-VsCodeWindow $project
        if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
    }

```

No tratador do arrasto, troque o começo:

```powershell
    $win.Add_MouseLeftButtonDown({
        $left = $win.Left
```

por:

```powershell
    $win.Add_MouseLeftButtonDown({
        param($src, $e)
        # Buttons, options and the text box handle their own clicks and never get here
        if ($e.ClickCount -eq 2) { Invoke-DoubleClick; return }
        $left = $win.Left
```

- [ ] **Step 5: Gerar as imagens e rodar a suíte**

Run: `powershell -NoProfile -File tools\render-screenshots.ps1` e depois `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a3.txt; Get-Content $env:TEMP\a3.txt -Tail 15`
Esperado: as 8 imagens de `docs/images/{en,pt}` regeneradas, com o título no chip (abra `docs/images/pt/permission.png` e confira); 144 passed, 0 failed (os testes Desktop pegam erro de script no widget).

- [ ] **Step 6: Verificação à mão (widget de teste, sem tocar no widget instalado)**

Com uma pasta de dados temporária (`-DataDir`), grave em `sessions\x.json` o `hwnd` da janela do VS Code (`{"hwnd":<hwnd>,"kind":"vscode","process":"code.exe"}`), abra o widget com `-DataDir` e, com outra janela na frente, dê duplo clique na pílula: a janela do VS Code tem que vir para a frente. Depois, grave na `queue` um `done-x-<ms>.json` com `allDone: true` e confira que toca o "tada". Feche o widget com Stop-Process. Se não der para clicar (sessão sem usuário), anote no ledger e deixe para a verificação pós-merge.

- [ ] **Step 7: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 tools/samples.json docs/images
git commit -m "feat: session title on the cards, all-done sound and double click to go back

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Release 2.1.0

**Files:**
- Modify: `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, `README.md`, `README.pt-BR.md`

- [ ] **Step 1: CHANGELOG**

Logo depois de `# Changelog` e da linha em branco:

```markdown
## 2.1.0 (<data do dia>)

- **Session title on the cards.** Next to the project, the cards show the session's title: the name you gave it with `/rename`, or the one Claude Code picked. Two sessions in the same project are easy to tell apart.
- **"All done" sound.** When several sessions were working and the last one finishes, its notice plays a different sound (Windows' "tada").
- **Double-click to go back.** Double-click the widget (outside its buttons) to bring back the session's window: the finished session on a "finished" notice, otherwise the session you typed in last.

```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a4.txt; Get-Content $env:TEMP\a4.txt -Tail 15`
Esperado: `plugin.json version matches the latest CHANGELOG entry` FAIL. Total: 143 passed, 1 failed.

- [ ] **Step 3: Versão e READMEs**

`plugin.json`: `"version": "2.0.1"` → `"version": "2.1.0"`.

`README.md`, seção "How to use it", lista depois da tabela: acrescente depois do item **Drag**:

```markdown
- **Double-click** the widget (outside its buttons) to bring back the session's window: on a "finished" notice, that session; otherwise, the session you typed in last.
```

E depois do item `With several requests or sessions, ...`:

```markdown
- The project chip also shows the session's title (the name from `/rename`, or Claude Code's automatic one). When several sessions were working and the last one finishes, its notice plays a different sound.
```

Em "How it works", no item do `hook.ps1`, depois de `On SessionStart it only makes sure the widget is running.`, acrescente: ` It also keeps track of which sessions are working (`busy\`), to tell when the last one of several finishes.`

`README.pt-BR.md`, mesmos lugares:

```markdown
- **Duplo clique** no widget (fora dos botões) traz a janela da sessão: no aviso de "terminou", a daquela sessão; nos outros casos, a da última sessão em que você digitou.
```

```markdown
- O chip do projeto também mostra o título da sessão (o nome dado com `/rename`, ou o automático do Claude Code). Quando várias sessões estavam trabalhando e a última termina, o aviso toca um som diferente.
```

E em "Como funciona", depois de `No SessionStart ele só garante que o widget está aberto.`: ` Ele também acompanha quais sessões estão trabalhando (`busy\`), para saber quando a última de várias termina.`

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\a4.txt; Get-Content $env:TEMP\a4.txt -Tail 15`
Esperado: 144 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json README.md README.pt-BR.md
git commit -m "docs: release 2.1.0

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
