#!/bin/bash
# ============================================================
# test_21_remote_client.sh — HTTP-слой клиента службы.
# Сети нет: curl подменяется моком через CURL_BIN.
#
# Мок маршрутизирует по пути (MOCK_CURL_ROUTES) и падает на неизвестном:
# пока он отдавал одно тело на любой URL, перепутанный путь эндпоинта не мог
# уронить ни один assert. Маршруты пишутся с префиксом /v1 — тем самым, который
# обязан прийти из [remote] endpoint.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

# Модуль подключается в script.sh, где эти функции уже есть. Прогресс-бар берём
# НАСТОЯЩИЙ, вырезанный из production: прежняя пустышка `show_progress_bar() { :; }`
# убирала ровно тот побочный эффект (печать в stdout), который и был дефектом —
# remote_upload возвращал идентификатор подстановкой команд и приносил вместе с
# ним весь бар. Мок, снимающий симптом, делает баг непроверяемым по построению.
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
eval "$(sed -n '/^show_progress_bar() {/,/^}/p' "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh")"
log_msg() { echo "[$1] $2"; }

export CURL_BIN="$TESTS_DIR/mocks/curl"
export MOCK_CURL_LOG; MOCK_CURL_LOG="$(mktemp "${TMPDIR:-/tmp}/mock_curl_XXXXXX")"
remote_endpoint="http://mock.invalid/v1"
remote_api_key="test-key"
remote_api_key_command=""
REMOTE_UPLOAD_SIDECAR=""
set_video_codec="libx264"

# Таблица маршрутов: «МЕТОД путь<TAB>код<TAB>тело».
routes() { printf '%s\n' "$@" | sed 's/|/\t/g'; }

suite "remote: разбор плоского JSON"
_j='{"job_id":"abc123","state":"running","progress":42,"reused":false,"note":null}'
assert_eq "строка"       "abc123"  "$(remote_json_field "$_j" job_id)"
assert_eq "строка 2"     "running" "$(remote_json_field "$_j" state)"
assert_eq "число"        "42"      "$(remote_json_field "$_j" progress)"
assert_eq "false"        "false"   "$(remote_json_field "$_j" reused)"
assert_empty "нет поля"            "$(remote_json_field "$_j" missing)"
# Ключ-подстрока не должен матчиться вместо полного имени.
assert_empty "частичный ключ"      "$(remote_json_field "$_j" job)"

# ══════════════════════════════════════════════════════════════
suite "remote: экранирование строк JSON"
# ══════════════════════════════════════════════════════════════
# `${s//\/\\}` разбиралось bash-ом как «удалить подстроку /\», а обратный слэш
# не экранировался вовсе: вход a\b"c/\d давал a\b\"cd — потеря данных плюс
# невалидный JSON. Единственное свободное текстовое поле, которое уезжает на
# службу, — subtitles_style, и `\` там законен (ASS/SSA).
assert_eq "обратный слэш удваивается" 'a\\b\"c/\\d' "$(remote_json_escape 'a\b"c/\d')"
assert_eq "слэш не теряется"          'a/b'         "$(remote_json_escape 'a/b')"
assert_eq "кавычка экранируется"      '\"'          "$(remote_json_escape '"')"
assert_eq "путь Windows"              'C:\\tmp\\a'  "$(remote_json_escape 'C:\tmp\a')"
assert_eq "кириллица не трогается"    'Шрифт'       "$(remote_json_escape 'Шрифт')"
assert_empty "пустое остаётся пустым"               "$(remote_json_escape '')"

# ══════════════════════════════════════════════════════════════
suite "remote: нормализация адреса службы"
# ══════════════════════════════════════════════════════════════
# `${x%/}` снимал ровно ОДИН хвостовой слэш, TrimEnd в PS1 — все, а Trim пробелов
# был только в GUI: один config.ini давал «…/v1//jobs» из CLI и «…/v1/jobs» из GUI.
assert_eq "один хвостовой слэш"  "http://h/v1" "$(remote_normalize_endpoint 'http://h/v1/')"
assert_eq "несколько слэшей"     "http://h/v1" "$(remote_normalize_endpoint 'http://h/v1//')"
assert_eq "пробелы по краям"     "http://h/v1" "$(remote_normalize_endpoint '  http://h/v1  ')"
assert_eq "пробел и слэш вместе" "http://h/v1" "$(remote_normalize_endpoint ' http://h/v1// ')"
assert_eq "чистый адрес не меняется" "http://h/v1" "$(remote_normalize_endpoint 'http://h/v1')"
assert_empty "пустое остаётся пустым" "$(remote_normalize_endpoint '')"

# ══════════════════════════════════════════════════════════════
suite "remote: HTTP-слой"
# ══════════════════════════════════════════════════════════════
: > "$MOCK_CURL_LOG"
export MOCK_CURL_ROUTES; MOCK_CURL_ROUTES="$(routes 'GET /v1/health|200|{"status":"ok"}')"
# Зовём БЕЗ подстановки команд: она выполнила бы функцию в подоболочке, и
# код ответа не пережил бы возврата — ровно та ошибка, которую ловит этот тест.
remote_http GET /health
assert_eq "тело ответа" '{"status":"ok"}' "$REMOTE_HTTP_BODY"
assert_eq "код ответа"  "200"             "$REMOTE_HTTP_CODE"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "адрес собран" "http://mock.invalid/v1/health" "$_log"
# Ключ обязан прийти конфигом на stdin, а НЕ аргументом: argv читает любой
# локальный пользователь через /proc/<pid>/cmdline, а отправка живёт минутами.
assert_contains "ключ ушёл заголовком"  'header = "Authorization: Bearer test-key"' "$_log"
_argv="$(head -1 "$MOCK_CURL_LOG")"
assert_not_contains "ключа нет в argv"  "Bearer test-key" "$_argv"
assert_contains     "конфиг читается со stdin" "--config -" "$_argv"

# Неизвестный путь теперь роняет мок — иначе перепутанный эндпоинт был бы неотличим
# от верного (клиент ходил по /jobs, спека и тест — по /v1/jobs, набор зелёный).
: > "$MOCK_CURL_LOG"
remote_http GET /health/nope
assert_eq "мок падает на неизвестном маршруте" "000" "$REMOTE_HTTP_CODE"

# ══════════════════════════════════════════════════════════════
suite "remote: preflight"
# ══════════════════════════════════════════════════════════════
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":"3","encoders":["h264_nvenc","hevc_nvenc"],"chunk_size":1048576}')"
set_video_codec="libx264"
if remote_preflight >/dev/null 2>&1; then pass "живая служба принята"
else fail "живая служба принята" "код 0" "код 1"; fi
assert_eq "версия сборщика запомнена" "3" "$REMOTE_CAPS_ARGS_VERSION"
assert_eq "размер куска запомнен" "1048576" "$REMOTE_CHUNK_SIZE"

# Энкодер сверяется ЗДЕСЬ, до первого файла: отказать на сотом из двухсот дороже,
# чем на нулевом. Сверка идёт по СЕМЕЙСТВУ (libx264 → h264), потому что служба
# принимает семейство и сама выбирает nvenc или программный энкодер.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":"3","encoders":["hevc_nvenc","av1_nvenc"],"chunk_size":1048576}')"
set_video_codec="libx264"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "кодека нет в capabilities → отказ" "1" "$rc"
assert_contains "названо семейство" "h264" "$out"

set_video_codec="libx265"
if remote_preflight >/dev/null 2>&1; then pass "hevc из libx265 принят по семейству"
else fail "hevc из libx265 принят по семейству" "код 0" "код 1"; fi

# Служба не объявила encoders — отказывать на этом нельзя: молчание службы
# не то же самое, что отсутствие кодека.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":"3","chunk_size":1048576}')"
set_video_codec="libx264"
if remote_preflight >/dev/null 2>&1; then pass "без списка encoders прогон не рвётся"
else fail "без списка encoders прогон не рвётся" "код 0" "код 1"; fi

# Кодек, которого нет в нашей таблице отображения, — тоже отказ до первого файла.
set_video_codec="mpeg4"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "неизвестный кодек отвергается" "1" "$rc"
assert_contains "кодек назван" "mpeg4" "$out"
set_video_codec="libx264"

MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|401|{"error":"нужен Bearer-ключ"}')"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "401 отвергается" "1" "$rc"
assert_contains "причина названа" "401" "$out"

# 404 на /capabilities почти всегда означает адрес без версии API — это обязано
# быть сказано словами, а не остаться кодом ответа.
MOCK_CURL_ROUTES="$(routes 'GET /capabilities|404|{"error":"not found"}')"
remote_endpoint="http://mock.invalid"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "404 отвергается" "1" "$rc"
assert_contains "адрес без версии назван до запроса" "не оканчивается версией API" "$out"
assert_contains "404 объяснён" "/v1" "$out"
remote_endpoint="http://mock.invalid/v1"

MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":"3"}')"
remote_endpoint=""
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "пустой адрес отвергается" "1" "$rc"
assert_contains "названа переменная" "TRANSCODE_URL" "$out"
remote_endpoint="http://mock.invalid/v1"

# ══════════════════════════════════════════════════════════════
suite "remote: ключ из внешнего источника (api_key_command)"
# ══════════════════════════════════════════════════════════════
# config.ini не коммитится, но остаётся в бэкапах и синхронизируемых папках, а
# переменная окружения видна всему дереву процессов. Команда не оставляет ключ
# ни там, ни там; выполняется ОДИН раз, в preflight.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":"3","chunk_size":1048576}')"
: > "$MOCK_CURL_LOG"
remote_api_key=""
remote_api_key_command="printf 'from-vault\n'"
if remote_preflight >/dev/null 2>&1; then pass "ключ получен командой"
else fail "ключ получен командой" "код 0" "код 1"; fi
assert_eq "ключ подставлен" "from-vault" "$remote_api_key"
assert_contains "ключ ушёл в заголовок" "Bearer from-vault" "$(cat "$MOCK_CURL_LOG")"

remote_api_key=""
remote_api_key_command="exit 3"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "провал команды — отказ" "1" "$rc"
assert_contains "причина названа" "api_key_command" "$out"

remote_api_key=""
remote_api_key_command="printf ''"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "пустой вывод команды — отказ" "1" "$rc"
remote_api_key_command=""
remote_api_key="test-key"

# ══════════════════════════════════════════════════════════════
suite "remote: sha256"
# ══════════════════════════════════════════════════════════════
_f="$(mktemp "${TMPDIR:-/tmp}/remote_sha_XXXXXX")"
printf 'abc' > "$_f"
assert_eq "sha256 от abc" \
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
  "$(remote_sha256 "$_f")"
rm -f "$_f"

# ══════════════════════════════════════════════════════════════
suite "remote: загрузка кусками"
# ══════════════════════════════════════════════════════════════
_big="$(mktemp "${TMPDIR:-/tmp}/remote_up_XXXXXX")"
head -c 3000 /dev/zero | tr '\0' 'x' > "$_big"
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'POST /v1/uploads|200|{"upload_id":"up-42","chunk_size":1024}' \
  'PATCH /v1/uploads/up-42|200|{"received":0}' \
  'POST /v1/uploads/up-42/complete|200|{"ok":true,"duration":12}')"
REMOTE_CHUNK_SIZE=1024
REMOTE_UPLOAD_SIDECAR=""
# Через файл, а не через $( ): подстановка команд выполнила бы функцию в
# подоболочке, и REMOTE_UPLOAD_ID до нас бы не дошёл — тот самый механизм,
# из-за которого идентификатор и не имеет права возвращаться через stdout.
_capture="$(mktemp "${TMPDIR:-/tmp}/remote_cap_XXXXXX")"
remote_upload "$_big" > "$_capture"
_stdout="$(cat "$_capture")"
assert_eq "идентификатор загрузки" "up-42" "$REMOTE_UPLOAD_ID"
# Идентификатор возвращается ПЕРЕМЕННОЙ. На stdout уходит прогресс-бар, и
# `uid="$(remote_upload …)"` унёс бы его в тело POST /jobs — служба обязана была
# бы ответить 400 на каждом файле.
assert_contains "на stdout — прогресс-бар, а не идентификатор" "100%" "$_stdout"
assert_eq "длительность из complete запомнена" "12" "$REMOTE_UPLOAD_DURATION"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "первый кусок"  "Content-Range: bytes 0-1023/3000"    "$_log"
assert_contains "второй кусок"  "Content-Range: bytes 1024-2047/3000" "$_log"
assert_contains "третий кусок"  "Content-Range: bytes 2048-2999/3000" "$_log"
assert_contains "завершение"    "/v1/uploads/up-42/complete"          "$_log"
assert_contains "хеш отправлен" "sha256"                              "$_log"

# ══════════════════════════════════════════════════════════════
suite "remote: докачка с НЕвыровненного смещения"
# ══════════════════════════════════════════════════════════════
# Смещение приходит из ответа службы (received), а кратности размеру куска она
# не обещает. Прежний `dd skip=$((offset/bs)) bs=$bs` при received=1500 и
# chunk=1024 объявлял Content-Range 1500-2523, а читал байты с 1024: собранный
# на сервере файл — мусор, sha256 в complete не сходился. Позиционная разметка
# ниже показывает, КАКИЕ байты уехали, а не только что уехали какие-то.
_marked="$(mktemp "${TMPDIR:-/tmp}/remote_mark_XXXXXX")"
: > "$_marked"
for _i in 0 1 2 3 4 5; do
    printf 'BLOCK%d' "$_i" >> "$_marked"
    head -c 494 /dev/zero | tr '\0' "$_i" >> "$_marked"
done                                  # 6 блоков по 500 байт = 3000
_sidecar="$(mktemp "${TMPDIR:-/tmp}/remote_sc_XXXXXX")"
{
    echo "upload_id=up-43"
    echo "size=3000"
    echo "endpoint=$remote_endpoint"
} > "$_sidecar"
REMOTE_UPLOAD_SIDECAR="$_sidecar"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_LOG_DATA=1
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/uploads/up-43|200|{"upload_id":"up-43","received":1500}' \
  'PATCH /v1/uploads/up-43|200|{"received":3000}' \
  'POST /v1/uploads/up-43/complete|200|{"ok":true}')"
REMOTE_CHUNK_SIZE=1024
remote_upload "$_marked" >/dev/null
_log="$(cat "$MOCK_CURL_LOG")"
assert_eq "идентификатор из sidecar переиспользован" "up-43" "$REMOTE_UPLOAD_ID"
assert_not_contains "принятое не перезаливается" "bytes 0-" "$_log"
assert_contains "докачка объявлена с 1500" "Content-Range: bytes 1500-2523/3000" "$_log"
# Байт 1500 — начало четвёртого блока: маркер BLOCK3. Прежний код прислал бы
# сюда содержимое со смещения 1024, то есть хвост блока BLOCK2.
assert_contains "отправлены байты ИМЕННО с 1500" "DATA: BLOCK3" "$_log"
assert_not_contains "не отправлен блок со смещения 1024" "DATA: 22222" "$_log"
unset MOCK_CURL_LOG_DATA
REMOTE_UPLOAD_SIDECAR=""
rm -f "$_marked" "$_sidecar"

# sidecar с чужим размером не должен воскрешать чужую загрузку
_sidecar="$(mktemp "${TMPDIR:-/tmp}/remote_sc_XXXXXX")"
{ echo "upload_id=up-99"; echo "size=1"; echo "endpoint=$remote_endpoint"; } > "$_sidecar"
REMOTE_UPLOAD_SIDECAR="$_sidecar"
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'POST /v1/uploads|200|{"upload_id":"up-44","chunk_size":4096}' \
  'PATCH /v1/uploads/up-44|200|{"received":3000}' \
  'POST /v1/uploads/up-44/complete|200|{"ok":true}')"
remote_upload "$_big" >/dev/null
assert_eq "устаревший sidecar игнорируется" "up-44" "$REMOTE_UPLOAD_ID"
if [ ! -f "$_sidecar" ]; then pass "успешная загрузка убирает sidecar"; else fail "успешная загрузка убирает sidecar" "файла нет" "файл на месте"; fi
REMOTE_UPLOAD_SIDECAR=""
rm -f "$_sidecar"

# ══════════════════════════════════════════════════════════════
suite "remote: повтор отправки куска"
# ══════════════════════════════════════════════════════════════
# Обрыв на 90-м проценте трёхгигабайтного файла не должен стоить всего файла.
# Повторяем то, что может пройти со второй попытки (5xx, 429, обрыв), и НЕ
# повторяем отказ по существу: 413 не станет верным с третьей попытки.
_flag="$(mktemp "${TMPDIR:-/tmp}/remote_flag_XXXXXX")"; rm -f "$_flag"
REMOTE_RETRY_SECONDS=0
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'POST /v1/uploads|200|{"upload_id":"up-50","chunk_size":4096}' \
  'PATCH /v1/uploads/up-50|503|{"error":"перегрузка"}')"
if remote_upload "$_big" >/dev/null 2>&1; then
    fail "503 после трёх попыток — отказ" "код 1" "код 0"
else
    pass "503 после трёх попыток — отказ"
fi
assert_eq "куск отправлен ровно 3 раза" "3" "$(grep -c 'Content-Range: bytes 0-' "$MOCK_CURL_LOG")"

: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'POST /v1/uploads|200|{"upload_id":"up-51","chunk_size":4096}' \
  'PATCH /v1/uploads/up-51|413|{"error":"объявлено больше предела"}')"
if remote_upload "$_big" >/dev/null 2>&1; then
    fail "413 отвергается" "код 1" "код 0"
else
    pass "413 отвергается"
fi
assert_eq "413 не повторяется" "1" "$(grep -c 'Content-Range: bytes 0-' "$MOCK_CURL_LOG")"
unset REMOTE_RETRY_SECONDS
rm -f "$_big" "$_flag"

# ══════════════════════════════════════════════════════════════
suite "remote: создание задачи"
# ══════════════════════════════════════════════════════════════
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes 'POST /v1/jobs|200|{"job_id":"job-7","state":"queued","reused":false}')"
remote_prefer="auto"; remote_wait_timeout="1800"; overwrite_existing="no"
remote_submit up-42 transcode '{"codec":"h264"}' > "$_capture"
_stdout="$(cat "$_capture")"
assert_eq "идентификатор задачи" "job-7" "$REMOTE_JOB_ID"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "операция"     '"op":"transcode"'   "$_log"
assert_contains "загрузка"     '"upload_id":"up-42"' "$_log"
assert_contains "предпочтение" '"prefer":"auto"'    "$_log"
assert_contains "таймаут"      '"wait_timeout":1800' "$_log"
assert_not_contains "без overwrite нет no_reuse" '"no_reuse":true' "$_log"

# Дедупликация печатает строку лога — и она не имеет права оказаться внутри
# идентификатора задачи. Идентификатор возвращается переменной именно поэтому.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes 'POST /v1/jobs|200|{"job_id":"job-8","state":"done","reused":true}')"
remote_submit up-42 transcode '{"codec":"h264"}' > "$_capture"
_stdout="$(cat "$_capture")"
assert_eq "идентификатор чист при reused" "job-8" "$REMOTE_JOB_ID"
assert_contains "о дедупликации сказано" "дедупликация" "$_stdout"

: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes 'POST /v1/jobs|200|{"job_id":"job-7"}')"
overwrite_existing="yes"
remote_submit up-42 transcode '{"codec":"h264"}' >/dev/null
assert_contains "overwrite → no_reuse" '"no_reuse":true' "$(cat "$MOCK_CURL_LOG")"
overwrite_existing="no"

suite "remote: субтитры уезжают отдельной загрузкой"
: > "$MOCK_CURL_LOG"
remote_submit up-42 transcode '{"codec":"h264"}' up-sub >/dev/null
assert_contains "subtitle_upload_id" '"subtitle_upload_id":"up-sub"' "$(cat "$MOCK_CURL_LOG")"

suite "remote: холостой прогон"
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes 'POST /v1/jobs|200|{"dry_run":true,"segmented":false,"outputs_expected":1,"argv":["ffmpeg","-i","x"]}')"
out="$(remote_dry_run up-42 transcode '{"codec":"h264"}')"
assert_contains "план напечатан" "ffmpeg" "$out"
assert_contains "флаг отправлен" '"dry_run":true' "$(cat "$MOCK_CURL_LOG")"

# ══════════════════════════════════════════════════════════════
suite "remote: ожидание задачи"
# ══════════════════════════════════════════════════════════════
export REMOTE_POLL_SECONDS=0
MOCK_CURL_ROUTES="$(routes 'GET /v1/jobs/job-7|200|{"job_id":"job-7","state":"done","progress":100}')"
if remote_wait job-7 "файл" >/dev/null 2>&1; then pass "done даёт успех"
else fail "done даёт успех" "код 0" "код 1"; fi

MOCK_CURL_ROUTES="$(routes 'GET /v1/jobs/job-7|200|{"job_id":"job-7","state":"failed","error":"код возврата 1"}')"
out="$(remote_wait job-7 "файл" 2>&1)"; rc=$?
assert_eq "failed даёт отказ" "1" "$rc"
assert_contains "причина показана" "код возврата 1" "$out"

# Одна итерация: ограничиваем число опросов, иначе waiting_gpu крутился бы вечно.
MOCK_CURL_ROUTES="$(routes 'GET /v1/jobs/job-7|200|{"state":"waiting_gpu","waiting_seconds":42,"missing_mib":512}')"
out="$( (REMOTE_WAIT_MAX_POLLS=1 remote_wait job-7 "файл" 2>&1) )" || true
assert_contains "ожидание объяснено" "42" "$out"
assert_contains "нехватка памяти названа" "512" "$out"

# Клиентский предел ожидания. Без него застрявшая в running задача держала бы
# прогон вечно: remote_wait_timeout уезжает в тело задачи и трактуется СЛУЖБОЙ.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-9|200|{"state":"running","progress":10}' \
  'DELETE /v1/jobs/job-9|200|{"ok":true}')"
remote_wait_timeout=1
out="$( (REMOTE_WAIT_FACTOR=1 REMOTE_POLL_SECONDS=1 remote_wait job-9 "файл" 2>&1) )"; rc=$?
assert_eq "застрявшая задача не ждётся вечно" "1" "$rc"
assert_contains "названа причина" "не завершилась за" "$out"
assert_contains "задача отменена на сервере" "DELETE" "$(cat "$MOCK_CURL_LOG")"
remote_wait_timeout=1800
assert_eq "предел считается от wait_timeout" "5400" "$(remote_wait_deadline_seconds)"

suite "remote: скачивание результата"
_dst="$(mktemp "${TMPDIR:-/tmp}/remote_dl_XXXXXX")"; rm -f "$_dst"
MOCK_CURL_ROUTES="$(routes 'GET /v1/jobs/job-7/result|200|RESULT-BYTES')"
if remote_fetch job-7 "$_dst" >/dev/null; then pass "скачивание успешно"
else fail "скачивание успешно" "код 0" "код 1"; fi
assert_file_exists "файл создан" "$_dst"
assert_eq "содержимое" "RESULT-BYTES" "$(cat "$_dst")"
_out="$(remote_fetch job-7 "$_dst" "клип")"
assert_contains "фаза названа" "скачивание" "$_out"
rm -f "$_dst"

suite "remote: отмена освобождает карту"
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes 'DELETE /v1/jobs/job-7|200|{"ok":true}')"
remote_cancel job-7
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "метод DELETE" "DELETE" "$_log"
assert_contains "адрес задачи" "/v1/jobs/job-7" "$_log"

rm -f "$MOCK_CURL_LOG" "$_capture"
summary
