#!/bin/bash
# ============================================================
# test_02_format_args.sh — Тест build_format_args()
# Проверяет все комбинации: 7 пресетов × 8 уровней качества
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── Настоящая build_format_args из production ──────────────────────────────
# Раньше здесь лежала inline-копия, подписанная «копия из скрипта, без изменений».
# Изменения были, и существенные: копия принимала ДВА параметра с дефолтом
# preset=avc1_best и ВОЗВРАЩАЛА СТРОКУ, тогда как production принимает три
# (quality, preset=auto, platform=youtube) и заполняет argv-массив FMT_ARGS_ARR.
# То есть тест проверял функцию с другим дефолтом и другим контрактом — сломать
# настоящую можно было при полностью зелёном наборе.
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
if [ ! -f "$YT_SH" ]; then
    suite "build_format_args"
    fail "production-скрипт на месте" "$YT_SH" "файл не найден — тест проверял бы копию, а не production"
    summary
    exit 1
fi
source "$YT_SH"
set +u +o pipefail

# Отдаём массив как строку "-f <значение>": так сохраняются прежние ожидания теста,
# но проверяется НАСТОЯЩАЯ функция. platform по умолчанию youtube — прежняя копия
# про платформу не знала вовсе.
fmt_call() {
    FMT_ARGS_ARR=()
    build_format_args "$1" "${2:-auto}" "${3:-youtube}" >/dev/null 2>&1
    printf '%s' "${FMT_ARGS_ARR[*]}"
}

# ══════════════════════════════════════════════════════════════
suite "avc1_best: все уровни качества"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call audio avc1_best)
assert_eq "audio"  "-f bestaudio[ext!=webm]/bestaudio"  "$r"

r=$(fmt_call 360 avc1_best)
assert_contains "360"   "height<=360"   "$r"
assert_contains "360"   "vcodec^=avc1"  "$r"

r=$(fmt_call 720 avc1_best)
assert_contains "720"   "height<=720"   "$r"
assert_contains "720"   "vcodec^=avc1"  "$r"

r=$(fmt_call 1080 avc1_best)
assert_contains "1080"  "height<=1080"  "$r"

r=$(fmt_call 2160 avc1_best)
assert_contains "2160"  "height<=2160"  "$r"

r=$(fmt_call unknown avc1_best)
assert_contains "unknown → fallback 720"  "height<=720"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https: числовые ID"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call audio avc1_https)
assert_eq "audio"  "-f 140"              "$r"

r=$(fmt_call 360 avc1_https)
assert_eq "360"    "-f 140+134"          "$r"

r=$(fmt_call 480 avc1_https)
assert_eq "480"    "-f 140+135/134"      "$r"

r=$(fmt_call 720 avc1_https)
assert_eq "720"    "-f 140+136/135/134"  "$r"

r=$(fmt_call 1080 avc1_https)
assert_eq "1080"   "-f 140+137/136/135/134"  "$r"

r=$(fmt_call 1440 avc1_https)
assert_contains "1440 → 140+264 (не битый 140+138)"  "140+264"  "$r"
assert_not_contains "1440 → нет аудио-itag 138"  "140+138"  "$r"

r=$(fmt_call 2160 avc1_https)
assert_contains "2160 → 140+266 (не битый 140+139)"  "140+266"  "$r"
assert_not_contains "2160 → нет аудио-itag 139"  "140+139"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_m3u8: числовые ID"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call audio avc1_m3u8)
assert_eq "audio"  "-f 234"              "$r"

r=$(fmt_call 720 avc1_m3u8)
assert_eq "720"    "-f 234+232/231/230"  "$r"

r=$(fmt_call 1080 avc1_m3u8)
assert_contains "1080 → 270+234 (не битый 234+233)"  "270+234"  "$r"
assert_not_contains "1080 → нет 234+233"  "234+233"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https_60fps: 60fps форматы"
# ══════════════════════════════════════════════════════════════

# 720/1080: 140-аудио (не m3u8 234) + финальный /best-fallback, без фантомных 297/296.
r=$(fmt_call 720 avc1_https_60fps)
assert_eq "720"   "-f 140+298/best[height<=720]"        "$r"
assert_not_contains "720 → нет фантомных 297/296"  "297"  "$r"

r=$(fmt_call 1080 avc1_https_60fps)
assert_eq "1080"  "-f 140+299/298/best[height<=1080]"    "$r"

# 1440/2160: селектор по разрешению идёт ПЕРВЫМ (иначе 140+299 отдаёт 1080p).
r=$(fmt_call 1440 avc1_https_60fps)
assert_contains "1440 → resolution-first"  "bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299"  "$r"

r=$(fmt_call 2160 avc1_https_60fps)
assert_contains "2160 → resolution-first + fps>=50"  "bestvideo[height<=2160][fps>=50]"  "$r"
assert_not_contains "2160 → не начинается с 140+299 (даунгрейд в 1080p)"  "-f 140+299"  "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_m3u8_60fps: M3U8 60fps"
# ══════════════════════════════════════════════════════════════

# Контракт: сначала точные itag-цепочки, затем обобщённый fallback — пропавший на
# стороне YouTube itag не должен ронять загрузку. Прежние ожидания застыли на версии
# ДО появления fallback: их проверяла inline-копия, которая за production не поспевала.
r=$(fmt_call 720 avc1_m3u8_60fps)
assert_eq "720"   "-f 234+311/310/309/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]"    "$r"

r=$(fmt_call 1080 avc1_m3u8_60fps)
assert_eq "1080"  "-f 234+312/311/310/309/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]" "$r"

# ══════════════════════════════════════════════════════════════
suite "avc1_https_60fps_hdr: HDR форматы"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call 720 avc1_https_60fps_hdr)
assert_eq "720"   "-f 234+698/697/696/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]"    "$r"

r=$(fmt_call 1080 avc1_https_60fps_hdr)
assert_eq "1080"  "-f 234+699/698/697/696/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]" "$r"

# ══════════════════════════════════════════════════════════════
suite "old_combo: legacy форматы"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call audio old_combo)
assert_eq "audio"  "-f 140"              "$r"

r=$(fmt_call 360 old_combo)
assert_eq "360"    "-f 18"               "$r"

r=$(fmt_call 480 old_combo)
assert_eq "480"    "-f 59/22/18"         "$r"
assert_not_contains "480 → нет несуществующего itag 20"  "20/"  "$r"

r=$(fmt_call 720 old_combo)
assert_eq "720"    "-f 22/18"            "$r"

r=$(fmt_call 1080 old_combo)
assert_eq "1080"   "-f 37/22/18"         "$r"
assert_not_contains "1080 → нет несуществующего itag 24"  "24/"  "$r"

r=$(fmt_call 1440 old_combo)
assert_eq "1440"   "-f 38/37/22/18"      "$r"

r=$(fmt_call 2160 old_combo)
assert_eq "2160"   "-f 38/37/22/18"      "$r"

# ══════════════════════════════════════════════════════════════
suite "Неизвестный пресет: fallback"
# ══════════════════════════════════════════════════════════════

r=$(fmt_call 720 unknown_preset)
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
