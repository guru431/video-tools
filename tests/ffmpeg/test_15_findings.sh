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
suite "F23: merge не зависает на существующем выходе и не оставляет partial"
# ══════════════════════════════════════════════════════════════
# Суть находки: concat шёл БЕЗ -y прямо поверх цели. Существующий выход → ffmpeg
# спрашивает «File exists. Overwrite? [y/N]» и ждёт stdin, которого в batch/GUI нет.
# Упавший мерж оставлял partial под именем цели, и следующий запуск считал его готовым.
MW=$(mktemp -d /tmp/test_ff_merge_XXXXXX)
mkdir -p "$MW/bin"
HANG_LOG="$MW/hang.log"

# Мок воспроизводит поведение настоящего ffmpeg: пишем в существующий файл без -y —
# значит, повисли бы на запросе. Вместо реального зависания фиксируем факт в лог,
# чтобы тест оставался быстрым и детерминированным.
cat > "$MW/bin/ffmpeg" <<'MEOF'
#!/bin/bash
case "$*" in *"-f null"*) exit 0 ;; esac   # валидация выхода — всегда успех
has_y=no; has_nostdin=no
for a in "$@"; do
    [ "$a" = "-y" ] && has_y=yes
    [ "$a" = "-nostdin" ] && has_nostdin=yes
done
for out in "$@"; do :; done               # выход — последний аргумент
if [ -e "$out" ] && [ "$has_y" = "no" ]; then
    echo "WOULD_HANG:$out (нет -y, nostdin=$has_nostdin)" >> "$MOCK_HANG_LOG"
    exit 1
fi
if [ "${MOCK_MERGE_FAIL:-0}" = "1" ]; then printf 'partial' > "$out"; exit 1; fi
printf 'merged' > "$out"
exit 0
MEOF
chmod +x "$MW/bin/ffmpeg"
export MOCK_HANG_LOG="$HANG_LOG"

merge_run() {
    rm -f "$HANG_LOG"
    run_capture 'merge_files="yes"' 'overwrite_existing="yes"' "ffmpeg=\"$MW/bin/ffmpeg\"" "$@"
}

touch "$IN/z1.mp4" "$IN/z2.mp4"
# Цель уже существует — ровно тот случай, где старый код вставал намертво.
printf 'старое содержимое' > "$DST/z1.mp4"
export MOCK_MERGE_FAIL=0
merge_run
if [ -s "$HANG_LOG" ]; then
    fail "merge поверх существующего файла не зависает" "нет запроса Overwrite" "$(cat "$HANG_LOG")"
else
    pass "merge поверх существующего файла не зависает"
fi
assert_eq "merge: цель заменена результатом" "merged" "$(cat "$DST/z1.mp4" 2>/dev/null)"
if ls "$DST"/.*.partial >/dev/null 2>&1; then fail "merge успех: partial убран" "нет .partial" "остался"; else pass "merge успех: partial убран"; fi

# Провал мержа: цель обязана остаться прежней, partial — исчезнуть.
printf 'старое содержимое' > "$DST/z1.mp4"
export MOCK_MERGE_FAIL=1
merge_run
assert_eq "merge провал: цель НЕ затёрта partial'ом" "старое содержимое" "$(cat "$DST/z1.mp4" 2>/dev/null)"
if ls "$DST"/.*.partial >/dev/null 2>&1; then fail "merge провал: partial удалён" "нет .partial" "остался: $(ls "$DST"/.*.partial)"; else pass "merge провал: partial удалён"; fi
assert_contains "merge провал: залогирован FAIL" "FAIL" "$OUT_TEXT"
export MOCK_MERGE_FAIL=0
unset MOCK_HANG_LOG
rm -f "$IN/z1.mp4" "$IN/z2.mp4" "$DST/z1.mp4"; rm -rf "$MW"

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

# ══════════════════════════════════════════════════════════════
suite "F12: выход не может совпасть со входом (оригинал не удаляется)"
# ══════════════════════════════════════════════════════════════

# source == destination, тот же контейнер, без префикса → out_file == full_path.
# MOCK_FFMPEG_INVALID заставляет валидацию существующего выхода провалиться: без F12
# ветка «удаление битого файла» стёрла бы оригинал ещё до кодирования.
printf 'ORIGINAL-BYTES' > "$IN/same.mp4"
run_capture 'folder_destination="$IN"' 'output_container=":+:mp4"' 'overwrite_existing="yes"'
if [ -f "$IN/same.mp4" ]; then pass "in==out + overwrite=yes: оригинал не удалён"; else fail "in==out + overwrite=yes: оригинал не удалён" "файл на месте" "удалён"; fi
assert_contains "in==out + overwrite=yes: помечен как FAIL" "выход совпадает с входом" "$OUT_TEXT"

run_capture 'folder_destination="$IN"' 'output_container=":+:mp4"'
assert_contains "in==out: файл помечен как FAIL" "выход совпадает с входом" "$OUT_TEXT"
if log_has "-c:v libx264"; then fail "in==out: ffmpeg не запускается" "нет encode" "запущено"; else pass "in==out: ffmpeg не запускается"; fi
if [ -f "$IN/same.mp4" ]; then pass "in==out: оригинал не удалён"; else fail "in==out: оригинал не удалён" "файл на месте" "удалён"; fi
assert_eq "in==out: содержимое оригинала не тронуто" "ORIGINAL-BYTES" "$(cat "$IN/same.mp4" 2>/dev/null)"

# Смена контейнера снимает коллизию — та же папка, но другое расширение.
run_capture 'folder_destination="$IN"' 'output_container=":+:mkv"'
if log_has "-c:v libx264"; then pass "in!=out (другой контейнер): кодирование идёт"; else fail "in!=out (другой контейнер): кодирование идёт" "encode" "нет"; fi
rm -f "$IN/same.mp4" "$IN/same.mkv"

# ══════════════════════════════════════════════════════════════
suite "F15: невалидная playback_speed отвергается, а не вешает каскад"
# ══════════════════════════════════════════════════════════════
touch "$IN/spd.mp4"

# Каждый прогон под timeout: суть бага — бесконечный цикл, поэтому «не завис» это
# часть проверки. Без фикса run_capture здесь не возвращался бы никогда.
run_speed() {
    local val="$1"
    OUT_TEXT=$(
        export PATH="$MOCKS_DIR:$PATH"; export MOCK_FFMPEG_ENCODERS=""; export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        # set -a: скрипт запускается подпроцессом (иначе timeout не поймает зависание),
        # поэтому конфиг должен уехать в окружение.
        set -a; default_vars; playback_speed=":+:$val"; set +a
        timeout 15 bash "$SCRIPT" 2>&1
    ) < /dev/null
    RC=$?
}

for bad in 0 -1 -2.5 abc 0.0 150; do
    run_speed "$bad"
    if [ "$RC" -eq 124 ]; then
        fail "speed='$bad': не зависает" "завершение" "таймаут 15с (бесконечный цикл)"
    else
        pass "speed='$bad': не зависает"
    fi
    assert_contains "speed='$bad': явная ошибка диапазона" "playback_speed должен быть числом" "$OUT_TEXT"
done

# Валидные значения по-прежнему строят каскад.
run_speed "3.0"
assert_not_contains "speed='3.0': принято" "playback_speed должен быть числом" "$OUT_TEXT"
run_speed "0.25"
assert_not_contains "speed='0.25': принято" "playback_speed должен быть числом" "$OUT_TEXT"
rm -f "$IN/spd.mp4" "$DST/spd.mp4"

# ══════════════════════════════════════════════════════════════
suite "F16: split по тишине — границы монотонны, без зазоров и потери хвоста"
# ══════════════════════════════════════════════════════════════
# Файл 120с, шаг 30с → номинальные границы 0/30/60/90.
# Тишины: 28-32 (центр 30, сдвига нет), 55-59 (центр 57 → 60 уезжает назад),
# 94-98 (центр 96 → 90 уезжает вперёд). Итоговые границы: 0/30/57/96.
# Длительности как разности: 30, 27, 39, и последняя — до конца файла.
# Старый код считал длину от НОМИНАЛЬНОЙ следующей границы: part2 получал -t 30
# (перекрытие 3с с part3), part3 получал -t 27 и обрывался на 84с — 12 секунд
# исходника между 84 и 96 не попадали НИ В ОДНУ часть.
touch "$IN/split.mp4"
OUT_TEXT=$(
    export PATH="$MOCKS_DIR:$PATH"; export MOCK_FFMPEG_ENCODERS=""; export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
    export MOCK_FFMPEG_DURATION="00:02:00.00"
    export MOCK_FFMPEG_SILENCE="28:32 55:59 94:98"
    rm -f "$FFMPEG_LOG"
    default_vars
    length_coding=":+:00-00-30"; split_by_silence="yes"
    source "$SCRIPT" 2>&1
) < /dev/null

# Берём только строки кодирования (в логе есть и вызовы -i для probe/silencedetect).
ENC_LINES=$(grep -F -- "-c:v libx264" "$FFMPEG_LOG" 2>/dev/null)

assert_contains "part.1: стартует с 0 (начало не срезано)"  "(part.1)"      "$ENC_LINES"
assert_contains "part.2: -ss 30"                            "-ss 30"        "$ENC_LINES"
assert_contains "part.3: -ss 57 (граница сдвинута к тишине)" "-ss 57"       "$ENC_LINES"
assert_contains "part.4: -ss 96 (граница сдвинута к тишине)" "-ss 96"       "$ENC_LINES"

# Длительности — разности соседних границ, а не номинальные 30.
assert_contains "part.2: -t 27 = 57-30 (нет перекрытия)"    "-t 27"         "$ENC_LINES"
assert_contains "part.3: -t 39 = 96-57 (нет 12с зазора)"     "-t 39"        "$ENC_LINES"
if [ "$(grep -cF -- "-t 30" <<< "$ENC_LINES")" -le 1 ]; then
    pass "номинальные -t 30 не применяются к сдвинутым частям"
else
    fail "номинальные -t 30 не применяются к сдвинутым частям" "не более одной части с -t 30" "$(grep -cF -- "-t 30" <<< "$ENC_LINES")"
fi

# Последняя часть идёт до конца файла: -t обрезал бы хвост.
LAST_LINE=$(grep -F -- "(part.4)" <<< "$ENC_LINES" | head -1)
if grep -qE -- "-t [0-9]" <<< "$LAST_LINE"; then
    fail "последняя часть без -t (хвост не обрезан)" "нет -t" "$LAST_LINE"
else
    pass "последняя часть без -t (хвост не обрезан)"
fi
rm -f "$IN/split.mp4" "$DST"/split*.mp4

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
