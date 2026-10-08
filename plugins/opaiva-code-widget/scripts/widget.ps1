# opaiva-code-widget: always-on-top desktop widget for Claude Code (Windows PowerShell 5.1 + WPF).
# Never takes focus: it sits in a corner of the screen and shows, in this order of priority:
#   1. requests written by hook.ps1 to queue\req-<id>.json, answered in queue\res-<id>.json
#        kind=permission -> Approve / Deny / Decide in VS Code
#        kind=question   -> multiple-choice questions (AskUserQuestion) -> answers
#   2. "Claude finished" notices (queue\done-<session>-<ms>.json); OK / Go to VS Code delete them
#   3. a small "no requests" pill
# It only accepts focus while you type an "Other answer", then gives focus back.
# Drag to move (position saved in state.json); right-click > Close widget.
# Started by hook.ps1 with the plugin data dir; usually you never run it by hand.
# -RenderSamples <samples.json> -OutDir <dir>: draws each state with sample data to transparent PNGs
# (README screenshots, see tools/render-screenshots.ps1) and exits, without touching the queue.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less files as ANSI. UI text lives in
# strings.json (read explicitly as UTF-8).
param(
    [string]$DataDir = (Join-Path $env:USERPROFILE '.claude\opaiva-code-widget'),
    [string]$Lang = '',
    [string]$RenderSamples = '',
    [string]$OutDir = ''
)
$RenderMode = [bool]$RenderSamples
$ErrorActionPreference = 'Stop'
$Utf8 = New-Object System.Text.UTF8Encoding $false
. (Join-Path $PSScriptRoot 'common.ps1')
$Data = [IO.Path]::GetFullPath($DataDir).TrimEnd('\')
$Queue = Join-Path $Data 'queue'
$StatePath = Join-Path $Data 'state.json'
$LogPath = Join-Path $Data 'widget.log'
$DoneMaxAgeMs = 12 * 3600 * 1000

$Lang = Resolve-Lang $Lang
$S = Get-Strings $Lang

# One widget per data dir; hook.ps1 computes the same name to know whether the widget is running
$MutexName = Get-MutexName $Data
$mutex = $null
if (-not $RenderMode) {
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
    if (-not $createdNew) { exit 0 }
}

$script:lastErr = $null
function Write-Log($msg) {
    $text = [string]$msg
    if ($text -eq $script:lastErr) { return }
    $script:lastErr = $text
    Write-LogLine $LogPath $text
}

try {
    if (-not $RenderMode) {
        New-Item -ItemType Directory -Force -Path $Queue | Out-Null
        # Lets hook.ps1 replace this widget after a plugin update (different script path)
        [IO.File]::WriteAllText((Join-Path $Data 'widget.json'), (@{ pid = $PID; script = $PSCommandPath } | ConvertTo-Json -Compress), $Utf8)
        # Responses and temp files from a previous run are useless now
        Get-ChildItem -LiteralPath $Queue -File | Where-Object { $_.Name -like 'res-*' -or $_.Name -like '*.tmp' } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    }

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

    # Win32: bring VS Code to the front, keep the widget from ever becoming the active window
    # (NoActivate), and allow focus only while typing a free-text answer
    $script:canFocus = $false
    try {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace ClaudeWidget {
    public static class WinFocus {
        delegate bool EnumProc(IntPtr h, IntPtr l);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
        [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);
        [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int index, int value);
        const int GWL_EXSTYLE = -20;
        const int WS_EX_NOACTIVATE = 0x08000000;
        // On: clicks still reach the buttons, but the window never steals focus
        public static void SetNoActivate(IntPtr h, bool on) {
            int ex = GetWindowLong(h, GWL_EXSTYLE);
            SetWindowLong(h, GWL_EXSTYLE, on ? (ex | WS_EX_NOACTIVATE) : (ex & ~WS_EX_NOACTIVATE));
        }
        public static void DestroyIconHandle(IntPtr h) { DestroyIcon(h); }
        public static IntPtr Foreground() { return GetForegroundWindow(); }
        public static bool Activate(IntPtr h) { return SetForegroundWindow(h); }
        // A session's remembered window (VS Code or terminal), if it still exists
        public static bool FocusHandle(long handle) {
            var h = new IntPtr(handle);
            if (handle == 0 || !IsWindow(h)) return false;
            if (IsIconic(h)) ShowWindow(h, 9);
            return SetForegroundWindow(h);
        }
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
    }
}
'@
        $script:canFocus = $true
    } catch { Write-Log $_ }

    # "Finished" sound (different from the request sound)
    $script:doneSound = $null
    $wav = Join-Path $env:WINDIR 'Media\Windows Notify System Generic.wav'
    if (Test-Path -LiteralPath $wav) {
        try { $script:doneSound = New-Object System.Media.SoundPlayer $wav; $script:doneSound.Load() } catch { $script:doneSound = $null }
    }

    # "All done" sound: the last session of a round with several sessions finished
    $script:allDoneSound = $null
    $tada = Join-Path $env:WINDIR 'Media\tada.wav'
    if (Test-Path -LiteralPath $tada) {
        try { $script:allDoneSound = New-Object System.Media.SoundPlayer $tada; $script:allDoneSound.Load() } catch { $script:allDoneSound = $null }
    }

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Code" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual" FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Height" Value="36"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Focusable" Value="False"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="8" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="bd" Property="Opacity" Value="0.7"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chip" TargetType="Border">
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Padding" Value="9,3"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <!-- Slim dark scrollbar (the default Windows one is light gray) -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="8"/>
      <Setter Property="MinWidth" Value="8"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb>
                <Thumb>
                  <Thumb.Template>
                    <ControlTemplate TargetType="Thumb">
                      <Border Margin="3,0,0,0" CornerRadius="2.5" Background="#4A4A54"/>
                    </ControlTemplate>
                  </Thumb.Template>
                </Thumb>
              </Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Card" Margin="14" CornerRadius="14" Background="#1E1E22" BorderBrush="#34343B" BorderThickness="1">
    <Border.Effect><DropShadowEffect BlurRadius="20" ShadowDepth="3" Opacity="0.5" Color="Black"/></Border.Effect>
    <Grid>

      <StackPanel x:Name="IdlePanel" Orientation="Horizontal" Margin="14,9,16,9" Background="Transparent">
        <Ellipse Width="8" Height="8" Fill="#5FB98A" VerticalAlignment="Center" Margin="0,0,9,0"/>
        <TextBlock Text="Claude Code" Foreground="#E8E8EC" FontSize="12.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="IdleText" Foreground="#7E7E88" FontSize="12" VerticalAlignment="Center"/>
      </StackPanel>

      <StackPanel x:Name="ReqPanel" Width="440" Margin="20,16,20,18" Visibility="Collapsed">
        <DockPanel Margin="0,0,0,12">
          <TextBlock x:Name="Countdown" DockPanel.Dock="Right" Foreground="#7E7E88" FontSize="12" VerticalAlignment="Center"/>
          <Ellipse x:Name="ReqDot" Width="10" Height="10" Fill="#D97757" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock Text="Claude Code" Foreground="#F4F4F6" FontSize="14.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="ReqTitle" Foreground="#8A8A93" FontSize="12.5" VerticalAlignment="Center"/>
        </DockPanel>

        <WrapPanel Margin="0,0,0,10">
          <Border Style="{StaticResource Chip}" Background="#3A2A24">
            <TextBlock x:Name="Tool" Foreground="#F0A58A" FontSize="12" FontWeight="SemiBold"/>
          </Border>
          <Border x:Name="ProjectChip" Style="{StaticResource Chip}" Background="#26262C" BorderBrush="#34343B" BorderThickness="1">
            <TextBlock x:Name="Project" Foreground="#C8C8D0" FontSize="12"/>
          </Border>
          <Border x:Name="QueueChip" Style="{StaticResource Chip}" Background="#2E2A1E" Visibility="Collapsed">
            <TextBlock x:Name="QueueText" Foreground="#E8C770" FontSize="12" FontWeight="SemiBold"/>
          </Border>
        </WrapPanel>

        <TextBlock x:Name="Desc" Foreground="#DADAE0" FontSize="13.5" TextWrapping="Wrap" Margin="0,0,0,10"/>

        <Border CornerRadius="8" Background="#141417" BorderBrush="#2C2C33" BorderThickness="1" Padding="12,9">
          <TextBox x:Name="Detail" IsReadOnly="True" Background="Transparent" BorderThickness="0"
                   Foreground="#E8E8EC" FontFamily="Cascadia Mono, Consolas" FontSize="12"
                   TextWrapping="Wrap" MaxHeight="160" VerticalScrollBarVisibility="Auto"
                   SelectionBrush="#D97757"/>
        </Border>

        <TextBlock x:Name="Cwd" Foreground="#6E6E78" FontSize="11" Margin="2,8,0,0" TextTrimming="CharacterEllipsis"/>

        <DockPanel Margin="0,16,0,0" LastChildFill="False">
          <Button x:Name="BtnApprove" Style="{StaticResource Btn}"
                  Background="#D97757" BorderBrush="#D97757" DockPanel.Dock="Left"/>
          <Button x:Name="BtnDeny" Style="{StaticResource Btn}"
                  Background="Transparent" BorderBrush="#6A3A3A" Foreground="#F29090"
                  Margin="8,0,0,0" DockPanel.Dock="Left"/>
          <Button x:Name="BtnVs" Style="{StaticResource Btn}"
                  Background="#2A2A30" BorderBrush="#3A3A42" Foreground="#C8C8D0" DockPanel.Dock="Right"/>
        </DockPanel>
      </StackPanel>

      <StackPanel x:Name="QPanel" Width="460" Margin="20,16,20,18" Visibility="Collapsed">
        <DockPanel Margin="0,0,0,12">
          <TextBlock x:Name="QCountdown" DockPanel.Dock="Right" Foreground="#7E7E88" FontSize="12" VerticalAlignment="Center"/>
          <Ellipse x:Name="QDot" Width="10" Height="10" Fill="#7AA2F7" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock Text="Claude Code" Foreground="#F4F4F6" FontSize="14.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="QTitle" Foreground="#8A8A93" FontSize="12.5" VerticalAlignment="Center"/>
        </DockPanel>

        <WrapPanel Margin="0,0,0,10">
          <Border x:Name="QProjectChip" Style="{StaticResource Chip}" Background="#26262C" BorderBrush="#34343B" BorderThickness="1">
            <TextBlock x:Name="QProject" Foreground="#C8C8D0" FontSize="12"/>
          </Border>
          <Border x:Name="QQueueChip" Style="{StaticResource Chip}" Background="#2E2A1E" Visibility="Collapsed">
            <TextBlock x:Name="QQueueText" Foreground="#E8C770" FontSize="12" FontWeight="SemiBold"/>
          </Border>
        </WrapPanel>

        <ScrollViewer MaxHeight="560" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <StackPanel x:Name="QList"/>
        </ScrollViewer>

        <DockPanel Margin="0,14,0,0" LastChildFill="False">
          <Button x:Name="BtnAnswer" Style="{StaticResource Btn}"
                  Background="#D97757" BorderBrush="#D97757" DockPanel.Dock="Left"/>
          <Button x:Name="BtnQVs" Style="{StaticResource Btn}"
                  Background="#2A2A30" BorderBrush="#3A3A42" Foreground="#C8C8D0" DockPanel.Dock="Right"/>
        </DockPanel>
      </StackPanel>

      <StackPanel x:Name="DonePanel" Width="380" Margin="18,14,18,16" Visibility="Collapsed">
        <DockPanel Margin="0,0,0,10">
          <TextBlock x:Name="DoneAgo" DockPanel.Dock="Right" Foreground="#7E7E88" FontSize="12" VerticalAlignment="Center"/>
          <Border Width="18" Height="18" CornerRadius="9" Background="#2F6F4E" VerticalAlignment="Center" Margin="0,0,9,0">
            <TextBlock Text="&#10003;" Foreground="#FFFFFF" FontSize="11" FontWeight="Bold"
                       HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock Text="Claude Code" Foreground="#F4F4F6" FontSize="14.5" FontWeight="SemiBold" VerticalAlignment="Center"/>
          <TextBlock x:Name="DoneTitle" Foreground="#8A8A93" FontSize="12.5" VerticalAlignment="Center"/>
        </DockPanel>

        <WrapPanel Margin="0,0,0,8">
          <Border x:Name="DoneProjectChip" Style="{StaticResource Chip}" Background="#26262C" BorderBrush="#34343B" BorderThickness="1">
            <TextBlock x:Name="DoneProject" Foreground="#C8C8D0" FontSize="12"/>
          </Border>
          <Border x:Name="DoneMoreChip" Style="{StaticResource Chip}" Background="#1F2E26" Visibility="Collapsed">
            <TextBlock x:Name="DoneMoreText" Foreground="#7FD1A4" FontSize="12" FontWeight="SemiBold"/>
          </Border>
        </WrapPanel>

        <TextBlock x:Name="DoneMsg" Foreground="#C8C8D0" FontSize="13" TextWrapping="Wrap"
                   TextTrimming="CharacterEllipsis" LineHeight="19" LineStackingStrategy="BlockLineHeight" MaxHeight="57"/>

        <DockPanel Margin="0,14,0,0" LastChildFill="False">
          <Button x:Name="BtnGoVs" Style="{StaticResource Btn}" Height="32"
                  Background="#2F6F4E" BorderBrush="#2F6F4E" DockPanel.Dock="Left"/>
          <Button x:Name="BtnDismiss" Style="{StaticResource Btn}" Height="32"
                  Background="#2A2A30" BorderBrush="#3A3A42" Foreground="#C8C8D0" DockPanel.Dock="Right"/>
        </DockPanel>
      </StackPanel>

    </Grid>
  </Border>
</Window>
'@

    $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ui = @{}
    foreach ($n in 'Card', 'IdlePanel', 'IdleText', 'ReqPanel', 'ReqTitle', 'QPanel', 'QTitle', 'DonePanel', 'DoneTitle',
        'ReqDot', 'Countdown', 'Tool', 'ProjectChip', 'Project', 'QueueChip', 'QueueText', 'Desc', 'Detail', 'Cwd',
        'BtnApprove', 'BtnDeny', 'BtnVs', 'QCountdown', 'QDot', 'QProjectChip', 'QProject', 'QQueueChip', 'QQueueText',
        'QList', 'BtnAnswer', 'BtnQVs', 'DoneAgo', 'DoneProjectChip', 'DoneProject', 'DoneMoreChip', 'DoneMoreText',
        'DoneMsg', 'BtnGoVs', 'BtnDismiss') {
        $ui[$n] = $win.FindName($n)
    }

    # --- Localized text ---
    $Sep = '  ' + [char]0x00B7 + '  '
    $win.Title = $S.windowTitle
    $ui.IdleText.Text = $Sep + $S.idle
    $ui.IdlePanel.ToolTip = $S.idleTip
    $ui.ReqTitle.Text = $Sep + $S.permissionTitle
    $ui.QTitle.Text = $Sep + $S.questionTitle
    $ui.DoneTitle.Text = $Sep + $S.doneTitle
    $ui.BtnApprove.Content = $S.approve
    $ui.BtnDeny.Content = $S.deny
    $ui.BtnVs.Content = $S.decideInVsCode
    $ui.BtnAnswer.Content = $S.answer
    $ui.BtnQVs.Content = $S.answerInVsCode
    $ui.BtnGoVs.Content = $S.goToVsCode
    $ui.BtnDismiss.Content = $S.ok

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

    function Update-Position {
        $win.Left = [math]::Max([System.Windows.SystemParameters]::VirtualScreenLeft, $script:anchorRight - $win.ActualWidth)
        $win.Top = [math]::Max([System.Windows.SystemParameters]::VirtualScreenTop, $script:anchorBottom - $win.ActualHeight)
    }
    $win.Left = $script:anchorRight - 220
    $win.Top = $script:anchorBottom - 70
    $win.Add_SizeChanged({ Update-Position })
    $win.Add_Loaded({ Update-Position })

    $script:hwnd = [IntPtr]::Zero
    $win.Add_SourceInitialized({
        $script:hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
        if ($script:canFocus) { [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $true) }
    })

    $win.Add_MouseLeftButtonDown({
        param($src, $e)
        # Buttons, options and the text box handle their own clicks and never get here
        if ($e.ClickCount -eq 2) { Invoke-DoubleClick; return }
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

    # --- State ---
    $script:cache = @{}        # req-*.json already read (file name -> request)
    $script:doneCache = @{}    # done-*.json already read
    $script:seen = @{}         # requests/notices that already played their sound
    $script:current = $null    # request/question on screen
    $script:currentDone = $null
    $script:shownAt = 0
    $script:qState = New-Object System.Collections.ArrayList   # state of the questions on screen
    $script:typing = $false    # focus allowed to type an "Other answer"
    $script:prevFg = [IntPtr]::Zero

    $script:brushes = @{}
    function Get-Brush([string]$hex) {
        if (-not $script:brushes.ContainsKey($hex)) {
            $b = (New-Object System.Windows.Media.BrushConverter).ConvertFromString($hex)
            $b.Freeze()
            $script:brushes[$hex] = $b
        }
        return $script:brushes[$hex]
    }

    # --- Focus: only while typing a free-text answer ---
    function Enable-Typing($box) {
        if ($script:canFocus -and $script:hwnd -ne [IntPtr]::Zero) {
            if (-not $script:typing) {
                $script:prevFg = [ClaudeWidget.WinFocus]::Foreground()
                [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $false)
                $script:typing = $true
            }
            [void][ClaudeWidget.WinFocus]::Activate($script:hwnd)
        }
        [void]$win.Activate()
        $box.UpdateLayout()
        [void]$box.Focus()
        [void][System.Windows.Input.Keyboard]::Focus($box)
    }

    function Disable-Typing {
        if (-not $script:typing) { return }
        $script:typing = $false
        if ($script:canFocus -and $script:hwnd -ne [IntPtr]::Zero) {
            [ClaudeWidget.WinFocus]::SetNoActivate($script:hwnd, $true)
            # Give focus back to where you were, if it is still on the widget
            if ([ClaudeWidget.WinFocus]::Foreground() -eq $script:hwnd -and $script:prevFg -ne [IntPtr]::Zero) {
                [void][ClaudeWidget.WinFocus]::Activate($script:prevFg)
            }
        }
        $script:prevFg = [IntPtr]::Zero
    }

    function Set-Panel([string]$name) {
        if ($name -ne 'QPanel') { Disable-Typing }
        foreach ($p in 'IdlePanel', 'ReqPanel', 'QPanel', 'DonePanel') {
            $v = if ($p -eq $name) { 'Visible' } else { 'Collapsed' }
            if ($ui[$p].Visibility -ne $v) { $ui[$p].Visibility = $v }
        }
    }

    function Invoke-Attention([string]$key, [scriptblock]$sound) {
        if ($RenderMode -or $script:seen.ContainsKey($key)) { return }
        $script:seen[$key] = $true
        & $sound
        # Re-assert "always on top" in case another window took over
        $win.Topmost = $false
        $win.Topmost = $true
    }

    function Set-Countdown($textBlock, $r) {
        $left = [int]$r.timeout - [int](((Get-NowMs) - [int64]$r.created) / 1000)
        if ($left -lt 0) { $left = 0 }
        $textBlock.Text = $S.closesIn -f [math]::Floor($left / 60), ($left % 60)
    }

    function Set-QueueChip($chip, $textBlock, [int]$total) {
        if ($total -gt 1) {
            $textBlock.Text = $S.queued -f ($total - 1)
            $chip.Visibility = 'Visible'
        }
        else { $chip.Visibility = 'Collapsed' }
    }

    # "project . session title" (the title cut at 40 characters); either part may be missing
    function Set-ProjectChip($chip, $textBlock, $item) {
        $text = if ($item.cwd) { Split-Path -Leaf ([string]$item.cwd) } else { '' }
        $title = ([string]$item.title).Trim()
        if ($title.Length -gt 40) { $title = $title.Substring(0, 39) + '...' }
        if ($title) { $text = if ($text) { $text + ' ' + [char]0x00B7 + ' ' + $title } else { $title } }
        $textBlock.Text = $text
        $chip.Visibility = if ($text) { 'Visible' } else { 'Collapsed' }
    }

    # Queue readers live in common.ps1; the caches keep each file from being re-read every tick
    function Get-Pending { Get-PendingRequests $Queue $script:cache }
    function Get-Done { Get-DoneNotices $Queue $script:doneCache $DoneMaxAgeMs }

    # ---------------- Permission request ----------------
    function Show-Permission($r) {
        $ui.Tool.Text = [string]$r.tool
        Set-ProjectChip $ui.ProjectChip $ui.Project $r
        if ($r.cwd) { $ui.Cwd.Text = [string]$r.cwd; $ui.Cwd.Visibility = 'Visible' } else { $ui.Cwd.Visibility = 'Collapsed' }
        $ui.Desc.Text = [string]$r.description
        $ui.Detail.Text = [string]$r.detail
        $ui.Detail.ScrollToHome()
        Set-Panel 'ReqPanel'
        Invoke-Attention $r.id { [System.Media.SystemSounds]::Asterisk.Play() }
    }

    # ---------------- Question (AskUserQuestion) ----------------
    $CheckMark = [string][char]0x2713

    function New-TextBlock([string]$text, [double]$size, [string]$color, [switch]$Bold) {
        $tb = New-Object System.Windows.Controls.TextBlock
        $tb.Text = $text
        $tb.FontSize = $size
        $tb.Foreground = Get-Brush $color
        $tb.TextWrapping = 'Wrap'
        if ($Bold) { $tb.FontWeight = [System.Windows.FontWeights]::SemiBold }
        return $tb
    }

    # Radio (circle) or checkbox (rounded square) drawn as shapes: same size whether on or off
    function New-Indicator([bool]$multi, [hashtable]$tag) {
        $ind = New-Object System.Windows.Controls.Grid
        $ind.Width = 16
        $ind.Height = 16
        $ind.Margin = New-Object System.Windows.Thickness 0, 1, 10, 0
        $ind.VerticalAlignment = 'Top'
        if ($multi) {
            $ring = New-Object System.Windows.Controls.Border
            $ring.CornerRadius = New-Object System.Windows.CornerRadius 4
            $ring.BorderThickness = New-Object System.Windows.Thickness 1.5
            $mark = New-TextBlock $CheckMark 11 '#FFFFFF' -Bold
            $mark.HorizontalAlignment = 'Center'
            $mark.VerticalAlignment = 'Center'
            $ring.Child = $mark
            [void]$ind.Children.Add($ring)
        }
        else {
            $ring = New-Object System.Windows.Shapes.Ellipse
            $ring.StrokeThickness = 1.5
            $mark = New-Object System.Windows.Shapes.Ellipse
            $mark.Width = 8
            $mark.Height = 8
            $mark.HorizontalAlignment = 'Center'
            $mark.VerticalAlignment = 'Center'
            [void]$ind.Children.Add($ring)
            [void]$ind.Children.Add($mark)
        }
        $tag.ring = $ring
        $tag.mark = $mark
        $tag.multi = $multi
        return $ind
    }

    function New-OptionRow([string]$label, [string]$desc, [bool]$multi, [hashtable]$tag) {
        $row = New-Object System.Windows.Controls.Border
        $row.CornerRadius = New-Object System.Windows.CornerRadius 8
        $row.BorderThickness = New-Object System.Windows.Thickness 1
        $row.Padding = New-Object System.Windows.Thickness 10, 7, 10, 7
        $row.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
        $row.Cursor = [System.Windows.Input.Cursors]::Hand
        $dock = New-Object System.Windows.Controls.DockPanel
        $ind = New-Indicator $multi $tag
        [System.Windows.Controls.DockPanel]::SetDock($ind, 'Left')
        [void]$dock.Children.Add($ind)
        $texts = New-Object System.Windows.Controls.StackPanel
        [void]$texts.Children.Add((New-TextBlock $label 13 '#F0F0F4' -Bold))
        if ($desc) {
            $d = New-TextBlock $desc 12 '#9A9AA4'
            $d.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
            [void]$texts.Children.Add($d)
        }
        [void]$dock.Children.Add($texts)
        $row.Child = $dock
        $row.Tag = $tag
        # Handled MouseLeftButtonDown: the click picks the option instead of dragging the window
        $row.Add_MouseLeftButtonDown({ param($src, $e) $e.Handled = $true; Select-Option $src.Tag })
        return $row
    }

    function Show-Question($r) {
        Set-ProjectChip $ui.QProjectChip $ui.QProject $r
        $ui.QList.Children.Clear()
        $script:qState = New-Object System.Collections.ArrayList
        $questions = @($r.questions)
        for ($qi = 0; $qi -lt $questions.Count; $qi++) {
            $q = $questions[$qi]
            $st = @{
                text     = [string]$q.question
                multi    = [bool]$q.multiSelect
                options  = New-Object System.Collections.ArrayList
                selected = New-Object System.Collections.ArrayList
                other    = $false
                rows     = New-Object System.Collections.ArrayList
                otherBox = $null
            }
            $block = New-Object System.Windows.Controls.StackPanel
            if ($qi -lt $questions.Count - 1) { $block.Margin = New-Object System.Windows.Thickness 0, 0, 0, 16 }

            $head = New-Object System.Windows.Controls.WrapPanel
            $head.Margin = New-Object System.Windows.Thickness 0, 0, 0, 6
            if ($q.header) {
                $chip = New-Object System.Windows.Controls.Border
                $chip.CornerRadius = New-Object System.Windows.CornerRadius 6
                $chip.Padding = New-Object System.Windows.Thickness 9, 3, 9, 3
                $chip.Margin = New-Object System.Windows.Thickness 0, 0, 8, 0
                $chip.Background = Get-Brush '#22304A'
                $chip.Child = New-TextBlock ([string]$q.header) 12 '#9DB8F5' -Bold
                [void]$head.Children.Add($chip)
            }
            if ($st.multi) {
                $hint = New-TextBlock $S.multiHint 12 '#7E7E88'
                $hint.VerticalAlignment = 'Center'
                [void]$head.Children.Add($hint)
            }
            if ($head.Children.Count -gt 0) { [void]$block.Children.Add($head) }

            $qt = New-TextBlock $st.text 13.5 '#DADAE0'
            $qt.Margin = New-Object System.Windows.Thickness 0, 0, 0, 8
            [void]$block.Children.Add($qt)

            foreach ($o in @($q.options)) {
                $label = [string]$o.label
                [void]$st.options.Add($label)
                $row = New-OptionRow $label ([string]$o.description) $st.multi @{ qi = $qi; label = $label; other = $false }
                [void]$st.rows.Add($row)
                [void]$block.Children.Add($row)
            }
            $otherRow = New-OptionRow $S.otherLabel $S.otherDesc $st.multi @{ qi = $qi; label = $null; other = $true }
            [void]$st.rows.Add($otherRow)
            [void]$block.Children.Add($otherRow)

            $box = New-Object System.Windows.Controls.TextBox
            $box.Visibility = 'Collapsed'
            $box.Background = Get-Brush '#141417'
            $box.Foreground = Get-Brush '#E8E8EC'
            $box.CaretBrush = Get-Brush '#E8E8EC'
            $box.BorderBrush = Get-Brush '#D97757'
            $box.SelectionBrush = Get-Brush '#D97757'
            $box.Padding = New-Object System.Windows.Thickness 8, 6, 8, 6
            $box.Margin = New-Object System.Windows.Thickness 0, 0, 0, 4
            $box.FontSize = 13
            $box.TextWrapping = 'Wrap'
            $box.Add_TextChanged({ Update-QVisuals })
            $box.Add_KeyDown({ param($src, $e) if ($e.Key -eq 'Return') { $e.Handled = $true; Submit-Answers } })
            $st.otherBox = $box
            [void]$block.Children.Add($box)

            [void]$ui.QList.Children.Add($block)
            [void]$script:qState.Add($st)
        }
        Update-QVisuals
        Set-Panel 'QPanel'
        Invoke-Attention $r.id { [System.Media.SystemSounds]::Asterisk.Play() }
    }

    function Select-Option([hashtable]$tag) {
        $st = $script:qState[[int]$tag.qi]
        if ($tag.other) {
            if ($st.multi) { $st.other = -not $st.other }
            else { $st.selected.Clear(); $st.other = $true }
        }
        elseif ($st.multi) {
            if ($st.selected.Contains($tag.label)) { $st.selected.Remove($tag.label) } else { [void]$st.selected.Add($tag.label) }
        }
        else {
            $st.selected.Clear()
            [void]$st.selected.Add($tag.label)
            $st.other = $false
        }
        Update-QVisuals
        if ($tag.other -and $st.other) { Enable-Typing $st.otherBox }
        elseif (-not ($script:qState | Where-Object { $_.other })) { Disable-Typing }
    }

    function Update-QVisuals {
        $complete = $true
        foreach ($st in $script:qState) {
            foreach ($row in $st.rows) {
                $t = $row.Tag
                $on = if ($t.other) { $st.other } else { $st.selected.Contains($t.label) }
                $row.Background = Get-Brush $(if ($on) { '#3A2A24' } else { '#24242A' })
                $row.BorderBrush = Get-Brush $(if ($on) { '#D97757' } else { '#34343B' })
                $ringColor = Get-Brush $(if ($on) { '#D97757' } else { '#6E6E78' })
                $t.mark.Visibility = if ($on) { 'Visible' } else { 'Hidden' }
                if ($t.multi) {
                    # Checkbox: filled orange square with a white check
                    $t.ring.BorderBrush = $ringColor
                    $t.ring.Background = Get-Brush $(if ($on) { '#D97757' } else { '#00000000' })
                }
                else {
                    # Radio: orange ring with an orange dot
                    $t.ring.Stroke = $ringColor
                    $t.mark.Fill = Get-Brush '#D97757'
                }
            }
            $st.otherBox.Visibility = if ($st.other) { 'Visible' } else { 'Collapsed' }
            $otherText = $st.otherBox.Text.Trim()
            # A checked "Other answer" needs text; otherwise one checked option is enough
            $ok = if ($st.other) { $otherText.Length -gt 0 } else { $st.selected.Count -gt 0 }
            if (-not $ok) { $complete = $false }
        }
        $ui.BtnAnswer.IsEnabled = $complete
        $ui.BtnAnswer.Opacity = if ($complete) { 1.0 } else { 0.45 }
    }

    function Submit-Answers {
        $r = $script:current
        if (-not $r -or $r.kind -ne 'question' -or (Test-ClickTooSoon)) { return }
        if (-not $ui.BtnAnswer.IsEnabled) { return }
        # answers: question text -> chosen label (several: "A, B"); free text goes as typed
        $answers = [ordered]@{}
        foreach ($st in $script:qState) {
            $parts = New-Object System.Collections.ArrayList
            foreach ($label in $st.options) { if ($st.selected.Contains($label)) { [void]$parts.Add($label) } }
            if ($st.other) { [void]$parts.Add($st.otherBox.Text.Trim()) }
            $answers[$st.text] = ($parts -join ', ')
        }
        $res = Join-Path $Queue "res-$($r.id).json"
        if (-not (Test-Path -LiteralPath $res)) { Write-JsonAtomic $res ([ordered]@{ decision = 'answer'; answers = $answers }) }
        $script:current = $null
        Update-View
    }

    # ---------------- Views ----------------
    function Show-Idle {
        $script:current = $null
        $script:currentDone = $null
        Set-Panel 'IdlePanel'
    }

    function Show-Request($r, [int]$total) {
        $script:currentDone = $null
        if (-not $script:current -or $script:current.id -ne $r.id) {
            $script:current = $r
            $script:shownAt = Get-NowMs
            if ($r.kind -eq 'question') { Show-Question $r } else { Show-Permission $r }
        }
        if ($r.kind -eq 'question') {
            Set-QueueChip $ui.QQueueChip $ui.QQueueText $total
            Set-Countdown $ui.QCountdown $r
        }
        else {
            Set-QueueChip $ui.QueueChip $ui.QueueText $total
            Set-Countdown $ui.Countdown $r
        }
    }

    function Show-Done($d, [int]$total) {
        $script:current = $null
        if (-not $script:currentDone -or $script:currentDone.key -ne $d.key) {
            $script:currentDone = $d
            $script:shownAt = Get-NowMs
            Set-ProjectChip $ui.DoneProjectChip $ui.DoneProject $d
            $ui.DoneMsg.Text = [string]$d.message
            $ui.BtnGoVs.Content = switch ([string]$d.kind) {
                'terminal' { $S.goToTerminal }
                'other' { $S.goToWindow }
                default { $S.goToVsCode }
            }
            Set-Panel 'DonePanel'
            $allDone = [bool]$d.allDone
            Invoke-Attention $d.key {
                if ($allDone) {
                    if ($script:allDoneSound) { $script:allDoneSound.Play() } else { [System.Media.SystemSounds]::Exclamation.Play() }
                }
                elseif ($script:doneSound) { $script:doneSound.Play() }
                else { [System.Media.SystemSounds]::Beep.Play() }
            }
        }
        if ($total -gt 1) {
            $more = $total - 1
            $ui.DoneMoreText.Text = if ($more -eq 1) { $S.moreOne } else { $S.moreMany -f $more }
            $ui.DoneMoreChip.Visibility = 'Visible'
        }
        else { $ui.DoneMoreChip.Visibility = 'Collapsed' }
        $mins = [int][math]::Floor(((Get-NowMs) - [int64]$d.created) / 60000)
        if ($mins -lt 1) { $ui.DoneAgo.Text = $S.now }
        elseif ($mins -lt 60) { $ui.DoneAgo.Text = $S.minutesAgo -f $mins }
        else { $ui.DoneAgo.Text = $S.hoursAgo -f [math]::Floor($mins / 60) }
    }

    function Update-View {
        if ($script:dnd) { return }
        $p = @(Get-Pending)
        if ($p.Count -gt 0) { Show-Request $p[0] $p.Count; return }
        $d = @(Get-Done)
        if ($d.Count -gt 0) { Show-Done $d[0] $d.Count; return }
        Show-Idle
    }

    # Keeps a double click from also answering the next item in the queue
    function Test-ClickTooSoon { return ((Get-NowMs) - $script:shownAt) -lt 700 }

    function Send-Response($decision) {
        $r = $script:current
        if (-not $r -or (Test-ClickTooSoon)) { return }
        $res = Join-Path $Queue "res-$($r.id).json"
        if (-not (Test-Path -LiteralPath $res)) { Write-JsonAtomic $res @{ decision = $decision } }
        $script:current = $null
        Update-View
    }

    # The project's VS Code window (a title part equal to the project name), else any VS Code window
    function Find-VsCodeWindow([string]$project) {
        $windows = @([ClaudeWidget.WinFocus]::FindWindows('Visual Studio Code'))
        foreach ($h in $windows) {
            if (Test-TitleHasProject ([ClaudeWidget.WinFocus]::Title($h)) $project) { return $h }
        }
        if ($windows.Count -gt 0) { return $windows[0] }
        return [IntPtr]::Zero
    }

    # Brings the window remembered for the session you typed in last, if it still exists
    function Show-LatestSessionWindow {
        $dir = Join-Path $Data 'sessions'
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
            try {
                $w = [IO.File]::ReadAllText($f.FullName, $Utf8) | ConvertFrom-Json
                if ([ClaudeWidget.WinFocus]::FocusHandle([int64]$w.hwnd)) { return $true }
            } catch {}
        }
        return $false
    }

    # Double click outside buttons: the finished notice's session; otherwise the latest session's
    # window, else the VS Code window of the project on screen (or any VS Code window)
    function Invoke-DoubleClick {
        if (-not $script:canFocus) { return }
        if ($script:currentDone) { Close-DoneNotice -GoToSession; return }
        if (Show-LatestSessionWindow) { return }
        $project = if ($script:current -and $script:current.cwd) { Split-Path -Leaf ([string]$script:current.cwd) } else { '' }
        $h = Find-VsCodeWindow $project
        if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
    }

    function Close-DoneNotice([switch]$GoToSession) {
        $d = $script:currentDone
        if (-not $d -or (Test-ClickTooSoon)) { return }
        Remove-Item -LiteralPath $d.file -Force -ErrorAction SilentlyContinue
        $script:currentDone = $null
        if ($GoToSession -and $script:canFocus) {
            # The exact window remembered for that session (VS Code or terminal)...
            $focused = $d.hwnd -and [ClaudeWidget.WinFocus]::FocusHandle([int64]$d.hwnd)
            # ...otherwise, for VS Code sessions, the project's VS Code window, or any VS Code window
            if (-not $focused -and [string]$d.kind -in @('', 'vscode')) {
                $project = if ($d.cwd) { Split-Path -Leaf ([string]$d.cwd) } else { '' }
                $h = Find-VsCodeWindow $project
                if ($h -ne [IntPtr]::Zero) { [void][ClaudeWidget.WinFocus]::FocusHandle($h.ToInt64()) }
            }
        }
        Update-View
    }

    $ui.BtnApprove.Add_Click({ Send-Response 'allow' })
    $ui.BtnDeny.Add_Click({ Send-Response 'deny' })
    $ui.BtnVs.Add_Click({ Send-Response 'vscode' })
    $ui.BtnAnswer.Add_Click({ Submit-Answers })
    $ui.BtnQVs.Add_Click({ Send-Response 'vscode' })
    $ui.BtnDismiss.Add_Click({ Close-DoneNotice })
    $ui.BtnGoVs.Add_Click({ Close-DoneNotice -GoToSession })

    # Hands pending requests back to VS Code and exits (right-click > Close, and the tray menu)
    function Close-Widget {
        foreach ($r in @(Get-Pending)) {
            try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
        }
        $win.Close()
    }
    $menu = New-Object System.Windows.Controls.ContextMenu
    $closeItem = New-Object System.Windows.Controls.MenuItem
    $closeItem.Header = $S.closeWidget
    $closeItem.Add_Click({ Close-Widget })
    [void]$menu.Items.Add($closeItem)
    $ui.Card.ContextMenu = $menu

    # --- Tray icon and "do not disturb" ---
    # The mode is the file dnd.flag: hook.ps1 sends requests to VS Code while it exists, and here the
    # window is hidden. Re-read on every tick, so removing the file by hand works too.
    function New-DotIcon([string]$hex) {
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = 'AntiAlias'
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($hex))
        $g.FillEllipse($brush, 4, 4, 24, 24)
        $g.Dispose()
        $brush.Dispose()
        $h = $bmp.GetHicon()
        $icon = [System.Drawing.Icon]::FromHandle($h).Clone()
        [ClaudeWidget.WinFocus]::DestroyIconHandle($h)
        $bmp.Dispose()
        return $icon
    }
    $script:dnd = $false
    $tray = $null
    if (-not $RenderMode) {
        $iconOn = New-DotIcon '#D97757'
        $iconOff = New-DotIcon '#8A8A93'
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $dndItem = $trayMenu.Items.Add($S.trayDnd)
        $trayClose = $trayMenu.Items.Add($S.closeWidget)
        $tray.ContextMenuStrip = $trayMenu
        $tray.Icon = $iconOn
        $tray.Text = $S.trayTip
        function Sync-Dnd {
            $on = Test-Dnd $Data
            if ($on -eq $script:dnd) { return }
            $script:dnd = $on
            $tray.Icon = if ($on) { $iconOff } else { $iconOn }
            $tray.Text = if ($on) { $S.trayTipDnd } else { $S.trayTip }
            $dndItem.Checked = $on
            if ($on) {
                # Whatever is on screen goes back to VS Code
                foreach ($r in @(Get-Pending)) {
                    try { Write-JsonAtomic (Join-Path $Queue "res-$($r.id).json") @{ decision = 'vscode' } } catch {}
                }
                $script:current = $null
                $win.Hide()
            }
            else { $win.Show() }
        }
        $toggleDnd = { Set-Dnd $Data (-not (Test-Dnd $Data)); Sync-Dnd }
        $tray.Add_MouseClick({ param($s, $e) if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { & $toggleDnd } })
        $dndItem.Add_Click({ & $toggleDnd })
        $trayClose.Add_Click({ Close-Widget })
        $tray.Visible = $true
        # Hiding inside Loaded is undone when WPF finishes showing the window: hide a moment later
        $win.Add_Loaded({
            $once = New-Object System.Windows.Threading.DispatcherTimer
            $once.Interval = [TimeSpan]::FromMilliseconds(30)
            $once.Add_Tick({ param($sender, $e) $sender.Stop(); try { Sync-Dnd } catch { Write-Log $_ } })
            $once.Start()
        })
    }

    # Pulsing dot while a request or question is waiting
    foreach ($dot in $ui.ReqDot, $ui.QDot) {
        $pulse = [System.Windows.Media.Animation.DoubleAnimation]::new(1.0, 0.3, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(850)))
        $pulse.AutoReverse = $true
        $pulse.RepeatBehavior = [System.Windows.Media.Animation.RepeatBehavior]::Forever
        $dot.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $pulse)
    }

    # ---------------- README screenshots (-RenderSamples) ----------------
    function Save-Png($element, [string]$path) {
        $element.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        $element.Arrange([System.Windows.Rect]::new([System.Windows.Point]::new(0, 0), $element.DesiredSize))
        $element.UpdateLayout()
        $scale = 2.0
        $w = [int][math]::Ceiling($element.ActualWidth * $scale)
        $h = [int][math]::Ceiling($element.ActualHeight * $scale)
        $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap $w, $h, (96 * $scale), (96 * $scale), ([System.Windows.Media.PixelFormats]::Pbgra32)
        $rtb.Render($element)
        $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
        $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
        $fs = [IO.File]::Create($path)
        try { $enc.Save($fs) } finally { $fs.Dispose() }
    }

    function Export-Samples {
        $sample = ([IO.File]::ReadAllText($RenderSamples, $Utf8) | ConvertFrom-Json).$Lang
        New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
        # Render the card outside the window: transparent background, shadow included
        $card = $win.Content
        $win.Content = $null
        $frame = New-Object System.Windows.Controls.Grid
        [void]$frame.Children.Add($card)
        $now = Get-NowMs

        Show-Idle
        Save-Png $frame (Join-Path $OutDir 'idle.png')

        $p = $sample.permission
        $p | Add-Member -NotePropertyName id -NotePropertyValue 'sample-permission' -Force
        $p | Add-Member -NotePropertyName kind -NotePropertyValue 'permission' -Force
        $p | Add-Member -NotePropertyName created -NotePropertyValue ($now - 23000) -Force
        $p | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $p 2
        Save-Png $frame (Join-Path $OutDir 'permission.png')

        $q = $sample.question
        $q | Add-Member -NotePropertyName id -NotePropertyValue 'sample-question' -Force
        $q | Add-Member -NotePropertyName kind -NotePropertyValue 'question' -Force
        $q | Add-Member -NotePropertyName created -NotePropertyValue ($now - 41000) -Force
        $q | Add-Member -NotePropertyName timeout -NotePropertyValue 300 -Force
        Show-Request $q 1
        $sel = @($q.selected)
        for ($i = 0; $i -lt $script:qState.Count -and $i -lt $sel.Count; $i++) {
            foreach ($label in @($sel[$i])) { [void]$script:qState[$i].selected.Add([string]$label) }
        }
        Update-QVisuals
        Save-Png $frame (Join-Path $OutDir 'question.png')

        $d = $sample.done
        $d | Add-Member -NotePropertyName key -NotePropertyValue 'sample-done' -Force
        $d | Add-Member -NotePropertyName created -NotePropertyValue ($now - 2 * 60000) -Force
        Show-Done $d 1
        Save-Png $frame (Join-Path $OutDir 'done.png')
    }

    if ($RenderMode) { Export-Samples; return }

    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(400)
    $script:ticks = 0
    $timer.Add_Tick({
        try { if ($tray) { Sync-Dnd } } catch { Write-Log $_ }
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
    $win.Add_Closed({
        $timer.Stop()
        if ($tray) { $tray.Visible = $false; $tray.Dispose() }
    })
    $timer.Start()

    # Application.Run (not ShowDialog) honors ShowActivated=False: no focus stealing on start
    $app = New-Object System.Windows.Application
    [void]$app.Run($win)
}
catch {
    if ($RenderMode) { throw }
    Write-Log $_
}
finally {
    if ($tray) { try { $tray.Visible = $false; $tray.Dispose() } catch {} }
    if ($mutex) {
        try { $mutex.ReleaseMutex() } catch {}
        $mutex.Dispose()
    }
}
