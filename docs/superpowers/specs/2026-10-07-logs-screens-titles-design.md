# Correções: rotação do log, troca de monitor e título do VS Code (bloco 3)

Data: 2026-10-07 · Versão alvo: 2.0.1 · Status: aguardando revisão

## Contexto e objetivo

Três bugs encontrados na revisão do projeto, mais os ajustes pequenos adiados nos blocos 1 e 2. Este bloco vem antes das funcionalidades novas: o "não perturbe" e o ícone na bandeja vão mexer no mesmo código de posição e de janela.

| Id | Problema hoje |
|---|---|
| B4 | O `hook.log` gira em 256 KB (vira `hook.log.old`), mas o `widget.log` cresce sem limite. |
| B5 | A posição salva só é conferida quando o widget abre, contra o retângulo que envolve todos os monitores. Dois furos: (1) se o monitor do widget é desconectado com o widget aberto, ele fica fora da tela; (2) com monitores de tamanhos diferentes, uma posição num canto vazio desse retângulo passa na conferência, e o widget abre fora de qualquer tela. |
| B6 | O nome do projeto é procurado como pedaço de texto no título da janela. Um projeto `widget` casa com a janela do `claude-code-widget`, ou com `widget.ps1` aberto em outro projeto. Afeta o "você já está olhando" (`Test-UserWatching`, no `hook.ps1`) e o botão "Ir para o VS Code" (`WinFocus.Focus`, no `widget.ps1`). Além disso, o `Save-SessionWindow` decide se a janela é do VS Code pelo título, e não pelo processo. |

**Objetivo:** corrigir os três sem mudar mais nada do comportamento, e fechar os ajustes adiados.

## Decisões tomadas (com o usuário)

| Item | Decisão |
|---|---|
| Monitor do widget some com o widget aberto | Vai para o canto inferior direito da área útil da tela principal. Quando o monitor volta, ele volta sozinho para a posição salva. Só arrastar grava o `state.json`. |
| Versão do Pester | Aceitar 5.5 ou mais novo (a CI usa o mais recente, hoje 6.2). Os textos que dizem "Pester 5" passam a dizer "Pester 5.5 ou mais novo". |
| Versão do plugin | 2.0.1 (só correções). |

## O que muda

### 1. Log com rotação (B4)

Nova função no `common.ps1`:

```powershell
Write-LogLine([string]$Path, [string]$Text, [int64]$MaxBytes = 256KB)
```

- Cria a pasta do arquivo se faltar.
- Se o arquivo já passa de `$MaxBytes`, apaga `<arquivo>.old` e renomeia o arquivo para `<arquivo>.old`.
- Acrescenta a linha `aaaa-mm-ddThh:mm:ss <texto>` em UTF-8 sem BOM.
- Nunca lança erro: um log que falha não pode derrubar o hook nem o widget. Duas gravações simultâneas que tentam girar ao mesmo tempo podem perder uma linha; isso é aceito.

Uso:
- `hook.ps1`: `Write-HookLog` passa a chamar `Write-LogLine $LogPath $msg`.
- `widget.ps1`: `Write-Log` mantém o filtro que ignora o mesmo erro repetido em seguida e chama `Write-LogLine $LogPath $text`.

### 2. Posição por monitor (B5)

Três funções novas no `common.ps1` (usadas só pelo widget; ficam ali porque o `widget.ps1` não pode ser carregado por testes sem abrir a janela):

- `Get-ScreenAreas`: lista a área útil (sem a barra de tarefas) de cada monitor, lida na hora pela API do Windows (`EnumDisplayMonitors` + `GetMonitorInfo`, num tipo C# `ClaudeWidget.Monitors` compilado na primeira chamada). Cada item: `@{ left; top; right; bottom; primary }`. As coordenadas vêm em pixels e são convertidas para as unidades do WPF: divididas pela largura em pixels do monitor principal, dividida por `SystemParameters.PrimaryScreenWidth`. As duas leituras vêm do mesmo processo no mesmo instante, então a razão fica certa com ou sem o modo DPI ativo (nesta máquina, 5120 px / 2560 = 2 com o modo ativo, 1 sem).
  - Por que não `System.Windows.Forms.Screen`: verificado aqui, ele guarda `Bounds` da primeira leitura (2560 antes do modo DPI ativar, 5120 depois) mas lê `WorkingArea` de novo a cada vez. Os dois podem divergir no mesmo processo.
- `Get-ScreenKey($Areas)`: texto que identifica a configuração das telas, as áreas concatenadas em ordem. Serve para notar uma mudança.
- `Resolve-Anchor($Saved, $Areas)`: recebe a posição salva (`@{ right; bottom }` ou `$null`) e as áreas. Devolve `@{ right; bottom; saved }`:
  - Se a posição salva cabe em alguma área, devolve ela (`saved = $true`). "Cabe" usa as mesmas margens de hoje, por área: `left + 120 < right <= areaRight + 1` e `top + 60 < bottom <= areaBottom + 1`.
  - Senão (ou sem posição salva), devolve o canto inferior direito da área principal (`saved = $false`). Sem área marcada como principal, usa a primeira.
  - Sem nenhuma área (a leitura falhou), devolve `$null`, e o widget mantém a posição atual.

No `widget.ps1`:

- Ao abrir: lê o `state.json` para `$script:savedAnchor`, e a posição inicial é `Resolve-Anchor $script:savedAnchor (Get-ScreenAreas)`. Isso substitui a conferência pelo retângulo de todos os monitores.
- No timer que já existe (400 ms), a cada 5 ticks (~2 s): calcula `Get-ScreenKey (Get-ScreenAreas)`. Se mudou desde a última vez, recalcula a posição a partir de `$script:savedAnchor`, chama `Update-Position` e grava uma linha no `widget.log`: `screens changed: anchor <right>,<bottom> (saved|default)`.
- Arrastar atualiza `$script:savedAnchor` e o `state.json`, como hoje. O reposicionamento automático nunca grava o `state.json`: é isso que deixa o widget voltar quando o monitor volta.
- Escolha do mecanismo: checar no timer, e não escutar `WM_DISPLAYCHANGE`. O timer já existe e roda no thread da interface. Os eventos de `SystemEvents` chegam em outro thread, onde um scriptblock do PowerShell 5.1 não roda. O custo é de até ~2 s para reagir.

### 3. Título do VS Code (B6)

Nova função no `common.ps1`:

```powershell
Test-TitleHasProject([string]$Title, [string]$Project)  # -> bool
```

O título padrão do VS Code é `[● ]arquivo - pasta[ sufixos] - Visual Studio Code[ sufixos]`. O nome do projeto precisa aparecer como uma parte inteira do título:
- antes dele: o começo do título (com o `●` opcional de arquivo não salvo) ou o separador ` - `;
- depois dele: o fim do título ou o separador ` - `, com sufixos opcionais entre eles, como ` (Workspace)`, ` (Espaço de Trabalho)`, ` [WSL: Ubuntu]` ou ` [Administrator]`;
- sem diferenciar maiúsculas.

Expressão regular, montada com o nome escapado (`●` é `[char]0x25CF`, colocado na expressão como caractere; o escape `●` não casa no .NET do PowerShell 5.1, verificado aqui):

```
(?i)(^|\s-\s)(●\s*)?<projeto>(\s[(\[][^)\]]*[)\]])*(\s-\s|$)
```

Funciona também para nomes de projeto que contêm ` - `. Título ou projeto vazio dá `$false`.

Uso:
- `hook.ps1`, `Test-UserWatching`: o título precisa conter "Visual Studio Code" (como hoje) **e** `Test-TitleHasProject $title $project`.
- `widget.ps1`, botão "Ir para o VS Code": o C# troca `Focus(app, project)` por `FindWindows(app)` (janelas visíveis cujo título contém `app`, na ordem de cima para baixo) e `Title(h)`. O PowerShell escolhe a primeira janela com `Test-TitleHasProject`; sem nenhuma, a primeira janela do VS Code (como hoje); e foca com `FocusHandle`.
- `hook.ps1`, `Save-SessionWindow`: nova função `Get-WindowKind([string]$ProcessName)`. Devolve `vscode` para `code.exe` e `code - insiders.exe`, `terminal` para os processos de `$TerminalHosts`, e `other` para o resto. O título deixa de ser usado para isso.

Limitação aceita: um arquivo aberto sem extensão e com o mesmo nome do projeto (por exemplo, projeto `Makefile`) continua casando.

### 4. Ajustes pequenos adiados

| Origem | Ajuste |
|---|---|
| Bloco 1 | Teste novo: `Get-DoneNotices` esquece do cache os avisos cujo arquivo sumiu. |
| Bloco 1 | `.github/workflows/test.yml` ganha `permissions: contents: read` no topo, e uma regra no `repo.Tests.ps1` exige `permissions:` no topo de todo workflow. |
| Bloco 1 | Harness: `CLAUDE_WIDGET_AWAY_SECS` de `100000` para `2000000000`, para que uma máquina de CI ligada há mais de 27 horas sem uso não pule o widget. |
| Bloco 1 | "Pester 5" vira "Pester 5.5 ou mais novo": READMEs (seção de desenvolvimento), cabeçalho do `tools/test.ps1` e nome do passo da CI. |
| Bloco 2 | A regra do id antigo no README também pega `plugin install|uninstall|update|enable|disable claude-code-widget` sem o `@`. O nome do marketplace (`marketplace update claude-code-widget`) continua permitido. |
| Bloco 2 | O leitor de seções do Markdown nos testes ignora linhas `#` dentro de blocos de código (```` ``` ````). A regra do id antigo passa a usar o mesmo leitor. Um teste com um Markdown de exemplo prova isso. |

### 5. Documentação e versão

- `plugin.json`: `version` = `2.0.1`.
- `CHANGELOG.md`: entrada `## 2.0.1 (data do dia da implementação)` com as três correções em linguagem de usuário.
- READMEs (en e pt-BR):
  - "Comportamentos importantes": um item sobre a troca de monitor (o widget vai para a tela principal e volta quando o monitor volta);
  - "Como funciona": os logs guardam até 256 KB, mais um arquivo `.old`.

## Riscos aceitos

- **Escala por monitor:** o widget usa a escala do sistema. Com monitores de escalas diferentes, a conversão de pixels para unidades do WPF pode ficar imprecisa no monitor secundário. O Windows já virtualiza as coordenadas para processos com a escala do sistema; o erro, se houver, é a posição ficar alguns pixels fora, não o widget sumir. Não há como testar aqui (um monitor só).
- **Mudanças de tela com o widget aberto não são testadas de verdade:** não dá para desconectar um monitor nos testes. `Resolve-Anchor` e `Get-ScreenKey` são testados com monitores falsos, e a abertura com uma posição fora de qualquer tela é testada com o widget real. A reação no timer fica sem teste automático.
- **Títulos personalizados:** quem mudar `window.title` ou `window.titleSeparator` no VS Code pode ficar sem o "você já está olhando" quando a sessão não tem janela guardada. Antes, o mesmo usuário tinha falsos positivos. A janela guardada pelo `UserPromptSubmit` continua sendo o caminho principal e não depende do título.

## Testes e verificação

1. `tools\test.ps1` passa inteiro, com os testes novos:
   - `Write-LogLine`: grava a linha com data e hora; gira ao passar do limite; mantém só um `.old`; não lança erro com um caminho inválido.
   - `Resolve-Anchor`: cabe na principal; cabe na secundária; cai no canto vazio entre monitores de tamanhos diferentes; o monitor sumiu; o monitor voltou; sem posição salva.
   - `Get-ScreenKey`: muda quando uma área muda. `Get-ScreenAreas`: devolve pelo menos uma área, com exatamente uma principal, e a área principal bate com `SystemParameters.WorkArea` do WPF.
   - Widget real (tag Desktop): com um `state.json` fora de qualquer tela, a janela abre no canto inferior direito da área útil da tela principal, e o `state.json` não muda.
   - `Write-HookLog`: o `hook.log` gira ao passar de 256 KB.
   - `Test-TitleHasProject`: os casos da seção 3, incluindo `widget` contra `claude-code-widget` e contra `widget.ps1 - outro - Visual Studio Code`.
   - `Get-WindowKind`: `Code.exe`, `Code - Insiders.exe`, `WindowsTerminal.exe`, `explorer.exe`.
   - Os ajustes da seção 4.
2. Verificação à mão no fim: o botão "Ir para o VS Code" de um aviso de "terminou" sem janela guardada traz a janela do projeto certo.
3. CI verde no GitHub.

## Fora do escopo

- Escutar mensagens do Windows para reagir na hora à troca de monitor.
- Suportar escala por monitor (per-monitor DPI).
- Ler a configuração `window.title` do VS Code.
- Qualquer funcionalidade nova (bloco 4).
