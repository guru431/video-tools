#!/bin/bash
# ============================================================
# test_06_ps1.sh — Тест PS1 yt-dlp GUI.
#
# Две части:
#   A. Source-контракт (grep по исходнику) — не требует PowerShell, идёт всегда.
#   B. Реальные функции/таблицы — дот-сорсим PRODUCTION-скрипт с $env:YTDLP_TEST=1
#      (guard выходит до построения GUI) и проверяем настоящие Read-Config,
#      Get-Platform, $qualityMap, $formatPresets, $simpleBest, Quote-WinArg.
#      Раньше здесь были inline-КОПИИ таблиц/функций, разошедшиеся с production
#      (finding: тест зеленел на устаревших значениях). Теперь источник один.
#      Требует WinForms (скрипт делает Add-Type в шапке) → только Windows PS.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"

source "$TESTS_DIR/lib/framework.sh"

get_field() {
    local output="$1" field="$2"
    printf '%s\n' "$output" | grep "^${field}=" | sed "s/^${field}=//"
}

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: source-контракт (рефакторинг argv/таблиц)"
# ══════════════════════════════════════════════════════════════
src="$(cat "$DLP_PS1")"

# Единый argv-квотер вместо ручных кавычек/`-join " "`.
assert_contains "Quote-WinArg определён"          "function Quote-WinArg"          "$src"
assert_contains "Join-WinArgs определён"          "function Join-WinArgs"          "$src"
assert_contains "psi.Arguments из \$cmdLine"      '$psi.Arguments              = $cmdLine' "$src"
assert_contains "vot Arguments через Join-WinArgs" 'Join-WinArgs $votArgs'         "$src"
assert_not_contains "нет ручного join для argv"   '$command -join " "'             "$src"
# Таблицы форматов вынесены в script scope (один источник истины) — присваивание
# $formatPresets/$simpleBest не должно повторяться внутри Add_Click.
fp_cnt=$(grep -cF '$formatPresets = @{' "$DLP_PS1")
assert_eq "formatPresets определён 1 раз (script scope)"  "1"  "$fp_cnt"
sb_cnt=$(grep -cF '$simpleBest = @(' "$DLP_PS1")
assert_eq "simpleBest определён 1 раз (script scope)"     "1"  "$sb_cnt"
assert_contains "тестовый guard (YTDLP_TEST)"     "if (\$env:YTDLP_TEST -eq '1') { return }" "$src"
assert_contains "config override (YTDLP_CONFIG)"  'if ($env:YTDLP_CONFIG)'         "$src"
# F9: ffmpeg резолвится рядом со скриптом, не только PATH.
assert_contains "ffmpeg резолвер \$ffmpegBin"     '$ffmpegLocal = Join-Path $scriptDir "ffmpeg.exe"' "$src"
assert_contains "мерж через \$ffmpegBin"          '& $ffmpegBin @ffArgs'           "$src"

# Существующие инварианты GUI (перенесены из прошлой версии).
assert_not_contains "нет массового Stop-Process yt-dlp"  'Get-Process -Name "yt-dlp"'  "$src"
null_cnt=$(grep -cF '$global:downloadProcess = $null' "$DLP_PS1")
assert_eq "downloadProcess обнуляется только в init"  "1"  "$null_cnt"
assert_contains "guard перед WaitForExit"  'if ($proc) { $proc.WaitForExit(); $exitCode = $proc.ExitCode }'  "$src"
assert_contains "merge: проверка LASTEXITCODE"  '$LASTEXITCODE -eq 0 -and (Test-Path $outputFile)'  "$src"
assert_contains "vot stderr ReadToEndAsync (нет deadlock)"  "ReadToEndAsync()"  "$src"
assert_contains "qualityMap audio=0"  '"audio" = 0'  "$src"
assert_contains "translate исключает audio (qi>=1)"  '$qi -ge 1 -and $qi -le 6'  "$src"
assert_not_contains "нет --no-check-certificate"  "--no-check-certificate"  "$src"
assert_contains "--download-archive из config"  "--download-archive"  "$src"
assert_contains "mix громкости из config"  'volume=$cfg_transOrigVol'  "$src"
assert_contains "Unregister-Event (утечка событий)"  "Unregister-Event"  "$src"
assert_contains "btnRemoveUrl дизейблится при загрузке"  '$btnRemoveUrl.Enabled = $false'  "$src"
assert_contains "base_dir от scriptDir"  'Combine($scriptDir, $cfg_baseDir)'  "$src"

# ══════════════════════════════════════════════════════════════
# Часть B — реальные функции. Требует Windows PowerShell + WinForms.
# ══════════════════════════════════════════════════════════════
PS_CMD=""
command -v powershell &>/dev/null && PS_CMD="powershell"
[ -z "$PS_CMD" ] && command -v pwsh &>/dev/null && PS_CMD="pwsh"

winforms_ok=0
if [ -n "$PS_CMD" ]; then
    probe=$($PS_CMD -NoProfile -NonInteractive -Command "try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; 'ok' } catch { 'no' }" 2>/dev/null | tr -d '\r')
    [ "$probe" = "ok" ] && winforms_ok=1
fi

if [ "$winforms_ok" -ne 1 ]; then
    suite "PS1 yt-dlp: реальные функции (dot-source production)"
    skip "Read-Config/Get-Platform/formatPresets/Quote-WinArg" "нет Windows PowerShell + WinForms"
    summary
    exit $?
fi

win_prod=$(cygpath -w "$DLP_PS1" 2>/dev/null || echo "$DLP_PS1")

# Временный config.ini для проверки production Read-Config (кэш + подстановка ${ENV}).
tmpcfg=$(mktemp /tmp/test_ytps1_cfg_XXXXXX.ini)
cat > "$tmpcfg" << 'INIEOF'
[proxy]
url = ${TEST_PROXY_VAR}
[cookies]
method = browser
[download]
default_quality = 1080
[translation]
enabled = true
target_lang = ru
INIEOF
win_cfg=$(cygpath -w "$tmpcfg" 2>/dev/null || echo "$tmpcfg")

# Harness: дот-сорсит production, печатает KEY=VALUE. Пишем во временный .ps1,
# чтобы не бороться с bash-экранированием кавычек/скобок.
harness=$(mktemp /tmp/test_ytps1_harness_XXXXXX.ps1)
win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
cat > "$harness" << 'PS1EOF'
param([string]$Prod, [string]$Cfg)
$ErrorActionPreference = 'Stop'
$env:YTDLP_TEST = '1'
$env:YTDLP_CONFIG = $Cfg
$env:TEST_PROXY_VAR = 'http://sub.example.com:3128'
. $Prod

# Read-Config (production: кэш + подстановка ${ENV})
Write-Output ("rc_proxy=" + (Read-Config 'url' 'proxy' ''))
Write-Output ("rc_method=" + (Read-Config 'method' 'cookies' 'none'))
Write-Output ("rc_quality=" + (Read-Config 'default_quality' 'download' '720'))
Write-Output ("rc_default=" + (Read-Config 'nonexistent' 'proxy' 'my_default'))
Write-Output ("rc_transen=" + (Read-Config 'enabled' 'translation' 'false'))

# Get-Platform (production: якорь по границе домена)
Write-Output ("plat_yt=" + (Get-Platform 'https://www.youtube.com/watch?v=abc123'))
Write-Output ("plat_short=" + (Get-Platform 'https://youtu.be/abc123'))
Write-Output ("plat_rt=" + (Get-Platform 'https://rutube.ru/video/abc'))
Write-Output ("plat_vk=" + (Get-Platform 'https://vk.com/video123'))
Write-Output ("plat_tw=" + (Get-Platform 'https://twitch.tv/somestream'))
Write-Output ("plat_vm=" + (Get-Platform 'https://vimeo.com/123456'))
Write-Output ("plat_other=" + (Get-Platform 'https://example.com/video.mp4'))
Write-Output ("plat_notyt=" + (Get-Platform 'https://notyoutube.com/watch'))

# qualityMap → defaultQualityIdx
foreach ($q in @('audio','720','360','480','1080','1440','2160','xxx','')) {
    $idx = if ($qualityMap.ContainsKey($q)) { $qualityMap[$q] } else { 3 }
    Write-Output ("qm_${q}=" + $idx)
}

# formatPresets (реальные значения таблицы)
Write-Output ("fp_best_0=" + $formatPresets['avc1_best'][0])
Write-Output ("fp_best_3=" + $formatPresets['avc1_best'][3])
Write-Output ("fp_https_0=" + $formatPresets['avc1_https'][0])
Write-Output ("fp_https_3=" + $formatPresets['avc1_https'][3])
Write-Output ("fp_https_6=" + $formatPresets['avc1_https'][6])
Write-Output ("fp_m3u8_3=" + $formatPresets['avc1_m3u8'][3])
Write-Output ("fp_60fps_3=" + $formatPresets['avc1_https_60fps'][3])
Write-Output ("fp_m3u860_4=" + $formatPresets['avc1_m3u8_60fps'][4])
Write-Output ("fp_hdr_3=" + $formatPresets['avc1_https_60fps_hdr'][3])
Write-Output ("fp_old_0=" + $formatPresets['old_combo'][0])
Write-Output ("fp_old_3=" + $formatPresets['old_combo'][3])
Write-Output ("fp_old_6=" + $formatPresets['old_combo'][6])
Write-Output ("sb_3=" + $simpleBest[3])

# Quote-WinArg (CommandLineToArgvW)
Write-Output ("qa_plain=" + (Quote-WinArg 'best[height<=720]/best'))
Write-Output ("qa_space=" + (Quote-WinArg 'a b'))
Write-Output ("qa_quote=" + (Quote-WinArg 'a"b'))
Write-Output ("qa_empty=" + (Quote-WinArg ''))
Write-Output ("qa_pathsp=" + (Quote-WinArg 'C:\dir with space\f.txt'))
Write-Output ("qa_tailbs=" + (Quote-WinArg 'a b\'))
PS1EOF

out=$($PS_CMD -NoProfile -NonInteractive -File "$win_harness" -Prod "$win_prod" -Cfg "$win_cfg" 2>/dev/null | tr -d '\r')
rm -f "$tmpcfg" "$harness"

# ── Read-Config ───────────────────────────────────────────────
suite "PS1 yt-dlp: Read-Config (production, кэш + \${ENV})"
assert_eq "proxy url = подстановка \${TEST_PROXY_VAR}"  "http://sub.example.com:3128"  "$(get_field "$out" rc_proxy)"
assert_eq "cookies method"                             "browser"                      "$(get_field "$out" rc_method)"
assert_eq "default_quality"                            "1080"                         "$(get_field "$out" rc_quality)"
assert_eq "нет ключа → default"                        "my_default"                   "$(get_field "$out" rc_default)"
assert_eq "translation enabled"                        "true"                         "$(get_field "$out" rc_transen)"

# ── Get-Platform ──────────────────────────────────────────────
suite "PS1 yt-dlp: Get-Platform (production, якорь границы)"
assert_eq "youtube.com → YouTube"   "YouTube"     "$(get_field "$out" plat_yt)"
assert_eq "youtu.be → YouTube"      "YouTube"     "$(get_field "$out" plat_short)"
assert_eq "rutube.ru → RuTube"      "RuTube"      "$(get_field "$out" plat_rt)"
assert_eq "vk.com → VK Video"       "VK Video"    "$(get_field "$out" plat_vk)"
assert_eq "twitch.tv → Twitch"      "Twitch"      "$(get_field "$out" plat_tw)"
assert_eq "vimeo.com → Vimeo"       "Vimeo"       "$(get_field "$out" plat_vm)"
assert_eq "example.com → Video"     "Video"       "$(get_field "$out" plat_other)"
assert_eq "notyoutube.com → Video (граница!)"  "Video"  "$(get_field "$out" plat_notyt)"

# ── qualityMap ────────────────────────────────────────────────
suite "PS1 yt-dlp: qualityMap → defaultQualityIdx (production)"
assert_eq "audio → 0"   "0"  "$(get_field "$out" qm_audio)"
assert_eq "720 → 3"     "3"  "$(get_field "$out" qm_720)"
assert_eq "360 → 1"     "1"  "$(get_field "$out" qm_360)"
assert_eq "480 → 2"     "2"  "$(get_field "$out" qm_480)"
assert_eq "1080 → 4"    "4"  "$(get_field "$out" qm_1080)"
assert_eq "1440 → 5"    "5"  "$(get_field "$out" qm_1440)"
assert_eq "2160 → 6"    "6"  "$(get_field "$out" qm_2160)"
assert_eq "xxx → 3 (default)"  "3"  "$(get_field "$out" qm_xxx)"
assert_eq "'' → 3 (default)"   "3"  "$(get_field "$out" qm_)"

# ── formatPresets / simpleBest ────────────────────────────────
suite "PS1 yt-dlp: formatPresets/simpleBest (production, не inline-копия)"
assert_contains "avc1_best[0] → bestaudio"        "bestaudio[ext!=webm]"  "$(get_field "$out" fp_best_0)"
assert_eq "avc1_best[3] (720p)"   "bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]"  "$(get_field "$out" fp_best_3)"
assert_eq "avc1_https[0]"         "140"                "$(get_field "$out" fp_https_0)"
assert_eq "avc1_https[3]"         "140+136/135/134"    "$(get_field "$out" fp_https_3)"
assert_contains "avc1_https[6] (не битый 139)"  "140+266"  "$(get_field "$out" fp_https_6)"
assert_eq "avc1_m3u8[3]"          "234+232/231/230"    "$(get_field "$out" fp_m3u8_3)"
assert_eq "avc1_https_60fps[3] (production=140+298)"  "140+298/best[height<=720]"  "$(get_field "$out" fp_60fps_3)"
assert_contains "avc1_m3u8_60fps[4]"  "234+312/311/310/309"  "$(get_field "$out" fp_m3u860_4)"
assert_contains "avc1_https_60fps_hdr[3]"  "234+698/697/696"  "$(get_field "$out" fp_hdr_3)"
assert_eq "old_combo[0]"          "140"                "$(get_field "$out" fp_old_0)"
assert_eq "old_combo[3]"          "22/18"              "$(get_field "$out" fp_old_3)"
assert_eq "old_combo[6]"          "38/37/22/18"        "$(get_field "$out" fp_old_6)"
assert_eq "simpleBest[3]"         "best[height<=720]/best"  "$(get_field "$out" sb_3)"

# ── Quote-WinArg ──────────────────────────────────────────────
suite "PS1 yt-dlp: Quote-WinArg (CommandLineToArgvW)"
assert_eq "без пробела/кавычки → без изменений"  "best[height<=720]/best"  "$(get_field "$out" qa_plain)"
assert_eq "пробел → в кавычках"    '"a b"'         "$(get_field "$out" qa_space)"
assert_eq "кавычка → \\\" внутри"  '"a\"b"'        "$(get_field "$out" qa_quote)"
assert_eq "пустой → \"\""          '""'            "$(get_field "$out" qa_empty)"
assert_eq "путь с пробелом"        '"C:\dir with space\f.txt"'  "$(get_field "$out" qa_pathsp)"
assert_eq "хвостовой \\ удвоен перед кавычкой"  '"a b\\"'  "$(get_field "$out" qa_tailbs)"

summary
