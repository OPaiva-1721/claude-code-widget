# Renomear o plugin para `opaiva-code-widget`: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** o plugin passa a se chamar `opaiva-code-widget` (versão 2.0.0), volta a passar em `claude plugin validate` no Claude Code ≥ 2.1.292 e o CI deixa de precisar de `continue-on-error`.

**Architecture:** troca de nome mecânica: pasta do plugin, manifestos, caminhos em testes e ferramentas, READMEs, changelog e CI. Duas regras novas no `tests/repo.Tests.ps1` protegem o resultado: o nome do plugin não pode parecer da Anthropic, e o id antigo só aparece nos READMEs dentro da seção de migração, com a desinstalação antes da instalação.

**Tech Stack:** Windows PowerShell 5.1, Pester ≥ 5.5 (6.2.0 instalado), GitHub Actions, Claude Code CLI ≥ 2.1.292 para validar.

**Spec:** `docs/superpowers/specs/2026-10-07-rename-plugin-design.md`

## Global Constraints

- Nome do plugin: `opaiva-code-widget`. Nome do marketplace: continua `claude-code-widget`. Repositório: continua `OPaiva-1721/claude-code-widget`.
- Comando de instalação: `claude plugin install opaiva-code-widget@claude-code-widget`.
- `displayName` e título dos READMEs: continuam "Claude Code Widget".
- Versão: `2.0.0`, no `plugin.json` e no topo do `CHANGELOG.md`.
- O prefixo interno do mutex `Local\ClaudeCodeWidget-` **não muda**, e o teste fixado do mutex fica igual.
- Nenhum comportamento do hook ou do widget muda.
- Todo `.ps1` continua só com ASCII.
- Branch: `rename/opaiva-code-widget`. Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. **O README ainda manda instalar ou atualizar pelo id antigo fora da seção de migração.** Quem seguir o comando fica preso na 1.1.1. Coberto na Task 2: o id antigo só pode aparecer na seção "2.0.0".
2. **A migração manda instalar o novo antes de desinstalar o antigo.** Isso deixa dois widgets e dois hooks em cada pedido. Coberto na Task 2: a desinstalação precisa vir antes da instalação no texto.
3. **Troca de nome pela metade** (pasta, `marketplace.json` e `plugin.json` com nomes diferentes). A instalação falha ou pega a pasta errada. Coberto na Task 1: o nome e a pasta da entrada do marketplace precisam bater com o `plugin.json`.
4. **O CLI local é mais antigo que o 2.1.292 e não aplica a regra**, então um nome inválido passaria na máquina de quem desenvolve. Coberto na Task 1: regra local de nome reservado.
5. **A pasta de dados citada no README não é a pasta real.** Quem for olhar logs não acha os arquivos. Verificado na checagem pós-merge: o caminho real em `installed_plugins.json` e na pasta `plugins\data`.

---

### Task 1: Renomear o plugin (pasta, manifestos, caminhos)

**Files:**
- Move: `plugins/claude-code-widget/` → `plugins/opaiva-code-widget/` (`git mv`)
- Modify: `plugins/opaiva-code-widget/.claude-plugin/plugin.json` (`name`)
- Modify: `.claude-plugin/marketplace.json` (`plugins[0].name`, `plugins[0].source`)
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1`, `hook.ps1`, `widget.ps1` (comentário de cabeçalho; pasta de dados de reserva em `hook.ps1`/`widget.ps1`)
- Modify (caminhos): `tests/common.Tests.ps1`, `tests/hook.Tests.ps1`, `tests/hook.e2e.Tests.ps1`, `tests/helpers/HookHarness.ps1`, `tests/repo.Tests.ps1`, `tests/widget.Tests.ps1`, `tools/render-screenshots.ps1`
- Test: `tests/repo.Tests.ps1`

**Interfaces:**
- Consumes: nada.
- Produces: pasta `plugins/opaiva-code-widget/`, usada pela Task 2 nos READMEs e no workflow.

- [ ] **Step 1: Escrever as regras novas em `tests/repo.Tests.ps1`**

Logo antes do comentário `# Installed copies only update when the version number changes`, insira:

```powershell
    # Claude Code 2.1.292+ rejects third-party plugin names that pass as Anthropic's own and warns
    # about any "claude" in a plugin name. A local CLI may be older and not check, so check here too.
    It 'marketplace plugin names are not reserved for Anthropic' {
        $market = [IO.File]::ReadAllText((Join-Path $repo '.claude-plugin\marketplace.json')) | ConvertFrom-Json
        foreach ($entry in @($market.plugins)) {
            $entry.name | Should -Not -Match 'claude|anthropic|cc-plugin-'
        }
    }

    # A half-done rename (folder, marketplace entry and plugin.json disagreeing) breaks installs
    It 'each marketplace entry matches its plugin folder and plugin.json name' {
        $market = [IO.File]::ReadAllText((Join-Path $repo '.claude-plugin\marketplace.json')) | ConvertFrom-Json
        foreach ($entry in @($market.plugins)) {
            $manifest = Join-Path (Join-Path $repo $entry.source) '.claude-plugin\plugin.json'
            $manifest | Should -Exist
            $plugin = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
            $entry.name | Should -BeExactly $plugin.name
            Split-Path -Leaf $entry.source | Should -BeExactly $plugin.name
        }
    }

```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: só `marketplace plugin names are not reserved for Anthropic` FAIL (`claude-code-widget` casa com `claude`). `each marketplace entry matches ...` PASS: hoje os três nomes batem. Total: 77 passed, 1 failed.

- [ ] **Step 3: Mover a pasta e trocar os nomes nos manifestos**

```bash
git mv plugins/claude-code-widget plugins/opaiva-code-widget
```

Em `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, troque `"name": "claude-code-widget",` por `"name": "opaiva-code-widget",`. O resto, incluindo `displayName`, `repository` e `version`, fica igual.

Em `.claude-plugin/marketplace.json`, só a entrada do plugin muda; o `"name"` da linha 2, que é o do marketplace, fica `claude-code-widget`:

```json
    {
      "name": "opaiva-code-widget",
      "source": "./plugins/opaiva-code-widget",
```

- [ ] **Step 4: Trocar caminhos e textos internos**

Rode com Python, a partir da raiz do repositório. O script mostra quantas trocas fez em cada arquivo:

```bash
python - <<'EOF'
import io
edits = {
  'tests/common.Tests.ps1': [('plugins/claude-code-widget/', 'plugins/opaiva-code-widget/'), ('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'tests/hook.Tests.ps1': [('plugins/claude-code-widget/', 'plugins/opaiva-code-widget/'), ('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'tests/hook.e2e.Tests.ps1': [('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'tests/helpers/HookHarness.ps1': [('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'tests/repo.Tests.ps1': [('plugins\\claude-code-widget\\', 'plugins\\opaiva-code-widget\\')],
  'tests/widget.Tests.ps1': [('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'tools/render-screenshots.ps1': [('plugins\\claude-code-widget\\scripts', 'plugins\\opaiva-code-widget\\scripts')],
  'plugins/opaiva-code-widget/scripts/common.ps1': [('# claude-code-widget:', '# opaiva-code-widget:')],
  'plugins/opaiva-code-widget/scripts/hook.ps1': [('# claude-code-widget:', '# opaiva-code-widget:'), ("'.claude\\claude-code-widget'", "'.claude\\opaiva-code-widget'")],
  'plugins/opaiva-code-widget/scripts/widget.ps1': [('# claude-code-widget:', '# opaiva-code-widget:'), ("'.claude\\claude-code-widget'", "'.claude\\opaiva-code-widget'")],
}
for path, pairs in edits.items():
    s = open(path, encoding='ascii', newline='').read()
    for old, new in pairs:
        n = s.count(old)
        assert n > 0, (path, old)
        s = s.replace(old, new)
        print(f'{path}: {n}x {old!r}')
    open(path, 'w', encoding='ascii', newline='').write(s)
EOF
```

Esperado: uma linha por troca, todas com contagem ≥ 1, e nenhum `AssertionError`.

- [ ] **Step 5: Conferir o que sobrou do nome antigo**

Run (Bash): `git grep -n "claude-code-widget" -- plugins tests tools .claude-plugin`
Esperado, exatamente estas ocorrências e nenhuma outra:
- `.claude-plugin/marketplace.json:2` — `"name": "claude-code-widget",` (nome do marketplace)
- `plugins/opaiva-code-widget/.claude-plugin/plugin.json` — `"repository": "https://github.com/OPaiva-1721/claude-code-widget"`
- `tests/common.Tests.ps1` — duas linhas com o caminho literal do teste fixado do mutex (`...\plugins\data\claude-code-widget-claude-code-widget` e a versão em maiúsculas)

- [ ] **Step 6: Rodar tudo e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: 78 passed, 0 failed (os 76 anteriores mais as 2 regras novas).

- [ ] **Step 7: Validar com um Claude Code ≥ 2.1.292**

O `claude` instalado na máquina pode ser mais antigo e não aplicar a regra. Use o CLI do scratchpad, que é o mesmo do CI:

```powershell
$cc = '<scratchpad>\cc-new'   # pasta com node_modules\@anthropic-ai\claude-code instalado
if (-not (Test-Path "$cc\node_modules\.bin\claude.cmd")) {
    npm install --prefix $cc @anthropic-ai/claude-code --no-audit --no-fund
    Push-Location "$cc\node_modules\@anthropic-ai\claude-code"; node install.cjs; Pop-Location
}
$env:CLAUDE_CONFIG_DIR = "$cc\cfg"; New-Item -ItemType Directory -Force $env:CLAUDE_CONFIG_DIR | Out-Null
& "$cc\node_modules\.bin\claude.cmd" --version
& "$cc\node_modules\.bin\claude.cmd" plugin validate .
& "$cc\node_modules\.bin\claude.cmd" plugin validate plugins/opaiva-code-widget
```

Esperado: versão ≥ 2.1.292 e `Validation passed` nos dois, sem erros. (`<scratchpad>` é a pasta de scratchpad da sessão. O `node install.cjs` existe porque o npm local pode bloquear o script de pós-instalação do pacote.)

- [ ] **Step 8: Commit**

```bash
git add -A plugins .claude-plugin tests tools
git commit -m "refactor: rename the plugin to opaiva-code-widget

Claude Code 2.1.292+ reserves plugin names starting with \"claude-\".
The marketplace keeps the name claude-code-widget.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: READMEs, changelog, versão 2.0.0 e CI

**Files:**
- Modify: `README.md`, `README.pt-BR.md`
- Modify: `CHANGELOG.md`
- Modify: `plugins/opaiva-code-widget/.claude-plugin/plugin.json` (`version`)
- Modify: `.github/workflows/test.yml`
- Test: `tests/repo.Tests.ps1`

**Interfaces:**
- Consumes: pasta `plugins/opaiva-code-widget/` (Task 1).
- Produces: nada para outras tasks.

- [ ] **Step 1: Escrever a regra dos READMEs em `tests/repo.Tests.ps1`**

No bloco `BeforeDiscovery`, depois da linha que define `$workflows`, acrescente:

```powershell
    $readmes = @('README.md', 'README.pt-BR.md') | ForEach-Object { @{ name = $_; path = Join-Path $repo $_ } }
```

Logo antes do comentário `# Installed copies only update when the version number changes`, insira:

```powershell
    # After the rename the old plugin id only belongs in the migration steps ("2.0.0" section), and
    # there the old plugin is uninstalled before the new one is installed (both at once = two widgets)
    It '<name> uses the old plugin id only in the 2.0.0 section, uninstalling first' -ForEach $readmes {
        $section = ''
        $outside = @()
        $migration = New-Object System.Collections.ArrayList
        foreach ($line in [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)) {
            if ($line -match '^#{2,3} (.+)$') { $section = $Matches[1] }
            if ($section -match '2\.0\.0') { [void]$migration.Add($line) }
            elseif ($line -match 'claude-code-widget@claude-code-widget') { $outside += $line }
        }
        $outside | Should -BeNullOrEmpty
        $text = $migration -join "`n"
        $uninstall = $text.IndexOf('claude plugin uninstall claude-code-widget@claude-code-widget')
        $install = $text.IndexOf('claude plugin install opaiva-code-widget@claude-code-widget')
        $uninstall | Should -BeGreaterOrEqual 0
        $install | Should -BeGreaterThan $uninstall
    }

```

- [ ] **Step 2: Subir a versão primeiro**

Em `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, troque `"version": "1.1.1",` por `"version": "2.0.0",`.

- [ ] **Step 3: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: FAIL em `README.md uses the old plugin id only in the 2.0.0 section...`, em `README.pt-BR.md uses the old plugin id...` (as duas listam as linhas de instalar/atualizar/desinstalar com o id antigo) e em `plugin.json version matches the latest CHANGELOG entry` (esperado `2.0.0`, o changelog diz `1.1.1`). Todo o resto PASS.

- [ ] **Step 4: Atualizar os comandos e caminhos nos dois READMEs**

Rode a partir da raiz. Primeiro as trocas globais, depois a inserção da seção nova, que contém o id antigo de propósito:

```bash
python - <<'EOF'
for path in ('README.md', 'README.pt-BR.md'):
    s = open(path, encoding='utf-8', newline='').read()
    for old, new in [('claude-code-widget@claude-code-widget', 'opaiva-code-widget@claude-code-widget'),
                     ('plugins/claude-code-widget', 'plugins/opaiva-code-widget'),
                     ('data\\claude-code-widget-claude-code-widget', 'data\\opaiva-code-widget-claude-code-widget')]:
        print(path, s.count(old), 'x', old)
        s = s.replace(old, new)
    open(path, 'w', encoding='utf-8', newline='').write(s)
EOF
```

Esperado: em cada README, `claude-code-widget@claude-code-widget` 4x (instalar, `/plugin install`, atualizar, desinstalar), `plugins/claude-code-widget` 2x (validate e `plugin.json` na seção de desenvolvimento), `data\claude-code-widget-claude-code-widget` 1x.

- [ ] **Step 5: Inserir a seção de migração**

Em `README.md`, imediatamente antes da linha `## How to use it`, insira (com uma linha em branco antes de `## How to use it`):

````markdown
### Renamed in 2.0.0

Up to version 1.1.1 the plugin was called `claude-code-widget`. Claude Code now reserves plugin names that start with `claude-` for Anthropic's own plugins, so from 2.0.0 on it is `opaiva-code-widget`. The marketplace keeps its name. If you have the old plugin, `plugin update` no longer finds new versions. Switch once:

1. **Uninstall the old plugin first.** With both installed, every request shows up in two widgets.

   ```powershell
   claude plugin uninstall claude-code-widget@claude-code-widget
   ```

2. Close the old widget: **right-click → Close widget**.
3. Install the new one:

   ```powershell
   claude plugin marketplace update claude-code-widget
   claude plugin install opaiva-code-widget@claude-code-widget
   ```

4. Start a new Claude Code session, or run `/reload-plugins`.

The widget starts in the default corner again, because the new name comes with a new data folder.

````

Em `README.pt-BR.md`, imediatamente antes da linha `## Como usar`, insira:

````markdown
### Renomeado na 2.0.0

Até a versão 1.1.1 o plugin se chamava `claude-code-widget`. O Claude Code agora reserva os nomes de plugin que começam com `claude-` para os plugins da própria Anthropic, então a partir da 2.0.0 ele se chama `opaiva-code-widget`. O marketplace continua com o mesmo nome. Se você tem o plugin antigo, o `plugin update` não encontra mais versões novas. Faça a troca uma vez:

1. **Desinstale o plugin antigo primeiro.** Com os dois instalados, cada pedido aparece em dois widgets.

   ```powershell
   claude plugin uninstall claude-code-widget@claude-code-widget
   ```

2. Feche o widget antigo: **botão direito → Fechar widget**.
3. Instale o novo:

   ```powershell
   claude plugin marketplace update claude-code-widget
   claude plugin install opaiva-code-widget@claude-code-widget
   ```

4. Abra uma sessão nova do Claude Code ou rode `/reload-plugins`.

O widget volta a abrir no canto padrão, porque o nome novo vem com uma pasta de dados nova.

````

- [ ] **Step 6: Entrada no `CHANGELOG.md`**

Logo depois da linha `# Changelog` e da linha em branco que vem em seguida, insira (use a data do dia):

```markdown
## 2.0.0 (2026-10-07)

- **Renamed to `opaiva-code-widget`.** Claude Code 2.1.292 and later reserve plugin names that start with `claude-` for Anthropic's own plugins. Install with `claude plugin install opaiva-code-widget@claude-code-widget`; the marketplace keeps its name. If you have the old `claude-code-widget` plugin, follow [Renamed in 2.0.0](README.md#renamed-in-200) and uninstall it first. After the switch the widget starts in the default corner.

```

- [ ] **Step 7: CI sem exceções**

Em `.github/workflows/test.yml`, substitua o trecho dos passos de validação:

```yaml
      # One command per step: a PowerShell step only fails on its last command's exit code.
      # continue-on-error: since Claude Code 2.1.292 the name "claude-code-widget" is reserved
      # (third-party names cannot start with "claude-"). Installing still works; the plugin gets a
      # new name in its own change, and then these two lines go away.
      - name: Validate marketplace
        continue-on-error: true
        run: claude plugin validate .
      - name: Validate plugin
        continue-on-error: true
        run: claude plugin validate plugins/claude-code-widget
```

por:

```yaml
      # One command per step: a PowerShell step only fails on its last command's exit code
      - name: Validate marketplace
        run: claude plugin validate .
      - name: Validate plugin
        run: claude plugin validate plugins/opaiva-code-widget
```

- [ ] **Step 8: Rodar tudo e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: 80 passed, 0 failed (78 da Task 1 mais as 2 regras de README, uma por arquivo; a regra de versão volta a passar).

Run (Bash): `git grep -n "claude-code-widget@claude-code-widget" -- README.md README.pt-BR.md`
Esperado: só as linhas dentro das seções "Renamed in 2.0.0" e "Renomeado na 2.0.0" (uma por README, o comando `uninstall`).

- [ ] **Step 9: Commit**

```bash
git add README.md README.pt-BR.md CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json .github/workflows/test.yml tests/repo.Tests.ps1
git commit -m "docs: migration steps for the rename; release 2.0.0; strict plugin validation in CI

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Checagem pós-merge (na máquina do usuário)

Depois do push, do CI verde (os passos `Validate marketplace` e `Validate plugin` precisam passar **sem** `continue-on-error`) e do merge no `main`, siga a seção "Renamed in 2.0.0" do README ao pé da letra:

1. `claude plugin uninstall claude-code-widget@claude-code-widget`
2. Fechar o widget antigo (botão direito → Fechar widget).
3. `claude plugin marketplace update claude-code-widget`, depois `claude plugin install opaiva-code-widget@claude-code-widget`
4. `/reload-plugins`

Conferir:
- `claude plugin list` mostra só `opaiva-code-widget@claude-code-widget`, versão 2.0.0;
- em `%USERPROFILE%\.claude\plugins\installed_plugins.json`, o `installPath` termina em `cache\claude-code-widget\opaiva-code-widget\2.0.0`;
- existe `%USERPROFILE%\.claude\plugins\data\opaiva-code-widget-claude-code-widget\`, a pasta citada no README;
- roda exatamente um processo `widget.ps1`, vindo do `installPath`;
- um pedido de permissão passa pelo widget, com `-> allow` no `hook.log` da pasta nova.
