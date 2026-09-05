#!/bin/bash
# test_04_video_args.sh — Тест формирования видео-аргументов

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
source "$TESTS_DIR/lib/framework.sh"

EMPTY_DIR=$(mktemp -d /tmp/test_vid_XXXXXX)

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

run_script() {
    local dump
    dump=$(mktemp_suffix /tmp/test_dump_ .txt)
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() {
            {
                echo "video_codec_arg=${set_video_codec_arg:-}"
                echo "video_frames=${set_video_number_frames:-}"
                echo "crf_args=${crf_args:-}"
                echo "format_files_out=${format_files_out:-}"
                echo "video_settings=${video_settings:-}"
            } > "$1"
        }
        # Путь дампа передаём АРГУМЕНТОМ через строку trap (раскрывается здесь и сейчас),
        # а не читаем $dump внутри хендлера: bash 3.2 (системный на macOS) сбрасывает
        # local-контекст вызывающей функции ДО запуска EXIT-трапа, и $dump там пуст.
        trap "_dump '$dump'" EXIT
        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null
    cat "$dump"; rm -f "$dump"
}

getv() { echo "$1" | grep "^${2}=" | cut -d= -f2-; }

suite "Видео: кодек"
OUT=$(run_script 'video_codec=":+:libx264"')
assert_contains "codec +libx264"   "-c:v libx264"   "$(getv "$OUT" video_codec_arg)"

OUT=$(run_script 'video_codec=":+:libx265"')
assert_contains "codec +libx265"   "-c:v libx265"   "$(getv "$OUT" video_codec_arg)"

OUT=$(run_script 'video_codec=":+:libsvtav1"')
assert_contains "codec +libsvtav1" "-c:v libsvtav1" "$(getv "$OUT" video_codec_arg)"

OUT=$(run_script 'video_codec=":-:libx264"')
assert_empty "codec -libx264"  "$(getv "$OUT" video_codec_arg)"

suite "Видео: качество (CRF)"
OUT=$(run_script 'video_quality=":+:23"')
assert_eq "quality +23" "-crf 23" "$(getv "$OUT" crf_args)"

OUT=$(run_script 'video_quality=":+:28"')
assert_eq "quality +28" "-crf 28" "$(getv "$OUT" crf_args)"

OUT=$(run_script 'video_quality=":-:23"')
assert_empty "quality -23"  "$(getv "$OUT" crf_args)"

suite "Видео: контейнер"
OUT=$(run_script 'output_container=":+:mkv"')
assert_eq "container +mkv"  "mkv"  "$(getv "$OUT" format_files_out)"

# webm требует VP8/VP9/AV1 + Opus/Vorbis (F8-валидация иначе отклонит libx264/aac).
OUT=$(run_script 'output_container=":+:webm"' 'video_codec=":+:libvpx-vp9"' 'audio_codec=":+:libopus"')
assert_eq "container +webm" "webm" "$(getv "$OUT" format_files_out)"

OUT=$(run_script 'output_container=":+:avi"')
assert_eq "container +avi"  "avi"  "$(getv "$OUT" format_files_out)"

OUT=$(run_script 'output_container=":-:mp4"')
assert_eq "container - -> default mp4" "mp4" "$(getv "$OUT" format_files_out)"

suite "Видео: частота кадров"
OUT=$(run_script 'video_number_frames=":+:30"')
assert_eq "framerate +30" "-r 30" "$(getv "$OUT" video_frames)"

OUT=$(run_script 'video_number_frames=":+:60"')
assert_eq "framerate +60" "-r 60" "$(getv "$OUT" video_frames)"

OUT=$(run_script 'video_number_frames=":-:25"')
assert_empty "framerate -25"  "$(getv "$OUT" video_frames)"


# ══════════════════════════════════════════════════════════════
suite "Видео: имена контейнеров, у которых нет своего muxer'а"
# ══════════════════════════════════════════════════════════════
# ffmpeg выбирает muxer ПО РАСШИРЕНИЮ выходного файла, а расширение и имя muxer'а
# совпадают не всегда. `container = +m4v` давал сырой elementary-stream — файл,
# который не открывает ни один плеер, при коде возврата 0; `mpg`/`wmv`/`mts`/`m2ts`
# либо брали не тот muxer, либо не находились вовсе. Отображаем известные случаи
# и говорим об этом вслух: молча отдать неоткрываемый файл хуже, чем сменить
# расширение с объяснением.
OUT=$(run_script 'output_container=":+:m4v"')
assert_eq "container +m4v → mp4"   "mp4"    "$(getv "$OUT" format_files_out)"
OUT=$(run_script 'output_container=":+:mpg"')
assert_eq "container +mpg → mpeg"  "mpeg"   "$(getv "$OUT" format_files_out)"
OUT=$(run_script 'output_container=":+:wmv"')
assert_eq "container +wmv → asf"   "asf"    "$(getv "$OUT" format_files_out)"
OUT=$(run_script 'output_container=":+:mts"')
assert_eq "container +mts → mpegts"  "mpegts" "$(getv "$OUT" format_files_out)"
OUT=$(run_script 'output_container=":+:m2ts"')
assert_eq "container +m2ts → mpegts" "mpegts" "$(getv "$OUT" format_files_out)"
# Нормальные имена не трогаем: подмена должна быть узким списком, а не фильтром.
OUT=$(run_script 'output_container=":+:mkv"')
assert_eq "container +mkv не трогаем" "mkv" "$(getv "$OUT" format_files_out)"

# Подмена молчаливой быть не должна — пользователь получит файл с другим
# расширением, чем просил в config.ini.
OUT_TXT=$( (
    export PATH="$TESTS_DIR/mocks:$PATH"; export MOCK_FFMPEG_ENCODERS=""
    default_vars; output_container=":+:m4v"
    source "$SCRIPT" 2>&1
) < /dev/null )
assert_contains "SH: подмена m4v объяснена вслух" "container = m4v" "$OUT_TXT"

# Паритет: то же отображение обязано быть в PS1 и CMD — иначе один config.ini
# даёт три разных расширения выхода.
PS1_SRC=$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")
CMD_SRC=$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")
assert_contains "PS1: m4v → mp4"   'container = m4v'  "$PS1_SRC"
assert_contains "PS1: mpg → mpeg"  'container = mpg'  "$PS1_SRC"
assert_contains "PS1: wmv → asf"   'container = wmv'  "$PS1_SRC"
assert_contains "PS1: mts/m2ts → mpegts" '(mts|m2ts)' "$PS1_SRC"
assert_contains "CMD: m4v → mp4"   'format_files_out!"=="m4v"'  "$CMD_SRC"
assert_contains "CMD: mpg → mpeg"  'format_files_out!"=="mpg"'  "$CMD_SRC"
assert_contains "CMD: wmv → asf"   'format_files_out!"=="wmv"'  "$CMD_SRC"
assert_contains "CMD: mts → mpegts"  'format_files_out!"=="mts"'  "$CMD_SRC"
assert_contains "CMD: m2ts → mpegts" 'format_files_out!"=="m2ts"' "$CMD_SRC"

rm -rf "$EMPTY_DIR"
summary
