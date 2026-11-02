# 結合テスト用の Redmine を Docker で起動し、テスト用データを作る。
# 標準出力の最終行に管理者の API キーを出す。
$ErrorActionPreference = 'Stop'
$compose = Join-Path $PSScriptRoot 'docker-compose.yml'
$baseUrl = 'http://127.0.0.1:3030'

docker compose -f $compose up -d | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'docker compose up に失敗しました。' }

$deadline = (Get-Date).AddMinutes(10)
while ($true) {
    try {
        Invoke-WebRequest -Uri "$baseUrl/" -UseBasicParsing -TimeoutSec 5 | Out-Null
        break
    } catch {
        if ((Get-Date) -gt $deadline) { throw "Redmine が起動しませんでした: $baseUrl" }
        Start-Sleep -Seconds 3
    }
}

$output = docker compose -f $compose exec -T redmine bundle exec rails runner /rmbulk-seed/seed.rb
if ($LASTEXITCODE -ne 0) { throw "テスト用データの作成に失敗しました: $output" }
$key = @($output | Where-Object { $_ -match '^APIKEY=' }) | Select-Object -Last 1
if (-not $key) { throw "API キーを取得できませんでした: $output" }
$key -replace '^APIKEY=', ''
