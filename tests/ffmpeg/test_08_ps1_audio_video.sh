#!/bin/bash
# ============================================================
# test_08_ps1_audio_video.sh — Тест PS1: аудио/видео аргументы
# Тестирует построение аргументов -c:a, -b:a, -ac, -ar,
# -c:v, -r, -crf, -b:v, а также copy_codecs + фильтры.
# Использует inline PowerShell без запуска полного скрипта.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути). На Linux/CI пропускаем.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "PS1 audio/video аргументы"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

# ── Хелпер: запустить секцию построения аргументов PS1 ─────────────────────
# Принимает переменные в формате :+:/:-: и возвращает результирующие
# audio/video аргументы через stdout (одна переменная на строку: NAME=VALUE)
run_ps1_args() {
    local audio_codec="${1:-:+:aac}"
    local audio_channels="${2:-:+:2}"
    local audio_bitrate="${3:-:+:128}"
    local audio_sampling_rate="${4:-:+:48000}"
    local video_codec="${5:-:+:libx264}"
    local video_frames="${6--:25}"
    local video_quality="${7-:+:23}"
    local video_bitrate="${8-:-:2000}"
    local copy_codecs="${9:-no}"

    $PS_CMD -NoProfile -NonInteractive -Command "
\$audio_codec            = '$audio_codec'
\$audio_number_channels  = '$audio_channels'
\$audio_bitrate          = '$audio_bitrate'
\$audio_sampling_rate    = '$audio_sampling_rate'
\$video_codec            = '$video_codec'
\$video_number_frames    = '$video_frames'
\$video_quality          = '$video_quality'
\$video_bitrate          = '$video_bitrate'
\$copy_codecs            = '$copy_codecs'

# Парсинг :status:value
\$_, \$audio_codec_status,            \$audio_codec_value            = \$audio_codec            -split ':'
\$_, \$audio_number_channels_status,  \$audio_number_channels_value  = \$audio_number_channels  -split ':'
\$_, \$audio_bitrate_status,          \$audio_bitrate_value          = \$audio_bitrate          -split ':'
\$_, \$audio_sampling_rate_status,    \$audio_sampling_rate_value    = \$audio_sampling_rate    -split ':'
\$_, \$video_codec_status,            \$video_codec_value            = \$video_codec            -split ':'
\$_, \$video_number_frames_status,    \$video_number_frames_value    = \$video_number_frames    -split ':'
\$_, \$video_quality_status,          \$video_quality_value          = \$video_quality          -split ':'
\$_, \$video_bitrate_status,          \$video_bitrate_value          = \$video_bitrate          -split ':'

# Формирование аудио-параметров (как в script.ps1 строки 56-59)
\$set_audio_codec          = if (\$audio_codec_status   -eq '+') { \"-c:a \$audio_codec_value\"          } else { '' }
\$set_audio_number_channels= if (\$audio_number_channels_status -eq '+') { \"-ac \$audio_number_channels_value\" } else { '' }
\$set_audio_bitrate        = if (\$audio_bitrate_status -eq '+') { \"-b:a \${audio_bitrate_value}k\"      } else { '' }
\$set_audio_sampling_rate  = if (\$audio_sampling_rate_status -eq '+') { \"-ar \$audio_sampling_rate_value\" } else { '' }

# Формирование видео-параметров (строки 62-64)
\$set_video_codec         = if (\$video_codec_status          -eq '+') { \$video_codec_value          } else { '' }
\$set_video_number_frames = if (\$video_number_frames_status  -eq '+') { \"-r \$video_number_frames_value\" } else { '' }
\$set_video_quality       = if (\$video_quality_status        -eq '+') { \"-crf \$video_quality_value\" } else { '' }
\$set_video_bitrate       = if (\$video_bitrate_status        -eq '+') { \"-b:v \${video_bitrate_value}k\" } else { '' }

# copy_codecs: итоговый convert_settings
if (\$copy_codecs -eq 'yes') {
    \$convert_settings = '-c copy'
} else {
    \$vf_args = @()
    \$af_args = @()
    # copy_codecs несовместим с фильтрами (Bug 3 fix)
    if (\$copy_codecs -eq 'yes') { \$vf_args = @(); \$af_args = @() }
    \$convert_settings = (\$set_audio_codec, \$set_audio_number_channels,
                         \$set_audio_bitrate, \$set_audio_sampling_rate,
                         \$set_video_number_frames, \$set_video_quality) -join ' '
}

Write-Output \"set_audio_codec=\$set_audio_codec\"
Write-Output \"set_audio_number_channels=\$set_audio_number_channels\"
Write-Output \"set_audio_bitrate=\$set_audio_bitrate\"
Write-Output \"set_audio_sampling_rate=\$set_audio_sampling_rate\"
Write-Output \"set_video_codec=\$set_video_codec\"
Write-Output \"set_video_number_frames=\$set_video_number_frames\"
Write-Output \"set_video_quality=\$set_video_quality\"
Write-Output \"set_video_bitrate=\$set_video_bitrate\"
Write-Output \"convert_settings=\$convert_settings\"
" 2>/dev/null
}

# ── Хелпер: получить одно поле из вывода run_ps1_args ──────────────────────
get_field() {
    local output="$1"
    local field="$2"
    echo "$output" | grep "^${field}=" | sed "s/^${field}=//"
}

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио аргументы (+включено)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":+:aac" ":+:2" ":+:128" ":+:48000")
assert_eq "audio codec +aac → -c:a aac"     "-c:a aac"     "$(get_field "$out" "set_audio_codec")"
assert_eq "audio channels +2 → -ac 2"       "-ac 2"        "$(get_field "$out" "set_audio_number_channels")"
assert_eq "audio bitrate +128 → -b:a 128k"  "-b:a 128k"    "$(get_field "$out" "set_audio_bitrate")"
assert_eq "audio rate +48000 → -ar 48000"   "-ar 48000"    "$(get_field "$out" "set_audio_sampling_rate")"

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио аргументы (−выключено)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":-:aac" ":-:2" ":-:128" ":-:48000")
assert_eq "audio codec -aac → пустой"    "" "$(get_field "$out" "set_audio_codec")"
assert_eq "audio channels -2 → пустой"  "" "$(get_field "$out" "set_audio_number_channels")"
assert_eq "audio bitrate -128 → пустой" "" "$(get_field "$out" "set_audio_bitrate")"
assert_eq "audio rate -48000 → пустой"  "" "$(get_field "$out" "set_audio_sampling_rate")"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео аргументы (+включено)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":+:aac" ":+:2" ":+:128" ":+:48000" \
                   ":+:libx264" ":+:30" ":+:23" ":-:3000")
assert_eq "video codec +libx264 → libx264"   "libx264"  "$(get_field "$out" "set_video_codec")"
assert_eq "video frames +30 → -r 30"         "-r 30"    "$(get_field "$out" "set_video_number_frames")"
assert_eq "video quality +23 → -crf 23"      "-crf 23"  "$(get_field "$out" "set_video_quality")"
assert_eq "video bitrate -3000 → пустой"     ""         "$(get_field "$out" "set_video_bitrate")"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео аргументы (−выключено)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":+:aac" ":+:2" ":+:128" ":+:48000" \
                   ":-:libx264" ":-:30" ":-:23" ":+:3000")
assert_eq "video codec -libx264 → пустой"   "" "$(get_field "$out" "set_video_codec")"
assert_eq "video frames -30 → пустой"       "" "$(get_field "$out" "set_video_number_frames")"
assert_eq "video quality -23 → пустой"      "" "$(get_field "$out" "set_video_quality")"
assert_eq "video bitrate +3000 → -b:v 3000k" "-b:v 3000k" "$(get_field "$out" "set_video_bitrate")"

# ══════════════════════════════════════════════════════════════
suite "PS1: copy_codecs=yes → -c copy"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":+:aac" ":+:2" ":+:128" ":+:48000" \
                   ":+:libx264" ":+:30" ":+:23" ":-:3000" "yes")
assert_eq "copy_codecs=yes → convert_settings=-c copy" \
    "-c copy" "$(get_field "$out" "convert_settings")"

# ══════════════════════════════════════════════════════════════
suite "PS1: различные кодеки"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_args ":+:libmp3lame" ":+:1" ":+:192" ":-:44100" \
                   ":+:libx265" ":-:25" ":+:28" ":-:2000")
assert_eq "libmp3lame → -c:a libmp3lame"  "-c:a libmp3lame"  "$(get_field "$out" "set_audio_codec")"
assert_eq "mono channels → -ac 1"         "-ac 1"             "$(get_field "$out" "set_audio_number_channels")"
assert_eq "192k bitrate → -b:a 192k"      "-b:a 192k"         "$(get_field "$out" "set_audio_bitrate")"
assert_eq "sampling_rate off → пустой"    ""                  "$(get_field "$out" "set_audio_sampling_rate")"
assert_eq "libx265 → libx265"             "libx265"           "$(get_field "$out" "set_video_codec")"
assert_eq "quality crf 28"                "-crf 28"           "$(get_field "$out" "set_video_quality")"

summary
