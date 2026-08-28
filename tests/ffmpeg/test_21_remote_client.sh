#!/bin/bash
# ============================================================
# test_21_remote_client.sh — HTTP-слой клиента службы.
# Сети нет: curl подменяется моком через CURL_BIN.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

# Модуль подключается в script.sh, где эти функции уже есть. В автономном
# тесте подставляем их сами — проверяем клиент, а не прогресс-бар.
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
show_progress_bar() { :; }
log_msg() { :; }

export CURL_BIN="$TESTS_DIR/mocks/curl"
export MOCK_CURL_LOG; MOCK_CURL_LOG="$(mktemp "${TMPDIR:-/tmp}/mock_curl_XXXXXX")"
remote_endpoint="http://mock.invalid/v1"
remote_api_key="test-key"

suite "remote: разбор плоского JSON"
_j='{"job_id":"abc123","state":"running","progress":42,"reused":false,"note":null}'
assert_eq "строка"       "abc123"  "$(remote_json_field "$_j" job_id)"
assert_eq "строка 2"     "running" "$(remote_json_field "$_j" state)"
assert_eq "число"        "42"      "$(remote_json_field "$_j" progress)"
assert_eq "false"        "false"   "$(remote_json_field "$_j" reused)"
assert_empty "нет поля"            "$(remote_json_field "$_j" missing)"
# Ключ-подстрока не должен матчиться вместо полного имени.
assert_empty "частичный ключ"      "$(remote_json_field "$_j" job)"

suite "remote: HTTP-слой"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_BODY='{"status":"ok"}'
export MOCK_CURL_CODE=200
# Зовём БЕЗ подстановки команд: она выполнила бы функцию в подоболочке, и
# код ответа не пережил бы возврата — ровно та ошибка, которую ловит этот тест.
remote_http GET /health
assert_eq "тело ответа" '{"status":"ok"}' "$REMOTE_HTTP_BODY"
assert_eq "код ответа"  "200"             "$REMOTE_HTTP_CODE"
assert_contains "ключ в заголовке" "Authorization: Bearer test-key" "$(cat "$MOCK_CURL_LOG")"
assert_contains "адрес собран"     "http://mock.invalid/v1/health"  "$(cat "$MOCK_CURL_LOG")"

suite "remote: preflight"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"args_version":"3","encoders":["h264_nvenc","hevc_nvenc"],"chunk_size":1048576}'
set_video_codec="libx264"
if remote_preflight >/dev/null 2>&1; then pass "живая служба принята"
else fail "живая служба принята" "код 0" "код 1"; fi
assert_eq "версия сборщика запомнена" "3" "$REMOTE_CAPS_ARGS_VERSION"
assert_eq "размер куска запомнен" "1048576" "$REMOTE_CHUNK_SIZE"

export MOCK_CURL_CODE=401
export MOCK_CURL_BODY='{"error":"нужен Bearer-ключ"}'
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "401 отвергается" "1" "$rc"
assert_contains "причина названа" "401" "$out"

export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"args_version":"3","encoders":["hevc_nvenc"],"chunk_size":1048576}'
remote_endpoint=""
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "пустой адрес отвергается" "1" "$rc"
assert_contains "названа переменная" "TRANSCODE_URL" "$out"
remote_endpoint="http://mock.invalid/v1"

suite "remote: sha256"
_f="$(mktemp "${TMPDIR:-/tmp}/remote_sha_XXXXXX")"
printf 'abc' > "$_f"
assert_eq "sha256 от abc" \
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
  "$(remote_sha256 "$_f")"
rm -f "$_f"

suite "remote: загрузка кусками"
_big="$(mktemp "${TMPDIR:-/tmp}/remote_up_XXXXXX")"
head -c 3000 /dev/zero | tr '\0' 'x' > "$_big"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"upload_id":"up-42","chunk_size":1024,"received":0}'
REMOTE_CHUNK_SIZE=1024
uid="$(remote_upload "$_big")"
assert_eq "идентификатор загрузки" "up-42" "$uid"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "создание загрузки" "/v1/uploads" "$_log"
assert_contains "первый кусок"  "Content-Range: bytes 0-1023/3000"    "$_log"
assert_contains "второй кусок"  "Content-Range: bytes 1024-2047/3000" "$_log"
assert_contains "третий кусок"  "Content-Range: bytes 2048-2999/3000" "$_log"
assert_contains "завершение"    "/v1/uploads/up-42/complete"          "$_log"
assert_contains "хеш отправлен" "sha256"                              "$_log"

suite "remote: докачка с известного смещения"
: > "$MOCK_CURL_LOG"
# Служба сообщает, что 2048 байт уже приняты — заново их лить нельзя.
export MOCK_CURL_BODY='{"upload_id":"up-43","received":2048}'
uid="$(remote_upload "$_big")"
_log="$(cat "$MOCK_CURL_LOG")"
assert_not_contains "принятое не перезаливается" "bytes 0-1023/3000" "$_log"
assert_contains "докачка с 2048" "Content-Range: bytes 2048-2999/3000" "$_log"

suite "remote: отказ загрузки виден"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=413
export MOCK_CURL_BODY='{"error":"объявлено больше предела"}'
if remote_upload "$_big" >/dev/null 2>&1; then
    fail "413 отвергается" "код 1" "код 0"
else
    pass "413 отвергается"
fi
export MOCK_CURL_CODE=200
rm -f "$_big"

suite "remote: создание задачи"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"job_id":"job-7","state":"queued","reused":false}'
remote_prefer="auto"; remote_wait_timeout="1800"; overwrite_existing="no"
jid="$(remote_submit up-42 transcode '{"codec":"h264"}')"
assert_eq "идентификатор задачи" "job-7" "$jid"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "операция"     '"op":"transcode"'   "$_log"
assert_contains "загрузка"     '"upload_id":"up-42"' "$_log"
assert_contains "предпочтение" '"prefer":"auto"'    "$_log"
assert_contains "таймаут"      '"wait_timeout":1800' "$_log"
assert_not_contains "без overwrite нет no_reuse" '"no_reuse":true' "$_log"

: > "$MOCK_CURL_LOG"
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
export MOCK_CURL_BODY='{"dry_run":true,"segmented":false,"outputs_expected":1,"argv":["ffmpeg","-i","x"]}'
out="$(remote_dry_run up-42 transcode '{"codec":"h264"}')"
assert_contains "план напечатан" "ffmpeg" "$out"
assert_contains "флаг отправлен" '"dry_run":true' "$(cat "$MOCK_CURL_LOG")"

suite "remote: ожидание задачи"
export REMOTE_POLL_SECONDS=0
export MOCK_CURL_BODY='{"job_id":"job-7","state":"done","progress":100}'
if remote_wait job-7 "файл" >/dev/null 2>&1; then pass "done даёт успех"
else fail "done даёт успех" "код 0" "код 1"; fi

export MOCK_CURL_BODY='{"job_id":"job-7","state":"failed","error":"код возврата 1"}'
out="$(remote_wait job-7 "файл" 2>&1)"; rc=$?
assert_eq "failed даёт отказ" "1" "$rc"
assert_contains "причина показана" "код возврата 1" "$out"

# Одна итерация: ограничиваем число опросов, иначе waiting_gpu крутился бы вечно.
out="$( (export MOCK_CURL_BODY='{"state":"waiting_gpu","waiting_seconds":42,"missing_mib":512}'
         REMOTE_WAIT_MAX_POLLS=1 remote_wait job-7 "файл" 2>&1) )" || true
assert_contains "ожидание объяснено" "42" "$out"
assert_contains "нехватка памяти названа" "512" "$out"

suite "remote: скачивание результата"
_dst="$(mktemp "${TMPDIR:-/tmp}/remote_dl_XXXXXX")"; rm -f "$_dst"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='RESULT-BYTES'
if remote_fetch job-7 "$_dst"; then pass "скачивание успешно"
else fail "скачивание успешно" "код 0" "код 1"; fi
assert_file_exists "файл создан" "$_dst"
assert_eq "содержимое" "RESULT-BYTES" "$(cat "$_dst")"
rm -f "$_dst"

suite "remote: отмена освобождает карту"
: > "$MOCK_CURL_LOG"
remote_cancel job-7
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "метод DELETE" "DELETE" "$_log"
assert_contains "адрес задачи" "/v1/jobs/job-7" "$_log"

rm -f "$MOCK_CURL_LOG"
summary
