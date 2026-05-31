$src      = Join-Path $PSScriptRoot 'Downloading_from_YouTube_v14.ps1'
$out      = Join-Path $PSScriptRoot '_VideoDownloader_v14.exe'
$ps2exePs = Join-Path $PSScriptRoot 'ps2exe_tool.ps1'

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $ps2exePs)) {
    Write-Host "Downloading ps2exe..."
    try {
        Invoke-WebRequest `
            -Uri     'https://raw.githubusercontent.com/MScholtes/PS2EXE/master/Module/ps2exe.ps1' `
            -OutFile $ps2exePs `
            -Proxy   $env:HTTPS_PROXY
    } catch {
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/MScholtes/PS2EXE/master/Module/ps2exe.ps1' -OutFile $ps2exePs
    }
    Write-Host "Downloaded: $((Get-Item $ps2exePs).Length) bytes"
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
    Remove-Item $ps2exePs -Force -ErrorAction SilentlyContinue
} else {
    Write-Host "FAILED: EXE not created"
    exit 1
}
