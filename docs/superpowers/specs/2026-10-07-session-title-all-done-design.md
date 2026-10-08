# Título da sessão, som de "tudo pronto" e duplo clique (bloco 4a)

Data: 2026-10-07 · Versão alvo: 2.1.0 · Status: aguardando revisão

## Contexto e objetivo

Três ideias pequenas tiradas do Claude Monitor (github.com/LucasM-Maciel/ticlins-claude-monitor), escolhidas pelo usuário. É a primeira parte do bloco 4. A visão das sessões, o "não perturbe" e a bandeja ficam no 4b. O diff, o "Sempre permitir" e os atalhos ficam no 4c.

1. **Título da sessão nos cartões.** Com duas sessões no mesmo projeto, hoje os cartões são iguais. O Claude Code grava no transcript o título automático da sessão (`{"type":"ai-title","aiTitle":...}`) e o nome dado com `/rename` (`{"type":"custom-title","customTitle":...}`). Verificado aqui: as duas linhas se repetem a cada ~20 linhas do transcript, e o `custom-title` vale mais que o `ai-title`.
2. **Som de "tudo pronto".** Quando a última sessão que estava trabalhando termina, o aviso de "terminou" toca um som diferente do normal.
3. **Duplo clique traz o VS Code.** Duplo clique no widget, fora dos botões, traz a janela da sessão.

## Decisões

| Item | Decisão |
|---|---|
| Onde o título aparece | No chip do projeto dos três cartões (permissão, pergunta, terminou): `projeto · título`. O título é cortado em 40 caracteres, com `...`. Sem título, o chip fica como hoje. |
| De onde vem o título | O hook lê os últimos 512 KB do transcript (`transcript_path`) e pega o último `custom-title` (`customTitle`); sem nenhum, o último `ai-title` (`aiTitle`) da mesma sessão (`sessionId` igual ao do evento, ou ausente). Se o arquivo falhar, não houver título ou a linha for inválida, o título fica vazio. |
| Quando o título é lido | No `PermissionRequest`, no `PreToolUse` (AskUserQuestion) e no `Stop`, gravado no pedido ou no aviso, no campo `title`. |
| "Trabalhando" | `UserPromptSubmit` grava `busy\<sessão>.json` com `pid` (o processo do Claude dessa sessão) e `since`. O `Stop` apaga o da própria sessão. |
| Processo do Claude | O primeiro ancestral do hook chamado `claude.exe`; sem nenhum, o primeiro `node.exe` (instalação via npm); sem nenhum dos dois, `0`. |
| Rodada | Uma "rodada" vai de quando uma sessão começa a trabalhar sem nenhuma outra trabalhando até quando nenhuma trabalha mais. `busy-round.json` guarda as sessões que trabalharam na rodada. O `UserPromptSubmit` começa uma rodada nova (se nenhuma outra sessão está viva) ou entra na atual. |
| Quando é "tudo pronto" | No `Stop`, depois de apagar o próprio arquivo: nenhum outro `busy\*.json` vivo **e** a rodada teve 2 sessões ou mais. Assim, com uma sessão só, o som normal continua (senão todo aviso seria "tudo pronto"). Vivo = o `pid` ainda roda **e** `since` tem menos de 12 horas; com `pid` 0 vale só a idade. Arquivos que não estão vivos são apagados. Ao fim da rodada, `busy-round.json` é apagado. O aviso ganha `allDone = true`. |
| Som de "tudo pronto" | `%WINDIR%\Media\tada.wav`; sem ele, `SystemSounds.Exclamation`. Toca no lugar do som normal, só quando o aviso aparece. O aviso não aparece se você já está olhando a sessão; nesse caso, não toca nada (como hoje). |
| Duplo clique | No cartão de "terminou": o mesmo que o botão **Ir para o VS Code / terminal**. Nos outros estados (pílula, permissão, pergunta): a janela guardada da sessão mais recente (`sessions\*.json` mais novo cuja janela ainda existe); sem nenhuma, a janela do VS Code do projeto do item na tela, ou qualquer janela do VS Code. Duplo clique em botões, opções ou na caixa de texto não faz nada disso. |
| Versão | 2.1.0 (funcionalidades novas, sem mudança de instalação). |

## O que muda

### hook.ps1

- `Get-SessionTitle([string]$TranscriptPath, [string]$SessionId)` → texto (pode ser vazio). Lê o fim do arquivo com `FileStream` + `Seek` (no máximo 512 KB), em UTF-8, descarta a primeira linha (pode estar cortada), e testa cada linha que contém `"custom-title"` ou `"ai-title"` com `ConvertFrom-Json` dentro de `try`.
- `Get-ClaudePid` → `[int]`, a partir de `Get-ProcessTree` (já existe): sobe pelos ancestrais e devolve o primeiro `claude.exe`, senão o primeiro `node.exe`, senão `0`.
- `Set-SessionBusy([string]$Sid)` grava `busy\<sid>.json` (`@{ pid; since }`) com `Write-JsonAtomic`.
- `Get-WorkingSessions` → ids das sessões com `busy\*.json` vivo; apaga os que não estão vivos.
- `Set-SessionBusy` também atualiza `busy-round.json`: sem nenhuma sessão viva, a rodada recomeça só com esta sessão; senão, esta sessão entra na lista.
- `Complete-SessionBusy([string]$Sid)` → `[bool]` "tudo pronto": apaga `busy\<sid>.json`; se ainda há sessão viva, `$false`; senão apaga `busy-round.json` e devolve `$true` quando a rodada teve 2 sessões ou mais.
- `UserPromptSubmit`: chama `Set-SessionBusy` (depois de `Remove-Done`).
- `Stop`: chama `Complete-SessionBusy` **antes** de decidir se mostra o aviso (o arquivo é apagado mesmo sem aviso); o aviso ganha `title` e `allDone`.
- `PermissionRequest` e `PreToolUse` (AskUserQuestion): o pedido ganha `title`.
- Nada disso escreve no stdout. Qualquer falha nessas funções é engolida, e o fluxo segue como hoje.

### widget.ps1

- `Set-ProjectChip` recebe o item e monta `projeto · título` (título cortado em 40 caracteres).
- Som: carrega `tada.wav` como `$script:allDoneSound`; `Show-Done` toca esse som quando `allDone` é verdadeiro.
- Duplo clique: no `MouseLeftButtonDown` da janela, com `ClickCount -eq 2`, chama `Invoke-DoubleClick` em vez de `DragMove`. Botões, opções e a caixa de texto já marcam o clique como tratado (`Handled`), então não chegam à janela.
- `Invoke-DoubleClick`: no cartão de "terminou", `Close-DoneNotice -GoToSession`; senão, `Find-LatestSessionWindow` (o `sessions\*.json` mais novo, por `LastWriteTime`, cuja janela existe) e `FocusHandle`; senão, `Find-VsCodeWindow` com o projeto do item na tela.

### Dados de exemplo e documentação

- `tools/samples.json`: título nos três exemplos (en e pt), e as imagens do README geradas de novo com `tools/render-screenshots.ps1`.
- READMEs: o título no chip, o som de "tudo pronto" e o duplo clique na tabela/lista de uso; a pasta `busy\` em "Como funciona".
- `CHANGELOG.md`: entrada 2.1.0.

## Riscos aceitos

- **Sessão fechada no meio do trabalho** (VS Code fechado, `claude` morto): o `pid` deixa de rodar e a sessão para de contar. Uma sessão encerrada sem `Stop` e sem `pid` conhecido conta como trabalhando por até 12 horas, o que pode atrasar um "tudo pronto".
- **Sessões que trabalham sem prompt** (por exemplo, retomadas por um hook ou pelo Remote Control) só contam depois do primeiro `UserPromptSubmit` delas.
- **Título:** se o Claude Code mudar o formato das linhas `ai-title`/`custom-title`, o título some (sem erro). Uma linha maior que 512 KB no fim do transcript também esconde o título até a próxima repetição.
- **Duplo clique** não tem teste automático (o `widget.ps1` não pode ser carregado por testes). Verificação à mão.

## Testes e verificação

1. `hook.Tests.ps1` (unidade, com transcripts de exemplo em `tests/fixtures/`):
   - `Get-SessionTitle`: `custom-title` vale mais que `ai-title`; o último vale; outra sessão é ignorada; sem título, arquivo inexistente ou caminho vazio dão vazio; título além dos 512 KB finais não é lido; linha quebrada é ignorada.
   - `Get-ClaudePid` devolve um número ≥ 0 sem erro.
   - `Set-SessionBusy` / `Complete-SessionBusy`: uma sessão sozinha → `$false` (rodada de 1); A e B juntas: A termina → `$false`, B termina → `$true`; outra com `pid` morto não conta e o arquivo dela é apagado; outra com `since` de 13 horas atrás não conta; `pid` 0 recente conta como viva; depois do fim da rodada, uma sessão sozinha volta a dar `$false`.
2. `hook.e2e.Tests.ps1`: o `Stop` grava `title` e `allDone`; com a rodada tendo outra sessão que já terminou, `allDone` é verdadeiro; com outra sessão ainda ocupada (um `busy\*.json` com o `pid` do próprio teste), `allDone` é falso; o `UserPromptSubmit` grava o `busy` da sessão; o pedido de permissão leva o `title`.
3. Widget (Desktop): a renderização das amostras com título continua passando; o teste da fila continua sem `widget.log`.
4. À mão: duplo clique na pílula traz a janela desta sessão; duas sessões, a última que termina toca o som de "tudo pronto".

## Fora do escopo

- Lista das sessões na pílula (4b).
- Escolher o som ou o volume (bloco 5).
- Título nas sessões que nunca tiveram título (o hook não inventa um).
