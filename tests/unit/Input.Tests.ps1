BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\lib\Input.ps1')

    # テキストを指定した文字コードで書き出す（改行は CRLF）
    function Write-TestCsv {
        param([string]$Path, [string[]]$Lines, [ValidateSet('utf8bom', 'utf8', 'sjis')][string]$Encoding = 'utf8bom')
        $text = ($Lines -join "`r`n") + "`r`n"
        $bytes = switch ($Encoding) {
            'utf8bom' { [byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes($text) }
            'utf8' { [Text.Encoding]::UTF8.GetBytes($text) }
            'sjis' { [Text.Encoding]::GetEncoding(932).GetBytes($text) }
        }
        [IO.File]::WriteAllBytes($Path, $bytes)
        $Path
    }

    $script:header = '仮ID,プロジェクト,トラッカー,題名,開始日,期日,対象バージョン'
}

Describe 'CSV の読み込み' {
    It '<Enc> を同じ内容として読める' -ForEach @(@{ Enc = 'utf8bom' }, @{ Enc = 'utf8' }, @{ Enc = 'sjis' }) {
        $path = Write-TestCsv -Path (Join-Path $TestDrive "$Enc.csv") -Encoding $Enc -Lines @(
            $header, '1,WBS,タスク,設計,2026-11-04,2026-11-05,v1.0')
        $r = Read-RmInputFile -Path $path
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Subject | Should -Be '設計'
        $r.Rows[0].Tracker | Should -Be 'タスク'
        $r.Rows[0].TempId | Should -Be '1'
        $r.Rows[0].RowNumber | Should -Be 2
        $r.Rows[0].Description | Should -Be ''
        $r.Rows[0].Parent | Should -Be ''
    }

    It '説明の中の改行・カンマ・ダブルクォートを保つ' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'multiline.csv') -Lines @(
            "$header,説明",
            '1,WBS,タスク,設計,2026-11-04,2026-11-05,v1.0,"1行目,""引用""',
            '2行目"',
            '2,WBS,タスク,実装,2026-11-06,2026-11-07,v1.0,')
        $r = Read-RmInputFile -Path $path
        @($r.Rows).Count | Should -Be 2
        $r.Rows[0].Description | Should -Be "1行目,`"引用`"`r`n2行目"
        $r.Rows[1].Subject | Should -Be '実装'
        $r.Rows[1].RowNumber | Should -Be 3
    }

    It '説明の中の空行と空白だけの行を保つ' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'paragraph.csv') -Lines @(
            "$header,説明",
            '1,WBS,タスク,設計,2026-11-04,2026-11-05,v1.0,"段落1',
            '',
            '段落2',
            '   ',
            '終わり"',
            '',
            '2,WBS,タスク,実装,2026-11-06,2026-11-07,v1.0,')
        $r = Read-RmInputFile -Path $path
        @($r.Rows).Count | Should -Be 2
        $r.Rows[0].Description | Should -Be "段落1`r`n`r`n段落2`r`n   `r`n終わり"
        $r.Rows[1].Subject | Should -Be '実装'
    }

    It '引用符で囲んだ空のセルと、末尾の改行がないファイルを読める' {
        $path = Join-Path $TestDrive 'noeol.csv'
        [IO.File]::WriteAllText($path, "$header,説明`n1,WBS,タスク,`"設計`",2026-11-04,2026-11-05,v1.0,`"`"", (New-Object Text.UTF8Encoding $false))
        $r = Read-RmInputFile -Path $path
        $r.Rows[0].Subject | Should -Be '設計'
        $r.Rows[0].Description | Should -Be ''
    }

    It '全列が空の行は無視し、前後の空白を除く' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'blank.csv') -Lines @(
            $header, ',,,,,,', ' 1 , WBS ,タスク, 設計 ,2026-11-04,2026-11-05,v1.0')
        $r = Read-RmInputFile -Path $path
        @($r.Rows).Count | Should -Be 1
        $r.Rows[0].Subject | Should -Be '設計'
        $r.Rows[0].Project | Should -Be 'WBS'
        $r.Rows[0].RowNumber | Should -Be 3
    }

    It '列の順番が違っても読める' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'order.csv') -Lines @(
            '題名,対象バージョン,期日,開始日,トラッカー,プロジェクト,親チケット',
            '設計,v1.0,2026-11-05,2026-11-04,タスク,WBS,#1')
        $r = Read-RmInputFile -Path $path
        $r.Rows[0].Subject | Should -Be '設計'
        $r.Rows[0].Version | Should -Be 'v1.0'
        $r.Rows[0].Parent | Should -Be '#1'
        $r.Rows[0].TempId | Should -Be ''
    }

    It '不明な列は警告して無視する' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'unknown.csv') -Lines @(
            "$header,担当者", '1,WBS,タスク,設計,2026-11-04,2026-11-05,v1.0,山田')
        $r = Read-RmInputFile -Path $path
        $r.Warnings | Should -Contain '不明な列を無視します: 担当者'
        $r.Rows[0].PSObject.Properties.Name | Should -Not -Contain '担当者'
    }

    It '列名の行しかなければ Rows は空' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'header.csv') -Lines @($header)
        @((Read-RmInputFile -Path $path).Rows).Count | Should -Be 0
    }

    It '必須列がなければ throw' {
        $path = Write-TestCsv -Path (Join-Path $TestDrive 'missing.csv') -Lines @(
            '仮ID,プロジェクト,トラッカー,題名,開始日,期日', '1,WBS,タスク,設計,2026-11-04,2026-11-05')
        { Read-RmInputFile -Path $path } | Should -Throw '必須の列がありません: 対象バージョン'
    }

    It '未対応の拡張子は throw' {
        $path = Join-Path $TestDrive 'a.txt'
        Set-Content -Path $path -Value 'x'
        { Read-RmInputFile -Path $path } | Should -Throw '*対応していません*'
    }

    It 'ファイルがなければ throw' {
        { Read-RmInputFile -Path (Join-Path $TestDrive 'none.csv') } | Should -Throw 'ファイルが見つかりません*'
    }
}

BeforeDiscovery {
    $script:noExcel = $true
    try {
        $probe = New-Object -ComObject Excel.Application
        $probe.Quit()
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($probe)
        $script:noExcel = $false
    } catch { }
}

Describe 'Excel の読み込み' -Skip:$noExcel {
    BeforeAll {
        # sheets: シートごとに、行の配列（行はセル値の配列）。[datetime] は日付セル、'@文字列' は文字列セルとして書く
        function New-TestXlsx {
            param([string]$Path, [object[]]$Sheets)
            $excel = New-Object -ComObject Excel.Application
            try {
                $excel.DisplayAlerts = $false
                $book = $excel.Workbooks.Add()
                while ($book.Worksheets.Count -lt $Sheets.Count) { [void]$book.Worksheets.Add([Type]::Missing, $book.Worksheets.Item($book.Worksheets.Count)) }
                for ($s = 0; $s -lt $Sheets.Count; $s++) {
                    $sheet = $book.Worksheets.Item($s + 1)
                    $rows = $Sheets[$s]
                    for ($r = 0; $r -lt $rows.Count; $r++) {
                        for ($c = 0; $c -lt $rows[$r].Count; $c++) {
                            $cell = $sheet.Cells.Item($r + 1, $c + 1)
                            $v = $rows[$r][$c]
                            # $cell.Value2 = $v は最初に代入した型を覚えてしまい、別の型で失敗するので InvokeMember で代入する
                            $setValue = { param($value) [void]$cell.GetType().InvokeMember('Value2', [Reflection.BindingFlags]::SetProperty, $null, $cell, @($value)) }
                            if ($v -is [string] -and $v.StartsWith('@')) { $cell.NumberFormat = '@'; & $setValue $v.Substring(1) }
                            elseif ($v -is [datetime]) { & $setValue $v.ToOADate(); $cell.NumberFormat = 'yyyy/m/d' }
                            elseif ($null -ne $v) { & $setValue $v }
                        }
                    }
                }
                $book.SaveAs($Path, 51)
                $book.Close($false)
            } finally {
                $excel.Quit()
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
                [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            }
            $Path
        }

        $headerRow = @('仮ID', 'プロジェクト', 'トラッカー', '題名', '開始日', '期日', '対象バージョン', '親チケット')
        $script:xlsx = New-TestXlsx -Path (Join-Path $TestDrive 'wbs.xlsx') -Sheets @(
            , @(
                $headerRow,
                @(1, 'WBS', 'タスク', '設計', [datetime]'2026-11-04', [datetime]'2026-11-05', 'v1.0', $null),
                @(2, 'WBS', 'タスク', '実装', '@2026/11/05', '@2026/11/06', 'v1.0', 123),
                @($null, $null, $null, $null, $null, $null, $null, $null),
                @(3, 'WBS', 'タスク', '試験', [datetime]'2026-11-07', [datetime]'2026-11-08', '@1.5', '#1')
            )
        )
        $script:twoSheets = New-TestXlsx -Path (Join-Path $TestDrive 'two.xlsx') -Sheets @(
            @($headerRow, @(1, 'WBS', 'タスク', '設計', [datetime]'2026-11-04', [datetime]'2026-11-05', 'v1.0', $null)),
            @($headerRow, @(9, 'X', 'X', '別シート', [datetime]'2026-11-04', [datetime]'2026-11-05', 'v1.0', $null), @(10, 'X', 'X', '別シート2', [datetime]'2026-11-04', [datetime]'2026-11-05', 'v1.0', $null))
        )
        $script:missing = New-TestXlsx -Path (Join-Path $TestDrive 'missing.xlsx') -Sheets @(
            , @(@('題名'), @('設計'))
        )
        $script:r = Read-RmInputFile -Path $xlsx
    }

    It '先頭シートだけを読み、2枚目は無視する' {
        $two = Read-RmInputFile -Path $twoSheets
        @($two.Rows).Count | Should -Be 1
        $two.Rows[0].Subject | Should -Be '設計'
    }

    It '空の行は無視し、行番号はシート上の行番号' {
        @($r.Rows).Count | Should -Be 3
        $r.Rows[2].Subject | Should -Be '試験'
        $r.Rows[2].RowNumber | Should -Be 5
    }

    It '日付セルは yyyy-MM-dd、文字列の日付はそのまま' {
        $r.Rows[0].StartDate | Should -Be '2026-11-04'
        $r.Rows[0].DueDate | Should -Be '2026-11-05'
        $r.Rows[1].StartDate | Should -Be '2026/11/05'
    }

    It '数値セルの仮ID・親チケットは整数の文字列になる' {
        $r.Rows[0].TempId | Should -Be '1'
        $r.Rows[1].Parent | Should -Be '123'
        $r.Rows[0].Parent | Should -Be ''
    }

    It '文字列セルの値はそのまま' {
        $r.Rows[2].Version | Should -Be '1.5'
        $r.Rows[2].Parent | Should -Be '#1'
    }

    It '読み込み後に EXCEL.EXE が増えていない' {
        $before = @(Get-Process EXCEL -ErrorAction SilentlyContinue).Count
        Read-RmInputFile -Path $xlsx | Out-Null
        Start-Sleep -Seconds 2
        @(Get-Process EXCEL -ErrorAction SilentlyContinue).Count | Should -BeLessOrEqual $before
    }

    It '必須列がないファイルで throw しても EXCEL.EXE が残らない' {
        $before = @(Get-Process EXCEL -ErrorAction SilentlyContinue).Count
        { Read-RmInputFile -Path $missing } | Should -Throw '必須の列がありません*'
        Start-Sleep -Seconds 2
        @(Get-Process EXCEL -ErrorAction SilentlyContinue).Count | Should -BeLessOrEqual $before
    }
}

Describe 'Excel の値の変換（Excel 不要）' {
    BeforeAll {
        # Excel の UsedRange.Value2 と同じ、下限 1 の 2 次元配列を作る
        function New-Value2 {
            param([object[]]$Rows)
            $cols = ($Rows | ForEach-Object { $_.Count } | Measure-Object -Maximum).Maximum
            $arr = [Array]::CreateInstance([object], [int[]]@($Rows.Count, $cols), [int[]]@(1, 1))
            for ($r = 0; $r -lt $Rows.Count; $r++) {
                for ($c = 0; $c -lt $Rows[$r].Count; $c++) { $arr.SetValue($Rows[$r][$c], $r + 1, $c + 1) }
            }
            , $arr
        }
        $oa = ([datetime]'2026-11-04').ToOADate()
        $values = New-Value2 @(
            @('仮ID', 'プロジェクト', 'トラッカー', '題名', '開始日', '期日', '対象バージョン', '親チケット'),
            @([double]1, 'WBS', 'タスク', '設計', $oa, ($oa + 1), 'v1.0', $null),
            @([double]2, 'WBS', 'タスク', '実装', '2026/11/05', '2026/11/06', [double]1.5, [double]123),
            @($null, $null, $null, $null, $null, $null, $null, $null),
            @([double]3, 'WBS', 'タスク', '試験', $oa, $oa, 'v1.0', '#1')
        )
        $table = ConvertFrom-RmExcelValues -Values $values
        $script:r = ConvertTo-RmInputRows -Headers $table.Headers -Records $table.Records
    }

    It '空の行は無視し、行番号はシート上の行番号' {
        @($r.Rows).Count | Should -Be 3
        $r.Rows[2].RowNumber | Should -Be 5
    }

    It '日付の列の数値は yyyy-MM-dd、文字列の日付はそのまま' {
        $r.Rows[0].StartDate | Should -Be '2026-11-04'
        $r.Rows[0].DueDate | Should -Be '2026-11-05'
        $r.Rows[1].StartDate | Should -Be '2026/11/05'
    }

    It '整数の数値は整数の文字列、小数はそのままの文字列になる' {
        $r.Rows[0].TempId | Should -Be '1'
        $r.Rows[1].Parent | Should -Be '123'
        $r.Rows[1].Version | Should -Be '1.5'
        $r.Rows[0].Parent | Should -Be ''
    }

    It 'セルが1つだけ（スカラー）でも列名として扱う' {
        $t = ConvertFrom-RmExcelValues -Values '題名'
        $t.Headers | Should -Be @('題名')
        @($t.Records).Count | Should -Be 0
    }

    It '空のシート（$null）は列なし' {
        $t = ConvertFrom-RmExcelValues -Values $null
        @($t.Headers).Count | Should -Be 0
    }
}
