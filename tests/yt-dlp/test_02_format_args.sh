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
                audio) echo "-f bestaudio[ext!=webm]/bestaudio" ;;
                360)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360]\"" ;;
                480)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480]\"" ;;
                720)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]\"" ;;
                1080)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080]\"" ;;
                1440)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440]\"" ;;
                2160)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160]\"" ;;
                *)     echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]\"" ;;
            esac ;;
        avc1_https)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 140+134" ;;
                480)   echo "-f 140+135/134" ;;
                720)   echo "-f 140+136/135/134" ;;
                1080)  echo "-f 140+137/136/135/134" ;;
                1440)  echo "-f 140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]" ;;
                2160)  echo "-f 140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]" ;;
                *)     echo "-f 140+136/135/134" ;;
            esac ;;
        avc1_m3u8)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+230" ;;
                480)   echo "-f 234+231/230" ;;
                720)   echo "-f 234+232/231/230" ;;
                1080)  echo "-f 270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]" ;;
                1440)  echo "-f bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]" ;;
                2160)  echo "-f bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]" ;;
                *)     echo "-f 234+232/231/230" ;;
            esac ;;
        avc1_https_60fps)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 140+134/best[height<=360]" ;;
                480)   echo "-f 140+135/best[height<=480]" ;;
                720)   echo "-f 140+298/best[height<=720]" ;;
                1080)  echo "-f 140+299/298/best[height<=1080]" ;;
                1440)  echo "-f bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=1440]" ;;
                2160)  echo "-f bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=2160]" ;;
                *)     echo "-f 140+298/best[height<=720]" ;;
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
                480)   echo "-f 59/22/18" ;;
                720)   echo "-f 22/18" ;;
                1080)  echo "-f 37/22/18" ;;
                1440)  echo "-f 38/37/22/18" ;;
                2160)  echo "-f 38/37/22/18" ;;
                *)     echo "-f 22/18" ;;
            esac ;;
        *)
            echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
    esac
}

# ══════════════════════════════════════════════════════════════
suite "avc1_best: все уровни качества"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio avc1_best)
assert_eq "audio"  "-f bestaudio[ext!=webm]/bestaudio"  "$r"

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
assert_contains "1440 → 140+264 (не битый 140+138)"  "140+264"  "$r"
assert_not_contains "1440 → нет аудио-itag 138"  "140+138"  "$r"

r=$(build_format_args 2160 avc1_https)
assert_contains "2160 → 140+266 (не битый 140+139)"  "140+266"  "$r"
assert_not_contains "2160 → нет аудио-itag 139"  "140+139"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_m3u8: числовые ID"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args audio avc1_m3u8)
assert_eq "audio"  "-f 234"              "$r"

r=$(build_format_args 720 avc1_m3u8)
assert_eq "720"    "-f 234+232/231/230"  "$r"

r=$(build_format_args 1080 avc1_m3u8)
assert_contains "1080 → 270+234 (не битый 234+233)"  "270+234"  "$r"
assert_not_contains "1080 → нет 234+233"  "234+233"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https_60fps: 60fps форматы"
# ══════════════════════════════════════════════════════════════

# 720/1080: 140-аудио (не m3u8 234) + финальный /best-fallback, без фантомных 297/296.
r=$(build_format_args 720 avc1_https_60fps)
assert_eq "720"   "-f 140+298/best[height<=720]"        "$r"
assert_not_contains "720 → нет фантомных 297/296"  "297"  "$r"

r=$(build_format_args 1080 avc1_https_60fps)
assert_eq "1080"  "-f 140+299/298/best[height<=1080]"    "$r"

# 1440/2160: селектор по разрешению идёт ПЕРВЫМ (иначе 140+299 отдаёт 1080p).
r=$(build_format_args 1440 avc1_https_60fps)
assert_contains "1440 → resolution-first"  "bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299"  "$r"

r=$(build_format_args 2160 avc1_https_60fps)
assert_contains "2160 → resolution-first + fps>=50"  "bestvideo[height<=2160][fps>=50]"  "$r"
assert_not_contains "2160 → не начинается с 140+299 (даунгрейд в 1080p)"  "-f 140+299"  "$r"

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
assert_eq "480"    "-f 59/22/18"         "$r"
assert_not_contains "480 → нет несуществующего itag 20"  "20/"  "$r"

r=$(build_format_args 720 old_combo)
assert_eq "720"    "-f 22/18"            "$r"

r=$(build_format_args 1080 old_combo)
assert_eq "1080"   "-f 37/22/18"         "$r"
assert_not_contains "1080 → нет несуществующего itag 24"  "24/"  "$r"

r=$(build_format_args 1440 old_combo)
assert_eq "1440"   "-f 38/37/22/18"      "$r"

r=$(build_format_args 2160 old_combo)
assert_eq "2160"   "-f 38/37/22/18"      "$r"

# ══════════════════════════════════════════════════════════════
suite "Неизвестный пресет: fallback"
# ══════════════════════════════════════════════════════════════

r=$(build_format_args 720 unknown_preset)
assert_contains "неизвестный пресет → fallback"  "height<=720"  "$r"
assert_contains "неизвестный пресет → avc1"      "vcodec^=avc1"  "$r"

# ══════════════════════════════════════════════════════════════
suite "Task 9: исправленные itag-таблицы во всех 3 платформах (анализ исходников)"
# ══════════════════════════════════════════════════════════════
SH_SRC="$(cat "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh")"
CMD_SRC="$(cat "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd")"
PS1_SRC="$(cat "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1")"

# SH
assert_contains "SH: avc1_https 2160 → 140+266"  "140+266"  "$SH_SRC"
assert_not_contains "SH: нет битого 140+139"  "140+139"  "$SH_SRC"
assert_not_contains "SH: нет битого 234+233"  "234+233"  "$SH_SRC"
assert_not_contains "SH: old_combo без itag 20/"  "20/18"  "$SH_SRC"
assert_contains "SH: avc1_best fallback /bestaudio+bestvideo"  "/bestaudio+bestvideo"  "$SH_SRC"
# CMD
assert_contains "CMD: avc1_https q6 → 140+266"  "140+266"  "$CMD_SRC"
assert_not_contains "CMD: нет битого 140+139"  "140+139"  "$CMD_SRC"
assert_not_contains "CMD: old_combo без itag 20/18"  "20/18"  "$CMD_SRC"
assert_contains "CMD: GE-плейсхолдер декодируется в >="  "save_settings:GE=>=!"  "$CMD_SRC"
# PS1
assert_contains "PS1: avc1_https 2160 → 140+266"  "140+266"  "$PS1_SRC"
assert_not_contains "PS1: нет битого 234+234"  "234+234/233"  "$PS1_SRC"
assert_not_contains "PS1: old_combo без itag 20/18"  "20/18"  "$PS1_SRC"

# ══════════════════════════════════════════════════════════════
suite "ПРОДАКШН build_format_args (dot-source SH) — таблицы не дрейфуют"
# ══════════════════════════════════════════════════════════════
# main() под guard → можно дот-сорсить и звать НАСТОЯЩУЮ build_format_args.
# Изоляция в субшелле: у боевого скрипта 'set -uo pipefail' в шапке, не тащим его
# в тело теста. Ловит расхождение боевых itag-таблиц с ожиданиями (F-test-copies).
prod_fmt() { ( YTDLP_BIN=":"; source "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh" >/dev/null 2>&1; build_format_args "$1" "$2" youtube; printf '%s' "${FMT_ARGS_ARR[1]}" ); }

assert_eq       "prod 60fps 720"   "140+298/best[height<=720]"       "$(prod_fmt 720 avc1_https_60fps)"
assert_eq       "prod 60fps 1080"  "140+299/298/best[height<=1080]"  "$(prod_fmt 1080 avc1_https_60fps)"
assert_contains "prod 60fps 1440 resolution-first"  "bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299"  "$(prod_fmt 1440 avc1_https_60fps)"
assert_contains "prod 60fps 2160 resolution-first"  "bestvideo[height<=2160][fps>=50]"  "$(prod_fmt 2160 avc1_https_60fps)"
assert_eq       "prod avc1_best audio"  "bestaudio[ext!=webm]/bestaudio"  "$(prod_fmt audio avc1_best)"
assert_eq       "prod avc1_https 2160"  "140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]"  "$(prod_fmt 2160 avc1_https)"

summary
