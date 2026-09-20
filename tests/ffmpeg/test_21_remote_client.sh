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
suite "remote: экранирование под старым bash (3.2)"
# ══════════════════════════════════════════════════════════════
# macOS-раннер запускает набор системным /bin/bash 3.2.57, и там подстановка
# `s="${s//"$bs"/"$bs$bs"}"` работает ИНАЧЕ: до bash 4.3 строка замены внутри
# подстановки, взятой в двойные кавычки, не проходит снятие кавычек — обе `"` из
# `"$bs$bs"` уезжают в результат буквально. Вход a\b"c/\d давал
# a\"\\"b\"c/\"\\"d: невалидный JSON и битый Authorization-заголовок, при этом на
# Linux и в Git Bash (bash 5) всё зелено. Разница воспроизводится без macOS —
# `shopt -s compat42` включает ровно ту семантику, поэтому обе функции гоняем
# дочерним bash-ем в этом режиме. Проверяем и remote_curl_auth: там тот же идиом,
# но ключ с обратным слэшем не ронял бы тест — только молча ломал авторизацию.
_old_bash() {
	"$BASH" -c '
		shopt -s compat42 2>/dev/null || { printf "NOCOMPAT"; exit 0; }
		remote_api_key='"'"'k\ey"x'"'"'
		source "$1"
		printf "%s|%s" "$(remote_json_escape '"'"'a\b"c/\d'"'"')" "$(remote_curl_auth)"
	' _ "$PROJECT_DIR/ffmpeg/remote_client.sh"
}
_ob="$(_old_bash)"
if [ "$_ob" = "NOCOMPAT" ]; then
	skip "bash без compat42 — старую семантику не воспроизвести"
else
	assert_eq "JSON: то же, что на bash 5" \
		'a\\b\"c/\\d|header = "Authorization: Bearer k\\ey\"x"' "$_ob"
fi

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

# ══════════════════════════════════════════════════════════════
suite "remote: контракт службы args_version 2"
# ══════════════════════════════════════════════════════════════
# Класс «клиент разошёлся с живой службой» до 2026-09-05 не проверялся ничем:
# мок отдавал форму v1, спека описывала v1, и первый же настоящий запрос к
# службе показал, что удалённый счёт не работает вовсе. Ниже — ровно те формы
# ответа, которые служба отдаёт на самом деле.

# encoders приходит ОБЪЕКТОМ по месту счёта, а не плоским списком.
CAPS_V2='{"args_version":2,"encoders":{"gpu":["h264_nvenc","hevc_nvenc","av1_nvenc"],"cpu":["libx264","libx265","libsvtav1"]},"limits":{"chunk_size":1048576,"wait_timeout_max_s":3600},"ops":{"transcode":{"sample":{},"values":{"container":["avi","mkv","mp4","ts","webm"]}}}}'
MOCK_CURL_ROUTES="$(routes "GET /v1/capabilities|200|$CAPS_V2")"
set_video_codec="libx264"; remote_wait_timeout=1800
output_container_status="-"; output_container_value="mp4"
if remote_preflight >/dev/null 2>&1; then pass "encoders объектом {gpu,cpu} — служба принята"
else fail "encoders объектом {gpu,cpu} — служба принята" "код 0" "код 1"; fi
assert_eq "версия сборщика прочитана" "2" "$REMOTE_CAPS_ARGS_VERSION"
assert_eq "chunk_size взят из limits" "1048576" "$REMOTE_CHUNK_SIZE"
assert_contains "энкодеры разобраны из обеих групп" "h264_nvenc" "$REMOTE_CAPS_ENCODERS"
assert_contains "программные энкодеры тоже" "libsvtav1" "$REMOTE_CAPS_ENCODERS"
# Имена групп — не энкодеры и в перечень попадать не должны: иначе они уедут
# в сообщение об ошибке и будут выглядеть как объявленные кодеки.
assert_not_contains "имя группы gpu не попало в список" '"gpu"' "$REMOTE_CAPS_ENCODERS"

# Сверка семейства работает и на объектной форме.
set_video_codec="libsvtav1"
if remote_preflight >/dev/null 2>&1; then pass "av1 найден в группе gpu"
else fail "av1 найден в группе gpu" "код 0" "код 1"; fi

# Пустые группы — это «служба не умеет ничего», и отказ обязан быть.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":2,"encoders":{"gpu":[],"cpu":[]},"limits":{"chunk_size":1048576}}')"
set_video_codec="libx264"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "пустые группы энкодеров → отказ" "1" "$rc"
assert_contains "сказано, что считать нечем" "пустой список" "$out"

# ── Потолок ожидания карты ────────────────────────────────────────────────
# Служба объявляет его в limits и отвергает превышение 400-м на POST /jobs —
# то есть уже ПОСЛЕ отправки файла целиком. Спрашиваем до загрузки.
MOCK_CURL_ROUTES="$(routes "GET /v1/capabilities|200|$CAPS_V2")"
set_video_codec="libx264"; remote_wait_timeout=7200
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "wait_timeout выше потолка → отказ до загрузки" "1" "$rc"
assert_contains "назван потолок службы" "3600" "$out"
remote_wait_timeout=3600
if remote_preflight >/dev/null 2>&1; then pass "wait_timeout ровно по потолку принят"
else fail "wait_timeout ровно по потолку принят" "код 0" "код 1"; fi
remote_wait_timeout=1800

# ── Контейнер выхода ──────────────────────────────────────────────────────
output_container_status="+"; output_container_value="mov"
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "контейнер вне списка службы → отказ до загрузки" "1" "$rc"
assert_contains "контейнер назван" "mov" "$out"
output_container_status="+"; output_container_value="mkv"
if remote_preflight >/dev/null 2>&1; then pass "объявленный контейнер принят"
else fail "объявленный контейнер принят" "код 0" "код 1"; fi
# Список не разобран — молчание службы не повод отказывать.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":2,"encoders":{"gpu":["h264_nvenc"]}}')"
output_container_status="+"; output_container_value="mov"
if remote_preflight >/dev/null 2>&1; then pass "без списка контейнеров прогон не рвётся"
else fail "без списка контейнеров прогон не рвётся" "код 0" "код 1"; fi
output_container_status="-"; output_container_value="mp4"

# ── Плоская форма encoders обязана продолжать работать ────────────────────
# Совместимость в обе стороны: за обратным прокси может стоять служба прежней
# версии, и «починили новую, сломали старую» — та же авария зеркально.
MOCK_CURL_ROUTES="$(routes 'GET /v1/capabilities|200|{"args_version":2,"encoders":["h264_nvenc","libx264"],"chunk_size":2097152}')"
set_video_codec="libx264"
if remote_preflight >/dev/null 2>&1; then pass "плоский список encoders по-прежнему принят"
else fail "плоский список encoders по-прежнему принят" "код 0" "код 1"; fi
assert_eq "chunk_size с верхнего уровня тоже читается" "2097152" "$REMOTE_CHUNK_SIZE"

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
# Sidecar ПЕРЕЖИВАЕТ успешную загрузку и получает пометку complete=yes. Раньше он
# здесь удалялся, и записывать в него job_id было уже некуда: функция записи молча
# выходила по отсутствию файла, поэтому возобновление задачи не работало НИ РАЗУ.
if [ -f "$_sidecar" ]; then pass "успешная загрузка оставляет sidecar"; else fail "успешная загрузка оставляет sidecar" "файл на месте" "файла нет"; fi
assert_contains "загрузка помечена завершённой" "complete=yes" "$(cat "$_sidecar" 2>/dev/null)"
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
# Поле обязано лежать на ВЕРХНЕМ уровне params, а не внутри объекта audio. Проверяем
# на реальной форме params: remote_op_for_config всегда заканчивает её объектом
# "audio":{…}, и ревью читало `${p%\}}` как срез закрывающей скобки ЭТОГО объекта.
# Срезается последняя скобка — своя у params, — поэтому поле встаёт рядом с audio;
# тест закрепляет это структурно, а не по вхождению подстроки.
assert_eq "поле на верхнем уровне, а не внутри audio" \
	'{"upload_id":"up-42","op":"transcode","params":{"codec":"h264","audio":{"codec":"copy"},"subtitle_upload_id":"up-sub"},"prefer":"auto","wait_timeout":1800}' \
	"$(remote_job_body up-42 transcode '{"codec":"h264","audio":{"codec":"copy"}}' up-sub)"

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

# Клиентский предел ожидания по ЗАСТРЕВАНИЮ. Прежний «3 × wait_timeout на всю
# задачу» выводил предел из параметра с другим смыслом (wait_timeout — сколько
# СЛУЖБА ждёт окна на карте): часовой 4K-файл отменялся при живом прогрессе, а
# prefer = cpu на длинном файле — через 90 минут серверной работы. Теперь таймер
# сбрасывается на каждое изменение state/progress.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-9|200|{"state":"running","progress":10}' \
  'DELETE /v1/jobs/job-9|200|{"ok":true}')"
remote_stall_timeout=1
out="$( (REMOTE_POLL_SECONDS=1 remote_wait job-9 "файл" 2>&1) )"; rc=$?
assert_eq "застрявшая задача не ждётся вечно" "1" "$rc"
assert_contains "названа причина" "не подаёт признаков движения" "$out"
assert_contains "задача отменена на сервере" "DELETE" "$(cat "$MOCK_CURL_LOG")"
remote_stall_timeout=900
assert_eq "предел берётся из stall_timeout" "900" "$(remote_stall_seconds)"
remote_stall_timeout=""
assert_eq "пустой stall_timeout → умолчание 900" "900" "$(remote_stall_seconds)"
remote_stall_timeout=900

# Живой прогресс НЕ считается застреванием: задача, идущая с 10 % до 11 %, обязана
# продолжаться. Ограничиваем число опросов, иначе цикл был бы бесконечным.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-10|200|{"state":"running","progress":10}' \
  'DELETE /v1/jobs/job-10|200|{"ok":true}')"
remote_stall_timeout=1
out="$( (REMOTE_WAIT_MAX_POLLS=1 REMOTE_POLL_SECONDS=1 remote_wait job-10 "файл" 2>&1) )" || true
assert_not_contains "первый опрос не объявляет застревание" "не подаёт признаков движения" "$out"
remote_stall_timeout=900

# Один сбойный опрос не стоит файла: 502 при рестарте службы (или 429, или обрыв)
# считался фатальным — файл падал, а служба продолжала считать результат, который
# никто не заберёт. Повторяем, и только после N подряд отменяем задачу.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-11|502|{"error":"bad gateway"}' \
  'DELETE /v1/jobs/job-11|200|{"ok":true}')"
out="$( (REMOTE_POLL_MAX_FAILS=2 REMOTE_POLL_SECONDS=1 remote_wait job-11 "файл" 2>&1) )"; rc=$?
assert_eq "серия сбойных опросов заканчивается отказом" "1" "$rc"
assert_contains "сбой опроса не молчит" "Опрос задачи не удался" "$out"
assert_contains "после серии сбоев задача отменена" "DELETE" "$(cat "$MOCK_CURL_LOG")"

# Неповторяемый код (400) отменяет задачу сразу, без серии попыток.
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-12|400|{"error":"нет такой задачи"}' \
  'DELETE /v1/jobs/job-12|200|{"ok":true}')"
out="$( (REMOTE_POLL_SECONDS=1 remote_wait job-12 "файл" 2>&1) )"; rc=$?
assert_eq "неповторяемый код — сразу отказ" "1" "$rc"
assert_not_contains "400 не повторяется" "Опрос задачи не удался" "$out"

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

# ══════════════════════════════════════════════════════════════
suite "remote: возобновление задачи из sidecar"
# ══════════════════════════════════════════════════════════════
# Обещание «после падения клиента на ожидании или скачивании следующий запуск идёт
# сразу в GET /jobs/{id} вместо повторной отправки гигабайт» было недостижимо:
# sidecar удалялся сразу после complete, а запись job_id молча выходила по
# отсутствию файла. Ключ несёт номер части и подпись настроек — иначе часть 2
# читала бы задачу части 1, а смена config.ini публиковала бы результат от прежних
# настроек.
_rsrc="$(mktemp "${TMPDIR:-/tmp}/remote_rs_XXXXXX")"
printf 'source-bytes' > "$_rsrc"
_sidecar="$(mktemp "${TMPDIR:-/tmp}/remote_sc_XXXXXX")"
REMOTE_UPLOAD_SIDECAR="$_sidecar"
{
	echo "upload_id=up-70"
	echo "size=$(file_size "$_rsrc")"
	echo "mtime=$(remote_file_mtime "$_rsrc")"
	echo "endpoint=$remote_endpoint"
	echo "sig=SIG-A"
	echo "job.1=job-71"
	echo "job.2=job-72"
} > "$_sidecar"
assert_eq "часть 1 читает свою задачу" "job-71" "$(remote_upload_sidecar_read_job "$_rsrc" 1 SIG-A)"
assert_eq "часть 2 читает свою задачу" "job-72" "$(remote_upload_sidecar_read_job "$_rsrc" 2 SIG-A)"
assert_empty "части без записи — пусто"           "$(remote_upload_sidecar_read_job "$_rsrc" 3 SIG-A)"
assert_empty "другая подпись настроек — пусто"    "$(remote_upload_sidecar_read_job "$_rsrc" 1 SIG-B)"
# Отпечаток источника: подмена файла той же длины обязана отменить возобновление.
_other="$(mktemp "${TMPDIR:-/tmp}/remote_rs2_XXXXXX")"
printf 'other-bytesX' > "$_other"
assert_empty "другой источник — пусто" "$(remote_upload_sidecar_read_job "$_other" 1 SIG-A)"
rm -f "$_other"

# Смена настроек: прежние задачи обязаны исчезнуть вместе с подписью, иначе sidecar
# навсегда остался бы с чужой подписью и возобновление молча не работало бы.
remote_upload_sidecar_write_job "$_rsrc" 1 SIG-B job-80
assert_eq "новая задача под новой подписью" "job-80" "$(remote_upload_sidecar_read_job "$_rsrc" 1 SIG-B)"
assert_empty "задача прежней подписи удалена" "$(remote_upload_sidecar_read_job "$_rsrc" 2 SIG-B)"
assert_not_contains "прежний job.2 вычищен" "job-72" "$(cat "$_sidecar")"
assert_contains "upload_id пережил перезапись" "up-70" "$(cat "$_sidecar")"

# Файла может не быть (ручная чистка, обрыв между complete и созданием задачи) —
# запись обязана его создать. Прежняя версия здесь молча выходила, и именно поэтому
# идентификатор задачи не попадал в sidecar НИ РАЗУ.
rm -f "$_sidecar"
remote_upload_sidecar_write_job "$_rsrc" 1 SIG-C job-90
assert_file_exists "sidecar создан при записи задачи" "$_sidecar"
assert_eq "задача читается из созданного sidecar" "job-90" "$(remote_upload_sidecar_read_job "$_rsrc" 1 SIG-C)"

# Годность задачи проверяется ОДНИМ запросом: мёртвую нельзя отдавать в remote_wait —
# тот получит 404 и отменит ФАЙЛ, то есть возобновление обойдётся дороже загрузки.
MOCK_CURL_ROUTES="$(routes \
  'GET /v1/jobs/job-live|200|{"job_id":"job-live","state":"running","progress":40}' \
  'GET /v1/jobs/job-dead|404|{"error":"нет такой задачи"}' \
  'GET /v1/jobs/job-bad|200|{"job_id":"job-bad","state":"failed","error":"упало"}')"
if remote_job_usable job-live; then pass "живая задача годна"; else fail "живая задача годна" "код 0" "код 1"; fi
if remote_job_usable job-dead; then fail "исчезнувшая задача негодна" "код 1" "код 0"; else pass "исчезнувшая задача негодна"; fi
if remote_job_usable job-bad;  then fail "провалившаяся задача негодна" "код 1" "код 0"; else pass "провалившаяся задача негодна"; fi
if remote_job_usable ""; then fail "пустой идентификатор негоден" "код 1" "код 0"; else pass "пустой идентификатор негоден"; fi

# Подтверждённая загрузка не отправляется заново и НЕ подтверждается повторно:
# ответ на второй complete контрактом не описан, а 409 здесь стоил бы перезалива.
{
	echo "upload_id=up-70"
	echo "size=$(file_size "$_rsrc")"
	echo "mtime=$(remote_file_mtime "$_rsrc")"
	echo "endpoint=$remote_endpoint"
	echo "complete=yes"
} > "$_sidecar"
: > "$MOCK_CURL_LOG"
MOCK_CURL_ROUTES="$(routes \
  "GET /v1/uploads/up-70|200|{\"upload_id\":\"up-70\",\"received\":$(file_size "$_rsrc")}" \
  'GET /v1/uploads/up-70/probe|200|{"duration":42}')"
remote_upload "$_rsrc" >/dev/null
_log="$(cat "$MOCK_CURL_LOG")"
assert_eq "идентификатор взят из sidecar" "up-70" "$REMOTE_UPLOAD_ID"
assert_not_contains "байты заново не отправляются" "PATCH" "$_log"
assert_not_contains "повторного complete нет"      "/complete" "$_log"
assert_eq "длительность взята у probe" "42" "$REMOTE_UPLOAD_DURATION"
REMOTE_UPLOAD_SIDECAR=""
rm -f "$_sidecar" "$_rsrc"

# ══════════════════════════════════════════════════════════════
suite "remote: валидация числовых значений config.ini"
# ══════════════════════════════════════════════════════════════
# Всё, что уезжает в JSON без кавычек, обязано быть проверено ДО загрузки гигабайт:
# «23 кбит» в quality давало тело {"quality":23 кбит}, и узнавалось это после полной
# отправки файла. Проверялся здесь только bitrate.
_saved_q="$video_quality_status"
video_quality_status="+"; video_quality_value="23"
video_number_frames_status="-"; audio_number_channels_status="-"
audio_sampling_rate_status="-"; playback_speed_status="-"
video_resolution_status="-"; video_bitrate_status="-"; audio_bitrate_status="-"
remote_wait_timeout=1800; remote_stall_timeout=900; remote_prefer=auto; remote_on_failure=abort
threads=4
if remote_validate_config 2>/dev/null; then pass "числовой quality проходит"
else fail "числовой quality проходит" "код 0" "код 1"; fi
video_quality_value="23 кбит"
_verr="$(remote_validate_config 2>&1 >/dev/null)"; _vrc=$?
assert_eq "нечисловой quality отклонён" "1" "$_vrc"
assert_contains "и назван по имени" "quality" "$_verr"
video_quality_value="23"
video_number_frames_status="+"; video_number_frames_value="30fps"
_verr="$(remote_validate_config 2>&1 >/dev/null)"
assert_contains "нечисловой fps отклонён" "number_frames" "$_verr"
video_number_frames_status="-"
playback_speed_status="+"; playback_speed_value="1.5"
if remote_validate_config 2>/dev/null; then pass "дробная скорость проходит"
else fail "дробная скорость проходит" "код 0" "код 1"; fi
playback_speed_value="1,5"
_verr="$(remote_validate_config 2>&1 >/dev/null)"
assert_contains "запятая в скорости отклонена" "playback_speed" "$_verr"
playback_speed_status="-"
threads="много"
_verr="$(remote_validate_config 2>&1 >/dev/null)"
assert_contains "нечисловые threads отклонены" "threads" "$_verr"
threads=4
video_quality_status="$_saved_q"

rm -f "$MOCK_CURL_LOG" "$_capture"
summary
