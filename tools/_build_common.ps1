# Общие константы и хелперы сборки EXE.
# Dot-source из ffmpeg/build_exe.ps1 и yt-dlp/build_exe.ps1 — SHA-пин ps2exe и версия
# определены здесь один раз (иначе при обновлении ps2exe/бампе версии легко забыть один файл).

$script:Ps2ExeSha    = 'E180C1264C131CAEDDFA37130A2F0EB826A3FFCA701B808DA3337689721FF45A'  # PS2EXE @ MScholtes/PS2EXE d32d5ce + локальный патч (экранирование метаданных для C#-литералов: \ " CR LF TAB)
$script:Ps2ExeCommit = 'd32d5ce21c458696e860a7533943b1466d925be9'  # закреплённый commit ps2exe (провенанс)
$script:BuildVersion = '17.0.0.0'

# Проверяет наличие вендоренного ps2exe и совпадение SHA256 (supply-chain).
function Assert-Ps2Exe {
    param([string]$Ps2ExePath)
    if (-not (Test-Path -LiteralPath $Ps2ExePath)) {
        Write-Host "ERROR: vendored ps2exe not found: $Ps2ExePath"
        exit 1
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Ps2ExePath).Hash
    if ($actual -ne $script:Ps2ExeSha) {
        Write-Host "ERROR: ps2exe.ps1 SHA256 mismatch (expected $script:Ps2ExeSha, got $actual)"
        exit 1
    }
}

# Пишет sidecar-файл <exe>.sha256 (SHA256 + имя) — пользователь может сверить бинарь с источником.
function Write-ExeChecksum {
    param([string]$ExePath)
    if (Test-Path -LiteralPath $ExePath) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExePath).Hash
        Set-Content -LiteralPath "$ExePath.sha256" -Value ("{0}  {1}" -f $h, (Split-Path $ExePath -Leaf)) -Encoding ASCII
        Write-Host "SHA256: $h"
    }
}
