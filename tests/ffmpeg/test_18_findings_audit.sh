#!/bin/bash
# ============================================================
# test_18_findings_audit.sh — аудит-находки F1/F2/F4/F5 + F3(sig):
#   F1 — dry_run с overwrite_existing=yes НЕ удаляет существующий выход (extract);
#   F2 — in-place merge (dest == source) отклоняется, первый источник не затирается;
#   F4 — молчаливый провал финального rename помечается FAIL, manifest не пишется;
#   F3 — settings-подпись при split_by_silence=yes включает порог/длительность тишины;
#   F5 — GUI резолвит относительный log_file от каталога приложения.
# SH проверяется поведенчески (source "$SCRIPT"); PS1/CMD — source-scan (нет
# кроссплатформенного раннера в Git Bash), как и в test_15.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS_DIR="$TESTS_DIR/mocks"
source "$TESTS_DIR/lib/framework.sh"

WORK=$(mktemp -d /tmp/test_ff_a18_XXXXXX)
IN="$WORK/in"; DST="$WORK/out"; FFMPEG_LOG="$WORK/mock.log"
mkdir -p "$IN" "$DST"

default_vars() {
    folder_sources="$IN"; folder_destination="$DST"
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
    save_old_extension="no"; format_files_in="mp4,mkv,avi,webm"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"
    copy_codecs="no"; extract_audio_copy="no"; overwrite_existing="no"
}

run_capture() {
    rm -f "$FFMPEG_LOG"
    OUT_TEXT=$(
        export PATH="$MOCKS_DIR:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        default_vars
        for ov in "$@"; do eval "$ov"; done
        source "$SCRIPT" 2>&1
    ) < /dev/null
    RC=$?
}
log_has() { [ -f "$FFMPEG_LOG" ] && grep -qF -- "$1" "$FFMPEG_LOG"; }

SH_SRC="$(cat "$SCRIPT")"
PS1_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")"
CMD_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")"
GUI_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v16.ps1")"

# ══════════════════════════════════════════════════════════════
suite "F1: dry_run не уничтожает существующий выход при overwrite_existing=yes"
# ══════════════════════════════════════════════════════════════
# Суть: extract при overwrite=yes удалял готовый аудиофайл ДО проверки dry_run —
# режим, обещающий лишь показать команду, реально уничтожал данные.
touch "$IN/a.mp4"
printf 'EXISTING-AUDIO-BYTES' > "$DST/a.m4a"   # мок отдаёт Audio: aac → расширение m4a
run_capture 'extract_audio_copy="yes"' 'overwrite_existing="yes"' 'dry_run="yes"'
assert_contains "extract dry-run+overwrite: печатается команда" "[DRY-RUN]" "$OUT_TEXT"
if [ -f "$DST/a.m4a" ]; then pass "extract dry-run+overwrite: существующий выход НЕ удалён"; else fail "extract dry-run+overwrite: выход НЕ удалён" "файл на месте" "удалён"; fi
assert_eq "extract dry-run+overwrite: содержимое выхода не тронуто" "EXISTING-AUDIO-BYTES" "$(cat "$DST/a.m4a" 2>/dev/null)"
if log_has "-vn -c:a copy"; then fail "extract dry-run: реальное извлечение не запущено" "нет -vn -c:a copy" "запущено"; else pass "extract dry-run: реальное извлечение не запущено"; fi
# Настоящий прогон (не dry_run) при overwrite=yes обязан перезаписать.
run_capture 'extract_audio_copy="yes"' 'overwrite_existing="yes"'
if log_has "-vn -c:a copy"; then pass "extract overwrite (не dry): извлечение выполнено"; else fail "extract overwrite: извлечение выполнено" "ffmpeg вызван" "пропущен"; fi
rm -f "$IN/a.mp4" "$DST/a.m4a"

# Паритет PS1/CMD (source-scan): удаление под guard'ом dry_run.
assert_contains "PS1 extract: удаление под guard'ом dry_run" 'if ($dry_run -ne "yes") { Remove-Item -LiteralPath $outAudio' "$PS1_SRC"
assert_contains "CMD extract: удаление под guard'ом dry_run" 'if "%overwrite_existing%"=="yes" if not "%dry_run%"=="yes" del "!out_audio!"' "$CMD_SRC"
assert_contains "CMD обычный путь: pre-delete под guard'ом dry_run" 'if "%overwrite_existing%"=="yes" if not "%dry_run%"=="yes" (' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F2: in-place merge отклоняется (результат == вход → потеря источника)"
# ══════════════════════════════════════════════════════════════
# dest == source, overwrite=yes: цель merge = первый источник. Слияние затёрло бы его
# собой, а следующий прогон задублировал бы объединённое содержимое.
touch "$IN/z1.mp4" "$IN/z2.mp4"
printf 'ORIGINAL-Z1' > "$IN/z1.mp4"
run_capture 'folder_destination="$IN"' 'merge_files="yes"' 'overwrite_existing="yes"'
assert_contains "in-place merge помечен FAIL" "Объединение отклонено" "$OUT_TEXT"
if log_has "-f concat"; then fail "in-place merge: слияние не запущено" "нет -f concat" "запущено"; else pass "in-place merge: слияние не запущено"; fi
assert_eq "in-place merge: первый источник не затёрт" "ORIGINAL-Z1" "$(cat "$IN/z1.mp4" 2>/dev/null)"
rm -f "$IN/z1.mp4" "$IN/z2.mp4"

# Контроль: merge в ОТДЕЛЬНЫЙ каталог по-прежнему работает (не ложное срабатывание).
touch "$IN/z1.mp4" "$IN/z2.mp4"; rm -f "$DST/z1.mp4"
run_capture 'merge_files="yes"' 'overwrite_existing="yes"'
assert_not_contains "merge в отдельный dest: не отклонён" "Объединение отклонено" "$OUT_TEXT"
if log_has "-f concat"; then pass "merge в отдельный dest: слияние выполнено"; else fail "merge в отдельный dest: слияние выполнено" "-f concat" "нет"; fi
rm -f "$IN/z1.mp4" "$IN/z2.mp4" "$DST/z1.mp4"

# Паритет PS1/CMD (source-scan).
assert_contains "PS1 merge: guard совпадения цели со входом" '$_mergeTargetIsInput' "$PS1_SRC"
assert_contains "PS1 merge: отклонение с сообщением"        'Объединение отклонено' "$PS1_SRC"
assert_contains "CMD merge: guard совпадения цели со входом" '_merge_collision' "$CMD_SRC"
assert_contains "CMD merge: отклонение с сообщением"        'Объединение отклонено' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F4: молчаливый провал финального rename → FAIL, а не мнимый OK"
# ══════════════════════════════════════════════════════════════
# Суть: результат mv/move не проверялся. При недоступной цели скрипт логировал OK,
# увеличивал success и писал manifest для отсутствующего результата. Провал rename
# воспроизводим детерминированно: цель занята КАТАЛОГОМ — mv кладёт temp внутрь него,
# и файла-цели не появляется.
touch "$IN/rn.mp4"; rm -f "$DST/rn.mp4" "$DST/.rn.ffconv"
mkdir -p "$DST/rn.mp4"   # имя цели занято каталогом → публикация файла невозможна
run_capture
assert_contains "rename-провал: помечен FAIL" "не удалось опубликовать результат" "$OUT_TEXT"
assert_not_contains "rename-провал: НЕ помечен OK" "-> rn.mp4 (" "$OUT_TEXT"
if [ ! -f "$DST/.rn.ffconv" ]; then pass "rename-провал: manifest не записан"; else fail "rename-провал: manifest не записан" "нет .rn.ffconv" "записан"; fi
rm -rf "$IN/rn.mp4" "$DST/rn.mp4" "$DST"/.ffconv-partial-* "$DST/.rn.ffconv"

# Контроль: обычный успешный rename по-прежнему даёт OK + manifest.
touch "$IN/rn.mp4"; rm -f "$DST/rn.mp4" "$DST/.rn.ffconv"
run_capture
if [ -f "$DST/rn.mp4" ]; then pass "rename-успех: цель опубликована"; else fail "rename-успех: цель опубликована" "есть rn.mp4" "нет"; fi
if [ -f "$DST/.rn.ffconv" ]; then pass "rename-успех: manifest записан"; else fail "rename-успех: manifest записан" "есть .rn.ffconv" "нет"; fi
rm -f "$IN/rn.mp4" "$DST/rn.mp4" "$DST/.rn.ffconv"

# Паритет PS1/CMD (source-scan): rename проверяется.
assert_contains "PS1 обычный путь: Move-Item -ErrorAction Stop"    'Move-Item -LiteralPath $out_tmp -Destination $out_file -Force -ErrorAction Stop' "$PS1_SRC"
assert_contains "PS1 обычный путь: подтверждение публикации"       'Test-Path -LiteralPath $out_file -PathType Leaf' "$PS1_SRC"
assert_contains "PS1 merge: Move-Item -ErrorAction Stop"           'Move-Item -LiteralPath $mergeTmp -Destination $mergeTarget -Force -ErrorAction Stop' "$PS1_SRC"
assert_contains "CMD обычный путь: errorlevel после move"          'move /y "!out_tmp!" "!out_file!" >nul 2>&1' "$CMD_SRC"
assert_contains "CMD merge: errorlevel после move"                 'move /y "!_merge_tmp!" "!_merge_target!" >nul 2>&1' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F3: settings-подпись при split_by_silence=yes включает порог/длительность"
# ══════════════════════════════════════════════════════════════
# split_by_silence меняет границы частей по порогу/длительности тишины: их смена обязана
# обесценивать manifest. В подпись входит сам флаг split, но не эти параметры — пробел.
# (CMD исключён: split_by_silence там намеренно откатывается на время — нет float-math.)
assert_contains "SH: подпись условно добавляет sil=" 'settings_sig="${settings_sig}|sil=${silence_threshold},${silence_duration}"' "$SH_SRC"
assert_contains "PS1: подпись условно добавляет sil=" '$settings_sig = "$settings_sig|sil=$silence_threshold,$silence_duration"' "$PS1_SRC"

# ══════════════════════════════════════════════════════════════
suite "F5: GUI резолвит относительный log_file от каталога приложения"
# ══════════════════════════════════════════════════════════════
# GUI передавал log_file как есть; Add-Content писал относительно $PWD. Нормализуем от
# $script:_appDir тем же правилом, что source/destination и не-GUI wrappers (run.ps1 F28).
assert_contains "GUI: log_file резолвится от _appDir" 'IsPathRooted($_cfg_log_file)) { $_cfg_log_file = Join-Path $script:_appDir $_cfg_log_file }' "$GUI_SRC"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
