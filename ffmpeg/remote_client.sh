#!/bin/bash
# Модуль удалённого бэкенда подключается через `source` из converter-скрипта и
# работает на его переменных: ни присваивания, ни чтения shellcheck здесь не
# видит и объявляет их неопределёнными (SC2154) или неиспользуемыми (SC2034).
# shellcheck disable=SC2034,SC2154
# ============================================================
# Удалённый бэкенд — клиент службы конвертации (Bash)
#
# Подключается из FFmpeg_Converter_script.sh. Ничего не запускает сам:
# только функции. Так модуль можно дот-сорсить в тест без сети и без
# побочных эффектов — тем же приёмом, что и run-файлы.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

# --- Экранирование для литерала в двойных кавычках ---
# Один примитив на два места: строка JSON и значение в curl-конфиге экранируют
# ровно одну и ту же пару символов по одному и тому же правилу (см. curl.1,
# --config). Управляющие символы в наших значениях (кодеки, разрешения, стиль
# ASS, ключ) не встречаются: их бы отверг белый список службы ещё раньше.
#
# Проход посимвольный, а не подстановкой шаблона: оба «коротких» варианта
# ломаются, каждый по-своему и каждый молча.
#   ${s//\\/\\\\}            — слэш внутри шаблона bash считает разделителем ещё
#                              до снятия экранирования, и выражение вырождается
#                              в «удалить подстроку /\»: вход a\b"c/\d давал
#                              a\b\"cd — потеря данных и невалидный JSON разом.
#   s="${s//"$bs"/"$bs$bs"}" — до bash 4.3 строка замены внутри подстановки,
#                              взятой в двойные кавычки, НЕ проходит снятие
#                              кавычек, и обе `"` уезжают в результат буквально:
#                              тот же вход давал a\"\\"b\"c/\"\\"d. На bash 5
#                              (Linux, Git Bash) зелено, на системном bash 3.2
#                              macOS — красно, то есть на половине CI.
# Побайтовый проход безопасен и для UTF-8: продолжающие байты кириллицы всегда
# ≥ 0x80 и с 0x5C/0x22 не совпадают, поэтому «Шрифт» проходит насквозь.
remote_escape_dq() {
	local s="$1" out='' i c
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $c in
			'\') out="$out\\\\" ;;
			'"') out="$out\\\"" ;;
			*)   out="$out$c" ;;
		esac
	done
	printf '%s' "$out"
}

# --- JSON: сборка ---
remote_json_escape() {
	remote_escape_dq "$1"
}

# --- Нормализация адреса службы ---
# Единственная реализация на платформу; PS1-двойник — Format-RemoteEndpoint,
# и их равенство сверяет test_23_remote_parity.sh. Раньше нормализация жила в
# трёх местах в трёх формах: `${x%/}` в run.sh снимал ровно один слэш,
# `.TrimEnd('/')` в CLI-PS1 — все, а `Trim()` был только в GUI. Один и тот же
# config.ini давал «…/v1//jobs» из CLI и «…/v1/jobs» из GUI, а адрес с пробелом
# на конце (обычное дело при копировании из мессенджера) работал только в GUI.
remote_normalize_endpoint() {
	local e="$1"
	# Пробелы по краям — ввод человека, а не часть адреса.
	e="${e#"${e%%[![:space:]]*}"}"
	e="${e%"${e##*[![:space:]]}"}"
	while [ -n "$e" ] && [ "${e: -1}" = "/" ]; do e="${e%/}"; done
	printf '%s' "$e"
}

# --- Отображение энкодера на кодек службы ---
# Служба принимает СЕМЕЙСТВО (h264/hevc/av1) и сама выбирает nvenc или
# программный энкодер по тому, где считает. Поэтому и libx264, и h264_nvenc,
# и h264_qsv отображаются в одно значение: разницу между ними на удалённом
# пути определяет очередь службы, а не наш config.ini.
remote_map_codec() {
	case "$1" in
		libx264|h264_nvenc|h264_qsv)   printf 'h264' ;;
		libx265|hevc_nvenc|hevc_qsv)   printf 'hevc' ;;
		libsvtav1|av1_nvenc|av1_qsv)   printf 'av1'  ;;
		*) return 1 ;;
	esac
}

# --- Операция и параметры из уже разобранного config.ini ---
# Аргументы: <начало в секундах> <длительность в секундах>; 0 0 = файл целиком.
# Печатает две строки: операцию и JSON параметров.
#
# Незнакомое службе поле — отказ 400, а НЕ молчаливое игнорирование. Обратное
# тоже верно и опаснее: поле, которое мы не отправили, примет умолчание службы,
# и результат тихо разойдётся с локальным. Поэтому каждое включённое (+) поле
# config.ini обязано оказаться здесь.
remote_op_for_config() {
	local start_sec="${1:-0}" length_sec="${2:-0}" sub_found="${3:-0}"
	local op="transcode" p=""

	local codec
	codec="$(remote_map_codec "$set_video_codec")" || return 1
	p="\"codec\":\"$codec\""

	# quality и bitrate вместе служба отвергает 400. Локальный скрипт при
	# включённом quality игнорирует битрейт — повторяем это правило здесь.
	if [ "$video_quality_status" = "+" ]; then
		p="$p,\"quality\":$video_quality_value"
	elif [ "$video_bitrate_status" = "+" ]; then
		# config.ini задаёт кбит/с, служба принимает бит/с.
		p="$p,\"bitrate\":$((video_bitrate_value * 1000)),\"bitrate_cap_source\":true"
	fi

	[ "$video_resolution_status" = "+" ] && p="$p,\"resolution\":\"$video_resolution_value\""
	# Статус ключа значим ровно так же, как значение: локальный путь требует «+»
	# (script.sh: scale_backend/pad), и `keep_aspect_ratio = -yes` локально означает
	# «выключено», а удалённо уезжало как true — один config.ini давал разную геометрию.
	if [ "$keep_aspect_ratio_status" = "+" ] && [ "$keep_aspect_ratio_value" = "yes" ]; then
		p="$p,\"keep_aspect\":true"
	else
		p="$p,\"keep_aspect\":false"
	fi
	[ "$video_number_frames_status" = "+" ] && p="$p,\"fps\":$video_number_frames_value"
	# rotate служба принимает числом (1 или 2) либо строкой "off": допустимые
	# значения у неё — ("off", 1, 2), и "2" В КАВЫЧКАХ в этот список не входит.
	# Отказ приходил 400-м и ПОСЛЕ полной загрузки файла — то есть цена ошибки
	# равнялась времени отправки гигабайтов.
	if [ "$video_rotation_status" = "+" ]; then
		case "$video_rotation_value" in
			1|2) p="$p,\"rotate\":$video_rotation_value" ;;
			*) echo "[ПРЕДУПРЕЖДЕНИЕ] [video] rotation = '$video_rotation_value': служба принимает только 1 или 2 — поворот на удалённом пути не применяется." >&2 ;;
		esac
	fi
	# speed=1.0 не отправляем: это умолчание службы, и лишнее поле только
	# расширяет площадь расхождения при сверке холостых прогонов.
	if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
		p="$p,\"speed\":$playback_speed_value"
	fi

	# Поле subtitles уезжает только когда sidecar РЕАЛЬНО найден. Раньше оно шло по
	# одному статусу ключа: `subtitles = +burn` без файла локально означал «кодируем
	# без титров», а службе отправлялось "subtitles":"burn" без subtitle_upload_id —
	# либо 400 на каждом файле (уже ПОСЛЕ полной загрузки видео), либо молчаливое
	# игнорирование. Тот же путь проходила и --remote-selftest.
	if [ "$video_subtitles_status" = "+" ] && [ "$sub_found" = "1" ]; then
		p="$p,\"subtitles\":\"$video_subtitles_value\""
		[ -n "$subtitles_style" ] && \
			p="$p,\"subtitle_style\":\"$(remote_json_escape "$subtitles_style")\""
	fi

	# Контейнер — ПО СТАТУСУ, как в локальном пути (script.sh: «+» → значение,
	# иначе mp4). Раньше значение бралось всегда: `container = -mkv` локально давал
	# movie.mp4, а службе уходило "container":"mkv" — она отдавала Matroska, клиент
	# клал её в .ffconv-partial-movie.mp4, проверка `-f null -` по содержимому
	# проходила, и публиковался movie.mp4 с MKV внутри. Тихо неверный результат.
	if [ "$output_container_status" = "+" ]; then
		p="$p,\"container\":\"$output_container_value\""
	else
		p="$p,\"container\":\"mp4\""
	fi
	p="$p,\"threads\":${threads:-4}"

	[ "$gpu_preset_status" = "+" ] && p="$p,\"preset\":\"$gpu_preset_value\""
	[ "$gpu_tune_status" = "+" ]   && p="$p,\"tune\":\"$gpu_tune_value\""
	[ "$gpu_rc_status" = "+" ]     && p="$p,\"rc\":\"$gpu_rc_value\""

	# `codec` без статуса «+» означает «звук не трогаем» — локально скрипт не ставит
	# -c:a вовсе. Тогда bitrate/channels/rate бессмысленны: перекодирования нет, и
	# запрос «copy плюс битрейт 128» противоречив (служба отвечает 400 либо молча
	# решает по-своему). Отправляем только сам copy.
	local a
	if [ "$audio_codec_status" = "+" ]; then
		a="\"codec\":\"${audio_codec_value}\""
		[ "$audio_bitrate_status" = "+" ]         && a="$a,\"bitrate\":$audio_bitrate_value"
		[ "$audio_number_channels_status" = "+" ] && a="$a,\"channels\":$audio_number_channels_value"
		[ "$audio_sampling_rate_status" = "+" ]   && a="$a,\"rate\":$audio_sampling_rate_value"
		[ "$audio_normalize_status" = "+" ]       && a="$a,\"normalize\":\"$audio_normalize_value\""
	else
		a="\"codec\":\"copy\""
	fi
	p="$p,\"audio\":{$a}"

	# Отрезок — это op: cut с перекодированием, а не op: split. Разрезание на
	# части остаётся клиентским циклом: имена part.N и manifest строит он, и
	# отдать их назначение серверу значило бы переписать обе вещи (раздел 3.1).
	if [ "$start_sec" -gt 0 ] 2>/dev/null || [ "$length_sec" -gt 0 ] 2>/dev/null; then
		op="cut"
		p="\"start\":$start_sec,\"reencode\":true,$p"
		[ "$length_sec" -gt 0 ] 2>/dev/null && \
			p="\"end\":$((start_sec + length_sec)),$p"
	fi

	printf '%s\n{%s}\n' "$op" "$p"
}

# --- JSON: разбор плоских полей ---
# Своего разборщика ровно столько, сколько нужно: ответы службы плоские, а
# зависимости от `jq` быть не должно — в Git Bash его нет, и на машине
# владельца это основная платформа.
#
# Ключ ищем с открывающей кавычкой и двоеточием, иначе "job" совпал бы с
# началом "job_id" и вернул чужое значение.
#
# Значение без кавычек (число, true/false) берём классом «всё до разделителя», а
# не перечислением через \| : альтернация в BRE — расширение GNU sed, и BSD sed
# на macOS считает её литералом. Подстановка тогда молча не срабатывает, функция
# возвращает пустоту вместо числа, и падает это только на macOS-джобе CI.
# Кавычка исключена из класса намеренно: пустая строка ("") обязана дать пустой
# результат, как и раньше, а не два символа кавычек.
#
# `.*"key"` — ЖАДНЫЙ префикс, то есть sed берёт ПОСЛЕДНЕЕ вхождение ключа в строке.
# Для плоского ответа это одно и то же, но ответы вложенные: у
# {"state":"running","steps":[{"state":"done"}]} поле state читалось как "done", и
# клиент считал завершённой задачу, которая ещё идёт. Берём ПЕРВОЕ вхождение: срезаем
# всё до первого `"key"` отдельным шагом, а значение вынимаем уже из хвоста.
remote_json_field() {
	local json="$1" key="$2" tail v
	# Переводы строк схлопываем: pretty-printed JSON от службы иначе не разбирается
	# построчным sed вовсе (ключ и значение оказываются на разных строках).
	json="$(printf '%s' "$json" | tr '\n' ' ')"
	case "$json" in *"\"${key}\""*) ;; *) return 0 ;; esac
	tail="${json#*\"${key}\"}"
	v="$(printf '%s' "$tail" | sed -n "s/^[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
	if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
	v="$(printf '%s' "$tail" | sed -n "s/^[[:space:]]*:[[:space:]]*\([^\",}[:space:]]\{1,\}\).*/\1/p" | head -1)"
	printf '%s' "$v"
}

# --- HTTP ---
# Бинарь берём из CURL_BIN, чтобы тест подменил его моком. Тот же приём, что
# у VOT_BIN/YTDLP_BIN в yt-dlp: без него тест ходил бы в настоящую сеть.
#
# Ответ отдаётся ДВУМЯ переменными, а не через stdout, и это не стиль, а
# необходимость: `body="$(remote_http …)"` выполняет функцию в подоболочке, и
# выставленный там REMOTE_HTTP_CODE до вызывающего не доходит вовсе — код
# ответа молча оказался бы пустым, а `!= "200"` — истинным на каждом успехе.
# Поэтому зовём БЕЗ подстановки команд и читаем REMOTE_HTTP_BODY.
#
# Bearer-ключ уходит curl'у через STDIN (`--config -`), а НЕ аргументом.
# Аргументы процесса на Linux читает любой локальный пользователь
# (/proc/<pid>/cmdline открыт по умолчанию), и окно не мгновенное: отправка
# куска в 32 МБ живёт секунды, а файл целиком — минуты. Тот же стандарт уже
# принят в yt-dlp для прокси-URL с паролем («передаётся через global PROXY_URL,
# не в argv — пароль не утекает в ps aux»), и новый код обязан ему следовать.
remote_curl_auth() {
	# Внутри кавычек curl-конфига экранируются ровно \ и " — то же правило, что и
	# в строке JSON, поэтому общий remote_escape_dq (там же — почему не подстановка).
	local k; k="$(remote_escape_dq "$remote_api_key")"
	printf 'header = "Authorization: Bearer %s"\n' "$k"
}

REMOTE_HTTP_CODE=""
REMOTE_HTTP_BODY=""
remote_http() {
	local method="$1" path="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
	local curl_bin="${CURL_BIN:-curl}"
	# --connect-timeout/--max-time обязательны: без них зависший TCP-connect держит
	# клиента до таймаута ОС (на Linux — минуты), а `remote_cancel` из trap'а Ctrl+C
	# при этом блокирует выход. Значения — для КОРОТКИХ запросов; отправка куска идёт
	# через remote_upload_chunk со своим потолком.
	local args=(-sS -X "$method" -w '\n%{http_code}'
		--connect-timeout "${REMOTE_CONNECT_TIMEOUT:-10}"
		--max-time "${REMOTE_MAX_TIME:-60}")
	local h
	for h in "$@"; do args+=(-H "$h"); done
	if [ -n "$body" ]; then
		args+=(-H "Content-Type: application/json" --data-binary "$body")
	fi
	local out err_file
	REMOTE_HTTP_BODY=""
	# stderr curl'а не выбрасываем, а сохраняем: «HTTP 000» без причины — самая
	# бесполезная строка, которую может увидеть пользователь.
	err_file="$(mktemp "${TMPDIR:-/tmp}/ffconv_curl_XXXXXX")"
	out="$(remote_curl_auth | "$curl_bin" --config - "${args[@]}" "${remote_endpoint}${path}" 2>"$err_file")" || {
		REMOTE_HTTP_CODE="000"
		local why; why="$(head -3 "$err_file" | tr '\n' ' ')"
		[ -n "$why" ] && echo "[ПРЕДУПРЕЖДЕНИЕ] curl: $why" >&2
		rm -f "$err_file"
		return 1
	}
	rm -f "$err_file"
	REMOTE_HTTP_CODE="${out##*$'\n'}"
	REMOTE_HTTP_BODY="${out%$'\n'*}"
	return 0
}

# Единая retry-политика для КОРОТКИХ запросов (poll/submit/fetch/cancel).
# До этого повтор был только у PATCH куска, и одна минутная пауза службы (рестарт,
# 502 от reverse-proxy, 429) на пакете в 200 файлов давала N провалов и N задач-сирот
# на карте. Повторяем только то, что имеет смысл повторять (remote_retryable_code),
# пауза растёт, `Retry-After` уважается.
remote_http_retry() {
	local tries="${REMOTE_HTTP_RETRIES:-4}" try=1 pause="${REMOTE_RETRY_SECONDS:-3}"
	while :; do
		remote_http "$@"
		case "$REMOTE_HTTP_CODE" in 200|201|202|204) return 0 ;; esac
		remote_retryable_code "$REMOTE_HTTP_CODE" || return 1
		[ "$try" -ge "$tries" ] && return 1
		# Retry-After в теле служба не шлёт, а заголовки мы не читаем — берём
		# растущую паузу с потолком в минуту.
		local wait_s="$pause"
		[ "$wait_s" -gt 60 ] 2>/dev/null && wait_s=60
		echo "[ПРЕДУПРЕЖДЕНИЕ] Служба ответила HTTP $REMOTE_HTTP_CODE — повтор через ${wait_s}с (попытка $((try + 1)) из $tries)." >&2
		sleep "$wait_s"
		pause=$((pause * 2))
		try=$((try + 1))
	done
}

# --- Предпусковая проверка ---
# Один раз за прогон, ДО первого файла. Всё, что может сделать невозможным
# весь прогон, должно выясниться здесь: отказать на сотом файле из двухсот
# дороже, чем на нулевом.
REMOTE_CAPS_ARGS_VERSION=""
# Потолок ожидания карты и список контейнеров — из ответа службы, а не из
# констант клиента: оба уже отвергались 400-м, но ПОСЛЕ загрузки файла.
REMOTE_CAPS_WAIT_MAX=""
REMOTE_CAPS_CONTAINERS=""
REMOTE_CAPS_ENCODERS=""
REMOTE_CHUNK_SIZE=""
# Версия сборщика аргументов, на которую рассчитан ЭТОТ клиент. Бампить вместе с
# изменением набора полей в remote_op_for_config/remote_job_body. Значение обязано
# совпадать в .sh и .ps1 — это сверяет test_23_remote_parity.sh.
REMOTE_CLIENT_ARGS_VERSION="2"

# Ключ службы из внешнего источника. Приоритет: api_key_command → api_key.
# Файл config.ini не коммитится, но остаётся в бэкапах и в синхронизируемой
# папке, а ${TRANSCODE_API_KEY} видна всему дереву процессов и оседает в истории
# оболочки. Команда (`pass show …`, `security find-generic-password`, `op read`)
# не оставляет значения ни там, ни там. Выполняется ОДИН раз, в preflight:
# менеджер паролей может спросить пароль, и делать это на каждом файле нельзя.
# Однократный кэш: --remote-selftest выполняет preflight дважды, и менеджер
# паролей спрашивал пароль два раза подряд на одном прогоне.
REMOTE_API_KEY_RESOLVED="no"
remote_resolve_api_key() {
	[ -n "${remote_api_key_command:-}" ] || return 0
	[ "$REMOTE_API_KEY_RESOLVED" = "yes" ] && return 0
	local out
	out="$(eval "$remote_api_key_command" 2>/dev/null)" || {
		echo "[ОШИБКА] [remote] api_key_command завершилась с ошибкой — ключ не получен." >&2
		return 1
	}
	# Только первая строка и без переводов: менеджеры паролей печатают '\n'.
	out="$(printf '%s' "$out" | head -1)"
	out="$(remote_normalize_endpoint "$out")"   # тот же trim пробелов
	if [ -z "$out" ]; then
		echo "[ОШИБКА] [remote] api_key_command ничего не напечатала — ключ не получен." >&2
		return 1
	fi
	remote_api_key="$out"
	REMOTE_API_KEY_RESOLVED="yes"
	return 0
}

# Семейство кодека поддержано службой? Служба перечисляет ЭНКОДЕРЫ
# (h264_nvenc, libx264, …), а мы отправляем СЕМЕЙСТВО (h264) — см.
# remote_map_codec. Поэтому сверяем по семейству: наличие h264_nvenc означает,
# что h264 служба посчитает. Сверять литерально («нет libx264 → отказ») нельзя:
# это противоречило бы самому отображению, ради которого оно и заведено.
# tr '\n' ' ' — pretty-printed JSON: без склейки строк список энкодеров, разбитый
# на строки, не находится вовсе, и «служба не объявила» принимало ЛЮБОЙ кодек.
remote_caps_encoders() {
	# Форм у поля ДВЕ, и обе законны: плоский список ["h264_nvenc", …] и объект
	# по месту счёта {"gpu":[…],"cpu":[…]} — вторую служба отдаёт с
	# args_version 2. Прежний разбор знал только первую, на второй возвращал
	# пустоту, и preflight честно печатал «служба объявила пустой список
	# энкодеров — считать нечем», хотя энкодеры в ответе были. Удалённый счёт
	# не работал вовсе, и увидеть это мог только --remote-selftest: мок curl
	# отдаёт форму v1.
	#
	# Поэтому берём ЗНАЧЕНИЕ ключа целиком (список или объект) и вынимаем из
	# него все строки в кавычках. Имена вложенных ключей ("gpu"/"cpu") сначала
	# срезаем вместе с двоеточием — иначе они попали бы в перечень наравне с
	# энкодерами и оказались бы в сообщении об ошибке.
	# Альтернацию \| в sed понимает только GNU: BSD sed на macOS считает её
	# литералом и молча возвращает пустоту — то есть ровно тот отказ, который
	# здесь и чинится. Поэтому форму выбирает оболочка, а sed зовётся под каждую
	# отдельно.
	local v
	v="$(printf '%s' "$1" | tr '\n' ' ' | sed -n 's/.*"encoders"[[:space:]]*:[[:space:]]*//p' | head -1)"
	case "$v" in
		\[*) v="$(printf '%s' "$v" | sed -n 's/^\(\[[^]]*\]\).*/\1/p')" ;;
		\{*) v="$(printf '%s' "$v" | sed -n 's/^\({[^}]*}\).*/\1/p')" ;;
		*)   return 0 ;;
	esac
	printf '%s' "$v" \
		| sed 's/"[A-Za-z_][A-Za-z0-9_]*"[[:space:]]*:[[:space:]]*//g' \
		| grep -o '"[^"]*"' | tr '\n' ' '
}

# Список контейнеров берётся из ops.transcode.values.container. Хвост режем
# от ПЕРВОГО "transcode" и в нём ищем ПЕРВЫЙ "container": у соседних операций
# (concat, remux) свои списки, и жадный поиск подставил бы чужой. Не нашли —
# молчим и ничего не проверяем: отсутствие поля не повод отказывать.
remote_caps_containers() {
	local tail
	tail="$(printf '%s' "$1" | tr '\n' ' ')"
	case "$tail" in *'"transcode"'*) ;; *) return 0 ;; esac
	tail="${tail#*\"transcode\"}"
	case "$tail" in *'"container"'*) ;; *) return 0 ;; esac
	tail="${tail#*\"container\"}"
	printf '%s' "$tail" | sed -n 's/^[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
		| grep -o '"[^"]*"' | tr '\n' ' '
}

# Пустой список ("encoders": []) и отсутствие ключа — РАЗНЫЕ вещи. Первое означает
# «служба не умеет ничего», второе — «служба ничего не сказала», и раньше оба
# приводили к «принять любой кодек».
remote_caps_declared() {
	case "$(printf '%s' "$1" | tr '\n' ' ')" in *'"encoders"'*) return 0 ;; esac
	return 1
}

remote_caps_has_codec() {
	local family="$1" list="$2"
	# Списка нет — служба его не объявила. Отказывать на этом нельзя: молчание
	# службы не то же самое, что отсутствие кодека.
	[ -n "$list" ] || return 0
	# Само семейство или энкодер с ним в префиксе: "h264", "h264_nvenc".
	case "$list" in *"\"$family\""*|*"\"${family}_"*) return 0 ;; esac
	# Программные энкодеры называются не по семейству: libx264 → h264.
	case "$family" in
		h264) case "$list" in *x264*) return 0 ;; esac ;;
		hevc) case "$list" in *x265*) return 0 ;; esac ;;
		av1)  case "$list" in *av1*) return 0 ;; esac ;;
	esac
	return 1
}

# Всё, что уезжает в JSON без кавычек, обязано быть проверено ДО загрузки гигабайт.
# Нечисловой wait_timeout («30 мин») давал невалидное тело `{"wait_timeout":30 мин}`,
# и обнаруживалось это ПОСЛЕ полной отправки файла; prefer вне списка служба
# отвергает 400 там же. Паритет с Test-RemoteConfigValues в .ps1.
remote_validate_config() {
	local ok=0
	case "${remote_wait_timeout:-1800}" in
		''|*[!0-9]*) echo "[ОШИБКА] [remote] wait_timeout должен быть целым числом секунд (получено: '${remote_wait_timeout}')." >&2; ok=1 ;;
	esac
	case "${remote_stall_timeout:-900}" in
		''|*[!0-9]*) echo "[ОШИБКА] [remote] stall_timeout должен быть целым числом секунд (получено: '${remote_stall_timeout}')." >&2; ok=1 ;;
	esac
	case "${remote_prefer:-auto}" in
		auto|gpu|cpu) ;;
		*) echo "[ОШИБКА] [remote] prefer принимает auto, gpu или cpu (получено: '${remote_prefer}')." >&2; ok=1 ;;
	esac
	case "${remote_on_failure:-abort}" in
		abort|local) ;;
		*) echo "[ОШИБКА] [remote] on_failure принимает abort или local (получено: '${remote_on_failure}')." >&2; ok=1 ;;
	esac
	if [ "$video_resolution_status" = "+" ]; then
		case "$video_resolution_value" in
			*[!0-9x]*|x*|*x) echo "[ОШИБКА] [video] resolution ожидается в виде ШИРИНАxВЫСОТА без пробелов (получено: '${video_resolution_value}')." >&2; ok=1 ;;
			*x*) ;;
			*) echo "[ОШИБКА] [video] resolution ожидается в виде ШИРИНАxВЫСОТА (получено: '${video_resolution_value}')." >&2; ok=1 ;;
		esac
	fi
	if [ "$video_bitrate_status" = "+" ]; then
		case "$video_bitrate_value" in
			''|*[!0-9]*) echo "[ОШИБКА] [video] bitrate ожидается числом в кбит/с без суффикса (получено: '${video_bitrate_value}')." >&2; ok=1 ;;
		esac
	fi
	if [ "$audio_bitrate_status" = "+" ]; then
		case "$audio_bitrate_value" in
			''|*[!0-9]*) echo "[ОШИБКА] [audio] bitrate ожидается числом в кбит/с без суффикса (получено: '${audio_bitrate_value}')." >&2; ok=1 ;;
		esac
	fi
	return $ok
}

remote_preflight() {
	remote_endpoint="$(remote_normalize_endpoint "$remote_endpoint")"
	if [ -z "$remote_endpoint" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте [remote] endpoint в config.ini (или переменную окружения TRANSCODE_URL)." >&2
		return 1
	fi
	remote_validate_config || return 1
	remote_resolve_api_key || return 1
	if [ -z "$remote_api_key" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте [remote] api_key (или api_key_command) в config.ini, либо переменную окружения TRANSCODE_API_KEY." >&2
		return 1
	fi
	if ! command -v "${CURL_BIN:-curl}" >/dev/null 2>&1; then
		echo "[ОШИБКА] Для удалённого бэкенда нужен curl, но он не найден." >&2
		return 1
	fi
	# Версия API живёт В АДРЕСЕ: клиент собирает URL как "<endpoint>/capabilities",
	# а служба слушает /v1/capabilities. Адрес без /vN даёт 404 на первом же
	# запросе, и сообщение «HTTP 404» человеку ничего не объясняет — поэтому
	# говорим о причине ДО запроса. Это предупреждение, а не отказ: за обратным
	# прокси префикс может добавляться на стороне сервера.
	case "$remote_endpoint" in
		*/v[0-9]|*/v[0-9][0-9]) ;;
		*) echo "[ПРЕДУПРЕЖДЕНИЕ] Адрес службы «${remote_endpoint}» не оканчивается версией API (/v1). Клиент запрашивает «${remote_endpoint}/capabilities», а служба слушает «/v1/capabilities» — вероятен HTTP 404." ;;
	esac
	local caps
	remote_http GET /capabilities
	caps="$REMOTE_HTTP_BODY"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба конвертации недоступна: HTTP $REMOTE_HTTP_CODE (запрошено ${remote_endpoint}/capabilities)." >&2
		[ "$REMOTE_HTTP_CODE" = "404" ] && \
			echo "[ОШИБКА] 404 на /capabilities обычно означает адрес без версии API: проверьте, что [remote] endpoint оканчивается на /v1." >&2
		return 1
	fi
	REMOTE_CAPS_ARGS_VERSION="$(remote_json_field "$caps" args_version)"
	REMOTE_CAPS_ENCODERS="$(remote_caps_encoders "$caps")"
	REMOTE_CHUNK_SIZE="$(remote_json_field "$caps" chunk_size)"
	[ -n "$REMOTE_CHUNK_SIZE" ] || REMOTE_CHUNK_SIZE=$((32 * 1024 * 1024))
	REMOTE_CAPS_WAIT_MAX="$(remote_json_field "$caps" wait_timeout_max_s)"
	REMOTE_CAPS_CONTAINERS="$(remote_caps_containers "$caps")"
	# Энкодер — здесь, а не на каждом файле. Контракт preflight именно такой:
	# «отказать на сотом файле из двухсот дороже, чем на нулевом». Раньше список
	# encoders из ответа игнорировался вовсе, а поддержку определяла статическая
	# таблица remote_map_codec внутри encode_file — то есть ровно тем способом,
	# который контракт запрещает, и вдобавок молча расходясь со службой.
	local family
	if ! family="$(remote_map_codec "$set_video_codec")"; then
		echo "[ОШИБКА] Кодек «${set_video_codec}» удалённой службе неизвестен (ожидаются h264/hevc/av1-энкодеры)." >&2
		return 1
	fi
	# Пустой список и отсутствие ключа — разные вещи: первое означает «служба не
	# умеет ничего» и обязано быть отказом, второе — «служба ничего не сказала».
	if remote_caps_declared "$caps" && [ -z "$REMOTE_CAPS_ENCODERS" ]; then
		echo "[ОШИБКА] Служба объявила пустой список энкодеров — считать нечем." >&2
		return 1
	fi
	if ! remote_caps_has_codec "$family" "$REMOTE_CAPS_ENCODERS"; then
		echo "[ОШИБКА] Служба не умеет кодек «${family}» (из [video] codec = $set_video_codec). Служба объявила: $REMOTE_CAPS_ENCODERS" >&2
		return 1
	fi
	# Потолок ожидания карты объявляет служба. Больше него — 400 на POST /jobs,
	# то есть уже ПОСЛЕ отправки файла целиком. Спрашиваем здесь.
	case "$REMOTE_CAPS_WAIT_MAX" in
		''|*[!0-9]*) ;;
		*) if [ "${remote_wait_timeout:-1800}" -gt "$REMOTE_CAPS_WAIT_MAX" ] 2>/dev/null; then
				echo "[ОШИБКА] [remote] wait_timeout = ${remote_wait_timeout} больше потолка службы (${REMOTE_CAPS_WAIT_MAX} с) — задача была бы отвергнута после загрузки файла." >&2
				return 1
			fi ;;
	esac
	# Контейнер выхода — тоже 400 после загрузки. Проверяем только когда список
	# разобран: молчание службы не повод отказывать.
	if [ -n "$REMOTE_CAPS_CONTAINERS" ]; then
		local want="mp4"
		[ "$output_container_status" = "+" ] && want="$output_container_value"
		case "$REMOTE_CAPS_CONTAINERS" in
			*"\"$want\""*) ;;
			*) echo "[ОШИБКА] Служба не умеет контейнер «${want}» (из [video] container). Служба объявила: $REMOTE_CAPS_CONTAINERS" >&2
			   return 1 ;;
		esac
	fi
	# Версия сборщика аргументов службы. Расхождение не запрещает работу, но
	# молча получить файл, собранный логикой, которой у нас нет, — хуже, чем шумно.
	# Ожидаемое значение — КОНСТАНТА клиента: раньше сверка шла только при
	# переменной окружения REMOTE_KNOWN_ARGS_VERSION, которую никто нигде не
	# задавал, то есть риск из §13 спеки не был закрыт вовсе.
	local known="${REMOTE_KNOWN_ARGS_VERSION:-$REMOTE_CLIENT_ARGS_VERSION}"
	if [ -n "$known" ] && [ -n "$REMOTE_CAPS_ARGS_VERSION" ] && \
	   [ "$REMOTE_CAPS_ARGS_VERSION" != "$known" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Служба собирает аргументы версии $REMOTE_CAPS_ARGS_VERSION, клиент рассчитан на $known. Сверьте холостой прогон (--remote-selftest)."
	fi
	return 0
}

# --- sha256 ---
# sha256sum есть в Linux и Git Bash, shasum — в macOS. Проверяем оба, потому
# что macOS заявлена в поддержке проекта.
remote_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "[ОШИБКА] Не найден ни sha256sum, ни shasum — подтвердить загрузку нечем." >&2
		return 1
	fi
}

# --- Загрузка кусками ---
# Возобновляемость — не удобство, а условие работоспособности: файлы от
# гигабайта, и одна POST-загрузка на 20 ГБ рвётся и начинается заново.
# Перед отправкой спрашиваем у службы, сколько байт она уже приняла, и льём
# только хвост.
#
# Идентификатор возвращается ПЕРЕМЕННОЙ REMOTE_UPLOAD_ID, а не через stdout —
# тем же приёмом, что REMOTE_HTTP_BODY/REMOTE_HTTP_CODE, и по зеркальной
# причине: функция ПЕЧАТАЕТ прогресс-бар, а вызов `uid="$(remote_upload …)"`
# складывал в переменную и бар, и идентификатор. Служба получала upload_id вида
# «\r  [####…]  40%  отправка…UP123», обязана была ответить 400 — и удалённый
# бэкенд в .sh не работал ни на одном файле. Тест этого не видел, потому что
# подменял show_progress_bar пустышкой: мок убирал ровно тот побочный эффект,
# который и есть дефект.

# Сохранённый идентификатор загрузки. Без него докачка недостижима в принципе:
# каждый вызов начинался с POST /uploads, то есть просил НОВУЮ загрузку, и
# GET /uploads/<свежий id> честно отвечал received: 0. Механизм докачки был, а
# воспользоваться им нечем — обрыв на 90-м проценте стоил всего файла, ровно то,
# что спека называет недопустимым. Путь задаёт вызывающий (REMOTE_UPLOAD_SIDECAR,
# рядом с manifest'ом): модуль не знает раскладки каталога назначения, а пустое
# значение просто отключает докачку между запусками (субтитры, самопроверка).
# Время изменения источника — вторая половина отпечатка. Один размер ничего не
# доказывает: подмена файла другим той же длины (перекодировка, восстановление из
# бэкапа) заставляла клиент докачивать ЧУЖИЕ байты в старую загрузку, и complete
# отвечал 409 на верно собранном по мнению клиента файле.
remote_file_mtime() {
	stat -c%Y "$1" 2>/dev/null || stat -f%m "$1" 2>/dev/null || echo 0
}

remote_upload_sidecar_read() {
	local f="$REMOTE_UPLOAD_SIDECAR" src="$1" uid="" size="" ep="" mt=""
	[ -n "$f" ] && [ -f "$f" ] || return 0
	uid="$(sed -n 's/^upload_id=//p' "$f" | head -1)"
	size="$(sed -n 's/^size=//p' "$f" | head -1)"
	ep="$(sed -n 's/^endpoint=//p' "$f" | head -1)"
	mt="$(sed -n 's/^mtime=//p' "$f" | head -1)"
	# Источник изменился или сменилась служба — прежние байты не наши.
	[ "$size" = "$(file_size "$src")" ] || return 0
	[ "$ep" = "$remote_endpoint" ] || return 0
	# Старый sidecar без mtime не отвергаем: поле добавлено позже, и жёсткая проверка
	# обесценила бы докачку ровно на тех файлах, ради которых её и писали.
	[ -z "$mt" ] || [ "$mt" = "$(remote_file_mtime "$src")" ] || return 0
	printf '%s' "$uid"
}

# Идентификатор задачи живёт рядом с идентификатором загрузки: после падения клиента
# на фазе ожидания или скачивания следующий запуск идёт сразу в GET /jobs/{id} вместо
# повторной отправки гигабайт. Дедупликация службы спасает саму задачу, но не трафик.
remote_upload_sidecar_read_job() {
	local f="$REMOTE_UPLOAD_SIDECAR"
	[ -n "$f" ] && [ -f "$f" ] || return 0
	sed -n 's/^job_id=//p' "$f" | head -1
}

remote_upload_sidecar_write_job() {
	local f="$REMOTE_UPLOAD_SIDECAR" jid="$1"
	[ -n "$f" ] && [ -f "$f" ] || return 0
	[ -n "$jid" ] || return 0
	grep -q '^job_id=' "$f" 2>/dev/null && return 0
	echo "job_id=$jid" >> "$f" 2>/dev/null || true
	return 0
}

remote_upload_sidecar_write() {
	local f="$REMOTE_UPLOAD_SIDECAR" src="$1" uid="$2"
	[ -n "$f" ] || return 0
	{
		echo "upload_id=$uid"
		echo "size=$(file_size "$src")"
		echo "mtime=$(remote_file_mtime "$src")"
		echo "endpoint=$remote_endpoint"
	} > "$f" 2>/dev/null || true
}

remote_upload_sidecar_clear() {
	[ -n "$REMOTE_UPLOAD_SIDECAR" ] && rm -f "$REMOTE_UPLOAD_SIDECAR" 2>/dev/null
	return 0
}

# Повторять имеет смысл обрыв и перегрузку, а не отказ по существу: 413 «файл
# больше предела» не станет верным с третьей попытки, а три лишних отправки
# 32 МБ стоят минут.
# Идентификаторы (upload_id/job_id) подставляются в ПУТЬ URL. Значение приходит от
# службы, но доверять ему на слово незачем: пробел или «..» в нём меняют адрес
# запроса — «../jobs/x y» адресовал бы чужой ресурс. Алфавит тот же, что у
# типичных идентификаторов служб.
remote_valid_id() {
	case "$1" in
		''|*[!A-Za-z0-9._-]*) return 1 ;;
		*..*) return 1 ;;
	esac
	return 0
}

remote_retryable_code() {
	case "$1" in
		""|000|408|429|5[0-9][0-9]) return 0 ;;
		*) return 1 ;;
	esac
}

REMOTE_UPLOAD_SIDECAR=""
REMOTE_UPLOAD_ID=""
REMOTE_UPLOAD_DURATION=""
remote_upload() {
	local file="$1" size offset=0 chunk uid="" answer
	REMOTE_UPLOAD_ID=""
	REMOTE_UPLOAD_DURATION=""
	size="$(file_size "$file")"

	uid="$(remote_upload_sidecar_read "$file")"
	if [ -n "$uid" ]; then
		# Сколько уже принято. Не 200 — идентификатор протух, начинаем заново.
		remote_http_retry GET "/uploads/$uid"
		if [ "$REMOTE_HTTP_CODE" = "200" ]; then
			offset="$(remote_json_field "$REMOTE_HTTP_BODY" received)"
			# Не число или больше файла — считаем нулём: лишний перезалив дешевле
			# пропущенного начала файла.
			[ -n "$offset" ] || offset=0
			[ "$offset" -ge 0 ] 2>/dev/null && [ "$offset" -le "$size" ] 2>/dev/null || offset=0
		else
			uid=""; offset=0
		fi
	fi

	if [ -z "$uid" ]; then
		remote_http_retry POST /uploads
		answer="$REMOTE_HTTP_BODY"
		[ "$REMOTE_HTTP_CODE" = "200" ] || {
			echo "[ОШИБКА] Служба не приняла загрузку: HTTP $REMOTE_HTTP_CODE." >&2
			return 1
		}
		uid="$(remote_json_field "$answer" upload_id)"
		[ -n "$uid" ] || { echo "[ОШИБКА] Служба не вернула upload_id." >&2; return 1; }
		# Идентификатор уезжает прямо в URL — принимаем только безопасный алфавит:
		# «../jobs/x y» из ответа службы иначе адресовал бы чужой ресурс.
		remote_valid_id "$uid" || { echo "[ОШИБКА] Служба вернула недопустимый upload_id." >&2; return 1; }
		chunk="$(remote_json_field "$answer" chunk_size)"
		[ -n "$chunk" ] && [ "$chunk" -gt 0 ] 2>/dev/null && REMOTE_CHUNK_SIZE="$chunk"
		offset=0
		remote_upload_sidecar_write "$file" "$uid"
	fi

	while [ "$offset" -lt "$size" ]; do
		local this=$((size - offset))
		[ "$this" -gt "$REMOTE_CHUNK_SIZE" ] && this="$REMOTE_CHUNK_SIZE"
		# Кусок читается с ТОЧНОГО смещения и уходит потоком (см. remote_upload_chunk).
		# Раньше здесь стоял `dd skip` в блоках размером с кусок, и комментарий
		# утверждал, что смещение всегда кратно — посылка неверна: offset приходит из
		# ответа службы (received), а кратности ей никто не обещал. При received=1500
		# и chunk=1024 клиент объявлял Content-Range 1500-2523, а отправлял байты с
		# 1024: собранный на сервере файл — мусор. tail -c +N на обычном файле делает
		# lseek, а не чтение с начала, поэтому точность здесь не стоит скорости.
		#
		# Повтор отправки куска: разрыв на 90-м проценте трёхгигабайтного файла
		# не должен стоить всего файла (спека, §8).
		local try=1 sent="no" tries="${REMOTE_UPLOAD_RETRIES:-3}"
		while [ "$try" -le "$tries" ]; do
			if remote_upload_chunk "$uid" "$file" "$offset" \
				$((offset + this - 1)) "$size"; then sent="yes"; break; fi
			remote_retryable_code "$REMOTE_HTTP_CODE" || break
			try=$((try + 1))
			if [ "$try" -le "$tries" ]; then
				echo "[ПРЕДУПРЕЖДЕНИЕ] Повтор отправки куска ${offset} (попытка $try из $tries)." >&2
				sleep "${REMOTE_RETRY_SECONDS:-3}"
			fi
		done
		[ "$sent" = "yes" ] || return 1
		offset=$((offset + this))
		remote_report_upload "$offset" "$size" "$file"
	done

	local sha; sha="$(remote_sha256 "$file")" || return 1
	remote_http POST "/uploads/$uid/complete" \
		"{\"size\":$size,\"sha256\":\"$sha\"}"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба не подтвердила загрузку: HTTP $REMOTE_HTTP_CODE." >&2
		# Sidecar здесь ОБЯЗАН исчезнуть. Он хранит upload_id, и при следующем запуске
		# клиент воскрешал ровно ту же загрузку: GET /uploads/{id} отвечал
		# received == size, куски не слались, complete снова возвращал 409 sha mismatch —
		# файл попадал в тупик до ручного удаления sidecar'а. Спека (§11) обещает
		# повтор «с нуля», и без очистки он не происходил НИКОГДА.
		remote_upload_sidecar_clear
		return 1
	fi
	# Длительность службе уже известна: файл она приняла и разобрала. Локальный
	# ffprobe остаётся основным источником, а это — запасной для тонкого клиента
	# без локального ffmpeg (см. remote_active в script.sh).
	#
	# Ответ на complete её НЕ содержит — там только upload_id и status, — поэтому
	# запасной источник был мёртв с самого начала и молча давал пустую строку.
	# Разбор входа отдаёт отдельная ручка; её отказ не фатален, ради длительности
	# ронять загрузку нельзя.
	REMOTE_UPLOAD_DURATION="$(remote_json_field "$REMOTE_HTTP_BODY" duration)"
	if [ -z "$REMOTE_UPLOAD_DURATION" ]; then
		remote_http GET "/uploads/$uid/probe"
		[ "$REMOTE_HTTP_CODE" = "200" ] && \
			REMOTE_UPLOAD_DURATION="$(remote_json_field "$REMOTE_HTTP_BODY" duration)"
	fi
	REMOTE_UPLOAD_ID="$uid"
	remote_upload_sidecar_clear
	return 0
}

# Отдельной функцией, потому что тело куска — двоичное и идёт из файла:
# --data-binary @file, а не строкой, иначе нули и переводы строк исказятся.
# Кусок уходит ПОТОКОМ со стандартного ввода (`--data-binary @-`), без temp-файла:
# прежняя схема писала на диск лишние байты в размер всего исходника — по куску за
# раз, но 20 ГБ суммарно на 20-гигабайтном файле.
#
# Ключ при этом обязан остаться вне argv (`/proc/<pid>/cmdline` читает любой
# локальный пользователь, а отправка 32-МБ куска живёт секунды). Stdin занят телом,
# поэтому конфиг подаётся ФАЙЛОМ. Process substitution `--config <(…)` здесь стоял
# раньше и не работал на главной платформе проекта: curl из Git Bash — mingw-сборка,
# она не открывает `/proc/<pid>/fd/N` и отвечает «cannot read config from …».
# Windows-отправка куска не работала НИ РАЗУ, а `2>/dev/null` превращал внятную
# жалобу curl в «обрыв связи» — сообщение уводило в сторону сети. Файл создаётся
# правами 0600 и живёт ровно один запрос.
#
# %{size_upload} обязателен: раньше «сколько байт реально отправлено» проверялось
# по размеру temp-файла, и без файла эта проверка исчезла бы. Короткое чтение с
# сетевой шары дало бы Content-Range на полную длину при неполном теле — ровно тот
# класс, из-за которого sha256 в complete не сходился без указания причины.
#
# Потолок времени свой: 32 МБ на медленном канале живут дольше REMOTE_MAX_TIME,
# рассчитанного на короткие запросы.
remote_upload_chunk() {
	local uid="$1" file="$2" from="$3" to="$4" total="$5"
	local curl_bin="${CURL_BIN:-curl}" out cfg err rc
	local this=$((to - from + 1))
	cfg="$(mktemp "${TMPDIR:-/tmp}/ffconv_auth_XXXXXX")" || {
		echo "[ОШИБКА] Не удалось создать временный файл для ключа службы." >&2
		REMOTE_HTTP_CODE="000"; return 1
	}
	# Права снимаем ДО записи ключа: между mktemp и chmod файл пуст.
	chmod 600 "$cfg" 2>/dev/null
	remote_curl_auth > "$cfg"
	# Файл для stderr создаётся БЕЗУСЛОВНО: перенаправление нельзя получить
	# раскрытием переменной. `${err:+2>"$err"}` разворачивается не в редирект, а в
	# лишний АРГУМЕНТ `2>/tmp/…`, и curl честно отвечает «URL rejected: Bad
	# hostname» — на второй URL в команде.
	err="$(mktemp "${TMPDIR:-/tmp}/ffconv_curlerr_XXXXXX")" || {
		rm -f "$cfg"
		echo "[ОШИБКА] Не удалось создать временный файл для вывода curl." >&2
		REMOTE_HTTP_CODE="000"; return 1
	}
	out="$( { tail -c "+$((from + 1))" "$file" 2>/dev/null | head -c "$this"; } | \
		"$curl_bin" --config "$cfg" -sS -X PATCH \
		--connect-timeout "${REMOTE_CONNECT_TIMEOUT:-10}" \
		--max-time "${REMOTE_CHUNK_MAX_TIME:-1800}" \
		-H "Content-Range: bytes ${from}-${to}/${total}" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@-" \
		-w '\n%{http_code} %{size_upload}' \
		"${remote_endpoint}/uploads/${uid}" 2>"$err")"
	rc=$?
	rm -f "$cfg"
	if [ "$rc" -ne 0 ]; then
		# Причину печатаем словами curl: «обрыв связи» на неудобочитаемом конфиге
		# или отказе в правах — диагноз не тот, и искать будут не там.
		local why=""
		why="$(tr '\n' ' ' < "$err" 2>/dev/null)"
		rm -f "$err"
		echo "[ОШИБКА] Не удалось отправить кусок ${from}-${to}: ${why:-curl завершился с кодом $rc}" >&2
		REMOTE_HTTP_CODE="000"
		return 1
	fi
	rm -f "$err"
	local last="${out##*$'\n'}"
	REMOTE_HTTP_CODE="${last%% *}"
	local sent_bytes="${last##* }"
	if [ "$REMOTE_HTTP_CODE" = "200" ]; then
		# Мок может не сообщать size_upload — тогда доверяем коду ответа.
		case "$sent_bytes" in
			''|*[!0-9]*) return 0 ;;
		esac
		if [ "$sent_bytes" != "$this" ]; then
			echo "[ОШИБКА] Отправлено $sent_bytes байт вместо $this (кусок ${from}-${to}) — тело куска неполное." >&2
			REMOTE_HTTP_CODE="000"
			return 1
		fi
		return 0
	fi
	echo "[ОШИБКА] Служба отвергла кусок ${from}-${to}: HTTP $REMOTE_HTTP_CODE." >&2
	return 1
}

# Прогресс загрузки — отдельная фаза. На файле в 3 ГБ по сети это и есть
# долгая часть: без своего индикатора прогресс стоял бы на нуле минутами.
# Подпись фазы идёт ТРЕТЬИМ аргументом, а имя файла — вторым: удалённый путь
# состоит из четырёх фаз, и раньше каждая называла себя по-своему (слово
# «отправка» подставлялось вместо имени файла, ожидание карты печатало свою
# строку поверх бара, скачивание не показывало ничего).
remote_report_upload() {
	local done_b="$1" total_b="$2" label="${3:-}" pct=0
	[ "$total_b" -gt 0 ] 2>/dev/null && pct=$((done_b * 100 / total_b))
	show_progress_bar "$pct" "$label" "отправка"
}

# --- Тело запроса на создание задачи ---
# Собирается в одном месте: боевой путь и холостой прогон обязаны отправлять
# одинаковое тело, иначе сверка планов проверяет не то, что поедет.
remote_job_body() {
	local uid="$1" op="$2" params="$3" sub_uid="${4:-}" extra="${5:-}"
	local p="$params"
	if [ -n "$sub_uid" ]; then
		p="${p%\}},\"subtitle_upload_id\":\"$sub_uid\"}"
	fi
	local body="{\"upload_id\":\"$uid\",\"op\":\"$op\",\"params\":$p"
	body="$body,\"prefer\":\"${remote_prefer:-auto}\""
	body="$body,\"wait_timeout\":${remote_wait_timeout:-1800}"
	# overwrite_existing = yes обязан отключить дедупликацию службы: иначе
	# «перезаписать заново» вернуло бы прежний результат с reused: true.
	[ "$overwrite_existing" = "yes" ] && body="$body,\"no_reuse\":true"
	[ -n "$extra" ] && body="$body,$extra"
	printf '%s}' "$body"
}

# Идентификатор задачи — переменной, а не через stdout, по той же причине, что и
# у remote_upload: функция зовёт log_msg (дедупликация), а тот печатает в stdout.
# `jid="$(remote_submit …)"` унёс бы строку лога в тело следующего запроса.
REMOTE_JOB_ID=""
remote_submit() {
	local answer jid
	REMOTE_JOB_ID=""
	remote_http_retry POST /jobs "$(remote_job_body "$@")"
	answer="$REMOTE_HTTP_BODY"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба отвергла задачу: HTTP $REMOTE_HTTP_CODE — $(remote_json_field "$answer" error)" >&2
		return 1
	fi
	jid="$(remote_json_field "$answer" job_id)"
	[ -n "$jid" ] || { echo "[ОШИБКА] Служба не вернула job_id." >&2; return 1; }
	remote_valid_id "$jid" || { echo "[ОШИБКА] Служба вернула недопустимый job_id." >&2; return 1; }
	[ "$(remote_json_field "$answer" reused)" = "true" ] && \
		log_msg "INFO" "Служба вернула готовый результат прежней задачи (дедупликация)"
	REMOTE_JOB_ID="$jid"
	return 0
}

# Холостой прогон НЕ загружает исходник. «Только показать команды» не имеет права
# стоить часов трафика и гигабайт в хранилище службы: загрузка шла ДО проверки
# dry_run, задача при этом не создавалась (и не освобождала место), а `mkdir -p`
# назначения при dry_run пропущен — sidecar не писался, и прерванный «холостой»
# прогон даже не докачивался. Вместо этого печатаем тело POST /jobs, которое
# поехало бы: `upload_id` в нём — плейсхолдер <pending>.
#
# План службы (§9 спеки) запрашивается только когда исходник уже загружен по
# другой причине, то есть когда вызывающий передал настоящий upload_id.
remote_dry_run() {
	local uid="$1" answer
	local body; body="$(remote_job_body "$1" "$2" "$3" "${4:-}" '"dry_run":true')"
	if [ -z "$uid" ] || [ "$uid" = "<pending>" ]; then
		echo "[DRY-RUN][REMOTE] POST ${remote_endpoint}/jobs $body"
		echo "[DRY-RUN][REMOTE] Исходник не загружен: холостой прогон не отправляет байты. План службы доступен только после реальной загрузки."
		return 0
	fi
	remote_http POST /jobs "$body"
	answer="$REMOTE_HTTP_BODY"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Холостой прогон отвергнут: HTTP $REMOTE_HTTP_CODE — $(remote_json_field "$answer" error)" >&2
		return 1
	fi
	# Печатаем ПЛАН целиком, а не одну команду: длинный файл служба режет,
	# кодирует посегментно, склеивает и отдельным проходом обрабатывает звук —
	# одной строкой это не описывается.
	echo "[DRY-RUN][REMOTE] $answer"
}

# --- Ожидание ---
# Предел ожидания КЛИЕНТСКИЙ и обязателен: `while :` без него означал, что
# задача, застрявшая в running/waiting_gpu, держит прогон вечно — на пакете в
# двести файлов это то же самое зависание, ради недопущения которого в проекте
# отказались от тихого отката на локальный ffmpeg. remote_wait_timeout уезжает
# в тело задачи и трактуется СЛУЖБОЙ; клиенту нужен свой, с запасом на очередь.
# Дедлайн считается по ЗАСТРЕВАНИЮ, а не по общему времени задачи. Прежний
# `3 × wait_timeout на всю задачу` выводил предел из параметра с другим смыслом
# (`wait_timeout` = «сколько служба ждёт окна на карте»): при wait_timeout = 60
# на любую задачу приходилось 180 с, и часовой 4K-файл отменялся при живом
# прогрессе; при prefer = cpu и умолчании 1800 отмена приходила через 90 минут,
# убивая часы серверной работы. Теперь таймер сбрасывается на каждое изменение
# state/progress: отменяем то, что действительно стоит, а не то, что долго идёт.
remote_stall_seconds() {
	local s="${remote_stall_timeout:-900}"
	[ "$s" -gt 0 ] 2>/dev/null || s=900
	printf '%s' "$s"
}

REMOTE_CURRENT_JOB=""
# Отпечаток результата из ответа службы (если она его сообщает) и признак того,
# что скачанное с ним сошлось. Читает publish_result в script.sh.
REMOTE_RESULT_SHA256=""
REMOTE_RESULT_SIZE=""
REMOTE_RESULT_VERIFIED="no"
remote_wait() {
	local jid="$1" label="$2" polls=0 answer state
	local last_change limit sig last_sig="" fails=0 maxfails="${REMOTE_POLL_MAX_FAILS:-5}"
	last_change="$(date +%s)"
	limit="$(remote_stall_seconds)"
	REMOTE_CURRENT_JOB="$jid"
	while :; do
		remote_http GET "/jobs/$jid"
		answer="$REMOTE_HTTP_BODY"
		if [ "$REMOTE_HTTP_CODE" != "200" ]; then
			# Один сбойный опрос не должен стоить файла: многочасовая задача
			# опрашивается тысячи раз, и 502 от reverse-proxy при рестарте службы
			# (или 429, или обрыв) считался фатальным — файл падал, а служба
			# продолжала кодировать результат, который никто не заберёт.
			fails=$((fails + 1))
			if [ "$fails" -ge "$maxfails" ]; then
				printf "\n"
				echo "[ОШИБКА] Состояние задачи недоступно $fails раз подряд (последний код: HTTP $REMOTE_HTTP_CODE) — отменяем задачу." >&2
				remote_cancel "$jid"
				REMOTE_CURRENT_JOB=""; return 1
			fi
			remote_retryable_code "$REMOTE_HTTP_CODE" || {
				printf "\n"
				echo "[ОШИБКА] Состояние задачи недоступно: HTTP $REMOTE_HTTP_CODE." >&2
				remote_cancel "$jid"
				REMOTE_CURRENT_JOB=""; return 1
			}
			echo "[ПРЕДУПРЕЖДЕНИЕ] Опрос задачи не удался (HTTP $REMOTE_HTTP_CODE), попытка $fails из $maxfails." >&2
			sleep "$(( ${REMOTE_POLL_SECONDS:-2} * fails ))"
			continue
		fi
		fails=0
		state="$(remote_json_field "$answer" state)"
		case "$state" in
			done)
				# Служба может назвать sha256/размер результата — запоминаем, чтобы
				# сверить скачанное без полного декода (см. remote_fetch).
				REMOTE_RESULT_SHA256="$(remote_json_field "$answer" result_sha256)"
				REMOTE_RESULT_SIZE="$(remote_json_field "$answer" result_size)"
				# Ни того, ни другого поля в состоянии задачи нет — проверка
				# скачанного была мёртвой и всегда оставляла «не сверено». Размер
				# служба сообщает отдельной ручкой перечня выходов. Берём его
				# ТОЛЬКО когда выход один: у нескольких /result отдаёт tar, и его
				# длина с суммой длин файлов не совпадает по определению.
				if [ -z "$REMOTE_RESULT_SHA256" ] && [ -z "$REMOTE_RESULT_SIZE" ]; then
					remote_http GET "/jobs/$jid/outputs"
					if [ "$REMOTE_HTTP_CODE" = "200" ] && 					   [ "$(remote_json_field "$REMOTE_HTTP_BODY" count)" = "1" ]; then
						REMOTE_RESULT_SIZE="$(remote_json_field "$REMOTE_HTTP_BODY" bytes)"
					fi
				fi
				show_progress_bar 100 "$label" "кодирование"; printf "\n"
				REMOTE_CURRENT_JOB=""; return 0 ;;
			failed|cancelled)
				printf "\n"
				echo "[ОШИБКА] Задача $state: $(remote_json_field "$answer" error)" >&2
				REMOTE_CURRENT_JOB=""; return 1 ;;
			waiting_gpu)
				# Ожидание без объяснения неотличимо от зависания, поэтому
				# показываем и сколько ждём, и сколько памяти не хватает.
				printf "\r  ожидание карты: %s с, не хватает %s МиБ            " \
					"$(remote_json_field "$answer" waiting_seconds)" \
					"$(remote_json_field "$answer" missing_mib)" ;;
			*)
				show_progress_bar "$(remote_json_field "$answer" progress)" "$label" "кодирование" ;;
		esac
		# Признак живости — пара (state, progress). Задача, честно идущая с 40 % до
		# 41 %, обязана жить дальше; зависшая на одном и том же — быть отменённой.
		sig="${state}|$(remote_json_field "$answer" progress)"
		if [ "$sig" != "$last_sig" ]; then
			last_sig="$sig"
			last_change="$(date +%s)"
		fi
		polls=$((polls + 1))
		if [ -n "${REMOTE_WAIT_MAX_POLLS:-}" ] && [ "$polls" -ge "$REMOTE_WAIT_MAX_POLLS" ]; then
			printf "\n"; REMOTE_CURRENT_JOB=""; return 1
		fi
		if [ "$(( $(date +%s) - last_change ))" -ge "$limit" ]; then
			printf "\n"
			echo "[ОШИБКА] Задача $jid не подаёт признаков движения $limit с — отменяем и считаем файл неудачным." >&2
			remote_cancel "$jid"
			REMOTE_CURRENT_JOB=""; return 1
		fi
		sleep "${REMOTE_POLL_SECONDS:-2}"
	done
}

# --- Результат ---
# Пишем сразу в целевой временный файл через curl -o: тело может быть в
# гигабайты, и держать его в переменной оболочки нельзя.
# Фаза называет себя до начала и после конца. Байтового прогресса здесь нет
# сознательно: длина результата заранее неизвестна (служба отдаёт его потоком),
# а curl -# рисует свой бар в stderr поверх нашего. Показать фазу достаточно:
# жаловались не на отсутствие процентов, а на то, что минуты «ничего не
# происходит» неотличимы от зависания.
remote_fetch() {
	local jid="$1" dst="$2" label="${3:-$2}" curl_bin="${CURL_BIN:-curl}" code
	show_progress_bar 0 "$label" "скачивание"
	code="$(remote_curl_auth | "$curl_bin" --config - -sS -X GET \
		-o "$dst" -w '%{http_code}' \
		"${remote_endpoint}/jobs/${jid}/result" 2>/dev/null)" || {
		printf "\n"
		echo "[ОШИБКА] Обрыв связи при скачивании результата." >&2
		rm -f "$dst"; return 1
	}
	REMOTE_HTTP_CODE="$code"
	if [ "$code" != "200" ]; then
		printf "\n"
		echo "[ОШИБКА] Результат недоступен: HTTP $code." >&2
		rm -f "$dst"; return 1
	fi
	show_progress_bar 100 "$label" "скачивание"; printf "\n"

	# Если служба назвала sha256/размер результата — сверяем ИХ, а не декодируем
	# файл целиком. `-f null -` на трёхгигабайтном выходе стоит минут на файл, а у
	# тонкого клиента без локального ffmpeg его нет вовсе, и проверка сводилась к
	# «файл непустой». Хеш отвечает на тот же вопрос точнее и почти бесплатно.
	# Поля нет — молчим и оставляем прежнюю проверку вызывающему.
	REMOTE_RESULT_VERIFIED="no"
	if [ -n "${REMOTE_RESULT_SHA256:-}" ]; then
		local got; got="$(remote_sha256 "$dst")" || got=""
		if [ -n "$got" ] && [ "$got" = "$REMOTE_RESULT_SHA256" ]; then
			REMOTE_RESULT_VERIFIED="yes"
		else
			echo "[ОШИБКА] Скачанный результат не совпал с sha256 службы — файл повреждён при передаче." >&2
			rm -f "$dst"; return 1
		fi
	elif [ -n "${REMOTE_RESULT_SIZE:-}" ]; then
		local sz; sz="$(file_size "$dst")"
		if [ "$sz" != "$REMOTE_RESULT_SIZE" ]; then
			echo "[ОШИБКА] Размер скачанного результата ($sz) не совпал с объявленным службой ($REMOTE_RESULT_SIZE)." >&2
			rm -f "$dst"; return 1
		fi
		REMOTE_RESULT_VERIFIED="yes"
	fi
	return 0
}

# --- Отмена ---
# Брошенная задача продолжит держать карту, ради вежливости к которой служба
# и построена. Поэтому DELETE шлём даже когда уходим по прерыванию.
remote_cancel() {
	[ -n "${1:-}" ] || return 0
	remote_http DELETE "/jobs/$1" >/dev/null 2>&1
	return 0
}

# --- Боевая самопроверка удалённого пути (--remote-selftest) ---
# Первый настоящий контакт со службой иначе происходит на пакете из двухсот
# файлов, и всё, что расходится на стыке (путь эндпоинта, версия сборщика
# аргументов, размер куска, порядок PATCH/complete, доступность энкодера),
# выясняется там же. Тестами этот стык не закрыть: мок curl — не служба.
# Один прогон на файле в мегабайт закрывает весь класс до того, как поедут
# гигабайты. Печать РАЗРЕШЁННЫХ URL целиком здесь не украшение: отсутствие
# /v1 в адресе видно глазом раньше, чем по коду 404.
remote_selftest_row() {
	printf '  %-26s %-10s %s\n' "$1" "$2" "$3"
}

remote_selftest() {
	local rc=0 t0 clip out jid="" tmpd p
	tmpd="$(mktemp -d "${TMPDIR:-/tmp}/ffconv_selftest_XXXXXX")" || return 1
	clip="$tmpd/selftest.mp4"
	out="$tmpd/selftest.out"

	echo "=== Самопроверка удалённого бэкенда ==="
	echo "Адрес службы: ${remote_endpoint:-<пусто>}"
	echo "Запрашиваемые URL:"
	for p in /capabilities /uploads "/uploads/{id}" "/uploads/{id}/complete" \
	         /jobs "/jobs/{id}" "/jobs/{id}/result"; do
		printf '  %s%s\n' "$remote_endpoint" "$p"
	done
	echo
	remote_selftest_row "шаг" "итог" "время"

	t0=$(date +%s)
	if remote_preflight; then
		remote_selftest_row "preflight" "ok" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "preflight" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		rm -rf "$tmpd"; return 1
	fi

	t0=$(date +%s)
	# testsrc + sine: пробный ролик обязан иметь и видео, и звук, иначе
	# аудио-параметры текущего config.ini на службу вообще не поедут.
	if "$ffmpeg" -nostdin -hide_banner -v error -y \
		-f lavfi -i "testsrc=size=320x240:rate=25" \
		-f lavfi -i "sine=frequency=440" \
		-t 1 -shortest -pix_fmt yuv420p "$clip" 2>/dev/null && [ -s "$clip" ]; then
		remote_selftest_row "пробный ролик" "ok" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "пробный ролик" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		rm -rf "$tmpd"; return 1
	fi

	# Докачка между запусками самопроверке не нужна: sidecar отключаем явно.
	local _saved_sidecar="$REMOTE_UPLOAD_SIDECAR"
	REMOTE_UPLOAD_SIDECAR=""
	t0=$(date +%s)
	if remote_upload "$clip"; then
		printf "\n"
		remote_selftest_row "загрузка" "ok" "$(( $(date +%s) - t0 ))с"
	else
		printf "\n"
		remote_selftest_row "загрузка" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		REMOTE_UPLOAD_SIDECAR="$_saved_sidecar"; rm -rf "$tmpd"; return 1
	fi
	REMOTE_UPLOAD_SIDECAR="$_saved_sidecar"

	local r_out r_op r_params
	if ! r_out="$(remote_op_for_config 0 0)"; then
		remote_selftest_row "параметры задачи" "ОТКАЗ" "-"
		rm -rf "$tmpd"; return 1
	fi
	r_op="$(printf '%s' "$r_out" | head -1)"
	r_params="$(printf '%s' "$r_out" | tail -1)"

	t0=$(date +%s)
	if remote_dry_run "$REMOTE_UPLOAD_ID" "$r_op" "$r_params"; then
		remote_selftest_row "холостой прогон" "ok" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "холостой прогон" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		rc=1
	fi

	t0=$(date +%s)
	if remote_submit "$REMOTE_UPLOAD_ID" "$r_op" "$r_params"; then
		jid="$REMOTE_JOB_ID"
		remote_selftest_row "задача создана" "$jid" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "задача создана" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		rm -rf "$tmpd"; return 1
	fi

	t0=$(date +%s)
	if remote_wait "$jid" "selftest" && remote_fetch "$jid" "$out" "selftest"; then
		remote_selftest_row "кодирование+скачивание" "ok" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "кодирование+скачивание" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		remote_cancel "$jid"; rm -rf "$tmpd"; return 1
	fi

	t0=$(date +%s)
	if [ -s "$out" ] && "$ffmpeg" -nostdin -v error -i "$out" -f null - 2>/dev/null; then
		remote_selftest_row "проверка результата" "ok" "$(( $(date +%s) - t0 ))с"
	else
		remote_selftest_row "проверка результата" "ОТКАЗ" "$(( $(date +%s) - t0 ))с"
		rc=1
	fi

	# Задача уже done, но DELETE освобождает её место в хранилище службы.
	remote_cancel "$jid"
	rm -rf "$tmpd"
	if [ "$rc" -eq 0 ]; then
		echo "Самопроверка пройдена: удалённый путь работает целиком."
	else
		echo "[ОШИБКА] Самопроверка выявила расхождения — см. таблицу выше." >&2
	fi
	return "$rc"
}
