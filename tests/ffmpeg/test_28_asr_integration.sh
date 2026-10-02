#!/bin/bash
# Путь к дот-сорсимому скрипту вычисляется в рантайме (SC1090); переменные,
# которые здесь только присваиваются, читает production-скрипт (SC2034).
# shellcheck disable=SC1090,SC2034
# ============================================================
# test_28_asr_integration.sh — режим распознавания речи сквозь
# FFmpeg_Converter_script.sh: моки ffmpeg и curl, настоящие выборка входов,
# зеркало подпапок, пропуск готового, сводка и код возврата.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS="$TESTS_DIR/mocks"
FIX="$TESTS_DIR/fixtures/asr"
source "$TESTS_DIR/lib/framework.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_int_XXXXXX")"
IN="$WORK/in"; OUT="$WORK/out"
LIMITS="$(cat "$FIX/limits.json")"
BASIC="$(cat "$FIX/basic.json")"
TAB=$'\t'

default_vars() {
    folder_sources="$IN"; folder_destination="$OUT"; ffmpeg="$MOCKS/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":-:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":+:23"; keep_aspect_ratio=":+:yes"; output_container=":+:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"; overwrite_existing="no"
    copy_codecs="no"; extract_audio_copy="no"
    remote_enabled="no"; remote_endpoint=""; remote_api_key=""
    remote_api_key_command=""; remote_on_failure="abort"; remote_prefer="auto"; remote_wait_timeout="1800"
    asr_enabled="yes"; asr_endpoint="https://asr.example:30010"; asr_api_key="int-secret-key"
    asr_api_key_command=""; asr_pinned_pubkey=""; asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""
}

# RUN_OUT ← вывод скрипта, RUN_RC ← код возврата; маршруты мока curl — в $ROUTES.
run_asr() {
    RUN_OUT="$( (
        export PATH="$MOCKS:$PATH"
        export MOCK_FFMPEG_LOG="$WORK/ff.log" MOCK_CURL_LOG="$WORK/curl.log"
        export CURL_BIN="$MOCKS/curl" MOCK_CURL_ROUTES="$ROUTES"
        export FFCONV_ASR_NOW="2026-10-02 12:00" ASR_RETRY_WAIT=0
        default_vars
        for ov in "$@"; do eval "$ov"; done
        source "$SCRIPT" 2>&1
    ) < /dev/null )"
    RUN_RC=$?
}
reset_dirs() { rm -rf "$IN" "$OUT" "$WORK/ff.log" "$WORK/curl.log"; mkdir -p "$IN" "$OUT"; }
ok_routes() { ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}200${TAB}${BASIC}"; }
posts() { POSTS=0; [ -f "$WORK/curl.log" ] && POSTS="$(grep -c 'speech/transcriptions' "$WORK/curl.log")"; }

# ══════════════════════════════════════════════════════════════
suite "файл целиком: .txt и .asr.json в зеркале подпапки"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes
mkdir -p "$IN/sub"; : > "$IN/sub/Встреча 1.mp4"
run_asr
assert_eq "код возврата 0" "0" "$RUN_RC"
_txt="$OUT/sub/Встреча 1.txt"
assert_file_exists "расшифровка в зеркале подпапки" "$_txt"
assert_eq "шапка называет исходный файл" "# Расшифровка: Встреча 1.mp4" "$(head -1 "$_txt" 2>/dev/null)"
assert_eq "остальное — как у фикстуры" "$(tail -n +2 "$FIX/basic.txt")" "$(tail -n +2 "$_txt" 2>/dev/null)"
assert_eq "сырой ответ сохранён" "$BASIC" "$(cat "$OUT/sub/Встреча 1.asr.json" 2>/dev/null)"
_ff="$(cat "$WORK/ff.log" 2>/dev/null)"
assert_contains "звук — FLAC 16 кГц моно" "-map 0:a:0 -vn -ac 1 -ar 16000 -c:a flac" "$_ff"
assert_not_contains "целиком — без -ss" "-ss" "$_ff"
assert_contains "сводка" "Обработано:  1" "$RUN_OUT"
assert_not_contains "ключ не печатается" "int-secret-key" "$RUN_OUT"
assert_empty "временных файлов в назначении нет" "$(find "$OUT" -name '.ffconv-partial-*')"

# ══════════════════════════════════════════════════════════════
suite "длинная запись — равные части, смещения в JSON и шапке"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/long.mp4"
run_asr 'export MOCK_FFMPEG_DURATION=01:00:00.00'
assert_eq "код возврата 0" "0" "$RUN_RC"
_ff="$(cat "$WORK/ff.log" 2>/dev/null)"
assert_contains "вторая часть" "-ss 1201 -t 1201" "$_ff"
assert_contains "третья часть — до конца файла" "-ss 2402 -i" "$_ff"
assert_not_contains "у последней части нет -t" "-t 1199" "$_ff"
posts; assert_eq "три запроса" "3" "$POSTS"
_j="$(cat "$OUT/long.asr.json" 2>/dev/null)"
assert_contains "обёртка частей" '{"chunks":[{"offset_seconds":0,"response":' "$_j"
assert_contains "смещение третьей" '"offset_seconds":2402,"response":' "$_j"
assert_contains "шапка о частях" "# Частей: 3 по ≈00:20:01 — метки говорящих в разных частях независимы" "$(cat "$OUT/long.txt" 2>/dev/null)"

# ══════════════════════════════════════════════════════════════
suite "готовое пропускается; overwrite_existing = yes — пересчёт"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr
rm -f "$WORK/curl.log"
run_asr
assert_eq "повтор — код 0" "0" "$RUN_RC"
assert_contains "пропуск назван" "расшифровка уже есть" "$RUN_OUT"
posts; assert_eq "повтор не отправляет запись" "0" "$POSTS"
rm -f "$WORK/curl.log"
run_asr 'overwrite_existing="yes"'
posts; assert_eq "overwrite — запрос снова" "1" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "файл без звука — провал без запроса"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/mute.mp4"
run_asr 'export MOCK_FFMPEG_NO_AUDIO=1'
assert_eq "код 1" "1" "$RUN_RC"
assert_contains "причина" "нет звуковой дорожки" "$RUN_OUT"
posts; assert_eq "запроса нет" "0" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "400 — провален файл, прогон продолжается"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}400${TAB}{\"detail\":\"ffprobe не прочитал аудио\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
posts; assert_eq "оба файла отправлены" "2" "$POSTS"
assert_contains "detail дословно" "HTTP 400: ffprobe не прочитал аудио" "$RUN_OUT"
assert_not_contains "прогон не останавливался" "Остановлено:" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "401 на запросе — прогон остановлен, остаток не тронут"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}401${TAB}{\"detail\":\"bad key\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
posts; assert_eq "только один запрос" "1" "$POSTS"
assert_contains "причина в сводке" "Остановлено: ключ не принят (HTTP 401)" "$RUN_OUT"
assert_contains "остаток посчитан" "Не обработано: 1" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "preflight: ключ не принят — ни один файл не тронут"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"
ROUTES="GET /speech/limits${TAB}401${TAB}{\"detail\":\"bad key\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
assert_contains "причина" "ключ не принят (HTTP 401)" "$RUN_OUT"
assert_not_contains "файлы не трогались" "Обработано:" "$RUN_OUT"
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'asr_language="de"'
assert_eq "чужой язык — код 1" "1" "$RUN_RC"
assert_contains "язык назван" "language = 'de'" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "dry_run: план и команды без извлечения и отправки"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'dry_run="yes"' 'export MOCK_FFMPEG_DURATION=01:00:00.00'
assert_eq "код 0" "0" "$RUN_RC"
assert_contains "план" "[DRY-RUN] a.mp4: частей 3" "$RUN_OUT"
assert_contains "команда ffmpeg" "-c:a flac part_002.flac" "$RUN_OUT"
assert_contains "запрос" "speech/transcriptions" "$RUN_OUT"
assert_not_contains "ключа в выводе нет" "int-secret-key" "$RUN_OUT"
posts; assert_eq "отправки нет" "0" "$POSTS"
assert_empty "файлов нет" "$(ls -A "$OUT")"

# ══════════════════════════════════════════════════════════════
suite "два входа на один .txt; destination = source"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/x.mp4"; : > "$IN/x.mkv"
run_asr
assert_eq "коллизия — код 1" "1" "$RUN_RC"
assert_contains "конфликт назван" "конфликт выходов" "$RUN_OUT"
posts; assert_eq "отправлен только первый" "1" "$POSTS"
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'folder_destination="$IN"'
assert_file_exists "рядом с записью" "$IN/a.txt"
rm -f "$WORK/curl.log"
run_asr 'folder_destination="$IN"'
posts; assert_eq "повтор in-place не отправляет" "0" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "[remote] и parallel_files в режиме распознавания"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'remote_enabled="yes"' 'remote_endpoint="http://svc.example/v1"' 'remote_api_key="r"' 'parallel_files=":+:3"'
assert_contains "[remote] не используется — сказано" "[remote] в режиме распознавания не используется" "$RUN_OUT"
assert_not_contains "служба конвертации не опрашивалась" "/capabilities" "$(cat "$WORK/curl.log" 2>/dev/null)"
assert_contains "parallel_files назван" "parallel_files в режиме распознавания игнорируется" "$RUN_OUT"
assert_eq "код 0" "0" "$RUN_RC"

rm -rf "$WORK"
summary
