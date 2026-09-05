$src      = Join-Path $PSScriptRoot 'Downloading_from_YouTube_v18.ps1'
$out      = Join-Path $PSScriptRoot '_VideoDownloader_v18.exe'
$tmpSrc   = Join-Path $PSScriptRoot '_build_tmp.ps1'
$ps2exePs = Join-Path $PSScriptRoot '..\tools\ps2exe.ps1'

# Общие константы (SHA-пин ps2exe + версия) и проверка — один источник на оба build-скрипта.
. (Join-Path $PSScriptRoot '../tools/_build_common.ps1')
Assert-Ps2Exe $ps2exePs

# Комментарии в бинарь не попадают: их текст входит в сумму признаков, по которой
# антивирус выносит вердикт (docs/knowledge-base.md; Remove-PsComments в
# tools/_build_common.ps1). Собираем из временной копии, исходник не трогаем.
Write-Host "Stripping comments for the packaged copy..."
[System.IO.File]::WriteAllText(
    $tmpSrc,
    (Remove-PsComments ([System.IO.File]::ReadAllText($src, [System.Text.Encoding]::UTF8))),
    (New-Object System.Text.UTF8Encoding $true))

Write-Host "Loading ps2exe function..."
. $ps2exePs

# Удаляем прежний EXE ДО сборки: иначе при падении Invoke-ps2exe остался бы старый
# файл и Test-Path ниже дал бы ложный SUCCESS.
Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue

Write-Host "Running Invoke-ps2exe..."
$ErrorActionPreference = 'Stop'
try {
    Invoke-ps2exe `
        -inputFile  $tmpSrc `
        -outputFile $out `
        -noConsole `
        -STA `
        -x64 `
        -title   "Video Downloader (yt-dlp) v18" `
        -version $script:BuildVersion
} catch {
    Write-Host "FAIL: $_"
    Remove-Item -LiteralPath $tmpSrc -Force -ErrorAction SilentlyContinue
    exit 1
}

Remove-Item -LiteralPath $tmpSrc -Force -ErrorAction SilentlyContinue

if (Test-Path -LiteralPath $out) {
    $size = [math]::Round((Get-Item -LiteralPath $out).Length / 1KB)
    Write-Host "SUCCESS: $out ($size KB)"
    Write-ExeChecksum $out
} else {
    Write-Host "FAILED: EXE not created"
    exit 1
}
