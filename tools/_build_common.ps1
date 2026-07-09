# Общие константы и хелперы сборки EXE.
# Dot-source из ffmpeg/build_exe.ps1 и yt-dlp/build_exe.ps1 — SHA-пин ps2exe и версия
# определены здесь один раз (иначе при обновлении ps2exe/бампе версии легко забыть один файл).

$script:Ps2ExeSha    = 'FAEA495151AF69D2AE78783D0071186F98DC568D7B7478F639DA0E74ECF01763'  # PS2EXE @ MScholtes/PS2EXE d32d5ce
$script:Ps2ExeCommit = 'd32d5ce21c458696e860a7533943b1466d925be9'  # закреплённый commit ps2exe (провенанс)
$script:BuildVersion = '15.0.0.0'

# Проверяет наличие вендоренного ps2exe и совпадение SHA256 (supply-chain).
function Assert-Ps2Exe {
    param([string]$Ps2ExePath)
    if (-not (Test-Path $Ps2ExePath)) {
        Write-Host "ERROR: vendored ps2exe not found: $Ps2ExePath"
        exit 1
    }
    $actual = (Get-FileHash -Algorithm SHA256 $Ps2ExePath).Hash
    if ($actual -ne $script:Ps2ExeSha) {
        Write-Host "ERROR: ps2exe.ps1 SHA256 mismatch (expected $script:Ps2ExeSha, got $actual)"
        exit 1
    }
}

# Пишет sidecar-файл <exe>.sha256 (SHA256 + имя) — пользователь может сверить бинарь с источником.
function Write-ExeChecksum {
    param([string]$ExePath)
    if (Test-Path $ExePath) {
        $h = (Get-FileHash -Algorithm SHA256 $ExePath).Hash
        Set-Content -Path "$ExePath.sha256" -Value ("{0}  {1}" -f $h, (Split-Path $ExePath -Leaf)) -Encoding ASCII
        Write-Host "SHA256: $h"
    }
}
