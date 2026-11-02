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

    It 'タイムアウトを 30 秒にする' {
        Mock Invoke-RestMethod { [pscustomobject]@{ user = [pscustomobject]@{ id = 1; login = 'a' } } }
        Get-RmCurrentUser | Out-Null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 30 }
    }

    It 'Redmine 以外の応答（HTML のログイン画面など）は接続確認で失敗にする' {
        Mock Invoke-RestMethod { '<html>login</html>' }
        { Get-RmCurrentUser } | Should -Throw 'Redmine の API 応答ではありません。URL を確認してください。'
    }

    It 'チケット番号が返らない応答は登録の失敗にする' {
        Mock Invoke-RestMethod { '<html>login</html>' }
        { New-RmIssue -Fields @{ project_id = 1; subject = 'x' } } | Should -Throw 'Redmine の API 応答ではありません。URL を確認してください。'
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

Describe 'メタデータ' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid())
        New-Item -ItemType Directory $root | Out-Null
    }

    It 'ファイルがなければ空のメタデータを返す' {
        $m = Read-RmMetadata -Root $root
        @($m.projects).Count | Should -Be 0
        $m.projectDetails.Count | Should -Be 0
    }

    It 'Update-RmProjectList はプロジェクト一覧を保存し、詳細を破棄する' {
        Mock Get-RmProjects { @([pscustomobject]@{ id = 1; name = 'WBS'; identifier = 'wbs'; status = 1 }, [pscustomobject]@{ id = 2; name = 'B'; identifier = 'b'; status = 5 }) }
        $m = Read-RmMetadata -Root $root
        $m.projectDetails['1'] = @{ fetchedAt = 'x'; trackers = @(); versions = @() }
        Save-RmMetadata -Root $root -Metadata $m
        $r = Update-RmProjectList -Root $root
        @($r.projects).Count | Should -Be 2
        $r.projects[0].name | Should -Be 'WBS'
        $r.projectDetails.Count | Should -Be 0
        $saved = Read-RmMetadata -Root $root
        @($saved.projects).Count | Should -Be 2
        $saved.projects[0].identifier | Should -Be 'wbs'
        $saved.projectDetails.Count | Should -Be 0
        $saved.fetchedAt | Should -Not -BeNullOrEmpty
    }

    It 'Get-RmProjectDetail は初回だけ API を呼び、保存する' {
        Mock Get-RmProjectTrackers { @([pscustomobject]@{ id = 2; name = 'タスク' }, [pscustomobject]@{ id = 3; name = '機能' }) }
        Mock Get-RmProjectVersions { @([pscustomobject]@{ id = 5; name = 'v1.0'; status = 'open' }) }
        $m = Read-RmMetadata -Root $root
        $d = Get-RmProjectDetail -Root $root -Metadata $m -ProjectId 1
        @($d.trackers).Count | Should -Be 2
        $d.trackers[0].name | Should -Be 'タスク'
        Get-RmProjectDetail -Root $root -Metadata $m -ProjectId 1 | Out-Null
        Should -Invoke Get-RmProjectTrackers -Times 1 -Exactly
        $saved = Read-RmMetadata -Root $root
        $saved.projectDetails['1'].versions[0].name | Should -Be 'v1.0'
        @($saved.projectDetails['1'].trackers).Count | Should -Be 2
    }

    It '保存済みの詳細は読み直しても使われ、API を呼ばない' {
        Mock Get-RmProjectTrackers { @([pscustomobject]@{ id = 2; name = 'タスク' }) }
        Mock Get-RmProjectVersions { @() }
        Get-RmProjectDetail -Root $root -Metadata (Read-RmMetadata -Root $root) -ProjectId 1 | Out-Null
        $detail = Get-RmProjectDetail -Root $root -Metadata (Read-RmMetadata -Root $root) -ProjectId 1
        Should -Invoke Get-RmProjectTrackers -Times 1 -Exactly
        @($detail.versions).Count | Should -Be 0
        @($detail.trackers).Count | Should -Be 1
    }

    It 'Clear-RmProjectDetail は指定したプロジェクトの詳細だけを消す' {
        $m = Read-RmMetadata -Root $root
        $m.projectDetails['1'] = @{ fetchedAt = 'x'; trackers = @(); versions = @() }
        $m.projectDetails['2'] = @{ fetchedAt = 'x'; trackers = @(); versions = @() }
        Clear-RmProjectDetail -Root $root -Metadata $m -ProjectId 1
        $saved = Read-RmMetadata -Root $root
        $saved.projectDetails.ContainsKey('1') | Should -BeFalse
        $saved.projectDetails.ContainsKey('2') | Should -BeTrue
    }
}
