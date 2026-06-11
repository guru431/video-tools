#!/bin/bash
# test_05_filters.sh — Тест цепочек фильтров (transpose, scale, setpts, atempo)

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
source "$TESTS_DIR/lib/framework.sh"

EMPTY_DIR=$(mktemp -d /tmp/test_flt_XXXXXX)

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
    dump=$(mktemp /tmp/test_dump_XXXXXX.txt)
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() { { echo "vf_chain=${vf_chain:-}"; echo "af_chain=${af_chain:-}"; } > "$dump"; }
        trap _dump EXIT
        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null
    cat "$dump"; rm -f "$dump"
}

getv() { echo "$1" | grep "^${2}=" | cut -d= -f2-; }

suite "Фильтры: поворот (transpose)"
OUT=$(run_script 'video_rotation=":+:1"')
VF=$(getv "$OUT" vf_chain)
assert_contains "rotation +1 -> transpose=1"  "transpose=1"  "$VF"
assert_not_contains "rotation +1: нет =2"     "transpose=2"  "$VF"

OUT=$(run_script 'video_rotation=":+:2"')
assert_contains "rotation +2 -> transpose=2"  "transpose=2"  "$(getv "$OUT" vf_chain)"

OUT=$(run_script 'video_rotation=":-:1"')
assert_not_contains "rotation - -> нет transpose"  "transpose"  "$(getv "$OUT" vf_chain)"

suite "Фильтры: масштабирование (scale)"
OUT=$(run_script 'video_resolution=":+:1280x720"' 'keep_aspect_ratio=":+:yes"')
VF=$(getv "$OUT" vf_chain)
assert_contains "1280x720 + aspect: scale"      "scale=1280:720"                   "$VF"
assert_contains "1280x720 + aspect: force_ar"   "force_original_aspect_ratio=decrease" "$VF"

OUT=$(run_script 'video_resolution=":+:1280x720"' 'keep_aspect_ratio=":-:yes"')
VF=$(getv "$OUT" vf_chain)
assert_contains "1280x720 no aspect: scale"      "scale=1280:720"  "$VF"
assert_not_contains "1280x720 no aspect: no ar"  "force_original_aspect_ratio"  "$VF"

OUT=$(run_script 'video_resolution=":+:1920x1080"' 'keep_aspect_ratio=":+:yes"')
assert_contains "1920x1080"  "scale=1920:1080"  "$(getv "$OUT" vf_chain)"

OUT=$(run_script 'video_resolution=":-:1280x720"')
assert_not_contains "resolution - -> нет scale"  "scale="  "$(getv "$OUT" vf_chain)"

suite "Фильтры: скорость воспроизведения"
OUT=$(run_script 'playback_speed=":+:2.0"')
assert_contains "speed 2.0: setpts"  "setpts=PTS/2.0"  "$(getv "$OUT" vf_chain)"
assert_contains "speed 2.0: atempo"  "atempo=2"         "$(getv "$OUT" af_chain)"

OUT=$(run_script 'playback_speed=":+:1.0"')
assert_not_contains "speed 1.0: нет setpts"  "setpts"  "$(getv "$OUT" vf_chain)"
assert_not_contains "speed 1.0: нет atempo"  "atempo"  "$(getv "$OUT" af_chain)"

OUT=$(run_script 'playback_speed=":-:1.0"')
assert_not_contains "speed disabled: нет setpts"  "setpts"  "$(getv "$OUT" vf_chain)"

suite "Фильтры: atempo каскад (> 2.0)"
OUT=$(run_script 'playback_speed=":+:4.0"')
assert_contains "speed 4.0 -> каскад 2x2"  "atempo=2.0,atempo=2.0"  "$(getv "$OUT" af_chain)"

OUT=$(run_script 'playback_speed=":+:3.0"')
AF=$(getv "$OUT" af_chain)
assert_contains "speed 3.0: atempo=2.0"  "atempo=2.0"  "$AF"
assert_contains "speed 3.0: atempo=1.5"  "atempo=1.5"  "$AF"

suite "Фильтры: atempo каскад (< 0.5)"
OUT=$(run_script 'playback_speed=":+:0.25"')
assert_contains "speed 0.25 -> каскад 0.5x0.5"  "atempo=0.5,atempo=0.5"  "$(getv "$OUT" af_chain)"

suite "Фильтры: комбо rotate + scale"
OUT=$(run_script 'video_rotation=":+:1"' 'video_resolution=":+:1280x720"' 'keep_aspect_ratio=":-:yes"')
VF=$(getv "$OUT" vf_chain)
assert_contains "комбо: transpose=1"    "transpose=1"    "$VF"
assert_contains "комбо: scale=1280:720" "scale=1280:720" "$VF"
t_pos=$(echo "$VF" | grep -bo "transpose" | head -1 | cut -d: -f1)
s_pos=$(echo "$VF" | grep -bo "scale" | head -1 | cut -d: -f1)
if [ -n "$t_pos" ] && [ -n "$s_pos" ] && [ "$t_pos" -lt "$s_pos" ]; then
    pass "комбо: transpose стоит перед scale"
else
    fail "комбо: transpose перед scale" "transpose раньше" "vf=$VF"
fi

suite "Фильтры: rotation + GPU → CPU fallback (Task 4)"
# transpose_cuda не существует: при rotation+GPU вся цепочка должна быть на CPU
OUT=$(run_script 'MOCK_FFMPEG_ENCODERS="V..... h264_nvenc"' 'hw_accel=":+:nvidia"' \
    'video_rotation=":+:2"' 'video_resolution=":+:1280x720"' 'keep_aspect_ratio=":+:yes"')
VF=$(getv "$OUT" vf_chain)
assert_contains "rotation+nvidia → transpose=2"  "transpose=2"  "$VF"
assert_not_contains "rotation+nvidia → нет transpose_cuda"  "transpose_cuda"  "$VF"
assert_contains "rotation+nvidia → CPU scale"  "scale=1280:720:force_original_aspect_ratio"  "$VF"
assert_not_contains "rotation+nvidia → нет scale_cuda"  "scale_cuda"  "$VF"
assert_contains "rotation+nvidia → hwdownload в цепочке"  "hwdownload"  "$VF"

suite "script.sh: фиксы Task 4 (анализ исходника)"
src_sh="$(cat "$SCRIPT")"
# Muxer map: mkv/ts — расширения файла, не имена форматов ffmpeg
assert_contains "muxer map: matroska"  "matroska"  "$src_sh"
assert_contains "muxer map: mpegts"  "mpegts"  "$src_sh"
assert_contains "-f использует \$muxer_out"  '-f $muxer_out'  "$src_sh"
# transpose_cuda удалён из всего скрипта
assert_not_contains "нет несуществующего transpose_cuda"  "transpose_cuda"  "$src_sh"
# -nostdin в главном вызове ffmpeg (иначе ffmpeg съедает NUL-список из stdin цикла)
assert_contains "-nostdin в main ffmpeg"  '"$ffmpeg" -nostdin -hide_banner'  "$src_sh"
# Цикл чтения файлов: read -r -d '' (без -r теряются backslash в путях)
assert_not_contains "нет read без -r (буквальный \$'\\\\0')"  "while read -d \$'\\0' full_path"  "$src_sh"
# Экранирование субтитров: backslash → forward slash перед остальным
assert_contains "субтитры: backslash → slash"  's#\\#/#g'  "$src_sh"

rm -rf "$EMPTY_DIR"
summary
