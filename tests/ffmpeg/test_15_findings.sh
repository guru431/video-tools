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
suite "F25: потолок битрейта берётся из видеопотока, а не из контейнера"
# ══════════════════════════════════════════════════════════════
# Суть: мок отдаёт контейнер 2000 kb/s при видеопотоке 1808 kb/s (разница — аудио
# 192k + overhead). Настройка обещает «не повышать исходный видеобитрейт», но
# сравнивала с 2000 и потому поднимала видео с 1808 до 1900.
touch "$IN/br.mp4"
rm -f "$DST/br.mp4"; run_capture 'video_bitrate=":+:1900"' 'video_quality=":-:23"'
if log_has "-b:v 1808k"; then pass "запрошено 1900 > видео 1808 → ограничено 1808k"; else fail "потолок = битрейт видеопотока" "-b:v 1808k" "$(grep -o '\-b:v [0-9]*k' "$FFMPEG_LOG" | head -1)"; fi
if log_has "-b:v 1900k"; then fail "битрейт видео не повышен до запрошенного" "нет -b:v 1900k" "видео поднято 1808 → 1900"; else pass "битрейт видео не повышен до запрошенного"; fi

# Запрос ниже исходного — берётся запрошенный, потолок не мешает.
rm -f "$DST/br.mp4"; run_capture 'video_bitrate=":+:1000"' 'video_quality=":-:23"'
if log_has "-b:v 1000k"; then pass "запрошено 1000 < видео 1808 → используется 1000k"; else fail "запрос ниже исходного" "-b:v 1000k" "$(grep -o '\-b:v [0-9]*k' "$FFMPEG_LOG" | head -1)"; fi

# Контейнер без per-stream битрейта (MKV/WebM): честный fallback + явный WARN,
# а не молчаливая выдача битрейта контейнера за битрейт видео.
OLD_VB="${MOCK_FFMPEG_VIDEO_BITRATE-}"
export MOCK_FFMPEG_VIDEO_BITRATE=""
rm -f "$DST/br.mp4"; run_capture 'video_bitrate=":+:1900"' 'video_quality=":-:23"'
if log_has "-b:v 1900k"; then pass "fallback: контейнер 2000 > запрос 1900 → 1900k"; else fail "fallback на контейнер" "-b:v 1900k" "$(grep -o '\-b:v [0-9]*k' "$FFMPEG_LOG" | head -1)"; fi
assert_contains "fallback: предупреждение о битрейте контейнера" "битрейт видеопотока не сообщён" "$OUT_TEXT"
unset MOCK_FFMPEG_VIDEO_BITRATE
rm -f "$IN/br.mp4" "$DST/br.mp4"

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

# F24: отключённый аудиокодек (статус '-') не передаётся в ffmpeg как -c:a вовсе,
# поэтому отклонять его как «несовместимый с WebM» не за что — контейнер сам
# выберет дефолт. Проверка смотрела на значение из конфига, игнорируя статус.
run_capture 'output_container=":+:webm"' 'video_codec=":+:libvpx-vp9"' 'audio_codec=":-:aac"'
assert_not_contains "webm + отключённый aac: НЕ отклонён" "WebM не поддерживает аудиокодек" "$OUT_TEXT"
assert_contains     "webm + отключённый aac: доходит до сводки" "Обработано:" "$OUT_TEXT"
if log_has "-c:a aac"; then fail "webm + отключённый aac: -c:a не передан" "нет -c:a aac" "передан в ffmpeg"; else pass "webm + отключённый aac: -c:a не передан"; fi
# Включённый несовместимый кодек по-прежнему обязан отклоняться.
run_capture 'output_container=":+:webm"' 'video_codec=":+:libvpx-vp9"' 'audio_codec=":+:aac"'
assert_contains "webm + включённый aac: отклонён" "WebM не поддерживает аудиокодек" "$OUT_TEXT"
rm -f "$IN/f.mp4" "$DST/f.webm"

# F24 (паритет PS1/CMD): source-scan — проверка обязана смотреть на сформированный
# аргумент, а не на *_codec_value. В CMD дополнительно нужен guard `if defined`:
# `!undefined:-c:a =!` раскрывается в литерал `-c:a =`, а не в пустую строку.
PS1_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")"
CMD_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")"
assert_contains     "PS1: webm-проверка использует set_audio_codec"  '$_effAudioCodec = $set_audio_codec' "$PS1_SRC"
assert_not_contains "PS1: не проверяет audio_codec_value напрямую"   'if ($audio_codec_value -and $audio_codec_value.ToLower() -notmatch' "$PS1_SRC"
assert_contains     "PS1: video-набор заякорен с конца"              'libaom-av1)$'      "$PS1_SRC"
assert_contains     "CMD: webm-проверка использует set_audio_codec"  'set "_eff_ac=!set_audio_codec:-c:a =!"' "$CMD_SRC"
assert_contains     "CMD: guard 'if defined' перед подстановкой"     'if defined set_audio_codec set "_eff_ac='  "$CMD_SRC"
assert_not_contains "CMD: не сверяет audio_codec_value со списком"   'if /i "!audio_codec_value!"=="%%c" set "_ac_ok=1"' "$CMD_SRC"

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

# ══════════════════════════════════════════════════════════════
suite "F26: имя temp сохраняет расширение (иначе ffmpeg не выводит muxer)"
# ══════════════════════════════════════════════════════════════
# Суть: temp назывался `.movie.mp4.partial` — расширение стало `.partial`. Режимы
# merge и copy_codecs идут с `-c copy` БЕЗ выходного -f, а без него настоящий ffmpeg
# выводит muxer из расширения и падает: "Error initializing the muxer ... Invalid
# argument". Общий мок этого не проверял (писал в любой файл), поэтому merge был
# сломан незаметно. Мок с тех пор ужесточён — тест намеренно идёт через ОБЩИЙ мок,
# так что заодно проверяет, что тот воспроизводит контракт настоящего ffmpeg.

# --- merge (-c copy, выходного -f нет; `-f concat` относится ко ВХОДУ) ---
touch "$IN/q1.mp4" "$IN/q2.mp4"; rm -f "$DST/q1.mp4"
run_capture 'merge_files="yes"'
assert_not_contains "merge: muxer инициализируется (temp сохранил расширение)" "Error initializing the muxer" "$OUT_TEXT"
if [ -f "$DST/q1.mp4" ]; then pass "merge: цель создана"; else fail "merge: цель создана" "есть q1.mp4" "нет"; fi
rm -f "$IN/q1.mp4" "$IN/q2.mp4" "$DST/q1.mp4"

# --- copy_codecs (-c copy -map 0, без -f) ---
touch "$IN/cc.avi"; rm -f "$DST/cc.avi"
run_capture 'copy_codecs="yes"'
assert_not_contains "copy_codecs: muxer инициализируется" "Error initializing the muxer" "$OUT_TEXT"
if [ -f "$DST/cc.avi" ]; then pass "copy_codecs: выход создан"; else fail "copy_codecs: выход создан" "есть cc.avi" "нет"; fi
rm -f "$IN/cc.avi" "$DST/cc.avi" "$DST/.cc.ffconv"

# ══════════════════════════════════════════════════════════════
suite "F27: параллельный режим не отклоняет файлы ложной коллизией"
# ══════════════════════════════════════════════════════════════
# Суть: encode_file уходит в дочернюю оболочку (xargs bash -c), а canon_path не был
# в списке export -f. Обе стороны сравнения «выход == вход» становились пустыми
# строками — то есть равными — и КАЖДЫЙ файл отклонялся как ложная коллизия.
touch "$IN/par1.mp4" "$IN/par2.mp4"; rm -f "$DST/par1.mp4" "$DST/par2.mp4"
run_capture 'parallel_files=":+:2"'
assert_not_contains "параллель: нет ложной коллизии in==out" "выход совпадает с входом" "$OUT_TEXT"
assert_not_contains "параллель: canon_path доступен в дочерней оболочке" "canon_path: command not found" "$OUT_TEXT"
if [ -f "$DST/par1.mp4" ] && [ -f "$DST/par2.mp4" ]; then pass "параллель: оба файла перекодированы"; else fail "параллель: оба файла перекодированы" "par1.mp4 + par2.mp4" "$(ls "$DST" 2>/dev/null | tr '\n' ' ')"; fi
rm -f "$IN"/par*.mp4 "$DST"/par*.mp4 "$DST"/.par*.ffconv

# ══════════════════════════════════════════════════════════════
suite "F17: готовность многочастного выхода подтверждает manifest, а не (part.1)"
# ══════════════════════════════════════════════════════════════
# Суть: наличие ОДНОЙ лишь `(part.1)` трактовалось как «файл целиком готов». Если
# остальные части не создались (обрыв, падение, нехватка места), весь input молча
# пропускался, и хвост исходника терялся навсегда.
split_run() {
    OUT_TEXT=$(
        export PATH="$MOCKS_DIR:$PATH"; export MOCK_FFMPEG_ENCODERS=""; export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        export MOCK_FFMPEG_DURATION="00:02:00.00"
        rm -f "$FFMPEG_LOG"
        default_vars; length_coding=":+:00-00-30"
        for ov in "$@"; do eval "$ov"; done
        source "$SCRIPT" 2>&1
    ) < /dev/null
}

touch "$IN/sp.mp4"; rm -f "$DST"/sp*.mp4 "$DST"/.sp.ffconv
# Осиротевшая part.1 без manifest — ровно тот случай, где старый код сдавался.
: > "$DST/sp (part.1).mp4"
split_run
if log_has "-c:v libx264"; then pass "осиротевшая (part.1): файл дообработан, а не пропущен"; else fail "осиротевшая (part.1): файл дообработан" "ffmpeg вызван" "пропущен как готовый"; fi

# Успешный полный прогон → manifest complete со всеми частями.
rm -f "$DST"/sp*.mp4 "$DST"/.sp.ffconv
split_run
if [ -f "$DST/.sp.ffconv" ]; then pass "полный прогон: manifest записан"; else fail "полный прогон: manifest записан" "есть .sp.ffconv" "нет"; fi
assert_contains "manifest: помечен complete" "state=complete" "$(cat "$DST/.sp.ffconv" 2>/dev/null)"
MF_PARTS=$(grep -c '^output=' "$DST/.sp.ffconv" 2>/dev/null || echo 0)
assert_eq "manifest: перечислены все 4 части" "4" "$MF_PARTS"

# Повтор при полном manifest → пропуск.
split_run
if log_has "-c:v libx264"; then fail "полный manifest: повтор пропущен" "ffmpeg не вызван" "перекодировал заново"; else pass "полный manifest: повтор пропущен"; fi

# Удалили одну часть → manifest есть, но выход неполон → доработать, а не пропустить.
rm -f "$DST/sp (part.3).mp4"
split_run
if log_has "-c:v libx264"; then pass "пропавшая часть: manifest обесценен, файл переработан"; else fail "пропавшая часть: файл переработан" "ffmpeg вызван" "пропущен"; fi

# Источник изменился → manifest обесценен (сверка по размеру).
rm -f "$DST"/sp*.mp4 "$DST"/.sp.ffconv; split_run
printf 'ИЗМЕНЁННЫЙ ИСТОЧНИК' > "$IN/sp.mp4"
split_run
if log_has "-c:v libx264"; then pass "изменённый источник: manifest обесценен"; else fail "изменённый источник: manifest обесценен" "ffmpeg вызван" "пропущен"; fi
rm -f "$IN/sp.mp4" "$DST"/sp*.mp4 "$DST"/.sp.ffconv

# ══════════════════════════════════════════════════════════════
suite "F17b: manifest обесценивается при смене настроек выхода"
# ══════════════════════════════════════════════════════════════
# Manifest, привязанный только к источнику, пропустил бы файл при смене контейнера —
# запрошенный выход так и не был бы создан.
touch "$IN/sig.mp4"; rm -f "$DST"/sig.* "$DST"/.sig.ffconv
run_capture 'output_container=":+:mkv"'
if [ -f "$DST/sig.mkv" ]; then pass "первый прогон: mkv создан"; else fail "первый прогон: mkv создан" "есть sig.mkv" "нет"; fi
run_capture 'output_container=":+:mkv"'
if log_has "-c:v libx264"; then fail "те же настройки: повтор пропущен" "ffmpeg не вызван" "вызван"; else pass "те же настройки: повтор пропущен"; fi
run_capture 'output_container=":+:mp4"'
if [ -f "$DST/sig.mp4" ]; then pass "смена контейнера: mp4 создан (manifest обесценен)"; else fail "смена контейнера: mp4 создан" "есть sig.mp4" "нет"; fi
rm -f "$IN/sig.mp4" "$DST"/sig.* "$DST"/.sig.ffconv

# ══════════════════════════════════════════════════════════════
suite "F18: прерванное кодирование не оставляет файл под финальным именем"
# ══════════════════════════════════════════════════════════════
# Суть: ffmpeg писал сразу в out_file. Обрыв БЕЗ шанса на очистку (kill -9, пропажа
# питания, переполнение диска) оставлял обрезанный файл под финальным именем, и
# следующий запуск принимал его за готовый результат. Ветка `rm -f` от этого не
# спасает — она просто не успевает выполниться. Проверяем структурное свойство,
# которое и даёт гарантию: имя цели не передаётся ffmpeg вовсе, оно появляется
# только атомарным переименованием уже дописанного файла.
touch "$IN/tx.mp4"; rm -f "$DST/tx.mp4" "$DST"/.ffconv-partial-* "$DST"/.tx.ffconv
run_capture
if log_has ".ffconv-partial-tx.mp4"; then pass "ffmpeg пишет во временное имя, а не в цель"; else fail "ffmpeg пишет во временное имя" "аргумент .ffconv-partial-tx.mp4" "ffmpeg получил финальное имя"; fi
ENC_ARGS=$(grep -F -- "-c:v libx264" "$FFMPEG_LOG" 2>/dev/null | head -1)
if grep -qE -- "(^| )$DST/tx\.mp4( |$)" <<< "$ENC_ARGS"; then fail "финальное имя не передаётся ffmpeg" "нет $DST/tx.mp4 в аргументах" "$ENC_ARGS"; else pass "финальное имя не передаётся ffmpeg"; fi
rm -f "$DST/tx.mp4" "$DST/.tx.ffconv"

run_capture 'export MOCK_FFMPEG_FAIL=1'
if [ ! -f "$DST/tx.mp4" ]; then pass "провал: финального имени нет"; else fail "провал: финального имени нет" "нет tx.mp4" "создан обрезанный"; fi
if ls "$DST"/.ffconv-partial-* >/dev/null 2>&1; then fail "провал: temp убран" "нет temp" "остался: $(ls "$DST"/.ffconv-partial-* 2>/dev/null)"; else pass "провал: temp убран"; fi
if [ ! -f "$DST/.tx.ffconv" ]; then pass "провал: manifest не записан"; else fail "провал: manifest не записан" "нет" "есть"; fi

# Успех: финальное имя появляется, temp исчезает.
run_capture
if [ -f "$DST/tx.mp4" ]; then pass "успех: финальный файл на месте"; else fail "успех: финальный файл на месте" "есть tx.mp4" "нет"; fi
if ls "$DST"/.ffconv-partial-* >/dev/null 2>&1; then fail "успех: temp убран" "нет temp" "остался"; else pass "успех: temp убран"; fi
rm -f "$IN/tx.mp4" "$DST/tx.mp4" "$DST/.tx.ffconv"

# ══════════════════════════════════════════════════════════════
suite "F17/F18/F23/F26 (паритет PS1/CMD): transactional + manifest + merge"
# ══════════════════════════════════════════════════════════════
# SH проверен поведенчески выше. Для PS1/CMD (нет кроссплатформенного раннера в
# Git Bash) держим source-scan на те же инварианты — иначе платформы разъедутся.
PS1_SRC2="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")"
CMD_SRC2="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")"

# --- Транзакционная запись: ffmpeg получает temp, цель появляется переименованием ---
assert_contains     "PS1: есть Get-PartialPath"                 'function Get-PartialPath'          "$PS1_SRC2"
assert_contains     "PS1: temp — префикс (расширение сохранено)" '".ffconv-partial-$leaf"'          "$PS1_SRC2"
assert_contains     "PS1: ffmpeg пишет в out_tmp"               '$ffmpegArgs += @($out_tmp, "-y")'  "$PS1_SRC2"
assert_contains     "PS1: цель появляется переименованием"      'Move-Item -LiteralPath $out_tmp -Destination $out_file -Force' "$PS1_SRC2"
assert_not_contains "PS1: цель не передаётся ffmpeg напрямую"   '$ffmpegArgs += @($out_file, "-y")' "$PS1_SRC2"
assert_contains     "CMD: temp — префикс (расширение сохранено)" 'set "out_tmp=%folder_destination%!file_path!.ffconv-partial-!file_name!!pref!.!current_format_out!"' "$CMD_SRC2"
assert_contains     "CMD: ffmpeg пишет в out_tmp"               '!out_seek! "!out_tmp!" -y'         "$CMD_SRC2"
assert_contains     "CMD: цель появляется переименованием"      'move /y "!out_tmp!" "!out_file!"'  "$CMD_SRC2"

# --- Manifest вместо (part.1) ---
assert_contains     "PS1: есть Test-ManifestComplete"           'function Test-ManifestComplete'    "$PS1_SRC2"
assert_contains     "PS1: manifest сверяет подпись настроек"    'settings=*'                        "$PS1_SRC2"
assert_not_contains "PS1: (part.1) больше не признак готовности" 'Test-Path "$out_base (part.1).$current_format_out"' "$PS1_SRC2"
assert_contains     "CMD: есть :manifest_is_complete"           ':manifest_is_complete'             "$CMD_SRC2"
assert_contains     "CMD: state=complete дописывается последней" '>>"!_mf!.tmp" echo state=complete' "$CMD_SRC2"
assert_not_contains "CMD: (part.1) больше не признак готовности" 'if not exist "%folder_destination%!file_path!!file_name! (part.1).!current_format_out!" (' "$CMD_SRC2"

# --- merge: -nostdin -y + temp + валидация (F23 был закрыт только в SH) ---
assert_contains     "PS1: merge с -nostdin -y"                  '-nostdin -strict -2 -f concat -safe 0 -i $tmpFile -c copy -map 0 -y $mergeTmp' "$PS1_SRC2"
assert_contains     "PS1: merge валидирует до подмены цели"     '& $ffmpeg -nostdin -v error -i $mergeTmp -f null -' "$PS1_SRC2"
assert_contains     "PS1: merge подменяет цель переименованием" 'Move-Item -LiteralPath $mergeTmp -Destination $mergeTarget -Force' "$PS1_SRC2"
assert_not_contains "PS1: merge не пишет прямо в цель"          '-c copy -map 0 "$folder_destination\$fname"' "$PS1_SRC2"
assert_contains     "CMD: merge с -nostdin -y"                  '-nostdin -strict -2 -f concat -safe 0 -i "!full_path!" -c copy -map 0 -y "!_merge_tmp!"' "$CMD_SRC2"
assert_contains     "CMD: merge валидирует до подмены цели"     '-i "!_merge_tmp!" -f null -'       "$CMD_SRC2"
assert_contains     "CMD: merge подменяет цель переименованием" 'move /y "!_merge_tmp!" "!_merge_target!"' "$CMD_SRC2"

# --- Ни одна платформа не должна вернуться к суффиксному .partial ---
# Это и есть тот дефект, что ломал muxer: расширением становилось `.partial`.
for _f in FFmpeg_Converter_script.sh FFmpeg_Converter_script.ps1 FFmpeg_Converter_script.cmd; do
    if grep -qE '\.(partial)"?$|\{fname\}\.partial|\$fname\.partial|!fname!\.partial' "$PROJECT_DIR/ffmpeg/$_f" 2>/dev/null; then
        fail "$_f: нет суффиксного .partial" "temp только префиксом" "найден суффикс .partial"
    else
        pass "$_f: нет суффиксного .partial"
    fi
done

# ══════════════════════════════════════════════════════════════
suite "F29: размер входа в сводке считается один раз, а не за каждую часть"
# ══════════════════════════════════════════════════════════════
# Тот же расклад, что в F16: файл режется на 4 части. Вход — ровно 4096 байт (4 KB).
# Раньше запись "ok" писалась на каждую часть и несла ПОЛНЫЙ размер источника,
# поэтому сводка показывала вход 4×4096 = 16 KB и завышенное сжатие: чем больше
# частей, тем «лучше» выглядел результат. Выход считается по частям — это верно.
dd if=/dev/zero of="$IN/stats.mp4" bs=1024 count=4 2>/dev/null
OUT_TEXT=$(
    export PATH="$MOCKS_DIR:$PATH"; export MOCK_FFMPEG_ENCODERS=""; export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
    export MOCK_FFMPEG_DURATION="00:02:00.00"
    export MOCK_FFMPEG_SILENCE="28:32 55:59 94:98"
    rm -f "$FFMPEG_LOG"
    default_vars
    length_coding=":+:00-00-30"; split_by_silence="yes"
    source "$SCRIPT" 2>&1
) < /dev/null

assert_contains "4 части действительно созданы" "(part.4)" "$OUT_TEXT"
assert_contains "вход засчитан один раз (4 KB, не 16 KB)" "Вход:        4 KB" "$OUT_TEXT"
assert_not_contains "вход НЕ умножен на число частей" "Вход:        16 KB" "$OUT_TEXT"
rm -f "$IN/stats.mp4" "$DST"/stats*.mp4

# ══════════════════════════════════════════════════════════════
suite "F32: sidecar-субтитры находятся и при save_old_extension=yes"
# ══════════════════════════════════════════════════════════════
# Суть: имя выхода и стем входа жили в одной переменной. При save_old_extension=yes
# она становилась "movie.mp4", поэтому sidecar искался как "movie.mp4.srt" вместо
# "movie.srt" — прожиг/метаданные субтитров молча пропускались.
touch "$IN/sub.mp4"
printf '1\n00:00:00,000 --> 00:00:01,000\nX\n' > "$IN/sub.srt"

# save_old_extension=no — работало и раньше, фиксируем как контроль.
run_capture 'video_subtitles=":+:burn"'
if log_has "subtitles="; then pass "save_old_extension=no: субтитры прожигаются"; else fail "save_old_extension=no: субтитры прожигаются" "фильтр subtitles=" "нет"; fi

# save_old_extension=yes — суть находки: sidecar обязан найтись по стему.
run_capture 'video_subtitles=":+:burn"' 'save_old_extension="yes"'
if log_has "subtitles="; then pass "save_old_extension=yes: субтитры прожигаются (F32)"; else fail "save_old_extension=yes: субтитры прожигаются (F32)" "фильтр subtitles=" "нет — sidecar не найден"; fi
# Имя выхода при этом обязано сохранить расширение источника: sub.mp4 -> sub.mp4.mp4
if log_has "sub.mp4.mp4"; then pass "save_old_extension=yes: имя выхода несёт расширение источника"; else fail "save_old_extension=yes: имя выхода несёт расширение источника" "sub.mp4.mp4" "нет"; fi
rm -f "$IN/sub.mp4" "$IN/sub.srt" "$DST"/sub*

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
