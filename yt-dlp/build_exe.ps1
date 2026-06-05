$src      = Join-Path $PSScriptRoot 'Downloading_from_YouTube_v14.ps1'
$out      = Join-Path $PSScriptRoot '_VideoDownloader_v14.exe'
$ps2exePs = Join-Path $PSScriptRoot '..\tools\ps2exe.ps1'
$ps2exeSha = 'FAEA495151AF69D2AE78783D0071186F98DC568D7B7478F639DA0E74ECF01763'  # PS2EXE @ MScholtes/PS2EXE d32d5ce

# ps2exe вендорится в репозитории (tools/ps2exe.ps1) и не качается на лету:
# pin на коммит d32d5ce + проверка SHA256 перед dot-source (supply-chain).
if (-not (Test-Path $ps2exePs)) {
    Write-Host "ERROR: vendored ps2exe not found: $ps2exePs"
    exit 1
}
$ps2exeActual = (Get-FileHash -Algorithm SHA256 $ps2exePs).Hash
if ($ps2exeActual -ne $ps2exeSha) {
    Write-Host "ERROR: ps2exe.ps1 SHA256 mismatch (expected $ps2exeSha, got $ps2exeActual)"
    exit 1
}

Write-Host "Loading ps2exe function..."
. $ps2exePs

Write-Host "Running Invoke-ps2exe..."
Invoke-ps2exe `
    -inputFile  $src `
    -outputFile $out `
    -noConsole `
    -STA `
    -x64 `
    -title   "Video Downloader (yt-dlp) v14" `
    -version "14.0.0.0"

if (Test-Path $out) {
    $size = [math]::Round((Get-Item $out).Length / 1KB)
    Write-Host "SUCCESS: $out ($size KB)"
} else {
    Write-Host "FAILED: EXE not created"
    exit 1
}
