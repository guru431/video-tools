#!/bin/bash
# ============================================================
# test_01_config_sh.sh — Тест парсинга config.ini (Bash)
# Тестирует: read_config(), to_flag() из FFmpeg_Converter_run.sh
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── Настоящие read_config/to_flag из production-скрипта ───────────────────
# Раньше здесь лежали inline-копии. Копия успела разойтись с оригиналом: в ней не
# было подстановки ${ENV_VAR} и иначе обрезался инлайн-комментарий — то есть тест
# «парсера config.ini» проверял НЕ ТОТ парсер, и сломать настоящий можно было незаметно.
# Дот-сорсим production; его main-гард (BASH_SOURCE == $0) не даёт запустить конвейер.
RUN_SH="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v16.sh"
if [ ! -f "$RUN_SH" ]; then
    suite "Парсер config.ini (SH)"
    fail "production-скрипт на месте" "$RUN_SH" "файл не найден — тест проверял бы копию, а не production"
    summary
    exit 1
fi
source "$RUN_SH"

# ── Единый тестовый config.ini на все тесты ──────────────────────────────────
CONFIG_FILE="$MY_DIR/config.ini"
cat > "$CONFIG_FILE" << 'EOCONFIG'
# Тестовый config.ini
[folders]
source = input
destination = output
[options]
audio_only = no
[audio]
codec = +libmp3lame
channels = +1
bitrate = +192
sampling_rate = +48000
normalize = +loudnorm
[video]
codec = +libx265
resolution = +1920x1080
bitrate = +4000
framerate = +30
rotation = +1
quality = +23
keep_aspect_ratio = +yes
container = +mkv
[performance]
threads = +8
parallel_files = -2
[gpu]
hw_accel = +nvidia
preset = +p5
tune = +hq
rc = +vbr
[speed]
playback_speed = +2.0
[other]
dry_run = yes
enable_log = yes
log_file = test.log
EOCONFIG

# ══════════════════════════════════════════════════════════════
suite "to_flag: конвертация +/- префиксов"
# ══════════════════════════════════════════════════════════════

assert_eq "+value → :+:value"    ":+:libx264"    "$(to_flag '+libx264' '')"
assert_eq "-value → :-:value"    ":-:libx264"    "$(to_flag '-libx264' '')"
assert_eq "bare value → :+:val"  ":+:libx264"    "$(to_flag 'libx264' '')"
assert_eq "пустое → default"     ":+:default"    "$(to_flag '' ':+:default')"

# ══════════════════════════════════════════════════════════════
suite "read_config: секция [audio]"
# ══════════════════════════════════════════════════════════════

assert_eq "codec"         "+libmp3lame"  "$(read_config 'codec' 'audio' '')"
assert_eq "channels"      "+1"           "$(read_config 'channels' 'audio' '')"
assert_eq "bitrate"       "+192"         "$(read_config 'bitrate' 'audio' '')"
assert_eq "sampling_rate" "+48000"       "$(read_config 'sampling_rate' 'audio' '')"
assert_eq "normalize"     "+loudnorm"    "$(read_config 'normalize' 'audio' '')"

# ══════════════════════════════════════════════════════════════
suite "read_config: секция [video]"
# ══════════════════════════════════════════════════════════════

assert_eq "codec"          "+libx265"    "$(read_config 'codec' 'video' '')"
assert_eq "resolution"     "+1920x1080"  "$(read_config 'resolution' 'video' '')"
assert_eq "framerate"      "+30"         "$(read_config 'framerate' 'video' '')"
assert_eq "rotation"       "+1"          "$(read_config 'rotation' 'video' '')"
assert_eq "quality"        "+23"         "$(read_config 'quality' 'video' '')"
assert_eq "keep_aspect"    "+yes"        "$(read_config 'keep_aspect_ratio' 'video' '')"
assert_eq "container"      "+mkv"        "$(read_config 'container' 'video' '')"

# ══════════════════════════════════════════════════════════════
suite "read_config: секции [gpu] [other] [speed]"
# ══════════════════════════════════════════════════════════════

assert_eq "hw_accel"       "+nvidia"    "$(read_config 'hw_accel' 'gpu' '')"
assert_eq "preset"         "+p5"        "$(read_config 'preset' 'gpu' '')"
assert_eq "dry_run"        "yes"        "$(read_config 'dry_run' 'other' '')"
assert_eq "log_file"       "test.log"   "$(read_config 'log_file' 'other' '')"
assert_eq "playback_speed" "+2.0"       "$(read_config 'playback_speed' 'speed' '')"
assert_eq "parallel (-)"   "-2"         "$(read_config 'parallel_files' 'performance' '')"

# ══════════════════════════════════════════════════════════════
suite "read_config: edge cases"
# ══════════════════════════════════════════════════════════════

assert_eq "несуществующий ключ → default"    "my_def"   "$(read_config 'nonexistent' 'audio' 'my_def')"
assert_eq "несуществующая секция → default"  "sec_def"  "$(read_config 'codec' 'nosection' 'sec_def')"

_bkp="$CONFIG_FILE"
CONFIG_FILE="/tmp/no_config_$$.ini"
assert_eq "нет файла → default"  "fallback"  "$(read_config 'codec' 'audio' 'fallback')"
CONFIG_FILE="$_bkp"

# ══════════════════════════════════════════════════════════════
suite "to_flag + read_config: полный цикл (как в run.sh)"
# ══════════════════════════════════════════════════════════════

assert_eq "audio codec → :+:libmp3lame"  ":+:libmp3lame"  "$(to_flag "$(read_config 'codec' 'audio' '+aac')" ':+:aac')"
assert_eq "video codec → :+:libx265"     ":+:libx265"     "$(to_flag "$(read_config 'codec' 'video' '+libx264')" ':+:libx264')"
assert_eq "parallel (-) → :-:2"          ":-:2"           "$(to_flag "$(read_config 'parallel_files' 'performance' '-2')" ':-:2')"
assert_eq "hw_accel (+) → :+:nvidia"     ":+:nvidia"      "$(to_flag "$(read_config 'hw_accel' 'gpu' '-nvidia')" ':-:nvidia')"

# ══════════════════════════════════════════════════════════════
suite "read_config: Task 8 — инлайн # и регистр ключей"
# ══════════════════════════════════════════════════════════════
cat > "$CONFIG_FILE" << 'EOCONFIG'
[audio]
Codec = +aac
[other]
log_file = my#file.log
note = value # это комментарий
EOCONFIG
# Капитализация ключа (Codec) — регистронезависимо
assert_eq "Codec (капитал) распознан"  "+aac"  "$(read_config 'codec' 'audio' '')"
# # без пробела слева — часть значения, не комментарий
assert_eq "my#file.log сохранён целиком"  "my#file.log"  "$(read_config 'log_file' 'other' '')"
# ' #' (пробел+решётка) — инлайн-комментарий срезан
assert_eq "инлайн ' #' срезан"  "value"  "$(read_config 'note' 'other' '')"

# ══════════════════════════════════════════════════════════════
suite "read_config: подстановка \${ENV_VAR} (inline-копия её не покрывала)"
# ══════════════════════════════════════════════════════════════
# Эта ветка есть в production, но её не было в inline-копии — то есть до перехода на
# дот-сорсинг тест «парсера конфига» не проверял её ВООБЩЕ, и сломать её можно было
# незаметно. Ровно тот класс дефекта, ради которого копии и убираются.
cat > "$CONFIG_FILE" << 'EOCONFIG'
[folders]
source = ${FFCONV_TEST_SRC}/videos
[other]
log_file = ${FFCONV_TEST_SRC}/logs/${FFCONV_TEST_NAME}.log
EOCONFIG
export FFCONV_TEST_SRC="/tmp/ffconv_env"
export FFCONV_TEST_NAME="batch7"
assert_eq "одна \${VAR} подставлена"  "/tmp/ffconv_env/videos"  "$(read_config 'source' 'folders' '')"
assert_eq "две \${VAR} в одной строке" "/tmp/ffconv_env/logs/batch7.log" "$(read_config 'log_file' 'other' '')"

# Незаданная переменная → пусто + WARN в stderr (а не литерал ${VAR} в пути).
unset FFCONV_TEST_NAME
_env_out=$(read_config 'log_file' 'other' '' 2>/tmp/env_warn_$$.txt)
_env_warn=$(cat /tmp/env_warn_$$.txt); rm -f /tmp/env_warn_$$.txt
assert_eq       "незаданная \${VAR} → пусто, не литерал" "/tmp/ffconv_env/logs/.log" "$_env_out"
assert_contains "незаданная \${VAR} → WARN в stderr"     "FFCONV_TEST_NAME не задана" "$_env_warn"
unset FFCONV_TEST_SRC

# ══════════════════════════════════════════════════════════════
suite "run_v16.sh: Task 8 (анализ исходника)"
# ══════════════════════════════════════════════════════════════
RUN_SH="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v16.sh"
src_run="$(cat "$RUN_SH")"
assert_contains "nocasematch для регистра ключей"  "shopt -s nocasematch"  "$src_run"
assert_contains "backslash → slash в путях"  '${folder_sources//\\//}'  "$src_run"
assert_contains "Windows-диск как абсолютный путь"  '/*|[A-Za-z]:*)'  "$src_run"

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$MY_DIR/config.ini"

summary
