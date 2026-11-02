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

    # 仮番号の解析（重複は2つ目以降の行をエラーにする）
    $tempIds = @{}       # RowNumber -> [int] 仮番号
    $tempIdOwner = @{}   # [int] 仮番号 -> RowNumber
    foreach ($row in $Rows) {
        if ($row.TempId -eq '') { continue }
        if ($row.TempId -notmatch '^\d+$' -or [long]$row.TempId -le 0 -or [long]$row.TempId -gt [int]::MaxValue) {
            & $addError $row.RowNumber 'Invalid' "仮番号は正の整数で指定してください: $($row.TempId)"
            continue
        }
        $id = [int]$row.TempId
        if ($tempIdOwner.ContainsKey($id)) {
            & $addError $row.RowNumber 'Invalid' "仮番号が重複しています: $($row.TempId)"
            continue
        }
        $tempIdOwner[$id] = $row.RowNumber
        $tempIds[$row.RowNumber] = $id
    }

    # 親の仮番号（RowNumber -> [int]）。循環の検出にも使う
    $parentTempIds = @{}
    foreach ($row in $Rows) {
        if ($row.Parent -match '^#(\d+)$' -and $tempIdOwner.ContainsKey([int]$Matches[1])) {
            $parentTempIds[$row.RowNumber] = [int]$Matches[1]
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
        if ($row.Parent -match '^#(\d+)$') {
            if ($parentTempIds.ContainsKey($n)) {
                $parentTempId = $parentTempIds[$n]
                # 自分の仮番号から親をたどって自分に戻れば循環
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
                & $addError $n 'Invalid' "親チケットの仮番号が見つかりません: $($row.Parent)"
            }
        } elseif ($row.Parent -match '^\d+$') {
            $parentIssueId = [int]$row.Parent
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
