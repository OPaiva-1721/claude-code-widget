# Tema, opacidade, volume, escala e pílula mínima (bloco 5a)

Data: 2026-10-08 · Versão alvo: 2.4.0 · Status: aguardando revisão

## Contexto e objetivo

Primeira metade do bloco visual. Deixa o widget confortável de olhar e de ouvir sem mudar o que ele faz. A segunda metade (5b) é o tema Minecraft, que reaproveita o mecanismo de tema criado aqui.

## Decisões (com o usuário)

| Item | Decisão |
|---|---|
| Tema | **Escuro, Claro e Automático** (segue o tema de aplicativos do Windows, lido ao abrir o widget). Padrão: escuro. |
| Tamanho | **Escala 100/125/150%** e **pílula mínima** (parado, só o ponto colorido). |
| Menu | **Passos fixos em submenus** do botão direito: sem sliders. |

Entendimento: quem já usa o widget não vê mudança nenhuma até mexer no menu. Sucesso = o menu muda tema, opacidade, volume, escala e pílula na hora, a escolha sobrevive a reiniciar, e o visual escuro continua exatamente igual.

## Preferências

Arquivo novo `prefs.json` na pasta de dados (o `state.json` continua só com a posição).

| Campo | Valores | Padrão |
|---|---|---|
| `theme` | `dark`, `light`, `auto` | `dark` |
| `opacity` | 0,5 a 1 (o menu oferece 1, 0,9, 0,8, 0,7, 0,6) | 1 |
| `volume` | 0 a 100 (o menu oferece 0, 25, 50, 75, 100) | 100 |
| `scale` | 1, 1,25, 1,5 | 1 |
| `minimal` | verdadeiro/falso | falso |

Arquivo ausente, ilegível ou com valor inválido: cada campo ruim volta ao padrão, sem erro. Valores numéricos fora da faixa são limitados; `scale` vira o valor permitido mais próximo. O widget grava o arquivo ao escolher no menu (só ele escreve).

## Mecanismo de tema

Hoje há cerca de 70 cores escritas à mão, no XAML e em código (`Get-Brush '#...'`). Em vez de trocar todos esses pontos, o tema é um **mapa de cores**: a paleta escura é a identidade (as cores de hoje) e o tema claro é um mapa `cor escura -> cor clara` para cada cor usada. `Get-Brush` passa a traduzir pelo mapa do tema atual, e `Set-Theme` percorre a árvore lógica da janela uma vez, trocando as cores dos elementos que já existem (pelo caminho cor atual -> cor escura -> cor do tema novo). O que for criado depois já nasce traduzido. Isso permite trocar de tema ao vivo, sem reabrir o widget, e dá ao tema Minecraft (5b) um lugar para entrar: é só outro mapa.

Regras do mapa (testadas): os valores de cada mapa são únicos, e nenhum valor coincide com uma chave (senão a volta cor atual -> escura ficaria ambígua). Cores sem entrada (branco do texto sobre botão laranja, laranja de destaque, verde do aviso) ficam iguais nos dois temas.

Limite aceito: a barra de rolagem usa a cor dentro de um modelo (template), fora da árvore lógica, e fica cinza-escuro nos dois temas.

`Automático` lê `HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize\AppsUseLightTheme` ao abrir; falha ao ler = escuro. Não acompanha uma troca do Windows com o widget aberto.

## Volume

`SoundPlayer` e `SystemSounds` não têm volume. Os três sons (pedido/pergunta, terminou, tudo pronto) passam por uma função `Play-Sound` que usa o `MediaPlayer` do WPF (propriedade `Volume`, 0 a 1):

- arquivos: o do aviso de pedido é o arquivo do som "Asterisco" do esquema de sons do Windows (registro `HKCU:\AppEvents\Schemes\Apps\.Default\SystemAsterisk\.Current`); terminou e tudo pronto continuam `Windows Notify System Generic.wav` e `tada.wav`;
- volume 0 não toca nada;
- se o arquivo não existe ou o `MediaPlayer` falha, cai no som do sistema de antes (`SystemSounds`), que **ignora o volume** (só o mudo vale). Limite aceito, registrado no log.

## Opacidade, escala e pílula mínima

- **Opacidade:** `Window.Opacity`, vale para todos os cartões.
- **Escala:** `ScaleTransform` como `LayoutTransform` do cartão; a janela continua ancorada pelo canto inferior direito, então cresce para cima e para a esquerda.
- **Pílula mínima:** parado, esconde "Claude Code" e o texto de estado e deixa só o ponto. O clique ainda abre a lista de sessões; o texto de estado (ex.: "2 trabalhando") passa a ser a dica (tooltip) da pílula. Cartões de pedido, pergunta e aviso não mudam.

## Menu do botão direito

Submenus, cada um com a opção atual marcada: **Tema** (Escuro, Claro, Automático), **Opacidade** (100, 90, 80, 70, 60%), **Volume** (Mudo, 25, 50, 75, 100%), **Tamanho** (100, 125, 150%), **Pílula mínima** (liga/desliga), **Fechar widget** (já existe). Escolher aplica na hora e grava `prefs.json`.

## O que muda

- `common.ps1`: `Get-DefaultPrefs`, `Read-Prefs`, `Save-Prefs`, `Get-WindowsLightTheme`, `Resolve-Theme`, `Get-ColorMap`, `Convert-ThemeColor`.
- `widget.ps1`: lê as preferências ao abrir; `Get-Brush` traduz pelo mapa; `Set-Theme`; `Set-Opacity`, `Set-Scale`, `Set-Minimal`; `Play-Sound`; submenus. Parâmetro novo `-Theme` (só para `-RenderSamples`, usado pelos prints).
- `strings.json`: rótulos dos submenus (pt e en).
- `tools/render-screenshots.ps1`: gera também `docs/images/{en,pt}/light-permission.png`.
- Documentação: READMEs (menu, `prefs.json`, aviso do som de fallback), `CHANGELOG.md` (2.4.0), versão em `plugin.json`.

## Riscos aceitos

- **Contraste do tema claro** conferido só por mim e pelos prints; o usuário valida na tela.
- **Troca ao vivo** depende de percorrer a árvore; elementos escondidos criados depois nascem certos, mas um elemento fora da árvore lógica (modelo de rolagem) não troca.
- **Volume** sem efeito quando cai no `SystemSounds`.
- **Testes:** os itens do menu e o som de verdade não têm teste automático; a lógica pura tem, e há testes de janela para escala e tema.

## Testes e verificação

1. `common.Tests.ps1`: `Read-Prefs` (ausente, lixo, campos inválidos isolados, limites, escala mais próxima, ida e volta com `Save-Prefs`); `Resolve-Theme` (dark/light, auto com claro e escuro); `Get-ColorMap` (escuro vazio; claro com valores únicos e disjuntos das chaves; cobre toda cor `#RRGGBB` escrita em `widget.ps1`); `Convert-ThemeColor`.
2. `widget.Tests.ps1` (Desktop): o print com `-Theme light` tem fundo do cartão claro e o escuro continua escuro; um widget com `prefs.json` de escala 1,5 abre com janela cerca de 1,5 vez maior que com escala 1; sem erro no `widget.log`.
3. À mão: menu (cada submenu), tema ao vivo, volume audível em 25% contra 100%, mudo, pílula mínima, reiniciar mantendo as escolhas.

## Fora do escopo

Sliders, cores livres, acompanhar o Windows ao vivo no modo Automático, trocar os sons, o tema Minecraft (5b).
