#!/bin/bash
# ============================================================
# test_21_remote_client.sh — HTTP-слой клиента службы.
# Сети нет: curl подменяется моком через CURL_BIN.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

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

rm -f "$MOCK_CURL_LOG"
summary
