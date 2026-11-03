# チェック、登録順の決定、登録、ログ、一覧表示と確認プロンプト

#region チェック

function ConvertTo-RmDate {
    param([string]$Text)
    $formats = [string[]]@('yyyy-MM-dd', 'yyyy/MM/dd', 'yyyy-M-d', 'yyyy/M/d')
    $date = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, $formats, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$date)) {
        return $date
    }
    $null
}

# 半角数字だけの正の整数（int に収まるもの）なら [int]、それ以外は $null
function ConvertTo-RmPositiveInt {
    param([string]$Text)
    $value = 0
    if ($Text -cmatch '^[0-9]+$' -and [int]::TryParse($Text, [ref]$value) -and $value -gt 0) { return $value }
    $null
}

function Resolve-RmProject {
    param([hashtable]$Metadata, [string]$Text)
    $byIdentifier = @($Metadata.projects | Where-Object { $_.identifier -ceq $Text })
    if ($byIdentifier.Count -gt 0) { return @{ Project = $byIdentifier[0] } }
    $byName = @($Metadata.projects | Where-Object { $_.name -ceq $Text })
    if ($byName.Count -eq 0) { return @{ Kind = 'NotFound'; Message = "プロジェクトが見つかりません: $Text" } }
    if ($byName.Count -gt 1) { return @{ Kind = 'Invalid'; Message = "プロジェクト名が複数に一致します。識別子で指定してください: $Text" } }
    @{ Project = $byName[0] }
}

function Test-RmRows {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][hashtable]$Metadata,
        [object[]]$Rows = @()
    )
    $errors = New-Object System.Collections.ArrayList
    $rowErrors = @{}
    $addError = {
        param($RowNumber, $Kind, $Message)
        [void]$errors.Add([pscustomobject]@{ RowNumber = $RowNumber; Kind = $Kind; Message = $Message })
        $rowErrors[$RowNumber] = $true
    }

    # 仮IDの解析（重複は2つ目以降の行をエラーにする）
    $tempIds = @{}       # RowNumber -> [int] 仮ID
    $tempIdOwner = @{}   # [int] 仮ID -> RowNumber
    foreach ($row in $Rows) {
        if ($row.TempId -eq '') { continue }
        $id = ConvertTo-RmPositiveInt $row.TempId
        if ($null -eq $id) {
            & $addError $row.RowNumber 'Invalid' "仮IDは正の整数で指定してください: $($row.TempId)"
            continue
        }
        if ($tempIdOwner.ContainsKey($id)) {
            & $addError $row.RowNumber 'Invalid' "仮IDが重複しています: $($row.TempId)"
            continue
        }
        $tempIdOwner[$id] = $row.RowNumber
        $tempIds[$row.RowNumber] = $id
    }

    # 親の仮ID（RowNumber -> [int]）。循環の検出にも使う
    $parentTempIds = @{}
    foreach ($row in $Rows) {
        if ($row.Parent.StartsWith('#', [StringComparison]::Ordinal)) {
            $parentNumber = ConvertTo-RmPositiveInt $row.Parent.Substring(1)
            if ($null -ne $parentNumber -and $tempIdOwner.ContainsKey($parentNumber)) { $parentTempIds[$row.RowNumber] = $parentNumber }
        }
    }
    $parentOfTempId = @{}
    foreach ($rowNumber in $tempIds.Keys) {
        if ($parentTempIds.ContainsKey($rowNumber)) { $parentOfTempId[$tempIds[$rowNumber]] = $parentTempIds[$rowNumber] }
    }

    $issueExists = @{}
    $items = @()
    $required = [ordered]@{ Project = 'プロジェクト'; Tracker = 'トラッカー'; Subject = '題名'; StartDate = '開始日'; DueDate = '期日'; Version = '対象バージョン' }

    foreach ($row in $Rows) {
        $n = $row.RowNumber
        foreach ($prop in $required.Keys) {
            if ($row.$prop -eq '') { & $addError $n 'Invalid' "$($required[$prop])が空です" }
        }

        # プロジェクト・tracker・バージョン
        $project = $null; $tracker = $null; $version = $null
        if ($row.Project -ne '') {
            $resolved = Resolve-RmProject -Metadata $Metadata -Text $row.Project
            if ($resolved.Project) {
                $project = $resolved.Project
                if ([int]$project.status -ne 1) {
                    & $addError $n 'Invalid' "プロジェクトが終了しています: $($row.Project)"
                    $project = $null
                }
            } else {
                & $addError $n $resolved.Kind $resolved.Message
            }
        }
        if ($project) {
            $detail = Get-RmProjectDetail -Root $Root -Metadata $Metadata -ProjectId $project.id
            if ($row.Tracker -ne '') {
                $tracker = @($detail.trackers | Where-Object { $_.name -ceq $row.Tracker }) | Select-Object -First 1
                if (-not $tracker) { & $addError $n 'NotFound' "トラッカーがプロジェクトで使えません: $($row.Tracker)" }
            }
            if ($row.Version -ne '') {
                $version = @($detail.versions | Where-Object { $_.name -ceq $row.Version }) | Select-Object -First 1
                if (-not $version) {
                    & $addError $n 'NotFound' "対象バージョンが見つかりません: $($row.Version)"
                } elseif ($version.status -ne 'open') {
                    & $addError $n 'Invalid' "対象バージョンが終了またはロックされています: $($row.Version)"
                }
            }
        }

        # 日付
        $start = $null; $due = $null
        if ($row.StartDate -ne '') {
            $start = ConvertTo-RmDate $row.StartDate
            if (-not $start) { & $addError $n 'Invalid' "開始日の形式が正しくありません: $($row.StartDate)" }
        }
        if ($row.DueDate -ne '') {
            $due = ConvertTo-RmDate $row.DueDate
            if (-not $due) { & $addError $n 'Invalid' "期日の形式が正しくありません: $($row.DueDate)" }
        }
        if ($start -and $due -and $due -lt $start) { & $addError $n 'Invalid' '期日が開始日より前です' }

        # 親チケット
        $parentTempId = $null; $parentIssueId = $null
        $existingParent = ConvertTo-RmPositiveInt $row.Parent
        if ($row.Parent.StartsWith('#', [StringComparison]::Ordinal) -and $null -ne (ConvertTo-RmPositiveInt $row.Parent.Substring(1))) {
            if ($parentTempIds.ContainsKey($n)) {
                $parentTempId = $parentTempIds[$n]
                # 自分の仮IDから親をたどって自分に戻れば循環
                if ($tempIds.ContainsKey($n)) {
                    $self = $tempIds[$n]
                    $current = $parentTempId
                    $steps = 0
                    while ($null -ne $current -and $steps -le $Rows.Count) {
                        if ($current -eq $self) { & $addError $n 'Invalid' "親子関係が循環しています: $($row.Parent)"; break }
                        $current = if ($parentOfTempId.ContainsKey($current)) { $parentOfTempId[$current] } else { $null }
                        $steps++
                    }
                }
            } else {
                & $addError $n 'Invalid' "親チケットの仮IDが見つかりません: $($row.Parent)"
            }
        } elseif ($null -ne $existingParent) {
            $parentIssueId = $existingParent
            if (-not $issueExists.ContainsKey($parentIssueId)) { $issueExists[$parentIssueId] = Test-RmIssueExists -IssueId $parentIssueId }
            if (-not $issueExists[$parentIssueId]) { & $addError $n 'Invalid' "親チケットが存在しません: $($row.Parent)" }
        } elseif ($row.Parent -ne '') {
            & $addError $n 'Invalid' "親チケットの書き方が正しくありません（例: 123 または #1）: $($row.Parent)"
        }

        if ($rowErrors.ContainsKey($n)) { continue }
        $items += [pscustomobject]@{
            RowNumber     = $n
            TempId        = if ($tempIds.ContainsKey($n)) { $tempIds[$n] } else { $null }
            ProjectId     = [int]$project.id
            TrackerId     = [int]$tracker.id
            VersionId     = [int]$version.id
            Subject       = $row.Subject
            Description   = $row.Description
            StartDate     = $start.ToString('yyyy-MM-dd')
            DueDate       = $due.ToString('yyyy-MM-dd')
            ParentIssueId = $parentIssueId
            ParentTempId  = $parentTempId
            ProjectName   = $row.Project
            TrackerName   = $row.Tracker
            VersionName   = $row.Version
            ParentText    = $row.Parent
        }
    }

    # 行番号順に並べる（同じ行の中では見つけた順を保つ）
    @{ Items = $items; Errors = @($errors | Sort-Object { $_.RowNumber }, { $errors.IndexOf($_) }) }
}

#endregion

#region 登録

# 親（ParentTempId の行）が必ず子より前に来るように並べる。その範囲でファイルの順番を保つ
function Get-RmRegistrationOrder {
    param([object[]]$Items = @())
    $fileTempIds = @{}
    foreach ($item in $Items) { if ($null -ne $item.TempId) { $fileTempIds[[int]$item.TempId] = $true } }

    $placedTempIds = @{}
    $remaining = New-Object System.Collections.ArrayList (, $Items)
    $ordered = @()
    while ($remaining.Count -gt 0) {
        $next = $null
        foreach ($item in $remaining) {
            $parent = $item.ParentTempId
            if ($null -eq $parent -or -not $fileTempIds.ContainsKey([int]$parent) -or $placedTempIds.ContainsKey([int]$parent)) {
                $next = $item
                break
            }
        }
        # チェックで循環は除いているが、念のため並べられない行が残ったら残りをそのまま並べる
        if ($null -eq $next) { $ordered += @($remaining); break }
        $ordered += $next
        if ($null -ne $next.TempId) { $placedTempIds[[int]$next.TempId] = $true }
        $remaining.Remove($next)
    }
    $ordered
}

function Invoke-RmRegistration {
    param([object[]]$Items = @(), $Log)
    $issueIdByTempId = @{}   # 登録に成功した仮ID -> チケット番号
    $results = @()
    $aborted = $false        # 認証・接続のエラーが起きたら、残りは試さずにスキップする
    $ordered = @(Get-RmRegistrationOrder -Items $Items)
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        $item = $ordered[$i]
        Show-RmProgress -Done $i -Total $ordered.Count -Subject $item.Subject
        $result = [pscustomobject]@{
            RowNumber = $item.RowNumber; TempId = $item.TempId; Subject = $item.Subject
            Status = $null; IssueId = $null; Message = ''
        }
        $parentIssueId = $item.ParentIssueId
        if ($aborted) {
            $result.Status = 'Skipped'
            $result.Message = '認証または接続のエラーで登録を中止したため'
        } elseif ($null -ne $item.ParentTempId) {
            if ($issueIdByTempId.ContainsKey([int]$item.ParentTempId)) {
                $parentIssueId = $issueIdByTempId[[int]$item.ParentTempId]
            } else {
                $result.Status = 'Skipped'
                $result.Message = "親（仮ID$($item.ParentTempId)）が登録されなかったため"
            }
        }
        if (-not $result.Status) {
            try {
                $result.IssueId = New-RmIssue -Fields @{
                    project_id       = $item.ProjectId
                    tracker_id       = $item.TrackerId
                    subject          = $item.Subject
                    description      = $item.Description
                    start_date       = $item.StartDate
                    due_date         = $item.DueDate
                    fixed_version_id = $item.VersionId
                    parent_issue_id  = $parentIssueId
                }
                $result.Status = 'Success'
                if ($null -ne $item.TempId) { $issueIdByTempId[[int]$item.TempId] = $result.IssueId }
            } catch {
                $result.Status = 'Error'
                $result.Message = $_.Exception.Message
                if ($result.Message -like '認証に失敗しました*' -or $result.Message -like 'Redmine に接続できません*') { $aborted = $true }
            }
        }
        if ($Log) { Write-RmLogResult -Log $Log -Result $result }
        $results += $result
    }
    Clear-RmProgress
    @($results | Sort-Object { $_.RowNumber })
}

#endregion

#region ログ

function New-RmLog {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$InputPath)
    $dir = (Get-RmPaths -Root $Root).LogDir
    $stamp = (Get-Date).ToString('yyyyMMdd_HHmmss')
    $path = Join-Path $dir "rmbulk_$stamp.log"
    # 同じ秒に実行されたときは前のログを上書きしないよう連番を付ける
    for ($i = 2; Test-Path -LiteralPath $path; $i++) { $path = Join-Path $dir "rmbulk_${stamp}_$i.log" }
    Write-RmTextFile -Path $path -Text ''
    $log = @{ Path = $path }
    Write-RmLog -Log $log -Message "入力ファイル: $InputPath"
    $log
}

function Write-RmLog {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)][string]$Message)
    $line = '{0} {1}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
    [IO.File]::AppendAllText($Log.Path, $line, (New-Object Text.UTF8Encoding $false))
}

function Write-RmLogResult {
    param([Parameter(Mandatory)]$Log, [Parameter(Mandatory)]$Result)
    $tempId = if ($null -ne $Result.TempId) { $Result.TempId } else { '-' }
    $head = "行$($Result.RowNumber) 仮ID$tempId"
    $message = switch ($Result.Status) {
        'Success' { "[成功] $head チケット#$($Result.IssueId) $($Result.Subject)" }
        'Error' { "[エラー] $head $($Result.Subject): $($Result.Message)" }
        'Skipped' { "[スキップ] $head $($Result.Subject): $($Result.Message)" }
    }
    Write-RmLog -Log $Log -Message $message
}

function Get-RmSummaryText {
    param([object[]]$Results = @())
    $count = { param($status) @($Results | Where-Object { $_.Status -eq $status }).Count }
    '成功 {0}件 / エラー {1}件 / スキップ {2}件' -f (& $count 'Success'), (& $count 'Error'), (& $count 'Skipped')
}

function Write-RmLogSummary {
    param([Parameter(Mandatory)]$Log, [object[]]$Results = @())
    Write-RmLog -Log $Log -Message (Get-RmSummaryText -Results $Results)
}

#endregion

#region 表示

# 全角は 2 桁、半角（半角カナを含む）は 1 桁として数える
function Get-RmDisplayWidth {
    param([AllowEmptyString()][string]$Text)
    $width = 0
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 0x1100 -or ($code -ge 0xFF61 -and $code -le 0xFF9F)) { $width += 1 } else { $width += 2 }
    }
    $width
}

# 表示幅が $Width を超えるときは末尾を ... にして収める（… は全角になる環境があるため使わない）
function Limit-RmDisplayWidth {
    param([AllowEmptyString()][string]$Text, [int]$Width)
    if ((Get-RmDisplayWidth $Text) -le $Width) { return $Text }
    $budget = [Math]::Max(0, $Width - 3)
    $sb = New-Object Text.StringBuilder
    $used = 0
    foreach ($ch in $Text.ToCharArray()) {
        $w = Get-RmDisplayWidth ([string]$ch)
        if ($used + $w -gt $budget) { break }
        [void]$sb.Append($ch)
        $used += $w
    }
    $sb.ToString() + '...'
}

function Get-RmConsoleWidth {
    $width = 0
    try { $width = [Console]::WindowWidth } catch { }
    if ($width -le 0) { $width = 120 }
    $width
}

$script:RmPreviewColumns = [ordered]@{
    '仮ID'           = 'TempId'
    'プロジェクト'   = 'Project'
    'トラッカー'     = 'Tracker'
    '題名'           = 'Subject'
    '開始日'         = 'StartDate'
    '期日'           = 'DueDate'
    '対象バージョン' = 'Version'
    '親チケット'     = 'Parent'
}

# 一覧の行（Text と IsError）を返す。エラーのある行のすぐ下に理由の行を入れる。
# $Width を超える場合は題名の列を縮めて、右側の列が切れないようにする
function Get-RmPreviewLines {
    param([object[]]$Rows = @(), $Check, [int]$Width)
    $gap = '  '
    $names = @($script:RmPreviewColumns.Keys)
    $subjectIndex = [array]::IndexOf($names, '題名')

    $widths = @($names | ForEach-Object { Get-RmDisplayWidth $_ })
    foreach ($row in $Rows) {
        for ($c = 0; $c -lt $names.Count; $c++) {
            $w = Get-RmDisplayWidth ([string]$row.($script:RmPreviewColumns[$names[$c]]))
            if ($w -gt $widths[$c]) { $widths[$c] = $w }
        }
    }
    $total = ($widths | Measure-Object -Sum).Sum + $gap.Length * ($names.Count - 1)
    $over = $total - ($Width - 1)
    if ($over -gt 0) { $widths[$subjectIndex] = [Math]::Max((Get-RmDisplayWidth '題名'), $widths[$subjectIndex] - $over) }

    $format = {
        param([string[]]$Values)
        $cells = for ($c = 0; $c -lt $Values.Count; $c++) {
            $text = Limit-RmDisplayWidth -Text $Values[$c] -Width $widths[$c]
            $text + (' ' * ($widths[$c] - (Get-RmDisplayWidth $text)))
        }
        ($cells -join $gap).TrimEnd()
    }
    $line = { param([string]$Text, [bool]$IsError) [pscustomobject]@{ Text = $Text; IsError = $IsError } }

    $messages = @{}
    foreach ($err in @($Check.Errors)) {
        if (-not $messages.ContainsKey($err.RowNumber)) { $messages[$err.RowNumber] = @() }
        $messages[$err.RowNumber] += $err.Message
    }

    & $line (& $format $names) $false
    & $line (& $format @($widths | ForEach-Object { '-' * $_ })) $false
    foreach ($row in $Rows) {
        $values = @($names | ForEach-Object { [string]$row.($script:RmPreviewColumns[$_]) })
        $isError = $messages.ContainsKey($row.RowNumber)
        & $line (& $format $values) $isError
        if ($isError) { foreach ($message in $messages[$row.RowNumber]) { & $line "    └ $message" $true } }
    }
}

function Show-RmPreview {
    param([object[]]$Rows = @(), $Check)
    Write-Host ''
    foreach ($line in Get-RmPreviewLines -Rows $Rows -Check $Check -Width (Get-RmConsoleWidth)) {
        if ($line.IsError) { Write-Host $line.Text -ForegroundColor Red } else { Write-Host $line.Text }
    }
    Write-Host ''
}

function Test-RmInteractiveOutput {
    -not [Console]::IsOutputRedirected
}

# 進捗の行（例: 登録中 [##########..........]  5/10  題名）。$Width - 1 に収める
function Format-RmProgressLine {
    param([int]$Done, [int]$Total, [AllowEmptyString()][string]$Subject, [int]$Width)
    $barWidth = 20
    $filled = if ($Total -gt 0) { [int][Math]::Floor($barWidth * $Done / $Total) } else { 0 }
    $head = '登録中 [' + ('#' * $filled) + ('.' * ($barWidth - $filled)) + ']  ' + "$Done/$Total" + '  '
    $head + (Limit-RmDisplayWidth -Text $Subject -Width ($Width - 1 - (Get-RmDisplayWidth $head)))
}

# 進捗を同じ行に上書きする。Write-Progress は 5.1 で画面上部に大きな帯が出るため使わない
function Show-RmProgress {
    param([int]$Done, [int]$Total, [AllowEmptyString()][string]$Subject)
    if (-not (Test-RmInteractiveOutput)) { return }
    $width = Get-RmConsoleWidth
    $text = Format-RmProgressLine -Done $Done -Total $Total -Subject $Subject -Width $width
    Write-Host ("`r" + $text + (' ' * [Math]::Max(0, $width - 1 - (Get-RmDisplayWidth $text)))) -NoNewline
}

function Clear-RmProgress {
    if (-not (Test-RmInteractiveOutput)) { return }
    Write-Host ("`r" + (' ' * ((Get-RmConsoleWidth) - 1)) + "`r") -NoNewline
}

# 登録が終わったあと、エラーとスキップの行だけを表示する
function Show-RmFailures {
    param([object[]]$Results = @())
    foreach ($result in $Results) {
        $label = switch ($result.Status) { 'Error' { 'エラー' } 'Skipped' { 'スキップ' } default { $null } }
        if ($label) { Write-Host "$label $($result.Subject): $($result.Message)" -ForegroundColor Red }
    }
}

function Read-RmConfirmation {
    (Read-Host '登録しますか？(y/n)') -eq 'y'
}

#endregion
