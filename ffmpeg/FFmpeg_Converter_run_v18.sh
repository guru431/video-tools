#!/bin/bash

# ============================================================
# FFmpeg Converter — Конфигурация (Bash / Linux)
# ============================================================

# BASH_SOURCE[0], а не $0: при прямом запуске они совпадают, но при дот-сорсинге из
# теста $0 — это уже путь тестового файла, и SCRIPT_DIR указал бы не туда.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.ini"

# --- Авто-определение ffmpeg рядом со скриптом ---
if [ -x "$SCRIPT_DIR/ffmpeg" ]; then
	ffmpeg="$SCRIPT_DIR/ffmpeg"
elif [ -f "$SCRIPT_DIR/ffmpeg.exe" ]; then
	ffmpeg="$SCRIPT_DIR/ffmpeg.exe"
else
	ffmpeg="ffmpeg"
fi

# --- Чтение config.ini ---
read_config() {
	local key="$1"
	local section="$2"
	local default="${3:-}"

	if [ ! -f "$CONFIG_FILE" ]; then
		echo "$default"
		return
	fi

	# Регистронезависимое сравнение ключей/секций — паритет с PS1 (-match/-eq) и GUI.
	local result="$default"
	local saved_ncm; saved_ncm=$(shopt -p nocasematch)
	shopt -s nocasematch
	local in_section=false
	while IFS= read -r line || [ -n "$line" ]; do
		# Trim через bash parameter expansion (см. yt-dlp/Downloading_from_YouTube_v18.sh
		# — sed-fork на Windows Git Bash слишком медленный из-за cygwin overhead).
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		line="${line%$'\r'}"
		# UTF-8 BOM в начале файла. Notepad и часть редакторов Windows сохраняют его по
		# умолчанию, а он приклеивается к ПЕРВОЙ строке: регэксп секции ^\[…\]$ на ней
		# не совпадал, [folders] не находилась вовсе, и скрипт молча брал умолчания —
		# «[ОШИБКА] Папка источника не найдена: …/_video_/0». PS1 читал тот же файл верно.
		line="${line#$'\xEF\xBB\xBF'}"
		[[ -z "$line" || "$line" == \#* ]] && continue

		if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
			if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
				in_section=true
			else
				in_section=false
			fi
			continue
		fi

		if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
			local value="${BASH_REMATCH[1]}"
			if [[ "$value" == *" #"* ]]; then
				value="${value%% #*}"
				value="${value%"${value##*[![:space:]]}"}"
			fi
			# Подстановка ${ENV_VAR} из окружения (паритет с yt-dlp). Не задана → пусто + WARN.
			# Кроме секции [remote]: там TRANSCODE_URL/TRANSCODE_API_KEY не заданы у
			# всех, кто удалённым бэкендом не пользуется (а он выключен по умолчанию),
			# и WARN печатался бы на каждом запуске. Про незаданную переменную громко
			# говорит remote_preflight — ровно тогда, когда она действительно нужна.
			# Два ограничителя, и оба обязательны: имя обязано быть валидным
			# идентификатором (`${}` и `${A-B}` роняли `${!_vn}` с «invalid variable
			# name», значение терялось молча), и число итераций ограничено —
			# самоссылка (SELF='${SELF}' в окружении) давала вечный цикл.
			local _sub_guard=0
			while [[ "$value" == *'${'*'}'* ]] && [ "$_sub_guard" -lt 32 ]; do
				_sub_guard=$((_sub_guard + 1))
				local _vn="${value#*\$\{}"; _vn="${_vn%%\}*}"
				if [[ ! "$_vn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
					echo "WARN: '\${$_vn}' — недопустимое имя переменной окружения, оставлено как есть" >&2
					break
				fi
				[ -n "${!_vn:-}" ] || [ "$section" = "remote" ] || echo "WARN: переменная $_vn не задана" >&2
				value="${value//\$\{$_vn\}/${!_vn:-}}"
			done
			# Кавычки вокруг значения — обычный результат «Копировать как путь» в
			# проводнике Windows. Без снятия путь «"C:/video/in"» не находился ни на
			# одной платформе, а PS1 вдобавок падал исключением IsPathRooted.
			if [ ${#value} -ge 2 ]; then
				case "$value" in
					'"'*'"') value="${value#\"}"; value="${value%\"}" ;;
					"'"*"'") value="${value#\'}"; value="${value%\'}" ;;
				esac
			fi
			# ПЕРВОЕ вхождение ключа — контракт (объявлен в комментарии run_v18.ps1).
			# `break` фиксирует его здесь, ContainsKey-guard — в PS1 и GUI,
			# `if not defined` — в CMD. Дубликат ключа не имеет права давать разные
			# кодеки на разных платформах из одного config.ini.
			result="$value"
			break
		fi
	done < "$CONFIG_FILE"

	eval "$saved_ncm"
	echo "$result"
}

# Конвертирует формат config.ini (+value / -value) в формат скрипта (:+:value / :-:value)
to_flag() {
	local val="$1"
	local default="$2"
	if [ -z "$val" ]; then echo "$default"; return; fi
	local first="${val:0:1}"
	local rest="${val:1}"
	case "$first" in
		+) echo ":+:$rest" ;;
		-) echo ":-:$rest" ;;
		*) echo ":+:$val" ;;
	esac
}

# --- Загрузка настроек из config.ini ---
folder_sources="$(read_config "source" "folders" "_video_/0")"
folder_destination="$(read_config "destination" "folders" "_video_/1")"
# Нормализуем Windows-разделители (стоковый config содержит "_video_\0").
folder_sources="${folder_sources//\\//}"
folder_destination="${folder_destination//\\//}"
# Абсолютным считаем POSIX-путь (/...) и Windows-диск (C:...); иначе резолвим от папки скрипта.
case "$folder_sources" in
	/*|[A-Za-z]:*) ;;
	*) folder_sources="$SCRIPT_DIR/$folder_sources" ;;
esac
case "$folder_destination" in
	/*|[A-Za-z]:*) ;;
	*) folder_destination="$SCRIPT_DIR/$folder_destination" ;;
esac

audio_only="$(read_config "audio_only" "options" "no")"
merge_files="$(read_config "merge_files" "options" "no")"
create_frame="$(read_config "create_frame" "options" "no")"
copy_codecs="$(read_config "copy_codecs" "options" "no")"
extract_audio_copy="$(read_config "extract_audio_copy" "options" "no")"
overwrite_existing="$(read_config "overwrite_existing" "options" "no")"

audio_codec="$(to_flag "$(read_config "codec" "audio" "+aac")" ":+:aac")"
audio_number_channels="$(to_flag "$(read_config "channels" "audio" "+2")" ":+:2")"
audio_bitrate="$(to_flag "$(read_config "bitrate" "audio" "+128")" ":+:128")"
audio_sampling_rate="$(to_flag "$(read_config "sampling_rate" "audio" "+48000")" ":+:48000")"
audio_normalize="$(to_flag "$(read_config "normalize" "audio" "-loudnorm")" ":-:loudnorm")"

video_codec="$(to_flag "$(read_config "codec" "video" "+libx264")" ":+:libx264")"
video_resolution="$(to_flag "$(read_config "resolution" "video" "+1280x720")" ":+:1280x720")"
video_bitrate="$(to_flag "$(read_config "bitrate" "video" "-3000")" ":-:3000")"
video_number_frames="$(to_flag "$(read_config "framerate" "video" "+30")" ":+:30")"
video_rotation="$(to_flag "$(read_config "rotation" "video" "-2")" ":-:2")"
video_subtitles="$(to_flag "$(read_config "subtitles" "video" "-burn")" ":-:burn")"
video_quality="$(to_flag "$(read_config "quality" "video" "-23")" ":-:23")"
keep_aspect_ratio="$(to_flag "$(read_config "keep_aspect_ratio" "video" "+yes")" ":+:yes")"
output_container="$(to_flag "$(read_config "container" "video" "+mp4")" ":+:mp4")"

multithreads="$(to_flag "$(read_config "threads" "performance" "+4")" ":+:4")"
parallel_files="$(to_flag "$(read_config "parallel_files" "performance" "-2")" ":-:2")"

hw_accel="$(to_flag "$(read_config "hw_accel" "gpu" "-intel")" ":-:intel")"
gpu_preset="$(to_flag "$(read_config "preset" "gpu" "-p5")" ":-:p5")"
gpu_tune="$(to_flag "$(read_config "tune" "gpu" "-hq")" ":-:hq")"
gpu_rc="$(to_flag "$(read_config "rc" "gpu" "-vbr")" ":-:vbr")"

playback_speed="$(to_flag "$(read_config "playback_speed" "speed" "-1.0")" ":-:1.0")"

start_coding="$(to_flag "$(read_config "start" "split" "-01-00-00")" ":-:01-00-00")"
length_coding="$(to_flag "$(read_config "length" "split" "-00-05-00")" ":-:00-05-00")"
split_by_silence="$(read_config "split_by_silence" "split" "no")"
silence_duration="$(read_config "silence_duration" "split" "2.0")"
silence_threshold="$(read_config "silence_threshold" "split" "-30dB")"

remote_enabled="$(read_config "enabled" "remote" "no")"
remote_endpoint="$(read_config "endpoint" "remote" "")"
remote_api_key="$(read_config "api_key" "remote" "")"
remote_api_key_command="$(read_config "api_key_command" "remote" "")"
remote_prefer="$(read_config "prefer" "remote" "auto")"
remote_wait_timeout="$(read_config "wait_timeout" "remote" "1800")"
remote_stall_timeout="$(read_config "stall_timeout" "remote" "900")"
remote_on_failure="$(read_config "on_failure" "remote" "abort")"
# Нормализация адреса живёт в ОДНОМ месте на платформу — remote_normalize_endpoint
# в remote_client.sh, вызывается из remote_preflight. Здесь её нет намеренно:
# раньше `${x%/}` снимал один хвостовой слэш, TrimEnd в PS1 — все, а Trim пробелов
# был только в GUI, и один config.ini давал разные адреса на разных входах.

save_old_extension="$(read_config "save_old_extension" "other" "no")"
format_files_in="$(read_config "format_files_in" "other" "3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac")"
subtitles_style="$(read_config "subtitles_style" "other" "FontName=Arial,FontSize=24,PrimaryColour=&HFFFFFF&")"
dry_run="$(read_config "dry_run" "other" "no")"
enable_log="$(read_config "enable_log" "other" "no")"
log_file="$(read_config "log_file" "other" "ffmpeg_convert.log")"
# F28. Относительный log_file резолвим от папки скрипта — как source/destination выше.
# Иначе лог уезжал в текущий cwd процесса: запуск из другого каталога (ярлык, cron,
# планировщик) раскидывал ffmpeg_convert.log по случайным местам, хотя контракт
# обещает script-relative пути для всех относительных значений config.ini.
log_file="${log_file//\\//}"
case "$log_file" in
	/*|[A-Za-z]:*) ;;
	*) log_file="$SCRIPT_DIR/$log_file" ;;
esac

# --- Диагностика окружения (--doctor) ---
# Одна команда вместо разрозненных отказов на разных стадиях: без ffmpeg прогон
# падает на первом файле, без curl/sha256 — на первой удалённой задаче, а адрес
# службы без /vN даёт 404, о котором сказать больше нечего. Отчёт печатает, ЧТО
# именно перестаёт работать без каждого инструмента, — это и есть недостающее.
ffconv_doctor() {
	echo ""
	echo "═══ Проверка окружения (ffmpeg) ═══"
	echo ""
	echo "Каталог скрипта: $SCRIPT_DIR"
	echo "Конфиг:          $CONFIG_FILE$([ -f "$CONFIG_FILE" ] || printf ' (нет — используются умолчания)')"
	echo ""
	echo "  инструмент     статус   путь / версия · что без него не работает"
	echo "  -------------- -------- -------------------------------------------"

	local rc=0 p v
	if p="$(command -v "$ffmpeg" 2>/dev/null)"; then
		v="$("$ffmpeg" -version 2>/dev/null | head -1)"
		printf '  %-14s %-8s %s\n' "ffmpeg" "есть" "${v:-$p}"
	else
		if [ "$remote_enabled" = "yes" ]; then
			printf '  %-14s %-8s %s\n' "ffmpeg" "НЕТ" "тонкий клиент: считает служба; локально недоступны проверка результата и длительность"
		else
			printf '  %-14s %-8s %s\n' "ffmpeg" "НЕТ" "КОНВЕРТАЦИЯ НЕВОЗМОЖНА — это основной инструмент"
			rc=1
		fi
	fi

	if [ "$remote_enabled" = "yes" ]; then
		if p="$(command -v "${CURL_BIN:-curl}" 2>/dev/null)"; then
			printf '  %-14s %-8s %s\n' "curl" "есть" "$p"
		else
			printf '  %-14s %-8s %s\n' "curl" "НЕТ" "удалённый бэкенд не работает вовсе"
			rc=1
		fi
		if p="$(command -v sha256sum 2>/dev/null || command -v shasum 2>/dev/null)"; then
			printf '  %-14s %-8s %s\n' "sha256" "есть" "$p"
		else
			printf '  %-14s %-8s %s\n' "sha256" "НЕТ" "нечем подтвердить загрузку службе (POST /uploads/{id}/complete)"
			rc=1
		fi
	fi

	echo ""
	echo "Настройки, влияющие на раскладку файлов и на то, где идёт счёт:"
	echo "  Источник:    $folder_sources$([ -d "$folder_sources" ] || printf '   ← каталога НЕТ')"
	echo "  Назначение:  $folder_destination"
	echo "  Расширения:  $format_files_in"
	echo "  Лог:         $([ "$enable_log" = "yes" ] && printf '%s' "$log_file" || printf 'выключен')"
	echo "  Удалённый:   $remote_enabled$([ "$remote_enabled" = "yes" ] && printf ' → %s' "${remote_endpoint:-<адрес не задан>}")"
	if [ "$remote_enabled" = "yes" ]; then
		case "$remote_endpoint" in
			*/v[0-9]|*/v[0-9][0-9]) ;;
			"") echo "  ВНИМАНИЕ:    адрес службы пуст — задайте [remote] endpoint" ;;
			*)  echo "  ВНИМАНИЕ:    адрес без версии API (/v1) — вероятен HTTP 404 на /capabilities" ;;
		esac
		if [ -n "$remote_api_key_command" ]; then
			echo "  Ключ:        из команды api_key_command (значение не печатаем)"
		elif [ -n "$remote_api_key" ]; then
			echo "  Ключ:        задан (значение не печатаем)"
		else
			echo "  ВНИМАНИЕ:    ключ службы пуст — задайте [remote] api_key или api_key_command"
		fi
	fi
	echo ""
	if [ "$rc" -eq 0 ]; then
		echo "Обязательные инструменты на месте."
	else
		echo "Не хватает обязательных инструментов — см. таблицу выше."
	fi
	return $rc
}

# start coding #
# Гард запускает конвейер только при ПРЯМОМ запуске. Дот-сорсинг отдаёт настоящие
# read_config/to_flag тестам, которые раньше держали у себя inline-копию. Копия успела
# разойтись с оригиналом: в ней не было подстановки ${ENV_VAR}, то есть тест «парсера
# конфига» эту ветку не проверял вовсе, а сломать её в production можно было незаметно.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	# Единственный флаг командной строки. Боевая проверка удалённого пути на
	# пробном ролике: иначе первый настоящий контакт со службой происходит на
	# пакете из двухсот файлов, и всё, что расходится на стыке, выясняется там же.
	for _arg in "$@"; do
		case "$_arg" in
			--remote-selftest) export FFCONV_REMOTE_SELFTEST=1 ;;
			--doctor) ffconv_doctor; exit $? ;;
			-h|--help)
				echo "Использование: $(basename "${BASH_SOURCE[0]}") [--remote-selftest] [--doctor]"
				echo "  --remote-selftest  прогнать удалённый путь целиком на пробном ролике и выйти"
				echo "  --doctor           отчёт об окружении: что найдено, где и что без него не работает"
				exit 0 ;;
			*)
				echo "Неизвестный аргумент: $_arg (см. --help)" >&2
				exit 1 ;;
		esac
	done
	if [ ! -f "${SCRIPT_DIR}/FFmpeg_Converter_script.sh" ]; then
		echo "Ошибка: не найден FFmpeg_Converter_script.sh рядом с этим файлом." >&2
		exit 1
	fi
	source "${SCRIPT_DIR}/FFmpeg_Converter_script.sh"
fi
