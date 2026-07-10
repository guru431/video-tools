#!/bin/bash
# ============================================================
# test_15_findings.sh — Фиксы аудита F5/F6/F7/F8 (уровень SH):
#   F5 — dry_run НЕ исполняет спецрежимы (extract/frame/merge), только печатает команды;
#   F6 — извлечение кадров пишет маркер завершения, провал удаляет каталог (повтор возможен);
#   F7 — overwrite_existing=yes перекодирует готовый файл, иначе пропускает;
#   F8 — предпусковая проверка совместимости webm + кодек субтитров meta по контейнеру.
# Использует mock ffmpeg (touch выходов); фейковые входы — реальный ffmpeg не нужен.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS_DIR="$TESTS_DIR/mocks"
source "$TESTS_DIR/lib/framework.sh"

WORK=$(mktemp -d /tmp/test_ff_find_XXXXXX)
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

# Запускает script.sh, захватывает stdout+stderr в OUT_TEXT и код возврата в RC.
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

# ══════════════════════════════════════════════════════════════
suite "F5: dry_run не исполняет спецрежимы ffmpeg"
# ══════════════════════════════════════════════════════════════

# --- extract_audio_copy ---
touch "$IN/a.mp4"
run_capture 'extract_audio_copy="yes"' 'dry_run="yes"'
assert_contains "extract dry-run: метка [DRY-RUN]" "[DRY-RUN]" "$OUT_TEXT"
if log_has "-vn -c:a copy"; then fail "extract dry-run: реальное извлечение пропущено" "нет -vn -c:a copy" "найдено в логе"; else pass "extract dry-run: реальное извлечение пропущено"; fi
if [ ! -f "$DST/a.m4a" ]; then pass "extract dry-run: аудиофайл не создан"; else fail "extract dry-run: аудиофайл не создан" "нет a.m4a" "создан"; fi
rm -f "$IN/a.mp4" "$DST/a.m4a"

# --- create_frame ---
touch "$IN/b.mp4"
run_capture 'create_frame="yes"' 'dry_run="yes"'
assert_contains "frame dry-run: метка [DRY-RUN]" "[DRY-RUN]" "$OUT_TEXT"
if log_has "-r 1/1"; then fail "frame dry-run: ffmpeg не запущен" "нет -r 1/1" "найдено в логе"; else pass "frame dry-run: ffmpeg не запущен"; fi
if [ ! -d "$DST/b" ]; then pass "frame dry-run: каталог кадров не создан"; else fail "frame dry-run: каталог не создан" "нет каталога" "создан"; fi
rm -f "$IN/b.mp4"; rm -rf "$DST/b"

# --- merge_files ---
touch "$IN/m1.mp4" "$IN/m2.mp4"
run_capture 'merge_files="yes"' 'dry_run="yes"'
assert_contains "merge dry-run: метка [DRY-RUN]" "[DRY-RUN]" "$OUT_TEXT"
if log_has "-f concat"; then fail "merge dry-run: concat не запущен" "нет -f concat" "найдено в логе"; else pass "merge dry-run: concat не запущен"; fi
if [ ! -f "$DST/m1.mp4" ]; then pass "merge dry-run: объединённый файл не создан"; else fail "merge dry-run: файл не создан" "нет m1.mp4" "создан"; fi
rm -f "$IN/m1.mp4" "$IN/m2.mp4" "$DST/m1.mp4"

# ══════════════════════════════════════════════════════════════
suite "F6: извлечение кадров — маркер завершения и retry-безопасность"
# ══════════════════════════════════════════════════════════════

touch "$IN/c.mp4"
run_capture 'create_frame="yes"'
if [ -f "$DST/c/.frames_complete" ]; then pass "frame успех: маркер .frames_complete создан"; else fail "frame успех: маркер создан" "есть" "нет"; fi
if log_has "-r 1/1"; then pass "frame успех: ffmpeg извлёк кадры"; else fail "frame успех: ffmpeg вызван" "вызван" "нет"; fi
# повтор — пропуск по маркеру (ffmpeg не вызывается снова)
run_capture 'create_frame="yes"'
if log_has "-r 1/1"; then fail "frame повтор: пропущен по маркеру" "ffmpeg не вызван" "вызван снова"; else pass "frame повтор: пропущен по маркеру"; fi
rm -f "$IN/c.mp4"; rm -rf "$DST/c"

# провал ffmpeg — частичный каталог удаляется, маркера нет (повтор возможен)
touch "$IN/d.mp4"
run_capture 'create_frame="yes"' 'export MOCK_FFMPEG_FAIL=1'
if [ ! -d "$DST/d" ]; then pass "frame провал: частичный каталог удалён"; else fail "frame провал: каталог удалён" "нет каталога" "остался"; fi
if [ ! -f "$DST/d/.frames_complete" ]; then pass "frame провал: маркера нет"; else fail "frame провал: маркера нет" "нет" "есть"; fi
rm -f "$IN/d.mp4"; rm -rf "$DST/d"

# ══════════════════════════════════════════════════════════════
suite "F7: overwrite_existing перекодирует готовый файл"
# ══════════════════════════════════════════════════════════════

touch "$IN/e.mp4"
: > "$DST/e.mp4"   # готовый валидный выход (mock -f null → exit 0)
run_capture 'overwrite_existing="no"'
if log_has "-c:v libx264"; then fail "skip: готовый валидный файл пропущен" "нет перекодирования" "encode запущен"; else pass "skip: готовый валидный файл пропущен"; fi
run_capture 'overwrite_existing="yes"'
if log_has "-c:v libx264"; then pass "overwrite: файл перекодирован заново"; else fail "overwrite: перекодирование" "encode запущен" "пропущен"; fi
rm -f "$IN/e.mp4" "$DST/e.mp4"

# ══════════════════════════════════════════════════════════════
suite "F8: совместимость контейнера webm и кодек субтитров meta"
# ══════════════════════════════════════════════════════════════

touch "$IN/f.mp4"
run_capture 'output_container=":+:webm"'   # дефолтные libx264 + aac — несовместимы
assert_contains "webm+libx264: сообщение о видеокодеке" "WebM не поддерживает видеокодек" "$OUT_TEXT"
# Прерывание ДО пакета: итоговая сводка не печатается (exit до цикла файлов).
assert_not_contains "webm+libx264: пакет прерван до сводки" "Обработано:" "$OUT_TEXT"
if log_has "-c:v libx264"; then fail "webm abort: перекодирование не запущено" "нет encode" "запущено"; else pass "webm abort: перекодирование не запущено"; fi

run_capture 'output_container=":+:webm"' 'video_codec=":+:libvpx-vp9"' 'audio_codec=":+:libopus"'
assert_contains "webm+vp9+opus: валидная комбинация доходит до сводки" "Обработано:" "$OUT_TEXT"
rm -f "$IN/f.mp4" "$DST/f.webm"

# --- кодек субтитров meta по контейнеру ---
touch "$IN/g.mp4"; printf '1\n00:00:00,000 --> 00:00:01,000\nX\n' > "$IN/g.srt"
run_capture 'video_subtitles=":+:meta"' 'output_container=":+:mkv"'
if log_has "-c:s srt"; then pass "meta mkv → -c:s srt"; else fail "meta mkv → -c:s srt" "-c:s srt" "нет"; fi
run_capture 'video_subtitles=":+:meta"' 'output_container=":+:mp4"'
if log_has "-c:s mov_text"; then pass "meta mp4 → -c:s mov_text"; else fail "meta mp4 → -c:s mov_text" "-c:s mov_text" "нет"; fi
run_capture 'video_subtitles=":+:meta"' 'output_container=":+:webm"' 'video_codec=":+:libvpx-vp9"' 'audio_codec=":+:libopus"'
if log_has "-c:s webvtt"; then pass "meta webm → -c:s webvtt"; else fail "meta webm → -c:s webvtt" "-c:s webvtt" "нет"; fi
rm -f "$IN/g.mp4" "$IN/g.srt" "$DST/g.mkv" "$DST/g.mp4" "$DST/g.webm"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
