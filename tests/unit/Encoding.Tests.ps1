Describe 'ソースファイルの文字コード' {
    It '<_> は UTF-8 BOM 付き（PowerShell 5.1 が日本語を正しく読むため）' -ForEach @(
        Get-ChildItem (Join-Path $PSScriptRoot '..\..') -Recurse -Filter *.ps1 |
            Where-Object { $_.FullName -notlike '*.superpowers*' } |
            ForEach-Object { $_.FullName }
    ) {
        $bytes = [IO.File]::ReadAllBytes($_)
        ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue
    }
}
