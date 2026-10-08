# Diff no cartão, "Sempre permitir" e atalhos globais: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** versão 2.3.0: o cartão de um Edit/Write mostra o diff, o cartão de permissão oferece botões "Sempre permitir" (as sugestões do próprio Claude Code), e atalhos globais opcionais aprovam, negam e ligam o "não perturbe".

**Architecture:** funções puras (`Get-DiffLines`, `ConvertTo-Hotkey`) no `common.ps1`; o hook acrescenta `change` e `suggestions` ao pedido e transforma a resposta `allowAlways` (só com um índice) numa sugestão que ele mesmo guardou; o widget desenha o diff e os botões e registra os atalhos com `RegisterHotKey`.

**Tech Stack:** Windows PowerShell 5.1, WPF, Win32 (`RegisterHotKey`, `keybd_event` nos testes), Pester ≥ 5.5.

**Spec:** `docs/superpowers/specs/2026-10-08-diff-always-allow-hotkeys-design.md`

## Global Constraints

- Todo `.ps1` só com ASCII; texto de interface só em `strings.json` (UTF-8).
- Não escreva barra invertida seguida de letra/dígito em strings pelas ferramentas de escrita (heredoc, python, Edit): viram TAB ou o caractere (já aconteceu com `\t` e `\u25CF`). Use a ferramenta Write para trechos novos, anexe por script que lê o arquivo, e confira `grep -c $'\t'`.
- Nomes de variável do PowerShell ignoram maiúsculas e o escopo é dinâmico: nunca use `$s`/`$S`, `$quietMs`/`$QuietMs` etc. como nomes diferentes; parâmetros de handler são `$src, $e`.
- O hook nunca escreve no stdout além da decisão; funções novas não vazam saída.
- O conteúdo gravado por "Sempre permitir" vem **só** da cópia que o hook tem de `permission_suggestions`, escolhida por índice. Oferecidas: `addRules` com `behavior` ≠ `deny` e regras, `setMode` para `default|plan|acceptEdits|auto|dontAsk`, `addDirectories` com pastas. Nunca: `removeRules`, `replaceRules`, `deny`, `bypassPermissions`.
- Diff: no máximo 14 linhas; textos do `change` cortados em 4000 caracteres, no máximo 5 edições.
- Atalhos: só com `CLAUDE_WIDGET_HOTKEYS=1`; teclas por `CLAUDE_WIDGET_KEY_APPROVE|DENY|DND`; padrões `Ctrl+Alt+Y`, `Ctrl+Alt+N`, `Ctrl+Alt+D`.
- Versão `2.3.0` no `plugin.json` e no topo do `CHANGELOG.md`.
- Branch: `feat/diff-always-allow-hotkeys`. Commits terminam com `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.
- Suíte: `powershell -NoProfile -File tools\test.ps1` (hoje 171 passando; ~2 min). Mande a saída para um arquivo e leia o fim. Não edite `widget.ps1`/`strings.json` enquanto a suíte roda (os testes Desktop leem do disco).

## Review Focus

1. **Resposta forjada ou estragada** (`res-<id>.json` com `index` fora da lista, texto no lugar do número, ou com campos de sugestão): o hook só aprova, sem gravar nada, ou grava uma sugestão oferecida. Coberto na Task 2.
2. **Pedido sem `permission_suggestions`, `Edit` sem `old_string`, `Write` sem `content`, `MultiEdit` com lista vazia:** o cartão aparece como hoje, sem erro. Coberto nas Tasks 1 e 2.
3. **Arquivo enorme no Write** (milhares de linhas): o cartão não pode travar nem crescer sem limite. Coberto na Task 1 (limite de 14 linhas) e na Task 2 (corte de 4000 caracteres).
4. **Atalho já usado por outro programa** ou valor de tecla inválido: o widget segue funcionando e escreve uma linha no log. Coberto na Task 4 (unidade de `ConvertTo-Hotkey`; o registro que falha não tem teste automático).
5. **Atalho de aprovar sem cartão de permissão na tela** (pílula, pergunta, aviso, "não perturbe"): não faz nada. Coberto na Task 4 (teste Desktop: tecla sem pedido).

---

### Task 1: `Get-DiffLines` e `ConvertTo-Hotkey`

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (funções novas no fim)
- Test: `tests/common.Tests.ps1`

**Interfaces:**
- Produces: `Get-DiffLines($Change)` → lista de `[pscustomobject]@{ kind; text }` (`kind` = `add`|`del`|`more`; em `more`, `text` é o número de linhas que ficaram de fora); `$Change` = `@{ kind = 'edit'|'write'; edits = @(@{ old; new }); content }`. `ConvertTo-Hotkey([string]$Text)` → `@{ mod; vk }` ou `$null`.

- [ ] **Step 1: Testes**

Escreva (ferramenta Write, em um arquivo temporário) e anexe ao fim de `tests/common.Tests.ps1`:

```powershell

Describe 'Get-DiffLines' {
    function New-Edit([string]$Old, [string]$New) { @{ kind = 'edit'; edits = @(@{ old = $Old; new = $New }) } }
    It 'shows only the lines that changed, without the equal start and end' {
        $lines = @(Get-DiffLines (New-Edit "a`nb`nc" "a`nX`nc"))
        $lines.Count | Should -Be 2
        $lines[0].kind | Should -BeExactly 'del'
        $lines[0].text | Should -BeExactly 'b'
        $lines[1].kind | Should -BeExactly 'add'
        $lines[1].text | Should -BeExactly 'X'
    }
    It 'shows every line when nothing is in common' {
        $lines = @(Get-DiffLines (New-Edit "x`ny" "z"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:x,del:y,add:z'
    }
    It 'treats an empty old text as a pure addition' {
        $lines = @(Get-DiffLines (New-Edit '' "new1`nnew2"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:new1,add:new2'
    }
    It 'shows nothing when the edit changes nothing' {
        @(Get-DiffLines (New-Edit "same`nlines" "same`nlines")).Count | Should -Be 0
    }
    It 'handles Windows line endings' {
        $lines = @(Get-DiffLines (New-Edit "a`r`nb" "a`r`nc"))
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:b,add:c'
    }
    It 'shows a written file as added lines' {
        $lines = @(Get-DiffLines @{ kind = 'write'; content = "one`ntwo`nthree" })
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'add:one,add:two,add:three'
    }
    It 'keeps 14 lines and says how many were left out' {
        $content = (1..20 | ForEach-Object { "line $_" }) -join "`n"
        $lines = @(Get-DiffLines @{ kind = 'write'; content = $content })
        $lines.Count | Should -Be 15
        @($lines | Where-Object { $_.kind -eq 'add' }).Count | Should -Be 14
        $lines[14].kind | Should -BeExactly 'more'
        $lines[14].text | Should -BeExactly '6'
    }
    It 'follows several edits in order' {
        $change = @{ kind = 'edit'; edits = @(@{ old = 'a'; new = 'b' }, @{ old = 'c'; new = 'd' }) }
        $lines = @(Get-DiffLines $change)
        ($lines | ForEach-Object { $_.kind + ':' + $_.text }) -join ',' | Should -BeExactly 'del:a,add:b,del:c,add:d'
    }
    It 'returns nothing without a change' {
        @(Get-DiffLines $null).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'edit'; edits = @() }).Count | Should -Be 0
        @(Get-DiffLines @{ kind = 'write' }).Count | Should -Be 0
    }
}

Describe 'ConvertTo-Hotkey' {
    It 'parses <text>' -ForEach @(
        @{ text = 'Ctrl+Alt+Y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'ctrl + alt + y'; mod = 0x4003; vk = 0x59 }
        @{ text = 'Shift+Win+F13'; mod = 0x400C; vk = 0x7C }
        @{ text = 'Ctrl+5'; mod = 0x4002; vk = 0x35 }
        @{ text = 'Alt+F1'; mod = 0x4001; vk = 0x70 }
    ) {
        $hk = ConvertTo-Hotkey $text
        $hk.mod | Should -Be $mod
        $hk.vk | Should -Be $vk
    }
    It 'rejects <text>' -ForEach @(
        @{ text = '' }
        @{ text = 'Y' }
        @{ text = 'Ctrl+Alt' }
        @{ text = 'Ctrl+Alt+Yes' }
        @{ text = 'Ctrl+Y+N' }
        @{ text = 'Ctrl+F25' }
        @{ text = 'Hyper+Y' }
    ) {
        ConvertTo-Hotkey $text | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests/common.Tests.ps1 -FullNameFilter '*Get-DiffLines*','*ConvertTo-Hotkey*' -Output Minimal"`
Esperado: todos FAIL (`is not recognized`): 9 de `Get-DiffLines` e 12 de `ConvertTo-Hotkey`.

- [ ] **Step 3: Implementar**

Anexe ao fim do `common.ps1` (Write num temporário e anexe por script):

```powershell

# Lines of text, with Windows or Unix line endings; an empty text has none
function Split-TextLines([string]$Text) {
    if (-not $Text) { return @() }
    return @(($Text -replace "`r`n", "`n") -split "`n")
}

# What to show on a permission card for a file change: a list of { kind; text } with kind add, del
# or more (text = how many lines were left out). An edit shows what left and what came in, without
# the lines that are equal at the start and at the end; a written file shows all its lines as added.
# At most 14 lines in total.
function Get-DiffLines($Change) {
    $all = New-Object System.Collections.ArrayList
    if ($Change -and $Change.kind -eq 'write') {
        foreach ($l in @(Split-TextLines ([string]$Change.content))) { [void]$all.Add([pscustomobject]@{ kind = 'add'; text = $l }) }
    }
    elseif ($Change) {
        foreach ($edit in @($Change.edits)) {
            $old = @(Split-TextLines ([string]$edit.old))
            $new = @(Split-TextLines ([string]$edit.new))
            $head = 0
            while ($head -lt $old.Count -and $head -lt $new.Count -and $old[$head] -ceq $new[$head]) { $head++ }
            $tail = 0
            while ($tail -lt $old.Count - $head -and $tail -lt $new.Count - $head -and $old[$old.Count - 1 - $tail] -ceq $new[$new.Count - 1 - $tail]) { $tail++ }
            for ($i = $head; $i -lt $old.Count - $tail; $i++) { [void]$all.Add([pscustomobject]@{ kind = 'del'; text = $old[$i] }) }
            for ($i = $head; $i -lt $new.Count - $tail; $i++) { [void]$all.Add([pscustomobject]@{ kind = 'add'; text = $new[$i] }) }
        }
    }
    $shown = @($all | Select-Object -First 14)
    $shown
    if ($all.Count -gt 14) { [pscustomobject]@{ kind = 'more'; text = [string]($all.Count - 14) } }
}

# "Ctrl+Alt+Y" -> @{ mod; vk } for RegisterHotKey (mod includes MOD_NOREPEAT, 0x4000); $null when the
# text is not a valid hotkey: modifiers Ctrl, Alt, Shift, Win (at least one) and one key A-Z, 0-9 or F1-F24
function ConvertTo-Hotkey([string]$Text) {
    if (-not $Text) { return $null }
    $mod = 0x4000
    $vk = 0
    foreach ($part in ($Text -split '\+')) {
        $p = $part.Trim().ToUpperInvariant()
        if ($p -eq 'CTRL') { $mod = $mod -bor 2 }
        elseif ($p -eq 'ALT') { $mod = $mod -bor 1 }
        elseif ($p -eq 'SHIFT') { $mod = $mod -bor 4 }
        elseif ($p -eq 'WIN') { $mod = $mod -bor 8 }
        elseif ($vk -ne 0) { return $null }
        elseif ($p -match '^[A-Z0-9]$') { $vk = [int][char]$p }
        elseif ($p -match '^F([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
        else { return $null }
    }
    if ($vk -eq 0 -or ($mod -band 0xF) -eq 0) { return $null }
    return @{ mod = $mod; vk = $vk }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: a mesma linha do Step 2, e depois a suíte inteira (`tools\test.ps1`).
Esperado: 21 passed no filtro; suíte 192 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 tests/common.Tests.ps1
git commit -m "feat: diff lines and hotkey parsing helpers

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Hook: `change`, `suggestions` e `allowAlways`

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1`
- Test: `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Produces: `New-ChangeInfo([string]$Tool, $ToolInput)` → `@{ kind; edits; content }` ou `$null`; `Get-OfferedSuggestions($Suggestions)` → objetos `{ index; type; rules; destination; mode; directories }`; `ConvertTo-UpdatedPermission($Suggestion)` → hashtable ordenada; `New-PermissionOutput([string]$Behavior, [string]$Message, $UpdatedPermissions = $null)`; campos `change` e `suggestions` no `req-*.json`; resposta `@{ decision = 'allowAlways'; index = N }`.

- [ ] **Step 1: Testes de unidade**

Anexe ao fim de `tests/hook.Tests.ps1` (Write num temporário):

```powershell

Describe 'New-ChangeInfo' {
    It 'describes an Edit' {
        $c = New-ChangeInfo 'Edit' ([pscustomobject]@{ file_path = 'C:\a.ps1'; old_string = 'x'; new_string = 'y' })
        $c.kind | Should -BeExactly 'edit'
        @($c.edits).Count | Should -Be 1
        $c.edits[0].old | Should -BeExactly 'x'
        $c.edits[0].new | Should -BeExactly 'y'
    }
    It 'describes a Write' {
        $c = New-ChangeInfo 'Write' ([pscustomobject]@{ file_path = 'C:\a.ps1'; content = 'hello' })
        $c.kind | Should -BeExactly 'write'
        $c.content | Should -BeExactly 'hello'
    }
    It 'describes a MultiEdit, at most 5 edits' {
        $edits = 1..8 | ForEach-Object { [pscustomobject]@{ old_string = "o$_"; new_string = "n$_" } }
        $c = New-ChangeInfo 'MultiEdit' ([pscustomobject]@{ file_path = 'C:\a.ps1'; edits = $edits })
        $c.kind | Should -BeExactly 'edit'
        @($c.edits).Count | Should -Be 5
        $c.edits[4].new | Should -BeExactly 'n5'
    }
    It 'cuts long texts at 4000 characters' {
        $c = New-ChangeInfo 'Write' ([pscustomobject]@{ content = 'x' * 9000 })
        $c.content.Length | Should -Be 4000
    }
    It 'is null for other tools and for empty input' {
        New-ChangeInfo 'Bash' ([pscustomobject]@{ command = 'ls' }) | Should -BeNullOrEmpty
        New-ChangeInfo 'MultiEdit' ([pscustomobject]@{ edits = @() }) | Should -BeNullOrEmpty
        New-ChangeInfo 'Edit' $null | Should -BeNullOrEmpty
    }
}

Describe 'Get-OfferedSuggestions' {
    BeforeAll {
        function ConvertFrom-TestJson([string]$Json) { $Json | ConvertFrom-Json }
    }
    It 'keeps allow rules, safe modes and directories, with their original index' {
        $list = ConvertFrom-TestJson '[
          {"type":"addRules","rules":["Bash(npm test *)"],"behavior":"allow","destination":"session","mode":null},
          {"type":"setMode","behavior":"allow","destination":"session","mode":"acceptEdits"},
          {"type":"addDirectories","directories":["C:\\other"],"destination":"session"}]'
        $out = @(Get-OfferedSuggestions $list)
        $out.Count | Should -Be 3
        ($out | ForEach-Object { $_.index }) -join ',' | Should -BeExactly '0,1,2'
        $out[0].rules[0] | Should -BeExactly 'Bash(npm test *)'
        $out[1].mode | Should -BeExactly 'acceptEdits'
        $out[2].directories[0] | Should -BeExactly 'C:\other'
    }
    It 'drops removeRules, replaceRules, deny and bypassPermissions' {
        $list = ConvertFrom-TestJson '[
          {"type":"removeRules","rules":["Bash(*)"],"behavior":"allow","destination":"userSettings"},
          {"type":"replaceRules","rules":["Bash(*)"],"behavior":"allow","destination":"userSettings"},
          {"type":"addRules","rules":["Bash(rm *)"],"behavior":"deny","destination":"session"},
          {"type":"setMode","behavior":"allow","destination":"session","mode":"bypassPermissions"},
          {"type":"addRules","rules":["Read(*)"],"behavior":"allow","destination":"session"}]'
        $out = @(Get-OfferedSuggestions $list)
        $out.Count | Should -Be 1
        $out[0].index | Should -Be 4
    }
    It 'drops rules without rules and directories without directories' {
        $list = ConvertFrom-TestJson '[{"type":"addRules","rules":[],"behavior":"allow"},{"type":"addDirectories","directories":[]}]'
        @(Get-OfferedSuggestions $list).Count | Should -Be 0
    }
    It 'returns nothing without suggestions' {
        @(Get-OfferedSuggestions $null).Count | Should -Be 0
    }
}

Describe 'ConvertTo-UpdatedPermission and New-PermissionOutput' {
    It 'keeps the suggestion as it came, without a null mode' {
        $s = '{"type":"addRules","rules":["Bash(git *)"],"behavior":"allow","destination":"projectSettings","mode":null}' | ConvertFrom-Json
        ConvertTo-UpdatedPermission $s | ConvertTo-Json -Compress |
            Should -BeExactly '{"type":"addRules","rules":["Bash(git *)"],"behavior":"allow","destination":"projectSettings"}'
    }
    It 'keeps the mode of a setMode suggestion' {
        $s = '{"type":"setMode","behavior":"allow","destination":"session","mode":"acceptEdits"}' | ConvertFrom-Json
        (ConvertTo-UpdatedPermission $s).mode | Should -BeExactly 'acceptEdits'
    }
    It 'adds updatedPermissions to the allow decision' {
        $s = '{"type":"addRules","rules":["Bash(git *)"],"behavior":"allow","destination":"session"}' | ConvertFrom-Json
        $out = New-PermissionOutput 'allow' '' @(ConvertTo-UpdatedPermission $s)
        ConvertTo-AsciiJson $out | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":["Bash(git *)"],"behavior":"allow","destination":"session"}]}}}'
    }
}
```

- [ ] **Step 2: Testes e2e**

No `Context 'PermissionRequest'` de `tests/hook.e2e.Tests.ps1`, depois do `It 'prints deny with the localized message...'` (antes do `It 'prints nothing when the widget hands the request back'`), acrescente (Write num temporário):

```powershell
        Context 'Edit with suggestions' {
            BeforeAll {
                function New-EditEvent($Sandbox) {
                    $e = New-HookEvent 'PermissionRequest' $Sandbox.Data @{
                        tool_name = 'Edit'
                        tool_input = @{ file_path = 'C:\dev\a.ps1'; old_string = "keep`nold"; new_string = "keep`nnew" }
                    }
                    $e.permission_suggestions = @(
                        @{ type = 'removeRules'; rules = @('Bash(*)'); behavior = 'allow'; destination = 'userSettings' },
                        @{ type = 'addRules'; rules = @('Edit(src/**)'); behavior = 'allow'; destination = 'session'; mode = $null },
                        @{ type = 'setMode'; behavior = 'allow'; destination = 'session'; mode = 'acceptEdits' })
                    return $e
                }
            }
            It 'sends the change and only the offered suggestions to the widget' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                $req.change.kind | Should -BeExactly 'edit'
                $req.change.edits[0].old | Should -BeExactly "keep`nold"
                @($req.suggestions).Count | Should -Be 2
                $req.suggestions[0].index | Should -Be 1
                $req.suggestions[0].rules[0] | Should -BeExactly 'Edit(src/**)'
                $req.suggestions[1].index | Should -Be 2
                Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
                [void](Complete-Hook $run)
            }
            It 'allowAlways with a valid index prints that suggestion as updatedPermissions' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = 1 }
                $r = Complete-Hook $run
                $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":["Edit(src/**)"],"behavior":"allow","destination":"session"}]}}}'
            }
            It 'allowAlways with an index that was not offered only allows' {
                foreach ($bad in 0, 7, -1) {
                    $run = Start-Hook $box (New-EditEvent $box)
                    $req = Wait-HookRequest $box
                    Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = $bad }
                    $r = Complete-Hook $run
                    $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
                }
            }
            It 'ignores suggestion content in the response: only the index counts' {
                $run = Start-Hook $box (New-EditEvent $box)
                $req = Wait-HookRequest $box
                Send-WidgetResponse $box $req.id @{ decision = 'allowAlways'; index = 'abc'; type = 'addRules'; rules = @('Bash(*)'); destination = 'userSettings' }
                $r = Complete-Hook $run
                $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            }
        }
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\c2.txt; Get-Content $env:TEMP\c2.txt -Tail 12` (ou o filtro `*New-ChangeInfo*`, `*Get-OfferedSuggestions*`, `*UpdatedPermission*`, `*Edit with suggestions*`)
Esperado: 5 + 4 + 3 testes de unidade FAIL (`is not recognized`/campos ausentes) e os 4 e2e FAIL (`change` nulo; o `allowAlways` hoje devolve nada). Total: 192 passed, 16 failed.

- [ ] **Step 4: Implementar**

No `hook.ps1`, logo antes de `function New-PermissionOutput`, acrescente (Write num temporário e insira por script):

```powershell
# The file change of an Edit, MultiEdit or Write for the widget's diff (texts cut at 4000 characters,
# at most 5 edits); $null for other tools or when there is nothing to show
function New-ChangeInfo([string]$Tool, $ToolInput) {
    if (-not $ToolInput) { return $null }
    function Limit-Text($t) { $t = [string]$t; if ($t.Length -gt 4000) { return $t.Substring(0, 4000) } return $t }
    if ($Tool -eq 'Write') {
        return @{ kind = 'write'; content = (Limit-Text $ToolInput.content) }
    }
    $edits = @()
    if ($Tool -eq 'Edit') { $edits = @($ToolInput) }
    elseif ($Tool -eq 'MultiEdit') { $edits = @($ToolInput.edits) }
    else { return $null }
    $list = @($edits | Where-Object { $_ } | Select-Object -First 5 | ForEach-Object { @{ old = (Limit-Text $_.old_string); new = (Limit-Text $_.new_string) } })
    if ($list.Count -eq 0) { return $null }
    return @{ kind = 'edit'; edits = $list }
}

# The suggestions of Claude Code the widget may offer as "Always allow", with their original index:
# rules that allow, the modes below bypassPermissions, and directories. Never rules that remove or
# replace the user's rules, nor anything that denies.
function Get-OfferedSuggestions($Suggestions) {
    $i = -1
    foreach ($s in @($Suggestions)) {
        $i++
        if (-not $s) { continue }
        $ok = $false
        switch ([string]$s.type) {
            'addRules' { $ok = ([string]$s.behavior -ne 'deny') -and (@($s.rules).Count -gt 0) }
            'setMode' { $ok = ([string]$s.behavior -ne 'deny') -and ([string]$s.mode -in @('default', 'plan', 'acceptEdits', 'auto', 'dontAsk')) }
            'addDirectories' { $ok = @($s.directories).Count -gt 0 }
        }
        if ($ok) {
            [pscustomobject]@{ index = $i; type = [string]$s.type; rules = @($s.rules); destination = [string]$s.destination
                mode = [string]$s.mode; directories = @($s.directories) }
        }
    }
}

# The suggestion as Claude Code sent it (type, rules, behavior, destination, mode, directories), without
# the empty fields, in the form updatedPermissions takes
function ConvertTo-UpdatedPermission($Suggestion) {
    $o = [ordered]@{}
    foreach ($name in 'type', 'rules', 'behavior', 'destination', 'mode', 'directories') {
        $p = $Suggestion.PSObject.Properties[$name]
        if ($p -and $null -ne $p.Value -and -not ($p.Value -is [array] -and $p.Value.Count -eq 0) -and [string]$p.Value -ne '') { $o[$name] = $p.Value }
    }
    return $o
}

```

Troque `New-PermissionOutput` por:

```powershell
function New-PermissionOutput([string]$Behavior, [string]$Message, $UpdatedPermissions = $null) {
    $decision = [ordered]@{ behavior = $Behavior }
    if ($Behavior -eq 'deny') { $decision.message = $Message }
    if ($Behavior -eq 'allow' -and @($UpdatedPermissions).Count -gt 0) { $decision.updatedPermissions = @($UpdatedPermissions) }
    return [ordered]@{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $decision } }
}
```

No `PermissionRequest` de `Invoke-Hook`, troque:

```powershell
        $id = New-Request 'permission' $cwd @{
            tool        = $tool
            description = $desc
            detail      = $detail
            title       = Get-SessionTitle $transcript $sid
        }
```

por:

```powershell
        $offered = @(Get-OfferedSuggestions $evt.permission_suggestions)
        $id = New-Request 'permission' $cwd @{
            tool        = $tool
            description = $desc
            detail      = $detail
            title       = Get-SessionTitle $transcript $sid
            change      = New-ChangeInfo $tool $in
            suggestions = $offered
        }
```

e troque o final do bloco (a linha `if ($decision -in @('allow', 'deny')) { return ... }`) por:

```powershell
        if ($decision -eq 'allowAlways') {
            # Only the index counts: the content comes from Claude Code's own suggestions of this request
            $index = -1
            if ([int]::TryParse([string]$res.index, [ref]$index) -and (@($offered | Where-Object { $_.index -eq $index }).Count -gt 0)) {
                $chosen = @($evt.permission_suggestions)[$index]
                return ConvertTo-AsciiJson (New-PermissionOutput 'allow' '' @(ConvertTo-UpdatedPermission $chosen))
            }
            return ConvertTo-AsciiJson (New-PermissionOutput 'allow' '')
        }
        if ($decision -in @('allow', 'deny')) { return ConvertTo-AsciiJson (New-PermissionOutput $decision $S.deniedMessage) }
```

(`$offered` é um array vazio, `@()`, quando não há sugestões: o campo `suggestions` vai como `[]`.)

- [ ] **Step 5: Rodar e ver passar**

Run: a suíte inteira.
Esperado: 208 passed, 0 failed. Atenção ao teste antigo `New-PermissionOutput ... Depth 5`: `updatedPermissions` não aparece nele, então continua igual.

- [ ] **Step 6: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/hook.ps1 tests/hook.Tests.ps1 tests/hook.e2e.Tests.ps1
git commit -m "feat: requests carry the file change and Claude Code's suggestions; allowAlways

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Widget: diff e botões "Sempre permitir"

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`, `plugins/opaiva-code-widget/scripts/strings.json`
- Modify: `tools/samples.json`; Test: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Get-DiffLines` (Task 1); campos `change`/`suggestions` do pedido (Task 2).
- Produces: `Set-ChangeView($change)`, `Set-AlwaysButtons($r)`, `Send-Response($decision, $extra)`; chaves de texto.

- [ ] **Step 1: Teste de renderização**

Em `tests/widget.Tests.ps1`, na lista do teste de renderização, troque `foreach ($name in 'idle', 'sessions', 'permission', 'question', 'done')` por `foreach ($name in 'idle', 'sessions', 'permission', 'edit', 'question', 'done')`. Rode a suíte: esperado FAIL só nesse teste (`edit.png` não existe), nas duas línguas.

- [ ] **Step 2: Strings**

`strings.json` (Edit, UTF-8), `pt`, depois de `"trayDnd": ...`:

```json
    "alwaysRule": "Sempre permitir: {0}",
    "alwaysMode": "Mudar o modo para {0}",
    "alwaysDir": "Sempre permitir a pasta {0}",
    "alwaysMore": "+{0}",
    "destSession": "nesta sessão",
    "destLocal": "só aqui (local)",
    "destProject": "neste projeto",
    "destUser": "em todos os projetos",
    "diffMore": "+{0} linhas",
    "modeDefault": "padrão",
    "modePlan": "planejar",
    "modeAcceptEdits": "aceitar edições",
    "modeAuto": "automático",
    "modeDontAsk": "não perguntar",
```

`en`:

```json
    "alwaysRule": "Always allow: {0}",
    "alwaysMode": "Switch mode to {0}",
    "alwaysDir": "Always allow folder {0}",
    "alwaysMore": "+{0}",
    "destSession": "this session",
    "destLocal": "local only",
    "destProject": "this project",
    "destUser": "all projects",
    "diffMore": "+{0} lines",
    "modeDefault": "default",
    "modePlan": "plan",
    "modeAcceptEdits": "accept edits",
    "modeAuto": "auto",
    "modeDontAsk": "don't ask",
```

- [ ] **Step 3: Amostras**

Em `tools/samples.json`, em `en` e em `pt`, depois do bloco `"permission": { ... }`, acrescente um `"edit"` (use a ferramenta Edit; no JSON, `\n` dentro de texto é escrito como `\\n`... atenção: escreva as quebras de linha como o par de caracteres barra e `n` DENTRO do JSON, o que exige a ferramenta Write num arquivo temporário e um script python que leia o JSON, acrescente a chave e regrave com `json.dumps(..., ensure_ascii=False, indent=2)` preservando as demais chaves):

```json
"edit": {
  "tool": "Edit",
  "description": "Raise the retry limit",            // pt: "Aumentar o limite de tentativas"
  "detail": "C:\\dev\\my-app\\src\\client.js",        // pt: C:\\dev\\meu-app\\src\\client.js
  "cwd": "C:\\dev\\my-app",
  "title": "Login form validation",                   // pt: "Validação do login"
  "change": { "kind": "edit", "edits": [ { "old": "const retries = 3;\nconst delay = 100;", "new": "const retries = 5;\nconst delay = 250;" } ] },
  "suggestions": [
    { "index": 0, "type": "addRules", "rules": ["Edit(src/**)"], "destination": "session", "mode": "", "directories": [] },
    { "index": 1, "type": "setMode", "rules": [], "destination": "session", "mode": "acceptEdits", "directories": [] }
  ]
}
```

(Os comentários `//` acima são só para o leitor: o JSON real não os tem. Depois de gravar, rode `json.load` para validar, e reaplique a indentação do arquivo para não reformatar as outras chaves: se o `json.dumps` reformatar tudo, tudo bem, desde que o conteúdo seja o mesmo.)

- [ ] **Step 4: XAML**

No `ReqPanel` de `widget.ps1`, logo depois do `</Border>` que fecha a caixa do `Detail` (a que contém `x:Name="Detail"`), acrescente:

```xml
        <Border x:Name="ChangeBox" CornerRadius="8" Background="#141417" BorderBrush="#2C2C33" BorderThickness="1" Margin="0,8,0,0" Visibility="Collapsed">
          <ScrollViewer MaxHeight="220" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" Focusable="False">
            <StackPanel x:Name="ChangeLines" Margin="0,4,0,4"/>
          </ScrollViewer>
        </Border>
```

e logo depois do `</DockPanel>` dos botões `BtnApprove`/`BtnDeny`/`BtnVs`:

```xml
        <WrapPanel x:Name="AlwaysList" Margin="0,10,0,0" Visibility="Collapsed"/>
```

Acrescente `'ChangeBox', 'ChangeLines', 'AlwaysList'` à lista de nomes do `$ui`.

- [ ] **Step 5: Código**

Troque `Send-Response` por:

```powershell
    function Send-Response($decision, [hashtable]$extra = @{}) {
        $r = $script:current
        if (-not $r -or (Test-ClickTooSoon)) { return }
        $res = Join-Path $Queue "res-$($r.id).json"
        if (-not (Test-Path -LiteralPath $res)) { Write-JsonAtomic $res (@{ decision = $decision } + $extra) }
        $script:current = $null
        Update-View
    }
```

Antes de `function Show-Permission`, acrescente (Write num temporário e insira por script):

```powershell
    # The diff of an Edit/Write under the detail box: red removed lines, green added lines
    function Set-ChangeView($change) {
        $ui.ChangeLines.Children.Clear()
        $lines = @(Get-DiffLines $change)
        if ($lines.Count -eq 0) { $ui.ChangeBox.Visibility = 'Collapsed'; return }
        foreach ($l in $lines) {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.FontFamily = New-Object System.Windows.Media.FontFamily 'Cascadia Mono, Consolas'
            $tb.FontSize = 12
            $tb.Padding = '10,1,10,1'
            $tb.TextWrapping = 'NoWrap'
            if ($l.kind -eq 'del') { $tb.Text = '- ' + $l.text; $tb.Background = Get-Brush '#3A1E1E'; $tb.Foreground = Get-Brush '#F29090' }
            elseif ($l.kind -eq 'add') { $tb.Text = '+ ' + $l.text; $tb.Background = Get-Brush '#1E3A2A'; $tb.Foreground = Get-Brush '#7FD3A0' }
            else { $tb.Text = $S.diffMore -f $l.text; $tb.Foreground = Get-Brush '#7E7E88' }
            [void]$ui.ChangeLines.Children.Add($tb)
        }
        $ui.ChangeBox.Visibility = 'Visible'
    }
    function Get-DestinationText([string]$dest) {
        switch ($dest) {
            'session' { $S.destSession }
            'localSettings' { $S.destLocal }
            'projectSettings' { $S.destProject }
            'userSettings' { $S.destUser }
            default { $dest }
        }
    }
    # "Always allow" buttons: one per suggestion Claude Code made (at most 3), showing the rule and where it is saved
    function Set-AlwaysButtons($r) {
        $ui.AlwaysList.Children.Clear()
        $shown = 0
        foreach ($sg in @($r.suggestions)) {
            if (-not $sg -or $shown -ge 3) { continue }
            $what = switch ([string]$sg.type) {
                'addRules' {
                    $rules = @($sg.rules)
                    $S.alwaysRule -f ($rules[0] + $(if ($rules.Count -gt 1) { ' ' + ($S.alwaysMore -f ($rules.Count - 1)) } else { '' }))
                }
                'setMode' {
                    $key = 'mode' + ([string]$sg.mode).Substring(0, 1).ToUpperInvariant() + ([string]$sg.mode).Substring(1)
                    $S.alwaysMode -f $(if ($S.PSObject.Properties[$key]) { $S.$key } else { [string]$sg.mode })
                }
                'addDirectories' { $S.alwaysDir -f @($sg.directories)[0] }
                default { '' }
            }
            if (-not $what) { continue }
            $full = $what + '  ' + [char]0x00B7 + '  ' + (Get-DestinationText ([string]$sg.destination))
            $btn = New-Object System.Windows.Controls.Button
            $btn.Style = $win.FindResource('Btn')
            $btn.Content = $(if ($full.Length -gt 60) { $full.Substring(0, 57) + '...' } else { $full })
            $btn.ToolTip = $full
            $btn.Height = 28
            $btn.FontSize = 12
            $btn.FontWeight = [System.Windows.FontWeights]::Normal
            $btn.Padding = '12,0'
            $btn.Margin = '0,0,8,6'
            $btn.Background = Get-Brush '#2A2A30'
            $btn.BorderBrush = Get-Brush '#3A3A42'
            $btn.Foreground = Get-Brush '#C8C8D0'
            $btn.Tag = [int]$sg.index
            $btn.Add_Click({ param($src, $e) Send-Response 'allowAlways' @{ index = [int]$src.Tag } })
            [void]$ui.AlwaysList.Children.Add($btn)
            $shown++
        }
        $ui.AlwaysList.Visibility = if ($shown -gt 0) { 'Visible' } else { 'Collapsed' }
    }
```

Em `Show-Permission`, depois de `$ui.Detail.ScrollToHome()`, acrescente:

```powershell
        Set-ChangeView $r.change
        Set-AlwaysButtons $r
```

Em `Export-Samples`, depois do bloco do `permission.png` (a linha `Save-Png $frame (Join-Path $OutDir 'permission.png')`), acrescente:

```powershell

        $e = $sample.edit
        $e | Add-Member -NotePropertyName id -NotePropertyValue 'sample-edit' -Force
        $e | Add-Member -NotePropertyName kind -NotePropertyValue 'permission' -Force
        $e | Add-Member -NotePropertyName created -NotePropertyValue ($now - 41000) -Force
        $e | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $e 1
        Save-Png $frame (Join-Path $OutDir 'edit.png')
```

(Veja como o bloco do `permission` é montado em `Export-Samples` e copie o mesmo padrão; o trecho acima assume que `$now` e `$frame` existem, como no restante da função.)

- [ ] **Step 6: Imagens e suíte**

Run: `powershell -NoProfile -File tools\render-screenshots.ps1`; abra `docs/images/pt/edit.png` e confira o diff (duas linhas vermelhas, duas verdes) e os dois botões de "Sempre permitir". Depois a suíte inteira. Esperado: 208 passed (o teste de renderização agora confere `edit.png`), 0 failed. Acrescente `<img src="docs/images/en/edit.png" ...>` aos READMEs na Task 5.

- [ ] **Step 7: Commit**

```bash
git add plugins tools tests docs/images
git commit -m "feat: diff and Always allow buttons on the permission card

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Widget: atalhos globais

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Test: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `ConvertTo-Hotkey` (Task 1), `Send-Response`, `Sync-Dnd`, `Set-Dnd`/`Test-Dnd`.
- Produces: C# `ClaudeWidget.HotKeys` (`RegisterHotKey`, `UnregisterHotKey`); variáveis `CLAUDE_WIDGET_HOTKEYS`, `CLAUDE_WIDGET_KEY_APPROVE|DENY|DND`.

- [ ] **Step 1: Testes Desktop**

No `BeforeAll` de `tests/widget.Tests.ps1`, junto do `Add-Type` do `CcwTest.Windows`, acrescente um segundo tipo (Write num temporário, insira antes do `}` que fecha o `if (-not ('CcwTest.Windows' -as [type]))`... ou melhor, num `if` novo logo depois):

```powershell
    if (-not ('CcwTest.Keys' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Keys {
        [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
        // Presses the keys together (down in order, up in reverse)
        public static void Chord(byte[] vks) {
            foreach (var k in vks) keybd_event(k, 0, 0, UIntPtr.Zero);
            for (int i = vks.Length - 1; i >= 0; i--) keybd_event(vks[i], 0, 2, UIntPtr.Zero);
        }
    }
}
'@
    }
```

No fim de `tests/widget.Tests.ps1` (Write num temporário e anexe):

```powershell

Describe 'widget.ps1 global hotkeys' -Tag 'Desktop' {
    BeforeAll {
        function New-PermissionRequestFile([string]$Queue, [string]$Id) {
            $req = [ordered]@{ id = $Id; pid = $PID; kind = 'permission'; created = (Get-NowMs); timeout = 300; cwd = 'C:\dev\app'
                tool = 'Bash'; description = 'x'; detail = 'ls'; title = ''; change = $null; suggestions = @() }
            Write-JsonAtomic (Join-Path $Queue "req-$Id.json") $req
        }
        function Start-HotkeyWidget([string]$Data, [bool]$Enabled) {
            $saved = @{}
            foreach ($n in 'CLAUDE_WIDGET_HOTKEYS', 'CLAUDE_WIDGET_KEY_APPROVE', 'CLAUDE_WIDGET_KEY_DENY', 'CLAUDE_WIDGET_KEY_DND') { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_HOTKEYS', $(if ($Enabled) { '1' } else { $null }))
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_APPROVE', 'Ctrl+Alt+F13')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DENY', 'Ctrl+Alt+F14')
            [Environment]::SetEnvironmentVariable('CLAUDE_WIDGET_KEY_DND', 'Ctrl+Alt+F15')
            try {
                return Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                    '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $Data), '-Lang', 'en'
            }
            finally { foreach ($n in $saved.Keys) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        }
        function Wait-ForFile([string]$Path, [int]$Seconds = 10) {
            $deadline = (Get-Date).AddSeconds($Seconds)
            while ((Get-Date) -lt $deadline) { if (Test-Path -LiteralPath $Path) { return $true }; Start-Sleep -Milliseconds 250 }
            return $false
        }
        $CTRL = [byte]0x11; $ALT = [byte]0x12
    }
    It 'approves, denies and toggles do not disturb with the configured keys' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            (Wait-ForFile (Join-Path $queue 'res-r1.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r1.json')) | ConvertFrom-Json).decision | Should -BeExactly 'allow'

            New-PermissionRequestFile $queue 'r2'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7D))
            (Wait-ForFile (Join-Path $queue 'res-r2.json')) | Should -BeTrue
            ([IO.File]::ReadAllText((Join-Path $queue 'res-r2.json')) | ConvertFrom-Json).decision | Should -BeExactly 'deny'

            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            (Wait-ForFile (Join-Path $data 'dnd.flag')) | Should -BeTrue
            Join-Path $data 'widget.log' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'does nothing when the hotkeys are not turned on' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $false
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            New-PermissionRequestFile $queue 'r1'
            Start-Sleep -Milliseconds 1800
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7E))
            Start-Sleep -Seconds 3
            Join-Path $queue 'res-r1.json' | Should -Not -Exist
            Join-Path $data 'dnd.flag' | Should -Not -Exist
        }
        finally {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            [void]$proc.WaitForExit(5000)
            Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'does not approve when there is no permission card on screen' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $proc = Start-HotkeyWidget $data $true
        try {
            (Wait-ForFile (Join-Path $data 'widget.json') 30) | Should -BeTrue
            Start-Sleep -Seconds 3
            [CcwTest.Keys]::Chord([byte[]]@($CTRL, $ALT, [byte]0x7C))
            Start-Sleep -Seconds 2
            $proc.HasExited | Should -BeFalse
            @(Get-ChildItem -LiteralPath $queue -Filter 'res-*.json').Count | Should -Be 0
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

(O `Start-HotkeyWidget` troca as variáveis só durante o `Start-Process`, que as herda, e as restaura em seguida. O `NO_TRAY` do `BeforeAll` do arquivo já está definido.)

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Import-Module Pester -MinimumVersion 5.5; Invoke-Pester tests/widget.Tests.ps1 -FullNameFilter '*global hotkeys*' -Output Detailed"`
Esperado: o primeiro teste FAIL (`res-r1.json` nunca aparece: não há atalho); os outros dois passam hoje (nada acontece), e passam a proteger.

- [ ] **Step 3: Implementar**

No C# do `widget.ps1`, depois da classe `WinFocus` (antes do `}` que fecha o `namespace ClaudeWidget`), acrescente:

```csharp
    public static class HotKeys {
        [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
        [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
    }
```

Dentro do bloco `if (-not $RenderMode) {` da bandeja, logo depois do `$win.Add_Loaded({ ... })` do `Sync-Dnd`, acrescente (Write num temporário e insira por script):

```powershell

        # --- Global hotkeys (opt-in: CLAUDE_WIDGET_HOTKEYS=1) ---
        # Approve / deny act only on a permission card on screen; the third toggles "do not disturb"
        function Send-HotkeyDecision([string]$decision) {
            if ($script:current -and $script:current.kind -eq 'permission' -and -not $script:dnd) { Send-Response $decision }
        }
        $script:hotkeyActions = @{}
        $script:hotkeyIds = @()
        if ($env:CLAUDE_WIDGET_HOTKEYS -eq '1') {
            $hotkeyDefs = @(
                @{ id = 1; name = 'CLAUDE_WIDGET_KEY_APPROVE'; text = 'Ctrl+Alt+Y'; action = { Send-HotkeyDecision 'allow' } }
                @{ id = 2; name = 'CLAUDE_WIDGET_KEY_DENY'; text = 'Ctrl+Alt+N'; action = { Send-HotkeyDecision 'deny' } }
                @{ id = 3; name = 'CLAUDE_WIDGET_KEY_DND'; text = 'Ctrl+Alt+D'; action = { Set-Dnd $Data (-not (Test-Dnd $Data)); Sync-Dnd } }
            )
            $win.Add_SourceInitialized({
                try {
                    $h = $script:hwnd
                    $source = [System.Windows.Interop.HwndSource]::FromHwnd($h)
                    $script:hotkeyHook = [System.Windows.Interop.HwndSourceHook]{
                        param($hwnd, $msg, $wParam, $lParam, [ref]$handled)
                        if ($msg -eq 0x0312) {
                            $action = $script:hotkeyActions[[int]$wParam]
                            if ($action) {
                                $handled.Value = $true
                                try { & $action } catch { Write-Log $_ }
                            }
                        }
                        return [IntPtr]::Zero
                    }
                    $source.AddHook($script:hotkeyHook)
                    foreach ($d in $hotkeyDefs) {
                        $text = [Environment]::GetEnvironmentVariable($d.name)
                        if (-not $text) { $text = $d.text }
                        $hk = ConvertTo-Hotkey $text
                        if (-not $hk) { Write-Log "hotkey $($d.name): '$text' is not a valid hotkey"; continue }
                        if ([ClaudeWidget.HotKeys]::RegisterHotKey($h, $d.id, [uint32]$hk.mod, [uint32]$hk.vk)) {
                            $script:hotkeyActions[$d.id] = $d.action
                            $script:hotkeyIds += $d.id
                            if ($d.id -eq 1) { $ui.BtnApprove.Content = $S.approve + " ($text)" }
                            if ($d.id -eq 2) { $ui.BtnDeny.Content = $S.deny + " ($text)" }
                        }
                        else { Write-Log "hotkey $text could not be registered (another program uses it?)" }
                    }
                } catch { Write-Log $_ }
            })
        }
```

(Os botões mostram a tecla só depois de registrada; o texto original vem do bloco de textos localizados, antes.)

No `$win.Add_Closed({ ... })`, depois de `$timer.Stop()`, acrescente `foreach ($id in @($script:hotkeyIds)) { [void][ClaudeWidget.HotKeys]::UnregisterHotKey($script:hwnd, $id) }`.

- [ ] **Step 4: Rodar e ver passar**

Run: o filtro do Step 2 e depois a suíte inteira.
Esperado: os 3 testes passam; suíte 211 passed, 0 failed, sem `widget.log` nos testes.

- [ ] **Step 5: Verificação à mão com a combinação padrão**

Com `CLAUDE_WIDGET_HOTKEYS=1` num widget com `-DataDir` temporário e um pedido na fila: `Ctrl+Alt+Y` aprova, `Ctrl+Alt+N` nega, `Ctrl+Alt+D` liga o modo. Se não der (sem tela), anote no ledger para a verificação pós-merge.

- [ ] **Step 6: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 tests/widget.Tests.ps1
git commit -m "feat: opt-in global hotkeys to approve, deny and toggle do not disturb

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Release 2.3.0

**Files:**
- Modify: `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, `README.md`, `README.pt-BR.md`

- [ ] **Step 1: CHANGELOG**

Logo depois de `# Changelog` e da linha em branco:

```markdown
## 2.3.0 (2026-10-08)

- **Diff on the card.** The permission card of an `Edit`, `MultiEdit` or `Write` shows what changes: removed lines in red, added lines in green (up to 14 lines).
- **Always allow.** The permission card offers buttons that approve and also save one of the rules Claude Code itself suggests, showing the rule and where it is saved (this session, this project, all projects...). Only rules that allow, the modes below "bypass permissions" and folders are offered; the widget never saves anything Claude Code did not suggest.
- **Global hotkeys (off by default).** Set `CLAUDE_WIDGET_HOTKEYS=1` to approve (`Ctrl+Alt+Y`), deny (`Ctrl+Alt+N`) and toggle "do not disturb" (`Ctrl+Alt+D`) from any window. Change the keys with `CLAUDE_WIDGET_KEY_APPROVE`, `CLAUDE_WIDGET_KEY_DENY` and `CLAUDE_WIDGET_KEY_DND`.
```

- [ ] **Step 2: Rodar e ver falhar**

Run: a suíte. Esperado: `plugin.json version matches the latest CHANGELOG entry` FAIL. Total: 210 passed, 1 failed.

- [ ] **Step 3: Versão e READMEs**

`plugin.json`: `"version": "2.2.1"` → `"version": "2.3.0"`.

`README.md` (e o equivalente em `README.pt-BR.md`):
- Depois da imagem `permission.png` do topo, a imagem `edit.png` (`<img src="docs/images/en/edit.png" width="420" alt="Permission card of an Edit with the diff and two Always allow buttons">`; pt: `docs/images/pt/edit.png`).
- Na tabela "How to use it", na linha do pedido de permissão, acrescentar: `For an **Edit** or **Write** the card shows the diff. **Always allow...** approves and saves the rule shown on the button (this session, this project or all projects); it only offers rules Claude Code itself suggested.` (pt: `Num **Edit** ou **Write**, o cartão mostra o diff. **Sempre permitir...** aprova e grava a regra do botão (nesta sessão, neste projeto ou em todos os projetos); só oferece regras que o próprio Claude Code sugeriu.`)
- Na tabela de configuração (`Settings` / `Configuração`), quatro linhas: `CLAUDE_WIDGET_HOTKEYS` (padrão: desligado; `1` liga os atalhos globais), `CLAUDE_WIDGET_KEY_APPROVE` (`Ctrl+Alt+Y`), `CLAUDE_WIDGET_KEY_DENY` (`Ctrl+Alt+N`), `CLAUDE_WIDGET_KEY_DND` (`Ctrl+Alt+D`), com uma frase: `While on, those key combinations stop working in other programs, and Approve/Deny act on the permission card on screen without you looking at it.` (pt: `Enquanto ligados, essas combinações deixam de funcionar nos outros programas, e Aprovar/Negar agem no cartão de permissão que estiver na tela, sem você olhar.`).
- Na seção `Security` / `Segurança`: `**Always allow** saves a permanent rule: the button shows the rule and where it goes, and the widget only saves rules Claude Code itself suggested for that request (never rules that remove yours, nor "bypass permissions").` (pt equivalente).

- [ ] **Step 4: Rodar e ver passar; commit**

Run: a suíte. Esperado: 211 passed, 0 failed.

```bash
git add CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json README.md README.pt-BR.md
git commit -m "docs: release 2.3.0

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Verificação pós-merge (com o usuário)**

Depois de instalar a 2.3.0: (1) um `Edit` de verdade mostra o diff certo; (2) **Sempre permitir** num pedido de `Bash`/`Edit` grava a regra (conferir `settings.local.json` ou a mesma ação passar sem cartão na sessão) e o Claude Code não reclama do campo `behavior`; (3) com `CLAUDE_WIDGET_HOTKEYS=1` no `settings.json`, os atalhos padrão aprovam, negam e ligam o "não perturbe".
