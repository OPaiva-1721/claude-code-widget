# Diff no cartão, "Sempre permitir" e atalhos globais (bloco 4c)

Data: 2026-10-08 · Versão alvo: 2.3.0 · Status: aguardando revisão

## Contexto e objetivo

Última parte do bloco 4. Os três itens mexem no cartão de pedido de permissão.

1. **Diff do Edit/Write:** hoje o cartão de um `Edit` ou `Write` mostra só o caminho do arquivo. Passa a mostrar o que muda.
2. **"Sempre permitir":** botões que aprovam e gravam, ao mesmo tempo, uma das regras que o próprio Claude Code sugere (as mesmas do menu dele no VS Code).
3. **Atalhos globais:** aprovar, negar e ligar/desligar o "não perturbe" com o teclado, com qualquer janela em foco.

## Formato do "Sempre permitir" (confirmado na documentação do Claude Code)

- O evento `PermissionRequest` traz `permission_suggestions`: lista de objetos `{ type, rules, behavior, destination, mode, directories }`. Exemplo da documentação: `{"type":"addRules","rules":["Bash(rm *)"],"behavior":"allow","destination":"session","mode":null}` e `{"type":"setMode","behavior":"allow","destination":"session","mode":"auto"}`.
- A resposta do hook, para aprovar e gravar: `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","updatedPermissions":[{"type":"addRules","rules":["Bash(git *)"],"destination":"projectSettings"}]}}}`.
- `destination`: `session` (até a sessão acabar), `localSettings` (`.claude/settings.local.json`), `projectSettings` (`.claude/settings.json`), `userSettings` (`~/.claude/settings.json`).
- A documentação não mostra o campo `behavior` no exemplo de saída. O hook devolve a sugestão como veio (sem `mode: null`), que inclui `behavior`. Se o Claude Code ignorar o campo, ele ignora; a aprovação em si (`behavior: allow`) não depende disso. A verificação final confere na prática.

## Decisões (com o usuário)

| Item | Decisão |
|---|---|
| Sugestões oferecidas | **Todas** as que o Claude Code envia, com as exceções de segurança abaixo. |
| Atalhos | **Ctrl+Alt+Y** aprova, **Ctrl+Alt+N** nega, **Ctrl+Alt+D** liga/desliga o "não perturbe". Perguntas continuam no mouse. |
| Ativação dos atalhos | **Desligados** até `CLAUDE_WIDGET_HOTKEYS=1` no `settings.json`. |

Exceções de segurança (decisão minha, para o usuário rever):
- O hook **nunca inventa** uma sugestão: o botão grava exatamente uma sugestão que o Claude Code mandou naquele pedido, escolhida por **índice**. A resposta do widget (um arquivo comum) só carrega o índice; o conteúdo vem da cópia do próprio hook. Índice fora da lista: aprova sem gravar nada.
- Não são oferecidos: `removeRules` e `replaceRules` (apagariam regras que o usuário tem), sugestões com `behavior: deny`, e `setMode` para `bypassPermissions` (liberaria tudo). O resto (`addRules` com `allow`, `setMode` para os outros modos, `addDirectories`) é oferecido.

## O que muda

### common.ps1

- `Get-DiffLines($Change)` → lista de `{ kind; text }` com `kind` = `add`, `del` ou `more`:
  - `$Change` é `@{ kind = 'edit'|'write'; edits = @(@{ old; new }); content }`.
  - Edit: tira as linhas iguais no começo e no fim de `old` e `new` (assim uma troca de uma linha não mostra o bloco inteiro); depois, `del` para cada linha de `old` e `add` para cada linha de `new`.
  - Write: `add` para cada linha de `content`.
  - No máximo 14 linhas (somando todas as edições); o que passar vira uma linha `more` com a contagem (`+N linhas`). Várias edições (`MultiEdit`) vão em sequência, uma separação `more` vazia entre elas não é necessária.
- `ConvertTo-Hotkey([string]$Text)` → `@{ mod; vk }` ou `$null`: aceita `Ctrl`, `Alt`, `Shift`, `Win` e uma tecla (`A`-`Z`, `0`-`9`, `F1`-`F24`), em qualquer caixa, separados por `+`. Exige pelo menos um modificador. `Ctrl+Alt+Y` → `mod = 0x4003` (inclui `MOD_NOREPEAT`), `vk = 0x59`.

### hook.ps1

- `New-ChangeInfo($Tool, $ToolInput)` → `@{ kind; edits; content }` ou `$null` para `Edit`, `Write` e `MultiEdit`; cada texto cortado em 4000 caracteres e no máximo 5 edições.
- `Get-OfferedSuggestions($Suggestions)` → só as sugestões permitidas (regras acima), na ordem original, com o índice original guardado (`index`). O pedido de permissão ganha `change` e `suggestions` (cada item: `index`, `type`, `rules`, `destination`, `mode`, `directories`).
- `New-PermissionOutput` aceita `$UpdatedPermissions` opcional e o põe em `decision.updatedPermissions`.
- Resposta do widget `{ decision = 'allowAlways'; index = N }`: o hook procura, na cópia que ele tem de `permission_suggestions`, a sugestão de índice `N`; se ela está entre as oferecidas, devolve `allow` com `updatedPermissions = @(<a sugestão sem mode nulo>)`; senão, devolve só `allow`.

### widget.ps1

- **Diff:** abaixo da caixa de detalhe, uma caixa `ChangeBox` (some quando não há `change`) com `Get-DiffLines`: linha `del` com fundo `#3A1E1E`, texto `#F29090` e prefixo `- `; `add` com fundo `#1E3A2A`, texto `#7FD3A0` e prefixo `+ `; `more` cinza, `+N linhas`. Fonte mono, tamanho 12, sem quebra de linha (rolagem horizontal se precisar), altura máxima 220.
- **Sempre permitir:** abaixo dos botões, uma `WrapPanel` com um botão por sugestão oferecida (no máximo 3; o resto não aparece). Texto:
  - `addRules`: `Sempre permitir: <regra>` (várias regras: a primeira e `+N`);
  - `setMode`: `Mudar o modo para <modo>`;
  - `addDirectories`: `Sempre permitir a pasta <pasta>`;
  - e, em todos, o destino em letras pequenas: `nesta sessão`, `só aqui (local)`, `neste projeto`, `em todos os projetos`.
  Texto cortado em 60 caracteres, com a versão inteira no tooltip. O clique grava `res-<id>.json` com `@{ decision = 'allowAlways'; index = <índice original> }`.
- **Atalhos:** com `CLAUDE_WIDGET_HOTKEYS=1`, o widget registra três atalhos com `RegisterHotKey` e um `HwndSourceHook` (verificado: funciona no processo WPF do PowerShell 5.1, o callback roda no thread da interface). Teclas configuráveis por `CLAUDE_WIDGET_KEY_APPROVE`, `CLAUDE_WIDGET_KEY_DENY` e `CLAUDE_WIDGET_KEY_DND` (padrão `Ctrl+Alt+Y`, `Ctrl+Alt+N`, `Ctrl+Alt+D`); um valor que `ConvertTo-Hotkey` não entende é ignorado com uma linha no `widget.log`, e um atalho que outro programa já usa também (`RegisterHotKey` falha: uma linha no log). Aprovar/negar só agem se o cartão na tela é um pedido de permissão (nada com pergunta, aviso ou pílula), e passam pelo mesmo `Send-Response` (com a proteção de 700 ms contra clique duplo). O atalho do "não perturbe" liga/desliga como o clique na bandeja. Atalhos são removidos ao fechar o widget.
- Os botões **Aprovar** e **Negar** mostram a tecla quando o atalho está ativo (`Aprovar (Ctrl+Alt+Y)`).

### Textos, exemplos e documentação

- `strings.json`: `alwaysRule`, `alwaysMode`, `alwaysDir`, `alwaysMore`, `destSession`, `destLocal`, `destProject`, `destUser`, `diffMore` (`+{0} linhas`), `modeNames` (nomes dos modos) em pt e en.
- `tools/samples.json` e `tools/render-screenshots.ps1`: um exemplo de `Edit` com diff e com dois botões de "sempre permitir"; imagem `edit.png` em `docs/images/{en,pt}`.
- READMEs: diff, "Sempre permitir" (e o que cada destino quer dizer), atalhos (com o `CLAUDE_WIDGET_HOTKEYS`, as três variáveis de tecla e o aviso de que a combinação deixa de funcionar nos outros programas), na seção de configuração; a seção de segurança diz que "Sempre permitir" grava uma regra permanente e que só oferece o que o Claude Code sugeriu.
- `CHANGELOG.md`: entrada 2.3.0.

## Riscos aceitos

- **Regra permanente por um clique:** "Sempre permitir" é mais poderoso que **Aprovar**. O botão mostra a regra e onde ela é gravada, o hook só grava sugestões do próprio Claude Code, e as exceções acima tiram as mais perigosas. Um clique errado ainda grava uma regra `Bash(...)` que o Claude Code considerou razoável sugerir.
- **Formato:** o campo `behavior` na saída não está na documentação; se a saída for rejeitada, o pedido continua sendo aprovado, só a regra não é gravada. Conferido à mão no fim.
- **Atalho aprova sem olhar:** com o widget escondido (não perturbe) não há cartão, então nada é aprovado; com o cartão na tela o atalho aprova o que está nele. Por isso vem desligado por padrão.
- **Diff simples:** é remover tudo que saiu e adicionar tudo que entrou (depois de tirar o começo e o fim iguais), não um diff linha a linha; para trocas grandes ele é mais verboso que um diff de verdade.
- **Conflito de atalho:** outro programa que já usa a combinação vence; o widget avisa no log e segue.
- **Testes:** o clique de "Sempre permitir" e o aspecto do diff não têm teste automático (a lógica por trás sim). O atalho é testado com uma tecla simulada.

## Testes e verificação

1. `common.Tests.ps1`: `Get-DiffLines` (edit com uma linha trocada no meio de um bloco, edit sem nada em comum, write, limite de 14 linhas com `more`, várias edições, texto vazio); `ConvertTo-Hotkey` (válidos, caixa, sem modificador, tecla inválida, `F13`, vazio).
2. `hook.Tests.ps1`: `New-ChangeInfo` (Edit, Write, MultiEdit, outra ferramenta, corte de 4000, no máximo 5 edições); `Get-OfferedSuggestions` (mantém `addRules allow`, `setMode acceptEdits` e `addDirectories`; descarta `removeRules`, `replaceRules`, `deny` e `setMode bypassPermissions`; guarda o índice original); `New-PermissionOutput` com `updatedPermissions`.
3. `hook.e2e.Tests.ps1`: o pedido de um `Edit` leva `change` e `suggestions`; resposta `allowAlways` com índice válido imprime `updatedPermissions` com aquela sugestão e sem `mode: null`; índice inválido ou de sugestão não oferecida imprime só `allow`; resposta forjada com conteúdo no lugar do índice é ignorada.
4. Widget (Desktop): com `CLAUDE_WIDGET_HOTKEYS=1` e as teclas trocadas para `F13`/`F14`/`F15` (por `CLAUDE_WIDGET_KEY_*`), uma tecla simulada aprova o pedido na fila (o `res-<id>.json` aparece com `allow`), outra nega, e a terceira cria o `dnd.flag`; sem a variável, a mesma tecla não faz nada; a renderização das amostras inclui `edit.png`.
5. À mão: um `Edit` de verdade mostra o diff certo; **Sempre permitir** grava a regra (conferir o `settings.local.json` ou a sessão) e a próxima ação igual passa sem cartão; os atalhos com a combinação padrão.

## Fora do escopo

- Aprovar perguntas por atalho.
- Desfazer ou listar as regras gravadas.
- Diff de verdade (LCS) e destaque de sintaxe.
- Atalho para "Ir para a sessão".
