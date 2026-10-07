# Código comum e testes automatizados (bloco 1)

Data: 2026-10-07 · Versão alvo: 1.1.1 · Status: aguardando revisão

## Contexto e objetivo

O plugin tem dois scripts PowerShell 5.1: `hook.ps1` (419 linhas) e `widget.ps1` (954 linhas). Eles não têm nenhum teste automatizado, e parte do código está duplicada entre os dois: nome do mutex, escrita atômica de JSON e escolha de idioma. Este bloco:

1. junta o código duplicado num arquivo comum (item D10 do roteiro);
2. cria uma suíte de testes com Pester 5, rodando localmente e no GitHub Actions (item D11).

**Para o usuário, nada muda.** Todo o comportamento visível fica idêntico. A versão vai para 1.1.1 só porque os scripts instalados mudam.

### Roteiro completo (para contexto; cada bloco terá a sua própria spec)

| Ordem | Bloco | Itens |
|---|---|---|
| 1 | **Este documento** | D10 código comum, D11 testes + CI |
| 2 | Correções | B4 rotação do `widget.log`, B5 reposicionar quando a tela muda, B6 falso positivo do título do VS Code |
| 3 | Funcionalidades | A1 diff do Edit/Write, A2 "Sempre permitir", A3 atalhos globais, **modo não perturbe + ícone na bandeja** |
| 4 | Visual | C8 tema claro, C9 escala / pill compacto |
| depois | Estrutura | D12 dividir o `widget.ps1` |

## Decisões tomadas

- **Pester 5** (≥ 5.5) como ferramenta de testes. Ele só é necessário para quem desenvolve: instalar o plugin continua sem depender de nada.
- Os testes rodam em **Windows PowerShell 5.1** (`powershell.exe`), o mesmo runtime do plugin.
- **GitHub Actions** em `windows-latest` a cada push e PR.
- Abordagem: **`common.ps1` carregado com dot-source + `hook.ps1` reorganizado em funções**. A alternativa de um módulo `.psm1` foi descartada porque mudaria o comportamento das variáveis `$script:` do widget. A de ter só testes de caixa-preta também, porque não removeria a duplicação.

## Estrutura dos arquivos

```
plugins/claude-code-widget/scripts/
  common.ps1      NOVO: funções compartilhadas, sem efeitos colaterais ao carregar
  hook.ps1        reorganizado: funções + Invoke-Hook + ponto de entrada protegido
  widget.ps1      carrega common.ps1; a interface não muda
  strings.json    sem mudança
tests/            NOVO, fora do plugin (não vai junto na instalação)
  common.Tests.ps1
  hook.Tests.ps1
  hook.e2e.Tests.ps1
  widget.Tests.ps1
  repo.Tests.ps1
  fixtures/       transcript .jsonl de exemplo etc.
tools/test.ps1    NOVO: confere o Pester 5 e roda a suíte
.github/workflows/test.yml   NOVO
```

### `common.ps1`

Ao ser carregado, só define funções: não cria pastas, não lê arquivos e não altera `$ErrorActionPreference`. Os dois scripts o carregam com `. (Join-Path $PSScriptRoot 'common.ps1')`.

| Função | Contrato |
|---|---|
| `Get-MutexName [string]$Dir` | `'Local\ClaudeCodeWidget-'` + os 12 primeiros hex do SHA1 de `$Dir.ToLowerInvariant()` em UTF-8. **Precisa ser idêntico ao algoritmo atual**: é assim que o hook detecta o widget de uma versão anterior. |
| `Write-JsonAtomic [string]$Path, $Object` | Grava `$Path.tmp` em UTF-8 sem BOM (`ConvertTo-Json -Depth 10 -Compress`) e renomeia para `$Path`. Unifica as profundidades atuais (hook 10, widget 5). |
| `Resolve-Lang [string]$Requested` | Vazio → usa `CurrentUICulture.TwoLetterISOLanguageName`. Resultado `pt` (sem diferenciar maiúsculas) → `'pt'`; qualquer outro → `'en'`. |
| `Get-Strings [string]$Lang` | Lê o `strings.json` da mesma pasta como UTF-8 e devolve `.$Lang`. |
| `Get-NowMs` | Hora atual UTC em milissegundos Unix (`int64`). |
| `Get-PendingRequests [string]$Queue, [hashtable]$Cache` | É o `Get-Pending` atual do widget, com fila e cache recebidos por parâmetro. Apaga `req-*` vencidos (`created + (timeout+5)s`) e os de processo (`pid`) morto; pula os que já têm `res-<id>.json`; ignora JSON inválido; tira do cache os arquivos que sumiram. Ordena por `created`, do mais antigo para o mais novo. |
| `Get-DoneNotices [string]$Queue, [hashtable]$Cache, [int64]$MaxAgeMs` | É o `Get-Done` atual, com o mesmo padrão. Acrescenta as propriedades `key` (nome do arquivo) e `file` (caminho completo) e apaga os avisos com mais de `$MaxAgeMs`. Ordena do mais novo para o mais antigo. |

### `hook.ps1`

- A configuração do topo continua igual: caminhos, `$Lang`/`$S` (agora via `Resolve-Lang`/`Get-Strings`), `$MutexName` (via `Get-MutexName`) e os limites de tempo.
- Funções novas, extraídas de trechos inline:
  - `Get-PermissionDetail $ToolInput`: prioridade `command` → `file_path` → `notebook_path` → `url` → `query` → JSON compacto (profundidade 4). Corta em 2000 caracteres + `' ...'`.
  - `New-PermissionOutput [string]$Behavior, [string]$Message`: devolve o objeto ordenado `hookSpecificOutput` do `PermissionRequest`. O `message` só entra quando `Behavior = 'deny'`.
  - `New-AnswerOutput $ToolInput, $Answers, [string]$Reason`: devolve o objeto do `PreToolUse`, com `permissionDecision = 'allow'` e `updatedInput` = a entrada original + `answers`.
- **`Invoke-Hook $evt`** (não `$Event`, que é variável automática do PowerShell): contém o roteamento que hoje fica nas linhas 297–419. Devolve **a string JSON a imprimir, ou `$null`**. Não chama `exit`. As funções que hoje leem `$evt`/`$logTag` do escopo do script passam a receber esses valores por parâmetro.
- O ponto de entrada fica no fim do arquivo:

  ```powershell
  # Loaded with dot-source (tests): stop here, only the functions above are wanted
  if ($MyInvocation.InvocationName -eq '.') { return }
  if ($EnsureWidget) { [void](Start-Widget); exit 0 }
  [Console]::InputEncoding = [Text.Encoding]::UTF8
  try { $evt = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
  $out = Invoke-Hook $evt
  if ($out) { $out }
  exit 0
  ```

  Carregado com dot-source (nos testes), o `return` para o script depois das definições, sem derrubar quem o carregou. Isso foi verificado no PowerShell 5.1.

### `widget.ps1`

- Carrega `common.ps1` e troca as cópias locais (mutex, `Write-JsonAtomic`, idioma, `Get-NowMs`) pelas funções comuns.
- `Get-Pending` vira `Get-PendingRequests $Queue $script:cache`, e `Get-Done` vira `Get-DoneNotices $Queue $script:doneCache $DoneMaxAgeMs`. Todos os pontos que usam essas funções continuam iguais.
- XAML, cards, foco e posição: nenhuma mudança.

### Regras mantidas

- Todo `.ps1` continua **só com ASCII**, e um teste garante isso. Os textos da interface ficam no `strings.json`.
- O hook continua sem imprimir nada em `Stop`/`UserPromptSubmit`/`SessionStart`.

## Testes

Todos os testes usam pastas temporárias em `$TestDrive` ou `%TEMP%` e nunca tocam a pasta de dados real do plugin.

### `common.Tests.ps1`
- `Get-MutexName`: valor fixado para um caminho conhecido (calculado com o algoritmo atual antes do refactor); igual para o mesmo caminho em maiúsculas e minúsculas; formato `Local\ClaudeCodeWidget-[0-9a-f]{12}`.
- `Write-JsonAtomic`: os bytes do arquivo não começam com BOM; texto com `ção` sobrevive à ida e volta; nenhum `.tmp` sobra.
- `Resolve-Lang`: `pt`→`pt`, `PT`→`pt`, `en`→`en`, `es`→`en`. O `-ne` do PowerShell não diferencia maiúsculas, então hoje `PT` já vira português. A função só normaliza o retorno para minúsculas.
- `Get-Strings`: `pt` e `en` têm o mesmo conjunto de chaves.
- `Get-PendingRequests`: ordem por `created`; vencido é apagado; `pid` inexistente é apagado; com `res-<id>.json` fica de fora (e não é apagado); JSON inválido é ignorado; o cache perde a entrada quando o arquivo some.
- `Get-DoneNotices`: ordem do mais novo para o mais antigo; aviso mais velho que `MaxAgeMs` é apagado; `key` e `file` preenchidos.

### `hook.Tests.ps1` (unidade, `hook.ps1` carregado com dot-source)
- `Format-Snippet`: remove blocos ```` ``` ````; `[texto](url)` vira `texto`; remove `` ` * _ # > | ``; junta espaços; acima de 300 caracteres corta e acrescenta `...`.
- `ConvertTo-AsciiJson`: a saída só tem ASCII; `ConvertFrom-Json` da saída devolve os valores originais com acento.
- `Get-PermissionDetail`: um caso por campo da prioridade, o fallback para JSON e o corte em 2000.
- `Get-LastAssistantText`: usa `last_assistant_message`; sem ele, lê o último bloco de texto de assistant de `fixtures/transcript.jsonl` (com linhas de `user`, `tool_use` e JSON inválido misturadas); sem os dois, devolve `''`.
- `New-PermissionOutput` / `New-AnswerOutput`: formato exato, campos originais preservados no `updatedInput`.

### `hook.e2e.Tests.ps1` (processo real)

Harness: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File hook.ps1`, com o evento JSON no stdin e estas variáveis de ambiente: `CLAUDE_PLUGIN_DATA=<temp>`, `CLAUDE_WIDGET_LANG=pt`, `CLAUDE_WIDGET_AWAY_SECS=100000`. O próprio teste segura um mutex com `Get-MutexName <temp>`, então `Start-Widget` acha que o widget está aberto e não abre o widget real. Um "widget falso" espera o `req-*.json` aparecer e grava o `res-<id>.json`.

| Cenário | Esperado |
|---|---|
| `PermissionRequest` (Bash) → `allow` | stdout = JSON de allow; `req`/`res` apagados |
| `PermissionRequest` → `deny` | JSON de deny com `message` = `deniedMessage` em pt |
| `PermissionRequest` → `vscode` | stdout vazio |
| `PreToolUse` `AskUserQuestion` → `answer` com acentos | `updatedInput.answers` com acentos; `questions` preservado |
| `PermissionRequest` `ExitPlanMode` | stdout vazio, nenhum `req-*` criado |
| Mutex solto durante a espera | stdout vazio em menos de 5 s |
| `CLAUDE_WIDGET_AWAY_SECS=0` | stdout vazio, nenhum `req-*` criado |
| `Stop` com `last_assistant_message` em markdown → `UserPromptSubmit` | cria `done-<sid>-*.json` com o trecho formatado; depois ele é apagado; stdout vazio nos dois |

O `cwd` dos eventos é uma pasta temporária com nome único (`ccw-e2e-<guid>`), para que nenhuma janela real do VS Code seja confundida com "a sessão em primeiro plano".

### `widget.Tests.ps1`
- Para `en` e `pt`: `widget.ps1 -RenderSamples tools/samples.json -OutDir <temp> -Lang <x>` termina com código 0 e gera `idle.png`, `permission.png`, `question.png` e `done.png`, todos maiores que 1 KB.
- Widget real: abre o `widget.ps1` com uma pasta de dados temporária que contém um pedido órfão e um aviso vencido, e confere que os dois somem e que o `widget.log` não registrou erro. Isso prova que o loop do widget usa as funções de fila do `common.ps1` corretamente.
- Esses testes têm a tag `Desktop`. Se a renderização WPF falhar no runner do GitHub, que não tem sessão de desktop, o workflow passa a chamar `tools\test.ps1 -CI -ExcludeTag Desktop`. Localmente eles continuam rodando.

### `repo.Tests.ps1`
- Todo `.ps1` em `plugins/` e `tools/` tem só bytes < 0x80.
- `plugin.json`, `marketplace.json`, `hooks.json` e `strings.json` são JSON válidos.
- A `version` do `plugin.json` é igual ao primeiro título `## x.y.z` do `CHANGELOG.md`. Isso pega o esquecimento de atualizar a versão, que o README marca como obrigatório.

### Fora do escopo
O que depende de interação real com o Windows continua sendo testado à mão: não roubar foco, arrastar, "voltar para a janela da sessão", som e sempre no topo.

## Execução

### `tools/test.ps1`
- Parâmetros: `-CI` (switch) e `-ExcludeTag` (string[]).
- Se não houver Pester ≥ 5.5, para com a mensagem: `Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck`.
- Roda `Invoke-Pester` em `tests/` com `Output.Verbosity = Detailed` e `Run.Exit = $true` sempre, para o código de saída refletir as falhas também localmente.
- `-CI` acrescenta `TestResult` em NUnitXml (`testResults.xml`, ignorado pelo git).
- `-ExcludeTag` repassa as tags para `Filter.ExcludeTag`. Os testes de renderização têm a tag `Desktop`; o CI só os exclui se a renderização WPF falhar no runner.
- Uso local: `powershell -NoProfile -File tools\test.ps1`.

### `.github/workflows/test.yml`
- Gatilhos: `push` e `pull_request`. Runner: `windows-latest`. Steps em `shell: powershell` (5.1).
- Passos: checkout → instalar Pester 5 → `tools\test.ps1 -CI` → publicar o `testResults.xml` como artifact.
- Job separado `validate`: instala o CLI (`npm i -g @anthropic-ai/claude-code`) e roda `claude plugin validate .` e `claude plugin validate plugins/claude-code-widget`. **Risco:** se o CLI exigir login até para `validate`, esse job sai do workflow, e a checagem de JSON do `repo.Tests.ps1` cobre o básico.

## Documentação
- `README.md` e `README.pt-BR.md`, seção Development: como instalar o Pester 5 e rodar `tools\test.ps1`.
- `CHANGELOG.md`: `## 1.1.1`, "Internal: shared code and automated tests. No behavior change."
- `plugin.json`: `version` 1.1.1.

## Critérios de aceite
1. `tools\test.ps1` passa localmente em Windows PowerShell 5.1.
2. O workflow passa no GitHub.
3. `common.ps1` existe, e nenhuma das funções da tabela continua duplicada em `hook.ps1`/`widget.ps1`.
4. O teste de mutex fixado passa, ou seja, o nome é idêntico ao da 1.1.0.
5. Teste manual: com o plugin carregado deste diretório, um pedido de permissão, uma pergunta e um aviso de "terminou" funcionam como antes.
