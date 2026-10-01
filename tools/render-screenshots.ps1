# Renders the widget states shown in the READMEs to docs/images/<lang>/*.png, using the real
# widget code (widget.ps1 -RenderSamples) and the sample data in tools/samples.json.
# Run after changing the widget's look:  powershell -NoProfile -File tools\render-screenshots.ps1
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$widget = Join-Path $repo 'plugins\claude-code-widget\scripts\widget.ps1'
$samples = Join-Path $PSScriptRoot 'samples.json'
foreach ($lang in 'en', 'pt') {
    $out = Join-Path $repo "docs\images\$lang"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $widget -RenderSamples $samples -OutDir $out -Lang $lang
    if ($LASTEXITCODE) { throw "render failed for '$lang'" }
    Get-ChildItem $out -Filter *.png | ForEach-Object { '{0}\{1}' -f $lang, $_.Name }
}
