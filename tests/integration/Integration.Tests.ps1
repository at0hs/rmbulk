BeforeDiscovery {
    & docker info *> $null
    $script:noDocker = ($LASTEXITCODE -ne 0)
    $script:noExcel = $true
    try {
        $probe = New-Object -ComObject Excel.Application
        $probe.Quit()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($probe)
        $script:noExcel = $false
    } catch { }
}

Describe '本物の Redmine への登録' -Skip:$noDocker {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\rmbulk.ps1')
        $script:apiKey = & (Join-Path $PSScriptRoot 'Initialize-TestRedmine.ps1') | Select-Object -Last 1
        $script:root = Join-Path $TestDrive 'tool'
        New-Item -ItemType Directory $root | Out-Null
        $script:runId = [guid]::NewGuid().ToString('N').Substring(0, 6)
        $script:header = '仮ID,プロジェクト,トラッカー,題名,説明,開始日,期日,対象バージョン,親チケット'

        Mock Read-Host { 'http://127.0.0.1:3030' } -ParameterFilter { -not $AsSecureString }
        Mock Read-Host { ConvertTo-SecureString $apiKey -AsPlainText -Force } -ParameterFilter { $AsSecureString }
        Mock Read-RmConfirmation { $true }

        function Write-SjisCsv {
            param([string]$Name, [string[]]$Lines)
            $path = Join-Path $TestDrive $Name
            [IO.File]::WriteAllBytes($path, [Text.Encoding]::GetEncoding(932).GetBytes(($Lines -join "`r`n") + "`r`n"))
            $path
        }

        # ログの [成功] 行から 仮ID -> チケット番号 を取り出す
        function Get-IssueIdsFromLog {
            $log = Get-ChildItem (Get-RmPaths -Root $root).LogDir | Sort-Object LastWriteTime | Select-Object -Last 1
            $ids = @{}
            foreach ($line in [IO.File]::ReadAllLines($log.FullName, [Text.Encoding]::UTF8)) {
                if ($line -match '\[成功\] 行\d+ 仮ID(\S+) チケット#(\d+)') { $ids[$Matches[1]] = [int]$Matches[2] }
            }
            $ids
        }
    }

    It 'setup でプロジェクト一覧が保存される' {
        Invoke-RmSetup -Root $root | Should -BeTrue
        (Read-RmMetadata -Root $root).projects.identifier | Should -Contain 'rmbulk-test'
    }

    It 'Shift-JIS の CSV から親子3階層を登録でき、日本語が化けない' {
        $csv = Write-SjisCsv -Name 'tree.csv' -Lines @(
            $header,
            "3,rmbulk-test,機能,孫-$runId,,2026/11/06,2026/11/07,v1.0,#2",
            "1,rmbulk テスト,機能,親-$runId,日本語の説明です,2026-11-04,2026-11-10,v1.0,",
            "2,rmbulk-test,機能,子-$runId,,2026-11-05,2026-11-08,v1.0,#1")
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue

        $ids = Get-IssueIdsFromLog
        $ids.Count | Should -Be 3
        $parent = (Invoke-RmApi -Method Get -Path "/issues/$($ids['1']).json").issue
        $child = (Invoke-RmApi -Method Get -Path "/issues/$($ids['2']).json").issue
        $grandchild = (Invoke-RmApi -Method Get -Path "/issues/$($ids['3']).json").issue
        $parent.subject | Should -Be "親-$runId"
        $parent.description | Should -Be '日本語の説明です'
        $parent.tracker.name | Should -Be '機能'
        $parent.fixed_version.name | Should -Be 'v1.0'
        $child.parent.id | Should -Be $ids['1']
        # 親の開始日・期日は Redmine の初期設定では子から算出されるため、子を持たない孫で日付を確認する
        $grandchild.start_date | Should -Be '2026-11-06'
        $grandchild.due_date | Should -Be '2026-11-07'
        $grandchild.parent.id | Should -Be $ids['2']
    }

    It '既存チケットを親に指定できる' {
        $existing = (Get-IssueIdsFromLog)['1']
        $csv = Write-SjisCsv -Name 'existing.csv' -Lines @(
            $header, ",rmbulk-test,機能,既存の子-$runId,,2026-11-04,2026-11-05,v1.0,$existing")
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue
        $id = (Get-IssueIdsFromLog)['-']
        (Invoke-RmApi -Method Get -Path "/issues/$id.json").issue.parent.id | Should -Be $existing
    }

    It '終了したバージョン・存在しない tracker・終了したプロジェクト・存在しない親は確認の段階で止まる' {
        $csv = Write-SjisCsv -Name 'invalid.csv' -Lines @(
            $header,
            ",rmbulk-test,機能,a-$runId,,2026-11-04,2026-11-05,old,",
            ",rmbulk-test,なし,b-$runId,,2026-11-04,2026-11-05,v1.0,",
            ",closed-proj,機能,c-$runId,,2026-11-04,2026-11-05,v1.0,",
            ",rmbulk-test,機能,d-$runId,,2026-11-04,2026-11-05,v1.0,99999999")
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Read-RmConfirmation -Times 0 -Exactly -Scope It
        $found = Invoke-RmApi -Method Get -Path "/issues.json?project_id=rmbulk-test&status_id=*&subject=~$runId&limit=100"
        @($found.issues | Where-Object { $_.subject -match '^[abcd]-' }).Count | Should -Be 0
    }

    It 'Excel ファイルからも登録できる' -Skip:$noExcel {
        $xlsx = Join-Path $TestDrive 'wbs.xlsx'
        $excel = New-Object -ComObject Excel.Application
        try {
            $excel.DisplayAlerts = $false
            $book = $excel.Workbooks.Add()
            $sheet = $book.Worksheets.Item(1)
            $values = @(
                @('仮ID', 'プロジェクト', 'トラッカー', '題名', '開始日', '期日', '対象バージョン', '親チケット'),
                @(1, 'rmbulk-test', '機能', "Excel親-$runId", ([datetime]'2026-11-04').ToOADate(), ([datetime]'2026-11-05').ToOADate(), 'v1.0', ''),
                @(2, 'rmbulk-test', '機能', "Excel子-$runId", ([datetime]'2026-11-04').ToOADate(), ([datetime]'2026-11-05').ToOADate(), 'v1.0', '#1'))
            for ($r = 0; $r -lt $values.Count; $r++) {
                for ($c = 0; $c -lt $values[$r].Count; $c++) {
                    # .Value2 = は最初に代入した型を覚えてしまい、別の型で失敗するので InvokeMember で代入する
                    $cell = $sheet.Cells.Item($r + 1, $c + 1)
                    [void]$cell.GetType().InvokeMember('Value2', [Reflection.BindingFlags]::SetProperty, $null, $cell, @($values[$r][$c]))
                }
            }
            $book.SaveAs($xlsx, 51)
            $book.Close($false)
        } finally {
            $excel.Quit()
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
        }
        Invoke-RmImport -Root $root -Path $xlsx | Should -BeTrue
        $ids = Get-IssueIdsFromLog
        (Invoke-RmApi -Method Get -Path "/issues/$($ids['2']).json").issue.parent.id | Should -Be $ids['1']
    }
}
