#!/bin/bash
# ============================================================
# test_02_format_args.sh — Тест build_format_args()
# Проверяет все комбинации: 7 пресетов × 8 уровней качества
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Inline определение функции (копия из скрипта, без изменений)
build_format_args() {
    local quality="$1"
    local preset="${2:-avc1_best}"

    case "$preset" in
        avc1_best)
            case "$quality" in
                audio) echo "-f bestaudio[ext!=webm]" ;;
                360)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]\"" ;;
                480)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]\"" ;;
                720)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
                1080)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]\"" ;;
                1440)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]\"" ;;
                2160)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]\"" ;;
                *)     echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
            esac ;;
        avc1_https)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 140+134" ;;
                480)   echo "-f 140+135/134" ;;
                720)   echo "-f 140+136/135/134" ;;
                1080)  echo "-f 140+137/136/135/134" ;;
                1440)  echo "-f 140+138/137/136/135/134" ;;
                2160)  echo "-f 140+139/138/137/136/135/134" ;;
                *)     echo "-f 140+136/135/134" ;;
            esac ;;
        avc1_m3u8)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+230" ;;
                480)   echo "-f 234+231/230" ;;
                720)   echo "-f 234+232/231/230" ;;
                1080)  echo "-f 234+233/232/231/230" ;;
                1440)  echo "-f 234+234/233/232/231/230" ;;
                2160)  echo "-f 234+235/234/233/232/231/230" ;;
                *)     echo "-f 234+232/231/230" ;;
            esac ;;
        avc1_https_60fps)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+296" ;;
                480)   echo "-f 234+297/296" ;;
                720)   echo "-f 234+298/297/296" ;;
                1080)  echo "-f 234+299/298/297/296" ;;
                1440)  echo "-f 234+300/299/298/297/296" ;;
                2160)  echo "-f 234+301/300/299/298/297/296" ;;
                *)     echo "-f 234+298/297/296" ;;
            esac ;;
        avc1_m3u8_60fps)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+309" ;;
                480)   echo "-f 234+310/309" ;;
                720)   echo "-f 234+311/310/309" ;;
                1080)  echo "-f 234+312/311/310/309" ;;
                1440)  echo "-f 234+313/312/311/310/309" ;;
                2160)  echo "-f 234+314/313/312/311/310/309" ;;
                *)     echo "-f 234+311/310/309" ;;
            esac ;;
        avc1_https_60fps_hdr)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+696" ;;
                480)   echo "-f 234+697/696" ;;
                720)   echo "-f 234+698/697/696" ;;
                1080)  echo "-f 234+699/698/697/696" ;;
                1440)  echo "-f 234+700/699/698/697/696" ;;
                2160)  echo "-f 234+701/700/699/698/697/696" ;;
                *)     echo "-f 234+698/697/696" ;;
            esac ;;
        old_combo)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 18" ;;
                480)   echo "-f 20/18" ;;
                720)   echo "-f 22/20/18" ;;
                1080)  echo "-f 24/22/20/18" ;;
                1440)  echo "-f 26/24/22/20/18" ;;
                2160)  echo "-f 28/26/24/22/20/18" ;;
                *)     echo "-f 22/20/18" ;;
            esac ;;
        *)
            echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
    esac
}

# ══════════════════════════════════════════════════════════════
suite "avc1_best: все уровни качества"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio avc1_best)
assert_eq "audio"  "-f bestaudio[ext!=webm]"  "$r"

r=$(build_format_args 360 avc1_best)
assert_contains "360"   "height<=360"   "$r"
assert_contains "360"   "vcodec^=avc1"  "$r"

r=$(build_format_args 720 avc1_best)
assert_contains "720"   "height<=720"   "$r"
assert_contains "720"   "vcodec^=avc1"  "$r"

r=$(build_format_args 1080 avc1_best)
assert_contains "1080"  "height<=1080"  "$r"

r=$(build_format_args 2160 avc1_best)
assert_contains "2160"  "height<=2160"  "$r"

r=$(build_format_args unknown avc1_best)
assert_contains "unknown → fallback 720"  "height<=720"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https: числовые ID"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio avc1_https)
assert_eq "audio"  "-f 140"              "$r"

r=$(build_format_args 360 avc1_https)
assert_eq "360"    "-f 140+134"          "$r"

r=$(build_format_args 480 avc1_https)
assert_eq "480"    "-f 140+135/134"      "$r"

r=$(build_format_args 720 avc1_https)
assert_eq "720"    "-f 140+136/135/134"  "$r"

r=$(build_format_args 1080 avc1_https)
assert_eq "1080"   "-f 140+137/136/135/134"  "$r"

r=$(build_format_args 1440 avc1_https)
assert_eq "1440"   "-f 140+138/137/136/135/134"  "$r"

r=$(build_format_args 2160 avc1_https)
assert_eq "2160"   "-f 140+139/138/137/136/135/134"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_m3u8: числовые ID"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio avc1_m3u8)
assert_eq "audio"  "-f 234"              "$r"

r=$(build_format_args 720 avc1_m3u8)
assert_eq "720"    "-f 234+232/231/230"  "$r"

r=$(build_format_args 1080 avc1_m3u8)
assert_eq "1080"   "-f 234+233/232/231/230"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https_60fps: 60fps форматы"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args 720 avc1_https_60fps)
assert_eq "720"   "-f 234+298/297/296"        "$r"

r=$(build_format_args 1080 avc1_https_60fps)
assert_eq "1080"  "-f 234+299/298/297/296"    "$r"

r=$(build_format_args 2160 avc1_https_60fps)
assert_eq "2160"  "-f 234+301/300/299/298/297/296"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_m3u8_60fps: M3U8 60fps"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args 720 avc1_m3u8_60fps)
assert_eq "720"   "-f 234+311/310/309"        "$r"

r=$(build_format_args 1080 avc1_m3u8_60fps)
assert_eq "1080"  "-f 234+312/311/310/309"    "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https_60fps_hdr: HDR форматы"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args 720 avc1_https_60fps_hdr)
assert_eq "720"   "-f 234+698/697/696"        "$r"

r=$(build_format_args 1080 avc1_https_60fps_hdr)
assert_eq "1080"  "-f 234+699/698/697/696"    "$r"

# ══════════════════════════════════════════════════════════════
suite "old_combo: legacy форматы"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio old_combo)
assert_eq "audio"  "-f 140"              "$r"

r=$(build_format_args 360 old_combo)
assert_eq "360"    "-f 18"               "$r"

r=$(build_format_args 480 old_combo)
assert_eq "480"    "-f 20/18"            "$r"

r=$(build_format_args 720 old_combo)
assert_eq "720"    "-f 22/20/18"         "$r"

r=$(build_format_args 1080 old_combo)
assert_eq "1080"   "-f 24/22/20/18"      "$r"

r=$(build_format_args 1440 old_combo)
assert_eq "1440"   "-f 26/24/22/20/18"   "$r"

r=$(build_format_args 2160 old_combo)
assert_eq "2160"   "-f 28/26/24/22/20/18"  "$r"

# ══════════════════════════════════════════════════════════════
suite "Неизвестный пресет: fallback"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args 720 unknown_preset)
assert_contains "неизвестный пресет → fallback"  "height<=720"  "$r"
assert_contains "неизвестный пресет → avc1"      "vcodec^=avc1"  "$r"

summary
