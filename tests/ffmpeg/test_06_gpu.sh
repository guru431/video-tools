#!/bin/bash
# ============================================================
# test_06_gpu.sh — Тест GPU (NVIDIA NVENC / Intel QSV)
# Управляется через MOCK_FFMPEG_ENCODERS=nvenc|qsv|""
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"

source "$TESTS_DIR/lib/framework.sh"

EMPTY_DIR=$(mktemp -d /tmp/test_gpu_XXXXXX)

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
    local encoders="$1"; shift
    local dump
    dump=$(mktemp /tmp/test_dump_XXXXXX.txt)
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS="$encoders"
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() {
            {
                echo "use_hw_accel=${use_hw_accel:-no}"
                echo "hw_accel_type=${hw_accel_type:-}"
                echo "set_video_codec=${set_video_codec:-}"
                echo "gpu_args=${gpu_args:-}"
                echo "crf_args=${crf_args:-}"
                echo "hw_decode_args=${hw_decode_args:-}"
            } > "$dump"
        }
        trap _dump EXIT
        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null
    cat "$dump"; rm -f "$dump"
}

getv() { echo "$1" | grep "^${2}=" | cut -d= -f2-; }

# ══════════════════════════════════════════════════════════════
suite "GPU NVIDIA: замена кодека"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "nvenc" 'hw_accel=":+:nvidia"' 'video_codec=":+:libx264"')
assert_eq "nvidia: use_hw_accel=yes"       "yes"       "$(getv "$OUT" use_hw_accel)"
assert_eq "nvidia: hw_accel_type=nvidia"   "nvidia"    "$(getv "$OUT" hw_accel_type)"
assert_eq "nvidia: libx264 → h264_nvenc"   "h264_nvenc" "$(getv "$OUT" set_video_codec)"

OUT=$(run_script "nvenc" 'hw_accel=":+:nvidia"' 'video_codec=":+:libx265"')
assert_eq "nvidia: libx265 → hevc_nvenc"  "hevc_nvenc"  "$(getv "$OUT" set_video_codec)"

OUT=$(run_script "nvenc" 'hw_accel=":+:nvidia"' 'video_codec=":+:libsvtav1"')
assert_eq "nvidia: libsvtav1 → av1_nvenc"  "av1_nvenc"  "$(getv "$OUT" set_video_codec)"

# ══════════════════════════════════════════════════════════════
suite "GPU NVIDIA: параметры качества"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "nvenc" \
    'hw_accel=":+:nvidia"' 'video_codec=":+:libx264"' \
    'video_quality=":+:28"' 'gpu_preset=":+:p5"' 'gpu_tune=":+:hq"' 'gpu_rc=":+:vbr"')

GP=$(getv "$OUT" gpu_args)
CR=$(getv "$OUT" crf_args)
# F6: флаг качества выбирается по суффиксу энкодера и живёт в crf_args (nvenc → -cq);
# gpu_args держит только preset/tune/rc. Итоговая команда содержит -cq в любом случае.
assert_contains "nvidia: -cq 28 (crf_args)"  "-cq 28"     "$CR"
assert_contains "nvidia: -preset p5"  "-preset p5" "$GP"
assert_contains "nvidia: -tune hq"    "-tune hq"   "$GP"
assert_contains "nvidia: -rc vbr"     "-rc vbr"    "$GP"
assert_not_contains "nvidia: -cq не в gpu_args" "-cq" "$GP"

# ══════════════════════════════════════════════════════════════
suite "GPU Intel QSV: замена кодека"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "qsv" 'hw_accel=":+:intel"' 'video_codec=":+:libx264"')
assert_eq "intel: use_hw_accel=yes"    "yes"       "$(getv "$OUT" use_hw_accel)"
assert_eq "intel: hw_accel_type=intel" "intel"     "$(getv "$OUT" hw_accel_type)"
assert_eq "intel: libx264 → h264_qsv"  "h264_qsv"  "$(getv "$OUT" set_video_codec)"

OUT=$(run_script "qsv" 'hw_accel=":+:intel"' 'video_codec=":+:libx265"')
assert_eq "intel: libx265 → hevc_qsv"  "hevc_qsv"  "$(getv "$OUT" set_video_codec)"

OUT=$(run_script "qsv" 'hw_accel=":+:intel"' 'video_codec=":+:libsvtav1"')
assert_eq "intel: libsvtav1 → av1_qsv"  "av1_qsv"  "$(getv "$OUT" set_video_codec)"

# ══════════════════════════════════════════════════════════════
suite "GPU Intel QSV: параметры качества"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "qsv" \
    'hw_accel=":+:intel"' 'video_codec=":+:libx264"' \
    'video_quality=":+:23"' 'gpu_preset=":+:fast"')

GP=$(getv "$OUT" gpu_args)
CR=$(getv "$OUT" crf_args)
assert_contains "intel: -global_quality 23 (crf_args)"  "-global_quality 23"  "$CR"
assert_contains "intel: -preset fast"        "-preset fast"        "$GP"
assert_not_contains "intel: -global_quality не в gpu_args" "-global_quality" "$GP"

# ══════════════════════════════════════════════════════════════
suite "GPU: NVENC не поддерживается (нет nvenc в mock)"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "" 'hw_accel=":+:nvidia"' 'video_codec=":+:libx264"')
assert_eq "no nvenc: use_hw_accel=no"      "no"      "$(getv "$OUT" use_hw_accel)"
assert_eq "no nvenc: кодек без замены"     "libx264" "$(getv "$OUT" set_video_codec)"

# ══════════════════════════════════════════════════════════════
suite "GPU: hw_accel отключён (-)"
# ══════════════════════════════════════════════════════════════

OUT=$(run_script "nvenc" \
    'hw_accel=":-:nvidia"' 'video_codec=":+:libx264"' 'video_quality=":+:23"')
assert_eq "hw disabled: use_hw_accel=no"   "no"       "$(getv "$OUT" use_hw_accel)"
assert_eq "hw disabled: кодек без замены"  "libx264"  "$(getv "$OUT" set_video_codec)"
assert_eq "hw disabled: crf_args=-crf 23"  "-crf 23"  "$(getv "$OUT" crf_args)"

# ══════════════════════════════════════════════════════════════
suite "F6: прямой hw-кодек при выключенном hw_accel → -cq/-global_quality, не -crf"
# ══════════════════════════════════════════════════════════════
# nvenc/qsv отвергают -crf; если пользователь указал h264_nvenc напрямую, а hw_accel
# выключен (или backend недоступен), флаг качества всё равно должен быть -cq/-global_quality.

OUT=$(run_script "" 'hw_accel=":-:nvidia"' 'video_codec=":+:h264_nvenc"' 'video_quality=":+:23"')
assert_eq "h264_nvenc+hwoff: use_hw_accel=no"  "no"       "$(getv "$OUT" use_hw_accel)"
assert_eq "h264_nvenc+hwoff: crf_args=-cq 23"  "-cq 23"   "$(getv "$OUT" crf_args)"

OUT=$(run_script "" 'hw_accel=":-:intel"' 'video_codec=":+:h264_qsv"' 'video_quality=":+:23"')
assert_eq "h264_qsv+hwoff: crf_args=-global_quality 23"  "-global_quality 23"  "$(getv "$OUT" crf_args)"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$EMPTY_DIR"

summary
