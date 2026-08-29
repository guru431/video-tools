#!/bin/bash
# ============================================================
# Удалённый бэкенд — клиент службы конвертации (Bash)
#
# Подключается из FFmpeg_Converter_script.sh. Ничего не запускает сам:
# только функции. Так модуль можно дот-сорсить в тест без сети и без
# побочных эффектов — тем же приёмом, что и run-файлы.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

# --- JSON: сборка ---
# Экранируем ровно два символа, которые ломают строковый литерал JSON.
# Управляющие символы в наших значениях (кодеки, разрешения, стиль ASS)
# не встречаются: их бы отверг белый список службы ещё раньше.
#
# Обратный слэш заменяется ЧЕРЕЗ ПЕРЕМЕННУЮ ("$bs"), а не литералом в шаблоне.
# Написанное «в лоб» `${s//\\/\\\\}` разбирается bash не как «\ → \\»: слэш
# внутри шаблона он считает разделителем ещё до снятия экранирования, и
# выражение вырождается в «удалить подстроку /\». Проверено: вход a\b"c/\d
# давал a\b\"cd — потеря данных и невалидный JSON одним движением. Кавычки в
# ${…} снимают и глоббинг: '\' — это класс-заготовка для шаблонов, а не текст.
remote_json_escape() {
	local s="$1"
	local bs='\'
	s="${s//"$bs"/"$bs$bs"}"
	s="${s//\"/$bs\"}"
	printf '%s' "$s"
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
	local start_sec="${1:-0}" length_sec="${2:-0}"
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
	if [ "$keep_aspect_ratio_value" = "yes" ]; then
		p="$p,\"keep_aspect\":true"
	else
		p="$p,\"keep_aspect\":false"
	fi
	[ "$video_number_frames_status" = "+" ] && p="$p,\"fps\":$video_number_frames_value"
	[ "$video_rotation_status" = "+" ]      && p="$p,\"rotate\":\"$video_rotation_value\""
	# speed=1.0 не отправляем: это умолчание службы, и лишнее поле только
	# расширяет площадь расхождения при сверке холостых прогонов.
	if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
		p="$p,\"speed\":$playback_speed_value"
	fi

	if [ "$video_subtitles_status" = "+" ]; then
		p="$p,\"subtitles\":\"$video_subtitles_value\""
		[ -n "$subtitles_style" ] && \
			p="$p,\"subtitle_style\":\"$(remote_json_escape "$subtitles_style")\""
	fi

	p="$p,\"container\":\"$output_container_value\""
	p="$p,\"threads\":${threads:-4}"

	[ "$gpu_preset_status" = "+" ] && p="$p,\"preset\":\"$gpu_preset_value\""
	[ "$gpu_tune_status" = "+" ]   && p="$p,\"tune\":\"$gpu_tune_value\""
	[ "$gpu_rc_status" = "+" ]     && p="$p,\"rc\":\"$gpu_rc_value\""

	local a="\"codec\":\"${audio_codec_value}\""
	[ "$audio_codec_status" = "+" ] || a="\"codec\":\"copy\""
	[ "$audio_bitrate_status" = "+" ]         && a="$a,\"bitrate\":$audio_bitrate_value"
	[ "$audio_number_channels_status" = "+" ] && a="$a,\"channels\":$audio_number_channels_value"
	[ "$audio_sampling_rate_status" = "+" ]   && a="$a,\"rate\":$audio_sampling_rate_value"
	[ "$audio_normalize_status" = "+" ]       && a="$a,\"normalize\":\"$audio_normalize_value\""
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
remote_json_field() {
	local json="$1" key="$2" v
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
	if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([^\",}[:space:]]\{1,\}\).*/\1/p" | head -1)"
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
	local k="$remote_api_key" bs='\'
	# Внутри кавычек curl-конфига экранируются ровно \ и " (см. curl.1, --config).
	k="${k//"$bs"/"$bs$bs"}"
	k="${k//\"/$bs\"}"
	printf 'header = "Authorization: Bearer %s"\n' "$k"
}

REMOTE_HTTP_CODE=""
REMOTE_HTTP_BODY=""
remote_http() {
	local method="$1" path="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
	local curl_bin="${CURL_BIN:-curl}"
	local args=(-sS -X "$method" -w '\n%{http_code}')
	local h
	for h in "$@"; do args+=(-H "$h"); done
	if [ -n "$body" ]; then
		args+=(-H "Content-Type: application/json" --data-binary "$body")
	fi
	local out
	REMOTE_HTTP_BODY=""
	out="$(remote_curl_auth | "$curl_bin" --config - "${args[@]}" "${remote_endpoint}${path}" 2>/dev/null)" || {
		REMOTE_HTTP_CODE="000"; return 1
	}
	REMOTE_HTTP_CODE="${out##*$'\n'}"
	REMOTE_HTTP_BODY="${out%$'\n'*}"
	return 0
}

# --- Предпусковая проверка ---
# Один раз за прогон, ДО первого файла. Всё, что может сделать невозможным
# весь прогон, должно выясниться здесь: отказать на сотом файле из двухсот
# дороже, чем на нулевом.
REMOTE_CAPS_ARGS_VERSION=""
REMOTE_CAPS_ENCODERS=""
REMOTE_CHUNK_SIZE=""

# Ключ службы из внешнего источника. Приоритет: api_key_command → api_key.
# Файл config.ini не коммитится, но остаётся в бэкапах и в синхронизируемой
# папке, а ${TRANSCODE_API_KEY} видна всему дереву процессов и оседает в истории
# оболочки. Команда (`pass show …`, `security find-generic-password`, `op read`)
# не оставляет значения ни там, ни там. Выполняется ОДИН раз, в preflight:
# менеджер паролей может спросить пароль, и делать это на каждом файле нельзя.
remote_resolve_api_key() {
	[ -n "${remote_api_key_command:-}" ] || return 0
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
	return 0
}

# Семейство кодека поддержано службой? Служба перечисляет ЭНКОДЕРЫ
# (h264_nvenc, libx264, …), а мы отправляем СЕМЕЙСТВО (h264) — см.
# remote_map_codec. Поэтому сверяем по семейству: наличие h264_nvenc означает,
# что h264 служба посчитает. Сверять литерально («нет libx264 → отказ») нельзя:
# это противоречило бы самому отображению, ради которого оно и заведено.
remote_caps_encoders() {
	printf '%s' "$1" | sed -n 's/.*"encoders"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -1
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

remote_preflight() {
	remote_endpoint="$(remote_normalize_endpoint "$remote_endpoint")"
	if [ -z "$remote_endpoint" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте [remote] endpoint в config.ini (или переменную окружения TRANSCODE_URL)." >&2
		return 1
	fi
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
	if ! remote_caps_has_codec "$family" "$REMOTE_CAPS_ENCODERS"; then
		echo "[ОШИБКА] Служба не умеет кодек «${family}» (из [video] codec = $set_video_codec). Служба объявила: $REMOTE_CAPS_ENCODERS" >&2
		return 1
	fi
	# Версия сборщика аргументов службы. Расхождение не запрещает работу, но
	# молча получить файл, собранный логикой, которой у нас нет, — хуже, чем шумно.
	if [ -n "${REMOTE_KNOWN_ARGS_VERSION:-}" ] && \
	   [ "$REMOTE_CAPS_ARGS_VERSION" != "$REMOTE_KNOWN_ARGS_VERSION" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Служба собирает аргументы версии $REMOTE_CAPS_ARGS_VERSION, клиент рассчитан на $REMOTE_KNOWN_ARGS_VERSION. Сверьте холостой прогон."
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
remote_upload_sidecar_read() {
	local f="$REMOTE_UPLOAD_SIDECAR" src="$1" uid="" size="" ep=""
	[ -n "$f" ] && [ -f "$f" ] || return 0
	uid="$(sed -n 's/^upload_id=//p' "$f" | head -1)"
	size="$(sed -n 's/^size=//p' "$f" | head -1)"
	ep="$(sed -n 's/^endpoint=//p' "$f" | head -1)"
	# Источник изменился или сменилась служба — прежние байты не наши.
	[ "$size" = "$(file_size "$src")" ] || return 0
	[ "$ep" = "$remote_endpoint" ] || return 0
	printf '%s' "$uid"
}

remote_upload_sidecar_write() {
	local f="$REMOTE_UPLOAD_SIDECAR" src="$1" uid="$2"
	[ -n "$f" ] || return 0
	{
		echo "upload_id=$uid"
		echo "size=$(file_size "$src")"
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
		remote_http GET "/uploads/$uid"
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
		remote_http POST /uploads
		answer="$REMOTE_HTTP_BODY"
		[ "$REMOTE_HTTP_CODE" = "200" ] || {
			echo "[ОШИБКА] Служба не приняла загрузку: HTTP $REMOTE_HTTP_CODE." >&2
			return 1
		}
		uid="$(remote_json_field "$answer" upload_id)"
		[ -n "$uid" ] || { echo "[ОШИБКА] Служба не вернула upload_id." >&2; return 1; }
		chunk="$(remote_json_field "$answer" chunk_size)"
		[ -n "$chunk" ] && [ "$chunk" -gt 0 ] 2>/dev/null && REMOTE_CHUNK_SIZE="$chunk"
		offset=0
		remote_upload_sidecar_write "$file" "$uid"
	fi

	local tmp_chunk
	tmp_chunk="$(mktemp "${TMPDIR:-/tmp}/ffconv_chunk_XXXXXX")"
	while [ "$offset" -lt "$size" ]; do
		local this=$((size - offset))
		[ "$this" -gt "$REMOTE_CHUNK_SIZE" ] && this="$REMOTE_CHUNK_SIZE"
		# Кусок читается с ТОЧНОГО смещения. Раньше здесь стоял `dd skip` в блоках
		# размером с кусок, и комментарий утверждал, что смещение всегда кратно —
		# посылка неверна: offset приходит из ответа службы (received), а кратности
		# ей никто не обещал. При received=1500 и chunk=1024 клиент объявлял
		# Content-Range 1500-2523, а отправлял байты с 1024: собранный на сервере
		# файл — мусор, и sha256 в complete не сходился без указания на причину.
		# tail -c +N на обычном файле делает lseek, а не чтение с начала, поэтому
		# точность здесь не стоит скорости (в отличие от dd bs=1 skip=$offset).
		tail -c "+$((offset + 1))" "$file" 2>/dev/null | head -c "$this" > "$tmp_chunk"
		local got; got="$(file_size "$tmp_chunk")"
		if [ "$got" != "$this" ]; then
			echo "[ОШИБКА] Прочитано $got байт вместо $this со смещения $offset — отправка прервана." >&2
			rm -f "$tmp_chunk"; return 1
		fi
		# Повтор отправки куска: разрыв на 90-м проценте трёхгигабайтного файла
		# не должен стоить всего файла (спека, §8).
		local try=1 sent="no" tries="${REMOTE_UPLOAD_RETRIES:-3}"
		while [ "$try" -le "$tries" ]; do
			if remote_upload_chunk "$uid" "$tmp_chunk" "$offset" \
				$((offset + this - 1)) "$size"; then sent="yes"; break; fi
			remote_retryable_code "$REMOTE_HTTP_CODE" || break
			try=$((try + 1))
			if [ "$try" -le "$tries" ]; then
				echo "[ПРЕДУПРЕЖДЕНИЕ] Повтор отправки куска ${offset} (попытка $try из $tries)." >&2
				sleep "${REMOTE_RETRY_SECONDS:-3}"
			fi
		done
		[ "$sent" = "yes" ] || { rm -f "$tmp_chunk"; return 1; }
		offset=$((offset + this))
		remote_report_upload "$offset" "$size" "$file"
	done
	rm -f "$tmp_chunk"

	local sha; sha="$(remote_sha256 "$file")" || return 1
	remote_http POST "/uploads/$uid/complete" \
		"{\"size\":$size,\"sha256\":\"$sha\"}"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба не подтвердила загрузку: HTTP $REMOTE_HTTP_CODE." >&2
		return 1
	fi
	# Длительность службе уже известна: файл она приняла и разобрала. Локальный
	# ffprobe остаётся основным источником, а это — запасной для тонкого клиента
	# без локального ffmpeg (см. remote_active в script.sh).
	REMOTE_UPLOAD_DURATION="$(remote_json_field "$REMOTE_HTTP_BODY" duration)"
	REMOTE_UPLOAD_ID="$uid"
	remote_upload_sidecar_clear
	return 0
}

# Отдельной функцией, потому что тело куска — двоичное и идёт из файла:
# --data-binary @file, а не строкой, иначе нули и переводы строк исказятся.
# Ключ, как и везде, уходит через stdin (--config -), а не аргументом.
remote_upload_chunk() {
	local uid="$1" chunk_file="$2" from="$3" to="$4" total="$5"
	local curl_bin="${CURL_BIN:-curl}" out
	out="$(remote_curl_auth | "$curl_bin" --config - -sS -X PATCH \
		-H "Content-Range: bytes ${from}-${to}/${total}" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$chunk_file" \
		-w '\n%{http_code}' \
		"${remote_endpoint}/uploads/${uid}" 2>/dev/null)" || {
		echo "[ОШИБКА] Обрыв связи при отправке куска ${from}-${to}." >&2
		REMOTE_HTTP_CODE="000"
		return 1
	}
	REMOTE_HTTP_CODE="${out##*$'\n'}"
	[ "$REMOTE_HTTP_CODE" = "200" ] && return 0
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
	remote_http POST /jobs "$(remote_job_body "$@")"
	answer="$REMOTE_HTTP_BODY"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба отвергла задачу: HTTP $REMOTE_HTTP_CODE — $(remote_json_field "$answer" error)" >&2
		return 1
	fi
	jid="$(remote_json_field "$answer" job_id)"
	[ -n "$jid" ] || { echo "[ОШИБКА] Служба не вернула job_id." >&2; return 1; }
	[ "$(remote_json_field "$answer" reused)" = "true" ] && \
		log_msg "INFO" "Служба вернула готовый результат прежней задачи (дедупликация)"
	REMOTE_JOB_ID="$jid"
	return 0
}

remote_dry_run() {
	local answer
	remote_http POST /jobs "$(remote_job_body "$1" "$2" "$3" "${4:-}" '"dry_run":true')"
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
remote_wait_deadline_seconds() {
	local base="${remote_wait_timeout:-1800}"
	[ "$base" -gt 0 ] 2>/dev/null || base=1800
	printf '%s' "$((base * ${REMOTE_WAIT_FACTOR:-3}))"
}

REMOTE_CURRENT_JOB=""
remote_wait() {
	local jid="$1" label="$2" polls=0 answer state
	local started limit
	started="$(date +%s)"
	limit="$(remote_wait_deadline_seconds)"
	REMOTE_CURRENT_JOB="$jid"
	while :; do
		remote_http GET "/jobs/$jid"
		answer="$REMOTE_HTTP_BODY"
		if [ "$REMOTE_HTTP_CODE" != "200" ]; then
			echo "[ОШИБКА] Состояние задачи недоступно: HTTP $REMOTE_HTTP_CODE." >&2
			REMOTE_CURRENT_JOB=""; return 1
		fi
		state="$(remote_json_field "$answer" state)"
		case "$state" in
			done)
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
		polls=$((polls + 1))
		if [ -n "${REMOTE_WAIT_MAX_POLLS:-}" ] && [ "$polls" -ge "$REMOTE_WAIT_MAX_POLLS" ]; then
			printf "\n"; REMOTE_CURRENT_JOB=""; return 1
		fi
		if [ "$(( $(date +%s) - started ))" -ge "$limit" ]; then
			printf "\n"
			echo "[ОШИБКА] Задача $jid не завершилась за $limit с — отменяем и считаем файл неудачным." >&2
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
