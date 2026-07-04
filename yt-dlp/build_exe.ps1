$src      = Join-Path $PSScriptRoot 'Downloading_from_YouTube_v15.ps1'
$out      = Join-Path $PSScriptRoot '_VideoDownloader_v15.exe'
$ps2exePs = Join-Path $PSScriptRoot '..\tools\ps2exe.ps1'

# Общие константы (SHA-пин ps2exe + версия) и проверка — один источник на оба build-скрипта.
. (Join-Path $PSScriptRoot '../tools/_build_common.ps1')
Assert-Ps2Exe $ps2exePs

Write-Host "Loading ps2exe function..."
. $ps2exePs

# Удаляем прежний EXE ДО сборки: иначе при падении Invoke-ps2exe остался бы старый
# файл и Test-Path ниже дал бы ложный SUCCESS.
Remove-Item $out -Force -ErrorAction SilentlyContinue

Write-Host "Running Invoke-ps2exe..."
$ErrorActionPreference = 'Stop'
try {
    Invoke-ps2exe `
        -inputFile  $src `
        -outputFile $out `
        -noConsole `
        -STA `
        -x64 `
        -title   "Video Downloader (yt-dlp) v15" `
        -version $script:BuildVersion
} catch {
    Write-Host "FAIL: $_"
    exit 1
}

if (Test-Path $out) {
    $size = [math]::Round((Get-Item $out).Length / 1KB)
    Write-Host "SUCCESS: $out ($size KB)"
    Write-ExeChecksum $out
} else {
    Write-Host "FAILED: EXE not created"
    exit 1
}
