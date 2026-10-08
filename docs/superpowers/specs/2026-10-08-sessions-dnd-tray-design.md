# Visão das sessões, "não perturbe" e ícone na bandeja (bloco 4b)

Data: 2026-10-08 · Versão alvo: 2.2.0 · Status: aguardando revisão

## Contexto e objetivo

Segunda parte do bloco 4. O usuário definiu "esconder o widget" como **modo "não perturbe" + ícone na bandeja** (não esconder só a pílula, nem um atalho de mostrar/esconder). A visão das sessões vem do Claude Monitor (github.com/LucasM-Maciel/ticlins-claude-monitor).

1. **Visão das sessões:** a pílula parada passa a dizer quantas sessões estão trabalhando e, com um clique, abre a lista (projeto, título e estado de cada uma).
2. **"Não perturbe":** pedidos e perguntas vão direto para o VS Code, avisos de "terminou" ficam guardados em silêncio, e o widget some da tela.
3. **Ícone na bandeja:** mostra o estado do widget, liga e desliga o "não perturbe" e fecha o widget.

## Decisões (com o usuário)

| Item | Decisão |
|---|---|
| Pedidos e perguntas no modo | Vão direto para o VS Code (o hook não cria o pedido e devolve nada), como na ausência prolongada. |
| Avisos de "terminou" no modo | O hook continua gravando o aviso; o widget não mostra nem toca nada enquanto o modo está ligado. Ao desligar, os avisos ainda guardados (máximo 12 h) aparecem normalmente. |
| Widget no modo | A janela inteira fica escondida (`Hide()`). O ícone da bandeja mostra o estado. |
| Bandeja | Clique esquerdo liga/desliga o modo. Menu do botão direito: **Não perturbe** (com marca), **Fechar widget**. |
| Lista de sessões | Um clique na pílula parada abre ou fecha a lista (arrastar continua arrastando; o clique só conta se a janela não se mexeu). |
| Persistência do modo | Fica ligado até você desligar, inclusive depois de reiniciar o widget ou o Windows. |

## O que muda

### Estado compartilhado (`common.ps1`)

- `Get-BusySessions([string]$BusyDir, [int64]$MaxAgeMs, [int64]$QuietMs)` → objetos `{ id; pid; since; cwd; transcript }` das sessões trabalhando. É o corpo atual de `Get-WorkingSessions` do `hook.ps1` (processo vivo ou desconhecido, menos de 12 h, transcript escrito nos últimos 15 min), movido para cá e devolvendo os objetos; apaga os arquivos que não estão vivos. O `hook.ps1` passa a chamar essa função (`Get-WorkingSessions` vira um invólucro que devolve só os ids).
- `Get-SessionTitle` (hoje no `hook.ps1`) passa para o `common.ps1`, sem mudar, para o widget usar.
- `Test-Dnd([string]$Dir)` → `[bool]`: existe o arquivo `dnd.flag` na pasta de dados.
- `Set-Dnd([string]$Dir, [bool]$On)`: cria ou apaga `dnd.flag`.

### hook.ps1

- `Set-SessionBusy` grava também `cwd` no `busy\<sessão>.json`.
- Em `PermissionRequest` e `PreToolUse` (AskUserQuestion), logo depois dos filtros de ferramenta e antes de `Test-Away`: `if (Test-Dnd $Data) { Write-HookLog "$logTag do not disturb: goes to VS Code"; return $null }`.
- `Stop`, `UserPromptSubmit` e `SessionStart` não mudam (os avisos continuam sendo gravados, e o widget continua sendo iniciado, para a bandeja existir e permitir desligar o modo).

### widget.ps1

- **Bandeja:** `System.Windows.Forms.NotifyIcon` criado depois da janela. Verificado aqui: funciona dentro do `Application.Run` do WPF no PowerShell 5.1, com o ícone desenhado por código (`Bitmap` + `GetHicon`, `DestroyIcon` no handle). Dois ícones, desenhados na hora, 32×32: círculo laranja (`#D97757`) com o widget ativo, círculo cinza (`#8A8A93`) no modo "não perturbe". Texto ao passar o mouse e itens do menu vêm do `strings.json`. O ícone é removido (`Visible = $false`, `Dispose`) ao fechar o widget, também pelo "Fechar widget" do botão direito do cartão.
- **Modo:** `$script:dnd` lido de `Test-Dnd` a cada tick do timer (assim o modo mudado de fora, por exemplo apagando o arquivo, também vale em ~0,4 s). Quando liga: `$win.Hide()`; quando desliga: `$win.Show()` e o próximo `Update-View` mostra o que estiver na fila. No modo, `Update-View` não mostra nada nem toca sons. Os pedidos que já estavam na tela quando o modo ligou são devolvidos ao VS Code (resposta `vscode`), como no "Decidir no VS Code".
- **Visão das sessões:**
  - A pílula parada mostra `sem pedidos` (como hoje) quando nenhuma sessão trabalha, e `N trabalhando` quando há sessões trabalhando (singular: `1 trabalhando`).
  - Um clique (botão esquerdo sem arrastar) na pílula alterna a lista, um painel abaixo da pílula (a janela cresce para cima, como os cartões). Cada linha: bolinha verde (trabalhando) ou laranja (esperando você, quando existe um pedido na fila daquela sessão), `projeto · título` e há quanto tempo (`2 min`).
  - Fonte da lista: `Get-BusySessions` a cada 2 s (no mesmo gancho da conferência de telas). O título vem de `Get-SessionTitle` sobre o `transcript` da sessão, relido no máximo a cada 15 s por sessão e só com a lista aberta. Máximo de 8 linhas; com mais, a última diz `+N`.
  - A lista fecha sozinha quando um cartão (pedido, pergunta, aviso) aparece, e quando a última sessão deixa de trabalhar.
  - O clique deve ser distinguido do arrasto e do duplo clique: o tratador atual do `MouseLeftButtonDown` já guarda `Left`/`Top` antes de `DragMove`; sem movimento, é um clique, e o alternar acontece (no duplo clique, o 2º clique chama `Invoke-DoubleClick` e não alterna).
- **Strings novas** (`strings.json`, pt e en): `workingOne`, `workingMany` (`{0} trabalhando`), `sessionsMore`, `trayTip`, `trayTipDnd`, `trayDnd`, `trayClose`, `minutesShort`.

### Dados de exemplo e documentação

- `tools/render-screenshots.ps1` e `samples.json`: nova imagem `sessions.png` (pílula com a lista aberta, 3 sessões de exemplo) em `docs/images/{en,pt}`.
- READMEs: seção de uso da lista, do modo e da bandeja; item em "Comportamentos importantes" (o que o modo faz, que fica ligado até desligar, que o widget some); `dnd.flag` na lista de arquivos de dados; os arquivos `busy\` e `busy-round.json` (pendência do 4a).
- `CHANGELOG.md`: entrada 2.2.0.

## Riscos aceitos

- **Modo esquecido ligado:** os pedidos passam a ir sempre para o VS Code (como se você estivesse ausente), e o widget fica escondido. O ícone cinza na bandeja mostra o estado, e o README avisa. Windows pode esconder o ícone na área de "ícones ocultos": o usuário precisa arrastá-lo para a barra, uma vez.
- **Widget fechado com o modo ligado:** o modo continua ligado (o arquivo fica). O próximo `SessionStart` ou aviso abre o widget escondido, com o ícone cinza, e é por lá que se desliga. Nada trava, porque os pedidos já vão para o VS Code.
- **Sessões sem `UserPromptSubmit`** (retomadas, Remote Control) não aparecem na lista até o primeiro prompt delas (limite herdado do 4a).
- **Estado "esperando você":** só conta quando há pedido na fila da própria sessão; os pedidos não trazem o id da sessão hoje, então a ligação é pelo `cwd` (projeto). Com duas sessões no mesmo projeto, as duas ficam laranja.
- **Teste da bandeja:** o ícone, o clique e o menu não têm teste automático (precisam de interação na bandeja do Windows). Verificação à mão.

## Testes e verificação

1. `common.Tests.ps1`:
   - `Get-BusySessions`: devolve as sessões vivas com `id`, `cwd` e `transcript`; apaga pid morto, `since` velho e transcript parado há mais de 15 min (os casos já cobertos no 4a, agora sobre a função movida).
   - `Test-Dnd` / `Set-Dnd`: liga, desliga, pasta inexistente.
2. `hook.Tests.ps1` e `hook.e2e.Tests.ps1`: os testes de `Get-SessionTitle` e de sessões trabalhando continuam passando; e2e novo: com `dnd.flag`, o `PermissionRequest` e o `PreToolUse` não criam `req-*.json` e não imprimem nada; sem o arquivo, continuam passando pelo widget; com o modo ligado, o `Stop` ainda grava o aviso.
3. Widget (Desktop):
   - o teste da fila continua sem `widget.log`;
   - novo: com `dnd.flag` na pasta de dados, a janela do widget fica invisível (nenhuma janela visível do processo) e deixa de ficar invisível quando o arquivo é apagado (~2 s);
   - renderização da amostra `sessions.png`.
4. À mão: ícone laranja/cinza, clique esquerdo liga e desliga, menu, lista de sessões abre e fecha com um clique sem atrapalhar o arrasto, duplo clique ainda traz a janela.

## Fora do escopo

- Atalhos globais (4c), diff e "Sempre permitir" (4c).
- Programar o modo por horário ou por tempo ("por 1 hora").
- Ação nas linhas da lista (clicar numa sessão para focá-la).
- Notificações do Windows (balões) da bandeja.
