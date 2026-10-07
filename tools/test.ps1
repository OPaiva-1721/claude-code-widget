# Runs the automated tests in tests\ with Pester 5, on Windows PowerShell 5.1 (the plugin's runtime).
#   powershell -NoProfile -File tools\test.ps1                      all tests, detailed output
#   powershell -NoProfile -File tools\test.ps1 -CI                  also writes testResults.xml (GitHub Actions)
#   powershell -NoProfile -File tools\test.ps1 -ExcludeTag Desktop  skips the tests that open widget windows
# Exits with a non-zero code when a test fails.
param([switch]$CI, [string[]]$ExcludeTag = @())
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot

if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5.0' })) {
    Write-Host 'Pester 5.5 or later is required. Install it once with:'
    Write-Host '  Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -Force -SkipPublisherCheck'
    exit 1
}
Import-Module Pester -MinimumVersion 5.5.0

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $repo 'tests'
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = Join-Path $repo 'testResults.xml'
}
Invoke-Pester -Configuration $config
