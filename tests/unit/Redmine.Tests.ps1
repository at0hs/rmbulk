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
