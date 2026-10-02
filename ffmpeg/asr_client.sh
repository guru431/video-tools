#!/bin/bash
# Модуль подключается через `source` из converter-скрипта и работает на его
# переменных (asr_*, ffmpeg, folder_*, log_msg, put_result…): shellcheck их не
# видит и объявляет неопределёнными (SC2154) или неиспользуемыми (SC2034).
# shellcheck disable=SC2034,SC2154
# ============================================================
# Распознавание речи (ASR) — клиент сервера WhisperX (Bash)
#
# Подключается из FFmpeg_Converter_script.sh. Ничего не запускает сам: только
# функции, поэтому модуль дот-сорсится в тест без сети и без побочных эффектов.
# Результаты функций — в глобальных ASR_*, а не в stdout: функция внутри $( )
# выполнилась бы в подоболочке, и всё, что она выставила, потерялось бы (см.
# шапку remote_client.sh). Двойник — asr_client.ps1; равенство плана частей,
# аргументов curl, исходов и текста сверяет test_27_asr_parity.sh.
#
# Спека: docs/superpowers/specs/2026-10-02-ffmpeg-asr-design.md
# ============================================================

# --- Экранирование значения для curl-конфига ---
# Внутри кавычек curl-конфига экранируются ровно \ и " (curl.1, --config). Проход
# посимвольный по той же причине, что в remote_escape_dq: подстановка шаблоном
# ломается на bash 3.2. Своя копия, а не вызов из remote_client.sh: модуль
# подключается и проверяется без удалённого бэкенда.
asr_escape_dq() {
	local s="$1" out='' i c
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $c in
			'\') out="$out\\\\" ;;
			'"') out="$out\\\"" ;;
			*)   out="$out$c" ;;
		esac
	done
	ASR_ESCAPED="$out"
}

# --- Адреса: список через пробел, без хвостовых слэшей ---
# У сервера разные адреса из разных сетей; берётся первый ответивший. read -a,
# а не `for w in $1`: голое раскрытие глоббит `*` и `?` по файлам каталога.
asr_split_endpoints() {
	local -a words
	local u i
	ASR_ENDPOINTS=()
	read -r -a words <<< "$1"
	for (( i = 0; i < ${#words[@]}; i++ )); do
		u="${words[i]}"
		while [ -n "$u" ] && [ "${u: -1}" = "/" ]; do u="${u%/}"; done
		[ -n "$u" ] && ASR_ENDPOINTS+=("$u")
	done
	return 0
}

# --- TLS: -k только вместе с пином ---
# Сертификат сервера самоподписанный и выписан на другое имя: обычная проверка не
# пройдёт. Пин проверяет, что на том конце именно наш сервер; -k без пина не
# ставится никогда — это было бы «доверять кому угодно».
asr_tls_args() {
	ASR_TLS_ARGS=()
	case "$1" in
		https://*) [ -n "${asr_pinned_pubkey:-}" ] && ASR_TLS_ARGS=(-k --pinnedpubkey "$asr_pinned_pubkey") ;;
	esac
	return 0
}

# --- Поле плоского JSON (ответ /speech/limits) ---
# Ответ плоский, кроме reject_codes, а имена нужных полей в нём уникальны —
# поэтому регулярное выражение, а не разбор целиком. Кавычки строки снимаются.
asr_json_field() {
	local re='"'"$2"'"[[:space:]]*:[[:space:]]*("[^"]*"|\[[^]]*\]|[^,}[:space:]]+)'
	ASR_JSON_VAL=""
	[[ $1 =~ $re ]] || return 1
	ASR_JSON_VAL="${BASH_REMATCH[1]}"
	case "$ASR_JSON_VAL" in
		\"*\") ASR_JSON_VAL="${ASR_JSON_VAL#\"}"; ASR_JSON_VAL="${ASR_JSON_VAL%\"}" ;;
	esac
	return 0
}

# --- Пределы сервера ---
# Опираемся на живой ответ: при переключении сервера на карту max_seconds и
# скорость меняются, и зашитые числа завели бы план частей не туда.
asr_parse_limits() {
	local v
	ASR_LIM_MAX_SECONDS=""; ASR_LIM_MAX_BYTES=""; ASR_LIM_JOB_TIMEOUT=""
	ASR_LIM_DEVICE=""; ASR_LIM_LANGUAGES=""; ASR_LIM_DIARIZATION=""; ASR_LIM_VER=""
	asr_json_field "$1" max_seconds && ASR_LIM_MAX_SECONDS="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" max_bytes && ASR_LIM_MAX_BYTES="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" job_timeout_sec && ASR_LIM_JOB_TIMEOUT="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" device && ASR_LIM_DEVICE="$ASR_JSON_VAL"
	asr_json_field "$1" diarization && ASR_LIM_DIARIZATION="$ASR_JSON_VAL"
	asr_json_field "$1" asr_ver && ASR_LIM_VER="$ASR_JSON_VAL"
	if asr_json_field "$1" languages; then
		v="${ASR_JSON_VAL#[}"; v="${v%]}"; v="${v//\"/}"; v="${v//,/ }"
		read -r -a _asr_langs <<< "$v"
		ASR_LIM_LANGUAGES="${_asr_langs[*]}"
	fi
	case "$ASR_LIM_MAX_SECONDS" in ''|*[!0-9]*) return 1 ;; esac
	case "$ASR_LIM_JOB_TIMEOUT" in ''|*[!0-9]*) return 1 ;; esac
	return 0
}

# --- План частей (спека §6) ---
# $1 — длительность в целых секундах (уже с запасом вверх). Предел «целиком» W —
# что сервер успеет за свой job_timeout_sec: на процессоре ~0.5 с на секунду
# записи (берём 0.6 с запасом), на карте в разы быстрее (0.1). Коэффициенты — в
# целых: ×10/6 и ×10. Длиннее W — равные части не длиннее W/2: равные, чтобы не
# было трёхсекундного хвоста, который сервер распознаёт хуже всего.
asr_plan_parts() {
	local d="$1" w lim p n l i off len
	if [ "$ASR_LIM_DEVICE" = "cpu" ]; then lim=$(( ASR_LIM_JOB_TIMEOUT * 10 / 6 )); else lim=$(( ASR_LIM_JOB_TIMEOUT * 10 )); fi
	w="$ASR_LIM_MAX_SECONDS"
	[ "$lim" -lt "$w" ] && w="$lim"
	ASR_PLAN_WHOLE="$w"
	if [ "$d" -le "$w" ]; then
		ASR_PLAN="0:$d"; ASR_PLAN_LEN="$d"
		return 0
	fi
	p=$(( w / 2 )); n=$(( (d + p - 1) / p )); l=$(( (d + n - 1) / n ))
	ASR_PLAN=""; ASR_PLAN_LEN="$l"
	for (( i = 0; i < n; i++ )); do
		off=$(( i * l )); len=$(( d - off ))
		[ "$len" -gt "$l" ] && len="$l"
		[ "$len" -gt 0 ] || break
		ASR_PLAN="${ASR_PLAN:+$ASR_PLAN }$off:$len"
	done
	return 0
}

# --- Аргументы запроса распознавания ---
# Ключа здесь нет: он уходит конфигом на stdin (asr_curl_run). Часть и ответ —
# ОТНОСИТЕЛЬНЫМИ именами: curl запускается из ASR_RUN_DIR. curl из Git Bash —
# нативная программа, и путь `file=@/tmp/…` MSYS в Windows-путь не переводит —
# curl отвечает кодом 26 (проверено 2026-10-02). Порядок аргументов — контракт
# с Get-AsrCurlArgs в .ps1 (test_27).
asr_curl_args() {
	local base="$1" part="$2" out="$3" diar="false"
	[ "${asr_diarize:-yes}" = "yes" ] && diar="true"
	ASR_CURL_ARGS=(-sS --connect-timeout 10 --max-time "$(( ASR_LIM_JOB_TIMEOUT + 300 ))")
	asr_tls_args "$base"
	[ ${#ASR_TLS_ARGS[@]} -gt 0 ] && ASR_CURL_ARGS+=("${ASR_TLS_ARGS[@]}")
	ASR_CURL_ARGS+=(-F "file=@${part};type=audio/flac" -F "model=whisperx"
		-F "language=${asr_language}" -F "diarize=${diar}")
	[ -n "${asr_num_speakers:-}" ] && ASR_CURL_ARGS+=(-F "num_speakers=${asr_num_speakers}")
	ASR_CURL_ARGS+=(-o "$out" -w '%{http_code}' "${base}/speech/transcriptions")
	return 0
}

# --- Извлечение звука части ---
# Первая звуковая дорожка → FLAC, моно, 16 кГц: кодер встроен в любую сборку
# ffmpeg, без потерь, час ≈ 65 МБ при пределе сервера 500 МБ. -ss/-t — только при
# нескольких частях и на входной стороне: перекодирование, смещение точное.
asr_extract_args() {
	ASR_FF_ARGS=(-nostdin -v error -y)
	[ "$4" -gt 1 ] && ASR_FF_ARGS+=(-ss "$2" -t "$3")
	ASR_FF_ARGS+=(-i "$1" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a flac "$5")
	return 0
}

asr_hms() {
	local s="${1%%.*}"
	printf -v ASR_HMS '%02d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
}

# Дата в шапке расшифровки. FFCONV_ASR_NOW подменяет её в тестах: реального
# времени тесты не читают. printf %(…)T — bash 4.2+, на 3.2 (macOS) — date.
asr_now() {
	ASR_NOW="${FFCONV_ASR_NOW:-}"
	[ -n "$ASR_NOW" ] && return 0
	printf -v ASR_NOW '%(%Y-%m-%d %H:%M)T' -1 2>/dev/null || ASR_NOW="$(date '+%Y-%m-%d %H:%M')"
}

# --- Проверка [asr] до первого файла ---
asr_validate_config() {
	local bad=0 i
	asr_split_endpoints "${asr_endpoint:-}"
	if [ ${#ASR_ENDPOINTS[@]} -eq 0 ]; then
		echo "[ОШИБКА] [asr] endpoint пуст: задайте адрес сервера распознавания (или \${ASR_URL})." >&2
		bad=1
	fi
	for (( i = 0; i < ${#ASR_ENDPOINTS[@]}; i++ )); do
		case "${ASR_ENDPOINTS[i]}" in
			http://?*|https://?*) ;;
			*) echo "[ОШИБКА] [asr] endpoint: '${ASR_ENDPOINTS[i]}' — адрес должен начинаться с http:// или https://." >&2
			   bad=1 ;;
		esac
	done
	if [ -z "${asr_language:-}" ]; then
		echo "[ОШИБКА] [asr] language пуст: укажите язык записи (ru, en)." >&2
		bad=1
	fi
	case "${asr_diarize:-yes}" in
		yes|no) ;;
		*) echo "[ОШИБКА] [asr] diarize = '$asr_diarize': ожидается yes или no." >&2; bad=1 ;;
	esac
	if [ -n "${asr_num_speakers:-}" ]; then
		local n_ok=0
		case "$asr_num_speakers" in
			*[!0-9]*) ;;
			*) [ "$(( 10#$asr_num_speakers ))" -ge 1 ] && [ "$(( 10#$asr_num_speakers ))" -le 50 ] && n_ok=1 ;;
		esac
		if [ "$n_ok" = "0" ]; then
			echo "[ОШИБКА] [asr] num_speakers = '$asr_num_speakers': целое от 1 до 50 или пусто." >&2
			bad=1
		fi
	fi
	return $bad
}

# --- Ключ из api_key_command (приоритет выше api_key) ---
# Выполняется один раз за прогон: менеджер паролей может спросить пароль.
ASR_API_KEY_RESOLVED="no"
asr_resolve_api_key() {
	[ -n "${asr_api_key_command:-}" ] || return 0
	[ "$ASR_API_KEY_RESOLVED" = "yes" ] && return 0
	local out
	out="$(eval "$asr_api_key_command" 2>/dev/null)" || {
		echo "[ОШИБКА] [asr] api_key_command завершилась с ошибкой — ключ не получен." >&2
		return 1
	}
	out="${out%%$'\n'*}"
	out="${out#"${out%%[![:space:]]*}"}"
	out="${out%"${out##*[![:space:]]}"}"
	if [ -z "$out" ]; then
		echo "[ОШИБКА] [asr] api_key_command ничего не напечатала — ключ не получен." >&2
		return 1
	fi
	asr_api_key="$out"
	ASR_API_KEY_RESOLVED="yes"
	return 0
}

# --- Вызов curl из каталога прогона ---
# Ключ — конфигом на stdin (`--config -`), а не аргументом: argv процесса читает
# любой локальный пользователь, а запрос живёт до получаса. Код ответа — из
# `-w %{http_code}` (тело уходит в файл через -o); "000" — ответа не было.
asr_curl_run() {
	local dir="$1" out
	shift
	asr_escape_dq "${asr_api_key:-}"
	out="$(cd "$dir" && printf 'header = "Authorization: Bearer %s"\n' "$ASR_ESCAPED" \
		| "${CURL_BIN:-curl}" --config - "$@" 2>curl.err)"
	ASR_CURL_RC=$?
	ASR_HTTP_CODE="$out"
	case "$ASR_HTTP_CODE" in ''|*[!0-9]*) ASR_HTTP_CODE="000" ;; esac
	ASR_CURL_ERR=""
	[ -s "$dir/curl.err" ] && IFS= read -r ASR_CURL_ERR < "$dir/curl.err"
	rm -f "$dir/curl.err"
	return 0
}

# --- Выбор адреса: первый, ответивший 200 на GET /speech/limits ---
# 401/403 и чужой сертификат (curl 90) — остановка сразу: ключ общий для всех
# адресов, а чужой сертификат — повод остановиться, а не искать дальше.
asr_select_endpoint() {
	local u tried="" i body hint
	ASR_BASE=""; ASR_STOP_REASON=""
	asr_split_endpoints "${asr_endpoint:-}"
	for (( i = 0; i < ${#ASR_ENDPOINTS[@]}; i++ )); do
		u="${ASR_ENDPOINTS[i]}"
		asr_tls_args "$u"
		rm -f "$ASR_RUN_DIR/limits.json"
		asr_curl_run "$ASR_RUN_DIR" -sS --connect-timeout 5 --max-time 15 \
			${ASR_TLS_ARGS[@]+"${ASR_TLS_ARGS[@]}"} -o limits.json -w '%{http_code}' "$u/speech/limits"
		if [ "$ASR_CURL_RC" = "90" ]; then
			ASR_STOP_REASON="сертификат $u не совпал с закреплённым ключом [asr] pinned_pubkey (curl 90) — соединение оборвано"
			return 1
		fi
		case "$ASR_HTTP_CODE" in
			200)
				body=""
				[ -f "$ASR_RUN_DIR/limits.json" ] && IFS= read -r -d '' body < "$ASR_RUN_DIR/limits.json"
				if asr_parse_limits "$body"; then
					ASR_BASE="$u"
					return 0
				fi
				tried="$tried; $u → 200, но ответ не похож на /speech/limits" ;;
			401|403)
				ASR_STOP_REASON="$u: ключ не принят (HTTP $ASR_HTTP_CODE) — проверьте [asr] api_key"
				return 1 ;;
			*)
				if [ "$ASR_CURL_RC" != "0" ]; then
					hint=""
					case "$ASR_CURL_RC" in
						35|60) [ -z "${asr_pinned_pubkey:-}" ] && hint=" — для самоподписанного сертификата задайте [asr] pinned_pubkey" ;;
					esac
					tried="$tried; $u → curl $ASR_CURL_RC${ASR_CURL_ERR:+ ($ASR_CURL_ERR)}$hint"
				else
					tried="$tried; $u → HTTP $ASR_HTTP_CODE"
				fi ;;
		esac
	done
	ASR_STOP_REASON="сервер распознавания недоступен: ${tried#; }"
	return 1
}

# --- Текст ошибки сервера: {"detail": "..."} — дословно ---
asr_detail() {
	local body="" re='"detail"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
	ASR_DETAIL=""
	[ -n "${1:-}" ] && [ -s "$1" ] || return 0
	IFS= read -r -d '' body < "$1"
	[[ $body =~ $re ]] && ASR_DETAIL="${BASH_REMATCH[1]}"
	return 0
}

# --- Исход запроса (спека §5.3) ---
# file — причина в самом файле (прогон продолжается); stop — причина общая для
# всех файлов: сервер, сеть, ключ, сертификат (прогон останавливается).
# Тексты причин — контракт с Get-AsrOutcome в .ps1 (test_27).
asr_classify() {
	local rc="$1" code="$2" f="${3:-}" d=""
	ASR_OUTCOME="stop"; ASR_REASON=""; ASR_DETAIL=""
	[ "$code" != "200" ] && asr_detail "$f"
	[ -n "$ASR_DETAIL" ] && d=": $ASR_DETAIL"
	if [ "$rc" != "0" ]; then
		case "$rc" in
			90) ASR_REASON="сертификат сервера не совпал с закреплённым ключом (curl 90)" ;;
			28) ASR_REASON="истёк таймаут ожидания ответа (curl 28); задача на сервере может ещё выполняться" ;;
			26) ASR_OUTCOME="file"; ASR_REASON="curl не смог прочитать извлечённый звук (curl 26)" ;;
			*)  ASR_REASON="сетевая ошибка (curl $rc${ASR_CURL_ERR:+: $ASR_CURL_ERR})" ;;
		esac
		return 0
	fi
	case "$code" in
		200) ASR_OUTCOME="ok" ;;
		400|413|422) ASR_OUTCOME="file"; ASR_REASON="HTTP $code$d" ;;
		401|403) ASR_REASON="ключ не принят (HTTP $code)$d" ;;
		503) ASR_REASON="очередь сервера заполнена (HTTP 503) и после повторов$d" ;;
		504) ASR_REASON="сервер не уложился в свой предел (HTTP 504); задача на сервере продолжает выполняться — повторите позже$d" ;;
		*) ASR_REASON="HTTP $code$d" ;;
	esac
	return 0
}

# --- Запрос одной части ---
# Запрос синхронный: соединение молчит до конца распознавания (до получаса) — это
# норма. 503 (очередь полна) — пауза и повтор; остальное классифицирует
# asr_classify. 200 без поля segments (страница ошибки прокси) — провал файла, а
# не пустая расшифровка.
asr_transcribe_part() {
	local part="$1" resp="$2" try=1 tries="${ASR_RETRIES:-5}" wait_s="${ASR_RETRY_WAIT:-60}"
	while :; do
		rm -f "$ASR_RUN_DIR/$resp"
		asr_curl_args "$ASR_BASE" "$part" "$resp"
		asr_curl_run "$ASR_RUN_DIR" "${ASR_CURL_ARGS[@]}"
		if [ "$ASR_CURL_RC" = "0" ] && [ "$ASR_HTTP_CODE" = "503" ] && [ "$try" -le "$tries" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] Очередь сервера заполнена (HTTP 503) — повтор через ${wait_s} с (попытка $try из $tries)." >&2
			sleep "$wait_s"
			try=$((try + 1))
			continue
		fi
		break
	done
	asr_classify "$ASR_CURL_RC" "$ASR_HTTP_CODE" "$ASR_RUN_DIR/$resp"
	if [ "$ASR_OUTCOME" = "ok" ] && ! grep -q '"segments"' "$ASR_RUN_DIR/$resp" 2>/dev/null; then
		ASR_OUTCOME="file"; ASR_REASON="сервер ответил 200, но без поля segments"
	fi
	return 0
}

# --- Предпусковая проверка: один раз, ДО первого файла ---
# Всё, что делает невозможным весь прогон, выясняется здесь: отказать на сотом
# файле дороже, чем на нулевом. Создаёт ASR_RUN_DIR (его убирает сводка скрипта и
# trap Ctrl+C) и выбирает адрес.
asr_preflight() {
	asr_validate_config || return 1
	if [ "${ffmpeg_available:-yes}" != "yes" ]; then
		echo "[ОШИБКА] Распознавание речи требует локального ffmpeg: им извлекается звук ($ffmpeg не найден)." >&2
		return 1
	fi
	if ! command -v "${CURL_BIN:-curl}" >/dev/null 2>&1; then
		echo "[ОШИБКА] curl не найден — распознавание речи невозможно." >&2
		return 1
	fi
	asr_resolve_api_key || return 1
	if [ -z "${asr_api_key:-}" ]; then
		echo "[ОШИБКА] [asr] ключ не задан: api_key, api_key_command или \${ASR_API_KEY}." >&2
		return 1
	fi
	ASR_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ffconv_asr.XXXXXXXX")" || {
		echo "[ОШИБКА] Не удалось создать временный каталог для распознавания." >&2
		ASR_RUN_DIR=""
		return 1
	}
	if ! asr_select_endpoint; then
		echo "[ОШИБКА] $ASR_STOP_REASON" >&2
		rm -rf "$ASR_RUN_DIR"; ASR_RUN_DIR=""
		return 1
	fi
	if [ -n "$ASR_LIM_LANGUAGES" ]; then
		case " $ASR_LIM_LANGUAGES " in
			*" $asr_language "*) ;;
			*)
				echo "[ОШИБКА] [asr] language = '$asr_language': сервер его не принимает (доступны: $ASR_LIM_LANGUAGES)." >&2
				rm -rf "$ASR_RUN_DIR"; ASR_RUN_DIR=""
				return 1 ;;
		esac
	fi
	case "$ASR_BASE" in
		http://*) echo "[ПРЕДУПРЕЖДЕНИЕ] $ASR_BASE — открытый http: ключ и звук идут по сети незашифрованными." ;;
	esac
	if [ "${asr_diarize:-yes}" = "yes" ] && [ "$ASR_LIM_DIARIZATION" = "false" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Сервер сообщает diarization = false: говорящих в расшифровке может не быть."
	fi
	ASR_STOP_REASON=""
	asr_plan_parts 0
	log_msg "INFO" "Распознавание речи: $ASR_BASE (${ASR_LIM_VER:-?}, ${ASR_LIM_DEVICE:-?}); целиком — до $ASR_PLAN_WHOLE с, длиннее — равными частями"
	return 0
}

# --- Сборка .txt из ответов сервера: один процесс awk на файл ---
# Ни jq, ни python в Git Bash/macOS не гарантированы. Разбор JSON — с RS = кавычка:
# документ режется на короткие записи «вне строки / внутри строки», и awk не
# ходит посимвольно по многомегабайтному тексту (в BWK awk substr считает длину
# всей строки на каждом вызове — посимвольный проход был бы квадратичным).
# Кавычка внутри строки экранирована, если перед ней НЕЧЁТНОЕ число обратных
# слэшей. Хранятся только нужные значения (слова и полный текст пропускаются),
# строки декодируются целиком: \" \\ \/ \b \f \n \r \t \uXXXX и суррогатные пары.
# LC_ALL=C: байты UTF-8 проходят насквозь, %c печатает байт. Правила шапки и
# реплик — спека §9.2; двойник — Write-AsrTranscript в .ps1 (байт в байт, test_27).
# В программе нет апострофов: она лежит в одинарных кавычках оболочки.
ASR_AWK_RENDER='
function hexval(h,   i, v, c) {
	if (length(h) != 4) return -1
	v = 0; h = tolower(h)
	for (i = 1; i <= 4; i++) {
		c = index("0123456789abcdef", substr(h, i, 1)) - 1
		if (c < 0) return -1
		v = v * 16 + c
	}
	return v
}
function utf8(cp) {
	if (cp < 128) return sprintf("%c", cp)
	if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
	if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
	return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
function decode(s,   out, i, c, cp, lo) {
	if (index(s, "\\") == 0) return s
	out = ""
	while ((i = index(s, "\\")) > 0) {
		out = out substr(s, 1, i - 1)
		c = substr(s, i + 1, 1)
		if (c == "u") {
			cp = hexval(substr(s, i + 2, 4)); s = substr(s, i + 6)
			if (cp >= 55296 && cp < 56320 && substr(s, 1, 2) == "\\u") {
				lo = hexval(substr(s, 3, 4))
				if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); s = substr(s, 7) }
			}
			if (cp > 0) out = out utf8(cp)
			continue
		}
		if (c == "n") out = out "\n"
		else if (c == "t") out = out "\t"
		else if (c == "r") out = out "\r"
		else if (c == "b") out = out "\b"
		else if (c == "f") out = out "\f"
		else out = out c
		s = substr(s, i + 2)
	}
	return out s
}
function clean(t) { gsub(/[\r\n\t]/, " ", t); sub(/^ +/, "", t); sub(/ +$/, "", t); return t }
function ts(x,   s) { s = int(x); return sprintf("%02d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60) }
function want(path) {
	return path ~ /^p[0-9]+\.(asr_ver|audio_seconds|processing_seconds)$/ ||
	       path ~ /^p[0-9]+\.warnings\.[0-9]+$/ ||
	       path ~ /^p[0-9]+\.stages\.[^.]+\.status$/ ||
	       path ~ /^p[0-9]+\.segments\.[0-9]+\.(start|text|speaker|confidence)$/
}
function curpath() {
	if (d == 0) return "p" part
	return (TY[d] == "o") ? PP[d] "." KEY[d] : PP[d] "." IX[d]
}
function setval(raw, isstr,   path, a) {
	path = curpath()
	if (!want(path)) return
	if (!isstr && raw == "null") return
	V[path] = isstr ? decode(raw) : raw
	split(path, a, ".")
	if (a[2] == "segments" && a[3] + 1 > NSEG[part]) NSEG[part] = a[3] + 1
	if (a[2] == "warnings" && a[3] + 1 > NW[part]) NW[part] = a[3] + 1
}
function flushlit() { if (lit != "") { setval(lit, 0); lit = "" } }
function opencont(t,   path) {
	path = curpath()
	d++; TY[d] = t; PP[d] = path; KEY[d] = ""; IX[d] = 0
	expect = (t == "o") ? "k" : "v"
}
function outside(s,   i, n, c) {
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "{") opencont("o")
		else if (c == "[") opencont("a")
		else if (c == "}" || c == "]") { flushlit(); d--; expect = "n" }
		else if (c == ":") expect = "v"
		else if (c == ",") { flushlit(); if (TY[d] == "a") IX[d]++; expect = (TY[d] == "o") ? "k" : "v" }
		else if (c == " " || c == "\n" || c == "\r" || c == "\t") flushlit()
		else lit = lit c
	}
}
function onstring(raw) {
	if (expect == "k") {
		KEY[d] = raw
		if (PP[d] ~ /^p[0-9]+\.stages$/) SK[part, ++NSK[part]] = raw
		expect = "c"
	} else { setval(raw, 1); expect = "n" }
}
BEGIN {
	RS = "\""
	part = 0
	split(ENVIRON["ASR_R_OFFS"], OFF, " ")
	out = ENVIRON["ASR_R_OUT"]
	lowthr = 0.6
}
FNR == 1 { part++; d = 0; ins = 0; sbuf = ""; lit = ""; expect = "v"; NSEG[part] = 0; NW[part] = 0; NSK[part] = 0 }
{
	if (!ins) { outside($0); ins = 1; next }
	n = length($0); k = 0
	while (k < n && substr($0, n - k, 1) == "\\") k++
	if (k % 2 == 1) { sbuf = sbuf $0 "\""; next }
	onstring(sbuf $0); sbuf = ""; ins = 0
}
END {
	aud = 0; audok = 1; prc = 0; prcok = 1; ver = ""; bad = ""; nwarn = 0
	nrep = 0; low = 0; nlow = 0; lowlist = ""; spk = ""; spkh = ""
	for (p = 1; p <= part; p++) {
		pre = "p" p "."
		off = OFF[p] + 0
		tag = (part > 1) ? "ч." p ": " : ""
		if ((pre "audio_seconds") in V) aud += V[pre "audio_seconds"]; else audok = 0
		if ((pre "processing_seconds") in V) prc += V[pre "processing_seconds"]; else prcok = 0
		if (ver == "" && (pre "asr_ver") in V) ver = V[pre "asr_ver"]
		for (j = 1; j <= NSK[p]; j++) {
			sk = SK[p, j]
			sst = ((pre "stages." sk ".status") in V) ? V[pre "stages." sk ".status"] : "?"
			if (sst != "ok") bad = bad (bad == "" ? "" : ", ") tag sk "=" sst
		}
		for (j = 0; j < NW[p]; j++)
			if ((pre "warnings." j) in V) WARN[++nwarn] = tag clean(V[pre "warnings." j])
		ns = 0; cur = ""; rb = ""; t0 = 0
		for (i = 0; i < NSEG[p]; i++) {
			sb = pre "segments." i "."
			if (!((sb "text") in V)) continue
			t = clean(V[sb "text"])
			if (t == "") continue
			sp = ((sb "speaker") in V && V[sb "speaker"] != "") ? V[sb "speaker"] : "SPEAKER_?"
			if (sp != "SPEAKER_?" && !((p, sp) in SEEN)) { SEEN[p, sp] = 1; ns++ }
			st = (((sb "start") in V) ? V[sb "start"] + 0 : 0) + off
			if ((sb "confidence") in V && V[sb "confidence"] + 0 < lowthr) {
				low++
				if (nlow < 3) { lowlist = lowlist (nlow ? ", " : "") ts(st); nlow++ }
			}
			if (rb != "" && sp != cur) { REP[++nrep] = "[" ts(t0) "] " cur ": " rb; rb = "" }
			if (rb == "") { cur = sp; t0 = st; rb = t } else rb = rb " " t
		}
		if (rb != "") REP[++nrep] = "[" ts(t0) "] " cur ": " rb
		spk = spk (p > 1 ? "," : "") ns
		spkh = spkh (p > 1 ? ", " : "") ns
	}
	print "# Расшифровка: " ENVIRON["ASR_R_SRC"] > out
	print "# Дата: " ENVIRON["ASR_R_DATE"] > out
	print "# Модель: " (ver == "" ? "?" : ver) > out
	print "# Длительность записи: " (audok ? ts(aud) : "?") ", обработка: " (prcok ? ts(prc) : "?") > out
	if (part == 1) print "# Говорящих: " spkh > out
	else {
		print "# Говорящих по частям: " spkh > out
		print "# Частей: " part " по ≈" ts(ENVIRON["ASR_R_PLEN"] + 0) " — метки говорящих в разных частях независимы" > out
	}
	print "# Сомнительных сегментов (confidence < 0.6): " low (low > 0 ? "; первые: " lowlist : "") > out
	if (bad != "") print "# Этапы с ошибкой: " bad > out
	for (j = 1; j <= nwarn; j++) print "# Предупреждение: " WARN[j] > out
	print "" > out
	for (j = 1; j <= nrep; j++) print REP[j] > out
	close(out)
	print "speakers=" spk " low=" low " bad=" bad
}
'

# $1 — имя входа, $2 — дата, $3 — длина части (для шапки), $4 — выход;
# дальше пары «файл ответа, смещение». Сводка — в ASR_R_SPEAKERS/LOW/BAD.
# Значения уходят в awk через ENVIRON, а не -v: -v раскрывает в них \-escape'ы.
asr_render() {
	local src="$1" date="$2" plen="$3" out="$4" offs="" summary
	local -a files=()
	shift 4
	while [ $# -ge 2 ]; do files+=("$1"); offs="${offs:+$offs }$2"; shift 2; done
	rm -f "$out"
	summary="$(ASR_R_SRC="$src" ASR_R_DATE="$date" ASR_R_OUT="$out" ASR_R_OFFS="$offs" ASR_R_PLEN="$plen" \
		LC_ALL=C awk "$ASR_AWK_RENDER" "${files[@]}")" || return 1
	ASR_R_SPEAKERS="${summary#speakers=}"; ASR_R_SPEAKERS="${ASR_R_SPEAKERS%% low=*}"
	ASR_R_LOW="${summary#* low=}"; ASR_R_LOW="${ASR_R_LOW%% bad=*}"
	ASR_R_BAD="${summary#* bad=}"
	[ -s "$out" ]
}

# --- .asr.json: ответ как есть или обёртка частей без пересборки ---
# $1 — выход; дальше пары «файл ответа, смещение». Время внутри response — от
# начала своей части; смещение указано явно (спека §9.1).
asr_write_json() {
	local out="$1" first=1
	shift
	if [ $# -eq 2 ]; then cp -f "$1" "$out"; return $?; fi
	{
		printf '{"chunks":['
		while [ $# -ge 2 ]; do
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"offset_seconds":%s,"response":' "$2"
			cat "$1"
			printf '}'
			shift 2
		done
		printf ']}\n'
	} > "$out"
}

# Части и ответы текущего файла — в ASR_RUN_DIR; сам каталог живёт весь прогон.
asr_file_cleanup() {
	[ -n "${ASR_RUN_DIR:-}" ] || return 0
	rm -f "$ASR_RUN_DIR"/part_*.flac "$ASR_RUN_DIR"/resp_*.json "$ASR_RUN_DIR/ffmpeg.err"
}

# --- Один файл (спека §5.2) ---
# rc 0 — файл учтён (ok/fail/skip через put_result); rc 2 — прогон остановлен,
# причина в ASR_STOP_REASON. Формулы имени и подпапки — те же, что у encode_file.
asr_file() {
	local full_path="$1" name="${1##*/}"
	if [ "$dest_inside_source" = "yes" ]; then
		canon_path "$full_path"
		case "$CANON_PATH" in
			"$canon_destination"/*)
				log_msg "SKIP" "внутри каталога назначения (собственный выход): $name"
				put_result "skip"
				return 0 ;;
		esac
	fi
	path_dir "$full_path"
	local rel="$PATH_DIR/"
	rel="${rel:$_src_prefix_len}"
	local stem="${name%.*}"
	[ "$save_old_extension" = "yes" ] && stem="$name"
	local out_dir="${folder_destination}${rel}"
	local out_txt="${out_dir}${stem}.txt" out_json="${out_dir}${stem}.asr.json"

	# Два входа одного прогона не делят один выход: movie.avi и movie.mp4 оба дают
	# movie.txt, и второй затёр бы первый (или «пропустил» бы его как готовый).
	lower_ascii "$out_txt"
	case "$ASR_CLAIMED" in
		*$'\n'"$LOWER_ASCII"$'\n'*)
			log_msg "FAIL" "$name: конфликт выходов — «${stem}.txt» уже занят другим входом (включите save_old_extension = yes либо разнесите файлы)"
			put_result "fail"
			return 0 ;;
	esac
	ASR_CLAIMED="$ASR_CLAIMED$LOWER_ASCII"$'\n'

	if [ "$overwrite_existing" != "yes" ] && [ -f "$out_txt" ]; then
		log_msg "SKIP" "$name: расшифровка уже есть (${stem}.txt)"
		put_result "skip"
		return 0
	fi

	# Длительность и звук — тот же разбор `ffmpeg -i`, что у конвертера.
	parse_media_info "$("$ffmpeg" -nostdin -i "$full_path" 2>&1)"
	if [ -z "$MI_ACODEC" ]; then
		log_msg "FAIL" "$name: нет звуковой дорожки"
		put_result "fail"
		return 0
	fi
	if [ -z "$MI_DUR" ]; then
		log_msg "FAIL" "$name: длительность не читается"
		put_result "fail"
		return 0
	fi
	local h m s
	IFS=: read -r h m s <<< "$MI_DUR"
	asr_plan_parts "$(( 10#$h * 3600 + 10#$m * 60 + 10#$s + 1 ))"
	local -a plan pairs=()
	read -r -a plan <<< "$ASR_PLAN"
	local n=${#plan[@]} i off len part resp t0 started

	if [ "$dry_run" = "yes" ]; then
		asr_hms "$ASR_PLAN_LEN"
		echo "[DRY-RUN] $name: частей $n (по ≈$ASR_HMS) → $out_txt"
		for (( i = 0; i < n; i++ )); do
			off="${plan[i]%%:*}"; len="${plan[i]#*:}"
			printf -v part 'part_%03d.flac' "$i"; printf -v resp 'resp_%03d.json' "$i"
			asr_extract_args "$full_path" "$off" "$len" "$n" "$part"
			echo "[DRY-RUN] $ffmpeg ${ASR_FF_ARGS[*]}"
			asr_curl_args "$ASR_BASE" "$part" "$resp"
			echo "[DRY-RUN] curl ${ASR_CURL_ARGS[*]}"
		done
		return 0
	fi

	[ -d "$out_dir" ] || mkdir -p "$out_dir"
	now_s; started=$NOW_S
	for (( i = 0; i < n; i++ )); do
		off="${plan[i]%%:*}"; len="${plan[i]#*:}"
		printf -v part 'part_%03d.flac' "$i"; printf -v resp 'resp_%03d.json' "$i"
		asr_extract_args "$full_path" "$off" "$len" "$n" "$ASR_RUN_DIR/$part"
		if ! "$ffmpeg" "${ASR_FF_ARGS[@]}" 2>"$ASR_RUN_DIR/ffmpeg.err" || [ ! -s "$ASR_RUN_DIR/$part" ]; then
			log_msg "FAIL" "$name: не удалось извлечь звук (часть $((i + 1))/$n)"
			asr_file_cleanup; put_result "fail"
			return 0
		fi
		if [ -n "$ASR_LIM_MAX_BYTES" ] && [ "$(file_size "$ASR_RUN_DIR/$part")" -gt "$ASR_LIM_MAX_BYTES" ]; then
			log_msg "FAIL" "$name: часть $((i + 1))/$n больше предела сервера ($ASR_LIM_MAX_BYTES байт)"
			asr_file_cleanup; put_result "fail"
			return 0
		fi
		asr_hms "$len"
		log_msg "INFO" "$name: распознавание, часть $((i + 1))/$n ($ASR_HMS записи) — ждём ответ сервера"
		now_s; t0=$NOW_S
		asr_transcribe_part "$part" "$resp"
		case "$ASR_OUTCOME" in
			ok) ;;
			file)
				log_msg "FAIL" "$name: $ASR_REASON"
				asr_file_cleanup; put_result "fail"
				return 0 ;;
			*)
				log_msg "FAIL" "$name: $ASR_REASON"
				ASR_STOP_REASON="$ASR_REASON"
				asr_file_cleanup; put_result "fail"
				return 2 ;;
		esac
		now_s; asr_hms $(( NOW_S - t0 ))
		log_msg "INFO" "$name: часть $((i + 1))/$n распознана за $ASR_HMS"
		rm -f "$ASR_RUN_DIR/$part"
		pairs+=("$ASR_RUN_DIR/$resp" "$off")
	done

	# Публикация: временные имена в каталоге назначения, затем rename; .txt —
	# последним: он маркер готовности, по нему работает пропуск.
	local tmp_json tmp_txt el extra=""
	tmp_json="$(partial_path "$out_json")"; tmp_txt="$(partial_path "$out_txt")"
	asr_now
	if ! asr_write_json "$tmp_json" "${pairs[@]}" \
		|| ! asr_render "$name" "$ASR_NOW" "$ASR_PLAN_LEN" "$tmp_txt" "${pairs[@]}"; then
		log_msg "FAIL" "$name: не удалось собрать расшифровку из ответа сервера"
		rm -f "$tmp_json" "$tmp_txt"; asr_file_cleanup; put_result "fail"
		return 0
	fi
	if mv -f "$tmp_json" "$out_json" 2>/dev/null && mv -f "$tmp_txt" "$out_txt" 2>/dev/null && [ -f "$out_txt" ]; then
		now_s; el=$(( NOW_S - started ))
		[ -n "$ASR_R_BAD" ] && extra=", этапы с ошибкой: $ASR_R_BAD"
		log_msg "OK" "$name -> ${stem}.txt (говорящих: $ASR_R_SPEAKERS, сомнительных сегментов: $ASR_R_LOW$extra) ($((el / 60))m $((el % 60))s)"
		put_result "ok:0:0"
	else
		log_msg "FAIL" "$name: не удалось опубликовать результат (rename)"
		rm -f "$tmp_json" "$tmp_txt"
		put_result "fail"
	fi
	asr_file_cleanup
	return 0
}

# --- Прогон: файлы строго по одному (у сервера один рабочий поток) ---
# Остановка (rc 2) — остальные файлы считаются «не обработано».
asr_run() {
	local full_path stopped="no" rc
	ASR_CLAIMED=$'\n'
	ASR_STOP_REASON=""
	ASR_NOT_PROCESSED=0
	while IFS= read -r -d '' full_path; do
		_any_input="yes"
		if [ "$stopped" = "yes" ]; then
			ASR_NOT_PROCESSED=$((ASR_NOT_PROCESSED + 1))
			continue
		fi
		asr_file "$full_path"; rc=$?
		[ "$rc" -eq 2 ] && stopped="yes"
	done < <(find_inputs | sort_null)
	return 0
}
