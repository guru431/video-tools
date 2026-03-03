#!/bin/bash
# ============================================================
# test_01_config_sh.sh — Тест парсинга config.ini (Bash)
# Тестирует: read_config(), to_flag() из FFmpeg_Converter_run.sh
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── Inline-определения функций (копии из run.sh, без форка sed) ─────────────
to_flag() {
    local val="$1"
    local default="$2"
    if [ -z "$val" ]; then echo "$default"; return; fi
    local first="${val:0:1}"
    local rest="${val:1}"
    case "$first" in
        +) echo ":+:$rest" ;;
        -) echo ":-:$rest" ;;
        *) echo ":+:$val" ;;
    esac
}

read_config() {
    local key="$1"
    local section="$2"
    local default="${3:-}"
    if [ ! -f "$CONFIG_FILE" ]; then echo "$default"; return; fi
    local in_section=false
    while IFS= read -r line || [ -n "$line" ]; do
        # trim без sed (быстро)
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" = "$section" ]] && in_section=true || in_section=false
            continue
        fi
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            local value="${BASH_REMATCH[1]%%#*}"
            value="${value%"${value##*[![:space:]]}"}"
            echo "$value"
            return
        fi
    done < "$CONFIG_FILE"
    echo "$default"
}

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

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$MY_DIR/config.ini"

summary
