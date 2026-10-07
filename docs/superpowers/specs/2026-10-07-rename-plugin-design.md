# Renomear o plugin para `opaiva-code-widget` (bloco 2)

Data: 2026-10-07 · Versão alvo: 2.0.0 · Status: aguardando revisão

## Contexto e objetivo

A partir do Claude Code 2.1.292, `claude plugin validate` recusa nomes de plugin de terceiros que começam com `claude-`. A mensagem é: *"Plugin name "claude-code-widget" is reserved: it passes as one of Anthropic's own … Name it for what it does."*

A instalação ainda funciona: isso foi verificado com o 2.1.292 numa configuração isolada. Mas o CI só passa com `continue-on-error` nos passos de validação, e a regra pode endurecer.

**Objetivo:** voltar a passar na validação sem exceções no CI. Para quem usa, nada muda além do nome do plugin.

## Decisões tomadas (com o usuário)

| Item | Decisão |
|---|---|
| Nome do plugin | `opaiva-code-widget` |
| Nome do marketplace | continua `claude-code-widget` |
| Repositório no GitHub | continua `OPaiva-1721/claude-code-widget` |
| Comando de instalação | `claude plugin install opaiva-code-widget@claude-code-widget` |
| `displayName` e título dos READMEs | continuam "Claude Code Widget" |
| Migração de quem já instalou | só um aviso no README. Sem cópia automática de `state.json` ou `sessions\` |
| Versão | 2.0.0, porque o comando de instalação muda |

Verificado com o Claude Code 2.1.292 em marketplaces descartáveis:
- plugin `opaiva-code-widget`: passa sem avisos;
- marketplace `claude-code-widget`: passa (a regra vale só para nomes de plugin);
- `displayName` "Claude Code Widget": passa (não é verificado);
- um nome de plugin contendo `claude` no meio, como `opaiva-claude-widget`: passa, mas com o aviso "reads as one of Anthropic's own". Por isso foi evitado.

## O que muda

1. **Pasta do plugin:** `plugins/claude-code-widget/` → `plugins/opaiva-code-widget/` via `git mv`, para manter o histórico dos arquivos.
2. **`plugins/opaiva-code-widget/.claude-plugin/plugin.json`:** `name` = `opaiva-code-widget`; `version` = `2.0.0`. Os demais campos ficam iguais.
3. **`.claude-plugin/marketplace.json`:** `plugins[0].name` = `opaiva-code-widget`; `plugins[0].source` = `./plugins/opaiva-code-widget`. O `name` do marketplace continua `claude-code-widget`.
4. **`.github/workflows/test.yml`:**
   - os dois passos de validação perdem o `continue-on-error: true` e o comentário sobre o nome reservado;
   - o caminho validado passa a ser `plugins/opaiva-code-widget`;
   - continua um comando por passo.
5. **Scripts do plugin:**
   - os comentários de cabeçalho `# claude-code-widget:` viram `# opaiva-code-widget:`;
   - a pasta de dados de reserva, usada só quando `CLAUDE_PLUGIN_DATA` não existe (scripts rodados fora de um plugin), passa de `.claude\claude-code-widget` para `.claude\opaiva-code-widget`;
   - **não muda:** o prefixo interno do mutex `Local\ClaudeCodeWidget-`, que não aparece para o usuário e está fixado em teste, nem qualquer comportamento.
6. **Testes e ferramentas:** os caminhos `plugins\claude-code-widget\...` passam para `plugins\opaiva-code-widget\...` em `tests/` e `tools/`. Os valores esperados ficam iguais, incluindo o teste do mutex fixado: ele recebe um caminho literal, que não muda.
7. **READMEs (`README.md` e `README.pt-BR.md`):**
   - instalar: `claude plugin install opaiva-code-widget@claude-code-widget` (CLI e `/plugin`);
   - atualizar: `claude plugin update opaiva-code-widget@claude-code-widget`;
   - desinstalar: `claude plugin uninstall opaiva-code-widget@claude-code-widget`;
   - pasta de dados: `%USERPROFILE%\.claude\plugins\data\opaiva-code-widget-claude-code-widget\`;
   - seção de desenvolvimento: caminhos de `validate` e do `plugin.json`;
   - **seção nova "Renamed in 2.0.0" / "Renomeado na 2.0.0"**, logo depois de "Update", com o passo a passo da migração e destaque no passo 1:

     ```powershell
     claude plugin uninstall claude-code-widget@claude-code-widget
     ```
     Depois: botão direito no widget antigo → **Close widget**. Em seguida:
     ```powershell
     claude plugin marketplace update claude-code-widget
     claude plugin install opaiva-code-widget@claude-code-widget
     ```
     Por fim, uma sessão nova ou `/reload-plugins`.

     A seção explica que o nome mudou porque o Claude Code reserva nomes de plugin começando com `claude-`. Avisa que o widget volta ao canto padrão da tela. E avisa que, se os dois plugins ficarem instalados juntos, cada pedido aparece em dois widgets.
8. **`CHANGELOG.md`:** entrada `## 2.0.0 (data do dia da implementação)` com a troca de nome, o novo comando de instalação e um link para a seção de migração do README.

## Riscos aceitos

- **Quem não ler o README fica na 1.1.1.** Depois do merge, o marketplace não lista mais `claude-code-widget`, então `claude plugin update claude-code-widget@claude-code-widget` não acha versões novas. A 1.1.1 continua funcionando.
- **Os dois plugins instalados ao mesmo tempo** geram dois widgets e dois hooks para cada pedido. A mitigação é só o aviso no README, por decisão do usuário. Detectar o plugin antigo automaticamente fica fora deste bloco.
- **O `displayName` "Claude Code Widget" pode entrar numa regra futura.** Hoje ele não é verificado. Se passar a ser, vira um bloco próprio.

## Testes e verificação

1. `tools\test.ps1` passa inteiro com os caminhos novos (76 testes).
2. Num Claude Code ≥ 2.1.292, `claude plugin validate .` e `claude plugin validate plugins/opaiva-code-widget` passam sem erros (o CLI fica no scratchpad, igual ao CI).
3. O CI no GitHub passa **sem** `continue-on-error`.
4. Depois do merge: migração na máquina do usuário seguindo a seção do README ao pé da letra. Resultado esperado: um único widget rodando de `plugins\cache\claude-code-widget\opaiva-code-widget\2.0.0\`, `claude plugin list` mostrando só `opaiva-code-widget`, e um pedido de permissão passando pelo widget.

## Fora do escopo

- Renomear o marketplace ou o repositório.
- Migração automática de `state.json`/`sessions\`.
- Detectar o plugin antigo instalado.
- Os ajustes menores adiados do bloco 1.
