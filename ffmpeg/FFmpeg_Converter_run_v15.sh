#!/bin/bash

# ============================================================
# FFmpeg Converter — Конфигурация (Bash / Linux)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
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
		# Trim через bash parameter expansion (см. yt-dlp/Downloading_from_YouTube_v15.sh
		# — sed-fork на Windows Git Bash слишком медленный из-за cygwin overhead).
		line="${line#"${line%%[![:space:]]*}"}"
		line="${line%"${line##*[![:space:]]}"}"
		line="${line%$'\r'}"
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
			while [[ "$value" == *'${'*'}'* ]]; do
				local _vn="${value#*\$\{}"; _vn="${_vn%%\}*}"
				[ -n "${!_vn:-}" ] || echo "WARN: переменная $_vn не задана" >&2
				value="${value//\$\{$_vn\}/${!_vn:-}}"
			done
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

save_old_extension="$(read_config "save_old_extension" "other" "no")"
format_files_in="$(read_config "format_files_in" "other" "3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac")"
subtitles_style="$(read_config "subtitles_style" "other" "FontName=Arial,FontSize=24,PrimaryColour=&HFFFFFF&")"
dry_run="$(read_config "dry_run" "other" "no")"
enable_log="$(read_config "enable_log" "other" "no")"
log_file="$(read_config "log_file" "other" "ffmpeg_convert.log")"

# start coding #
if [ ! -f "${SCRIPT_DIR}/FFmpeg_Converter_script.sh" ]; then
	echo "Ошибка: не найден FFmpeg_Converter_script.sh рядом с этим файлом." >&2
	exit 1
fi
source "${SCRIPT_DIR}/FFmpeg_Converter_script.sh"
