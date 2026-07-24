# check_release.ps1 — release hygiene helper для публичного репозитория.
#
#   .\tools\check_release.ps1              # тесты + сборка обоих EXE + манифест + сверка
#   .\tools\check_release.ps1 -SkipTests   # без прогона тестов
#   .\tools\check_release.ps1 -ManifestOnly # только (пере)генерация release-manifest.json
#
# Пишет release-manifest.json (провенанс: source commit, BuildVersion, ps2exe commit/SHA,
# SHA256 каждого артефакта) и сверяет .sha256 sidecar'ы с текущими EXE.
[CmdletBinding()]
param([switch]$ManifestOnly, [switch]$SkipTests)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_build_common.ps1')
$root = Split-Path -Parent $PSScriptRoot

$exes = @(
    @{ Path = 'ffmpeg/_VideoConverter_v16.exe';  Source = 'ffmpeg/FFmpeg_Converter_run_win_v16.ps1' },
    @{ Path = 'yt-dlp/_VideoDownloader_v16.exe'; Source = 'yt-dlp/Downloading_from_YouTube_v16.ps1' }
)
function Get-Sha256([string]$p) { (Get-FileHash -Algorithm SHA256 $p).Hash }

# Явно находит bash из Git for Windows. Голый `& bash` на Windows с установленным WSL
# резолвится в System32\bash.exe (WSL) — другое окружение: пути не транслируются, а
# STRICT_SKIP не отрабатывает как в CI, и release-проверка молча зеленеет с пропущенными
# CMD/PS1 suite'ами. Ищем msys-bash по расположению git.exe и стандартным путям установки.
function Resolve-GitBash {
    $cands = @()
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $d = Split-Path -Parent $git.Source   # <root>\cmd или <root>\bin
        $r = Split-Path -Parent $d            # <root>
        $cands += (Join-Path $r 'bin\bash.exe')
        $cands += (Join-Path $r 'usr\bin\bash.exe')
    }
    $cands += 'C:\Program Files\Git\bin\bash.exe'
    $cands += 'C:\Program Files (x86)\Git\bin\bash.exe'
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

Push-Location $root
try {
    # Провенанс считаем по состоянию ДО сборки: сборка меняет tracked EXE/манифест, и
    # `status` после неё ВСЕГДА грязный — вычисленный там dirty бессмыслен. Грязный ВХОД
    # (незакоммиченные правки исходников) делает провенанс недостоверным → отказ.
    $commit = ''
    try { $commit = (& git -C $root rev-parse HEAD 2>$null).Trim() } catch { $commit = 'unknown' }
    $dirty  = [bool](& git -C $root status --porcelain 2>$null)

    if (-not $ManifestOnly) {
        if ($dirty) { throw "рабочее дерево не чистое ДО сборки — зафиксируйте/уберите правки, иначе провенанс манифеста недостоверен" }
        if (-not $SkipTests) {
            Write-Host "== Тесты =="
            $bash = Resolve-GitBash
            if (-not $bash) {
                throw "Git-for-Windows bash не найден (голый bash резолвится в WSL — иное окружение, STRICT_SKIP не отработает). Установите Git for Windows."
            }
            # STRICT_SKIP=1 — как Windows CI: падаем, если ЦЕЛЫЙ CMD/PS1 suite пропущен
            # (cmd/powershell недоступны). Без него release-гейт слабее CI: частичный прогон
            # уходил бы зелёным. run_tests.sh вернёт rc=1 при полностью пропущенном suite'е.
            $env:STRICT_SKIP = '1'
            & $bash tests/run_tests.sh
            if ($LASTEXITCODE -ne 0) { throw "тесты провалены (rc=$LASTEXITCODE)" }
        }
        Write-Host "== Сборка EXE =="
        # После КАЖДОЙ сборки сразу проверяем $LASTEXITCODE: последовательные native-вызовы
        # иначе маскируют провал первой сборки успехом второй (rc второй перетирает rc первой).
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'ffmpeg/build_exe.ps1')
        if ($LASTEXITCODE -ne 0) { throw "сборка ffmpeg EXE провалена (rc=$LASTEXITCODE)" }
        & powershell -ExecutionPolicy Bypass -File (Join-Path $root 'yt-dlp/build_exe.ps1')
        if ($LASTEXITCODE -ne 0) { throw "сборка yt-dlp EXE провалена (rc=$LASTEXITCODE)" }
    }

    $artifacts = @()
    foreach ($e in $exes) {
        $full = Join-Path $root $e.Path
        if (-not (Test-Path $full)) { throw "не найден артефакт: $($e.Path)" }
        $sha = Get-Sha256 $full
        $sc = "$full.sha256"
        if (Test-Path $sc) {
            $want = ((Get-Content $sc -Raw) -split '\s+')[0]
            if ($want.ToUpper() -ne $sha.ToUpper()) {
                throw "sidecar не совпадает для $($e.Path): sidecar=$want факт=$sha"
            }
        } else {
            Write-Host "WARN: нет sidecar $($e.Path).sha256"
        }
        $artifacts += [ordered]@{ path = $e.Path; source = $e.Source; sha256 = $sha }
    }

    $manifest = [ordered]@{
        build_version = $script:BuildVersion
        source_commit = $commit
        source_tree_dirty = $dirty
        ps2exe = [ordered]@{ commit = $script:Ps2ExeCommit; sha256 = $script:Ps2ExeSha }
        artifacts = $artifacts
    }
    $manifestPath = Join-Path $root 'release-manifest.json'
    ($manifest | ConvertTo-Json -Depth 6) | Set-Content -Path $manifestPath -Encoding UTF8

    Write-Host ""
    Write-Host "release-manifest.json обновлён:"
    Write-Host "  BuildVersion : $($script:BuildVersion)"
    Write-Host "  ps2exe       : $($script:Ps2ExeCommit) ($($script:Ps2ExeSha.Substring(0,16))...)"
    Write-Host "  source commit: $commit"
    Write-Host "  tree dirty   : $dirty"
    foreach ($a in $artifacts) { Write-Host "  $($a.path) : $($a.sha256)" }
    if ($dirty) { Write-Host "ПРИМЕЧАНИЕ: рабочее дерево не чистое (ManifestOnly: провенанс отражает ГРЯЗНЫЙ вход)." }
}
finally {
    Pop-Location
}
