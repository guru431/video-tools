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
remote_json_escape() {
	local s="$1"
	s="${s//\/\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
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
remote_json_field() {
	local json="$1" key="$2" v
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
	if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([-0-9.]\{1,\}\|true\|false\).*/\1/p" | head -1)"
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
REMOTE_HTTP_CODE=""
REMOTE_HTTP_BODY=""
remote_http() {
	local method="$1" path="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
	local curl_bin="${CURL_BIN:-curl}"
	local args=(-sS -X "$method" -H "Authorization: Bearer ${remote_api_key}" -w '\n%{http_code}')
	local h
	for h in "$@"; do args+=(-H "$h"); done
	if [ -n "$body" ]; then
		args+=(-H "Content-Type: application/json" --data-binary "$body")
	fi
	local out
	REMOTE_HTTP_BODY=""
	out="$("$curl_bin" "${args[@]}" "${remote_endpoint}${path}" 2>/dev/null)" || {
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
REMOTE_CHUNK_SIZE=""
remote_preflight() {
	if [ -z "$remote_endpoint" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте переменную окружения TRANSCODE_URL." >&2
		return 1
	fi
	if [ -z "$remote_api_key" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте переменную окружения TRANSCODE_API_KEY." >&2
		return 1
	fi
	if ! command -v "${CURL_BIN:-curl}" >/dev/null 2>&1; then
		echo "[ОШИБКА] Для удалённого бэкенда нужен curl, но он не найден." >&2
		return 1
	fi
	local caps
	remote_http GET /capabilities
	caps="$REMOTE_HTTP_BODY"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба конвертации недоступна: HTTP $REMOTE_HTTP_CODE." >&2
		return 1
	fi
	REMOTE_CAPS_ARGS_VERSION="$(remote_json_field "$caps" args_version)"
	REMOTE_CHUNK_SIZE="$(remote_json_field "$caps" chunk_size)"
	[ -n "$REMOTE_CHUNK_SIZE" ] || REMOTE_CHUNK_SIZE=$((32 * 1024 * 1024))
	# Версия сборщика аргументов службы. Расхождение не запрещает работу, но
	# молча получить файл, собранный логикой, которой у нас нет, — хуже, чем шумно.
	if [ -n "${REMOTE_KNOWN_ARGS_VERSION:-}" ] && \
	   [ "$REMOTE_CAPS_ARGS_VERSION" != "$REMOTE_KNOWN_ARGS_VERSION" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Служба собирает аргументы версии $REMOTE_CAPS_ARGS_VERSION, клиент рассчитан на $REMOTE_KNOWN_ARGS_VERSION. Сверьте холостой прогон."
	fi
	return 0
}
