# Visão das sessões, "não perturbe" e bandeja: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** versão 2.2.0: modo "não perturbe" (pedidos vão para o VS Code, widget escondido, avisos guardados), ícone na bandeja que o controla, e uma lista das sessões que a pílula parada abre com um clique.

**Architecture:** o estado compartilhado vai para o `common.ps1` (`Get-BusySessions`, `Get-SessionTitle`, `Test-Dnd`, `Set-Dnd`), para o hook e o widget usarem as mesmas regras. O modo é o arquivo `dnd.flag` na pasta de dados: o hook consulta o arquivo, o widget o relê a cada tick e mostra ou esconde a janela. A bandeja é um `NotifyIcon` dentro do processo do widget.

**Tech Stack:** Windows PowerShell 5.1, WPF + `System.Windows.Forms.NotifyIcon`, Pester ≥ 5.5.

**Spec:** `docs/superpowers/specs/2026-10-08-sessions-dnd-tray-design.md`

## Global Constraints

- Todo `.ps1` só com ASCII; texto de interface só em `strings.json` (UTF-8). `·` no código vira `[char]0x00B7`.
- Não escreva barra invertida seguida de letra/dígito (`\t`, `\u25CF`) em strings pelas ferramentas de escrita (heredoc, python, Edit): viram TAB ou o caractere. Use a ferramenta Write para trechos novos e confira com `grep -c $'\t'`.
- O hook nunca escreve no stdout além da decisão; falhas das funções novas são engolidas.
- Modo: arquivo `dnd.flag` em `$Data`. Ligado persiste até desligar.
- Ícones: círculo `#D97757` (ativo), `#8A8A93` (não perturbe), 32×32, desenhados por código.
- Lista: no máximo 8 linhas (`+N` na última), título relido no máximo a cada 15 s e só com a lista aberta; Vivo = regras do 4a (pid, 12 h, transcript parado 15 min).
- `System.Windows.Forms.Screen` continua proibido (ver bloco 3); o `NotifyIcon` é permitido.
- Versão `2.2.0` no `plugin.json` e no topo do `CHANGELOG.md`.
- Branch: `feat/sessions-dnd-tray`. Commits terminam com `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Suíte: `powershell -NoProfile -File tools\test.ps1` (hoje 147 passando). Mande a saída para um arquivo e leia o fim.

## Review Focus

1. **Widget escondido sem ninguém saber:** com o modo ligado e o widget escondido, o usuário tem que conseguir desligar. Coberto na Task 2: o ícone cinza + clique esquerdo; e o `SessionStart` e o `Stop` continuam iniciando o widget no modo (o hook não os altera; o teste e2e do `Stop` na Task 1 protege isso).
2. **Pedido na tela quando o modo liga:** não pode ficar preso esperando 5 minutos. Coberto na Task 2: o widget devolve os pedidos pendentes ao VS Code ao ligar o modo (verificação à mão; a lógica é a mesma do "Fechar widget").
3. **Arquivo `dnd.flag` apagado ou criado de fora:** vale em ~0,4 s nos dois sentidos. Coberto na Task 2 (teste Desktop com o widget real).
4. **Clique na pílula vs. arrasto vs. duplo clique:** o clique só alterna a lista se a janela não se mexeu; o duplo clique não pode alternar. Sem teste automático (precisa de mouse); verificação à mão na Task 3.
5. **Sessão sem título ou com transcript ilegível:** a linha mostra só o projeto, sem erro. Coberto na Task 3 (`Format-SessionLine` com título vazio).

---

### Task 1: Estado compartilhado e "não perturbe" no hook

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (funções novas no fim; `Get-SessionTitle` movida do `hook.ps1`)
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1` (remover `Get-SessionTitle`; `Get-WorkingSessions` vira invólucro; `Set-SessionBusy` grava `cwd`; gate do modo)
- Test: `tests/common.Tests.ps1`, `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Produces: `Get-BusySessions([string]$BusyDir, [int64]$MaxAgeMs, [int64]$QuietMs)` → objetos `{ id; pid; since; cwd; transcript }`; `Get-SessionTitle([string]$TranscriptPath, [string]$SessionId)` (igual à de hoje); `Test-Dnd([string]$Dir)` → `[bool]`; `Set-Dnd([string]$Dir, [bool]$On)`; arquivo `$Data\dnd.flag`; campo `cwd` em `busy\<sessão>.json`.

- [ ] **Step 1: Testes do `common.ps1`**

No fim de `tests/common.Tests.ps1` (use a ferramenta Write num arquivo temporário e anexe, para não passar barras pelo shell):

```powershell

Describe 'Get-BusySessions' {
    BeforeEach {
        $busy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $busy | Out-Null
        function Add-Busy([string]$Id, [int]$ProcessId, [int64]$AgeMs = 0, [string]$Cwd = 'C:\dev\app', [string]$Transcript = '') {
            Write-JsonAtomic (Join-Path $busy "$Id.json") ([ordered]@{ pid = $ProcessId; since = (Get-NowMs) - $AgeMs; cwd = $Cwd; transcript = $Transcript })
        }
        $maxAge = 12 * 3600 * 1000
        $quiet = 15 * 60 * 1000
    }
    It 'lists live sessions with id, cwd and transcript' {
        Add-Busy 's1' $PID 1000 'C:\dev\one' 'C:\t\one.jsonl'
        $list = @(Get-BusySessions $busy $maxAge $quiet)
        $list.Count | Should -Be 1
        $list[0].id | Should -BeExactly 's1'
        $list[0].cwd | Should -BeExactly 'C:\dev\one'
        $list[0].transcript | Should -BeExactly 'C:\t\one.jsonl'
        $list[0].since | Should -BeGreaterThan 0
    }
    It 'removes sessions whose process is gone' {
        Add-Busy 'dead' 2147483640
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
        Join-Path $busy 'dead.json' | Should -Not -Exist
    }
    It 'removes sessions older than the maximum age' {
        Add-Busy 'old' 0 ($maxAge + 60000)
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'removes sessions whose transcript has been quiet too long' {
        $t = Join-Path $TestDrive 'quiet.jsonl'
        [IO.File]::WriteAllText($t, '{}')
        (Get-Item -LiteralPath $t).LastWriteTime = (Get-Date).AddMinutes(-20)
        Add-Busy 'quiet' $PID 0 'C:\dev\app' $t
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 0
    }
    It 'counts a session with an unknown process (pid 0)' {
        Add-Busy 'unknown' 0
        @(Get-BusySessions $busy $maxAge $quiet).Count | Should -Be 1
    }
    It 'returns nothing when the folder does not exist' {
        @(Get-BusySessions (Join-Path $TestDrive 'nope') $maxAge $quiet).Count | Should -Be 0
    }
}

Describe 'Test-Dnd and Set-Dnd' {
    It 'is off by default, on after Set-Dnd and off again' {
        $dir = Join-Path $TestDrive 'dnd'
        Test-Dnd $dir | Should -BeFalse
        Set-Dnd $dir $true
        Test-Dnd $dir | Should -BeTrue
        Join-Path $dir 'dnd.flag' | Should -Exist
        Set-Dnd $dir $false
        Test-Dnd $dir | Should -BeFalse
    }
    It 'turning it off twice is harmless' {
        $dir = Join-Path $TestDrive 'dnd2'
        { Set-Dnd $dir $false; Set-Dnd $dir $false } | Should -Not -Throw
    }
}
```

- [ ] **Step 2: Testes do hook**

Em `tests/hook.Tests.ps1`, o `Describe 'busy sessions and all done'` já cobre o `Complete-SessionBusy`; acrescente dentro dele, depois do último `It`:

```powershell
    It 'records the project of the session in the busy file' {
        Set-SessionBusy 'a' '' 'C:\dev\app'
        ([IO.File]::ReadAllText((Join-Path $Busy 'a.json')) | ConvertFrom-Json).cwd | Should -BeExactly 'C:\dev\app'
    }
```

Em `tests/hook.e2e.Tests.ps1`, no `Describe`, depois do `Context 'finished notices'` (antes do comentário `# After a plugin update`), acrescente:

```powershell
    Context 'do not disturb' {
        BeforeEach { Set-Dnd $box.Data $true }
        It 'sends permission requests straight to VS Code' {
            $evt = New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
        }
        It 'sends questions straight to VS Code' {
            $evt = New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = @(@{ question = 'Q?'; header = 'Q'; multiSelect = $false; options = @(@{ label = 'A'; description = '' }) }) } }
            $r = Complete-Hook (Start-Hook $box $evt)
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*.json').Count | Should -Be 0
        }
        It 'still writes the finished notice' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'ok' }
            [void](Complete-Hook (Start-Hook $box $stop))
            (Get-QueueFiles $box "done-$($stop.session_id)-*.json").Count | Should -Be 1
        }
    }
```

(O `Set-Dnd` vem do `common.ps1`, já carregado no topo do arquivo de testes e2e.)

- [ ] **Step 3: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b1.txt; Get-Content $env:TEMP\b1.txt -Tail 15`
Esperado: os 6 de `Get-BusySessions` e os 2 de `Test-Dnd` FAIL (`is not recognized`); o `cwd` do `Set-SessionBusy` FAIL (parâmetro a mais); e2e: `sends permission requests` e `sends questions` FAIL (o hook cria `req-*.json` e espera; o teste expira em 60 s: é lento, ok) e `still writes the finished notice` PASS (comportamento atual, protege o futuro). Total: 147 passed, 10 failed.

- [ ] **Step 4: Implementar em `common.ps1`**

Escreva o trecho abaixo com a ferramenta Write num arquivo temporário e anexe ao fim de `common.ps1` (CRLF). `Get-SessionTitle` é cortada do `hook.ps1` e colada aqui sem mudança, antes das funções novas:

```powershell

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
                $quietMs = ([DateTime]::UtcNow - (Get-Item -LiteralPath $transcript).LastWriteTimeUtc).TotalMilliseconds
                if ($quietMs -gt $QuietMs) { $alive = $false }
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
```

- [ ] **Step 5: Ajustar o `hook.ps1`**

1. Apague a função `Get-SessionTitle` inteira (o comentário `# The session's title as Claude Code shows it...` até o `}` dela); ela agora vem do `common.ps1` (cole-a lá, no ponto indicado no Step 4, exatamente como estava).
2. Troque o corpo de `Get-WorkingSessions` (e seu comentário) por:

```powershell
# Ids of the sessions still working (see Get-BusySessions)
function Get-WorkingSessions {
    foreach ($b in @(Get-BusySessions $Busy $BusyMaxAgeMs $BusyQuietMs)) { $b.id }
}
```

3. `Set-SessionBusy`: assinatura `function Set-SessionBusy([string]$Sid, [string]$Transcript = '', [string]$Cwd = '') {` e a gravação:

```powershell
        Write-JsonAtomic $file ([ordered]@{ pid = Get-ClaudePid; since = Get-NowMs; transcript = $Transcript; cwd = $Cwd })
```

   A chamada no `UserPromptSubmit` vira `Set-SessionBusy $sid $transcript $cwd`.
4. Gate do modo. No `PreToolUse`, depois de `if ($questions.Count -eq 0) { return $null }`:

```powershell
        if (Test-Dnd $Data) { Write-HookLog "$logTag do not disturb: question goes to VS Code"; return $null }
```

   No `PermissionRequest`, depois de `if ($tool -in @('AskUserQuestion', 'ExitPlanMode')) { return $null }`:

```powershell
        if (Test-Dnd $Data) { Write-HookLog "$logTag $tool do not disturb: goes to VS Code"; return $null }
```

- [ ] **Step 6: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b1.txt; Get-Content $env:TEMP\b1.txt -Tail 15`
Esperado: 157 passed, 0 failed (os testes antigos de `Get-SessionTitle` e de sessões trabalhando continuam passando contra as funções movidas).

- [ ] **Step 7: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 plugins/opaiva-code-widget/scripts/hook.ps1 tests/common.Tests.ps1 tests/hook.Tests.ps1 tests/hook.e2e.Tests.ps1
git commit -m "feat: do not disturb in the hook; busy sessions and titles move to common.ps1

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Bandeja e "não perturbe" no widget

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Modify: `plugins/opaiva-code-widget/scripts/strings.json`
- Test: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Test-Dnd`, `Set-Dnd` (Task 1), `Get-Pending`, `$S.closeWidget`.
- Produces: funções do widget `New-DotIcon`, `Sync-Dnd`, `Close-Widget`; chaves de texto `trayTip`, `trayTipDnd`, `trayDnd`.

- [ ] **Step 1: Teste Desktop**

No fim de `tests/widget.Tests.ps1`:

```powershell
Describe 'widget.ps1 do not disturb' -Tag 'Desktop' {
    It 'hides its window while dnd.flag exists and shows it again when removed' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        Set-Dnd $data $true
        function Get-VisibleCount($ProcessId) { @([CcwTest.Windows]::Rects($ProcessId)).Count }
        function Wait-Until([scriptblock]$Condition, [int]$Seconds = 15) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            (Wait-Until { Test-Path -LiteralPath (Join-Path $data 'widget.json') }) | Should -BeTrue
            Start-Sleep -Seconds 3
            Get-VisibleCount $proc.Id | Should -Be 0
            Set-Dnd $data $false
            (Wait-Until { (Get-VisibleCount $proc.Id) -gt 0 }) | Should -BeTrue
            Set-Dnd $data $true
            (Wait-Until { (Get-VisibleCount $proc.Id) -eq 0 }) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b2.txt; Get-Content $env:TEMP\b2.txt -Tail 15`
Esperado: o teste novo FAIL (a janela fica visível: o primeiro `Get-VisibleCount ... Should -Be 0` falha). Total: 157 passed, 1 failed.

- [ ] **Step 3: Strings**

Em `strings.json`, `pt`, depois de `"closeWidget": "Fechar widget",`:

```json
    "trayTip": "Claude Code · widget ativo",
    "trayTipDnd": "Claude Code · não perturbe",
    "trayDnd": "Não perturbe",
```

e em `en`, depois de `"closeWidget": "Close widget",`:

```json
    "trayTip": "Claude Code · widget on",
    "trayTipDnd": "Claude Code · do not disturb",
    "trayDnd": "Do not disturb",
```

(O arquivo é UTF-8; edite com a ferramenta Edit. O teste `pt and en define the same keys` protege a simetria.)

- [ ] **Step 4: Implementar no `widget.ps1`**

1. Na linha `Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase`, acrescente `, System.Windows.Forms, System.Drawing`.
2. No C# de `WinFocus`, depois de `[DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);`, acrescente `[DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);` e, antes de `public static IntPtr Foreground()`, acrescente `public static void DestroyIconHandle(IntPtr h) { DestroyIcon(h); }`.
3. Troque o bloco do menu de botão direito (de `# Right-click > Close: hands pending requests back to VS Code and exits` até `$ui.Card.ContextMenu = $menu`) por:

```powershell
    # Hands pending requests back to VS Code and exits (right-click > Close, and the tray menu)
    function Close-Widget {
        foreach ($r in @(Get-Pending)) {
            try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
        }
        $win.Close()
    }
    $menu = New-Object System.Windows.Controls.ContextMenu
    $closeItem = New-Object System.Windows.Controls.MenuItem
    $closeItem.Header = $S.closeWidget
    $closeItem.Add_Click({ Close-Widget })
    [void]$menu.Items.Add($closeItem)
    $ui.Card.ContextMenu = $menu

    # --- Tray icon and "do not disturb" ---
    # The mode is the file dnd.flag: hook.ps1 sends requests to VS Code while it exists, and here the
    # window is hidden. Re-read on every tick, so removing the file by hand works too.
    function New-DotIcon([string]$hex) {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
        $g.FillEllipse($brush, 4, 4, 24, 24)
        $g.Dispose()
        $brush.Dispose()
        $h = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
        [ClaudeWidget.WinFocus]::DestroyIconHandle($h)
        $bmp.Dispose()
        return $icon
    }
    $script:dnd = $false
    if (-not $RenderMode) {
        $iconOn = New-DotIcon '#D97757'
        $iconOff = New-DotIcon '#8A8A93'
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $dndItem = $trayMenu.Items.Add($S.trayDnd)
        $trayClose = $trayMenu.Items.Add($S.closeWidget)
        $tray.ContextMenuStrip = $trayMenu
        $tray.Icon = $iconOn
        $tray.Text = $S.trayTip
        function Sync-Dnd {
            $on = Test-Dnd $Data
            if ($on -eq $script:dnd) { return }
            $script:dnd = $on
            $tray.Icon = if ($on) { $iconOff } else { $iconOn }
            $tray.Text = if ($on) { $S.trayTipDnd } else { $S.trayTip }
            $dndItem.Checked = $on
            if ($on) {
                # Whatever is on screen goes back to VS Code
                foreach ($r in @(Get-Pending)) {
                    try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
                }
                $script:current = $null
                $win.Hide()
            }
            else { $win.Show() }
        }
        $toggleDnd = { Set-Dnd $Data (-not (Test-Dnd $Data)); Sync-Dnd }
        $tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $toggleDnd } })
        $dndItem.Add_Click({ & $toggleDnd })
        $trayClose.Add_Click({ Close-Widget })
        $tray.Visible = $true
        $win.Add_Loaded({ Sync-Dnd })
    }
```

   (`Sync-Dnd` roda também em `Add_Loaded`: se o arquivo já existe ao abrir, a janela é escondida logo depois de aparecer.)
4. `Update-View`: logo no início, acrescente `if ($script:dnd) { return }`.
5. O timer: no `Add_Tick`, depois de `try { Update-View } catch { Write-Log $_ }`, acrescente `try { Sync-Dnd } catch { Write-Log $_ }` (antes de `Update-View`: troque a ordem para `Sync-Dnd` primeiro). `Sync-Dnd` só existe fora do `RenderMode`, e o timer também.
6. `$win.Add_Closed({ $timer.Stop() })` vira:

```powershell
    $win.Add_Closed({
        $timer.Stop()
        $tray.Visible = $false
        $tray.Dispose()
    })
```

   e no `finally` final, antes de liberar o mutex, acrescente `if ($tray) { try { $tray.Visible = $false; $tray.Dispose() } catch {} }`.

- [ ] **Step 5: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b2.txt; Get-Content $env:TEMP\b2.txt -Tail 15`
Esperado: 158 passed, 0 failed (os testes Desktop antigos continuam passando: render, fila, posição).

- [ ] **Step 6: Verificação à mão**

Com uma pasta de dados temporária (`-DataDir`), abra o widget e confira na bandeja: ícone laranja; clique esquerdo → ícone cinza e a janela some; menu do botão direito mostra **Não perturbe** (marcado) e **Fechar widget**; clique de novo → volta. Feche pelo menu e confirme que o ícone sai da bandeja (sem ícone fantasma). Se não for possível (sem tela), anote no ledger e deixe para a verificação pós-merge.

- [ ] **Step 7: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 plugins/opaiva-code-widget/scripts/strings.json tests/widget.Tests.ps1
git commit -m "feat: tray icon and do not disturb mode in the widget

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Lista de sessões na pílula parada

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (função pura `Format-SessionLine`)
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1` (XAML da pílula, lista, clique, timer, amostra)
- Modify: `plugins/opaiva-code-widget/scripts/strings.json`, `tools/samples.json`, `tools/render-screenshots.ps1`
- Test: `tests/common.Tests.ps1`, `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Get-BusySessions`, `Get-SessionTitle` (Task 1), `Get-Pending`, `New-TextBlock`, `Get-Brush`.
- Produces: `Format-SessionLine([string]$Cwd, [string]$Title)` → texto `projeto · título` (título cortado em 40; sem título, só o projeto; sem projeto, só o título; sem nenhum, vazio); no widget: `Get-SessionRows`, `Set-SessionRows($rows)`, `Toggle-Sessions`.

- [ ] **Step 1: Teste de `Format-SessionLine`**

No fim de `tests/common.Tests.ps1`:

```powershell
Describe 'Format-SessionLine' {
    BeforeAll { $dot = [string][char]0x00B7 }
    It 'joins project and title' {
        Format-SessionLine 'C:\dev\my-app' 'Fix the login' | Should -BeExactly "my-app $dot Fix the login"
    }
    It 'shows only the project without a title' {
        Format-SessionLine 'C:\dev\my-app' '' | Should -BeExactly 'my-app'
        Format-SessionLine 'C:\dev\my-app' $null | Should -BeExactly 'my-app'
    }
    It 'shows only the title without a project' {
        Format-SessionLine '' 'Fix the login' | Should -BeExactly 'Fix the login'
    }
    It 'is empty without both' {
        Format-SessionLine '' '' | Should -BeExactly ''
    }
    It 'cuts a long title at 40 characters' {
        $title = 'x' * 60
        (Format-SessionLine 'C:\dev\a' $title) | Should -BeExactly ("a $dot " + ('x' * 39) + '...')
    }
    It 'does not split a surrogate pair when cutting' {
        $title = ('x' * 38) + [char]::ConvertFromUtf32(0x1F600) + 'yyyy'
        $line = Format-SessionLine '' $title
        $line | Should -BeExactly (('x' * 38) + '...')
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b3.txt; Get-Content $env:TEMP\b3.txt -Tail 15`
Esperado: os 6 testes FAIL (`is not recognized`). Total: 158 passed, 6 failed.

- [ ] **Step 3: `Format-SessionLine`**

Anexe ao fim do `common.ps1` (Write num temporário):

```powershell

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
```

No `widget.ps1`, `Set-ProjectChip` passa a usar a função (resolve também o corte de emoji do 4a):

```powershell
    function Set-ProjectChip($chip, $textBlock, $item) {
        $text = Format-SessionLine ([string]$item.cwd) ([string]$item.title)
        $textBlock.Text = $text
        $chip.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    }
```

Run: a suíte. Esperado: 164 passed, 0 failed.

- [ ] **Step 4: Strings**

`pt`: `"workingOne": "1 trabalhando",` e `"workingMany": "{0} trabalhando",` e `"sessionsMore": "+{0} sessões",`, e troque `idleTip` por `"Arraste para mover · clique para ver as sessões · botão direito para fechar"`.
`en`: `"workingOne": "1 working",`, `"workingMany": "{0} working",`, `"sessionsMore": "+{0} sessions",`, e `idleTip`: `"Drag to move · click to see sessions · right-click to close"`.

- [ ] **Step 5: XAML da pílula**

Troque o `IdlePanel` (hoje um `StackPanel` horizontal) por um painel vertical com o cabeçalho horizontal e a lista:

```xml
      <StackPanel x:Name="IdlePanel" Orientation="Vertical" Margin="14,9,16,9" Background="Transparent">
        <StackPanel Orientation="Horizontal">
          <Ellipse Width="8" Height="8" Fill="#5FB98A" VerticalAlignment="Center" Margin="0,0,9,0"/>
          <TextBlock Text="Claude Code" Foreground="#E8E8EC" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="IdleText" Foreground="#7E7E88" FontSize="12" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel x:Name="SessionsList" Margin="0,8,0,0" Visibility="Collapsed"/>
      </StackPanel>
```

e acrescente `'SessionsList'` à lista de nomes do `$ui`.

- [ ] **Step 6: Lista, clique e timer**

Antes de `function Show-Idle`, acrescente:

```powershell
    # --- Sessions list on the idle pill ---
    $script:sessionsOpen = $false
    $script:titles = @{}        # session id -> @{ at; text }
    $script:sessionRows = @()
    # Working sessions, with their title (re-read at most every 15 s, only while the list is open)
    # and whether a request from their project is waiting for you
    function Get-SessionRows {
        $busy = @(Get-BusySessions (Join-Path $Data 'busy') (12 * 3600 * 1000) (15 * 60 * 1000))
        $waiting = @{}
        foreach ($r in @(Get-Pending)) { $waiting[[string]$r.cwd] = $true }
        foreach ($b in $busy) {
            $c = $script:titles[$b.id]
            if ($script:sessionsOpen -and (-not $c -or ((Get-NowMs) - $c.at) -gt 15000)) {
                $c = @{ at = Get-NowMs; text = (Get-SessionTitle $b.transcript $b.id) }
                $script:titles[$b.id] = $c
            }
            [pscustomobject]@{ cwd = $b.cwd; title = $(if ($c) { $c.text } else { '' }); since = $b.since; waiting = $waiting.ContainsKey($b.cwd) }
        }
    }
    # Pill text ("no requests" / "N working") and, while open, one row per session (at most 8)
    function Set-SessionRows($rows) {
        $rows = @($rows)
        $script:sessionRows = $rows
        $ui.IdleText.Text = $Sep + $(if ($rows.Count -eq 0) { $S.idle } elseif ($rows.Count -eq 1) { $S.workingOne } else { $S.workingMany -f $rows.Count })
        if ($rows.Count -eq 0) { $script:sessionsOpen = $false }
        $list = $ui.SessionsList
        $list.Children.Clear()
        $list.Visibility = if ($script:sessionsOpen) { 'Visible' } else { 'Collapsed' }
        if (-not $script:sessionsOpen) { return }
        foreach ($r in @($rows | Select-Object -First 8)) {
            $row = New-Object System.Windows.Controls.DockPanel
            $row.Margin = '0,3,0,3'
            $dot = New-Object System.Windows.Shapes.Ellipse
            $dot.Width = 7
            $dot.Height = 7
            $dot.Margin = '0,0,8,0'
            $dot.VerticalAlignment = 'Center'
            $dot.Fill = Get-Brush $(if ($r.waiting) { '#D97757' } else { '#5FB98A' })
            [System.Windows.Controls.DockPanel]::SetDock($dot, 'Left')
            $mins = [int][math]::Floor(((Get-NowMs) - [int64]$r.since) / 60000)
            $age = New-TextBlock $(if ($mins -lt 1) { $S.now } else { $S.minutesAgo -f $mins }) 11.5 '#7E7E88'
            $age.Margin = '14,0,0,0'
            $age.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($age, 'Right')
            $name = New-TextBlock (Format-SessionLine ([string]$r.cwd) ([string]$r.title)) 12 '#C8C8D0'
            $name.TextWrapping = 'NoWrap'
            $name.VerticalAlignment = 'Center'
            [void]$row.Children.Add($dot)
            [void]$row.Children.Add($age)
            [void]$row.Children.Add($name)
            [void]$list.Children.Add($row)
        }
        if ($rows.Count -gt 8) {
            [void]$list.Children.Add((New-TextBlock ($S.sessionsMore -f ($rows.Count - 8)) 11.5 '#7E7E88'))
        }
    }
    function Update-Sessions { Set-SessionRows @(Get-SessionRows) }
    function Switch-Sessions {
        if ($ui.IdlePanel.Visibility -ne 'Visible' -or $script:sessionRows.Count -eq 0) { return }
        $script:sessionsOpen = -not $script:sessionsOpen
        Update-Sessions
    }

```

`Show-Idle` passa a ser:

```powershell
    function Show-Idle {
        $script:current = $null
        $script:currentDone = $null
        Set-Panel 'IdlePanel'
        Update-Sessions
    }
```

e `Set-Panel`, depois do `foreach`, ganha: `if ($name -ne 'IdlePanel') { $script:sessionsOpen = $false; $ui.SessionsList.Visibility = 'Collapsed' }`.

Atenção: `Update-View` chama `Show-Idle` a cada tick de 400 ms; `Get-BusySessions` lê arquivos e consulta processos. Para não pesar, `Show-Idle` só recalcula as linhas a cada 5 ticks (~2 s) ou quando acabou de entrar na pílula: use `$script:sessionsAt` (`Get-NowMs` da última leitura) e `if ($forceRefresh -or ((Get-NowMs) - $script:sessionsAt) -gt 2000)`; `Switch-Sessions` força. Resultado: `Show-Idle` fica

```powershell
    $script:sessionsAt = 0
    function Show-Idle {
        $wasIdle = $ui.IdlePanel.Visibility -eq 'Visible'
        $script:current = $null
        $script:currentDone = $null
        Set-Panel 'IdlePanel'
        if (-not $wasIdle -or ((Get-NowMs) - $script:sessionsAt) -gt 2000) {
            $script:sessionsAt = Get-NowMs
            Update-Sessions
        }
    }
```

e `Switch-Sessions` zera `$script:sessionsAt` antes de `Update-Sessions` (para a próxima rodada reler).

Clique: no `MouseLeftButtonDown`, troque o trecho

```powershell
        # A click without a move keeps the saved spot (its monitor may be unplugged right now)
        if ($win.Left -eq $left -and $win.Top -eq $top) { return }
```

por:

```powershell
        # A click without a move keeps the saved spot (its monitor may be unplugged right now);
        # on the idle pill it opens or closes the sessions list
        if ($win.Left -eq $left -and $win.Top -eq $top) { Switch-Sessions; return }
```

`Switch-Sessions` está definida mais abaixo no arquivo que o tratador, mas só é chamada em tempo de execução: ok.

- [ ] **Step 7: Amostra e imagens**

`tools/samples.json`: acrescente em `en` e `pt`, ao lado de `done`:

```json
    "sessions": [
      { "cwd": "C:\\dev\\my-app", "title": "Login form validation", "waiting": true, "minutes": 2 },
      { "cwd": "C:\\dev\\billing", "title": "New billing service", "waiting": false, "minutes": 7 },
      { "cwd": "C:\\dev\\docs", "title": "", "waiting": false, "minutes": 14 }
    ]
```

(em `pt`: `meu-app` / `Validação do login`, `cobranca` / `Serviço de cobrança`, `docs`.)

`widget.ps1`, em `Export-Samples`, depois de `Save-Png $frame (Join-Path $OutDir 'idle.png')`, acrescente:

```powershell

        $script:sessionsOpen = $true
        $rows = foreach ($s in @($sample.sessions)) {
            [pscustomobject]@{ cwd = [string]$s.cwd; title = [string]$s.title; since = $now - [int64]$s.minutes * 60000; waiting = [bool]$s.waiting }
        }
        Set-SessionRows $rows
        Save-Png $frame (Join-Path $OutDir 'sessions.png')
        $script:sessionsOpen = $false
        Set-SessionRows @()
```

`tools/render-screenshots.ps1`: acrescente `sessions` à lista de imagens esperadas, se houver. `README.md` e `README.pt-BR.md`: depois da imagem `idle.png`, acrescente `<img src="docs/images/en/sessions.png" width="260" alt="...">` (pt: `.../pt/sessions.png`) com `alt` descritivo.

- [ ] **Step 8: Rodar a suíte e as imagens**

Run: `powershell -NoProfile -File tools\render-screenshots.ps1` e `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\b3.txt; Get-Content $env:TEMP\b3.txt -Tail 15`
Esperado: `docs/images/{en,pt}/sessions.png` existem (abra uma e confira três linhas, bolinha laranja na primeira); a suíte inteira passa e o teste de renderização confere os 4 PNGs de sempre (acrescente `sessions` à lista dele em `tests/widget.Tests.ps1`: `foreach ($name in 'idle', 'sessions', 'permission', 'question', 'done')`).

- [ ] **Step 9: Verificação à mão**

Com `-DataDir` temporário, crie `busy\x.json` (`{"pid":0,"since":<agora em ms>,"cwd":"C:\\dev\\app","transcript":""}`) e confirme que a pílula diz "1 trabalhando"; um clique abre a lista; outro fecha; arrastar a pílula não abre a lista; duplo clique não alterna. Se não for possível, anote e deixe para a verificação pós-merge.

- [ ] **Step 10: Commit**

```bash
git add plugins/opaiva-code-widget/scripts tools tests docs/images README.md README.pt-BR.md
git commit -m "feat: sessions list on the idle pill

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Release 2.2.0

**Files:**
- Modify: `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, `README.md`, `README.pt-BR.md`

- [ ] **Step 1: CHANGELOG**

Logo depois de `# Changelog` e da linha em branco:

```markdown
## 2.2.0 (2026-10-08)

- **Tray icon and "do not disturb".** A tray icon (orange while active, grey in "do not disturb") toggles the mode with a left click; its menu has **Do not disturb** and **Close widget**. In the mode, permission requests and questions go straight to VS Code, the widget hides, and "finished" notices wait silently until you turn the mode off. The mode stays on until you turn it off, even after a restart. If the icon is in the hidden-icons area, drag it onto the taskbar once.
- **Sessions list.** The idle pill says how many sessions are working. Click it to see each one: project, session title and how long it has been working (orange when a request from that project is waiting).
```

- [ ] **Step 2: Rodar e ver falhar**

Run: a suíte. Esperado: `plugin.json version matches the latest CHANGELOG entry` FAIL. Total: 164 passed, 1 failed.

- [ ] **Step 3: Versão e READMEs**

`plugin.json`: `"version": "2.1.0"` → `"version": "2.2.0"`.

`README.md`:
- Tabela "How to use it": nova linha `| Idle pill, **N working** | Click it to list the working sessions (project, title, time). Click again to close the list. |`.
- Depois de "**Right-click → Close widget**...": `- **Tray icon.** Left-click toggles **do not disturb**; right-click for the menu. In the mode, requests and questions go straight to VS Code, the widget is hidden and "finished" notices wait until you turn it off. It stays on until you turn it off, even after a restart. Windows may hide new tray icons: drag it onto the taskbar once.`
- "How it works", última linha de arquivos: acrescente `busy\` (sessions working), `busy-round.json` e `dnd.flag` (the "do not disturb" mode) à lista.

`README.pt-BR.md`: o mesmo, em português: linha da tabela `| Pílula parada, **N trabalhando** | Clique para listar as sessões que estão trabalhando (projeto, título, tempo). Clique de novo para fechar a lista. |`; item **Ícone na bandeja.** `O clique esquerdo liga e desliga o **não perturbe**; o botão direito abre o menu. No modo, pedidos e perguntas vão direto para o VS Code, o widget fica escondido e os avisos de "terminou" esperam até você desligar. Fica ligado até você desligar, inclusive depois de reiniciar. O Windows pode esconder ícones novos na bandeja: arraste-o para a barra uma vez.`; e `busy\` (sessões trabalhando), `busy-round.json` e `dnd.flag` (o modo "não perturbe") na lista de arquivos de dados.

- [ ] **Step 4: Rodar e ver passar; commit**

Run: a suíte. Esperado: 165 passed, 0 failed.

```bash
git add CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json README.md README.pt-BR.md
git commit -m "docs: release 2.2.0

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```
