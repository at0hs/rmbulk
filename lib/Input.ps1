# CSV / Excel の読み込みと行オブジェクトへの変換

Add-Type -AssemblyName Microsoft.VisualBasic

$script:RmColumns = [ordered]@{
    '仮番号'         = 'TempId'
    'プロジェクト'   = 'Project'
    'トラッカー'     = 'Tracker'
    '題名'           = 'Subject'
    '説明'           = 'Description'
    '開始日'         = 'StartDate'
    '期日'           = 'DueDate'
    '対象バージョン' = 'Version'
    '親チケット'     = 'Parent'
}
$script:RmRequiredColumns = @('プロジェクト', 'トラッカー', '題名', '開始日', '期日', '対象バージョン')

function Read-RmInputFile {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "ファイルが見つかりません: $Path" }
    $fullPath = (Resolve-Path -LiteralPath $Path).Path
    $table = switch ([IO.Path]::GetExtension($fullPath).ToLowerInvariant()) {
        '.csv' { Read-RmCsvTable -Path $fullPath }
        { $_ -in '.xlsx', '.xls' } { Read-RmExcelTable -Path $fullPath }
        default { throw "ファイル形式に対応していません（.csv / .xlsx / .xls のみ）: $Path" }
    }
    ConvertTo-RmInputRows -Headers $table.Headers -Records $table.Records
}

function Get-RmCsvText {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    }
    try {
        # 不正なバイトがあれば例外になる UTF-8 で読み、だめなら Shift-JIS とみなす
        (New-Object Text.UTF8Encoding $false, $true).GetString($bytes)
    } catch {
        [Text.Encoding]::GetEncoding(932).GetString($bytes)
    }
}

function Read-RmCsvTable {
    param([Parameter(Mandatory)][string]$Path)
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser (New-Object IO.StringReader (Get-RmCsvText -Path $Path))
    try {
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters(',')
        $parser.HasFieldsEnclosedInQuotes = $true
        $parser.TrimWhiteSpace = $false

        $headers = @()
        if (-not $parser.EndOfData) { $headers = @($parser.ReadFields()) }
        $records = @()
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            $record = @{}
            for ($i = 0; $i -lt $headers.Count; $i++) {
                $record[$headers[$i]] = if ($i -lt $fields.Count) { [string]$fields[$i] } else { '' }
            }
            $records += $record
        }
    } finally {
        $parser.Close()
    }
    @{ Headers = $headers; Records = $records }
}

function ConvertTo-RmInputRows {
    param([string[]]$Headers = @(), [object[]]$Records = @())
    $warnings = @()
    $trimmedHeaders = @($Headers | ForEach-Object { ([string]$_).Trim() })

    $missing = @($script:RmRequiredColumns | Where-Object { $trimmedHeaders -notcontains $_ })
    if ($missing.Count -gt 0) { throw "必須の列がありません: $($missing -join ', ')" }
    foreach ($h in $trimmedHeaders) {
        if ($h -ne '' -and -not $script:RmColumns.Contains($h)) { $warnings += "不明な列を無視します: $h" }
    }

    $rows = @()
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $record = $Records[$i]
        $row = [ordered]@{ RowNumber = $i + 2 }
        foreach ($column in $script:RmColumns.Keys) { $row[$script:RmColumns[$column]] = '' }
        $hasValue = $false
        for ($c = 0; $c -lt $Headers.Count; $c++) {
            $value = ([string]$record[$Headers[$c]]).Trim()
            if ($value -ne '') { $hasValue = $true }
            $name = $trimmedHeaders[$c]
            if ($script:RmColumns.Contains($name)) { $row[$script:RmColumns[$name]] = $value }
        }
        if ($hasValue) { $rows += [pscustomobject]$row }
    }
    @{ Rows = $rows; Warnings = $warnings }
}

function Convert-RmExcelCell {
    param($Value, [string]$Column)
    if ($null -eq $Value) { return '' }
    if ($Value -is [double]) {
        if ($Column -in '開始日', '期日') { return [DateTime]::FromOADate($Value).ToString('yyyy-MM-dd') }
        if ($Value -eq [Math]::Truncate($Value)) { return ([long]$Value).ToString() }
        return $Value.ToString([Globalization.CultureInfo]::InvariantCulture)
    }
    [string]$Value
}

# UsedRange.Value2（下限 1 の 2 次元配列、セルが1つならスカラー）を列名と行に分ける
function ConvertFrom-RmExcelValues {
    param($Values)
    if ($null -eq $Values) { return @{ Headers = @(); Records = @() } }
    if ($Values -isnot [Array]) {
        $one = [Array]::CreateInstance([object], [int[]]@(1, 1), [int[]]@(1, 1))
        $one.SetValue($Values, 1, 1)
        $Values = $one
    }
    $r0 = $Values.GetLowerBound(0); $r1 = $Values.GetUpperBound(0)
    $c0 = $Values.GetLowerBound(1); $c1 = $Values.GetUpperBound(1)

    $headers = @()
    for ($c = $c0; $c -le $c1; $c++) { $headers += (Convert-RmExcelCell -Value $Values[$r0, $c] -Column '').Trim() }
    $records = @()
    for ($r = $r0 + 1; $r -le $r1; $r++) {
        $record = @{}
        for ($c = $c0; $c -le $c1; $c++) {
            $header = $headers[$c - $c0]
            $record[$header] = Convert-RmExcelCell -Value $Values[$r, $c] -Column $header
        }
        $records += $record
    }
    @{ Headers = $headers; Records = $records }
}

function Read-RmExcelTable {
    param([Parameter(Mandatory)][string]$Path)
    $excel = $null; $books = $null; $book = $null; $sheets = $null; $sheet = $null; $range = $null
    try {
        try {
            $excel = New-Object -ComObject Excel.Application
        } catch {
            throw "Excel を起動できません。Excel がインストールされているか確認してください: $($_.Exception.Message)"
        }
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $books = $excel.Workbooks
        $book = $books.Open($Path, 0, $true)
        $sheets = $book.Worksheets
        $sheet = $sheets.Item(1)
        $range = $sheet.UsedRange
        $values = $range.Value2
    } finally {
        if ($book) { $book.Close($false) }
        if ($excel) { $excel.Quit() }
        foreach ($obj in $range, $sheet, $sheets, $book, $books, $excel) {
            if ($obj) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($obj) }
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
    ConvertFrom-RmExcelValues -Values $values
}
