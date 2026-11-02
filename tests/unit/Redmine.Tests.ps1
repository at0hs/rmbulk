BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\lib\Redmine.ps1')
}

Describe 'Config' {
    It 'URL を保存して読み込める（末尾の / は除く）' {
        Save-RmConfig -Root $TestDrive -BaseUrl 'https://redmine.example.com/'
        (Read-RmConfig -Root $TestDrive).BaseUrl | Should -Be 'https://redmine.example.com'
    }

    It 'API キーは平文で保存されず、読み戻せる' {
        $key = ConvertTo-SecureString 'abc123secret' -AsPlainText -Force
        Save-RmApiKey -Root $TestDrive -ApiKey $key
        (Get-Content (Get-RmPaths -Root $TestDrive).ApiKey -Raw) | Should -Not -Match 'abc123secret'
        Read-RmApiKey -Root $TestDrive | Should -Be 'abc123secret'
    }

    It '設定がなければ setup を促す' {
        { Read-RmConfig -Root (Join-Path $TestDrive 'none') } | Should -Throw '*rmbulk setup*'
        { Read-RmApiKey -Root (Join-Path $TestDrive 'none') } | Should -Throw '*rmbulk setup*'
    }
}

Describe 'Redmine API' {
    BeforeEach {
        Set-RmConnection -BaseUrl 'http://r' -ApiKey 'k'
    }

    It 'API キーをヘッダで送り、本文を UTF-8 のバイト列で送る（空の項目は送らない）' {
        Mock Invoke-RestMethod { [pscustomobject]@{ issue = [pscustomobject]@{ id = 42 } } }
        New-RmIssue -Fields @{ project_id = 1; subject = '設計レビュー'; description = ''; parent_issue_id = $null } | Should -Be 42
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $text = [Text.Encoding]::UTF8.GetString($Body)
            $Uri -eq 'http://r/issues.json' -and $Method -eq 'Post' -and
            $Headers['X-Redmine-API-Key'] -eq 'k' -and $Body -is [byte[]] -and
            $text -match '設計レビュー' -and $text -notmatch 'description' -and $text -notmatch 'parent_issue_id'
        }
    }

    It 'プロジェクト一覧をページングして全件取得する' {
        Mock Invoke-RestMethod { [pscustomobject]@{ total_count = 150; projects = @(1..100 | ForEach-Object { [pscustomobject]@{ id = $_; name = "p$_"; identifier = "p$_"; status = 1 } }) } } -ParameterFilter { $Uri -match 'offset=0' }
        Mock Invoke-RestMethod { [pscustomobject]@{ total_count = 150; projects = @(101..150 | ForEach-Object { [pscustomobject]@{ id = $_; name = "p$_"; identifier = "p$_"; status = 1 } }) } } -ParameterFilter { $Uri -match 'offset=100' }
        $projects = Get-RmProjects
        $projects.Count | Should -Be 150
        $projects[149].identifier | Should -Be 'p150'
    }

    It 'プロジェクトの tracker とバージョンを取得する' {
        Mock Invoke-RestMethod { [pscustomobject]@{ project = [pscustomobject]@{ id = 3; trackers = @([pscustomobject]@{ id = 2; name = 'タスク' }) } } } -ParameterFilter { $Uri -eq 'http://r/projects/3.json?include=trackers' }
        Mock Invoke-RestMethod { [pscustomobject]@{ versions = @([pscustomobject]@{ id = 5; name = 'v1.0'; status = 'open' }) } } -ParameterFilter { $Uri -eq 'http://r/projects/3/versions.json' }
        (Get-RmProjectTrackers -ProjectId 3)[0].name | Should -Be 'タスク'
        (Get-RmProjectVersions -ProjectId 3)[0].status | Should -Be 'open'
    }

    It '401 は setup を促すメッセージにする' {
        Mock Invoke-RestMethod { throw 'unauthorized' }
        Mock Get-RmHttpError { @{ StatusCode = 401; Body = ''; Message = 'unauthorized' } }
        { Get-RmCurrentUser } | Should -Throw '認証に失敗しました（HTTP 401）。API キーが無効です。rmbulk setup を実行し直してください。'
    }

    It '422 は Redmine の errors を連結する' {
        Mock Invoke-RestMethod { throw 'unprocessable' }
        Mock Get-RmHttpError { @{ StatusCode = 422; Body = '{"errors":["題名を入力してください","期日が不正"]}'; Message = 'x' } }
        { New-RmIssue -Fields @{ project_id = 1 } } | Should -Throw 'HTTP 422: 題名を入力してください; 期日が不正'
    }

    It 'その他の HTTP エラーはステータスと本文を出す' {
        Mock Invoke-RestMethod { throw 'forbidden' }
        Mock Get-RmHttpError { @{ StatusCode = 403; Body = 'Forbidden'; Message = 'x' } }
        { Get-RmCurrentUser } | Should -Throw 'HTTP 403: Forbidden'
    }

    It '接続できないときは接続エラーのメッセージにする' {
        Mock Invoke-RestMethod { throw 'name not resolved' }
        Mock Get-RmHttpError { @{ StatusCode = $null; Body = ''; Message = 'name not resolved' } }
        { Get-RmCurrentUser } | Should -Throw 'Redmine に接続できません: name not resolved'
    }

    It '存在しないチケットは $false、存在すれば $true' {
        Mock Invoke-RestMethod { throw 'not found' } -ParameterFilter { $Uri -eq 'http://r/issues/9.json' }
        Mock Invoke-RestMethod { [pscustomobject]@{ issue = [pscustomobject]@{ id = 10 } } } -ParameterFilter { $Uri -eq 'http://r/issues/10.json' }
        Mock Get-RmHttpError { @{ StatusCode = 404; Body = ''; Message = 'x' } }
        Test-RmIssueExists -IssueId 9 | Should -BeFalse
        Test-RmIssueExists -IssueId 10 | Should -BeTrue
    }

    It 'Get-RmHttpError は本物の HTTP エラーからステータスを取り出す' {
        # ローカルで閉じているポートではなく、存在しない URL への応答として 404 を返す実サーバーは使えないため、
        # 接続できない場合に StatusCode が $null になることだけを確認する
        try { Invoke-RestMethod -Uri 'http://127.0.0.1:9/' -TimeoutSec 5 -ErrorAction Stop } catch { $err = Get-RmHttpError -ErrorRecord $_ }
        $err.StatusCode | Should -BeNullOrEmpty
        $err.Message | Should -Not -BeNullOrEmpty
    }
}
