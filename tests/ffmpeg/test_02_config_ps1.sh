#!/bin/bash
# ============================================================
# test_02_config_ps1.sh — Тест парсинга config.ini (PowerShell)
# Тестирует: Read-Config + To-Flag из FFmpeg_Converter_run.ps1
# Сравнивает результаты PS1 с ожидаемыми эталонными значениями
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность PowerShell
# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути). На Linux/CI пропускаем.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "PowerShell config parsing"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

# ── Обе функции — НАСТОЯЩИЕ из production ───────────────────────────────────
# Раньше здесь лежали inline-копии Read-Config и To-Flag, и они успели разойтись
# с оригиналом в четырёх местах: жадное '\s*#.*' вместо '\s+#.*' (значение
# my#file.log обрезалось до my), отсутствие подстановки ${ENV_VAR}, '^\[(.+)\]$'
# вместо '^\[([^\]]+)\]$' и потерянный .Trim() на возврате. Из-за этого сьюит
# «PS1 vs Bash: паритет» сравнивал КОПИЮ с настоящим bash-парсером — то есть
# не мог обнаружить расхождение, ради которого существовал.
RUN_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v15.ps1"
if [ ! -f "$RUN_PS1" ]; then
    suite "PowerShell config parsing"
    fail "production-скрипт на месте" "$RUN_PS1" "файл не найден — тест проверял бы копию, а не production"
    summary
    exit 1
fi
RUN_PS1_WIN=$(cygpath -w "$RUN_PS1" 2>/dev/null || echo "$RUN_PS1")

# $env:FFCONV_TEST=1 — гард в run_v15.ps1: дот-сорсим только определения функций,
# конвейер загрузки настроек не выполняется.
run_ps1_readconfig() {
    local config_content="$1"
    local key="$2"
    local section="$3"
    local default="$4"
    local config_file
    config_file=$(mktemp /tmp/test_config_XXXXXX.ini)
    printf '%s\n' "$config_content" > "$config_file"
    local win_path
    win_path=$(cygpath -w "$config_file" 2>/dev/null || echo "$config_file")

    local result
    result=$($PS_CMD -NoProfile -NonInteractive -Command "
\$env:FFCONV_TEST = '1'
. '$RUN_PS1_WIN'
\$configFile = '$win_path'
Read-Config '$key' '$section' '$default'
" 2>/dev/null | tr -d '\r')
    rm -f "$config_file"
    echo "$result"
}

run_ps1_toflag() {
    local val="$1"
    local default="$2"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$env:FFCONV_TEST = '1'
. '$RUN_PS1_WIN'
To-Flag '$val' '$default'
" 2>/dev/null | tr -d '\r'
}

# ══════════════════════════════════════════════════════════════
suite "PS1 To-Flag: конвертация префиксов"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_toflag "+libx264" "")
assert_eq "To-Flag: +value → :+:value"  ":+:libx264"  "$result"

result=$(run_ps1_toflag "-libx264" "")
assert_eq "To-Flag: -value → :-:value"  ":-:libx264"  "$result"

result=$(run_ps1_toflag "libx264" "")
assert_eq "To-Flag: bare → :+:value"    ":+:libx264"  "$result"

result=$(run_ps1_toflag "" ":+:default")
assert_eq "To-Flag: пустое → default"   ":+:default"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 Read-Config: базовый парсинг"
# ══════════════════════════════════════════════════════════════

# Многострочный config через несколько аргументов printf
CONFIG="[audio]
codec = +libmp3lame"

result=$(run_ps1_readconfig "$CONFIG" "codec" "audio" "missing")
assert_eq "Read-Config: читает значение"  "+libmp3lame"  "$result"

result=$(run_ps1_readconfig "$CONFIG" "nonexistent" "audio" "default_val")
assert_eq "Read-Config: несуществующий ключ → default"  "default_val"  "$result"

result=$(run_ps1_readconfig "$CONFIG" "codec" "video" "section_default")
assert_eq "Read-Config: другая секция → default"  "section_default"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 Read-Config: inline комментарии"
# ══════════════════════════════════════════════════════════════

CONFIG="[audio]
codec = +aac  # inline comment"

result=$(run_ps1_readconfig "$CONFIG" "codec" "audio" "")
assert_eq "Read-Config: inline comment срезается"  "+aac"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 Read-Config: поведение, которое скрывала inline-копия"
# ══════════════════════════════════════════════════════════════
# Каждая проверка ниже ПАДАЛА бы на старой копии — она и есть смысл миграции.

# Копия резала по '\s*#.*' (жадно, любой '#'), production — по '\s+#.*' (только
# ' #'). На my#file.log копия возвращала "my" и молча уводила лог не туда.
CONFIG_HASH="[log]
log_file = my#file.log"
result=$(run_ps1_readconfig "$CONFIG_HASH" "log_file" "log" "")
assert_eq "'#' внутри значения НЕ считается комментарием"  "my#file.log"  "$result"

# Копия не умела ${ENV_VAR} вовсе и возвращала литерал.
CONFIG_ENV="[folders]
destination = \${FFCONV_TEST_VAR}/sub"
result=$(FFCONV_TEST_VAR="D:\\out" run_ps1_readconfig "$CONFIG_ENV" "destination" "folders" "")
assert_contains "\${ENV_VAR} подставляется из окружения"  "D:\\out"  "$result"
assert_not_contains "\${ENV_VAR} не остаётся литералом"   '${FFCONV_TEST_VAR}'  "$result"

# Копия теряла .Trim() на возврате — хвостовые пробелы уезжали в имя файла/кодека.
CONFIG_SPACE="[video]
codec =    +libx265   "
result=$(run_ps1_readconfig "$CONFIG_SPACE" "codec" "video" "")
assert_eq "значение обрезается с обеих сторон"  "+libx265"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 vs Bash: паритет значений"
# ══════════════════════════════════════════════════════════════
# Проверяем что PS1 и Bash дают одинаковый результат

CONFIG_INI="$MY_DIR/config.ini"
cat > "$CONFIG_INI" << 'EOF'
[audio]
codec = +libmp3lame
bitrate = +192
[video]
codec = +libx265
quality = +23
container = +mkv
[gpu]
hw_accel = -nvidia
EOF

# Загружаем bash read_config. Имя файла менялось v11→v15 — берём первое существующее,
# иначе тест бесшумно пропускает сравнение и даёт ложный fail на пустых значениях.
RUN_SH=""
for cand in "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v15.sh" "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run.sh"; do
    [ -f "$cand" ] && RUN_SH="$cand" && break
done
if [ -n "$RUN_SH" ]; then
    source "$RUN_SH" 2>/dev/null
fi

bash_audio_codec="$audio_codec"
bash_video_codec="$video_codec"
bash_output_container="$output_container"

# PS1 значения
ps1_audio=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "codec" "audio" "")
ps1_video=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "codec" "video" "")
ps1_container=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "container" "video" "")

# Bash даёт :+:libmp3lame, PS1 даёт +libmp3lame (до to_flag)
# Сравниваем сырые значения read_config (без to_flag)
bash_raw_audio=$(CONFIG_FILE="$CONFIG_INI" read_config "codec" "audio" "")
bash_raw_video=$(CONFIG_FILE="$CONFIG_INI" read_config "codec" "video" "")
bash_raw_container=$(CONFIG_FILE="$CONFIG_INI" read_config "container" "video" "")

assert_eq "Паритет: audio codec (raw)"    "$bash_raw_audio"     "$ps1_audio"
assert_eq "Паритет: video codec (raw)"    "$bash_raw_video"     "$ps1_video"
assert_eq "Паритет: container (raw)"      "$bash_raw_container" "$ps1_container"

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$MY_DIR/config.ini"

summary
