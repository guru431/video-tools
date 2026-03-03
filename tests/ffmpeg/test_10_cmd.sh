#!/bin/bash
# ============================================================
# test_10_cmd.sh — Тест CMD: парсинг config.ini и исправления
# Тестирует: :to_flag, парсинг секций, Bug 3 (copy_codecs+filters),
# Bug 4 (seek_arg при b=0), Bug 6 (GPU encoder check).
# Использует cmd.exe через inline .cmd скрипты.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD тесты"
    skip "Все CMD тесты" "cmd.exe не доступен"
    summary
    exit 0
fi

# ── Хелпер: запустить inline CMD скрипт через temp файл ───────────────────
run_cmd() {
    local script_content="$1"
    local tmp_cmd
    tmp_cmd=$(mktemp /tmp/test_cmd_XXXXXX.cmd)
    printf '@echo off\r\nchcp 65001 >nul 2>&1\r\nsetlocal enabledelayedexpansion\r\n%s\r\n' \
        "$script_content" > "$tmp_cmd"
    local win_path
    win_path=$(cygpath -w "$tmp_cmd" 2>/dev/null || echo "$tmp_cmd" | sed 's|/c/|C:/|' | sed 's|/|\\|g')
    local result
    result=$(cmd //c "$win_path" 2>/dev/null)
    rm -f "$tmp_cmd"
    echo "$result"
}

# ══════════════════════════════════════════════════════════════
suite "CMD: :to_flag суброутин (+/- → :+:/:-:)"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "_fv=+libx264"
set "_fn=video_codec"
if "!_fv:~0,1!"=="+" (set "!_fn!=:+:!_fv:~1!") else if "!_fv:~0,1!"=="-" (set "!_fn!=:-:!_fv:~1!") else (set "!_fn!=:+:!_fv!")
echo !video_codec!
')
assert_eq "to_flag: +libx264 → :+:libx264"  ":+:libx264"  "$result"

result=$(run_cmd '
set "_fv=-libx264"
set "_fn=video_codec"
if "!_fv:~0,1!"=="+" (set "!_fn!=:+:!_fv:~1!") else if "!_fv:~0,1!"=="-" (set "!_fn!=:-:!_fv:~1!") else (set "!_fn!=:+:!_fv!")
echo !video_codec!
')
assert_eq "to_flag: -libx264 → :-:libx264"  ":-:libx264"  "$result"

result=$(run_cmd '
set "_fv=libx264"
set "_fn=video_codec"
if "!_fv:~0,1!"=="+" (set "!_fn!=:+:!_fv:~1!") else if "!_fv:~0,1!"=="-" (set "!_fn!=:-:!_fv:~1!") else (set "!_fn!=:+:!_fv!")
echo !video_codec!
')
assert_eq "to_flag: bare libx264 → :+:libx264"  ":+:libx264"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD: парсинг :+:value / :-:value"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "audio_codec=:+:aac"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "audio_codec_status=%%a" & set "audio_codec_value=%%b")
echo status=!audio_codec_status!
echo value=!audio_codec_value!
')
assert_contains "парсинг :+:aac → status=+"  "status=+"  "$result"
assert_contains "парсинг :+:aac → value=aac" "value=aac" "$result"

result=$(run_cmd '
set "video_codec=:-:libx264"
for /f "tokens=1,2 delims=:" %%a in ("%video_codec%") do (set "video_codec_status=%%a" & set "video_codec_value=%%b")
echo status=!video_codec_status!
echo value=!video_codec_value!
')
assert_contains "парсинг :-:libx264 → status=-"       "status=-"    "$result"
assert_contains "парсинг :-:libx264 → value=libx264"  "value=libx264" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD: аудио/видео аргументы"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "audio_codec=:+:aac"
set "audio_bitrate=:+:128"
set "audio_number_channels=:+:2"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "ac_status=%%a" & set "ac_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_bitrate%") do (set "ab_status=%%a" & set "ab_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_number_channels%") do (set "ach_status=%%a" & set "ach_value=%%b")
if "!ac_status!"=="+" (set "set_audio_codec=-c:a !ac_value!") else (set "set_audio_codec=")
if "!ab_status!"=="+" (set "set_audio_bitrate=-b:a !ab_value!k") else (set "set_audio_bitrate=")
if "!ach_status!"=="+" (set "set_audio_channels=-ac !ach_value!") else (set "set_audio_channels=")
echo codec=!set_audio_codec!
echo bitrate=!set_audio_bitrate!
echo channels=!set_audio_channels!
')
assert_contains "audio codec +aac → -c:a aac"      "-c:a aac"   "$result"
assert_contains "audio bitrate +128 → -b:a 128k"   "-b:a 128k"  "$result"
assert_contains "audio channels +2 → -ac 2"         "-ac 2"      "$result"

result=$(run_cmd '
set "audio_codec=:-:aac"
set "audio_bitrate=:-:128"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "ac_status=%%a" & set "ac_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_bitrate%") do (set "ab_status=%%a" & set "ab_value=%%b")
if "!ac_status!"=="+" (set "set_audio_codec=-c:a !ac_value!") else (set "set_audio_codec=")
if "!ab_status!"=="+" (set "set_audio_bitrate=-b:a !ab_value!k") else (set "set_audio_bitrate=")
echo codec=[!set_audio_codec!]
echo bitrate=[!set_audio_bitrate!]
')
assert_contains "audio codec -aac → пустой"    "codec=[]"   "$result"
assert_contains "audio bitrate -128 → пустой"  "bitrate=[]" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 3: copy_codecs=yes очищает vf_args/af_args"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "copy_codecs=yes"
set "current_vf=scale=1280:720"
set "current_af=loudnorm"
if defined current_vf (set "vf_args=-vf !current_vf!")
if defined current_af (set "af_args=-af !current_af!")
if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")
echo vf=[!vf_args!]
echo af=[!af_args!]
')
assert_contains "Bug3: copy_codecs=yes → vf_args пустой"  "vf=[]"  "$result"
assert_contains "Bug3: copy_codecs=yes → af_args пустой"  "af=[]"  "$result"

result=$(run_cmd '
set "copy_codecs=no"
set "current_vf=scale=1280:720"
set "current_af=loudnorm"
if defined current_vf (set "vf_args=-vf !current_vf!")
if defined current_af (set "af_args=-af !current_af!")
if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")
echo vf=[!vf_args!]
echo af=[!af_args!]
')
assert_contains "Bug3: copy_codecs=no → vf_args сохранён"  "vf=[-vf scale=1280:720]"  "$result"
assert_contains "Bug3: copy_codecs=no → af_args сохранён"  "af=[-af loudnorm]"         "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 4: seek_arg пустой когда b=0"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "b=0"
if %b%==0 (set "seek_arg=") else (set "seek_arg=-ss %b%")
echo seek=[!seek_arg!]
')
assert_contains "Bug4: b=0 → seek_arg пустой"  "seek=[]"  "$result"

result=$(run_cmd '
set "b=3600"
if %b%==0 (set "seek_arg=") else (set "seek_arg=-ss %b%")
echo seek=[!seek_arg!]
')
assert_contains "Bug4: b=3600 → seek_arg=-ss 3600"  "seek=[-ss 3600]"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 6: GPU encoder check логика"
# ══════════════════════════════════════════════════════════════

# Тест логики (без реального ffmpeg): симулируем encoder_check
result=$(run_cmd '
set "use_hw_accel=no"
set "set_video_codec=libx264"
set "encoder_check=V..... h264_nvenc   NVIDIA NVENC H.264"
if defined encoder_check (
    set "use_hw_accel=yes"
    if "!set_video_codec!"=="libx264" set "set_video_codec=h264_nvenc"
)
echo hw=!use_hw_accel!
echo codec=!set_video_codec!
')
assert_contains "Bug6: encoder found → use_hw_accel=yes"  "hw=yes"         "$result"
assert_contains "Bug6: encoder found → libx264→h264_nvenc" "codec=h264_nvenc" "$result"

result=$(run_cmd '
set "use_hw_accel=no"
set "set_video_codec=libx264"
set "encoder_check="
if defined encoder_check (
    set "use_hw_accel=yes"
    if "!set_video_codec!"=="libx264" set "set_video_codec=h264_nvenc"
)
echo hw=!use_hw_accel!
echo codec=!set_video_codec!
')
assert_contains "Bug6: encoder not found → use_hw_accel=no"  "hw=no"      "$result"
assert_contains "Bug6: encoder not found → codec unchanged"   "codec=libx264" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD: config.ini парсинг (to_flag через config)"
# ══════════════════════════════════════════════════════════════

# Создаём временный config и тестовый CMD файл напрямую
TMP_DIR=$(mktemp -d /tmp/test_cmd_config_XXXXXX)
TMP_INI="$TMP_DIR/config.ini"
printf '[audio]\ncodec = +libmp3lame\nbitrate = +192\n[video]\ncodec = +libx265\nquality = +28\n' > "$TMP_INI"

WIN_INI=$(cygpath -w "$TMP_INI")

# Напишем CMD файл напрямую (избегаем сложного экранирования в run_cmd)
TMP_CMD="$TMP_DIR/parse_test.cmd"
WIN_CMD=$(cygpath -w "$TMP_CMD")

cat > "$TMP_CMD" << CMDEOF
@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
set "CONFIG_FILE=$WIN_INI"
set "audio_codec=:+:aac"
set "video_codec=:+:libx264"
set "video_quality=:-:23"
set "_section="
for /f "usebackq tokens=* delims=" %%A in ("%CONFIG_FILE%") do (
    set "_line=%%A"
    for /f "tokens=* delims= " %%T in ("!_line!") do set "_line=%%T"
    if defined _line if not "!_line:~0,1!"=="#" (
        echo !_line! | findstr /r "^\[.*\]" >nul 2>&1
        if !errorlevel! equ 0 (
            set "_section=!_line:~1,-1!"
            if "!_section:~-1!"=="]" set "_section=!_section:~0,-1!"
        ) else (
            for /f "tokens=1,* delims==" %%K in ("!_line!") do (
                set "_key=%%K"
                set "_fv=%%L"
                for /f "tokens=* delims= " %%T in ("!_key!") do set "_key=%%T"
                for /l %%i in (1,1,5) do if "!_key:~-1!"==" " set "_key=!_key:~0,-1!"
                for /f "tokens=1 delims=#" %%V in ("%%L") do for /f "tokens=* delims= " %%T in ("%%V") do set "_fv=%%T"
                if "!_section!"=="audio" (
                    if "!_key!"=="codec" (
                        if "!_fv:~0,1!"=="+" (set "audio_codec=:+:!_fv:~1!") else (set "audio_codec=:-:!_fv:~1!")
                    )
                )
                if "!_section!"=="video" (
                    if "!_key!"=="codec" (
                        if "!_fv:~0,1!"=="+" (set "video_codec=:+:!_fv:~1!") else (set "video_codec=:-:!_fv:~1!")
                    )
                    if "!_key!"=="quality" (
                        if "!_fv:~0,1!"=="+" (set "video_quality=:+:!_fv:~1!") else (set "video_quality=:-:!_fv:~1!")
                    )
                )
            )
        )
    )
)
echo audio_codec=!audio_codec!
echo video_codec=!video_codec!
echo video_quality=!video_quality!
CMDEOF

result=$(cmd //c "$WIN_CMD" 2>/dev/null)
rm -rf "$TMP_DIR"
assert_contains "config: audio codec = +libmp3lame → :+:libmp3lame"  ":+:libmp3lame"  "$result"
assert_contains "config: video codec = +libx265 → :+:libx265"        ":+:libx265"     "$result"
assert_contains "config: video quality = +28 → :+:28"                ":+:28"          "$result"

summary
