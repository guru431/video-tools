#!/bin/bash
# ============================================================
# test_16_gui_state.sh — F17: воркер сообщает GUI честный исход батча.
# Раньше финальная запись всегда была «Готово» независимо от countFail, а `exit 1`
# не создаёт ErrorRecord — GUI показывал «Готово» после провального батча.
# Контракт: progress JSON содержит state=running|success|failed|cancelled + exitCode.
# Запускает НАСТОЯЩИЙ FFmpeg_Converter_script.ps1 (dot-source, как делает run_v15.ps1)
# с mock ffmpeg; результат читается из JSON-файла прогресса.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "F17: GUI state воркера"
    skip "Все PS1 GUI-state тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

SCRIPT_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"
WORK=$(mktemp -d /tmp/test_gui_state_XXXXXX)
IN="$WORK/in"; DST="$WORK/out"
mkdir -p "$IN" "$DST"
: > "$IN/a.mp4"

# Запускает воркер с заданным mock-поведением и печатает содержимое progress JSON.
# $1 — MOCK_FFMPEG_FAIL (0/1), $2 — создать ли cancel-файл (yes/no).
run_worker() {
    local mock_fail="$1" want_cancel="${2:-no}"
    local prog="$WORK/progress.json" cancel="$WORK/cancel.flag"
    rm -f "$prog" "$cancel"
    [ "$want_cancel" = "yes" ] && : > "$cancel"

    local w_script w_in w_dst w_prog w_cancel w_mock
    w_script=$(cygpath -w "$SCRIPT_PS1"); w_in=$(cygpath -w "$IN"); w_dst=$(cygpath -w "$DST")
    w_prog=$(cygpath -w "$prog"); w_cancel=$(cygpath -w "$cancel")
    w_mock=$(cygpath -w "$TESTS_DIR/mocks/ffmpeg.cmd")

    MOCK_FFMPEG_FAIL="$mock_fail" MOCK_FFMPEG_ENCODERS="" \
    FFMPEG_GUI_PROGRESS_FILE="$w_prog" FFMPEG_GUI_CANCEL_FILE="$w_cancel" \
    "$PS_CMD" -NoProfile -NonInteractive -Command "
\$ErrorActionPreference='Continue'
# cygpath -w отдаёт короткий 8.3-путь (SUPERU~1), а .NET DirectoryName — длинный:
# без нормализации strip-префикса в Encode-File не срабатывает и пути склеиваются.
\$folder_sources=(Get-Item '$w_in').FullName + [IO.Path]::DirectorySeparatorChar
\$folder_destination=(Get-Item '$w_dst').FullName + [IO.Path]::DirectorySeparatorChar
\$ffmpeg='$w_mock'; \$ffprobe='$w_mock'
\$audio_codec=':+:aac'; \$audio_number_channels=':-:2'; \$audio_bitrate=':-:128'
\$audio_sampling_rate=':-:44100'; \$audio_normalize=':-:loudnorm'
\$video_codec=':+:libx264'; \$video_resolution=':-:1280x720'; \$video_bitrate=':-:2000'
\$video_number_frames=':-:25'; \$video_rotation=':-:2'; \$video_subtitles=':-:burn'
\$video_quality=':+:23'; \$keep_aspect_ratio=':+:yes'; \$output_container=':+:mp4'
\$multithreads=':-:4'; \$parallel_files=':-:2'
\$hw_accel=':-:nvidia'; \$gpu_preset=':-:p5'; \$gpu_tune=':-:hq'; \$gpu_rc=':-:vbr'
\$playback_speed=':-:1.0'; \$start_coding=':-:01-00-00'; \$length_coding=':-:00-05-00'
\$split_by_silence='no'; \$silence_duration='2.0'; \$silence_threshold='-30dB'
\$save_old_extension='no'; \$format_files_in='mp4,mkv,avi,webm'
\$subtitles_style=''; \$dry_run='no'; \$enable_log='no'; \$log_file=''
\$audio_only='no'; \$merge_files='no'; \$create_frame='no'
\$copy_codecs='no'; \$extract_audio_copy='no'; \$overwrite_existing='yes'
. '$w_script'
" > /dev/null 2>&1
    # ConvertTo-Json выравнивает значения переменным числом пробелов ("ok":  0) —
    # схлопываем пробелы, чтобы проверки не зависели от форматирования.
    tr -d " 
" < "$prog" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
suite "F17: воркер сообщает GUI честный исход батча"
# ══════════════════════════════════════════════════════════════

# Успешный батч.
JSON=$(run_worker 0 no)
assert_contains "успех: state=success"          '"state":"success"' "$JSON"
assert_contains "успех: exitCode=0"             '"exitCode":0'      "$JSON"

# Провальный батч: ffmpeg падает → countFail>0. Суть находки — здесь раньше
# писалось «Готово», и GUI не имел ни одного способа узнать об ошибке.
JSON=$(run_worker 1 no)
assert_contains "провал: state=failed"          '"state":"failed"'  "$JSON"
assert_contains "провал: exitCode=1"            '"exitCode":1'      "$JSON"
assert_not_contains "провал: НЕ рапортует success" '"state":"success"' "$JSON"
# Пробелы схлопнуты выше, поэтому сверяем по фрагменту без них.
assert_contains "провал: message объясняет причину" "ошибками:1" "$JSON"

# Отмена пользователем отличается от провала.
JSON=$(run_worker 0 yes)
assert_contains "отмена: state=cancelled"       '"state":"cancelled"' "$JSON"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
