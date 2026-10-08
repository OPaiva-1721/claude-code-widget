# Tema, opacidade, volume, escala e pílula mínima Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preferências visuais e de som (`prefs.json`) editáveis pelo menu do botão direito: tema escuro/claro/automático, opacidade, volume, escala e pílula mínima.

**Architecture:** Lógica pura (ler/validar preferências, mapa de cores do tema) em `common.ps1`, testada com Pester. O widget traduz toda cor por um mapa do tema (`Get-Brush`) e troca as cores dos elementos existentes percorrendo a árvore lógica (`Set-Theme`). Sons passam por `Play-Sound` com `MediaPlayer` (tem volume).

**Tech Stack:** Windows PowerShell 5.1, WPF, Pester 5.5+.

**Spec:** `docs/superpowers/specs/2026-10-08-visual-prefs-design.md`

## Global Constraints

- Arquivos `.ps1` só ASCII (texto de interface vai em `strings.json`, UTF-8). Evitar `\t`, `\u`, `\b` em strings escritas por ferramenta (viram caracteres de controle): conferir com `grep -c $'\t'`.
- Nenhum parâmetro de handler chamado `$s` (`$S` é a tabela de textos): usar `$src`, `$e`.
- Arquivos `.ps1` com CRLF (`.gitattributes`); conferir com `git diff --stat` que não há troca de fim de linha em massa.
- O visual escuro deve continuar idêntico ao de hoje; sem `prefs.json`, tudo se comporta como antes.
- Versão alvo 2.4.0 (`plugin.json` e `CHANGELOG.md` batem; há teste).
- Testes de janela (tag `Desktop`) usam `CLAUDE_WIDGET_NO_TRAY=1` e posicionam o widget de teste no canto superior esquerdo via `state.json` (`{"right":420,"bottom":220}`), para que ninguém clique nele sem querer.
- Suíte completa: `powershell -NoProfile -File tools\test.ps1` (hoje 214 testes passando).

## Review Focus

- `prefs.json` com lixo, campos faltando, valores de tipo errado (`"opacity": "x"`, `"volume": 1e9`, `NaN`) nunca derruba o widget: cada campo ruim volta ao padrão (testado na Task 1).
- Trocar de tema várias vezes seguidas (escuro -> claro -> escuro -> automático) deixa as cores exatamente como no começo; a volta não pode acumular erro (testado: ida e volta do mapa na Task 1; manual na Task 5).
- Cartões já abertos (pedido/pergunta/aviso na tela) trocam de cor junto com a pílula, e o que for criado depois nasce no tema certo (Task 2).
- Escala 150% não pode mandar o cartão para fora da tela: a janela continua ancorada no canto inferior direito (Task 3, teste de tamanho + conferência manual).
- Volume 0 não toca nenhum som, inclusive o fallback do sistema; arquivo de som ausente ou `MediaPlayer` falhando cai no som do sistema sem derrubar nada (Task 4).
- A pílula mínima não pode esconder o estado sem alternativa: o texto vira dica e o clique ainda abre a lista de sessões (Task 3).

---

### Task 1: Preferências e mapa de cores em common.ps1

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (acrescentar no fim)
- Test: `tests/common.Tests.ps1` (acrescentar no fim)

**Interfaces:**
- Produces: `Get-DefaultPrefs` -> hashtable `theme, opacity, volume, scale, minimal`; `Read-Prefs([string]$Dir)` -> hashtable completa e válida; `Save-Prefs([string]$Dir, $Prefs)` -> `$true`/`$false`; `Get-WindowsLightTheme` -> bool; `Resolve-Theme([string]$Theme, [bool]$WindowsIsLight = $false)` -> `'dark'|'light'`; `Get-ColorMap([string]$Theme)` -> hashtable `#RRGGBB escuro -> #RRGGBB do tema` (vazia para `dark`); `Convert-ThemeColor([string]$Hex, [hashtable]$Map)` -> `#RRGGBB`.

- [ ] **Step 1: Escrever os testes que falham**

Acrescentar ao fim de `tests/common.Tests.ps1`:

````powershell
Describe 'Read-Prefs / Save-Prefs' {
    BeforeEach {
        $dir = Join-Path $TestDrive ('p' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $file = Join-Path $dir 'prefs.json'
    }
    It 'gives the defaults when the file is missing' {
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'dark'
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
        $p.minimal | Should -BeFalse
    }
    It 'gives the defaults when the file is not JSON' {
        [IO.File]::WriteAllText($file, '{{ not json')
        (Read-Prefs $dir).theme | Should -Be 'dark'
    }
    It 'reads valid values' {
        [IO.File]::WriteAllText($file, '{"theme":"light","opacity":0.8,"volume":25,"scale":1.5,"minimal":true}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'light'
        $p.opacity | Should -Be 0.8
        $p.volume | Should -Be 25
        $p.scale | Should -Be 1.5
        $p.minimal | Should -BeTrue
    }
    It 'falls back field by field when a value is invalid' {
        [IO.File]::WriteAllText($file, '{"theme":"pink","opacity":"x","volume":true,"scale":null,"minimal":"yes"}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'dark'
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
        $p.minimal | Should -BeFalse
    }
    It 'keeps the valid fields next to an invalid one' {
        [IO.File]::WriteAllText($file, '{"theme":"auto","opacity":"x","volume":50}')
        $p = Read-Prefs $dir
        $p.theme | Should -Be 'auto'
        $p.volume | Should -Be 50
    }
    It 'limits numbers to their range and snaps the scale to the nearest allowed one' {
        [IO.File]::WriteAllText($file, '{"opacity":0.1,"volume":1000000000,"scale":1.4}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 0.5
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.5
        [IO.File]::WriteAllText($file, '{"opacity":7,"volume":-5,"scale":0.2}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 0
        $p.scale | Should -Be 1.0
    }
    It 'ignores NaN and infinity' {
        [IO.File]::WriteAllText($file, '{"opacity":"NaN","volume":"Infinity","scale":"-Infinity"}')
        $p = Read-Prefs $dir
        $p.opacity | Should -Be 1.0
        $p.volume | Should -Be 100
        $p.scale | Should -Be 1.0
    }
    It 'writes what it reads back (round trip)' {
        $want = @{ theme = 'auto'; opacity = 0.7; volume = 0; scale = 1.25; minimal = $true }
        Save-Prefs $dir $want | Should -BeTrue
        $p = Read-Prefs $dir
        foreach ($k in $want.Keys) { $p[$k] | Should -Be $want[$k] }
    }
    It 'replaces an existing file' {
        Save-Prefs $dir @{ theme = 'light'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } | Out-Null
        Save-Prefs $dir @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } | Should -BeTrue
        (Read-Prefs $dir).theme | Should -Be 'dark'
    }
    It 'returns false instead of throwing when the folder does not exist' {
        Save-Prefs (Join-Path $TestDrive 'nope\nope') (Get-DefaultPrefs) | Should -BeFalse
    }
}

Describe 'Resolve-Theme' {
    It 'resolves <theme> with Windows light=<light> to <want>' -ForEach @(
        @{ theme = 'dark'; light = $false; want = 'dark' }
        @{ theme = 'dark'; light = $true; want = 'dark' }
        @{ theme = 'light'; light = $false; want = 'light' }
        @{ theme = 'auto'; light = $true; want = 'light' }
        @{ theme = 'auto'; light = $false; want = 'dark' }
        @{ theme = 'weird'; light = $true; want = 'dark' }
    ) {
        Resolve-Theme $theme $light | Should -Be $want
    }
}

Describe 'Get-ColorMap' {
    BeforeAll {
        $widgetText = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'plugins\opaiva-code-widget\scripts\widget.ps1'))
        $native = @('#FFFFFF', '#D97757', '#2F6F4E')   # same in both themes
    }
    It 'is empty for the dark theme' {
        (Get-ColorMap 'dark').Count | Should -Be 0
    }
    It 'has unique values, none of them a key or a native color' {
        $m = Get-ColorMap 'light'
        $m.Count | Should -BeGreaterThan 20
        @($m.Values | Select-Object -Unique).Count | Should -Be $m.Count
        foreach ($v in $m.Values) {
            $m.ContainsKey($v) | Should -BeFalse -Because "$v is also a key"
            $native -contains $v | Should -BeFalse -Because "$v is a native color"
        }
    }
    It 'covers every color written in widget.ps1' {
        $m = Get-ColorMap 'light'
        $hex = [regex]::Matches($widgetText, '#[0-9A-Fa-f]{6}(?![0-9A-Fa-f])') | ForEach-Object { $_.Value.ToUpper() } | Sort-Object -Unique
        $missing = @($hex | Where-Object { -not $m.ContainsKey($_) -and ($native -notcontains $_) })
        $missing | Should -BeNullOrEmpty
    }
    It 'keeps text readable: dark text on the light card, light text on the dark card' {
        function Get-Lum([string]$h) { (0.299 * [Convert]::ToInt32($h.Substring(1, 2), 16) + 0.587 * [Convert]::ToInt32($h.Substring(3, 2), 16) + 0.114 * [Convert]::ToInt32($h.Substring(5, 2), 16)) }
        $m = Get-ColorMap 'light'
        (Get-Lum $m['#1E1E22']) | Should -BeGreaterThan 200   # card
        (Get-Lum $m['#F4F4F6']) | Should -BeLessThan 60       # title
        (Get-Lum $m['#E8E8EC']) | Should -BeLessThan 60       # main text
    }
}

Describe 'Convert-ThemeColor' {
    It 'maps a known color, ignoring letter case' {
        $m = @{ '#1E1E22' = '#FAFAFB' }
        Convert-ThemeColor '#1e1e22' $m | Should -Be '#FAFAFB'
    }
    It 'keeps a color that has no entry' {
        Convert-ThemeColor '#D97757' @{ '#1E1E22' = '#FAFAFB' } | Should -Be '#D97757'
    }
    It 'keeps everything with an empty map' {
        Convert-ThemeColor '#1E1E22' @{} | Should -Be '#1E1E22'
    }
    It 'goes back to the original color through the reverse map' {
        $m = Get-ColorMap 'light'
        $back = @{}
        foreach ($k in $m.Keys) { $back[$m[$k]] = $k }
        foreach ($k in $m.Keys) { Convert-ThemeColor (Convert-ThemeColor $k $m) $back | Should -Be $k }
    }
}
````

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\common.Tests.ps1 -FullNameFilter '*Prefs*','*Resolve-Theme*','*ColorMap*','*Convert-ThemeColor*' -Output Minimal"`
Expected: falhas "The term 'Read-Prefs' is not recognized" (e equivalentes).

- [ ] **Step 3: Implementar**

Acrescentar ao fim de `plugins/opaiva-code-widget/scripts/common.ps1` (CRLF; ASCII):

````powershell

# ---------------- Preferences (prefs.json) and theme ----------------

function Get-DefaultPrefs { @{ theme = 'dark'; opacity = 1.0; volume = 100; scale = 1.0; minimal = $false } }

# prefs.json in the data dir. Always returns a complete, valid set: a missing file gives the defaults,
# and each bad field falls back to its default on its own.
function Read-Prefs([string]$Dir) {
    $p = Get-DefaultPrefs
    $j = $null
    try {
        $path = Join-Path $Dir 'prefs.json'
        if (Test-Path -LiteralPath $path) { $j = [IO.File]::ReadAllText($path, (Get-Utf8NoBom)) | ConvertFrom-Json }
    } catch { return $p }
    if ($null -eq $j) { return $p }
    $num = {
        param($v)
        $n = 0.0
        if ($null -ne $v -and $v -isnot [bool] -and [double]::TryParse([string]$v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and
            -not [double]::IsNaN($n) -and -not [double]::IsInfinity($n)) { return $n }
        return $null
    }
    if ($j.theme -is [string] -and @('dark', 'light', 'auto') -contains $j.theme) { $p.theme = $j.theme }
    $n = & $num $j.opacity
    if ($null -ne $n) { $p.opacity = [math]::Min(1.0, [math]::Max(0.5, $n)) }
    $n = & $num $j.volume
    if ($null -ne $n) { $p.volume = [int][math]::Min(100, [math]::Max(0, [math]::Round($n))) }
    $n = & $num $j.scale
    if ($null -ne $n) {
        $best = 1.0
        foreach ($c in 1.0, 1.25, 1.5) { if ([math]::Abs($c - $n) -lt [math]::Abs($best - $n)) { $best = $c } }
        $p.scale = $best
    }
    if ($j.minimal -is [bool]) { $p.minimal = $j.minimal }
    return $p
}

# Overwrites prefs.json. Returns $false (never throws) when it cannot write.
function Save-Prefs([string]$Dir, $Prefs) {
    try {
        $o = [ordered]@{ theme = [string]$Prefs.theme; opacity = [double]$Prefs.opacity; volume = [int]$Prefs.volume; scale = [double]$Prefs.scale; minimal = [bool]$Prefs.minimal }
        [IO.File]::WriteAllText((Join-Path $Dir 'prefs.json'), ($o | ConvertTo-Json -Compress), (Get-Utf8NoBom))
        return $true
    } catch { return $false }
}

# True when Windows apps use the light theme (HKCU ...\Themes\Personalize\AppsUseLightTheme = 1)
function Get-WindowsLightTheme {
    try {
        $v = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return ($v.AppsUseLightTheme -eq 1)
    } catch { return $false }
}

# 'dark' or 'light' from the saved choice ('auto' follows Windows)
function Resolve-Theme([string]$Theme, [bool]$WindowsIsLight = $false) {
    if ($Theme -eq 'light') { return 'light' }
    if ($Theme -eq 'auto' -and $WindowsIsLight) { return 'light' }
    return 'dark'
}

# The widget is written in the dark colors. A theme is a map "dark color -> this theme's color"; the
# dark theme is the empty map. Colors without an entry (white on the orange buttons, the orange accent,
# the green of the finished notice) are the same in every theme. Values must be unique and never also
# a key, so that going back (theme color -> dark color) is unambiguous: Get-ColorMap's tests enforce it.
function Get-ColorMap([string]$Theme) {
    if ($Theme -ne 'light') { return @{} }
    return @{
        '#1E1E22' = '#FAFAFB'; '#34343B' = '#D9D9DF'; '#4A4A54' = '#B8B8C2'; '#5FB98A' = '#2F9A66'
        '#E8E8EC' = '#1F1F24'; '#7E7E88' = '#6A6A74'; '#F4F4F6' = '#17171A'; '#8A8A93' = '#70707C'
        '#3A2A24' = '#FBE6DC'; '#F0A58A' = '#B4502A'; '#26262C' = '#ECECF0'; '#C8C8D0' = '#3A3A44'
        '#2E2A1E' = '#FBF1D2'; '#E8C770' = '#8A6A10'; '#DADAE0' = '#2A2A32'; '#141417' = '#F1F1F4'
        '#2C2C33' = '#DCDCE2'; '#6E6E78' = '#7C7C86'; '#6A3A3A' = '#E3A8A8'; '#F29090' = '#B03A3A'
        '#2A2A30' = '#E6E6EB'; '#3A3A42' = '#CFCFD6'; '#7AA2F7' = '#3E6BD6'; '#1F2E26' = '#DDF1E6'
        '#7FD1A4' = '#1F7A4C'; '#3A1E1E' = '#FBE3E3'; '#1E3A2A' = '#DDF3E5'; '#7FD3A0' = '#1B7545'
        '#24242A' = '#F3F3F6'; '#F0F0F4' = '#202028'; '#9A9AA4' = '#5E5E68'; '#22304A' = '#DCE6FB'
        '#9DB8F5' = '#2F57B8'
    }
}

# The color a map gives to $Hex (case-insensitive); unchanged when it has no entry
function Convert-ThemeColor([string]$Hex, [hashtable]$Map) {
    if ($Map -and $Map.ContainsKey($Hex)) { return $Map[$Hex] }
    return $Hex
}
````

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\common.Tests.ps1 -Output Minimal"`
Expected: PASS em tudo. Se "has unique values..." ou "covers every color" falharem, corrija o mapa (cor repetida ou faltando) e rode de novo.

- [ ] **Step 5: Suíte completa e commit**

Run: `powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop` -> Expected: tudo verde (inclui o teste de ASCII dos scripts).

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 tests/common.Tests.ps1
git commit -m "feat: prefs.json reader/writer and light theme color map"
```

---

### Task 2: Tema no widget (mapa, troca ao vivo, -Theme)

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1` (param, `Get-Brush`, `Set-Theme`, aplicação inicial)
- Test: `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Read-Prefs`, `Get-WindowsLightTheme`, `Resolve-Theme`, `Get-ColorMap`, `Convert-ThemeColor` (Task 1).
- Produces: `$script:prefs` (hashtable de preferências em uso); `$script:colorMap`; `Set-Theme([string]$name)` (nome já resolvido: `dark`/`light`); parâmetro `-Theme` do script (só vale com `-RenderSamples`).

- [ ] **Step 1: Escrever o teste que falha**

Em `tests/widget.Tests.ps1`, dentro de `Describe 'widget.ps1 rendering'` (depois do `It` existente), acrescentar:

````powershell
    It 'draws the light theme with a light card and the dark theme with a dark card' {
        Add-Type -AssemblyName System.Drawing
        function Get-CardPixel([string]$theme) {
            $out = Join-Path $TestDrive "t-$theme"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang en -Theme $theme
            $LASTEXITCODE | Should -Be 0
            $bmp = New-Object System.Drawing.Bitmap (Join-Path $out 'permission.png')
            try {
                # 2x render: x = 50 px is inside the card's left padding, at mid height there is no content
                $c = $bmp.GetPixel(50, [int]($bmp.Height / 2))
                return [int](($c.R + $c.G + $c.B) / 3)
            }
            finally { $bmp.Dispose() }
        }
        (Get-CardPixel 'light') | Should -BeGreaterThan 200
        (Get-CardPixel 'dark') | Should -BeLessThan 80
    }
````

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\widget.Tests.ps1 -FullNameFilter '*light theme*' -Output Detailed"`
Expected: FAIL (o parâmetro `-Theme` não existe: o PowerShell recusa a chamada, `$LASTEXITCODE` diferente de 0).

- [ ] **Step 3: Implementar**

Em `widget.ps1`:

1. Bloco `param`: acrescentar `[string]$Theme = ''` depois de `[string]$OutDir = ''` (ajustando a vírgula). Atualizar o cabeçalho do arquivo com `-Theme dark|light` na linha do `-RenderSamples`.

2. Depois de `$Lang = Resolve-Lang $Lang` / `$S = Get-Strings $Lang`, acrescentar:

````powershell
# Preferences (prefs.json): theme, opacity, volume, scale, minimal pill. -Theme only applies to -RenderSamples.
$script:prefs = Read-Prefs $Data
if ($RenderMode -and $Theme) { $script:prefs.theme = $Theme }
````

3. Substituir a função `Get-Brush` (e a linha `$script:brushes = @{}`) por:

````powershell
    # Every color in this file is written in the dark theme; the current theme's map translates it
    $script:colorMap = @{}
    $script:brushes = @{}
    function New-FrozenBrush([string]$hex) {
        if (-not $script:brushes.ContainsKey($hex)) {
            $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
            $b.Freeze()
            $script:brushes[$hex] = $b
        }
        return $script:brushes[$hex]
    }
    function Get-Brush([string]$hex) { return New-FrozenBrush (Convert-ThemeColor $hex $script:colorMap) }

    # Switches the theme live: recolors every element already created (walking the logical tree), by
    # way of the dark color it started from; what is created later is translated by Get-Brush.
    function Convert-ElementColors($el, [hashtable]$back, [hashtable]$new) {
        foreach ($n in 'Foreground', 'Background', 'BorderBrush', 'Fill', 'Stroke', 'CaretBrush', 'SelectionBrush') {
            try {
                $prop = $el.GetType().GetProperty($n)
                if (-not $prop -or -not $prop.CanWrite -or $prop.GetIndexParameters().Count -ne 0) { continue }
                $b = $prop.GetValue($el, $null)
                if ($b -isnot [System.Windows.Media.SolidColorBrush] -or $b.Color.A -ne 255) { continue }
                $hex = '#{0:X2}{1:X2}{2:X2}' -f $b.Color.R, $b.Color.G, $b.Color.B
                $dark = Convert-ThemeColor $hex $back
                $target = Convert-ThemeColor $dark $new
                if ($target -ne $hex) { $prop.SetValue($el, (New-FrozenBrush $target), $null) }
            } catch {}
        }
        foreach ($child in [System.Windows.LogicalTreeHelper]::GetChildren($el)) {
            if ($child -is [System.Windows.DependencyObject]) { Convert-ElementColors $child $back $new }
        }
    }
    function Set-Theme([string]$name) {
        $new = Get-ColorMap $name
        $back = @{}
        foreach ($k in $script:colorMap.Keys) { $back[$script:colorMap[$k]] = $k }
        Convert-ElementColors $win $back $new
        $script:colorMap = $new
    }
````

4. Depois do bloco do menu de contexto (`$ui.Card.ContextMenu = $menu`), aplicar o tema inicial:

````powershell
    try { Set-Theme (Resolve-Theme $script:prefs.theme (Get-WindowsLightTheme)) } catch { Write-Log $_ }
````

Observação: `Set-Theme` roda antes de `Export-Samples`/do loop, então os cartões criados depois já saem no tema certo; o `-Theme` do render passa pela mesma linha (`$script:prefs.theme`), e no render `auto` seguiria o Windows.

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\widget.Tests.ps1 -FullNameFilter '*rendering*' -Output Detailed"`
Expected: PASS (inclui o teste em inglês e português já existente).

Conferir os prints à mão uma vez: `powershell -NoProfile -File plugins\opaiva-code-widget\scripts\widget.ps1 -RenderSamples tools\samples.json -OutDir $env:TEMP\light -Lang en -Theme light` e abrir `permission.png`, `edit.png`, `question.png`, `done.png` e `sessions.png`: texto legível, nenhum bloco escuro esquecido. Se algum aparecer, a cor falta no mapa (o teste "covers every color" deve pegar) ou vem de um modelo (rolagem).

- [ ] **Step 5: Suíte completa e commit**

Run: `powershell -NoProfile -File tools\test.ps1` -> Expected: tudo verde.

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 tests/widget.Tests.ps1
git commit -m "feat: light theme through a color map, switchable live"
```

---

### Task 3: Opacidade, escala, pílula mínima e o menu

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Modify: `plugins/opaiva-code-widget/scripts/strings.json`
- Test: `tests/widget.Tests.ps1`, `tests/common.Tests.ps1` (chaves de texto, se já houver teste de paridade pt/en)

**Interfaces:**
- Consumes: `$script:prefs`, `Set-Theme`, `Save-Prefs`, `Resolve-Theme`, `Get-WindowsLightTheme` (Tasks 1-2).
- Produces: `Set-Opacity`, `Set-Scale`, `Set-Minimal`, `Set-Pref([string]$key, $value)` (aplica, grava, atualiza as marcas do menu), `$script:prefItems` (lista dos itens de menu com `item`, `key`, `value`).

- [ ] **Step 1: Escrever o teste que falha**

Em `tests/widget.Tests.ps1`, acrescentar um novo `Describe` ao fim:

````powershell
Describe 'widget.ps1 preferences' -Tag 'Desktop' {
    BeforeAll {
        function Get-PillSize([string]$prefsJson) {
            $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
            # Top-left corner, so that nobody clicks the test widget by accident
            [IO.File]::WriteAllText((Join-Path $data 'state.json'), '{"right":420,"bottom":220}')
            if ($prefsJson) { [IO.File]::WriteAllText((Join-Path $data 'prefs.json'), $prefsJson) }
            $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
            try {
                $size = $null
                $deadline = (Get-Date).AddSeconds(30)
                while (-not $size -and (Get-Date) -lt $deadline) {
                    $r = @([CcwTest.Windows]::Rects($proc.Id))
                    if ($r.Count -gt 0) { Start-Sleep -Milliseconds 800; $r = @([CcwTest.Windows]::Rects($proc.Id)); $size = @{ w = $r[0][2] - $r[0][0]; h = $r[0][3] - $r[0][1] } }
                    else { Start-Sleep -Milliseconds 250 }
                }
                Join-Path $data 'widget.log' | Should -Not -Exist
                return $size
            }
            finally {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                [void]$proc.WaitForExit(5000)
                Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    It 'scale 1.5 makes the pill bigger, and the minimal pill smaller' {
        $normal = Get-PillSize ''
        $big = Get-PillSize '{"scale":1.5}'
        $min = Get-PillSize '{"minimal":true}'
        $big.w | Should -BeGreaterThan ($normal.w * 1.2)
        $big.h | Should -BeGreaterThan ($normal.h * 1.2)
        $min.w | Should -BeLessThan ($normal.w * 0.7)
    }
    It 'starts with garbage in prefs.json without errors' {
        $size = Get-PillSize '{"theme":7,"opacity":"x","scale":[1]}'
        $size | Should -Not -BeNullOrEmpty
    }
}
````

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\widget.Tests.ps1 -FullNameFilter '*preferences*' -Output Detailed"`
Expected: FAIL no primeiro teste (largura e altura iguais com ou sem preferências).

- [ ] **Step 3: Textos em `strings.json`**

Em `pt` (junto de `closeWidget`) e em `en`, acrescentar as chaves (UTF-8, usar a ferramenta Write/Edit e conferir os acentos):

- pt: `menuTheme` "Tema", `themeDark` "Escuro", `themeLight` "Claro", `themeAuto` "Automático (como o Windows)", `menuOpacity` "Opacidade", `menuVolume` "Volume", `volumeMute` "Mudo", `menuScale` "Tamanho", `menuMinimal` "Pílula mínima".
- en: `menuTheme` "Theme", `themeDark` "Dark", `themeLight` "Light", `themeAuto` "Automatic (like Windows)", `menuOpacity` "Opacity", `menuVolume` "Volume", `volumeMute` "Mute", `menuScale` "Size", `menuMinimal` "Minimal pill".

- [ ] **Step 4: Implementar em `widget.ps1`**

1. No XAML, dar nome ao título da pílula parada: em `IdlePanel`, trocar `<TextBlock Text="Claude Code" Foreground="#E8E8EC" FontSize="12.5" ...` por `<TextBlock x:Name="IdleTitle" Text="Claude Code" ...` (mesmos atributos) e acrescentar `'IdleTitle'` na lista de `FindName` (junto de `'IdleText'`).

2. Antes do bloco `$menu = New-Object ...ContextMenu`, definir as funções de aplicação:

````powershell
    function Set-Opacity { $win.Opacity = [double]$script:prefs.opacity }
    function Set-Scale {
        $sc = [double]$script:prefs.scale
        $ui.Card.LayoutTransform = New-Object System.Windows.Media.ScaleTransform $sc, $sc
    }
    # The idle pill's tooltip carries the status text when the pill is minimal (the text itself is hidden)
    function Update-IdleLook {
        $min = [bool]$script:prefs.minimal
        $v = if ($min) { 'Collapsed' } else { 'Visible' }
        $ui.IdleTitle.Visibility = $v
        $ui.IdleText.Visibility = $v
        $status = if ($ui.IdleText.Text.Length -gt $Sep.Length) { $ui.IdleText.Text.Substring($Sep.Length) } else { '' }
        $ui.IdlePanel.ToolTip = if ($min -and $status) { $status + [Environment]::NewLine + $S.idleTip } else { $S.idleTip }
    }
    function Set-Minimal { Update-IdleLook }
````

   E no fim de `Set-SessionRows`, logo depois da linha que define `$ui.IdleText.Text`, chamar `Update-IdleLook`. Atenção: `Set-SessionRows` tem `return` no meio (`if (-not $script:sessionsOpen) { return }`); a chamada de `Update-IdleLook` deve ficar **antes** desse `return` (logo após a linha do `IdleText.Text`).

3. Substituir a criação do menu (`$menu = ... $ui.Card.ContextMenu = $menu`) por:

````powershell
    # Right-click menu: each submenu lists fixed choices with the current one checked
    $script:prefItems = New-Object System.Collections.ArrayList
    function Sync-MenuChecks {
        foreach ($e in $script:prefItems) { $e.item.IsChecked = ($script:prefs[$e.key] -eq $e.value) }
    }
    function Set-Pref([string]$key, $value) {
        $script:prefs[$key] = $value
        switch ($key) {
            'theme' { Set-Theme (Resolve-Theme $script:prefs.theme (Get-WindowsLightTheme)) }
            'opacity' { Set-Opacity }
            'scale' { Set-Scale }
            'minimal' { Set-Minimal }
        }
        [void](Save-Prefs $Data $script:prefs)
        Sync-MenuChecks
    }
    function Add-ChoiceMenu($parent, [string]$header, $choices) {
        $sub = New-Object System.Windows.Controls.MenuItem
        $sub.Header = $header
        foreach ($c in $choices) {
            $item = New-Object System.Windows.Controls.MenuItem
            $item.Header = $c.label
            $item.Tag = @{ key = $c.key; value = $c.value }
            $item.Add_Click({ param($src, $e) Set-Pref $src.Tag.key $src.Tag.value })
            [void]$script:prefItems.Add(@{ item = $item; key = $c.key; value = $c.value })
            [void]$sub.Items.Add($item)
        }
        [void]$parent.Items.Add($sub)
    }
    $menu = New-Object System.Windows.Controls.ContextMenu
    Add-ChoiceMenu $menu $S.menuTheme @(
        @{ label = $S.themeDark; key = 'theme'; value = 'dark' }
        @{ label = $S.themeLight; key = 'theme'; value = 'light' }
        @{ label = $S.themeAuto; key = 'theme'; value = 'auto' })
    Add-ChoiceMenu $menu $S.menuOpacity @(foreach ($o in 1.0, 0.9, 0.8, 0.7, 0.6) { @{ label = ('{0}%' -f [int]($o * 100)); key = 'opacity'; value = [double]$o } })
    Add-ChoiceMenu $menu $S.menuVolume @(foreach ($v in 0, 25, 50, 75, 100) { @{ label = $(if ($v -eq 0) { $S.volumeMute } else { '{0}%' -f $v }); key = 'volume'; value = [int]$v } })
    Add-ChoiceMenu $menu $S.menuScale @(foreach ($z in 1.0, 1.25, 1.5) { @{ label = ('{0}%' -f [int]($z * 100)); key = 'scale'; value = [double]$z } })
    $minItem = New-Object System.Windows.Controls.MenuItem
    $minItem.Header = $S.menuMinimal
    $minItem.Add_Click({ param($src, $e) Set-Pref 'minimal' (-not [bool]$script:prefs.minimal); $src.IsChecked = [bool]$script:prefs.minimal })
    $minItem.IsChecked = [bool]$script:prefs.minimal
    [void]$menu.Items.Add($minItem)
    [void]$menu.Items.Add((New-Object System.Windows.Controls.Separator))
    $closeItem = New-Object System.Windows.Controls.MenuItem
    $closeItem.Header = $S.closeWidget
    $closeItem.Add_Click({ Close-Widget })
    [void]$menu.Items.Add($closeItem)
    $ui.Card.ContextMenu = $menu
    Sync-MenuChecks
    Set-Opacity
    Set-Scale
    Update-IdleLook
````

   `Set-Theme` inicial (Task 2) fica logo depois deste bloco. Em `-RenderSamples`, `Set-Opacity`/`Set-Scale` também rodam; para os prints saírem sempre em tamanho normal, envolver as chamadas `Set-Opacity` e `Set-Scale` em `if (-not $RenderMode) { ... }`.

   Nota: o `$minItem` guarda `IsChecked` à mão (não é um `prefItems`); `Sync-MenuChecks` não o toca.

- [ ] **Step 5: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\widget.Tests.ps1 -FullNameFilter '*preferences*' -Output Detailed"`
Expected: PASS. Se a pílula mínima não ficar menor que 70%, medir os tamanhos (`$normal`, `$min`) e ajustar o limite do teste ao que a pílula mínima realmente deixa (ponto 8 px + margens), mantendo "claramente menor".

Se o teste de paridade de textos (pt/en com as mesmas chaves) existir, ele passa com as chaves novas nos dois idiomas.

- [ ] **Step 6: Suíte completa e commit**

Run: `powershell -NoProfile -File tools\test.ps1` -> Expected: tudo verde.

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 plugins/opaiva-code-widget/scripts/strings.json tests/widget.Tests.ps1
git commit -m "feat: opacity, scale, minimal pill and the preferences menu"
```

---

### Task 4: Volume nos sons (Play-Sound)

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1`
- Test: `tests/repo.Tests.ps1` (regra de estrutura), mais verificação manual

**Interfaces:**
- Consumes: `$script:prefs.volume` (Task 1).
- Produces: `Play-Sound([string]$name, [scriptblock]$fallback)` com `$name` em `request`, `done`, `allDone`.

- [ ] **Step 1: Teste de regra que falha**

Em `tests/repo.Tests.ps1`, dentro do `Describe 'repository rules'`, junto do teste "has no handler parameter named like the strings table":

````powershell
    It 'widget.ps1 plays sounds only through Play-Sound (the volume setting must apply)' {
        $text = [IO.File]::ReadAllText((Join-Path $repo 'plugins\opaiva-code-widget\scripts\widget.ps1'))
        # The only direct SystemSounds / SoundPlayer uses are the fallbacks passed to Play-Sound
        $direct = [regex]::Matches($text, '(?m)^(?!.*Play-Sound).*(SystemSounds|SoundPlayer).*$')
        $direct.Count | Should -Be 0
    }
````

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\repo.Tests.ps1 -FullNameFilter '*Play-Sound*' -Output Detailed"`
Expected: FAIL (hoje há `SoundPlayer` e `SystemSounds` em linhas sem `Play-Sound`).

- [ ] **Step 2: Implementar**

1. Substituir os dois blocos de som (de `# "Finished" sound ...` até o fim do bloco de `tada.wav`) por:

````powershell
    # Sounds go through Play-Sound so that the volume setting applies. The WPF MediaPlayer has a Volume;
    # SoundPlayer and SystemSounds do not, so they are only the fallback (the volume is ignored there,
    # but 0 still means silence).
    function Get-SchemeSound([string]$event) {
        try {
            $key = Get-Item -LiteralPath "HKCU:\AppEvents\Schemes\Apps\.Default\$event\.Current" -ErrorAction Stop
            $path = [Environment]::ExpandEnvironmentVariables([string]$key.GetValue(''))
            if ($path -and (Test-Path -LiteralPath $path)) { return $path }
        } catch {}
        return $null
    }
    $script:sounds = @{}
    function New-MediaSound([string]$file) {
        if (-not $file -or -not (Test-Path -LiteralPath $file)) { return $null }
        try {
            $p = New-Object System.Windows.Media.MediaPlayer
            # A file Windows cannot decode: forget it, so that the next play uses the system sound
            $p.Add_MediaFailed({ param($src, $e) foreach ($k in @($script:sounds.Keys)) { if ([object]::ReferenceEquals($script:sounds[$k], $src)) { $script:sounds[$k] = $null } } })
            $p.Open([Uri]$file)
            return $p
        } catch { Write-Log $_; return $null }
    }
    if (-not $RenderMode) {
        $script:sounds.request = New-MediaSound (Get-SchemeSound 'SystemAsterisk')
        $script:sounds.done = New-MediaSound (Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav')
        $script:sounds.allDone = New-MediaSound (Join-Path $env:WINDIR 'Media\tada.wav')
    }
    function Play-Sound([string]$name, [scriptblock]$fallback) {
        $vol = [int]$script:prefs.volume
        if ($vol -le 0) { return }
        $p = $script:sounds[$name]
        if ($p) {
            try {
                $p.Volume = $vol / 100.0
                $p.Position = [TimeSpan]::Zero
                $p.Play()
                return
            } catch { Write-Log $_ }
        }
        & $fallback
    }
````

   (Cuidado com o caminho `Media\Windows ...` e `Media\tada.wav`: ao escrever com a ferramenta, conferir que `\W` e `\t` não viraram caracteres; `grep -c $'\t' widget.ps1` deve dar 0. Se a ferramenta mexer, escrever esses dois trechos com `Join-Path $env:WINDIR 'Media'` e o nome do arquivo separado.)

2. Os pontos de chamada. Os dois `Invoke-Attention $r.id { [System.Media.SystemSounds]::Asterisk.Play() }` (em `Show-Permission` e `Show-Question`) viram:

````powershell
        Invoke-Attention $r.id { Play-Sound 'request' { [System.Media.SystemSounds]::Asterisk.Play() } }
````

   E o bloco de `Show-Done` vira:

````powershell
            Invoke-Attention $d.key {
                if ($allDone) { Play-Sound 'allDone' { [System.Media.SystemSounds]::Exclamation.Play() } }
                else { Play-Sound 'done' { [System.Media.SystemSounds]::Beep.Play() } }
            }
````

   Em `Close-Widget`/fechamento: nada a fazer (o `MediaPlayer` morre com o processo).

- [ ] **Step 3: Rodar e ver passar**

Run: `powershell -NoProfile -Command "Invoke-Pester -Path tests\repo.Tests.ps1 -Output Minimal"` -> Expected: PASS. Em seguida `powershell -NoProfile -File tools\test.ps1` -> tudo verde (o teste de fila abre um widget real: `widget.log` não pode aparecer).

Verificação manual (não há teste automático de som): com um widget aberto, pedir uma ação que gera cartão e ouvir o som; mudar para 25% e repetir (mais baixo); Mudo (nada). Anotar no ledger.

- [ ] **Step 4: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/widget.ps1 tests/repo.Tests.ps1
git commit -m "feat: volume setting for the widget sounds"
```

---

### Task 5: Prints, documentação e versão 2.4.0

**Files:**
- Modify: `tools/render-screenshots.ps1`, `README.md`, `README.pt-BR.md`, `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`
- Create: `docs/images/en/light-permission.png`, `docs/images/pt/light-permission.png`

- [ ] **Step 1: Print do tema claro**

Em `tools/render-screenshots.ps1`, depois do loop que renderiza o tema escuro, acrescentar, para cada idioma, uma renderização com `-Theme light` numa pasta temporária e a cópia de `permission.png` como `light-permission.png`:

````powershell
foreach ($lang in 'en', 'pt') {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('ccw-light-' + [guid]::NewGuid().ToString('N'))
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $tmp -Lang $lang -Theme light
    if ($LASTEXITCODE) { throw "light render failed for '$lang'" }
    Copy-Item -LiteralPath (Join-Path $tmp 'permission.png') -Destination (Join-Path $repo "docs\images\$lang\light-permission.png") -Force
    Remove-Item -LiteralPath $tmp -Recurse -Force
    '{0}\light-permission.png' -f $lang
}
````

Run: `powershell -NoProfile -File tools\render-screenshots.ps1`. Abrir `docs/images/en/light-permission.png` e conferir a legibilidade.

- [ ] **Step 2: READMEs**

Em `README.md` e `README.pt-BR.md`, na seção de configuração (junto da tabela de variáveis): descrever o menu do botão direito (tema, opacidade, volume, tamanho, pílula mínima) e o arquivo `prefs.json` (campos e valores permitidos, padrão); dizer que o volume vale para os sons do widget e que, se o Windows não conseguir tocar o arquivo de som, o som do sistema toca sem controle de volume (mudo sempre vale); dizer que o modo Automático segue o tema de aplicativos do Windows ao abrir o widget. Incluir `light-permission.png`. Manter pt e en equivalentes; conferir a regra do teste de README (id antigo do plugin) e a de ASCII não vale para `.md`.

- [ ] **Step 3: CHANGELOG e versão**

Entrada nova no topo de `CHANGELOG.md`, `## 2.4.0 (2026-10-08)`, com: tema claro/escuro/automático, opacidade, volume (com o limite do fallback), tamanho 100/125/150%, pílula mínima, `prefs.json`, tudo pelo menu do botão direito. Em `plugin.json`, `"version": "2.4.0"`.

- [ ] **Step 4: Suíte completa**

Run: `powershell -NoProfile -File tools\test.ps1`
Expected: tudo verde (inclui "plugin.json version matches the latest CHANGELOG entry").

- [ ] **Step 5: Verificação manual com widget real (registrar no ledger)**

Abrir o widget por `hook.ps1 -EnsureWidget` (ou reiniciar) e conferir: cada submenu do botão direito marca a opção certa; tema claro/escuro ao vivo com um cartão de pedido aberto (peça uma ação que gere cartão) e voltar ao escuro deixa idêntico ao começo; escala 150% perto do canto da tela continua visível; pílula mínima mostra a dica e abre a lista com o clique; reiniciar mantém tudo.

- [ ] **Step 6: Commit**

```bash
git add tools/render-screenshots.ps1 README.md README.pt-BR.md CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json docs/images
git commit -m "docs: release 2.4.0 (theme, opacity, volume, scale, minimal pill)"
```
