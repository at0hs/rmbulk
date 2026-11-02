# 単体テスト（または指定したフォルダのテスト）を PowerShell 7 と Windows PowerShell 5.1 の両方で実行する。
param(
    [string]$Path = (Join-Path $PSScriptRoot 'unit')
)

$Path = (Resolve-Path $Path).Path
$failed = @()
foreach ($exe in 'pwsh', 'powershell') {
    Write-Host "=== $exe ===" -ForegroundColor Cyan
    $command = @"
Import-Module Pester -MinimumVersion 5.0
`$c = New-PesterConfiguration
`$c.Run.Path = '$Path'
`$c.Run.Exit = `$true
`$c.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration `$c
"@
    & $exe -NoProfile -ExecutionPolicy Bypass -Command $command
    if ($LASTEXITCODE -ne 0) { $failed += $exe }
}

if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
    exit 1
}
Write-Host 'ALL PASSED (pwsh, powershell)' -ForegroundColor Green
exit 0
