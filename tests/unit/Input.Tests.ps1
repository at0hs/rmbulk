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

    $script:header = '仮番号,プロジェクト,トラッカー,題名,開始日,期日,対象バージョン'
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
            '仮番号,プロジェクト,トラッカー,題名,開始日,期日', '1,WBS,タスク,設計,2026-11-04,2026-11-05')
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
