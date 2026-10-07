# Código comum e testes automatizados: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** juntar o código duplicado de `hook.ps1`/`widget.ps1` num `common.ps1` e cobrir o plugin com uma suíte Pester 5 que roda localmente e no GitHub Actions, sem mudar nenhum comportamento visível (versão 1.1.1).

**Architecture:** `common.ps1` só define funções e é carregado com dot-source pelos dois scripts. O `hook.ps1` passa a ter o roteamento numa função `Invoke-Hook` que devolve o JSON de saída, e uma proteção `return` no fim permite carregá-lo nos testes sem executar nada. Os testes de ponta a ponta rodam o `hook.ps1` como processo real contra uma pasta de dados temporária e são escritos **antes** do refactor, como testes de caracterização.

**Tech Stack:** Windows PowerShell 5.1, WPF, Pester ≥ 5.5, GitHub Actions (`windows-latest`).

**Spec:** `docs/superpowers/specs/2026-10-07-shared-code-and-tests-design.md`

## Global Constraints

- Runtime: **Windows PowerShell 5.1** (`powershell.exe`). Nada de recursos exclusivos do PowerShell 7 (`??`, `?.`, `&&`, ternário).
- **Todo arquivo `.ps1` (plugin, `tools/` e `tests/`) só com ASCII.** Nos testes, caracteres acentuados são montados com `[char]0x00E7` etc., nunca digitados.
- Texto da interface fica só no `strings.json` (UTF-8). Os scripts leem esse arquivo explicitamente como UTF-8.
- Pester ≥ **5.5.0**, só para desenvolvimento: o plugin instalado não depende dele.
- O nome do mutex deve continuar idêntico ao da 1.1.0: `Get-MutexName 'C:\Users\Test\.claude\plugins\data\claude-code-widget-claude-code-widget'` = `Local\ClaudeCodeWidget-e163331b644e`.
- O hook **nunca** imprime nada em `Stop`, `UserPromptSubmit` e `SessionStart`.
- Os testes nunca tocam a pasta de dados real do plugin: usam pastas temporárias e definem `CLAUDE_PLUGIN_DATA`.
- Versão final: `1.1.1` no `plugin.json` e no `CHANGELOG.md`.
- Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Branch: `refactor/shared-code-and-tests`.

## Review Focus

1. **Saída solta dentro de `Invoke-Hook`.** Qualquer valor não capturado vai para o stdout e o Claude Code recebe JSON inválido ou texto no contexto. O esperado é que o stdout seja exatamente o JSON da decisão, ou vazio. Coberto na Task 4: comparação exata do stdout em allow/deny e stdout vazio em `SessionStart`, `Stop`, `UserPromptSubmit` e `-EnsureWidget`.
2. **Stdin vazio ou que não é JSON.** O esperado é sair com código 0, sem imprimir nada, para o Claude Code seguir o fluxo normal. Coberto na Task 4.
3. **Acentos no input e nas respostas.** Um comando com `ção` precisa chegar intacto ao widget (arquivo UTF-8), e a resposta precisa voltar escapada em ASCII sem perder o texto. Coberto na Task 4.
4. **Widget ligado às funções de fila com argumentos errados.** Os erros do timer só vão para o `widget.log`, então o widget ficaria parado em "sem pedidos" sem nenhum aviso. Coberto na Task 6: um teste abre o widget de verdade e confere que ele limpa pedidos órfãos e avisos vencidos.
5. **Widget da 1.1.0 ainda aberto quando chega o hook da 1.1.1.** O hook precisa enxergar o widget antigo (mesmo mutex) e trocá-lo. O teste de mutex fixado está na Task 2. A troca pelo caminho do script é código que não muda e fica na checagem manual da Task 7.

---

### Task 1: Ferramenta de testes e regras do repositório

**Files:**
- Create: `tools/test.ps1`
- Create: `tests/repo.Tests.ps1`
- Create: `.gitignore`

**Interfaces:**
- Consumes: nada.
- Produces: `powershell -NoProfile -File tools\test.ps1 [-CI] [-ExcludeTag <string[]>]`. Sai com código diferente de zero se algum teste falhar. Com `-CI`, grava `testResults.xml` na raiz do repositório.

- [ ] **Step 1: Instalar o Pester 5 (uma vez por máquina)**

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
Get-Module -ListAvailable Pester | Select-Object Version
```

Esperado: aparece uma versão ≥ 5.5 ao lado da 3.4.0, que vem com o Windows.

- [ ] **Step 2: Criar `tools/test.ps1`**

```powershell
# Runs the automated tests in tests\ with Pester 5, on Windows PowerShell 5.1 (the plugin's runtime).
#   powershell -NoProfile -File tools\test.ps1                      all tests, detailed output
#   powershell -NoProfile -File tools\test.ps1 -CI                  also writes testResults.xml (GitHub Actions)
#   powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop  skips the tests that open widget windows
# Exits with a non-zero code when a test fails.
param([switch]$CI, [string[]]$ExcludeTag = @())
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) {
    Write-Host 'Pester 5.5 or later is required. Install it once with:'
    Write-Host '  Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $repo 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $repo 'testResults.xml'
}
Invoke-Pester -Configuration $config
```

- [ ] **Step 3: Criar `.gitignore`**

```
testResults.xml
```

- [ ] **Step 4: Criar `tests/repo.Tests.ps1`**

```powershell
# Repository rules: ASCII-only scripts, valid JSON manifests, plugin version matches the changelog.
BeforeDiscovery {
    $repo = Split-Path -Parent $PSScriptRoot
    $scripts = @(Get-ChildItem -Path (Join-Path $repo 'plugins'), (Join-Path $repo 'tools'), (Join-Path $repo 'tests') -Filter '*.ps1' -File -Recurse |
        ForEach-Object { @{ name = $_.FullName.Substring($repo.Length + 1); path = $_.FullName } })
    $manifests = @('.claude-plugin\marketplace.json', 'plugins\claude-code-widget\.claude-plugin\plugin.json',
        'plugins\claude-code-widget\hooks\hooks.json', 'plugins\claude-code-widget\scripts\strings.json') |
        ForEach-Object { @{ name = $_; path = Join-Path $repo $_ } }
}

Describe 'repository rules' {
    BeforeAll { $repo = Split-Path -Parent $PSScriptRoot }

    # Windows PowerShell 5.1 reads BOM-less files as ANSI: any non-ASCII byte turns into garbage
    It '<name> is ASCII-only' -ForEach $scripts {
        $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($path))
        $text | Should -Not -Match '[^\x00-\x7F]'
    }

    It '<name> is valid JSON' -ForEach $manifests {
        { [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json } | Should -Not -Throw
    }

    # Installed copies only update when the version number changes
    It 'plugin.json version matches the latest CHANGELOG entry' {
        $plugin = [IO.File]::ReadAllText((Join-Path $repo 'plugins\claude-code-widget\.claude-plugin\plugin.json')) | ConvertFrom-Json
        $latest = Select-String -LiteralPath (Join-Path $repo 'CHANGELOG.md') -Pattern '^## (\d+\.\d+\.\d+)' | Select-Object -First 1
        $latest | Should -Not -BeNullOrEmpty
        $latest.Matches[0].Groups[1].Value | Should -Be $plugin.version
    }
}
```

- [ ] **Step 5: Rodar e conferir que passa**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: 10 testes, todos PASS (5 ASCII: `hook.ps1`, `widget.ps1`, `render-screenshots.ps1`, `test.ps1`, `repo.Tests.ps1`; 4 JSON; 1 versão), exit code 0.

- [ ] **Step 6: Conferir que a regra de ASCII realmente pega erro**

Crie um arquivo descartável com um byte não-ASCII, rode e apague:

```powershell
[IO.File]::WriteAllText("$PWD\tools\ascii-probe.ps1", "# " + [char]0x00E7, (New-Object Text.UTF8Encoding $false))
powershell -NoProfile -File tools\test.ps1
Remove-Item tools\ascii-probe.ps1
powershell -NoProfile -File tools\test.ps1
```

Esperado: na primeira execução, `tools\ascii-probe.ps1 is ASCII-only` FAIL e exit code diferente de 0. Na segunda, tudo PASS.

- [ ] **Step 7: Commit**

```bash
git add .gitignore tools/test.ps1 tests/repo.Tests.ps1
git commit -m "test: Pester 5 runner and repository rules

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `common.ps1`, funções básicas

**Files:**
- Create: `plugins/claude-code-widget/scripts/common.ps1`
- Create: `tests/common.Tests.ps1`

**Interfaces:**
- Consumes: `strings.json` (já existe, mesma pasta).
- Produces (usadas nas Tasks 3–6):
  - `Get-Utf8NoBom` → `System.Text.UTF8Encoding` sem BOM
  - `Get-MutexName([string]$Dir)` → `string`
  - `Write-JsonAtomic([string]$Path, $Object)` → nada (profundidade 10, UTF-8 sem BOM, `.tmp` + rename)
  - `Resolve-Lang([string]$Requested)` → `'pt'` | `'en'`
  - `Get-Strings([string]$Lang)` → `PSCustomObject` com as chaves do `strings.json`
  - `Get-NowMs` → `int64` (ms Unix UTC)

- [ ] **Step 1: Escrever os testes que falham em `tests/common.Tests.ps1`**

```powershell
# Unit tests for plugins/claude-code-widget/scripts/common.ps1
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\claude-code-widget\scripts\common.ps1')
}

Describe 'Get-MutexName' {
    # Pinned: hook.ps1 finds a widget started by an older version through this exact name
    It 'matches the name computed by version 1.1.0' {
        Get-MutexName 'C:\Users\Test\.claude\plugins\data\claude-code-widget-claude-code-widget' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
    It 'ignores letter case in the path' {
        Get-MutexName 'C:\USERS\TEST\.CLAUDE\PLUGINS\DATA\CLAUDE-CODE-WIDGET-CLAUDE-CODE-WIDGET' |
            Should -BeExactly 'Local\ClaudeCodeWidget-e163331b644e'
    }
}

Describe 'Write-JsonAtomic' {
    BeforeAll { $accented = 'a' + [char]0x00E7 + [char]0x00E3 + 'o' }

    It 'writes UTF-8 without BOM, keeps accents and leaves no .tmp' {
        $path = Join-Path $TestDrive 'x.json'
        Write-JsonAtomic $path ([ordered]@{ text = $accented })
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json).text | Should -BeExactly $accented
        "$path.tmp" | Should -Not -Exist
    }
    It 'keeps objects nested deeper than 5 levels' {
        $path = Join-Path $TestDrive 'deep.json'
        Write-JsonAtomic $path @{ a = @{ b = @{ c = @{ d = @{ e = @{ f = 'deep' } } } } } }
        ([IO.File]::ReadAllText($path) | ConvertFrom-Json).a.b.c.d.e.f | Should -Be 'deep'
    }
}

Describe 'Resolve-Lang' {
    It 'maps <requested> to <expected>' -ForEach @(
        @{ requested = 'pt'; expected = 'pt' }
        @{ requested = 'PT'; expected = 'pt' }
        @{ requested = 'en'; expected = 'en' }
        @{ requested = 'es'; expected = 'en' }
    ) {
        Resolve-Lang $requested | Should -BeExactly $expected
    }
    It 'falls back to the Windows display language when empty' {
        $ui = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName
        $expected = if ($ui -eq 'pt') { 'pt' } else { 'en' }
        Resolve-Lang '' | Should -BeExactly $expected
    }
}

Describe 'Get-Strings' {
    It 'pt and en define the same keys' {
        $en = @((Get-Strings 'en').PSObject.Properties.Name | Sort-Object)
        $pt = @((Get-Strings 'pt').PSObject.Properties.Name | Sort-Object)
        $en.Count | Should -BeGreaterThan 0
        ($pt -join ',') | Should -BeExactly ($en -join ',')
    }
    It 'reads strings.json as UTF-8' {
        (Get-Strings 'pt').deniedMessage | Should -Match ([string][char]0x00E1)
    }
}

Describe 'Get-NowMs' {
    It 'returns the current Unix time in milliseconds' {
        $expected = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        [math]::Abs((Get-NowMs) - $expected) | Should -BeLessThan 5000
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: `common.Tests.ps1` FAIL no `BeforeAll`, porque o `common.ps1` não existe.

- [ ] **Step 3: Criar `plugins/claude-code-widget/scripts/common.ps1`**

```powershell
# claude-code-widget: helpers shared by hook.ps1 and widget.ps1 (Windows PowerShell 5.1).
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
```

`$PSScriptRoot` dentro de uma função aponta para a pasta do arquivo onde a função foi definida (`scripts\`), mesmo com o arquivo carregado por dot-source a partir de outra pasta. Isso foi verificado no PowerShell 5.1.

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: todos PASS, incluindo `common.ps1 is ASCII-only`, que é descoberto automaticamente.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-code-widget/scripts/common.ps1 tests/common.Tests.ps1
git commit -m "feat: common.ps1 with shared mutex, JSON, language and time helpers

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `common.ps1`, leitura da fila

**Files:**
- Modify: `plugins/claude-code-widget/scripts/common.ps1` (acrescentar no fim)
- Modify: `tests/common.Tests.ps1` (acrescentar no fim)

**Interfaces:**
- Consumes: `Get-NowMs`, `Get-Utf8NoBom` (Task 2).
- Produces (usadas pelo widget na Task 6):
  - `Get-PendingRequests([string]$Queue, [hashtable]$Cache)` → objetos de `req-*.json` vivos e sem resposta, do mais antigo para o mais novo. Apaga os vencidos e os órfãos. `$Cache` é nome do arquivo → objeto.
  - `Get-DoneNotices([string]$Queue, [hashtable]$Cache, [int64]$MaxAgeMs)` → objetos de `done-*.json` do mais novo para o mais antigo, com as propriedades extras `key` (nome do arquivo) e `file` (caminho completo). Apaga os que passaram de `$MaxAgeMs`.

- [ ] **Step 1: Acrescentar os testes que falham no fim de `tests/common.Tests.ps1`**

```powershell
Describe 'Get-PendingRequests' {
    BeforeAll {
        $deadPid = 2147483640   # no process has this id
        function New-TestRequest([string]$Queue, [string]$Id, [int64]$Created, [int]$OwnerPid = $PID, [int]$Timeout = 300) {
            $req = [ordered]@{ id = $Id; pid = $OwnerPid; kind = 'permission'; created = $Created; timeout = $Timeout; cwd = 'C:\dev\app' }
            [IO.File]::WriteAllText((Join-Path $Queue "req-$Id.json"), ($req | ConvertTo-Json -Compress))
        }
        function Get-Ids($Items) { (@($Items) | ForEach-Object { $_.id }) -join ',' }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns live requests oldest first' {
        New-TestRequest $queue 'newer' ($now - 1000)
        New-TestRequest $queue 'older' ($now - 2000)
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'older,newer'
    }
    It 'deletes expired requests' {
        New-TestRequest $queue 'old' ($now - 400 * 1000) -Timeout 300
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-old.json' | Should -Not -Exist
    }
    It 'deletes requests whose hook process is gone' {
        New-TestRequest $queue 'orphan' $now -OwnerPid $deadPid
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-orphan.json' | Should -Not -Exist
    }
    It 'skips answered requests without deleting them' {
        New-TestRequest $queue 'answered' $now
        [IO.File]::WriteAllText((Join-Path $queue 'res-answered.json'), '{"decision":"allow"}')
        @(Get-PendingRequests $queue $cache).Count | Should -Be 0
        Join-Path $queue 'req-answered.json' | Should -Exist
    }
    It 'ignores files that are not valid JSON' {
        [IO.File]::WriteAllText((Join-Path $queue 'req-bad.json'), '{not json')
        New-TestRequest $queue 'good' $now
        Get-Ids (Get-PendingRequests $queue $cache) | Should -BeExactly 'good'
    }
    It 'forgets cached requests whose file is gone' {
        New-TestRequest $queue 'gone' $now
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeTrue
        Remove-Item -LiteralPath (Join-Path $queue 'req-gone.json')
        [void](Get-PendingRequests $queue $cache)
        $cache.ContainsKey('req-gone.json') | Should -BeFalse
    }
    It 'returns nothing when the queue folder does not exist' {
        @(Get-PendingRequests (Join-Path $TestDrive 'missing') $cache).Count | Should -Be 0
    }
}

Describe 'Get-DoneNotices' {
    BeforeAll {
        $maxAge = 12 * 3600 * 1000
        function New-TestNotice([string]$Queue, [string]$Session, [int64]$Created) {
            $path = Join-Path $Queue "done-$Session-$Created.json"
            $notice = [ordered]@{ session = $Session; created = $Created; cwd = 'C:\dev\app'; message = 'hi'; hwnd = 0; kind = '' }
            [IO.File]::WriteAllText($path, ($notice | ConvertTo-Json -Compress))
            return $path
        }
    }
    BeforeEach {
        $queue = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $queue | Out-Null
        $cache = @{}
        $now = Get-NowMs
    }

    It 'returns notices newest first, with key and file' {
        [void](New-TestNotice $queue 's1' ($now - 60000))
        $newest = New-TestNotice $queue 's2' ($now - 1000)
        $list = @(Get-DoneNotices $queue $cache $maxAge)
        (($list | ForEach-Object { $_.session }) -join ',') | Should -BeExactly 's2,s1'
        $list[0].key | Should -BeExactly (Split-Path -Leaf $newest)
        Split-Path -Leaf $list[0].file | Should -BeExactly (Split-Path -Leaf $newest)
        $list[0].file | Should -Exist
    }
    It 'deletes notices older than the maximum age' {
        $stale = New-TestNotice $queue 'stale' ($now - $maxAge - 60000)
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $stale | Should -Not -Exist
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: os 9 testes novos FAIL com `The term 'Get-PendingRequests' is not recognized` (e `Get-DoneNotices`).

- [ ] **Step 3: Acrescentar no fim de `common.ps1`**

```powershell
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
```

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: todos PASS.

- [ ] **Step 5: Commit**

```bash
git add plugins/claude-code-widget/scripts/common.ps1 tests/common.Tests.ps1
git commit -m "feat: queue readers in common.ps1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Testes de ponta a ponta do hook (caracterização, antes do refactor)

Estes testes rodam contra o `hook.ps1` **atual, sem mudanças**, e precisam passar já. Eles são a rede de segurança da Task 5. Se algum falhar aqui, o problema está no teste ou no harness, não no hook. **Não altere o `hook.ps1` nesta task.**

**Files:**
- Create: `tests/helpers/HookHarness.ps1`
- Create: `tests/hook.e2e.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MutexName`, `Write-JsonAtomic`, `Get-Strings` (Task 2).
- Produces (só para testes):
  - `New-HookSandbox` → `{ Data, Queue, Hook, Mutex, MutexHeld }`. Cria a pasta temporária `ccw-e2e-<guid>` e segura o mutex dela.
  - `Remove-HookSandbox($Sandbox)`, `Close-FakeWidget($Sandbox)` (solta o mutex)
  - `New-HookEvent([string]$Name, [string]$Cwd, [hashtable]$Extra)` → evento `[ordered]` com `session_id` único
  - `Start-Hook($Sandbox, $HookInput, [hashtable]$Env, [string[]]$Arguments, [string]$RawInput)` → execução em andamento
  - `Complete-Hook($Run, [int]$TimeoutSec = 60)` → `{ ExitCode, Stdout, Stderr, Seconds }`
  - `Wait-HookRequest($Sandbox, [int]$TimeoutSec = 30)` → o `req-*.json` lido
  - `Send-WidgetResponse($Sandbox, [string]$Id, $Response)`

- [ ] **Step 1: Criar `tests/helpers/HookHarness.ps1`**

```powershell
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
        Hook      = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\plugins\claude-code-widget\scripts\hook.ps1'))
        Mutex     = New-Object System.Threading.Mutex($true, (Get-MutexName $dir))
        MutexHeld = $true
    }
}

function Remove-HookSandbox($Sandbox) {
    if ($Sandbox.MutexHeld) { $Sandbox.Mutex.ReleaseMutex() }
    $Sandbox.Mutex.Dispose()
    Remove-Item -LiteralPath $Sandbox.Data -Recurse -Force -ErrorAction SilentlyContinue
}

# "Closes the widget": hook.ps1 stops finding the mutex
function Close-FakeWidget($Sandbox) {
    $Sandbox.Mutex.ReleaseMutex()
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
    $psi.EnvironmentVariables['CLAUDE_WIDGET_AWAY_SECS'] = '100000'
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
```

- [ ] **Step 2: Criar `tests/hook.e2e.Tests.ps1`**

```powershell
# End-to-end tests: hook.ps1 as a real process, JSON in on stdin, JSON out on stdout.
BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\claude-code-widget\scripts\common.ps1')
    . (Join-Path $PSScriptRoot 'helpers\HookHarness.ps1')
    $pt = Get-Strings 'pt'
    function Get-QueueFiles($Sandbox, [string]$Filter = '*') {
        @(Get-ChildItem -LiteralPath $Sandbox.Queue -Filter $Filter -File -ErrorAction SilentlyContinue)
    }
}

Describe 'hook.ps1 end to end' {
    BeforeEach { $box = New-HookSandbox }
    AfterEach { Remove-HookSandbox $box }

    Context 'PermissionRequest' {
        BeforeAll {
            function New-BashEvent($Sandbox, [string]$Command) {
                New-HookEvent 'PermissionRequest' $Sandbox.Data @{ tool_name = 'Bash'; tool_input = @{ command = $Command } }
            }
        }

        It 'prints allow when the widget approves' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'permission'
            $req.tool | Should -Be 'Bash'
            $req.detail | Should -BeExactly 'npm test'
            Send-WidgetResponse $box $req.id @{ decision = 'allow' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
            (Get-QueueFiles $box).Count | Should -Be 0
        }
        It 'prints deny with the localized message when the widget denies' {
            $run = Start-Hook $box (New-BashEvent $box 'rm -rf build')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'deny' }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $decision = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput.decision
            $decision.behavior | Should -Be 'deny'
            $decision.message | Should -BeExactly $pt.deniedMessage
        }
        It 'prints nothing when the widget hands the request back' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            $req = Wait-HookRequest $box
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            $r = Complete-Hook $run
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It 'sends non-ASCII input to the widget intact' {
            $command = 'echo ' + [char]0x00E7 + [char]0x00E3 + 'o'
            $run = Start-Hook $box (New-BashEvent $box $command)
            $req = Wait-HookRequest $box
            $req.detail | Should -BeExactly $command
            Send-WidgetResponse $box $req.id @{ decision = 'vscode' }
            [void](Complete-Hook $run)
        }
        It 'never routes plan approval (ExitPlanMode) to the widget' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PermissionRequest' $box.Data @{ tool_name = 'ExitPlanMode'; tool_input = @{ plan = 'x' } }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
        It 'gives up within 5 s when the widget closes while waiting' {
            $run = Start-Hook $box (New-BashEvent $box 'npm test')
            [void](Wait-HookRequest $box)
            $closedAt = $run.Clock.Elapsed.TotalSeconds
            Close-FakeWidget $box
            $r = Complete-Hook $run
            $r.Stdout | Should -BeNullOrEmpty
            ($r.Seconds - $closedAt) | Should -BeLessThan 5
        }
        It 'skips the widget when the user is away' {
            $r = Complete-Hook (Start-Hook $box (New-BashEvent $box 'npm test') -Env @{ CLAUDE_WIDGET_AWAY_SECS = '0' })
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'AskUserQuestion' {
        It 'returns the answers in updatedInput and keeps the questions' {
            $question = 'Qual banco usar?'
            $answer = 'Op' + [char]0x00E7 + [char]0x00E3 + 'o B'
            $questions = @(@{ question = $question; header = 'Banco'; multiSelect = $false
                    options = @(@{ label = 'A'; description = 'a' }, @{ label = 'B'; description = 'b' }) })
            $run = Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'AskUserQuestion'; tool_input = @{ questions = $questions } })
            $req = Wait-HookRequest $box
            $req.kind | Should -Be 'question'
            $req.description | Should -BeExactly $question
            Send-WidgetResponse $box $req.id @{ decision = 'answer'; answers = @{ $question = $answer } }
            $r = Complete-Hook $run
            $r.Stdout | Should -Not -Match '[^\x00-\x7F]'
            $out = ($r.Stdout | ConvertFrom-Json).hookSpecificOutput
            $out.hookEventName | Should -Be 'PreToolUse'
            $out.permissionDecision | Should -Be 'allow'
            $out.permissionDecisionReason | Should -BeExactly $pt.answeredReason
            $out.updatedInput.answers.$question | Should -BeExactly $answer
            $out.updatedInput.questions[0].question | Should -BeExactly $question
        }
        It 'ignores PreToolUse for other tools' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'PreToolUse' $box.Data @{ tool_name = 'Bash'; tool_input = @{ command = 'ls' } }))
            $r.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box 'req-*').Count | Should -Be 0
        }
    }

    Context 'finished notices' {
        It 'Stop creates a notice and the next prompt removes it, printing nothing' {
            $stop = New-HookEvent 'Stop' $box.Data @{ last_assistant_message = 'Pronto: **testes** passaram. Veja [o log](http://x/y).' }
            $sid = $stop.session_id
            $r = Complete-Hook (Start-Hook $box $stop)
            $r.Stdout | Should -BeNullOrEmpty
            $notices = Get-QueueFiles $box "done-$sid-*.json"
            $notices.Count | Should -Be 1
            $notice = [IO.File]::ReadAllText($notices[0].FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $notice.message | Should -BeExactly 'Pronto: testes passaram. Veja o log.'
            $notice.cwd | Should -BeExactly $box.Data

            $prompt = New-HookEvent 'UserPromptSubmit' $box.Data @{ prompt = 'next' }
            $prompt.session_id = $sid
            $r2 = Complete-Hook (Start-Hook $box $prompt)
            $r2.Stdout | Should -BeNullOrEmpty
            (Get-QueueFiles $box "done-$sid-*.json").Count | Should -Be 0
        }
    }

    Context 'robustness' {
        It 'SessionStart prints nothing' {
            $r = Complete-Hook (Start-Hook $box (New-HookEvent 'SessionStart' $box.Data @{ source = 'startup' }))
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It '-EnsureWidget prints nothing when the widget is running' {
            $r = Complete-Hook (Start-Hook $box $null -Arguments @('-EnsureWidget') -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
            $r.Seconds | Should -BeLessThan 15
        }
        It 'exits quietly on input that is not JSON' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput 'not json')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
        It 'exits quietly on empty input' {
            $r = Complete-Hook (Start-Hook $box $null -RawInput '')
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -BeNullOrEmpty
        }
    }
}
```

- [ ] **Step 3: Rodar contra o hook atual e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: os 14 testes de `hook.e2e.Tests.ps1` PASS, em cerca de 30–60 s no total (cada processo do hook leva 1–2 s). Se algum falhar, corrija o **teste ou o harness**, porque o hook atual é a referência. Rode `git diff --stat plugins/` e confirme que está vazio.

- [ ] **Step 4: Commit**

```bash
git add tests/helpers/HookHarness.ps1 tests/hook.e2e.Tests.ps1
git commit -m "test: end-to-end characterization tests for hook.ps1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Refactor do `hook.ps1` (common + funções + `Invoke-Hook`)

**Files:**
- Modify: `plugins/claude-code-widget/scripts/hook.ps1`
- Create: `tests/hook.Tests.ps1`
- Create: `tests/fixtures/transcript.jsonl`

**Interfaces:**
- Consumes: `Get-Utf8NoBom`, `Get-MutexName`, `Write-JsonAtomic`, `Resolve-Lang`, `Get-Strings`, `Get-NowMs` (Task 2).
- Produces:
  - `Get-PermissionDetail($ToolInput)` → `string`
  - `New-PermissionOutput([string]$Behavior, [string]$Message)` → `[ordered]` hookSpecificOutput (`message` só em deny)
  - `New-AnswerOutput($ToolInput, $Answers, [string]$Reason)` → `[ordered]` hookSpecificOutput do PreToolUse
  - `Invoke-Hook($evt)` → `string` JSON ou `$null`
  - Assinaturas que mudam: `Save-SessionWindow([string]$sid, [string]$logTag)`, `New-Request([string]$kind, [string]$cwd, [hashtable]$fields)`
  - O hook carregado com dot-source só define funções e variáveis.

- [ ] **Step 1: Proteger o ponto de entrada (para os testes poderem carregar o arquivo)**

Em `hook.ps1`, imediatamente **antes** da linha `if ($EnsureWidget) { [void](Start-Widget); exit 0 }`, insira:

```powershell
# Loaded with dot-source (tests): stop here, only the functions above are wanted
if ($MyInvocation.InvocationName -eq '.') { return }
```

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: tudo PASS, porque os e2e continuam iguais.

- [ ] **Step 2: Criar `tests/fixtures/transcript.jsonl`** (6 linhas, exatamente assim)

```
{"type":"user","message":{"role":"user","content":"Run the tests"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First reply"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Final"},{"type":"tool_use","name":"Bash","input":{}},{"type":"text","text":"answer"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{}}]}}
not json but mentions "assistant"
```

- [ ] **Step 3: Escrever `tests/hook.Tests.ps1`**

```powershell
# Unit tests for the functions in plugins/claude-code-widget/scripts/hook.ps1. The file is
# dot-sourced: its entry point does not run.
BeforeAll {
    $savedData = $env:CLAUDE_PLUGIN_DATA
    $tmpData = Join-Path ([IO.Path]::GetTempPath()) ('ccw-unit-' + [guid]::NewGuid().ToString('N'))
    $env:CLAUDE_PLUGIN_DATA = $tmpData
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\claude-code-widget\scripts\hook.ps1')
    $fixtures = Join-Path $PSScriptRoot 'fixtures'
}
AfterAll {
    $env:CLAUDE_PLUGIN_DATA = $savedData
    Remove-Item -LiteralPath $tmpData -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'loading hook.ps1' {
    It 'defines Invoke-Hook without running the entry point' {
        Get-Command Invoke-Hook -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty
        Join-Path $tmpData 'hook.log' | Should -Not -Exist
    }
}

Describe 'Format-Snippet' {
    It 'removes code blocks' {
        Format-Snippet 'Run ```npm test``` now' | Should -BeExactly 'Run now'
    }
    It 'keeps link text and drops markdown symbols' {
        Format-Snippet '## Done: **tests** pass, see [the log](http://x/y).' | Should -BeExactly 'Done: tests pass, see the log.'
    }
    It 'cuts long text at 300 characters' {
        $out = Format-Snippet ('a' * 400)
        $out.Length | Should -Be 303
        $out | Should -BeLike '*...'
    }
    It 'returns an empty string for empty input' {
        Format-Snippet '' | Should -BeExactly ''
    }
}

Describe 'ConvertTo-AsciiJson' {
    It 'escapes non-ASCII characters and round-trips' {
        $text = 'Op' + [char]0x00E7 + [char]0x00E3 + 'o'
        $json = ConvertTo-AsciiJson ([ordered]@{ text = $text })
        $json | Should -Not -Match '[^\x00-\x7F]'
        $json | Should -Match '\\u00e7'
        ($json | ConvertFrom-Json).text | Should -BeExactly $text
    }
}

Describe 'Get-LastAssistantText' {
    It 'prefers last_assistant_message' {
        $evt = [pscustomobject]@{ last_assistant_message = 'From the event'; transcript_path = (Join-Path $fixtures 'transcript.jsonl') }
        Get-LastAssistantText $evt | Should -BeExactly 'From the event'
    }
    It 'falls back to the last assistant text in the transcript' {
        Get-LastAssistantText ([pscustomobject]@{ transcript_path = (Join-Path $fixtures 'transcript.jsonl') }) | Should -BeExactly 'Final answer'
    }
    It 'returns an empty string without message or transcript' {
        Get-LastAssistantText ([pscustomobject]@{ transcript_path = (Join-Path $tmpData 'missing.jsonl') }) | Should -BeExactly ''
    }
}

Describe 'Get-PermissionDetail' {
    It 'shows <expected> for <case>' -ForEach @(
        @{ case = 'command first'; json = '{"command":"npm test","file_path":"C:\\a.txt"}'; expected = 'npm test' }
        @{ case = 'file_path'; json = '{"file_path":"C:\\a.txt","content":"x"}'; expected = 'C:\a.txt' }
        @{ case = 'notebook_path'; json = '{"notebook_path":"C:\\n.ipynb"}'; expected = 'C:\n.ipynb' }
        @{ case = 'url'; json = '{"url":"https://example.com","prompt":"x"}'; expected = 'https://example.com' }
        @{ case = 'query'; json = '{"query":"widget docs"}'; expected = 'widget docs' }
        @{ case = 'anything else'; json = '{"pattern":"*.ps1"}'; expected = '{"pattern":"*.ps1"}' }
    ) {
        Get-PermissionDetail ($json | ConvertFrom-Json) | Should -BeExactly $expected
    }
    It 'cuts details longer than 2000 characters' {
        $out = Get-PermissionDetail ([pscustomobject]@{ command = 'x' * 2500 })
        $out.Length | Should -Be 2004
        $out | Should -BeLike '* ...'
    }
}

Describe 'New-PermissionOutput' {
    It 'allow has no message' {
        New-PermissionOutput 'allow' 'ignored' | ConvertTo-Json -Depth 5 -Compress |
            Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'
    }
    It 'deny carries the message' {
        New-PermissionOutput 'deny' 'No.' | ConvertTo-Json -Depth 5 -Compress |
            Should -BeExactly '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"No."}}}'
    }
}

Describe 'New-AnswerOutput' {
    It 'allows the tool and adds the answers to the original input' {
        $in = '{"questions":[{"question":"Which DB?","options":[{"label":"A"},{"label":"B"}]}]}' | ConvertFrom-Json
        $answers = [pscustomobject]@{ 'Which DB?' = 'B' }
        $out = (New-AnswerOutput $in $answers 'Answered').hookSpecificOutput
        $out.hookEventName | Should -Be 'PreToolUse'
        $out.permissionDecision | Should -Be 'allow'
        $out.permissionDecisionReason | Should -Be 'Answered'
        $out.updatedInput.answers.'Which DB?' | Should -Be 'B'
        $out.updatedInput.questions[0].question | Should -Be 'Which DB?'
    }
}
```

- [ ] **Step 4: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: FAIL em `loading hook.ps1` (`Invoke-Hook` não existe), `Get-PermissionDetail`, `New-PermissionOutput` e `New-AnswerOutput` (`term is not recognized`). PASS em `Format-Snippet`, `ConvertTo-AsciiJson` e `Get-LastAssistantText`, que já existem.

- [ ] **Step 5: Refatorar `hook.ps1` com estas edições, em ordem**

5a. Comentário do topo: troque

```powershell
# One script for every event; the route comes from hook_event_name:
```
por
```powershell
# One script for every event; Invoke-Hook routes on hook_event_name:
```
e troque
```powershell
# Stop/UserPromptSubmit/SessionStart never print anything (it would end up in Claude's context).
```
por
```powershell
# Stop/UserPromptSubmit/SessionStart never print anything (it would end up in Claude's context).
# Dot-sourcing this file (tests) only defines the functions; see the end of the file.
```

5b. Logo depois de `$Utf8 = New-Object System.Text.UTF8Encoding $false`, acrescente:

```powershell
. (Join-Path $PSScriptRoot 'common.ps1')
```

5c. Troque o bloco de idioma + mutex:

```powershell
$Lang = if ($env:CLAUDE_WIDGET_LANG) { $env:CLAUDE_WIDGET_LANG } else { [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
if ($Lang -ne 'pt') { $Lang = 'en' }
$S = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'strings.json'), $Utf8) | ConvertFrom-Json).$Lang

# One widget per data dir; the widget computes the same name
function Get-MutexName([string]$dir) {
    $hash = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($dir.ToLowerInvariant()))
    return 'Local\ClaudeCodeWidget-' + (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
}
$MutexName = Get-MutexName $Data
```
por
```powershell
$Lang = Resolve-Lang $env:CLAUDE_WIDGET_LANG
$S = Get-Strings $Lang

# One widget per data dir; the widget computes the same name
$MutexName = Get-MutexName $Data
```

5d. Apague a função local (agora ela vem do `common.ps1`):

```powershell
# Write to .tmp, then rename: the widget never reads a half-written file
function Write-JsonAtomic($path, $obj) {
    [IO.File]::WriteAllText("$path.tmp", ($obj | ConvertTo-Json -Depth 10 -Compress), $Utf8)
    [IO.File]::Move("$path.tmp", $path)
}

```

5e. Troque `function Save-SessionWindow([string]$sid) {` por `function Save-SessionWindow([string]$sid, [string]$logTag) {`.

5f. Em `New-Request`: troque `function New-Request([string]$kind, [hashtable]$fields) {` por `function New-Request([string]$kind, [string]$cwd, [hashtable]$fields) {`. Troque `        created = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()` por `        created = Get-NowMs` e `        cwd     = [string]$evt.cwd` por `        cwd     = $cwd`.

5g. Substitua **tudo** desde a linha `# Loaded with dot-source (tests): stop here, only the functions above are wanted` (inserida no Step 1) até o fim do arquivo por:

```powershell
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

    if ($hookEvent -eq 'SessionStart') { Write-HookLog $logTag; [void](Start-Widget); return $null }

    if ($hookEvent -eq 'UserPromptSubmit') {
        Write-HookLog $logTag
        Remove-Done $sid
        Save-SessionWindow $sid $logTag
        return $null
    }

    if ($hookEvent -eq 'Stop') {
        if (-not $sid) { return $null }
        Remove-Done $sid
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
```

- [ ] **Step 6: Conferir que não sobrou nada duplicado nem nenhuma referência antiga**

Run (Bash): `grep -nE 'function (Get-MutexName|Write-JsonAtomic|Get-NowMs)|SHA1|ConvertFrom-Json\)\.\$Lang|^ +cwd += \[string\]\$evt' plugins/claude-code-widget/scripts/hook.ps1`
Esperado: nenhuma linha. Isso confirma que não há cópia local das funções comuns, nem leitura direta do `strings.json`, e que o `New-Request` não lê mais `$evt`.

- [ ] **Step 7: Rodar tudo e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: todos PASS, ou seja, unidade do hook + os 14 e2e da Task 4 sem nenhuma mudança neles + common + repo.

- [ ] **Step 8: Commit**

```bash
git add plugins/claude-code-widget/scripts/hook.ps1 tests/hook.Tests.ps1 tests/fixtures/transcript.jsonl
git commit -m "refactor: hook.ps1 uses common.ps1 and routes through Invoke-Hook

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `widget.ps1` usa o `common.ps1`, com testes do widget real

**Files:**
- Modify: `plugins/claude-code-widget/scripts/widget.ps1`
- Create: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Get-MutexName`, `Write-JsonAtomic`, `Resolve-Lang`, `Get-Strings`, `Get-NowMs` (Task 2); `Get-PendingRequests`, `Get-DoneNotices` (Task 3).
- Produces: `Get-Pending` / `Get-Done` continuam existindo no widget como invólucros de uma linha, então nenhum ponto que as chama muda.

- [ ] **Step 1: Escrever `tests/widget.Tests.ps1`** (caracterização: tem que passar com o widget atual)

```powershell
# widget.ps1 tests. They run the real widget code, so they carry the Desktop tag:
#   rendering draws every card to PNG (no window is shown);
#   the queue test starts a real widget for a few seconds (an idle pill appears in a corner).
BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    $widget = Join-Path $repo 'plugins\claude-code-widget\scripts\widget.ps1'
    $samples = Join-Path $repo 'tools\samples.json'
}

Describe 'widget.ps1 rendering' -Tag 'Desktop' {
    It 'draws every card in <lang>' -ForEach @(@{ lang = 'en' }, @{ lang = 'pt' }) {
        $out = Join-Path $TestDrive $lang
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang $lang
        $LASTEXITCODE | Should -Be 0
        foreach ($name in 'idle', 'permission', 'question', 'done') {
            $png = Join-Path $out "$name.png"
            $png | Should -Exist
            (Get-Item -LiteralPath $png).Length | Should -BeGreaterThan 1024
        }
    }
}

Describe 'widget.ps1 queue loop' -Tag 'Desktop' {
    It 'removes orphaned requests and stale notices from its queue' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        $queue = Join-Path $data 'queue'
        New-Item -ItemType Directory -Path $queue | Out-Null
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $orphan = [ordered]@{ id = 'orphan'; pid = 2147483640; kind = 'permission'; created = $now; timeout = 300; cwd = '' }
        [IO.File]::WriteAllText((Join-Path $queue 'req-orphan.json'), ($orphan | ConvertTo-Json -Compress))
        $stale = $now - 13 * 3600 * 1000
        $notice = [ordered]@{ session = 's1'; created = $stale; cwd = ''; message = 'x'; hwnd = 0; kind = '' }
        [IO.File]::WriteAllText((Join-Path $queue "done-s1-$stale.json"), ($notice | ConvertTo-Json -Compress))

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $deadline = (Get-Date).AddSeconds(30)
            while ((Get-Date) -lt $deadline -and @(Get-ChildItem -LiteralPath $queue -File).Count -gt 0) { Start-Sleep -Milliseconds 250 }
            @(Get-ChildItem -LiteralPath $queue -File).Count | Should -Be 0
            Join-Path $data 'widget.json' | Should -Exist
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

A asserção `widget.log` não existe garante que o loop do timer não registrou nenhum erro. É assim que se pega o modo de falha 4 do Review Focus.

- [ ] **Step 2: Rodar contra o widget atual e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: os 3 testes novos PASS. Um pill "Claude Code · no requests" aparece no canto inferior direito por alguns segundos e some.

- [ ] **Step 3: Editar `widget.ps1`**

3a. Logo depois de `$Utf8 = New-Object System.Text.UTF8Encoding $false`, acrescente:

```powershell
. (Join-Path $PSScriptRoot 'common.ps1')
```

3b. Troque

```powershell
if (-not $Lang) { $Lang = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
if ($Lang -ne 'pt') { $Lang = 'en' }
$S = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'strings.json'), $Utf8) | ConvertFrom-Json).$Lang
```
por
```powershell
$Lang = Resolve-Lang $Lang
$S = Get-Strings $Lang
```

3c. Troque

```powershell
# One widget per data dir; hook.ps1 computes the same name to know whether the widget is running
$hash = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($Data.ToLowerInvariant()))
$MutexName = 'Local\ClaudeCodeWidget-' + (($hash[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
```
por
```powershell
# One widget per data dir; hook.ps1 computes the same name to know whether the widget is running
$MutexName = Get-MutexName $Data
```

3d. Apague (agora vêm do `common.ps1`):

```powershell
function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Write-JsonAtomic($path, $obj) {
    [IO.File]::WriteAllText("$path.tmp", ($obj | ConvertTo-Json -Depth 5 -Compress), $Utf8)
    [IO.File]::Move("$path.tmp", $path)
}

```

3e. Substitua as funções inteiras `function Get-Pending { ... }` e `function Get-Done { ... }` (do `function Get-Pending {` até a `}` que fecha `Get-Done`, logo antes de `# ---------------- Permission request ----------------`) por:

```powershell
    # Queue readers live in common.ps1; the caches keep each file from being re-read every tick
    function Get-Pending { Get-PendingRequests $Queue $script:cache }
    function Get-Done { Get-DoneNotices $Queue $script:doneCache $DoneMaxAgeMs }

```

- [ ] **Step 4: Conferir que não sobrou duplicação**

Run (Bash): `grep -nE 'function (Get-NowMs|Write-JsonAtomic)|SHA1|strings\.json' plugins/claude-code-widget/scripts/widget.ps1`
Esperado: só a linha do comentário de cabeçalho que cita `strings.json`, e nenhuma definição de função.

- [ ] **Step 5: Rodar tudo e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: todos PASS.

- [ ] **Step 6: Gerar as imagens do README de novo e conferir que nada mudou visualmente**

Run: `powershell -NoProfile -File tools\render-screenshots.ps1`, depois `git status --short docs/images`.
Esperado: os 8 PNGs são regenerados. Se o git apontar diferença, abra um par antigo/novo e confirme que o conteúdo é igual (a diferença costuma vir só do relógio: "há 2 min", contagem regressiva). Se for só isso, descarte com `git checkout -- docs/images`.

- [ ] **Step 7: Commit**

```bash
git add plugins/claude-code-widget/scripts/widget.ps1 tests/widget.Tests.ps1
git commit -m "refactor: widget.ps1 uses common.ps1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: CI, documentação e versão 1.1.1

**Files:**
- Create: `.github/workflows/test.yml`
- Modify: `README.md` (seções How it works e Development)
- Modify: `README.pt-BR.md` (seções Como funciona e Desenvolvimento)
- Modify: `CHANGELOG.md`
- Modify: `plugins/claude-code-widget/.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: `tools/test.ps1 -CI [-ExcludeTag]` (Task 1).
- Produces: workflow `test` com os jobs `pester` e `validate`.

- [ ] **Step 1: Subir a versão primeiro e ver o teste de versão falhar**

Em `plugins/claude-code-widget/.claude-plugin/plugin.json`, troque `"version": "1.1.0",` por `"version": "1.1.1",`.

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: FAIL só em `plugin.json version matches the latest CHANGELOG entry` (esperado `1.1.1`, o changelog diz `1.1.0`).

- [ ] **Step 2: Acrescentar a entrada no `CHANGELOG.md`**

Logo depois da linha `# Changelog` e da linha em branco que vem em seguida, insira (use a data do dia em que rodar esta task):

```markdown
## 1.1.1 (2026-10-07)

- Internal: the hook and the widget now share their common code (`common.ps1`), and an automated test suite (Pester 5) runs on every push and pull request in GitHub Actions. No behavior change.

```

Run: `powershell -NoProfile -File tools\test.ps1`
Esperado: todos PASS.

- [ ] **Step 3: READMEs**

Em `README.md`, logo depois do bullet que começa com ``- `widget.ps1` is a single long-running process``, insira:

```markdown
- `common.ps1` holds the helpers both scripts share: the widget's mutex name, atomic JSON writes, the UI language and the queue readers.
```

Em `README.md`, logo depois do bullet ``- Validate the plugin and the marketplace: ...``, insira:

```markdown
- Run the tests: install [Pester 5](https://pester.dev) once with `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`, then run `powershell -NoProfile -File tools\test.ps1`. One test shows a widget in the corner of the screen for a few seconds; add `-ExcludeTag Desktop` to skip the tests that run the real widget. GitHub Actions runs the same suite on every push and pull request.
```

Em `README.pt-BR.md`, logo depois do bullet que começa com ``- O `widget.ps1` é um único processo``, insira:

```markdown
- O `common.ps1` reúne o que os dois scripts compartilham: o nome do mutex do widget, a gravação atômica de JSON, o idioma da interface e a leitura da fila.
```

Em `README.pt-BR.md`, logo depois do bullet ``- Validar o plugin e o marketplace: ...``, insira:

```markdown
- Rodar os testes: instale o [Pester 5](https://pester.dev) uma vez com `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck` e depois rode `powershell -NoProfile -File tools\test.ps1`. Um dos testes mostra um widget no canto da tela por alguns segundos; use `-ExcludeTag Desktop` para pular os testes que abrem o widget de verdade. O GitHub Actions roda a mesma suíte a cada push e pull request.
```

- [ ] **Step 4: Criar `.github/workflows/test.yml`**

```yaml
name: test

on:
  push:
  pull_request:

jobs:
  pester:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Pester 5
        shell: powershell
        run: Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck
      - name: Run tests (Windows PowerShell 5.1)
        shell: powershell
        run: .\tools\test.ps1 -CI
      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: testResults.xml

  validate:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
      - name: Install Claude Code
        run: npm install -g @anthropic-ai/claude-code
      - name: Validate marketplace and plugin
        run: |
          claude plugin validate .
          claude plugin validate plugins/claude-code-widget
```

- [ ] **Step 5: Validar localmente o que o job `validate` vai rodar**

Run: `claude plugin validate .` e `claude plugin validate plugins/claude-code-widget`
Esperado: `✔ Validation passed` nos dois.

- [ ] **Step 6: Checagem manual com o plugin de verdade**

1. Rode `powershell -NoProfile -File tools\test.ps1` uma última vez. Esperado: todos PASS.
2. Desligue a cópia instalada para os hooks não rodarem em dobro: `claude plugin disable claude-code-widget@claude-code-widget`.
3. Confira o nome do flag com `claude --help`, procurando por `plugin-dir`. Depois abra uma sessão num projeto qualquer: `claude --plugin-dir <caminho do repo>\plugins\claude-code-widget`.
4. Peça algo que precise de permissão (por exemplo "rode `git status`"). O card aparece; **Approve** executa. Repita com **Deny**: o Claude diz que foi negado.
5. Peça "me faça uma pergunta de múltipla escolha com AskUserQuestion". O card de pergunta aparece; responda e confira que o Claude recebeu a resposta.
6. Mude para outra janela e espere uma resposta terminar. O aviso de "terminou" aparece; **Ir para o terminal** traz a janela de volta.
7. Feche o widget de teste (**botão direito → Fechar widget**) e religue a cópia instalada: `claude plugin enable claude-code-widget@claude-code-widget`.

Anote no PR o que foi conferido. Se algum passo falhar, pare e trate como bug, usando o superpowers:systematic-debugging.

- [ ] **Step 7: Commit e push do branch**

```bash
git add .github/workflows/test.yml README.md README.pt-BR.md CHANGELOG.md plugins/claude-code-widget/.claude-plugin/plugin.json
git commit -m "ci: run Pester and plugin validation on GitHub Actions; release 1.1.1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin refactor/shared-code-and-tests
```

- [ ] **Step 8: Conferir o CI**

Run: `gh run watch` (ou `gh run list --branch refactor/shared-code-and-tests`)
Esperado: os jobs `pester` e `validate` verdes.

Se o job `pester` falhar **só** nos testes com a tag `Desktop` (renderização WPF ou o widget real, porque o runner não tem sessão de desktop), troque no workflow `run: .\tools\test.ps1 -CI` por `run: .\tools\test.ps1 -CI -ExcludeTag Desktop` e faça o commit com a mensagem `ci: skip desktop tests on the hosted runner`. Esses testes continuam rodando localmente. Qualquer outra falha é bug: investigue antes de mexer no workflow.
