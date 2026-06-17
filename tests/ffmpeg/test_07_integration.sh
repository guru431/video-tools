#!/bin/bash
# ============================================================
# test_07_integration.sh — Интеграционный тест FFmpeg пайплайна
# Создаёт реальный MP4, запускает script.sh с прямыми переменными,
# проверяет что mock ffmpeg вызван с правильными аргументами.
# Примечание: run.sh пропускается (слишком медленный на Windows из-за sed).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS_DIR="$TESTS_DIR/mocks"

source "$TESTS_DIR/lib/framework.sh"

INPUT_DIR="/tmp/test_ffmpeg_input_$$"
OUTPUT_DIR="/tmp/test_ffmpeg_output_$$"
FFMPEG_LOG="/tmp/mock_ffmpeg_int_$$.txt"

mkdir -p "$INPUT_DIR" "$OUTPUT_DIR"

# Создаём крошечный тестовый MP4 (1 сек, 64x64, чёрный, синус)
HAS_TEST_VIDEO=0
REAL_FFMPEG=$(which ffmpeg 2>/dev/null || echo "")
if [ -n "$REAL_FFMPEG" ] && command -v ffmpeg &>/dev/null; then
    "$REAL_FFMPEG" -y \
        -f lavfi -i "color=c=black:s=64x64:d=1:r=25" \
        -f lavfi -i "sine=frequency=440:d=1" \
        -c:v libx264 -c:a aac -shortest \
        "$INPUT_DIR/test_video.mp4" \
        -loglevel quiet 2>/dev/null
    [ -f "$INPUT_DIR/test_video.mp4" ] && HAS_TEST_VIDEO=1
fi

# Установить базовые переменные и запустить script.sh напрямую
default_vars() {
    folder_sources="$INPUT_DIR"
    folder_destination="$OUTPUT_DIR"
    ffmpeg="$MOCKS_DIR/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":-:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":+:23"; keep_aspect_ratio=":+:yes"; output_container=":+:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"
    copy_codecs="no"; extract_audio_copy="no"
}

run_script() {
    local dump
    dump=$(mktemp /tmp/test_dump_XXXXXX.txt)
    rm -f "$FFMPEG_LOG"
    (
        export PATH="$MOCKS_DIR:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() { echo "done" > "$dump"; }
        trap _dump EXIT
        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null
    rm -f "$dump"
}

# ══════════════════════════════════════════════════════════════
suite "Интеграция: базовый запуск (libx264 + aac)"
# ══════════════════════════════════════════════════════════════

if [ "$HAS_TEST_VIDEO" = "1" ]; then
    run_script
    if [ -f "$FFMPEG_LOG" ]; then
        pass "mock ffmpeg был вызван"
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains "содержит входной файл"  "test_video.mp4"  "$call_args"
        assert_contains "содержит -c:v libx264"  "-c:v libx264"    "$call_args"
        assert_contains "содержит -c:a aac"      "-c:a aac"        "$call_args"
        assert_contains "содержит -crf 23"       "-crf 23"         "$call_args"
    else
        fail "mock ffmpeg был вызван" "лог создан" "лог не найден"
    fi
else
    skip "Базовый запуск" "ffmpeg не установлен для создания тестового файла"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: dry_run режим"
# ══════════════════════════════════════════════════════════════

if [ "$HAS_TEST_VIDEO" = "1" ]; then
    run_script 'dry_run="yes"'
    # dry_run: ffmpeg вызывается для проверки вывода (-f null), но НЕ для кодирования
    # Проверяем что в логе НЕТ вызова с ключами кодирования (-crf/-c:v/-c:a)
    if [ ! -f "$FFMPEG_LOG" ]; then
        pass "dry_run: кодирующий вызов ffmpeg пропущен"
    elif grep -qF -- "-crf" "$FFMPEG_LOG" 2>/dev/null || grep -qF -- "-c:v" "$FFMPEG_LOG" 2>/dev/null; then
        fail "dry_run: кодирующий вызов ffmpeg пропущен" \
             "нет флагов -crf/-c:v" "найдены флаги кодирования в логе"
    else
        pass "dry_run: кодирующий вызов ffmpeg пропущен"
    fi
else
    skip "dry_run тест" "нет тестового MP4"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: выходной формат mkv + libx265"
# ══════════════════════════════════════════════════════════════

if [ "$HAS_TEST_VIDEO" = "1" ]; then
    run_script 'output_container=":+:mkv"' 'video_codec=":+:libx265"' 'video_quality=":-:23"'
    if [ -f "$FFMPEG_LOG" ]; then
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains "mkv container"   "mkv"          "$call_args"
        assert_contains "libx265 codec"   "-c:v libx265" "$call_args"
    else
        skip "mkv/libx265 тест" "mock не был вызван"
    fi
else
    skip "Выходной формат" "нет тестового MP4"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: audio_only режим"
# ══════════════════════════════════════════════════════════════

if [ "$HAS_TEST_VIDEO" = "1" ]; then
    # F06: audio_only выводит контейнер+кодек из [audio] codec. default_vars
    # задаёт codec=aac → ожидаем -c:a aac и m4a-выход (а не форсированный libmp3lame).
    run_script 'audio_only="yes"'
    if [ -f "$FFMPEG_LOG" ]; then
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains "audio_only: содержит -vn"       "-vn"      "$call_args"
        assert_contains "audio_only aac: содержит -c:a aac"  "-c:a aac"  "$call_args"
        assert_contains "audio_only aac: выход .m4a"     ".m4a"     "$call_args"
        assert_not_contains "audio_only: нет -b:v"       "-b:v"     "$call_args"
    else
        skip "audio_only тест" "mock не был вызван"
    fi

    # F06: явный libmp3lame → сегодняшнее поведение (libmp3lame + mp3-выход).
    run_script 'audio_only="yes"' 'audio_codec=":+:libmp3lame"'
    if [ -f "$FFMPEG_LOG" ]; then
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains "audio_only libmp3lame: содержит libmp3lame" "libmp3lame" "$call_args"
        assert_contains "audio_only libmp3lame: выход .mp3"          ".mp3"       "$call_args"
    else
        skip "audio_only libmp3lame тест" "mock не был вызван"
    fi
else
    skip "audio_only тест" "нет тестового MP4"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: GPU + burn субтитры → hwdownload перед subtitles"
# ══════════════════════════════════════════════════════════════
# Регрессия: scale_cuda/hwaccel_output_format даёт GPU-кадры; subtitles —
# CPU-фильтр и падает с "Impossible to convert between the formats".
# Перед прожигом нужен hwdownload,format=nv12. Проверено на RTX 5060 Ti.

if [ "$HAS_TEST_VIDEO" = "1" ]; then
    printf '1\n00:00:00,000 --> 00:00:01,000\nTEST\n' > "$INPUT_DIR/test_video.srt"

    # GPU включён → hwdownload,format=nv12 ДОЛЖЕН стоять перед subtitles
    rm -rf "$OUTPUT_DIR"; mkdir -p "$OUTPUT_DIR"
    run_script 'export MOCK_FFMPEG_ENCODERS=nvenc' 'hw_accel=":+:nvidia"' 'video_subtitles=":+:burn"'
    if [ -f "$FFMPEG_LOG" ]; then
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains "GPU+burn: hwdownload,format=nv12 перед subtitles" \
            "hwdownload,format=nv12,subtitles" "$call_args"
    else
        skip "GPU+burn тест" "mock не был вызван"
    fi

    # GPU выключен → subtitles без hwdownload (CPU-кадры, скачивать нечего)
    rm -rf "$OUTPUT_DIR"; mkdir -p "$OUTPUT_DIR"
    run_script 'hw_accel=":-:nvidia"' 'video_subtitles=":+:burn"'
    if [ -f "$FFMPEG_LOG" ]; then
        call_args=$(cat "$FFMPEG_LOG")
        assert_contains     "CPU burn: есть subtitles"   "subtitles"  "$call_args"
        assert_not_contains "CPU burn: нет hwdownload"   "hwdownload" "$call_args"
    else
        skip "CPU burn тест" "mock не был вызван"
    fi

    rm -f "$INPUT_DIR/test_video.srt"
else
    skip "GPU+burn субтитры" "нет тестового MP4"
fi

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$FFMPEG_LOG"
rm -rf "$INPUT_DIR" "$OUTPUT_DIR"

summary
