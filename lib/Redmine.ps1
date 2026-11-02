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

#region API

$script:RmConnection = $null

function Set-RmConnection {
    param([Parameter(Mandatory)][string]$BaseUrl, [Parameter(Mandatory)][string]$ApiKey)
    # Windows PowerShell 5.1 は既定で TLS 1.2 を使わないことがある
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:RmConnection = @{ BaseUrl = $BaseUrl.TrimEnd('/'); ApiKey = $ApiKey }
}

function Get-RmHttpError {
    param([Parameter(Mandatory)][Management.Automation.ErrorRecord]$ErrorRecord)
    $status = $null
    $response = $ErrorRecord.Exception.Response
    if ($null -ne $response -and $null -ne $response.StatusCode) { $status = [int]$response.StatusCode }
    $body = ''
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    @{ StatusCode = $status; Body = $body; Message = $ErrorRecord.Exception.Message }
}

function Invoke-RmApi {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body,
        # 404 のときに throw せず $null を返す
        [switch]$NotFoundAsNull
    )
    if (-not $script:RmConnection) { throw '接続情報が設定されていません。' }
    $params = @{
        Uri         = $script:RmConnection.BaseUrl + $Path
        Method      = $Method
        Headers     = @{ 'X-Redmine-API-Key' = $script:RmConnection.ApiKey }
        ErrorAction = 'Stop'
    }
    if ($Body) {
        $params.ContentType = 'application/json; charset=utf-8'
        $params.Body = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 5 -Compress))
    }
    try {
        Invoke-RestMethod @params
    } catch {
        $err = Get-RmHttpError -ErrorRecord $_
        if ($null -eq $err.StatusCode) { throw "Redmine に接続できません: $($err.Message)" }
        if ($err.StatusCode -eq 404 -and $NotFoundAsNull) { return $null }
        if ($err.StatusCode -eq 401) { throw '認証に失敗しました（HTTP 401）。API キーが無効です。rmbulk setup を実行し直してください。' }
        if ($err.StatusCode -eq 422) {
            $messages = $null
            try { $messages = ($err.Body | ConvertFrom-Json).errors } catch { }
            if ($messages) { throw "HTTP 422: $(@($messages) -join '; ')" }
        }
        $detail = if ($err.Body) { $err.Body } else { $err.Message }
        throw "HTTP $($err.StatusCode): $detail"
    }
}

function Get-RmCurrentUser {
    (Invoke-RmApi -Method Get -Path '/users/current.json').user
}

function Get-RmProjects {
    $all = @()
    $offset = 0
    do {
        $page = Invoke-RmApi -Method Get -Path "/projects.json?limit=100&offset=$offset"
        $items = @($page.projects)
        $all += $items | ForEach-Object {
            [pscustomobject]@{ id = [int]$_.id; name = [string]$_.name; identifier = [string]$_.identifier; status = [int]$_.status }
        }
        $offset += 100
    } while ($items.Count -gt 0 -and $offset -lt [int]$page.total_count)
    $all
}

function Get-RmProjectTrackers {
    param([Parameter(Mandatory)][int]$ProjectId)
    $project = (Invoke-RmApi -Method Get -Path "/projects/$ProjectId.json?include=trackers").project
    @(@($project.trackers) | ForEach-Object { [pscustomobject]@{ id = [int]$_.id; name = [string]$_.name } })
}

function Get-RmProjectVersions {
    param([Parameter(Mandatory)][int]$ProjectId)
    $versions = (Invoke-RmApi -Method Get -Path "/projects/$ProjectId/versions.json").versions
    @(@($versions) | ForEach-Object { [pscustomobject]@{ id = [int]$_.id; name = [string]$_.name; status = [string]$_.status } })
}

function Test-RmIssueExists {
    param([Parameter(Mandatory)][int]$IssueId)
    $null -ne (Invoke-RmApi -Method Get -Path "/issues/$IssueId.json" -NotFoundAsNull)
}

function New-RmIssue {
    param([Parameter(Mandatory)][hashtable]$Fields)
    $issue = @{}
    foreach ($key in $Fields.Keys) {
        $value = $Fields[$key]
        if ($null -ne $value -and "$value" -ne '') { $issue[$key] = $value }
    }
    [int](Invoke-RmApi -Method Post -Path '/issues.json' -Body @{ issue = $issue }).issue.id
}

#endregion

#region Metadata

function Read-RmMetadata {
    param([Parameter(Mandatory)][string]$Root)
    $metadata = @{ fetchedAt = $null; projects = @(); projectDetails = @{} }
    $path = (Get-RmPaths -Root $Root).Metadata
    if (-not (Test-Path $path)) { return $metadata }

    $data = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $metadata.fetchedAt = $data.fetchedAt
    $metadata.projects = @($data.projects | Where-Object { $null -ne $_ })
    # ConvertFrom-Json は PSCustomObject を返すので、プロジェクト ID をキーとする hashtable に直す
    if ($data.projectDetails) {
        foreach ($prop in $data.projectDetails.PSObject.Properties) {
            $metadata.projectDetails[$prop.Name] = @{
                fetchedAt = $prop.Value.fetchedAt
                trackers  = @($prop.Value.trackers | Where-Object { $null -ne $_ })
                versions  = @($prop.Value.versions | Where-Object { $null -ne $_ })
            }
        }
    }
    $metadata
}

function Save-RmMetadata {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Metadata)
    $json = $Metadata | ConvertTo-Json -Depth 6
    Write-RmTextFile -Path (Get-RmPaths -Root $Root).Metadata -Text $json
}

function Update-RmProjectList {
    param([Parameter(Mandatory)][string]$Root)
    $metadata = @{
        fetchedAt      = (Get-Date).ToString('s')
        projects       = @(Get-RmProjects)
        projectDetails = @{}
    }
    Save-RmMetadata -Root $Root -Metadata $metadata
    $metadata
}

function Get-RmProjectDetail {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Metadata, [Parameter(Mandatory)][int]$ProjectId)
    $key = [string]$ProjectId
    if (-not $Metadata.projectDetails.ContainsKey($key)) {
        $Metadata.projectDetails[$key] = @{
            fetchedAt = (Get-Date).ToString('s')
            trackers  = @(Get-RmProjectTrackers -ProjectId $ProjectId)
            versions  = @(Get-RmProjectVersions -ProjectId $ProjectId)
        }
        Save-RmMetadata -Root $Root -Metadata $Metadata
    }
    $Metadata.projectDetails[$key]
}

function Clear-RmProjectDetail {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][hashtable]$Metadata, [Parameter(Mandatory)][int[]]$ProjectId)
    foreach ($id in $ProjectId) { $Metadata.projectDetails.Remove([string]$id) }
    Save-RmMetadata -Root $Root -Metadata $Metadata
}

#endregion
