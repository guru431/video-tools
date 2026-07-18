#!/bin/bash
# ============================================================
# test_03_audio_args.sh — Тест формирования аудио-аргументов
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"

source "$TESTS_DIR/lib/framework.sh"

EMPTY_DIR=$(mktemp -d /tmp/test_au_XXXXXX)

default_vars() {
    folder_sources="$EMPTY_DIR"; folder_destination="$EMPTY_DIR"
    ffmpeg="$TESTS_DIR/mocks/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":-:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":-:23"; keep_aspect_ratio=":+:yes"; output_container=":-:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"
    copy_codecs="no"; extract_audio_copy="no"
}

# ── Запускаем script.sh в subshell; trap EXIT пишет переменные в файл ────────
# Трюк: exit внутри source оставляет stdout перенаправленным → пишем в файл
run_script() {
    local dump
    dump=$(mktemp /tmp/test_dump_XXXXXX.txt)

    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        default_vars
        for ov in "$@"; do eval "$ov"; done

        # Пишем в файл, а не в stdout (stdout может быть /dev/null после exit)
        _dump() {
            {
                echo "audio_codec_arg=${set_audio_codec:-}"
                echo "audio_channels_arg=${set_audio_number_channels:-}"
                echo "audio_bitrate_arg=${set_audio_bitrate:-}"
                echo "audio_sampling_arg=${set_audio_sampling_rate:-}"
                echo "af_chain=${af_chain:-}"
                echo "video_settings=${video_settings:-}"
                echo "format_files_out=${format_files_out:-}"
            } > "$1"
        }
        # Путь дампа передаём АРГУМЕНТОМ через строку trap (раскрывается здесь и сейчас),
        # а не читаем $dump внутри хендлера: bash 3.2 (системный на macOS) сбрасывает
        # local-контекст вызывающей функции ДО запуска EXIT-трапа, и $dump там пуст.
        trap "_dump '$dump'" EXIT

        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null

    # Читаем файл после завершения subshell
    cat "$dump"
    rm -f "$dump"
}

getv() { echo "$1" | grep "^${2}=" | cut -d= -f2-; }

# ══════════════════════════════════════════════════════════════
suite "Аудио: кодек"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:aac"')
assert_eq "codec +aac"        "-c:a aac"        "$(getv "$OUT" audio_codec_arg)"

OUT=$(run_script 'audio_codec=":+:libmp3lame"')
assert_eq "codec +libmp3lame" "-c:a libmp3lame" "$(getv "$OUT" audio_codec_arg)"

OUT=$(run_script 'audio_codec=":-:aac"')
assert_empty "codec -aac"  "$(getv "$OUT" audio_codec_arg)"

# ══════════════════════════════════════════════════════════════
suite "Аудио: каналы"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_number_channels=":+:1"')
assert_eq "channels +1" "-ac 1" "$(getv "$OUT" audio_channels_arg)"

OUT=$(run_script 'audio_number_channels=":+:2"')
assert_eq "channels +2" "-ac 2" "$(getv "$OUT" audio_channels_arg)"

OUT=$(run_script 'audio_number_channels=":-:2"')
assert_empty "channels -2"  "$(getv "$OUT" audio_channels_arg)"

# ══════════════════════════════════════════════════════════════
suite "Аудио: битрейт и sampling"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_bitrate=":+:192"' 'audio_sampling_rate=":+:48000"')
assert_eq "bitrate +192"     "-b:a 192k" "$(getv "$OUT" audio_bitrate_arg)"
assert_eq "sampling +48000"  "-ar 48000" "$(getv "$OUT" audio_sampling_arg)"

OUT=$(run_script 'audio_bitrate=":-:128"' 'audio_sampling_rate=":-:44100"')
assert_empty "bitrate -128"   "$(getv "$OUT" audio_bitrate_arg)"
assert_empty "sampling -44100" "$(getv "$OUT" audio_sampling_arg)"

# ══════════════════════════════════════════════════════════════
suite "Аудио: нормализация"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_normalize=":+:loudnorm"')
assert_contains "loudnorm"   "loudnorm=I=-16" "$(getv "$OUT" af_chain)"

OUT=$(run_script 'audio_normalize=":+:dynaudnorm"')
assert_contains "dynaudnorm" "dynaudnorm"     "$(getv "$OUT" af_chain)"

OUT=$(run_script 'audio_normalize=":-:loudnorm"')
assert_empty "normalize -"  "$(getv "$OUT" af_chain)"

# ══════════════════════════════════════════════════════════════
suite "Аудио: audio_only (F06 — контейнер/кодек из [audio] codec)"
# ══════════════════════════════════════════════════════════════
# F06: audio_only больше не форсит mp3/libmp3lame всегда — он выводит ext+encoder
# из настроенного [audio] codec. default_vars задаёт codec=aac → ожидаем m4a/aac.

OUT=$(run_script 'audio_only="yes"')
assert_eq "audio_only: -vn"         "-vn"        "$(getv "$OUT" video_settings)"
assert_eq "audio_only aac: format=m4a"  "m4a"    "$(getv "$OUT" format_files_out)"
assert_eq "audio_only aac: -c:a aac"    "-c:a aac" "$(getv "$OUT" audio_codec_arg)"

# Явно libmp3lame → сегодняшнее поведение (mp3 / libmp3lame)
OUT=$(run_script 'audio_only="yes"' 'audio_codec=":+:libmp3lame"')
assert_eq "audio_only libmp3lame: format=mp3"   "mp3"             "$(getv "$OUT" format_files_out)"
assert_eq "audio_only libmp3lame: -c:a libmp3lame" "-c:a libmp3lame" "$(getv "$OUT" audio_codec_arg)"

rm -rf "$EMPTY_DIR"
summary
