BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\lib\Redmine.ps1')
    . (Join-Path $PSScriptRoot '..\..\lib\Import.ps1')

    function New-Row {
        param([int]$RowNumber = 2, [hashtable]$Values = @{})
        $row = [ordered]@{
            RowNumber = $RowNumber; TempId = ''; Project = 'WBS'; Tracker = 'タスク'; Subject = '設計'; Description = ''
            StartDate = '2026-11-04'; DueDate = '2026-11-05'; Version = 'v1.0'; Parent = ''
        }
        foreach ($k in $Values.Keys) { $row[$k] = $Values[$k] }
        [pscustomobject]$row
    }

    function New-TestMetadata {
        @{
            fetchedAt      = 'x'
            projects       = @(
                [pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 }
                [pscustomobject]@{ id = 2; name = '終了済み'; identifier = 'closed'; status = 5 }
                [pscustomobject]@{ id = 3; name = '重複'; identifier = 'dup-a'; status = 1 }
                [pscustomobject]@{ id = 4; name = '重複'; identifier = 'dup-b'; status = 1 }
            )
            projectDetails = @{}
        }
    }

    function Get-Messages {
        param($Result, [int]$RowNumber)
        @($Result.Errors | Where-Object { $_.RowNumber -eq $RowNumber } | ForEach-Object { $_.Message })
    }
}

Describe 'Test-RmRows' {
    BeforeEach {
        Mock Get-RmProjectDetail {
            @{
                trackers = @([pscustomobject]@{ id = 2; name = 'タスク' })
                versions = @(
                    [pscustomobject]@{ id = 5; name = 'v1.0'; status = 'open' }
                    [pscustomobject]@{ id = 6; name = 'old'; status = 'closed' }
                    [pscustomobject]@{ id = 7; name = 'lock'; status = 'locked' }
                )
            }
        }
        Mock Test-RmIssueExists { $IssueId -eq 123 }
        $script:m = New-TestMetadata
    }

    It '正しい行は ID に解決される' {
        $rows = @(
            New-Row -RowNumber 2 -Values @{ TempId = '1'; StartDate = '2026/11/04' }
            New-Row -RowNumber 3 -Values @{ TempId = '2'; Parent = '#1' }
            New-Row -RowNumber 4 -Values @{ Parent = '123'; Description = '説明' }
        )
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows $rows
        @($r.Errors).Count | Should -Be 0
        @($r.Items).Count | Should -Be 3
        $i = $r.Items[0]
        $i.ProjectId | Should -Be 1
        $i.TrackerId | Should -Be 2
        $i.VersionId | Should -Be 5
        $i.StartDate | Should -Be '2026-11-04'
        $i.TempId | Should -Be 1
        $i.ParentTempId | Should -BeNullOrEmpty
        $r.Items[1].ParentTempId | Should -Be 1
        $r.Items[1].ParentIssueId | Should -BeNullOrEmpty
        $r.Items[2].ParentIssueId | Should -Be 123
        $r.Items[2].TempId | Should -BeNullOrEmpty
        $r.Items[2].Description | Should -Be '説明'
        $r.Items[2].ProjectName | Should -Be 'WBS'
        $r.Items[2].TrackerName | Should -Be 'タスク'
        $r.Items[2].VersionName | Should -Be 'v1.0'
        $r.Items[2].ParentText | Should -Be '123'
    }

    It '識別子でもプロジェクトを指定でき、識別子の一致を優先する' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Project = 'dup-b' })
        $r.Items[0].ProjectId | Should -Be 4
    }

    It '月日が1桁の日付も受け付ける' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ StartDate = '2026/1/5'; DueDate = '2026-1-6' })
        $r.Items[0].StartDate | Should -Be '2026-01-05'
        $r.Items[0].DueDate | Should -Be '2026-01-06'
    }

    It '必須項目が空' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Subject = ''; Version = '' })
        Get-Messages $r 2 | Should -Contain '題名が空です'
        Get-Messages $r 2 | Should -Contain '対象バージョンが空です'
        @($r.Items).Count | Should -Be 0
    }

    It 'プロジェクトが見つからない（NotFound）' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Project = 'なし' })
        Get-Messages $r 2 | Should -Contain 'プロジェクトが見つかりません: なし'
        ($r.Errors | Where-Object { $_.Message -like 'プロジェクトが見つかりません*' }).Kind | Should -Be 'NotFound'
    }

    It 'プロジェクト名が複数に一致' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Project = '重複' })
        Get-Messages $r 2 | Should -Contain 'プロジェクト名が複数に一致します。識別子で指定してください: 重複'
    }

    It 'プロジェクトが終了している' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Project = '終了済み' })
        Get-Messages $r 2 | Should -Contain 'プロジェクトが終了しています: 終了済み'
        ($r.Errors | Select-Object -First 1).Kind | Should -Be 'Invalid'
    }

    It 'tracker がプロジェクトで使えない（NotFound）' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Tracker = 'バグ' })
        Get-Messages $r 2 | Should -Contain 'トラッカーがプロジェクトで使えません: バグ'
        ($r.Errors | Select-Object -First 1).Kind | Should -Be 'NotFound'
    }

    It '対象バージョンが見つからない（NotFound）' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Version = 'v9' })
        Get-Messages $r 2 | Should -Contain '対象バージョンが見つかりません: v9'
        ($r.Errors | Select-Object -First 1).Kind | Should -Be 'NotFound'
    }

    It '対象バージョンが終了またはロック（<V>）' -ForEach @(@{ V = 'old' }, @{ V = 'lock' }) {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Version = $V })
        Get-Messages $r 2 | Should -Contain "対象バージョンが終了またはロックされています: $V"
    }

    It '日付の形式が正しくない' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ StartDate = '11/04/2026'; DueDate = '2026-13-01' })
        Get-Messages $r 2 | Should -Contain '開始日の形式が正しくありません: 11/04/2026'
        Get-Messages $r 2 | Should -Contain '期日の形式が正しくありません: 2026-13-01'
    }

    It '期日が開始日より前' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ StartDate = '2026-11-05'; DueDate = '2026-11-04' })
        Get-Messages $r 2 | Should -Contain '期日が開始日より前です'
    }

    It '仮番号が正の整数でない（<T>）' -ForEach @(@{ T = 'a' }, @{ T = '0' }, @{ T = '1.5' }) {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ TempId = $T })
        Get-Messages $r 2 | Should -Contain "仮番号は正の整数で指定してください: $T"
    }

    It '仮番号の重複は2つ目以降の行にエラー' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(
            New-Row -RowNumber 2 -Values @{ TempId = '1' }
            New-Row -RowNumber 3 -Values @{ TempId = '1' })
        @(Get-Messages $r 2).Count | Should -Be 0
        Get-Messages $r 3 | Should -Contain '仮番号が重複しています: 1'
    }

    It '親の仮番号が見つからない' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Parent = '#9' })
        Get-Messages $r 2 | Should -Contain '親チケットの仮番号が見つかりません: #9'
    }

    It '親子関係の循環は循環に含まれる全行にエラー' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(
            New-Row -RowNumber 2 -Values @{ TempId = '1'; Parent = '#2' }
            New-Row -RowNumber 3 -Values @{ TempId = '2'; Parent = '#1' }
            New-Row -RowNumber 4 -Values @{ TempId = '3'; Parent = '#3' }
            New-Row -RowNumber 5 -Values @{ TempId = '4'; Parent = '#1' })
        Get-Messages $r 2 | Should -Contain '親子関係が循環しています: #2'
        Get-Messages $r 3 | Should -Contain '親子関係が循環しています: #1'
        Get-Messages $r 4 | Should -Contain '親子関係が循環しています: #3'
        # 循環にぶら下がっているだけの行（自身は循環に含まれない）にはエラーを付けない
        @(Get-Messages $r 5).Count | Should -Be 0
    }

    It '既存の親チケットが存在しない' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Parent = '999' })
        Get-Messages $r 2 | Should -Contain '親チケットが存在しません: 999'
    }

    It '親チケットの書き方が正しくない（<P>）' -ForEach @(@{ P = '＃1' }, @{ P = '#a' }, @{ P = 'abc' }) {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Parent = $P })
        Get-Messages $r 2 | Should -Contain "親チケットの書き方が正しくありません（例: 123 または #1）: $P"
    }

    It '1行に複数のエラーがあればすべて返す' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(New-Row -Values @{ Subject = ''; StartDate = '2026-11-05'; DueDate = '2026-11-04' })
        @(Get-Messages $r 2).Count | Should -Be 2
    }

    It 'エラーのない行だけを Items に入れる' {
        $r = Test-RmRows -Root $TestDrive -Metadata $m -Rows @(
            New-Row -RowNumber 2
            New-Row -RowNumber 3 -Values @{ Subject = '' })
        @($r.Items).Count | Should -Be 1
        $r.Items[0].RowNumber | Should -Be 2
    }

    It '同じ既存の親チケットは1回だけ問い合わせる' {
        Test-RmRows -Root $TestDrive -Metadata $m -Rows @(
            New-Row -RowNumber 2 -Values @{ Parent = '123' }
            New-Row -RowNumber 3 -Values @{ Parent = '123' }) | Out-Null
        Should -Invoke Test-RmIssueExists -Times 1 -Exactly
    }
}

Describe '登録' {
    BeforeAll {
        function New-TestItem {
            param([int]$RowNumber, $TempId = $null, [string]$Subject, $ParentTempId = $null, $ParentIssueId = $null)
            [pscustomobject]@{
                RowNumber = $RowNumber; TempId = $TempId; ProjectId = 1; TrackerId = 2; VersionId = 5
                Subject = $Subject; Description = ''; StartDate = '2026-11-04'; DueDate = '2026-11-05'
                ParentIssueId = $ParentIssueId; ParentTempId = $ParentTempId
                ProjectName = 'WBS'; TrackerName = 'タスク'; VersionName = 'v1.0'; ParentText = ''
            }
        }
    }

    BeforeEach {
        Mock Write-Host { }
    }

    It '子が先に書かれていても親から登録し、#n を実際の番号に置き換える' {
        $items = @(
            New-TestItem -RowNumber 2 -TempId 2 -Subject '子' -ParentTempId 1
            New-TestItem -RowNumber 3 -TempId 1 -Subject '親'
        )
        $script:calls = @()
        Mock New-RmIssue { $script:calls += $Fields.subject; if ($Fields.subject -eq '親') { 100 } else { 101 } }
        $res = Invoke-RmRegistration -Items $items
        $calls | Should -Be @('親', '子')
        Should -Invoke New-RmIssue -Times 1 -Exactly -ParameterFilter { $Fields.subject -eq '子' -and $Fields.parent_issue_id -eq 100 }
        Should -Invoke New-RmIssue -Times 1 -Exactly -ParameterFilter {
            $Fields.subject -eq '親' -and $Fields.project_id -eq 1 -and $Fields.tracker_id -eq 2 -and $Fields.fixed_version_id -eq 5 -and
            $Fields.start_date -eq '2026-11-04' -and $Fields.due_date -eq '2026-11-05' -and $null -eq $Fields.parent_issue_id
        }
        ($res | ForEach-Object { $_.RowNumber }) | Should -Be @(2, 3)
        ($res | Where-Object RowNumber -eq 2).IssueId | Should -Be 101
        ($res | Where-Object RowNumber -eq 2).Status | Should -Be 'Success'
    }

    It '親子関係のない行はファイルの順番で登録する' {
        $items = @(
            New-TestItem -RowNumber 2 -Subject 'A'
            New-TestItem -RowNumber 3 -TempId 2 -Subject 'B' -ParentTempId 1
            New-TestItem -RowNumber 4 -Subject 'C'
            New-TestItem -RowNumber 5 -TempId 1 -Subject 'D'
        )
        (Get-RmRegistrationOrder -Items $items | ForEach-Object { $_.Subject }) | Should -Be @('A', 'C', 'D', 'B')
    }

    It '既存チケットの親はそのまま parent_issue_id に入れる' {
        Mock New-RmIssue { 200 }
        Invoke-RmRegistration -Items @(New-TestItem -RowNumber 2 -Subject 'X' -ParentIssueId 123) | Out-Null
        Should -Invoke New-RmIssue -Times 1 -Exactly -ParameterFilter { $Fields.parent_issue_id -eq 123 }
    }

    It '1件失敗しても残りを続け、失敗した親の子孫（孫まで）はスキップする' {
        $items = @(
            New-TestItem -RowNumber 2 -TempId 1 -Subject '親'
            New-TestItem -RowNumber 3 -TempId 2 -Subject '子' -ParentTempId 1
            New-TestItem -RowNumber 4 -TempId 3 -Subject '孫' -ParentTempId 2
            New-TestItem -RowNumber 5 -Subject '無関係'
        )
        Mock New-RmIssue { if ($Fields.subject -eq '親') { throw 'HTTP 422: 題名が不正' } 300 }
        $res = Invoke-RmRegistration -Items $items
        ($res | Where-Object RowNumber -eq 2).Status | Should -Be 'Error'
        ($res | Where-Object RowNumber -eq 2).Message | Should -Be 'HTTP 422: 題名が不正'
        ($res | Where-Object RowNumber -eq 3).Status | Should -Be 'Skipped'
        ($res | Where-Object RowNumber -eq 3).Message | Should -Be '親（仮番号1）が登録されなかったため'
        ($res | Where-Object RowNumber -eq 4).Status | Should -Be 'Skipped'
        ($res | Where-Object RowNumber -eq 4).Message | Should -Be '親（仮番号2）が登録されなかったため'
        ($res | Where-Object RowNumber -eq 5).Status | Should -Be 'Success'
        Should -Invoke New-RmIssue -Times 2 -Exactly
    }

    It '成功した行は画面にチケット番号を表示する' {
        Mock New-RmIssue { 42 }
        Invoke-RmRegistration -Items @(New-TestItem -RowNumber 2 -Subject '設計') | Out-Null
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '行2: #42 設計' }
    }

    It '同じ秒に2回ログを作っても上書きせず別のファイルにする' {
        $root = Join-Path $TestDrive 'samesecond'
        Mock Get-Date { [datetime]'2026-11-03 10:00:00' }
        $first = New-RmLog -Root $root -InputPath 'a.csv'
        $second = New-RmLog -Root $root -InputPath 'b.csv'
        $second.Path | Should -Not -Be $first.Path
        $first.Path | Should -Match 'rmbulk_20261103_100000\.log$'
        $second.Path | Should -Match 'rmbulk_20261103_100000_2\.log$'
        [IO.File]::ReadAllText($first.Path) | Should -Match 'a\.csv'
    }

    It '1件ごとにログへ書き、最後に集計を書く（API キーは出ない）' {
        $root = Join-Path $TestDrive 'logtest'
        $log = New-RmLog -Root $root -InputPath 'C:\work\wbs.csv'
        $log.Path | Should -Match '\\logs\\rmbulk_\d{8}_\d{6}\.log$'
        $items = @(
            New-TestItem -RowNumber 2 -TempId 1 -Subject '親'
            New-TestItem -RowNumber 3 -TempId 2 -Subject '子' -ParentTempId 1
            New-TestItem -RowNumber 4 -Subject '別'
        )
        Mock New-RmIssue { if ($Fields.subject -eq '親') { throw 'HTTP 422: だめ' } 500 }
        Set-RmConnection -BaseUrl 'http://r' -ApiKey 'secret-api-key'
        $res = Invoke-RmRegistration -Items $items -Log $log
        Write-RmLogSummary -Log $log -Results $res
        $text = [IO.File]::ReadAllText($log.Path, [Text.Encoding]::UTF8)
        $text | Should -Match '入力ファイル: C:\\work\\wbs\.csv'
        $text | Should -Match '\[エラー\] 行2 仮番号1 親: HTTP 422: だめ'
        $text | Should -Match '\[スキップ\] 行3 仮番号2 子: 親（仮番号1）が登録されなかったため'
        $text | Should -Match '\[成功\] 行4 仮番号- チケット#500 別'
        $text | Should -Match '成功 1件 / エラー 1件 / スキップ 1件'
        $text | Should -Not -Match 'secret-api-key'
    }
}
