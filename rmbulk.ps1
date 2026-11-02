# rmbulk: CSV / Excel に書いたチケットを Redmine に一括登録する
param(
    [Parameter(Position = 0)][string]$Command,
    [Parameter(Position = 1)][string]$Target
)

foreach ($lib in 'Redmine', 'Input', 'Import') {
    $libPath = Join-Path $PSScriptRoot "lib\$lib.ps1"
    if (Test-Path $libPath) { . $libPath }
}

function Show-RmUsage {
    Write-Host @'
使い方:
  rmbulk setup                  # 接続設定とメタデータの取得
  rmbulk refresh                # メタデータだけを取り直す
  rmbulk template [<出力先>]    # 列名だけが入った CSV のひな形を出力する
  rmbulk import <ファイル>      # CSV / Excel を読み込み、確認したうえで登録する
'@
}

# dot-source されたとき（テスト）は関数の定義だけを読み込む
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($Command) {
    default {
        Show-RmUsage
        exit 1
    }
}
