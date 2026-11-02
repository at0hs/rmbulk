# rmbulk: CSV / Excel に書いたチケットを Redmine に一括登録する
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Target
)

foreach ($lib in 'Redmine', 'Input', 'Import') {
    . (Join-Path $PSScriptRoot "lib\$lib.ps1")
}

function Show-RmUsage {
    Write-Host @'
使い方:
  rmbulk setup                  # 接続設定とメタデータの取得
  rmbulk refresh                # メタデータだけを取り直す
  rmbulk template [<出力先>]    # 列名だけが入った CSV のひな形を出力する
  rmbulk import <ファイル>      # CSV / Excel を読み込み、確認したうえで登録する
'@
}

function Write-RmError {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Red
}

function Connect-RmSaved {
    param([Parameter(Mandatory)][string]$Root)
    Set-RmConnection -BaseUrl (Read-RmConfig -Root $Root).BaseUrl -ApiKey (Read-RmApiKey -Root $Root)
}

function Invoke-RmSetup {
    param([Parameter(Mandatory)][string]$Root)
    $current = $null
    try { $current = (Read-RmConfig -Root $Root).BaseUrl } catch { }

    $prompt = if ($current) { "Redmine の URL [$current]" } else { 'Redmine の URL' }
    $url = ([string](Read-Host $prompt)).Trim()
    if ($url -eq '') { $url = $current }
    if (-not $url) {
        Write-RmError 'URL が入力されていません。'
        return $false
    }
    $secureKey = Read-Host 'API キー' -AsSecureString
    $apiKey = if ($secureKey) { ConvertFrom-RmSecureString $secureKey } else { '' }
    if ($apiKey -eq '') {
        Write-RmError 'API キーが入力されていません。'
        return $false
    }

    try {
        Set-RmConnection -BaseUrl $url -ApiKey $apiKey
        $user = Get-RmCurrentUser
    } catch {
        Write-RmError "接続できませんでした。設定は保存していません。`n$($_.Exception.Message)"
        return $false
    }
    Write-Host "接続できました: $($user.login)"

    try {
        Save-RmConfig -Root $Root -BaseUrl $url
        Save-RmApiKey -Root $Root -ApiKey $secureKey
        $metadata = Update-RmProjectList -Root $Root
    } catch {
        Write-RmError "メタデータを取得できませんでした: $($_.Exception.Message)"
        return $false
    }
    Write-Host "プロジェクト $(@($metadata.projects).Count) 件を取得しました"
    $true
}

function Invoke-RmRefresh {
    param([Parameter(Mandatory)][string]$Root)
    try {
        Connect-RmSaved -Root $Root
        $metadata = Update-RmProjectList -Root $Root
    } catch {
        Write-RmError $_.Exception.Message
        return $false
    }
    Write-Host "プロジェクト $(@($metadata.projects).Count) 件を取得しました"
    $true
}

function Invoke-RmTemplate {
    param([string]$OutputPath)
    if (-not $OutputPath) { $OutputPath = 'rmbulk_template.csv' }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
    if (Test-Path -LiteralPath $fullPath) {
        Write-RmError "ファイルが既に存在します: $fullPath"
        return $false
    }
    Write-RmTextFile -Path $fullPath -Text (($script:RmColumns.Keys -join ',') + "`r`n")
    Write-Host "ひな形を出力しました: $fullPath"
    $true
}

function Invoke-RmImport {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path)
    try {
        Connect-RmSaved -Root $Root
        $fullPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $inputData = Read-RmInputFile -Path $fullPath
        foreach ($warning in $inputData.Warnings) { Write-Host $warning -ForegroundColor Yellow }
        $rows = @($inputData.Rows)
        if ($rows.Count -eq 0) {
            Write-Host '登録するチケットがありません。'
            return $true
        }

        $metadata = Read-RmMetadata -Root $Root
        $check = Test-RmRows -Root $Root -Metadata $metadata -Rows $rows
        if (@($check.Errors | Where-Object { $_.Kind -eq 'NotFound' }).Count -gt 0) {
            # 新しく作ったプロジェクトなどに備え、一度だけメタデータを取り直す
            $metadata = Update-RmProjectList -Root $Root
            $check = Test-RmRows -Root $Root -Metadata $metadata -Rows $rows
        }
    } catch {
        Write-RmError $_.Exception.Message
        return $false
    }

    Show-RmPreview -Rows $rows -Check $check
    if (@($check.Errors).Count -gt 0) {
        Write-RmError 'エラーがあるため登録しません。'
        return $false
    }
    if (-not (Read-RmConfirmation)) {
        Write-Host '登録を中止しました。'
        return $true
    }

    $log = New-RmLog -Root $Root -InputPath $fullPath
    $results = Invoke-RmRegistration -Items $check.Items -Log $log
    Write-RmLogSummary -Log $log -Results $results
    Write-Host (Get-RmSummaryText -Results $results)
    Write-Host "ログ: $($log.Path)"
    @($results | Where-Object { $_.Status -ne 'Success' }).Count -eq 0
}

# dot-source されたとき（テスト）は関数の定義だけを読み込む
if ($MyInvocation.InvocationName -eq '.') { return }

$ok = switch ($Command) {
    'setup' { Invoke-RmSetup -Root $PSScriptRoot }
    'refresh' { Invoke-RmRefresh -Root $PSScriptRoot }
    'template' { Invoke-RmTemplate -OutputPath $Target }
    'import' {
        if (-not $Target) { Show-RmUsage; $false }
        else { Invoke-RmImport -Root $PSScriptRoot -Path $Target }
    }
    default { Show-RmUsage; $false }
}
if (-not $ok) { exit 1 }
exit 0
