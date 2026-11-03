BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\rmbulk.ps1')

    function New-TestRoot {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $root | Out-Null
        Save-RmConfig -Root $root -BaseUrl 'http://r'
        Save-RmApiKey -Root $root -ApiKey (ConvertTo-SecureString 'k' -AsPlainText -Force)
        Save-RmMetadata -Root $root -Metadata @{
            fetchedAt      = 'x'
            projects       = @([pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 })
            projectDetails = @{}
        }
        $root
    }

    function New-TestCsv {
        param([string]$Root, [string[]]$DataLines)
        $path = Join-Path $Root 'input.csv'
        $text = (@('仮ID,プロジェクト,トラッカー,題名,開始日,期日,対象バージョン,親チケット') + $DataLines) -join "`r`n"
        [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $true))
        $path
    }
}

Describe 'setup' {
    BeforeEach {
        Mock Write-Host { }
        $script:root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $root | Out-Null
        Mock Read-Host { 'http://r/' } -ParameterFilter { -not $AsSecureString }
        Mock Read-Host { ConvertTo-SecureString 'key1' -AsPlainText -Force } -ParameterFilter { $AsSecureString }
    }

    It '接続できたら URL・API キー・プロジェクト一覧を保存する' {
        Mock Get-RmCurrentUser { [pscustomobject]@{ login = 'taro' } }
        Mock Get-RmProjects { @([pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 }) }
        Invoke-RmSetup -Root $root | Should -BeTrue
        (Read-RmConfig -Root $root).BaseUrl | Should -Be 'http://r'
        Read-RmApiKey -Root $root | Should -Be 'key1'
        (Read-RmMetadata -Root $root).projects[0].name | Should -Be 'WBS'
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '接続できました: taro' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'プロジェクト 1 件を取得しました' }
    }

    It '接続に失敗したら何も保存しない' {
        Mock Get-RmCurrentUser { throw '認証に失敗しました（HTTP 401）。API キーが無効です。rmbulk setup を実行し直してください。' }
        Invoke-RmSetup -Root $root | Should -BeFalse
        Test-Path (Get-RmPaths -Root $root).Config | Should -BeFalse
        Test-Path (Get-RmPaths -Root $root).ApiKey | Should -BeFalse
    }

    It '設定済みなら URL の入力を空にすると既存の値を使う' {
        Save-RmConfig -Root $root -BaseUrl 'http://old'
        Mock Read-Host { '' } -ParameterFilter { -not $AsSecureString }
        Mock Get-RmCurrentUser { [pscustomobject]@{ login = 'taro' } }
        Mock Get-RmProjects { @() }
        Invoke-RmSetup -Root $root | Should -BeTrue
        (Read-RmConfig -Root $root).BaseUrl | Should -Be 'http://old'
        Should -Invoke Read-Host -ParameterFilter { $Prompt -eq 'Redmine の URL [http://old]' }
    }
}

Describe 'refresh' {
    It 'プロジェクト一覧を取り直して保存する' {
        Mock Write-Host { }
        $root = New-TestRoot
        Mock Get-RmProjects { @([pscustomobject]@{ id = 9; name = '新'; identifier = 'new'; status = 1 }) }
        Invoke-RmRefresh -Root $root | Should -BeTrue
        (Read-RmMetadata -Root $root).projects[0].identifier | Should -Be 'new'
    }
}

Describe 'template' {
    It '列名の行だけを UTF-8 BOM 付きで出力する' {
        Mock Write-Host { }
        $out = Join-Path $TestDrive 'template.csv'
        Invoke-RmTemplate -OutputPath $out | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes($out)
        $bytes[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        (Get-Content $out -Encoding UTF8) | Should -Be '仮ID,プロジェクト,トラッカー,題名,説明,開始日,期日,対象バージョン,親チケット'
    }

    It '既にファイルがあれば上書きしない' {
        Mock Write-Host { }
        $out = Join-Path $TestDrive 'exists.csv'
        Set-Content -Path $out -Value 'keep'
        Invoke-RmTemplate -OutputPath $out | Should -BeFalse
        Get-Content $out | Should -Be 'keep'
    }
}

Describe 'バージョン' {
    It 'バージョンは x.y.z の形' {
        $RmVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'version コマンドはバージョンを表示する' {
        Mock Write-Host { }
        Invoke-RmVersion | Should -BeTrue
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq "rmbulk $RmVersion" }
    }

    It '使い方の表示にもバージョンを出す' {
        Mock Write-Host { }
        Show-RmUsage
        Should -Invoke Write-Host -ParameterFilter { "$Object" -match "^rmbulk $([regex]::Escape($RmVersion))\b" }
    }

    It 'バージョンが最新のタグより古くない（タグを打つ前に上げ忘れていない）' {
        $repo = Join-Path $PSScriptRoot '..\..'
        $tag = git -C $repo describe --tags --abbrev=0 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $tag) { Set-ItResult -Skipped -Because 'タグが取得できない'; return }
        [version]$RmVersion | Should -BeGreaterOrEqual ([version]($tag -replace '^v', ''))
    }
}

Describe 'import' {
    BeforeEach {
        Mock Write-Host { }
        Mock Out-Host { }
        Mock Get-RmProjectTrackers { @([pscustomobject]@{ id = 2; name = 'タスク' }) }
        Mock Get-RmProjectVersions { @([pscustomobject]@{ id = 5; name = 'v1.0'; status = 'open' }) }
        Mock Test-RmIssueExists { $true }
        Mock New-RmIssue { 100 + [int]($Fields.subject -replace '\D', '') }
        Mock Read-RmConfirmation { $true }
        Mock Get-RmCurrentUser { [pscustomobject]@{ id = 1; login = 'taro' } }
        $script:root = New-TestRoot
    }

    It 'メタデータが保存済みでも、最初に接続と認証を確かめ、失敗したら確認を聞かずに終わる' {
        Mock Get-RmCurrentUser { throw '認証に失敗しました（HTTP 401）。API キーが無効です。rmbulk setup を実行し直してください。' }
        $metadata = Read-RmMetadata -Root $root
        $metadata.projectDetails['1'] = @{
            fetchedAt = 'x'
            trackers  = @([pscustomobject]@{ id = 2; name = 'タスク' })
            versions  = @([pscustomobject]@{ id = 5; name = 'v1.0'; status = 'open' })
        }
        Save-RmMetadata -Root $root -Metadata $metadata
        $csv = New-TestCsv -Root $root -DataLines @('1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Read-RmConfirmation -Times 0
        Should -Invoke New-RmIssue -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*rmbulk setup を実行し直してください*' }
    }

    It 'y なら親から順に登録し、ログを残す' {
        $csv = New-TestCsv -Root $root -DataLines @(
            '2,WBS,タスク,子2,2026-11-04,2026-11-05,v1.0,#1',
            '1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue
        Should -Invoke New-RmIssue -Times 1 -Exactly -ParameterFilter { $Fields.subject -eq '子2' -and $Fields.parent_issue_id -eq 101 }
        $logs = @(Get-ChildItem (Get-RmPaths -Root $root).LogDir)
        $logs.Count | Should -Be 1
        [IO.File]::ReadAllText($logs[0].FullName) | Should -Match '成功 2件 / エラー 0件 / スキップ 0件'
        [IO.File]::ReadAllText($logs[0].FullName) | Should -Match "rmbulk $([regex]::Escape($RmVersion))"
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '成功 2件 / エラー 0件 / スキップ 0件' }
    }

    It 'エラーがあれば確認を聞かずに終わり、登録しない（件数はエラーのある行の数）' {
        $csv = New-TestCsv -Root $root -DataLines @(
            '1,WBS,タスク,,2026-11-04,2026-11-05,v1.0,',
            '2,WBS,タスク,正しい,2026-11-04,2026-11-05,v1.0,',
            '3,WBS,タスク,日付なし,,,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Read-RmConfirmation -Times 0
        Should -Invoke New-RmIssue -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '    └ 題名が空です' }
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'エラーが 2 件あるため登録しません。' }
    }

    It 'n なら登録しない' {
        Mock Read-RmConfirmation { $false }
        $csv = New-TestCsv -Root $root -DataLines @('1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue
        Should -Invoke New-RmIssue -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '登録を中止しました。' }
    }

    It 'NotFound があればメタデータを一度だけ取り直して再チェックする' {
        Mock Get-RmProjects { @(
                [pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 }
                [pscustomobject]@{ id = 2; name = '新規'; identifier = 'new'; status = 1 }) }
        $csv = New-TestCsv -Root $root -DataLines @('1,新規,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue
        Should -Invoke Get-RmProjects -Times 1 -Exactly
        Should -Invoke New-RmIssue -Times 1 -Exactly -ParameterFilter { $Fields.project_id -eq 2 }
    }

    It '取り直しても見つからなければエラーで終わる' {
        Mock Get-RmProjects { @([pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 }) }
        $csv = New-TestCsv -Root $root -DataLines @('1,なし,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Get-RmProjects -Times 1 -Exactly
        Should -Invoke Read-RmConfirmation -Times 0
    }

    It '列名だけのファイルは確認を聞かずに終わる' {
        $csv = New-TestCsv -Root $root -DataLines @()
        Invoke-RmImport -Root $root -Path $csv | Should -BeTrue
        Should -Invoke Read-RmConfirmation -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq '登録するチケットがありません。' }
    }

    It 'チェック中に 401 になったら setup を促して終わる' {
        Mock Test-RmIssueExists { throw '認証に失敗しました（HTTP 401）。API キーが無効です。rmbulk setup を実行し直してください。' }
        $csv = New-TestCsv -Root $root -DataLines @('1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,123')
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Read-RmConfirmation -Times 0
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*rmbulk setup を実行し直してください*' }
    }

    It '登録に失敗した行があれば、その行を表示して $false' {
        Mock New-RmIssue { throw 'HTTP 422: だめ' }
        $csv = New-TestCsv -Root $root -DataLines @('1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $root -Path $csv | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { "$Object" -eq 'エラー 親1: HTTP 422: だめ' -and $ForegroundColor -eq 'Red' }
    }

    It '設定がなければ setup を促す' {
        $empty = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $empty | Out-Null
        $csv = New-TestCsv -Root $root -DataLines @('1,WBS,タスク,親1,2026-11-04,2026-11-05,v1.0,')
        Invoke-RmImport -Root $empty -Path $csv | Should -BeFalse
        Should -Invoke Write-Host -ParameterFilter { "$Object" -like '*rmbulk setup を実行してください*' }
    }
}

Describe 'Read-RmConfirmation' {
    It '<Answer> → <Expected>' -ForEach @(
        @{ Answer = 'y'; Expected = $true }, @{ Answer = 'Y'; Expected = $true },
        @{ Answer = 'n'; Expected = $false }, @{ Answer = ''; Expected = $false }, @{ Answer = 'yes'; Expected = $false }) {
        Mock Read-Host { $Answer }
        Read-RmConfirmation | Should -Be $Expected
        Should -Invoke Read-Host -ParameterFilter { $Prompt -eq '登録しますか？(y/n)' }
    }
}

Describe 'rmbulk.cmd' {
    BeforeAll {
        # ツール一式をコピーし、接続できない URL と API キーを保存しておく
        $script:tool = Join-Path $TestDrive 'tool'
        New-Item -ItemType Directory $tool | Out-Null
        $repo = Join-Path $PSScriptRoot '..\..'
        Copy-Item (Join-Path $repo 'rmbulk.cmd'), (Join-Path $repo 'rmbulk.ps1') $tool
        Copy-Item (Join-Path $repo 'lib') $tool -Recurse
        Save-RmConfig -Root $tool -BaseUrl 'http://127.0.0.1:9'
        Save-RmApiKey -Root $tool -ApiKey (ConvertTo-SecureString 'k' -AsPlainText -Force)
    }

    # PowerShell 7 から実行すると、cmd.exe 経由で起動した 5.1 に 7 の PSModulePath が引き継がれる
    It '保存した API キーを読み込める（PowerShell 7 から実行しても）' {
        $output = & (Join-Path $tool 'rmbulk.cmd') refresh 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $output | Should -Not -Match 'API キーを読み込めません'
        $output | Should -Match 'Redmine に接続できません'
    }
}
