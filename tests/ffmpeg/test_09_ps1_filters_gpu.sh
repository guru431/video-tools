#!/bin/bash
# ============================================================
# test_09_ps1_filters_gpu.sh — Тест PS1: фильтры и GPU
# Тестирует: vf (поворот, масштаб, скорость), af (atempo каскад,
# loudnorm), GPU encoder check (nvidia/intel/off).
# Использует inline PowerShell без запуска полного скрипта.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

if ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; then
    suite "PS1 фильтры и GPU"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

# ── Хелпер: построить vf-цепочку (видео-фильтры) ──────────────────────────
run_ps1_vf() {
    local video_rotation="${1:-:-:2}"
    local video_resolution="${2:-:-:1280x720}"
    local keep_aspect_ratio="${3:-:+:yes}"
    local playback_speed="${4:-:-:1.0}"
    local hw_accel_type="${5:-}"   # empty = no GPU

    $PS_CMD -NoProfile -NonInteractive -Command "
\$video_rotation       = '$video_rotation'
\$video_resolution     = '$video_resolution'
\$keep_aspect_ratio    = '$keep_aspect_ratio'
\$playback_speed       = '$playback_speed'
\$hw_accel_type        = '$hw_accel_type'
\$use_hw_accel         = (\$hw_accel_type -ne '')

\$_, \$video_rotation_status,      \$video_rotation_value      = \$video_rotation -split ':'
\$_, \$video_resolution_status,    \$video_resolution_value    = \$video_resolution -split ':'
\$_, \$keep_aspect_ratio_status,   \$keep_aspect_ratio_value   = \$keep_aspect_ratio -split ':'
\$_, \$playback_speed_status,      \$playback_speed_value      = \$playback_speed -split ':'
\$set_video_resolution = if (\$video_resolution_status -eq '+') { \$video_resolution_value } else { '' }

\$vf_parts = @()
if (\$video_rotation_status -eq '+') {
    if (\$hw_accel_type -eq 'nvidia') {
        \$vf_parts += \"transpose_cuda=\$video_rotation_value\"
    } else {
        \$vf_parts += \"transpose=\$video_rotation_value\"
    }
}
if (\$set_video_resolution) {
    \$res_w, \$res_h = \$set_video_resolution -split 'x'
    if (\$keep_aspect_ratio_status -eq '+' -and \$keep_aspect_ratio_value -eq 'yes') {
        switch (\$hw_accel_type) {
            'nvidia' { \$vf_parts += \"scale_cuda=\${res_w}:\${res_h}:force_original_aspect_ratio=decrease\" }
            'intel'  { \$vf_parts += \"scale_qsv=\${res_w}:\${res_h}\" }
            default  { \$vf_parts += \"scale=\${res_w}:\${res_h}:force_original_aspect_ratio=decrease,pad=\${res_w}:\${res_h}:(ow-iw)/2:(oh-ih)/2\" }
        }
    } else {
        switch (\$hw_accel_type) {
            'nvidia' { \$vf_parts += \"scale_cuda=\${res_w}:\${res_h}\" }
            'intel'  { \$vf_parts += \"scale_qsv=\${res_w}:\${res_h}\" }
            default  { \$vf_parts += \"scale=\${res_w}:\${res_h}\" }
        }
    }
}
if (\$playback_speed_status -eq '+' -and \$playback_speed_value -ne '1.0') {
    \$vf_parts += \"setpts=PTS/\$playback_speed_value\"
}
Write-Output (\$vf_parts -join ',')
" 2>/dev/null
}

# ── Хелпер: построить af-цепочку (аудио-фильтры) ──────────────────────────
run_ps1_af() {
    local playback_speed="${1:-:-:1.0}"
    local audio_normalize="${2:-:-:loudnorm}"

    $PS_CMD -NoProfile -NonInteractive -Command "
\$playback_speed    = '$playback_speed'
\$audio_normalize   = '$audio_normalize'

\$_, \$playback_speed_status,  \$playback_speed_value  = \$playback_speed -split ':'
\$_, \$audio_normalize_status, \$audio_normalize_value = \$audio_normalize -split ':'

\$af_parts = @()
if (\$playback_speed_status -eq '+' -and \$playback_speed_value -ne '1.0') {
    \$speed = [double]\$playback_speed_value
    if (\$speed -gt 2.0) {
        \$remaining = \$speed
        while (\$remaining -gt 2.0) { \$af_parts += 'atempo=2.0'; \$remaining = \$remaining / 2.0 }
        \$af_parts += \"atempo=\$remaining\"
    } elseif (\$speed -lt 0.5) {
        \$remaining = \$speed
        while (\$remaining -lt 0.5) { \$af_parts += 'atempo=0.5'; \$remaining = \$remaining / 0.5 }
        \$af_parts += \"atempo=\$remaining\"
    } else {
        \$af_parts += \"atempo=\$speed\"
    }
}
if (\$audio_normalize_status -eq '+') {
    switch (\$audio_normalize_value) {
        'loudnorm'   { \$af_parts += 'loudnorm=I=-16:TP=-1.5:LRA=11' }
        'dynaudnorm' { \$af_parts += 'dynaudnorm' }
    }
}
Write-Output (\$af_parts -join ',')
" 2>/dev/null
}

# ── Хелпер: GPU encoder check ─────────────────────────────────────────────
run_ps1_gpu() {
    local hw_accel="${1:-:-:nvidia}"
    local video_codec="${2:-:+:libx264}"
    local mock_encoders="${3:-}"   # строка симулирующая вывод ffmpeg -encoders

    $PS_CMD -NoProfile -NonInteractive -Command "
\$hw_accel     = '$hw_accel'
\$video_codec  = '$video_codec'
\$encoders_list = '$mock_encoders'

\$_, \$hw_accel_status, \$hw_accel_value = \$hw_accel -split ':'
\$_, \$video_codec_status, \$set_video_codec = \$video_codec -split ':'

\$use_hw_accel  = \$false
\$hw_accel_type = ''

if (\$hw_accel_status -eq '+') {
    switch (\$hw_accel_value) {
        'nvidia' {
            if (\$encoders_list -match 'nvenc') {
                \$use_hw_accel = \$true
                \$hw_accel_type = 'nvidia'
                switch (\$set_video_codec) {
                    'libx264'   { \$set_video_codec = 'h264_nvenc' }
                    'libx265'   { \$set_video_codec = 'hevc_nvenc' }
                    'libsvtav1' { \$set_video_codec = 'av1_nvenc' }
                }
            }
        }
        'intel' {
            if (\$encoders_list -match 'qsv') {
                \$use_hw_accel = \$true
                \$hw_accel_type = 'intel'
                switch (\$set_video_codec) {
                    'libx264'   { \$set_video_codec = 'h264_qsv' }
                    'libx265'   { \$set_video_codec = 'hevc_qsv' }
                    'libsvtav1' { \$set_video_codec = 'av1_qsv' }
                }
            }
        }
    }
}

Write-Output \"use_hw_accel=\$use_hw_accel\"
Write-Output \"hw_accel_type=\$hw_accel_type\"
Write-Output \"set_video_codec=\$set_video_codec\"
" 2>/dev/null
}

get_field() {
    local output="$1"
    local field="$2"
    echo "$output" | grep "^${field}=" | sed "s/^${field}=//"
}

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (поворот)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_vf ":+:1" ":-:1280x720" ":+:yes" ":-:1.0")
assert_contains "rotation +1 → transpose=1"  "transpose=1"  "$result"

result=$(run_ps1_vf ":+:2" ":-:1280x720" ":+:yes" ":-:1.0")
assert_contains "rotation +2 → transpose=2"  "transpose=2"  "$result"

result=$(run_ps1_vf ":-:2" ":-:1280x720" ":+:yes" ":-:1.0")
assert_eq "rotation off → no transpose"  ""  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (масштаб с сохранением пропорций)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_vf ":-:1" ":+:1280x720" ":+:yes" ":-:1.0")
assert_contains "scale 1280x720 keep_ar → scale=1280:720:force_original_aspect_ratio" \
    "scale=1280:720:force_original_aspect_ratio=decrease" "$result"
assert_contains "scale 1280x720 keep_ar → pad"  "pad=1280:720" "$result"

result=$(run_ps1_vf ":-:1" ":+:1280x720" ":+:no" ":-:1.0")
assert_eq "scale без keep_ar → scale=1280:720"  "scale=1280:720"  "$result"

result=$(run_ps1_vf ":-:1" ":-:1280x720" ":+:yes" ":-:1.0")
assert_eq "resolution off → нет scale"  ""  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (скорость видео)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_vf ":-:1" ":-:1280x720" ":+:yes" ":+:2.0")
assert_contains "playback_speed 2.0 → setpts"  "setpts=PTS/2.0"  "$result"

result=$(run_ps1_vf ":-:1" ":-:1280x720" ":+:yes" ":+:1.0")
assert_eq "playback_speed 1.0 → нет setpts"  ""  "$result"

result=$(run_ps1_vf ":-:1" ":-:1280x720" ":+:yes" ":-:1.5")
assert_eq "playback_speed выключена → нет setpts"  ""  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио-фильтры (atempo)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_af ":+:1.5" ":-:loudnorm")
assert_eq "atempo 1.5 → одиночный atempo"  "atempo=1.5"  "$result"

result=$(run_ps1_af ":+:2.0" ":-:loudnorm")
assert_eq "atempo 2.0 → одиночный atempo"  "atempo=2"  "$result"

result=$(run_ps1_af ":+:0.5" ":-:loudnorm")
assert_eq "atempo 0.5 → одиночный atempo"  "atempo=0.5"  "$result"

result=$(run_ps1_af ":+:1.0" ":-:loudnorm")
assert_eq "atempo 1.0 → нет фильтра"  ""  "$result"

result=$(run_ps1_af ":-:1.5" ":-:loudnorm")
assert_eq "playback_speed выключена → нет atempo"  ""  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: atempo каскад (скорость > 2.0 и < 0.5)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_af ":+:3.0" ":-:loudnorm")
assert_contains "speed 3.0 → atempo=2.0 каскад"  "atempo=2.0"  "$result"
assert_contains "speed 3.0 → atempo=1.5 остаток"  "atempo=1.5"  "$result"

result=$(run_ps1_af ":+:4.0" ":-:loudnorm")
# PS1 выводит atempo=2 (не 2.0) когда double 4.0/2.0=2 — эквивалентно для ffmpeg
assert_contains "speed 4.0 → два atempo= каскад"  "atempo=2.0,atempo=2"  "$result"

result=$(run_ps1_af ":+:0.25" ":-:loudnorm")
assert_contains "speed 0.25 → atempo=0.5 каскад"  "atempo=0.5"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио-фильтры (нормализация)"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_af ":-:1.0" ":+:loudnorm")
assert_contains "loudnorm → loudnorm=I=-16"  "loudnorm=I=-16:TP=-1.5:LRA=11"  "$result"

result=$(run_ps1_af ":-:1.0" ":+:dynaudnorm")
assert_eq "dynaudnorm → dynaudnorm"  "dynaudnorm"  "$result"

result=$(run_ps1_af ":-:1.0" ":-:loudnorm")
assert_eq "normalize выключена → нет фильтра"  ""  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: GPU encoder check (NVIDIA)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_gpu ":+:nvidia" ":+:libx264" "V..... h264_nvenc           NVIDIA NVENC H.264")
assert_eq "nvidia + nvenc found → use_hw_accel=True"  "True"      "$(get_field "$out" "use_hw_accel")"
assert_eq "nvidia + nvenc found → hw_accel_type"      "nvidia"    "$(get_field "$out" "hw_accel_type")"
assert_eq "nvidia + nvenc → libx264 → h264_nvenc"     "h264_nvenc" "$(get_field "$out" "set_video_codec")"

out=$(run_ps1_gpu ":+:nvidia" ":+:libx264" "no matching encoders")
assert_eq "nvidia + no nvenc → use_hw_accel=False"  "False"    "$(get_field "$out" "use_hw_accel")"
assert_eq "nvidia + no nvenc → codec unchanged"     "libx264"  "$(get_field "$out" "set_video_codec")"

# ══════════════════════════════════════════════════════════════
suite "PS1: GPU encoder check (Intel QSV)"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_gpu ":+:intel" ":+:libx265" "V..... hevc_qsv              H.265/HEVC Intel QSV")
assert_eq "intel + qsv found → use_hw_accel=True"   "True"     "$(get_field "$out" "use_hw_accel")"
assert_eq "intel + qsv found → hw_accel_type"        "intel"   "$(get_field "$out" "hw_accel_type")"
assert_eq "intel + qsv → libx265 → hevc_qsv"         "hevc_qsv" "$(get_field "$out" "set_video_codec")"

out=$(run_ps1_gpu ":+:intel" ":+:libx264" "no matching encoders")
assert_eq "intel + no qsv → use_hw_accel=False"  "False"    "$(get_field "$out" "use_hw_accel")"
assert_eq "intel + no qsv → codec unchanged"     "libx264"  "$(get_field "$out" "set_video_codec")"

# ══════════════════════════════════════════════════════════════
suite "PS1: GPU выключен"
# ══════════════════════════════════════════════════════════════

out=$(run_ps1_gpu ":-:nvidia" ":+:libx264" "V..... h264_nvenc")
assert_eq "hw_accel off → use_hw_accel=False"  "False"    "$(get_field "$out" "use_hw_accel")"
assert_eq "hw_accel off → codec unchanged"     "libx264"  "$(get_field "$out" "set_video_codec")"

summary
