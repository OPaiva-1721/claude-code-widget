# Rotação do log, troca de monitor e título do VS Code: plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** versão 2.0.1 com três correções (o `widget.log` gira como o `hook.log`; o widget acompanha a troca de monitores; o projeto é reconhecido pelo nome inteiro no título do VS Code) e os ajustes pequenos adiados dos blocos 1 e 2.

**Architecture:** as funções novas e puras ficam no `common.ps1` (`Write-LogLine`, `Test-TitleHasProject`, `Get-ScreenAreas`, `Get-ScreenKey`, `Resolve-Anchor`), onde os testes conseguem carregá-las. O `hook.ps1` e o `widget.ps1` só passam a chamá-las. O widget confere as telas no timer que já existe, a cada ~2 s.

**Tech Stack:** Windows PowerShell 5.1, WPF, C# via `Add-Type` (Win32 `EnumDisplayMonitors`/`GetMonitorInfo`/`EnumWindows`), Pester ≥ 5.5 (6.2.0 instalado), GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-10-07-logs-screens-titles-design.md`

## Global Constraints

- Todo `.ps1` (scripts, testes, ferramentas) fica só com ASCII. Caracteres como `●` e `ç` entram com `[char]0x25CF` / `[char]0x00E7`.
- Nada muda no comportamento além das três correções e dos ajustes listados na spec.
- O nome do mutex e o teste fixado dele não mudam.
- O hook nunca escreve nada no stdout além da decisão: nenhuma função nova pode deixar saída no pipeline.
- Log: 256 KB por arquivo, mais um `.old`. Linha: `aaaa-mm-ddThh:mm:ss <texto>`, UTF-8 sem BOM.
- Posição: só arrastar grava o `state.json`. Margens de "cabe na tela": `left + 120 < right <= areaRight + 1` e `top + 60 < bottom <= areaBottom + 1`, por monitor.
- Monitores: lidos pela API do Windows (`GetMonitorInfo`), nunca por `System.Windows.Forms.Screen` (guarda `Bounds` velho; verificado nesta máquina, 5120×2880 a 200%).
- Versão: `2.0.1` no `plugin.json` e no topo do `CHANGELOG.md`.
- Branch: `fix/logs-screens-titles` (já criado, com a spec). Commits terminam com `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Suíte inteira: `powershell -NoProfile -File tools\test.ps1` (hoje: 85 testes, todos passando). Mande a saída para um arquivo e leia o fim.

## Review Focus

1. **"Ir para o VS Code" sem janela guardada** (sessões antigas, ou janela fechada): tem que trazer a janela do projeto, ou qualquer janela do VS Code, como antes. O `widget.ps1` não pode ser carregado por testes, então a escolha da janela (`Find-VsCodeWindow`) fica sem teste automático: a parte que decide (`Test-TitleHasProject`) é testada na Task 2, e o teste Desktop da fila pega erro de compilação do C# (o widget grava `widget.log`). Verificação à mão na Task 5.
2. **Clique sem arrastar com o widget no canto de reserva:** não pode gravar o canto de reserva como posição salva, ou o widget não volta quando o monitor volta. Sem teste automático (simular clique numa janela WPF de outro processo é frágil); o código compara a posição antes e depois do `DragMove` (Task 3).
3. **`state.json` de outra versão ou estragado** (campos faltando, texto que não é JSON): tem que abrir no canto padrão, sem erro. Coberto na Task 3: `Resolve-Anchor` com campos faltando e com o objeto lido de JSON.
4. **Conversão de pixels com e sem o modo DPI ativo:** a área principal de `Get-ScreenAreas` tem que bater com `SystemParameters.WorkArea` do WPF no mesmo processo. Coberto na Task 3.
5. **Log que não pode ser gravado** (pasta sem permissão, caminho inválido): o hook e o widget seguem normalmente. Coberto na Task 1: `Write-LogLine` não lança erro com um caminho inválido.

---

### Task 1: Log com rotação (B4)

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (função nova no fim)
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1:46-55` (`Write-HookLog`)
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1:43-49` (`Write-Log`)
- Test: `tests/common.Tests.ps1`, `tests/hook.Tests.ps1`

**Interfaces:**
- Consumes: `Get-Utf8NoBom` (já existe no `common.ps1`).
- Produces: `Write-LogLine([string]$Path, [string]$Text, [int64]$MaxBytes = 256KB)`, sem retorno, nunca lança erro.

- [ ] **Step 1: Escrever os testes**

No fim de `tests/common.Tests.ps1`:

```powershell
Describe 'Write-LogLine' {
    It 'appends a dated line, creating the folder' {
        $path = Join-Path $TestDrive 'logs\a.log'
        Write-LogLine $path 'first'
        Write-LogLine $path 'second'
        $lines = [IO.File]::ReadAllLines($path)
        $lines.Count | Should -Be 2
        $lines[1] | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d second$'
    }
    It 'moves the log to .old once it passes the limit, keeping a single .old' {
        $path = Join-Path $TestDrive 'r.log'
        [IO.File]::WriteAllText("$path.old", 'oldest')
        [IO.File]::WriteAllText($path, ('x' * 200))
        Write-LogLine $path 'new' 100
        [IO.File]::ReadAllText("$path.old") | Should -BeExactly ('x' * 200)
        $lines = @([IO.File]::ReadAllLines($path))
        $lines.Count | Should -Be 1
        $lines[0] | Should -Match ' new$'
    }
    It 'keeps appending while under the limit' {
        $path = Join-Path $TestDrive 'u.log'
        [IO.File]::WriteAllText($path, "line`r`n")
        Write-LogLine $path 'more' 100
        "$path.old" | Should -Not -Exist
        @([IO.File]::ReadAllLines($path)).Count | Should -Be 2
    }
    It 'writes UTF-8 without BOM' {
        $path = Join-Path $TestDrive 'utf.log'
        $text = 'a' + [char]0x00E7 + [char]0x00E3 + 'o'
        Write-LogLine $path $text
        [IO.File]::ReadAllBytes($path)[0] | Should -Not -Be 0xEF
        [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | Should -Match ([regex]::Escape($text))
    }
    It 'never throws, even when the log cannot be written' {
        { Write-LogLine (Join-Path $TestDrive 'bad<>|.log') 'x' } | Should -Not -Throw
    }
}
```

No fim de `tests/hook.Tests.ps1`:

```powershell
Describe 'Write-HookLog' {
    # Already true before 2.0.1 (hook.ps1 had its own rotation); guards the switch to Write-LogLine
    It 'moves hook.log to hook.log.old once it passes 256 KB' {
        New-Item -ItemType Directory -Force -Path $Data | Out-Null
        [IO.File]::WriteAllText($LogPath, ('x' * 300KB))
        Write-HookLog 'after rotation'
        "$LogPath.old" | Should -Exist
        @([IO.File]::ReadAllLines($LogPath)).Count | Should -Be 1
        Remove-Item -LiteralPath $LogPath, "$LogPath.old" -Force
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t1.txt; Get-Content $env:TEMP\t1.txt -Tail 15`
Esperado: os 5 testes de `Write-LogLine` FAIL com `The term 'Write-LogLine' is not recognized`. `Write-HookLog` PASS (a rotação antiga já faz isso). Total: 86 passed, 5 failed.

- [ ] **Step 3: Implementar**

No fim de `plugins/opaiva-code-widget/scripts/common.ps1`:

```powershell

# Appends "<date>T<time> <text>" to a log file (UTF-8). Past $MaxBytes the file first becomes
# <file>.old (replacing the previous one), so a log never grows past about twice $MaxBytes.
# Never throws: a log that cannot be written must not stop the hook or the widget.
function Write-LogLine([string]$Path, [string]$Text, [int64]$MaxBytes = 256KB) {
    try {
        $dir = [IO.Path]::GetDirectoryName($Path)
        if ($dir) { [void][IO.Directory]::CreateDirectory($dir) }
        $file = [IO.FileInfo]::new($Path)
        if ($file.Exists -and $file.Length -gt $MaxBytes) {
            [IO.File]::Delete("$Path.old")
            [IO.File]::Move($Path, "$Path.old")
        }
        [IO.File]::AppendAllText($Path, ('{0:s} {1}' -f (Get-Date), $Text) + "`r`n", (Get-Utf8NoBom))
    } catch {}
}
```

Em `plugins/opaiva-code-widget/scripts/hook.ps1`, troque a função inteira:

```powershell
function Write-HookLog([string]$msg) {
    try {
        New-Item -ItemType Directory -Force -Path $Data | Out-Null
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 256KB) {
            Remove-Item -LiteralPath "$LogPath.old" -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $LogPath -NewName 'hook.log.old'
        }
        Add-Content -LiteralPath $LogPath -Value ('{0:s} {1}' -f (Get-Date), $msg)
    } catch {}
}
```

por:

```powershell
function Write-HookLog([string]$msg) { Write-LogLine $LogPath $msg }
```

Em `plugins/opaiva-code-widget/scripts/widget.ps1`, troque:

```powershell
    try { Add-Content -LiteralPath $LogPath -Value ('{0:s} {1}' -f (Get-Date), $text) } catch {}
```

por:

```powershell
    Write-LogLine $LogPath $text
```

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t1.txt; Get-Content $env:TEMP\t1.txt -Tail 15`
Esperado: 91 passed, 0 failed. O teste Desktop `removes orphaned requests and stale notices from its queue` continua passando: ele exige que o widget **não** crie `widget.log`, então pega um erro no `Write-Log`.

- [ ] **Step 5: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 plugins/opaiva-code-widget/scripts/hook.ps1 plugins/opaiva-code-widget/scripts/widget.ps1 tests/common.Tests.ps1 tests/hook.Tests.ps1
git commit -m "fix: rotate widget.log like hook.log (shared Write-LogLine)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Projeto pelo nome inteiro no título do VS Code (B6)

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (função nova no fim)
- Modify: `plugins/opaiva-code-widget/scripts/hook.ps1` (`$VsCodeProcesses`, `Get-WindowKind`, `Save-SessionWindow`, `Test-UserWatching`)
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1` (C# `WinFocus`: `Focus` → `Title` + `FindWindows`; `Find-VsCodeWindow`; `Close-DoneNotice`)
- Test: `tests/common.Tests.ps1`, `tests/hook.Tests.ps1`

**Interfaces:**
- Consumes: nada das outras tasks.
- Produces: `Test-TitleHasProject([string]$Title, [string]$Project)` → `[bool]`; `Get-WindowKind([string]$ProcessName)` → `'vscode' | 'terminal' | 'other'` (no `hook.ps1`).

- [ ] **Step 1: Escrever os testes**

No fim de `tests/common.Tests.ps1`:

```powershell
Describe 'Test-TitleHasProject' {
    It 'matches "<title>"' -ForEach @(
        @{ title = 'x.ps1 - widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget (Workspace) - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widget [WSL: Ubuntu] - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - WIDGET - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - my - app - Visual Studio Code'; project = 'my - app' }
        @{ title = 'x.ps1 - c++ (x86) - Visual Studio Code'; project = 'c++ (x86)' }
    ) {
        Test-TitleHasProject $title $project | Should -BeTrue
    }
    It 'does not match "<title>"' -ForEach @(
        @{ title = 'x.ps1 - claude-code-widget - Visual Studio Code'; project = 'widget' }
        @{ title = 'widget.ps1 - other - Visual Studio Code'; project = 'widget' }
        @{ title = 'x.ps1 - widgets - Visual Studio Code'; project = 'widget' }
    ) {
        Test-TitleHasProject $title $project | Should -BeFalse
    }
    It 'matches a title that starts with the unsaved-file dot' {
        $dot = [string][char]0x25CF
        Test-TitleHasProject "$dot widget - Visual Studio Code" 'widget' | Should -BeTrue
        Test-TitleHasProject "$dot x.ps1 - widget - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'matches a translated workspace suffix' {
        $suffix = ' (Espa' + [char]0x00E7 + 'o de Trabalho)'
        Test-TitleHasProject "x.ps1 - widget$suffix - Visual Studio Code" 'widget' | Should -BeTrue
    }
    It 'is false for an empty title or project' {
        Test-TitleHasProject '' 'widget' | Should -BeFalse
        Test-TitleHasProject 'x.ps1 - widget - Visual Studio Code' '' | Should -BeFalse
    }
}
```

No fim de `tests/hook.Tests.ps1`:

```powershell
Describe 'Get-WindowKind' {
    It 'is <kind> for "<process>"' -ForEach @(
        @{ process = 'Code.exe'; kind = 'vscode' }
        @{ process = 'Code - Insiders.exe'; kind = 'vscode' }
        @{ process = 'WindowsTerminal.exe'; kind = 'terminal' }
        @{ process = 'explorer.exe'; kind = 'other' }
        @{ process = ''; kind = 'other' }
    ) {
        Get-WindowKind $process | Should -BeExactly $kind
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t2.txt; Get-Content $env:TEMP\t2.txt -Tail 15`
Esperado: os 13 testes de `Test-TitleHasProject` e os 5 de `Get-WindowKind` FAIL com `is not recognized`. Total: 91 passed, 18 failed.

- [ ] **Step 3: Implementar `Test-TitleHasProject`**

No fim de `plugins/opaiva-code-widget/scripts/common.ps1`:

```powershell

# Does a window title name this project as a whole part of it? VS Code titles read
# "[<dot> ]file - folder[ (Workspace)][ [WSL: Ubuntu]] - Visual Studio Code", so "widget" matches the
# folder "widget" but not "claude-code-widget" nor a file "widget.ps1". Letter case is ignored.
# (The unsaved-file dot goes in as the character itself: '\u25CF' does not match in .NET here.)
function Test-TitleHasProject([string]$Title, [string]$Project) {
    if (-not $Title -or -not $Project) { return $false }
    $dot = [regex]::Escape([string][char]0x25CF)
    $pattern = '(?i)(^|\s-\s)(' + $dot + '\s*)?' + [regex]::Escape($Project) + '(\s[(\[][^)\]]*[)\]])*(\s-\s|$)'
    return [regex]::IsMatch($Title, $pattern)
}
```

- [ ] **Step 4: Implementar no `hook.ps1`**

Logo depois da definição de `$TerminalHosts` (que termina em `'wezterm-gui.exe', 'alacritty.exe', 'mintty.exe', 'tabby.exe', 'hyper.exe')`), acrescente:

```powershell
# Processes that own a VS Code window
$VsCodeProcesses = @('code.exe', 'code - insiders.exe')
```

Logo antes do comentário `# On UserPromptSubmit the window in front is almost always where you typed.`, acrescente:

```powershell
# vscode / terminal / other, from the name of the process that owns the window
function Get-WindowKind([string]$ProcessName) {
    $name = $ProcessName.ToLowerInvariant()
    if ($VsCodeProcesses -contains $name) { return 'vscode' }
    if ($TerminalHosts -contains $name) { return 'terminal' }
    return 'other'
}

```

Em `Save-SessionWindow`, troque:

```powershell
        $title = Get-WindowTitle $fg
        $kind = if ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) { 'vscode' }
                elseif ($TerminalHosts -contains $name) { 'terminal' } else { 'other' }
```

por:

```powershell
        $kind = Get-WindowKind $name
```

Em `Test-UserWatching`, troque:

```powershell
        return ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
               ($title.IndexOf($project, [StringComparison]::OrdinalIgnoreCase) -ge 0)
```

por:

```powershell
        return ($title.IndexOf('Visual Studio Code', [StringComparison]::OrdinalIgnoreCase) -ge 0) -and
               (Test-TitleHasProject $title $project)
```

- [ ] **Step 5: Implementar no `widget.ps1`**

No C# de `ClaudeWidget.WinFocus`, troque o método inteiro:

```csharp
        public static bool Focus(string app, string project) {
            IntPtr found = IntPtr.Zero;
            EnumWindows((h, l) => {
                if (!IsWindowVisible(h)) return true;
                var sb = new StringBuilder(512);
                GetWindowText(h, sb, 512);
                var t = sb.ToString();
                if (t.IndexOf(app, StringComparison.OrdinalIgnoreCase) < 0) return true;
                if (!string.IsNullOrEmpty(project) && t.IndexOf(project, StringComparison.OrdinalIgnoreCase) < 0) return true;
                found = h;
                return false;
            }, IntPtr.Zero);
            if (found == IntPtr.Zero) return false;
            if (IsIconic(found)) ShowWindow(found, 9);
            return SetForegroundWindow(found);
        }
```

por:

```csharp
        public static string Title(IntPtr h) {
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            return sb.ToString();
        }
        // Visible windows whose title contains app, topmost first
        public static IntPtr[] FindWindows(string app) {
            var found = new System.Collections.Generic.List<IntPtr>();
            EnumWindows((h, l) => {
                if (IsWindowVisible(h) && Title(h).IndexOf(app, StringComparison.OrdinalIgnoreCase) >= 0) found.Add(h);
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }
```

Logo antes de `function Close-DoneNotice([switch]$GoToSession) {`, acrescente:

```powershell
    # The project's VS Code window (a title part equal to the project name), else any VS Code window
    function Find-VsCodeWindow([string]$project) {
        $windows = @([ClaudeWidget.WinFocus]::FindWindows('Visual Studio Code'))
        foreach ($h in $windows) {
            if (Test-TitleHasProject ([ClaudeWidget.WinFocus]::Title($h)) $project) { return $h }
        }
        if ($windows.Count -gt 0) { return $windows[0] }
        return [IntPtr]::Zero
    }

```

Em `Close-DoneNotice`, troque:

```powershell
                if (-not [ClaudeWidget.WinFocus]::Focus('Visual Studio Code', $project)) {
                    [void][ClaudeWidget.WinFocus]::Focus('Visual Studio Code', '')
                }
```

por:

```powershell
                $h = Find-VsCodeWindow $project
                if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
```

(`FocusHandle` já restaura a janela minimizada, como o `Focus` antigo fazia.)

- [ ] **Step 6: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t2.txt; Get-Content $env:TEMP\t2.txt -Tail 15`
Esperado: 109 passed, 0 failed. O teste Desktop da fila continua passando (sem `widget.log`): prova que o C# novo compila.

- [ ] **Step 7: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 plugins/opaiva-code-widget/scripts/hook.ps1 plugins/opaiva-code-widget/scripts/widget.ps1 tests/common.Tests.ps1 tests/hook.Tests.ps1
git commit -m "fix: match the VS Code project by its whole name in the window title

A project called widget no longer matches claude-code-widget or widget.ps1. The
session window kind comes from the owning process (Code.exe), not the title.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Posição por monitor (B5)

**Files:**
- Modify: `plugins/opaiva-code-widget/scripts/common.ps1` (três funções novas no fim)
- Modify: `plugins/opaiva-code-widget/scripts/widget.ps1` (bloco "Position", arrasto, timer)
- Test: `tests/common.Tests.ps1`, `tests/widget.Tests.ps1`

**Interfaces:**
- Consumes: `Write-Log` do widget (Task 1 já o liga ao `Write-LogLine`).
- Produces:
  - `Get-ScreenAreas` → hashtables `@{ left; top; right; bottom; primary }` em unidades do WPF (chame com `@()`);
  - `Get-ScreenKey($Areas)` → `[string]`;
  - `Resolve-Anchor($Saved, $Areas)` → `@{ right; bottom; saved }` ou `$null`;
  - tipo C# `ClaudeWidget.Monitors` com `List()` → `List<int[]>` (pixels: work left, top, right, bottom, largura do monitor, 1 = principal), usado também pelo teste Desktop.

- [ ] **Step 1: Escrever os testes de unidade**

No fim de `tests/common.Tests.ps1`:

```powershell
Describe 'Get-ScreenAreas' {
    It 'lists at least one screen, exactly one of them the main one' {
        $areas = @(Get-ScreenAreas)
        $areas.Count | Should -BeGreaterThan 0
        @($areas | Where-Object { $_.primary }).Count | Should -Be 1
        foreach ($a in $areas) {
            $a.right | Should -BeGreaterThan $a.left
            $a.bottom | Should -BeGreaterThan $a.top
        }
    }
    It 'uses the same units as WPF' {
        $main = @(Get-ScreenAreas | Where-Object { $_.primary })[0]
        $wa = [System.Windows.SystemParameters]::WorkArea
        [math]::Abs($main.right - $wa.Right) | Should -BeLessOrEqual 1
        [math]::Abs($main.bottom - $wa.Bottom) | Should -BeLessOrEqual 1
    }
}

Describe 'Get-ScreenKey' {
    BeforeAll { $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true } }
    It 'is the same for the same screens' {
        Get-ScreenKey @($main) | Should -BeExactly (Get-ScreenKey @($main.Clone()))
    }
    It 'changes when a screen changes' {
        $moved = $main.Clone()
        $moved.bottom = 1440
        Get-ScreenKey @($moved) | Should -Not -BeExactly (Get-ScreenKey @($main))
    }
}

Describe 'Resolve-Anchor' {
    BeforeAll {
        # Main screen 2560 x 1440 with a 40-pixel taskbar; a smaller screen on its left, bottom-aligned
        $main = @{ left = 0; top = 0; right = 2560; bottom = 1400; primary = $true }
        $side = @{ left = -1920; top = 360; right = 0; bottom = 1400; primary = $false }
    }
    It 'keeps a saved spot on the main screen' {
        $a = Resolve-Anchor @{ right = 2000; bottom = 900 } @($main, $side)
        $a.right | Should -Be 2000
        $a.bottom | Should -Be 900
        $a.saved | Should -BeTrue
    }
    It 'keeps a saved spot on another screen' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main, $side)
        $a.right | Should -Be -300
        $a.saved | Should -BeTrue
    }
    It 'moves a spot between screens of different sizes to the main corner' {
        # Above the smaller screen: inside the box around both screens, but on neither of them
        $a = Resolve-Anchor @{ right = -300; bottom = 200 } @($main, $side)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
        $a.saved | Should -BeFalse
    }
    It 'moves to the main corner when the saved screen is gone' {
        $a = Resolve-Anchor @{ right = -300; bottom = 1200 } @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'goes back to the saved spot when its screen is back' {
        $saved = @{ right = -300; bottom = 1200 }
        (Resolve-Anchor $saved @($main)).saved | Should -BeFalse
        $back = Resolve-Anchor $saved @($main, $side)
        $back.right | Should -Be -300
        $back.saved | Should -BeTrue
    }
    It 'uses the main corner without a saved spot' {
        $a = Resolve-Anchor $null @($side, $main)
        $a.right | Should -Be 2560
        $a.bottom | Should -Be 1400
    }
    It 'uses the main corner when the saved spot lacks fields' {
        $a = Resolve-Anchor ('{"x":5}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2560
        $a.saved | Should -BeFalse
    }
    It 'reads a saved spot as loaded from state.json' {
        $a = Resolve-Anchor ('{"right":2371.09,"bottom":878.6}' | ConvertFrom-Json) @($main)
        $a.right | Should -Be 2371.09
        $a.saved | Should -BeTrue
    }
    It 'uses the first screen when none is marked main' {
        $a = Resolve-Anchor $null @(@{ left = 0; top = 0; right = 1920; bottom = 1040; primary = $false })
        $a.right | Should -Be 1920
    }
    It 'returns nothing without screens' {
        Resolve-Anchor @{ right = 2000; bottom = 900 } @() | Should -BeNullOrEmpty
    }
}
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t3.txt; Get-Content $env:TEMP\t3.txt -Tail 15`
Esperado: 2 (`Get-ScreenAreas`) + 2 (`Get-ScreenKey`) + 10 (`Resolve-Anchor`) FAIL com `is not recognized`. Total: 109 passed, 14 failed.

- [ ] **Step 3: Implementar as funções**

No fim de `plugins/opaiva-code-widget/scripts/common.ps1`:

```powershell

# Work area (screen minus taskbar) of each monitor, in WPF units, read fresh on every call:
# @{ left; top; right; bottom; primary }. Used by widget.ps1. Pixels are converted with the main
# monitor's width in pixels against WPF's width for it, both read now, so the areas match WPF's
# coordinates whether or not this process is DPI aware. (System.Windows.Forms.Screen is not used:
# it keeps the main screen's bounds from its first use and can disagree with its own work areas.)
function Get-ScreenAreas {
    Add-Type -AssemblyName PresentationFramework
    $dips = [System.Windows.SystemParameters]::PrimaryScreenWidth
    if (-not ('ClaudeWidget.Monitors' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace ClaudeWidget {
    public static class Monitors {
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
        [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
        delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, IntPtr rect, IntPtr data);
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc proc, IntPtr data);
        [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
        // One entry per monitor, in pixels: work area left, top, right, bottom; monitor width; 1 = main screen
        public static List<int[]> List() {
            var list = new List<int[]>();
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (m, hdc, r, d) => {
                var info = new MONITORINFO();
                info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                if (GetMonitorInfo(m, ref info)) {
                    list.Add(new int[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom,
                        info.rcMonitor.Right - info.rcMonitor.Left, (info.dwFlags & 1) != 0 ? 1 : 0 });
                }
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
    $monitors = [ClaudeWidget.Monitors]::List()
    $mainWidth = 0
    foreach ($m in $monitors) { if ($m[5] -eq 1) { $mainWidth = $m[4] } }
    $scale = if ($mainWidth -gt 0 -and $dips -gt 0) { $mainWidth / $dips } else { 1.0 }
    foreach ($m in $monitors) {
        @{ left = $m[0] / $scale; top = $m[1] / $scale; right = $m[2] / $scale; bottom = $m[3] / $scale; primary = ($m[5] -eq 1) }
    }
}

# Text that changes whenever a monitor is added, removed, moved or resized, or the taskbar moves
function Get-ScreenKey($Areas) {
    return (@($Areas | Where-Object { $_ }) | ForEach-Object {
            '{0},{1},{2},{3},{4}' -f $_.left, $_.top, $_.right, $_.bottom, [bool]$_.primary }) -join ';'
}

# Where the widget's bottom-right corner goes: the saved spot (@{ right; bottom }, e.g. from
# state.json) while it is on one of the screens, else the main screen's bottom-right corner.
# Returns @{ right; bottom; saved }, or $null without any screen.
function Resolve-Anchor($Saved, $Areas) {
    $list = @($Areas | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    if ($Saved -and $null -ne $Saved.right -and $null -ne $Saved.bottom) {
        $r = [double]$Saved.right
        $b = [double]$Saved.bottom
        foreach ($a in $list) {
            # At least a 120 x 60 corner of the widget on that screen
            if ($r -gt $a.left + 120 -and $r -le $a.right + 1 -and $b -gt $a.top + 60 -and $b -le $a.bottom + 1) {
                return @{ right = $r; bottom = $b; saved = $true }
            }
        }
    }
    $main = $list[0]
    foreach ($a in $list) { if ($a.primary) { $main = $a; break } }
    return @{ right = [double]$main.right; bottom = [double]$main.bottom; saved = $false }
}
```

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t3.txt; Get-Content $env:TEMP\t3.txt -Tail 15`
Esperado: 123 passed, 0 failed.

- [ ] **Step 5: Escrever o teste Desktop da posição**

Em `tests/widget.Tests.ps1`, no `BeforeAll` do topo do arquivo, depois de `$samples = ...`, acrescente:

```powershell
    . (Join-Path $repo 'plugins\opaiva-code-widget\scripts\common.ps1')
    [void](Get-ScreenAreas)   # compiles ClaudeWidget.Monitors (pixels, same DPI mode as GetWindowRect here)
    if (-not ('CcwTest.Windows' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace CcwTest {
    public static class Windows {
        [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        // Rects (pixels: left, top, right, bottom) of the visible top-level windows of one process
        public static List<int[]> Rects(int pid) {
            var list = new List<int[]>();
            EnumWindows((h, l) => {
                uint owner;
                GetWindowThreadProcessId(h, out owner);
                RECT r;
                if (owner == pid && IsWindowVisible(h) && GetWindowRect(h, out r)) list.Add(new int[] { r.Left, r.Top, r.Right, r.Bottom });
                return true;
            }, IntPtr.Zero);
            return list;
        }
    }
}
'@
    }
```

No fim de `tests/widget.Tests.ps1`:

```powershell
Describe 'widget.ps1 position' -Tag 'Desktop' {
    # With one monitor the old check already sent such a spot to the corner: this guards the wiring
    # of the new per-monitor check (the gap between monitors is covered by Resolve-Anchor's tests)
    It 'opens in the main screen corner when the saved spot is on no screen, keeping state.json' {
        $data = Join-Path ([IO.Path]::GetTempPath()) ('ccw-widget-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $data 'queue') | Out-Null
        $state = '{"right":-50000,"bottom":-50000}'
        $statePath = Join-Path $data 'state.json'
        [IO.File]::WriteAllText($statePath, $state)
        $work = $null
        foreach ($m in [ClaudeWidget.Monitors]::List()) { if ($m[5] -eq 1) { $work = $m } }

        $proc = Start-Process powershell.exe -PassThru -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
            '-File', ('"{0}"' -f $widget), '-DataDir', ('"{0}"' -f $data), '-Lang', 'en'
        try {
            $inCorner = $false
            $deadline = (Get-Date).AddSeconds(30)
            while (-not $inCorner -and (Get-Date) -lt $deadline) {
                foreach ($r in [CcwTest.Windows]::Rects($proc.Id)) {
                    if ([math]::Abs($r[2] - $work[2]) -le 2 -and [math]::Abs($r[3] - $work[3]) -le 2) { $inCorner = $true }
                }
                if (-not $inCorner) { Start-Sleep -Milliseconds 250 }
            }
            $inCorner | Should -BeTrue
            [IO.File]::ReadAllText($statePath) | Should -BeExactly $state
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

- [ ] **Step 6: Rodar o teste Desktop no código antigo do widget**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t3.txt; Get-Content $env:TEMP\t3.txt -Tail 15`
Esperado: 124 passed, 0 failed. O teste novo **passa** antes da mudança no widget (num monitor só, a conferência antiga também manda `-50000` para o canto). Isso é esperado: ele protege a ligação nova, e o RED do B5 está nos testes de `Resolve-Anchor` (Step 2). Para provar que o teste pega o widget no lugar errado, faça uma checagem de mutação: troque temporariamente `$state` por `'{"right":1500,"bottom":800}'` (um ponto válido longe do canto), rode só este arquivo (`Invoke-Pester tests\widget.Tests.ps1` dentro de `powershell -NoProfile`), veja FAIL em `$inCorner | Should -BeTrue` e desfaça a troca.

- [ ] **Step 7: Ligar as funções no `widget.ps1`**

Troque o bloco inteiro:

```powershell
    # --- Position: anchored by the bottom-right corner, so the card grows up/left ---
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:anchorRight = $wa.Right
    $script:anchorBottom = $wa.Bottom
    try {
        if (Test-Path -LiteralPath $StatePath) {
            $st = [IO.File]::ReadAllText($StatePath, $Utf8) | ConvertFrom-Json
            $vl = [System.Windows.SystemParameters]::VirtualScreenLeft
            $vt = [System.Windows.SystemParameters]::VirtualScreenTop
            $vr = $vl + [System.Windows.SystemParameters]::VirtualScreenWidth
            $vb = $vt + [System.Windows.SystemParameters]::VirtualScreenHeight
            $sr = [double]$st.right
            $sb = [double]$st.bottom
            # Only reuse it if it still fits on screen (a monitor may have been unplugged)
            if ($sr -gt $vl + 120 -and $sr -le $vr + 1 -and $sb -gt $vt + 60 -and $sb -le $vb + 1) {
                $script:anchorRight = $sr
                $script:anchorBottom = $sb
            }
        }
    } catch {}
```

por:

```powershell
    # --- Position: anchored by the bottom-right corner, so the card grows up/left ---
    # $script:savedAnchor is where you last dragged it (state.json). While that spot is on no screen
    # (its monitor was unplugged), the widget uses the main screen's corner, and it goes back to the
    # saved spot once that screen is back: only dragging writes state.json.
    $script:savedAnchor = $null
    try {
        if (Test-Path -LiteralPath $StatePath) { $script:savedAnchor = [IO.File]::ReadAllText($StatePath, $Utf8) | ConvertFrom-Json }
    } catch {}
    $wa = [System.Windows.SystemParameters]::WorkArea
    $script:anchorRight = $wa.Right
    $script:anchorBottom = $wa.Bottom
    $script:screenKey = $null
    # Re-resolves the anchor if the screens changed since the last call. Returns the new anchor
    # (@{ right; bottom; saved }), or $null when nothing changed.
    function Sync-Anchor {
        $areas = @(Get-ScreenAreas)
        $key = Get-ScreenKey $areas
        if ($key -eq $script:screenKey) { return $null }
        $script:screenKey = $key
        $a = Resolve-Anchor $script:savedAnchor $areas
        if ($a) {
            $script:anchorRight = $a.right
            $script:anchorBottom = $a.bottom
        }
        return $a
    }
    try { [void](Sync-Anchor) } catch { Write-Log $_ }
```

Troque o tratador do arrasto:

```powershell
    $win.Add_MouseLeftButtonDown({
        try { $win.DragMove() } catch {}
        $script:anchorRight = $win.Left + $win.ActualWidth
        $script:anchorBottom = $win.Top + $win.ActualHeight
        try {
            $state = @{ right = $script:anchorRight; bottom = $script:anchorBottom } | ConvertTo-Json -Compress
            [IO.File]::WriteAllText($StatePath, $state, $Utf8)
        } catch {}
    })
```

por:

```powershell
    $win.Add_MouseLeftButtonDown({
        $left = $win.Left
        $top = $win.Top
        try { $win.DragMove() } catch {}
        # A click without a move keeps the saved spot (its monitor may be unplugged right now)
        if ($win.Left -eq $left -and $win.Top -eq $top) { return }
        $script:anchorRight = $win.Left + $win.ActualWidth
        $script:anchorBottom = $win.Top + $win.ActualHeight
        $script:savedAnchor = @{ right = $script:anchorRight; bottom = $script:anchorBottom }
        try { [IO.File]::WriteAllText($StatePath, ($script:savedAnchor | ConvertTo-Json -Compress), $Utf8) } catch {}
    })
```

Troque a linha do timer:

```powershell
    $timer.Add_Tick({ try { Update-View } catch { Write-Log $_ } })
```

por:

```powershell
    $script:ticks = 0
    $timer.Add_Tick({
        try { Update-View } catch { Write-Log $_ }
        # Every ~2 s: a monitor unplugged or back, a resolution change, the taskbar moved
        $script:ticks++
        if ($script:ticks % 5 -eq 0) {
            try {
                $a = Sync-Anchor
                if ($a) {
                    Update-Position
                    Write-Log ('screens changed: anchor {0},{1} ({2})' -f [int]$a.right, [int]$a.bottom, $(if ($a.saved) { 'saved' } else { 'default' }))
                }
            } catch { Write-Log $_ }
        }
    })
```

- [ ] **Step 8: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t3.txt; Get-Content $env:TEMP\t3.txt -Tail 15`
Esperado: 124 passed, 0 failed. Os três testes Desktop (render, fila, posição) passam: o widget abre, compila os dois tipos C#, não grava `widget.log` e respeita o canto.

- [ ] **Step 9: Commit**

```bash
git add plugins/opaiva-code-widget/scripts/common.ps1 plugins/opaiva-code-widget/scripts/widget.ps1 tests/common.Tests.ps1 tests/widget.Tests.ps1
git commit -m "fix: keep the widget on screen when monitors change

The saved spot is checked monitor by monitor (also on startup) and again every
~2 s; while it is on no screen the widget uses the main screen's corner and
returns once that screen is back. Monitors come from GetMonitorInfo.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Ajustes pequenos adiados (blocos 1 e 2)

**Files:**
- Modify: `tests/common.Tests.ps1` (`Get-DoneNotices`)
- Modify: `tests/repo.Tests.ps1` (leitor de Markdown, regra do id antigo, regra de `permissions`)
- Modify: `.github/workflows/test.yml`
- Modify: `tests/helpers/HookHarness.ps1:74`
- Modify: `tools/test.ps1:1`, `README.md:153`, `README.pt-BR.md:153`

**Interfaces:**
- Consumes: nada.
- Produces: helpers de teste `Get-MarkdownLines([string]$Path)` → objetos `{ section; text }`, `Get-MarkdownSection([string]$Path, [string]$Heading)` → linhas, `Get-OldPluginIdLines([string]$Path)` → linhas.

- [ ] **Step 1: Teste do cache de `Get-DoneNotices`**

Em `tests/common.Tests.ps1`, dentro de `Describe 'Get-DoneNotices'`, depois do `It 'deletes notices older than the maximum age'`:

```powershell
    It 'forgets cached notices whose file is gone' {
        $path = New-TestNotice $queue 's1' ($now - 1000)
        [void](Get-DoneNotices $queue $cache $maxAge)
        $cache.Count | Should -Be 1
        Remove-Item -LiteralPath $path
        @(Get-DoneNotices $queue $cache $maxAge).Count | Should -Be 0
        $cache.Count | Should -Be 0
    }
```

Este teste cobre um comportamento que já existe, então passa de primeira. Checagem de mutação: comente a linha `foreach ($k in @($Cache.Keys)) { if (-not $names.ContainsKey($k)) { $Cache.Remove($k) } }` de `Get-DoneNotices` no `common.ps1`, rode o arquivo e veja FAIL em `$cache.Count | Should -Be 0` (e o aviso apagado volta na lista). Desfaça.

- [ ] **Step 2: Testes das regras novas do repositório**

Em `tests/repo.Tests.ps1`, troque o `BeforeAll` do `Describe 'repository rules'`:

```powershell
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        # Lines of a markdown file under the ##/### headings whose title matches $Heading
        function Get-MarkdownSection([string]$Path, [string]$Heading) {
            $section = ''
            foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
                if ($line -match '^#{2,3} (.+)$') { $section = $Matches[1] }
                if ($section -match $Heading) { $line }
            }
        }
    }
```

por:

```powershell
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        # Each line of a markdown file with the ##/### heading it sits under ({ section; text }).
        # Lines inside ``` code blocks never start a section, even when they begin with #.
        function Get-MarkdownLines([string]$Path) {
            $section = ''
            $code = $false
            foreach ($line in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
                if ($line -match '^\s*```') { $code = -not $code }
                elseif (-not $code -and $line -match '^#{2,3} (.+)$') { $section = $Matches[1] }
                [pscustomobject]@{ section = $section; text = $line }
            }
        }
        # Lines of a markdown file under the ##/### headings whose title matches $Heading
        function Get-MarkdownSection([string]$Path, [string]$Heading) {
            Get-MarkdownLines $Path | Where-Object { $_.section -match $Heading } | ForEach-Object { $_.text }
        }
        # Lines outside the 2.0.0 migration section that still name the old plugin, with or without
        # "@<marketplace>". The marketplace keeps the old name, so "marketplace update claude-code-widget" is fine.
        function Get-OldPluginIdLines([string]$Path) {
            Get-MarkdownLines $Path | Where-Object {
                $_.section -notmatch '2\.0\.0' -and
                $_.text -match '(?<![\w-])claude-code-widget@|plugin (install|uninstall|update|enable|disable) claude-code-widget(?![\w@-])'
            } | ForEach-Object { $_.text }
        }
    }
```

Troque o teste `'<name> uses the old plugin id only in the 2.0.0 section, uninstalling first'` inteiro por:

```powershell
    It '<name> uses the old plugin id only in the 2.0.0 section, uninstalling first' -ForEach $readmes {
        @(Get-OldPluginIdLines $path) | Should -BeNullOrEmpty
        $text = @(Get-MarkdownSection $path '2\.0\.0') -join "`n"
        $uninstall = $text.IndexOf('claude plugin uninstall claude-code-widget@claude-code-widget')
        $install = $text.IndexOf('claude plugin install opaiva-code-widget@claude-code-widget')
        $uninstall | Should -BeGreaterOrEqual 0
        $install | Should -BeGreaterThan $uninstall
    }
```

Logo depois do teste `'<name> has no multi-command PowerShell steps'`, acrescente:

```powershell
    # The workflow only reads the repository: its token should not be able to write to it
    It '<name> limits the token permissions' -ForEach $workflows {
        [IO.File]::ReadAllText($path) | Should -Match '(?m)^permissions:'
    }
```

No fim do `Describe 'repository rules'` (antes da última `}`), acrescente:

```powershell
    Context 'markdown helpers' {
        BeforeAll {
            $sample = Join-Path $TestDrive 'sample.md'
            $fence = '```'
            [IO.File]::WriteAllLines($sample, [string[]]@(
                    '## Install'
                    'Run /plugin install claude-code-widget now.'
                    'claude plugin marketplace update claude-code-widget'
                    'claude plugin install opaiva-code-widget@claude-code-widget'
                    '### Renamed in 2.0.0'
                    $fence
                    '## not a heading'
                    'claude plugin uninstall claude-code-widget@claude-code-widget'
                    $fence
                    'after the block'
                ))
        }
        It 'ignores # lines inside code blocks' {
            @(Get-MarkdownSection $sample '2\.0\.0') -contains 'after the block' | Should -BeTrue
        }
        It 'finds the old plugin id without "@" outside the migration section' {
            (@(Get-OldPluginIdLines $sample) -join '|') | Should -BeExactly 'Run /plugin install claude-code-widget now.'
        }
    }
```

- [ ] **Step 3: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t4.txt; Get-Content $env:TEMP\t4.txt -Tail 15`
Esperado: só `.github\workflows\test.yml limits the token permissions` FAIL. Os helpers já estão no `BeforeAll`, então os dois testes de `markdown helpers` passam; para provar que eles pegam o problema, faça a checagem de mutação: troque `elseif (-not $code -and $line -match ...)` por `if ($line -match ...)` (o comportamento antigo), rode e veja FAIL em `ignores # lines inside code blocks`; desfaça. Total: 127 passed, 1 failed.

- [ ] **Step 4: `permissions` no workflow**

Em `.github/workflows/test.yml`, depois do bloco `on:` (antes de `jobs:`), acrescente:

```yaml
permissions:
  contents: read

```

E troque `      - name: Install Pester 5` por `      - name: Install Pester`.

- [ ] **Step 5: Harness e textos do Pester**

Em `tests/helpers/HookHarness.ps1`, troque:

```powershell
    $psi.EnvironmentVariables['CLAUDE_WIDGET_AWAY_SECS'] = '100000'
```

por:

```powershell
    # Far above any uptime: a CI machine that has had no input since boot is never "away"
    $psi.EnvironmentVariables['CLAUDE_WIDGET_AWAY_SECS'] = '2000000000'
```

Em `tools/test.ps1`, linha 1: `with Pester 5, on Windows PowerShell 5.1` → `with Pester 5.5 or later, on Windows PowerShell 5.1`.

Em `README.md`, linha 153: `install [Pester 5](https://pester.dev) once with` → `install [Pester](https://pester.dev) 5.5 or later once with`.

Em `README.pt-BR.md`, linha 153: `instale o [Pester 5](https://pester.dev) uma vez com` → `instale o [Pester](https://pester.dev) 5.5 ou mais novo uma vez com`.

- [ ] **Step 6: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t4.txt; Get-Content $env:TEMP\t4.txt -Tail 15`
Esperado: 128 passed, 0 failed.

- [ ] **Step 7: Commit**

```bash
git add tests/common.Tests.ps1 tests/repo.Tests.ps1 .github/workflows/test.yml tests/helpers/HookHarness.ps1 tools/test.ps1 README.md README.pt-BR.md
git commit -m "test: deferred minors from blocks 1 and 2

Get-DoneNotices cache test; read-only workflow token (with a repo rule); the old
plugin id rule also catches it without '@'; markdown sections ignore code blocks;
harness AWAY_SECS far above any uptime; docs say Pester 5.5 or later.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Release 2.0.1

**Files:**
- Modify: `CHANGELOG.md`, `plugins/opaiva-code-widget/.claude-plugin/plugin.json`, `README.md`, `README.pt-BR.md`

**Interfaces:**
- Consumes: as correções das Tasks 1 a 3.
- Produces: versão 2.0.1.

- [ ] **Step 1: Entrada no CHANGELOG**

Em `CHANGELOG.md`, logo depois de `# Changelog` e da linha em branco:

```markdown
## 2.0.1 (2026-10-07)

- **Monitor changes.** If the widget's monitor is unplugged while the widget is open, the widget moves to the main screen's corner within a couple of seconds, and goes back to where you put it once that monitor is back. A saved position between monitors of different sizes no longer opens the widget off screen.
- **VS Code windows are matched by the whole project name.** A project called `widget` no longer matches the `claude-code-widget` window, or a `widget.ps1` file open in another project. The "finished" notice is no longer skipped by mistake, and **Go to VS Code** brings the right window.
- `widget.log` is capped like `hook.log`: past 256 KB it moves to `widget.log.old`.

```

- [ ] **Step 2: Rodar e ver falhar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t5.txt; Get-Content $env:TEMP\t5.txt -Tail 15`
Esperado: `plugin.json version matches the latest CHANGELOG entry` FAIL (`Expected '2.0.0', but got '2.0.1'` ou o inverso). Total: 127 passed, 1 failed.

- [ ] **Step 3: Versão e READMEs**

Em `plugins/opaiva-code-widget/.claude-plugin/plugin.json`: `"version": "2.0.0"` → `"version": "2.0.1"`.

Em `README.md`, na seção "Behavior worth knowing", logo depois do item **Away from the computer.**, acrescente:

```markdown
- **Monitor changes.** If the widget's monitor goes away (say, you undock the laptop), the widget moves to the main screen's bottom-right corner within a couple of seconds. When that monitor is back, it returns to where you put it.
```

E em "How it works", troque `and logs (`hook.log`, `widget.log`).` por `and logs (`hook.log`, `widget.log`; each keeps up to 256 KB, plus one `.old` file).`

Em `README.pt-BR.md`, na seção "Comportamentos importantes", logo depois do item **Longe do computador.**, acrescente:

```markdown
- **Troca de monitor.** Se o monitor do widget some (por exemplo, quando você tira o notebook da dock), o widget vai para o canto inferior direito da tela principal em até 2 segundos. Quando o monitor volta, ele volta para onde você tinha colocado.
```

E em "Como funciona", troque `e os logs (`hook.log`, `widget.log`).` por `e os logs (`hook.log`, `widget.log`; cada um guarda até 256 KB, mais um arquivo `.old`).`

- [ ] **Step 4: Rodar e ver passar**

Run: `powershell -NoProfile -File tools\test.ps1 > $env:TEMP\t5.txt; Get-Content $env:TEMP\t5.txt -Tail 15`
Esperado: 128 passed, 0 failed.

- [ ] **Step 5: Commit**

```bash
git add CHANGELOG.md plugins/opaiva-code-widget/.claude-plugin/plugin.json README.md README.pt-BR.md
git commit -m "docs: release 2.0.1

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

- [ ] **Step 6: Verificação depois do merge (com o usuário)**

Depois de instalar a 2.0.1 (`claude plugin marketplace update claude-code-widget` + `claude plugin update opaiva-code-widget@claude-code-widget` + `/reload-plugins`):
1. O widget roda de `...\opaiva-code-widget\2.0.1\scripts\widget.ps1` e o `widget.log` não tem erros novos.
2. "Ir para o VS Code" sem janela guardada: grave na fila um aviso `done-manual-<ms>.json` com `cwd` = a pasta deste repositório, `hwnd` = 0 e `kind` = `vscode`; com outra janela na frente, peça ao usuário para clicar em **Ir para o VS Code** e confirme que a janela do `claude-code-widget-1` vem para a frente.
