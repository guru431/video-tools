#!/bin/bash
# ============================================================
# test_14_audio_only_codec.sh — F06: audio_only выводит контейнер+кодек
# из настроенного [audio] codec (а не форсит mp3/libmp3lame всегда).
#
# Маппинг (SPEC F06):
#   libmp3lame|mp3 -> mp3  / -c:a libmp3lame
#   aac            -> m4a  / -c:a aac
#   libopus|opus   -> opus / -c:a libopus
#   flac           -> flac / -c:a flac
#   libvorbis|vorbis -> ogg / -c:a libvorbis
#   unset/unknown  -> mp3  / -c:a libmp3lame (сегодняшнее поведение)
# При audio_only=yes: video_settings=-vn и НЕТ -b:v (set_video_bitrate_final пуст).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"

source "$TESTS_DIR/lib/framework.sh"

EMPTY_DIR=$(mktemp -d /tmp/test_f06_XXXXXX)

default_vars() {
    folder_sources="$EMPTY_DIR"; folder_destination="$EMPTY_DIR"
    ffmpeg="$TESTS_DIR/mocks/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    # video_bitrate включён — проверяем что в audio_only режиме он НЕ даёт -b:v
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":+:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":-:23"; keep_aspect_ratio=":+:yes"; output_container=":-:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="yes"; merge_files="no"; create_frame="no"
    copy_codecs="no"; extract_audio_copy="no"
}

run_script() {
    local dump
    dump=$(mktemp /tmp/test_f06_dump_XXXXXX.txt)
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() {
            {
                echo "format_files_out=${format_files_out:-}"
                echo "audio_codec_arg=${set_audio_codec:-}"
                echo "video_settings=${video_settings:-}"
                echo "video_bitrate_final=${set_video_bitrate_final:-}"
                echo "audio_settings=${audio_settings:-}"
            } > "$1"
        }
        # Путь дампа передаём АРГУМЕНТОМ через строку trap (раскрывается здесь и сейчас),
        # а не читаем $dump внутри хендлера: bash 3.2 (системный на macOS) сбрасывает
        # local-контекст вызывающей функции ДО запуска EXIT-трапа, и $dump там пуст.
        trap "_dump '$dump'" EXIT
        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null
    cat "$dump"
    rm -f "$dump"
}

getv() { echo "$1" | grep "^${2}=" | cut -d= -f2-; }

# ══════════════════════════════════════════════════════════════
suite "F06: aac → m4a / -c:a aac (НЕ форсированный mp3)"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:aac"')
assert_eq "aac: format=m4a"     "m4a"      "$(getv "$OUT" format_files_out)"
assert_eq "aac: -c:a aac"       "-c:a aac" "$(getv "$OUT" audio_codec_arg)"
assert_eq "aac: video_settings=-vn"  "-vn" "$(getv "$OUT" video_settings)"
assert_empty "aac: НЕТ -b:v в audio_only"  "$(getv "$OUT" video_bitrate_final)"
assert_not_contains "aac: audio_settings без -b:v"  "-b:v"  "$(getv "$OUT" audio_settings)"

# ══════════════════════════════════════════════════════════════
suite "F06: libmp3lame / mp3 → mp3 / -c:a libmp3lame"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:libmp3lame"')
assert_eq "libmp3lame: format=mp3"        "mp3"             "$(getv "$OUT" format_files_out)"
assert_eq "libmp3lame: -c:a libmp3lame"   "-c:a libmp3lame" "$(getv "$OUT" audio_codec_arg)"

OUT=$(run_script 'audio_codec=":+:mp3"')
assert_eq "mp3: format=mp3"        "mp3"             "$(getv "$OUT" format_files_out)"
assert_eq "mp3: -c:a libmp3lame"   "-c:a libmp3lame" "$(getv "$OUT" audio_codec_arg)"

# ══════════════════════════════════════════════════════════════
suite "F06: opus / libopus → opus / -c:a libopus"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:libopus"')
assert_eq "libopus: format=opus"    "opus"        "$(getv "$OUT" format_files_out)"
assert_eq "libopus: -c:a libopus"   "-c:a libopus" "$(getv "$OUT" audio_codec_arg)"

OUT=$(run_script 'audio_codec=":+:opus"')
assert_eq "opus: format=opus"    "opus"         "$(getv "$OUT" format_files_out)"
assert_eq "opus: -c:a libopus"   "-c:a libopus" "$(getv "$OUT" audio_codec_arg)"

# ══════════════════════════════════════════════════════════════
suite "F06: flac → flac / -c:a flac"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:flac"')
assert_eq "flac: format=flac"   "flac"      "$(getv "$OUT" format_files_out)"
assert_eq "flac: -c:a flac"     "-c:a flac" "$(getv "$OUT" audio_codec_arg)"

# ══════════════════════════════════════════════════════════════
suite "F06: libvorbis / vorbis → ogg / -c:a libvorbis"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:libvorbis"')
assert_eq "libvorbis: format=ogg"     "ogg"           "$(getv "$OUT" format_files_out)"
assert_eq "libvorbis: -c:a libvorbis" "-c:a libvorbis" "$(getv "$OUT" audio_codec_arg)"

OUT=$(run_script 'audio_codec=":+:vorbis"')
assert_eq "vorbis: format=ogg"     "ogg"            "$(getv "$OUT" format_files_out)"
assert_eq "vorbis: -c:a libvorbis" "-c:a libvorbis" "$(getv "$OUT" audio_codec_arg)"

# ══════════════════════════════════════════════════════════════
suite "F06: неизвестный/unset codec → mp3 / -c:a libmp3lame (fallback)"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script 'audio_codec=":+:somethingweird"')
assert_eq "unknown: format=mp3"        "mp3"             "$(getv "$OUT" format_files_out)"
assert_eq "unknown: -c:a libmp3lame"   "-c:a libmp3lame" "$(getv "$OUT" audio_codec_arg)"

rm -rf "$EMPTY_DIR"
summary
