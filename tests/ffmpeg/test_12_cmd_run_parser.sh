#!/bin/bash
# ============================================================
# test_12_cmd_run_parser.sh — Парсер config.ini в FFmpeg_Converter_run_v14.cmd
# Прогоняет run_v14.cmd с тестовым config.ini через хук --print-config
# (печатает распарсенные переменные, не запуская script.cmd). Ловит баги:
#   (а) детект секций через echo|findstr (пробел + якорь $ на piped input)
#   (б) хвостовой пробел в ключе после "key = value" — ключи не матчатся
#   (в) исполнение `&` из значений при echo|findstr (subtitles_style, пути)
#   (г) :trim_val режет максимум 3 хвостовых пробела
#   (д) :to_flag при пустом значении даёт ":+:" вместо дефолта
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD: парсер config.ini (run_v14)"
    skip "Все тесты парсера" "cmd.exe не доступен"
    summary
    exit 0
fi

# ══════════════════════════════════════════════════════════════
suite "CMD: парсер config.ini (run_v14, --print-config)"
# ══════════════════════════════════════════════════════════════

TMP_DIR=$(mktemp -d /tmp/test_cmd_run_parser_XXXXXX)
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v14.cmd" "$TMP_DIR/"

# Тестовый config.ini рядом с run-скриптом (run ищет %~dp0config.ini).
# quality имеет 5 хвостовых пробелов (баг г), codec пустой (баг д),
# subtitles_style содержит &HFFFFFF& (баг в), source — абсолютный путь.
cat > "$TMP_DIR/config.ini" << 'INIEOF'
# Тестовый конфиг парсера
[folders]
source = C:\abs\src

[video]
quality = +23     

[gpu]
hw_accel = +intel

[audio]
codec =

[other]
subtitles_style = FontSize=20,PrimaryColour=&HFFFFFF&
INIEOF
# CRLF для cmd
sed -i 's/$/\r/' "$TMP_DIR/config.ini"

WIN_RUN=$(cygpath -w "$TMP_DIR/FFmpeg_Converter_run_v14.cmd")
WIN_TMP=$(cygpath -w "$TMP_DIR")

output=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1)
exit_code=$?

# Извлечь конкретные строки key=value (без \r), для точных сравнений
get_line() { printf '%s\n' "$output" | tr -d '\r' | grep "^$1=" | head -1; }

assert_eq "exit code 0" "0" "$exit_code"
assert_not_contains "нет исполнения & из значений ('is not recognized')" "is not recognized" "$output"
assert_not_contains "нет parse error 'was unexpected at this time'" "was unexpected at this time" "$output"

# (а)+(б) секции и ключи распознаны — значения из конфига, не дефолты
assert_eq "[gpu] hw_accel = +intel распарсен (не дефолт :-:intel)" \
    "hw_accel=:+:intel" "$(get_line hw_accel)"

# (г) 5 хвостовых пробелов значения полностью срезаны
assert_eq "[video] quality = +23 + 5 trailing spaces -> video_quality=:+:23" \
    "video_quality=:+:23" "$(get_line video_quality)"

# (д) пустое значение codec= -> остался дефолт :+:aac, не ':+:'
assert_eq "[audio] codec= (пусто) -> остался дефолт audio_codec=:+:aac" \
    "audio_codec=:+:aac" "$(get_line audio_codec)"

# (в) значение с & дошло целиком
assert_eq "subtitles_style дошёл целиком с &HFFFFFF&" \
    "subtitles_style=FontSize=20,PrimaryColour=&HFFFFFF&" "$(get_line subtitles_style)"

# Резолвинг путей: абсолютный source не префиксуется, относительный destination — префиксуется %~dp0
assert_eq "абсолютный source не префиксован" \
    "folder_sources=C:\\abs\\src" "$(get_line folder_sources)"
assert_contains "относительный destination префиксован папкой скрипта" \
    "$WIN_TMP" "$(get_line folder_destination)"

rm -rf "$TMP_DIR"

summary
