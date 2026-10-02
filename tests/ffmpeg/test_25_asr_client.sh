#!/bin/bash
# Тест дот-сорсит настоящий модуль: переменные asr_*, которые здесь только
# присваиваются, читает он (SC2034); а те, что выставляет дот-сорснутый
# run_v19.sh, shellcheck не видит (SC2154).
# shellcheck disable=SC2034,SC2154
# ============================================================
# test_25_asr_client.sh — клиент распознавания речи (.sh): ключи [asr] в
# run_v19.sh, адреса, пределы сервера, план частей, аргументы curl, исходы,
# выбор адреса и запрос через мок curl, сборка текста и JSON из общих фикстур
# tests/fixtures/asr (те же ожидаемые .txt сверяет test_26 для .ps1).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/asr_client.sh"

FIX="$TESTS_DIR/fixtures/asr"
MOCK_CURL="$TESTS_DIR/mocks/curl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_XXXXXX")"
LIMITS="$(cat "$FIX/limits.json")"
TAB=$'\t'
_join() { local IFS='|'; JOINED="$*"; }

# ══════════════════════════════════════════════════════════════
suite "ключи [asr] читаются в run_v19.sh"
# ══════════════════════════════════════════════════════════════
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.sh" "$WORK/run.sh"
printf '%s\n' '[asr]' 'enabled = yes' 'endpoint = ${FF_T_ASR_UNSET} https://b.example:30010/' \
    'api_key = k1' 'api_key_command = printf k2' 'pinned_pubkey = sha256//AAA=' \
    'language = en' 'diarize = no' 'num_speakers = 3' > "$WORK/config.ini"
_vals="$( unset FF_T_ASR_UNSET; source "$WORK/run.sh" 2>"$WORK/warn.txt"
    printf '%s|%s|%s|%s|%s|%s|%s|%s' "$asr_enabled" "$asr_endpoint" "$asr_api_key" \
        "$asr_api_key_command" "$asr_pinned_pubkey" "$asr_language" "$asr_diarize" "$asr_num_speakers" )"
assert_eq "все восемь ключей разобраны" \
    "yes| https://b.example:30010/|k1|printf k2|sha256//AAA=|en|no|3" "$_vals"
assert_not_contains "незаданная \${VAR} в [asr] не печатает WARN" "FF_T_ASR_UNSET" "$(cat "$WORK/warn.txt")"
printf '[asr]\n' > "$WORK/config.ini"
_vals="$( source "$WORK/run.sh" 2>/dev/null; printf '%s|%s|%s' "$asr_enabled" "$asr_language" "$asr_diarize" )"
assert_eq "умолчания" "no|ru|yes" "$_vals"

# ══════════════════════════════════════════════════════════════
suite "адреса: список через пробел, без хвостовых слэшей"
# ══════════════════════════════════════════════════════════════
asr_split_endpoints "  https://a.example:30010/  http://b.example:30000//  "
_join "${ASR_ENDPOINTS[@]}"
assert_eq "два адреса, слэши сняты" "https://a.example:30010|http://b.example:30000" "$JOINED"
asr_split_endpoints ""
assert_eq "пустая строка — ни одного адреса" "0" "${#ASR_ENDPOINTS[@]}"

# ══════════════════════════════════════════════════════════════
suite "пределы сервера из /speech/limits"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"; _rc=$?
assert_eq "разобраны" "0" "$_rc"
_join "$ASR_LIM_MAX_SECONDS" "$ASR_LIM_MAX_BYTES" "$ASR_LIM_JOB_TIMEOUT" "$ASR_LIM_DEVICE" "$ASR_LIM_DIARIZATION" "$ASR_LIM_VER"
assert_eq "числа — целой частью, строки без кавычек" \
    "3600|524288000|1800|cpu|true|large-v3-turbo.cpu.int8.v1" "$JOINED"
assert_eq "языки списком" "en ru" "$ASR_LIM_LANGUAGES"
asr_parse_limits '<html>502 Bad Gateway</html>'; _rc=$?
assert_eq "не пределы — отказ" "1" "$_rc"
# Странные данные сервера: тот же исход, что у Get-AsrLimits (сверяет test_27).
asr_parse_limits '{"max_seconds":"3600","job_timeout_sec":1800.7,"device":"CPU","languages":null,"max_bytes":"x"}'; _rc=$?
assert_eq "числа строкой, languages: null — пределы" "0" "$_rc"
assert_eq "null — не язык «null»" "" "$ASR_LIM_LANGUAGES"
assert_eq "нечисловой max_bytes — без предела" "" "$ASR_LIM_MAX_BYTES"
assert_eq "CPU заглавными — формула процессора" "3000" "$ASR_PLAN_WHOLE"
asr_parse_limits '{"max_seconds":"0036","job_timeout_sec":1800,"languages":["ru",null,"en"]}'
assert_eq "ведущие нули — десятичное число" "36" "$ASR_LIM_MAX_SECONDS"
assert_eq "null в списке языков пропущен" "ru en" "$ASR_LIM_LANGUAGES"
for _b in '{"max_seconds":"abc","job_timeout_sec":1800}' '{"max_seconds":null,"job_timeout_sec":1800}' \
          '{"max_seconds":-5,"job_timeout_sec":1800}' '{"max_seconds":99999999999999999999,"job_timeout_sec":1800}' \
          '{"max_seconds":1,"job_timeout_sec":1800}' '{"max_seconds":3600,"job_timeout_sec":1,"device":"cpu"}'; do
    asr_parse_limits "$_b"; _rc=$?
    assert_eq "отказ: $_b" "1" "$_rc"
done

# ══════════════════════════════════════════════════════════════
suite "план частей (спека §6)"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"
for _c in "2999:0:2999" "3000:0:3000" "3001:0:1001 1001:1001 2002:999" \
          "5400:0:1350 1350:1350 2700:1350 4050:1350"; do
    asr_plan_parts "${_c%%:*}"
    assert_eq "cpu, ${_c%%:*} с" "${_c#*:}" "$ASR_PLAN"
done
asr_plan_parts 3001
assert_eq "длина части при нарезке" "1001" "$ASR_PLAN_LEN"
assert_eq "предел «целиком» на cpu" "3000" "$ASR_PLAN_WHOLE"
ASR_LIM_DEVICE="cuda"; ASR_LIM_MAX_SECONDS=7200
asr_plan_parts 7200; assert_eq "cuda, 7200 с — целиком" "0:7200" "$ASR_PLAN"
asr_plan_parts 7201; assert_eq "cuda, 7201 с — три части" "0:2401 2401:2401 4802:2399" "$ASR_PLAN"

# ══════════════════════════════════════════════════════════════
suite "аргументы запроса распознавания"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"
asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""; asr_pinned_pubkey=""
asr_curl_args "https://h.example:30010" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_eq "https без пина — обычная проверка TLS" \
    "-sS|--connect-timeout|10|--max-time|2100|-F|file=@part_000.flac;type=audio/flac|-F|model=whisperx|-F|language=ru|-F|diarize=true|-o|resp_000.json|-w|%{http_code}|https://h.example:30010/speech/transcriptions" \
    "$JOINED"
asr_pinned_pubkey="sha256//AAA="
asr_curl_args "https://h.example:30010" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_contains "https с пином — -k только вместе с --pinnedpubkey" "--max-time|2100|-k|--pinnedpubkey|sha256//AAA=|-F" "$JOINED"
asr_curl_args "http://h.example:30000" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_not_contains "http — без -k" "|-k|" "$JOINED"
asr_diarize="no"; asr_num_speakers="4"
asr_curl_args "http://h.example:30000" "part_001.flac" "resp_001.json"
_join "${ASR_CURL_ARGS[@]}"
assert_contains "diarize = no → false" "-F|diarize=false" "$JOINED"
assert_contains "num_speakers — только когда задан" "-F|num_speakers=4|-o" "$JOINED"
asr_diarize="yes"; asr_num_speakers=""; asr_pinned_pubkey=""
# Отправка части входит в --max-time: 65 МБ на 1 Мбит/с — ещё 520 с сверх 2100.
asr_curl_args "http://h.example:30000" "part_000.flac" "resp_000.json" 65000000
_join "${ASR_CURL_ARGS[@]}"
assert_contains "--max-time с отправкой части" "--max-time|2620|" "$JOINED"
asr_curl_args "http://h.example:30000" "part_000.flac" "resp_000.json" 1
_join "${ASR_CURL_ARGS[@]}"
assert_contains "любой ненулевой размер — секунда вверх" "--max-time|2101|" "$JOINED"
asr_extract_args "/in/a b.mp4" 1001 999 3 "part_001.flac"
_join "${ASR_FF_ARGS[@]}"
assert_eq "извлечение части" "-nostdin|-v|error|-y|-ss|1001|-t|999|-i|/in/a b.mp4|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_001.flac" "$JOINED"
asr_extract_args "/in/a.mp4" 0 61 1 "part_000.flac"
_join "${ASR_FF_ARGS[@]}"
assert_not_contains "целиком — без -ss/-t" "-ss" "$JOINED"
# Последняя часть — до конца файла, без -t: длительность контейнера бывает занижена
# (VBR-MP3 без TOC, сырой ADTS), и -t молча срезал бы конец записи.
asr_extract_args "/in/a.mp3" 2002 "" 3 "part_002.flac"
_join "${ASR_FF_ARGS[@]}"
assert_eq "последняя часть — без -t" "-nostdin|-v|error|-y|-ss|2002|-i|/in/a.mp3|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_002.flac" "$JOINED"

# ══════════════════════════════════════════════════════════════
suite "исходы: файл провален или прогон остановлен"
# ══════════════════════════════════════════════════════════════
printf '{"detail":"язык вне languages"}' > "$WORK/detail.json"
_cl() { asr_classify "$@"; CL="$ASR_OUTCOME|$ASR_REASON"; }
ASR_CURL_ERR=""
_cl 0 200 "";                  assert_eq "200 — успех" "ok|" "$CL"
_cl 0 400 "$WORK/detail.json"; assert_eq "400 — файл, detail дословно" "file|HTTP 400: язык вне languages" "$CL"
_cl 0 413 "";                  assert_eq "413 — файл" "file|HTTP 413" "$CL"
_cl 0 422 "";                  assert_eq "422 — файл" "file|HTTP 422" "$CL"
_cl 0 401 "";                  assert_eq "401 — прогон" "stop|ключ не принят (HTTP 401)" "$CL"
_cl 0 403 "";                  assert_eq "403 — прогон" "stop|ключ не принят (HTTP 403)" "$CL"
_cl 0 500 "";                  assert_eq "500 — прогон" "stop|HTTP 500" "$CL"
_cl 0 504 "";                  assert_contains "504 — прогон, задача ещё идёт" "stop|сервер не уложился" "$CL"
_cl 90 000 "";                 assert_eq "curl 90 — прогон" "stop|сертификат сервера не совпал с закреплённым ключом (curl 90)" "$CL"
_cl 28 000 "";                 assert_contains "curl 28 — прогон" "stop|истёк таймаут" "$CL"
_cl 26 000 "";                 assert_eq "curl 26 — файл" "file" "$ASR_OUTCOME"
assert_contains "curl 26 — причина" "не смог прочитать извлечённый звук (curl 26)" "$CL"
ASR_CURL_ERR="Failed to connect"
_cl 7 000 "";                  assert_eq "прочие коды curl — прогон с причиной" "stop|сетевая ошибка (curl 7: Failed to connect)" "$CL"
ASR_CURL_ERR=""
# detail декодируется, как у ConvertFrom-Json в .ps1: \" \\ \uXXXX и суррогатная пара.
printf '%s' '{"detail":"q \"x\" s \\ да 😀 \ud800!"}' > "$WORK/detail_esc.json"
_cl 0 422 "$WORK/detail_esc.json"
assert_eq "detail без экранирования JSON" 'file|HTTP 422: q "x" s \ да 😀 �!' "$CL"

suite "причина сбоя ffmpeg — первая непустая строка без \\r"
printf '\r\n[in#0 @ 0x1] moov atom not found\r\nError opening input file x.\r\n' > "$WORK/ff.err"
asr_first_line "$WORK/ff.err"
assert_eq "первая непустая строка" "[in#0 @ 0x1] moov atom not found" "$ASR_LINE"
: > "$WORK/ff.err"; asr_first_line "$WORK/ff.err"
assert_eq "пустой stderr — пусто" "" "$ASR_LINE"

# ══════════════════════════════════════════════════════════════
suite "выбор адреса: первый ответивший; ключ — только в конфиге curl"
# ══════════════════════════════════════════════════════════════
export CURL_BIN="$MOCK_CURL" MOCK_CURL_LOG="$WORK/curl.log"
ASR_RUN_DIR="$WORK/run"; mkdir -p "$ASR_RUN_DIR"
asr_api_key="sekret-key-1"; asr_pinned_pubkey=""
asr_endpoint="https://a.example:30010 https://b.example:30010"
export MOCK_CURL_ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}"
export MOCK_CURL_FAIL_HOSTS="a.example"
: > "$MOCK_CURL_LOG"
asr_select_endpoint; _rc=$?
assert_eq "выбор удался" "0" "$_rc"
assert_eq "недоступный первый пропущен" "https://b.example:30010" "$ASR_BASE"
assert_eq "пределы сохранены" "1800" "$ASR_LIM_JOB_TIMEOUT"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "ключ ушёл заголовком через конфиг" 'header = "Authorization: Bearer sekret-key-1"' "$_log"
assert_empty "ключа нет в argv" "$(grep -F -- '--config' "$MOCK_CURL_LOG" | grep -F 'sekret-key-1')"
assert_contains "первый адрес опрошен" "https://a.example:30010/speech/limits" "$_log"

export MOCK_CURL_FAIL_HOSTS="a.example b.example"
asr_select_endpoint; _rc=$?
assert_eq "никто не ответил — отказ" "1" "$_rc"
assert_contains "в причине каждый адрес" "https://a.example:30010 → curl 7" "$ASR_STOP_REASON"
assert_contains "и второй" "https://b.example:30010 → curl 7" "$ASR_STOP_REASON"
unset MOCK_CURL_FAIL_HOSTS

export MOCK_CURL_ROUTES="GET /speech/limits${TAB}401${TAB}{\"detail\":\"нет ключа\"}"
: > "$MOCK_CURL_LOG"
asr_select_endpoint; _rc=$?
assert_eq "401 — отказ сразу" "1" "$_rc"
assert_contains "причина названа" "ключ не принят (HTTP 401)" "$ASR_STOP_REASON"
assert_not_contains "второй адрес не опрашивался" "b.example" "$(cat "$MOCK_CURL_LOG")"

export MOCK_CURL_EXIT=90
asr_select_endpoint; _rc=$?
assert_eq "чужой сертификат — отказ сразу" "1" "$_rc"
assert_contains "причина — сертификат" "не совпал с закреплённым ключом" "$ASR_STOP_REASON"
unset MOCK_CURL_EXIT

# ══════════════════════════════════════════════════════════════
suite "запрос части: файл относительным именем, повтор при 503, тело без segments"
# ══════════════════════════════════════════════════════════════
asr_endpoint="https://b.example:30010"; asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""
export MOCK_CURL_ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}"
asr_select_endpoint
printf 'FLAC' > "$ASR_RUN_DIR/part_000.flac"
_basic="$(cat "$FIX/basic.json")"
export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}200${TAB}${_basic}"
: > "$MOCK_CURL_LOG"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "200 — успех" "ok" "$ASR_OUTCOME"
assert_eq "ответ сохранён как есть" "$_basic" "$(cat "$ASR_RUN_DIR/resp_000.json")"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "часть — относительным именем (curl из Git Bash не открывает /tmp/…)" "file=@part_000.flac;type=audio/flac" "$_log"
assert_contains "модель" "model=whisperx" "$_log"
assert_contains "язык" "language=ru" "$_log"
assert_not_contains "num_speakers не задан — не отправлен" "num_speakers" "$_log"

printf '503\n503\n200\n' > "$WORK/seq"
export MOCK_CURL_CODE_SEQ_FILE="$WORK/seq" ASR_RETRY_WAIT=0
: > "$MOCK_CURL_LOG"
asr_transcribe_part "part_000.flac" "resp_000.json" 2>"$WORK/err.txt"
assert_eq "после двух 503 — успех" "ok" "$ASR_OUTCOME"
assert_eq "три попытки" "3" "$(grep -c 'speech/transcriptions' "$MOCK_CURL_LOG")"
assert_contains "о повторе сказано" "HTTP 503" "$(cat "$WORK/err.txt")"
printf '503\n503\n503\n503\n' > "$WORK/seq"
: > "$MOCK_CURL_LOG"
ASR_RETRIES=2 asr_transcribe_part "part_000.flac" "resp_000.json" 2>/dev/null
assert_eq "очередь полна и после повторов — прогон" "stop" "$ASR_OUTCOME"
assert_contains "причина — 503" "HTTP 503" "$ASR_REASON"
assert_eq "одна попытка и два повтора" "3" "$(grep -c 'speech/transcriptions' "$MOCK_CURL_LOG")"
unset MOCK_CURL_CODE_SEQ_FILE

export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}200${TAB}<html>gateway</html>"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "200 без segments — файл провален" "file|сервер ответил 200, но без поля segments" "$ASR_OUTCOME|$ASR_REASON"
export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}400${TAB}{\"detail\":\"ffprobe не прочитал аудио\"}"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "400 — файл, detail дословно" "file|HTTP 400: ffprobe не прочитал аудио" "$ASR_OUTCOME|$ASR_REASON"
unset MOCK_CURL_ROUTES

# ══════════════════════════════════════════════════════════════
suite "проверка [asr] до запуска"
# ══════════════════════════════════════════════════════════════
_vc() { asr_endpoint="$1"; asr_language="$2"; asr_diarize="$3"; asr_num_speakers="$4"
        asr_validate_config 2>"$WORK/vc.txt"; VC=$?; VC_ERR="$(cat "$WORK/vc.txt")"; }
_vc "https://a:1" ru yes "";   assert_eq "верная конфигурация" "0" "$VC"
_vc "" ru yes "";              assert_eq "пустой адрес" "1" "$VC"
assert_contains "подсказка про переменную" 'ASR_URL' "$VC_ERR"
_vc "ftp://a" ru yes "";       assert_eq "чужая схема" "1" "$VC"
_vc "https://a:1" "" yes "";   assert_eq "пустой язык" "1" "$VC"
_vc "https://a:1" ru maybe ""; assert_eq "diarize не yes/no" "1" "$VC"
# 2^64+5 арифметика bash превращала в 5 — проверка шаблоном, без $(( )).
for _n in 0 000 51 abc -1 99999999999999999999 18446744073709551621; do _vc "https://a:1" ru yes "$_n"; assert_eq "num_speakers=$_n отвергнут" "1" "$VC"; done
for _n in 1 05 50; do _vc "https://a:1" ru yes "$_n"; assert_eq "num_speakers=$_n принят" "0" "$VC"; done

# ══════════════════════════════════════════════════════════════
suite "ключ из api_key_command"
# ══════════════════════════════════════════════════════════════
ASR_API_KEY_RESOLVED="no"; asr_api_key=""; asr_api_key_command='printf "  cmd-key  \n"'
asr_resolve_api_key; _rc=$?
assert_eq "команда отработала" "0" "$_rc"
assert_eq "первая строка без пробелов" "cmd-key" "$asr_api_key"
ASR_API_KEY_RESOLVED="no"; asr_api_key_command='false'
asr_resolve_api_key 2>/dev/null; _rc=$?
assert_eq "упавшая команда — отказ" "1" "$_rc"
asr_api_key_command=""

# ══════════════════════════════════════════════════════════════
suite "сборка текста из ответов (общие фикстуры tests/fixtures/asr)"
# ══════════════════════════════════════════════════════════════
# $1 — ожидаемый .txt; дальше — аргументы asr_render (выход — четвёртый из них).
_render_check() {
    local want="$FIX/$1"; shift
    asr_render "$@"; local rc=$?
    if [ "$rc" -eq 0 ] && cmp -s "$want" "$4"; then pass "$(basename "$want"): байт в байт"
    else fail "$(basename "$want"): байт в байт" "$(cat "$want")" "$(cat "$4" 2>/dev/null)"; fi
}
_render_check basic.txt "meeting.mp4" "2026-10-02 12:00" 480 "$WORK/basic.txt" "$FIX/basic.json" 0
assert_eq "сводка: говорящие|сомнительные|этапы" "2|1|" "$ASR_R_SPEAKERS|$ASR_R_LOW|$ASR_R_BAD"
_render_check escapes.txt "escapes.mkv" "2026-10-02 12:00" 76 "$WORK/escapes.txt" "$FIX/escapes.json" 0
assert_eq "этапы с ошибкой в сводке" "align=unavailable, diarize=failed" "$ASR_R_BAD"
_render_check chunks.txt "long.mp4" "2026-10-02 12:00" 1001 "$WORK/chunks.txt" "$FIX/basic.json" 0 "$FIX/escapes.json" 1001
assert_eq "говорящие по частям" "2,1" "$ASR_R_SPEAKERS"
_render_check empty.txt "silence.wav" "2026-10-02 12:00" 10 "$WORK/empty.txt" "$FIX/empty.json" 0
# Один говорящий час подряд — не одна строка с одной меткой времени: реплика
# рвётся, когда следующий сегмент начинается через 60 с и больше от её начала.
_render_check monologue.txt "lecture.mp3" "2026-10-02 12:00" 130 "$WORK/monologue.txt" "$FIX/monologue.json" 0

# Ответ на 2000 сегментов со словами (~400 КБ): разбор обязан быть линейным. В
# BWK awk (macOS) substr считает длину всей строки на каждом вызове, и
# посимвольный проход по документу целиком был бы квадратичным — минуты вместо
# долей секунды. Предел времени ловит именно это, а не медленную машину: линейный
# разбор укладывается в доли секунды и на CI.
{
    printf '{"asr_ver":"x","segments":['
    for (( _i = 0; _i < 2000; _i++ )); do
        [ "$_i" -gt 0 ] && printf ','
        printf '{"start":%d.5,"end":%d.9,"text":" реплика %d \\"q\\"","speaker":"SPEAKER_0%d","confidence":0.9,"words":[{"word":"реплика","start":%d.5,"end":%d.7,"score":0.8}]}' \
            "$_i" "$_i" "$_i" $(( _i % 2 )) "$_i" "$_i"
    done
    printf '],"stages":{"transcribe":{"status":"ok"}},"warnings":[],"audio_seconds":2000.0,"processing_seconds":1000.0}'
} > "$WORK/big.json"
_t0=$SECONDS
asr_render "big.mp4" "2026-10-02 12:00" 2000 "$WORK/big.txt" "$WORK/big.json" 0
_el=$(( SECONDS - _t0 ))
if [ "$_el" -le 10 ]; then pass "разбор ~400 КБ — не дольше 10 с (${_el} с)"
else fail "разбор ~400 КБ — не дольше 10 с" "≤ 10 с" "${_el} с — разбор стал квадратичным?"; fi
assert_eq "2000 реплик" "2000" "$(grep -c '^\[' "$WORK/big.txt")"
assert_eq "последняя реплика цела" '[00:33:19] SPEAKER_01: реплика 1999 "q"' "$(tail -1 "$WORK/big.txt")"

# ══════════════════════════════════════════════════════════════
suite "JSON результата"
# ══════════════════════════════════════════════════════════════
asr_write_json "$WORK/one.json" "$FIX/basic.json" 0
assert_eq "одна часть — ответ без изменений" "$(cat "$FIX/basic.json")" "$(cat "$WORK/one.json")"
asr_write_json "$WORK/two.json" "$FIX/basic.json" 0 "$FIX/escapes.json" 1001
_two="$(cat "$WORK/two.json")"
assert_contains "обёртка, первая часть" '{"chunks":[{"offset_seconds":0,"response":{' "$_two"
assert_contains "вторая часть со смещением" '"offset_seconds":1001,"response":{"asr_ver"' "$_two"

rm -rf "$WORK"
summary
