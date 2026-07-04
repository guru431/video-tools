#!/bin/bash
# ============================================================
# test_11_cmd_smoke.sh — End-to-end smoke-тест FFmpeg_Converter_script.cmd
# Полный прогон script.cmd (dry_run=yes) на временной папке с фейковым
# sample.mp4 и мок-ffmpeg.bat. Ловит фатальные parse errors CMD
# (":: внутри блоков", label внутри for /r), из-за которых скрипт
# умирал с ". was unexpected at this time." до обработки первого файла.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD smoke-тест"
    skip "Все CMD smoke-тесты" "cmd.exe не доступен"
    summary
    exit 0
fi

# ══════════════════════════════════════════════════════════════
suite "CMD: end-to-end smoke (script.cmd, dry_run)"
# ══════════════════════════════════════════════════════════════

TMP_DIR=$(mktemp -d /tmp/test_cmd_smoke_XXXXXX)
mkdir -p "$TMP_DIR/src" "$TMP_DIR/dst" "$TMP_DIR/bin"
printf 'fake video data' > "$TMP_DIR/src/sample.mp4"
# Файл с литеральным % в имени — регресс-кейс: call :process_file "%%~fa"
# повторно прогонял аргумент через %-expansion и съедал знак процента.
printf 'fake video data' > "$TMP_DIR/src/50% off.mp4"

# ── Мок ffmpeg.exe / ffprobe.exe ──
# ВАЖНО: мок обязан быть exe, а не .bat — script.cmd вызывает "%ffmpeg%"
# без call, а вызов батника без call в CMD обрывает вызывающий скрипт.
# Собираем крошечный exe через PowerShell Add-Type (.NET csc).
WIN_BIN_FOR_PS=$(cygpath -w "$TMP_DIR/bin")
powershell -NoProfile -Command "Add-Type -TypeDefinition 'public class M{public static int Main(string[] a){System.Console.Error.WriteLine(\"  Duration: 00:00:10.00, start: 0.000000, bitrate: 1000 kb/s\");System.Console.WriteLine(\"ffmpeg version 6.0-mock\");return 0;}}' -OutputAssembly '$WIN_BIN_FOR_PS\\ffmpeg.exe' -OutputType ConsoleApplication" >/dev/null 2>&1
if [ ! -f "$TMP_DIR/bin/ffmpeg.exe" ]; then
    skip "Все CMD smoke-тесты" "не удалось собрать мок ffmpeg.exe (Add-Type)"
    rm -rf "$TMP_DIR"
    summary
    exit 0
fi
cp "$TMP_DIR/bin/ffmpeg.exe" "$TMP_DIR/bin/ffprobe.exe"

WIN_SRC=$(cygpath -w "$TMP_DIR/src")
WIN_DST=$(cygpath -w "$TMP_DIR/dst")
WIN_BIN=$(cygpath -w "$TMP_DIR/bin")
WIN_FFMPEG=$(cygpath -w "$TMP_DIR/bin/ffmpeg.exe")
WIN_SCRIPT=$(cygpath -w "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")

# ── Обёртка: все переменные окружения, которые ждёт script.cmd ──
# (список из блока дефолтов FFmpeg_Converter_run_v15.cmd)
TMP_CMD="$TMP_DIR/run_smoke.cmd"
cat > "$TMP_CMD" << CMDEOF
@echo off
chcp 65001 >nul 2>&1
set "PATH=$WIN_BIN;%PATH%"
set "ffmpeg=$WIN_FFMPEG"
set "folder_sources=$WIN_SRC"
set "folder_destination=$WIN_DST"
set "audio_only=no"
set "merge_files=no"
set "create_frame=no"
set "copy_codecs=no"
set "extract_audio_copy=no"
set "audio_codec=:+:aac"
set "audio_number_channels=:+:2"
set "audio_bitrate=:+:128"
set "audio_sampling_rate=:+:48000"
set "audio_normalize=:-:loudnorm"
set "video_codec=:+:libx264"
set "video_resolution=:+:1280x720"
set "video_bitrate=:-:3000"
set "video_number_frames=:+:30"
set "video_rotation=:-:2"
set "video_subtitles=:-:burn"
set "video_quality=:-:23"
set "keep_aspect_ratio=:+:yes"
set "output_container=:+:mp4"
set "multithreads=:+:4"
set "parallel_files=:-:2"
set "hw_accel=:-:intel"
set "gpu_preset=:-:p5"
set "gpu_tune=:-:hq"
set "gpu_rc=:-:vbr"
set "playback_speed=:-:1.0"
set "start_coding=:-:01-00-00"
set "length_coding=:-:00-05-00"
set "split_by_silence=no"
set "silence_duration=2.0"
set "silence_threshold=-30dB"
set "save_old_extension=no"
set "format_files_in=3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
set "subtitles_style=FontName=Arial,FontSize=24,PrimaryColour=&HFFFFFF&"
set "dry_run=yes"
set "enable_log=no"
set "log_file=ffmpeg_convert.log"
call "$WIN_SCRIPT"
exit /b %ERRORLEVEL%
CMDEOF
# CRLF для cmd
sed -i 's/$/\r/' "$TMP_CMD"

WIN_CMD=$(cygpath -w "$TMP_CMD")

output=$(cmd //c "$WIN_CMD" < /dev/null 2>&1)
exit_code=$?

assert_not_contains "нет parse error 'was unexpected at this time'" "was unexpected at this time" "$output"
assert_eq "exit code 0" "0" "$exit_code"
assert_contains "вывод содержит DRY-RUN (файл дошёл до обработки)" "DRY-RUN" "$output"
assert_contains "DRY-RUN команда содержит входной sample.mp4" "sample.mp4" "$output"
assert_contains "DRY-RUN сохраняет литеральный % в имени файла" "50% off.mp4" "$output"
assert_not_contains "имя с % не искажено (нет '50 off.mp4')" "50 off.mp4" "$output"
assert_contains "DRY-RUN команда содержит -c:v libx264" "-c:v libx264" "$output"
assert_contains "итоговая сводка напечатана" "Обработано:" "$output"

rm -rf "$TMP_DIR"

summary
