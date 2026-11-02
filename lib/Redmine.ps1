# 設定（URL・API キー）の保存と読み込み、Redmine API の呼び出し、メタデータ

#region Config

function Get-RmPaths {
    param([Parameter(Mandatory)][string]$Root)
    @{
        Config   = Join-Path $Root 'config.json'
        ApiKey   = Join-Path $Root 'apikey.dat'
        Metadata = Join-Path $Root 'metadata.json'
        LogDir   = Join-Path $Root 'logs'
    }
}

function Write-RmTextFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $true))
}

function Save-RmConfig {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$BaseUrl)
    $json = @{ baseUrl = $BaseUrl.Trim().TrimEnd('/') } | ConvertTo-Json
    Write-RmTextFile -Path (Get-RmPaths -Root $Root).Config -Text $json
}

function Read-RmConfig {
    param([Parameter(Mandatory)][string]$Root)
    $path = (Get-RmPaths -Root $Root).Config
    if (-not (Test-Path $path)) { throw '設定がありません。rmbulk setup を実行してください。' }
    $data = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    @{ BaseUrl = [string]$data.baseUrl }
}

function Save-RmApiKey {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][securestring]$ApiKey)
    Write-RmTextFile -Path (Get-RmPaths -Root $Root).ApiKey -Text (ConvertFrom-SecureString $ApiKey)
}

function Read-RmApiKey {
    param([Parameter(Mandatory)][string]$Root)
    $message = 'API キーを読み込めません。rmbulk setup を実行してください。'
    $path = (Get-RmPaths -Root $Root).ApiKey
    if (-not (Test-Path $path)) { throw $message }
    try {
        $secure = ConvertTo-SecureString ([IO.File]::ReadAllText($path).Trim())
    } catch {
        throw $message
    }
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

#endregion
