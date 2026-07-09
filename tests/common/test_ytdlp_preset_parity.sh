#!/bin/bash
# ============================================================
# test_ytdlp_preset_parity.sh — паритет таблиц форматов yt-dlp между SH и PS1.
# Один набор inputs (preset × quality) → сравниваем итоговую format-строку:
#   SH  = реальная build_format_args (dot-source production .sh, main гардится),
#   PS1 = реальный $formatPresets/$simpleBest (dot-source production .ps1, YTDLP_TEST).
# Обе стороны — из production, не inline-копии: расхождение SH↔PS1 = провал.
# Требует WinForms (PS1-шапка Add-Type) → сравнение только на Windows PS.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"

PRESETS="avc1_best avc1_https avc1_m3u8 avc1_https_60fps avc1_m3u8_60fps avc1_https_60fps_hdr old_combo"
# idx 0..6 ↔ имена качества
QNAMES=(audio 360 480 720 1080 1440 2160)

PS_CMD=""
command -v powershell &>/dev/null && PS_CMD="powershell"
[ -z "$PS_CMD" ] && command -v pwsh &>/dev/null && PS_CMD="pwsh"
winforms_ok=0
if [ -n "$PS_CMD" ]; then
    probe=$($PS_CMD -NoProfile -NonInteractive -Command "try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; 'ok' } catch { 'no' }" 2>/dev/null | tr -d '\r')
    [ "$probe" = "ok" ] && winforms_ok=1
fi

if [ "$winforms_ok" -ne 1 ]; then
    suite "yt-dlp preset parity (SH ↔ PS1)"
    skip "сравнение таблиц форматов" "нет Windows PowerShell + WinForms (нужна PS1-сторона)"
    summary
    exit $?
fi

# ── SH-сторона: реальная build_format_args ────────────────────────────────
# platform=youtube → auto не срабатывает, используется явный preset.
sh_out=$(
    source "$YT_SH"
    for p in $PRESETS; do
        i=0
        for q in audio 360 480 720 1080 1440 2160; do
            FMT_ARGS_ARR=()
            build_format_args "$q" "$p" "youtube"
            echo "sh_${p}_${i}=${FMT_ARGS_ARR[1]}"
            i=$((i+1))
        done
    done
    # simpleBest: auto + не-youtube платформа
    i=0
    for q in audio 360 480 720 1080 1440 2160; do
        FMT_ARGS_ARR=()
        build_format_args "$q" "auto" "vk"
        echo "sh_sb_${i}=${FMT_ARGS_ARR[1]}"
        i=$((i+1))
    done
)

# ── PS1-сторона: реальные $formatPresets/$simpleBest ──────────────────────
win_prod=$(cygpath -w "$YT_PS1" 2>/dev/null || echo "$YT_PS1")
harness=$(mktemp /tmp/test_parity_XXXXXX.ps1)
win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
cat > "$harness" << 'PS1EOF'
param([string]$Prod)
$ErrorActionPreference = 'Stop'
$env:YTDLP_TEST = '1'
. $Prod
foreach ($p in @('avc1_best','avc1_https','avc1_m3u8','avc1_https_60fps','avc1_m3u8_60fps','avc1_https_60fps_hdr','old_combo')) {
    for ($i = 0; $i -lt 7; $i++) { Write-Output ("ps_${p}_${i}=" + $formatPresets[$p][$i]) }
}
for ($i = 0; $i -lt 7; $i++) { Write-Output ("ps_sb_${i}=" + $simpleBest[$i]) }
PS1EOF
ps_out=$($PS_CMD -NoProfile -NonInteractive -File "$win_harness" -Prod "$win_prod" 2>/dev/null | tr -d '\r')
rm -f "$harness"

get_field() { printf '%s\n' "$1" | grep "^${2}=" | sed "s/^${2}=//"; }

# ── Сравнение ─────────────────────────────────────────────────────────────
suite "yt-dlp preset parity: $PRESETS × [audio..2160]"
for p in $PRESETS; do
    for i in 0 1 2 3 4 5 6; do
        sh_v=$(get_field "$sh_out" "sh_${p}_${i}")
        ps_v=$(get_field "$ps_out" "ps_${p}_${i}")
        assert_eq "$p[${QNAMES[$i]}] SH==PS1"  "$sh_v"  "$ps_v"
    done
done
suite "yt-dlp preset parity: simpleBest (auto, не-YouTube)"
for i in 0 1 2 3 4 5 6; do
    sh_v=$(get_field "$sh_out" "sh_sb_${i}")
    ps_v=$(get_field "$ps_out" "ps_sb_${i}")
    assert_eq "simpleBest[${QNAMES[$i]}] SH==PS1"  "$sh_v"  "$ps_v"
done

summary
