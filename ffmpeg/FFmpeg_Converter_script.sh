#!/bin/bash

# ============================================================
# FFmpeg Converter Script (Bash)
# ============================================================

# --- Определение ffprobe рядом с ffmpeg ---
ffprobe_dir="$(dirname "$ffmpeg")"
if [ "$ffprobe_dir" != "." ] && { [ -x "$ffprobe_dir/ffprobe" ] || [ -f "$ffprobe_dir/ffprobe.exe" ]; }; then
	ffprobe="$ffprobe_dir/ffprobe"
else
	ffprobe="ffprobe"
fi

# --- E1. Проверка окружения ---
if [ ! -d "$folder_sources" ]; then
	echo -e "\n[ОШИБКА] Папка источника не найдена: $folder_sources\n"
	read -p "Нажмите [Enter], чтобы выйти..."
	exit 1
fi

if [ ! -d "$folder_destination" ]; then
	mkdir -p "$folder_destination"
	if [ $? -ne 0 ]; then
		echo -e "\n[ОШИБКА] Не удалось создать папку назначения: $folder_destination\n"
		read -p "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
fi

if ! command -v $ffmpeg &> /dev/null; then
	echo -e "\n[ОШИБКА] ffmpeg не найден: $ffmpeg\n"
	read -p "Нажмите [Enter], чтобы выйти..."
	exit 1
fi

# --- Парсинг настроек (формат :+:value или :-:value) ---
IFS=':' read -r foo video_codec_status video_codec_value <<< $video_codec
IFS=':' read -r foo video_number_frames_status video_number_frames_value <<< $video_number_frames
IFS=':' read -r foo video_bitrate_status video_bitrate_value <<< $video_bitrate
IFS=':' read -r foo video_resolution_status video_resolution_value <<< $video_resolution
IFS=':' read -r foo video_rotation_status video_rotation_value <<< $video_rotation
IFS=':' read -r foo video_quality_status video_quality_value <<< $video_quality

IFS=':' read -r foo audio_codec_status audio_codec_value <<< $audio_codec
IFS=':' read -r foo audio_number_channels_status audio_number_channels_value <<< $audio_number_channels
IFS=':' read -r foo audio_bitrate_status audio_bitrate_value <<< $audio_bitrate
IFS=':' read -r foo audio_sampling_rate_status audio_sampling_rate_value <<< $audio_sampling_rate
IFS=':' read -r foo audio_normalize_status audio_normalize_value <<< $audio_normalize

IFS=':' read -r foo multithreads_status multithreads_value <<< $multithreads
IFS=':' read -r foo parallel_files_status parallel_files_value <<< $parallel_files
IFS=':' read -r foo video_subtitles_status video_subtitles_value <<< $video_subtitles
IFS=':' read -r foo hw_accel_status hw_accel_value <<< $hw_accel
IFS=':' read -r foo gpu_preset_status gpu_preset_value <<< $gpu_preset
IFS=':' read -r foo gpu_tune_status gpu_tune_value <<< $gpu_tune
IFS=':' read -r foo gpu_rc_status gpu_rc_value <<< $gpu_rc
IFS=':' read -r foo playback_speed_status playback_speed_value <<< $playback_speed
IFS=':' read -r foo keep_aspect_ratio_status keep_aspect_ratio_value <<< $keep_aspect_ratio
IFS=':' read -r foo output_container_status output_container_value <<< $output_container

# --- Формирование аудио-параметров ---
if [ "$audio_codec_status" = "+" ]; then set_audio_codec="-c:a $audio_codec_value"; else set_audio_codec=""; fi
if [ "$audio_number_channels_status" = "+" ]; then set_audio_number_channels="-ac $audio_number_channels_value"; else set_audio_number_channels=""; fi
if [ "$audio_bitrate_status" = "+" ]; then set_audio_bitrate="-b:a ${audio_bitrate_value}k"; else set_audio_bitrate=""; fi
if [ "$audio_sampling_rate_status" = "+" ]; then set_audio_sampling_rate="-ar $audio_sampling_rate_value"; else set_audio_sampling_rate=""; fi

# --- Формирование видео-параметров ---
if [ "$video_codec_status" = "+" ]; then set_video_codec="$video_codec_value"; else set_video_codec=""; fi
if [ "$video_number_frames_status" = "+" ]; then set_video_number_frames="-r $video_number_frames_value"; else set_video_number_frames=""; fi
if [ "$video_bitrate_status" = "+" ]; then set_video_bitrate_orig="$video_bitrate_value"; else set_video_bitrate_orig=""; fi
if [ "$video_resolution_status" = "+" ]; then set_video_resolution="$video_resolution_value"; else set_video_resolution=""; fi

# --- Многопоточность ---
if [ "$multithreads_status" = "+" ]; then threads="$multithreads_value"; else threads=1; fi
if [ "$parallel_files_status" = "+" ]; then parallel_count="$parallel_files_value"; else parallel_count=1; fi

# --- Аппаратное ускорение (nvidia / intel / off) ---
use_hw_accel="no"
hw_accel_type=""
hw_decode_args=""
if [ "$hw_accel_status" = "+" ]; then
	case "$hw_accel_value" in
		nvidia)
			if $ffmpeg -encoders 2>/dev/null | grep -q nvenc; then
				use_hw_accel="yes"
				hw_accel_type="nvidia"
				hw_decode_args="-hwaccel cuda -hwaccel_output_format cuda"
				case "$set_video_codec" in
					libx264) set_video_codec="h264_nvenc" ;;
					libx265) set_video_codec="hevc_nvenc" ;;
					libsvtav1) set_video_codec="av1_nvenc" ;;
				esac
			else
				echo "[ПРЕДУПРЕЖДЕНИЕ] NVENC не поддерживается данной сборкой ffmpeg. Используется программное кодирование."
			fi
			;;
		intel)
			if $ffmpeg -encoders 2>/dev/null | grep -q qsv; then
				use_hw_accel="yes"
				hw_accel_type="intel"
				hw_decode_args="-hwaccel qsv -hwaccel_output_format qsv"
				case "$set_video_codec" in
					libx264) set_video_codec="h264_qsv" ;;
					libx265) set_video_codec="hevc_qsv" ;;
					libsvtav1) set_video_codec="av1_qsv" ;;
				esac
			else
				echo "[ПРЕДУПРЕЖДЕНИЕ] QSV не поддерживается данной сборкой ffmpeg. Используется программное кодирование."
			fi
			;;
	esac
fi

# --- Время начала и длительности ---
IFS=':' read -r foo start_coding_status start_coding_value <<< $start_coding
if [ "$start_coding_status" = "+" ]; then
	IFS='-' read -r x y z <<< $start_coding_value
	start_coding_value=$((${x#0}*3600+${y#0}*60+${z#0}))
	set_start_coding="-ss $start_coding_value"
else
	set_start_coding=""
fi

IFS=':' read -r foo length_coding_status length_coding_value <<< $length_coding
if [ "$length_coding_status" = "+" ]; then
	IFS='-' read -r x y z <<< $length_coding_value
	length_coding_value=$((${x#0}*3600+${y#0}*60+${z#0}))
	set_length_coding="-t $length_coding_value"
else
	set_length_coding=""
	split_by_silence="no"
fi

# --- A1. Формат и настройки видео/аудио ---
if [ "$audio_only" = "yes" ]; then
	format_files_out="mp3"
	video_settings="-vn"
	set_audio_codec="-c:a libmp3lame"
else
	# D3. Выходной контейнер
	if [ "$output_container_status" = "+" ]; then
		format_files_out="$output_container_value"
	else
		format_files_out="mp4"
	fi
	# E5. Сборка цепочки видео-фильтров
	vf_chain=""
	af_chain=""
	# Поворот
	if [ "$video_rotation_status" = "+" ]; then
		if [ "$hw_accel_type" = "nvidia" ]; then
			vf_chain="${vf_chain:+$vf_chain,}transpose_cuda=$video_rotation_value"
		else
			vf_chain="${vf_chain:+$vf_chain,}transpose=$video_rotation_value"
		fi
	fi
	# D4. Масштабирование с сохранением пропорций
	if [ -n "$set_video_resolution" ]; then
		IFS='x' read -r res_w res_h <<< "$set_video_resolution"
		if [ "$keep_aspect_ratio_status" = "+" ] && [ "$keep_aspect_ratio_value" = "yes" ]; then
			case "$hw_accel_type" in
				nvidia) vf_chain="${vf_chain:+$vf_chain,}scale_cuda=${res_w}:${res_h}:force_original_aspect_ratio=decrease" ;;
				intel)  vf_chain="${vf_chain:+$vf_chain,}scale_qsv=${res_w}:${res_h}" ;;
				*)      vf_chain="${vf_chain:+$vf_chain,}scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" ;;
			esac
		else
			case "$hw_accel_type" in
				nvidia) vf_chain="${vf_chain:+$vf_chain,}scale_cuda=${res_w}:${res_h}" ;;
				intel)  vf_chain="${vf_chain:+$vf_chain,}scale_qsv=${res_w}:${res_h}" ;;
				*)      vf_chain="${vf_chain:+$vf_chain,}scale=${res_w}:${res_h}" ;;
			esac
		fi
	fi
	# D6. Скорость воспроизведения (видео)
	if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
		pts_divisor="$playback_speed_value"
		vf_chain="${vf_chain:+$vf_chain,}setpts=PTS/$pts_divisor"
	fi
	# Hwdownload если есть фильтры и GPU
	if [ "$use_hw_accel" = "yes" ] && [ -n "$vf_chain" ]; then
		needs_download=$(echo "$vf_chain" | grep -v 'scale_cuda\|scale_qsv\|transpose_cuda\|setpts')
		if [ -n "$needs_download" ]; then
			if [ "$hw_accel_type" = "nvidia" ]; then
				vf_chain="hwdownload,format=nv12,${vf_chain}"
			elif [ "$hw_accel_type" = "intel" ]; then
				vf_chain="hwdownload,format=nv12,${vf_chain}"
			fi
		fi
	fi
	# Формирование codec-строки
	if [ -n "$set_video_codec" ]; then
		set_video_codec_arg="-c:v $set_video_codec"
	else
		set_video_codec_arg=""
	fi
	# Настройки GPU-кодека (NVENC / QSV)
	gpu_args=""
	if [ "$use_hw_accel" = "yes" ]; then
		if [ "$gpu_preset_status" = "+" ]; then gpu_args="$gpu_args -preset $gpu_preset_value"; fi
		if [ "$hw_accel_type" = "nvidia" ]; then
			if [ "$gpu_tune_status" = "+" ]; then gpu_args="$gpu_args -tune $gpu_tune_value"; fi
			if [ "$gpu_rc_status" = "+" ]; then gpu_args="$gpu_args -rc $gpu_rc_value"; fi
			if [ "$video_quality_status" = "+" ]; then gpu_args="$gpu_args -cq $video_quality_value"; fi
		elif [ "$hw_accel_type" = "intel" ]; then
			if [ "$video_quality_status" = "+" ]; then gpu_args="$gpu_args -global_quality $video_quality_value"; fi
		fi
	fi
	# CRF для программных кодеков
	crf_args=""
	if [ "$use_hw_accel" != "yes" ] && [ "$video_quality_status" = "+" ]; then
		crf_args="-crf $video_quality_value"
	fi
	video_settings="-f $format_files_out $set_video_codec_arg $set_video_number_frames $gpu_args $crf_args"
fi

# D6. Скорость воспроизведения (аудио)
af_chain=""
if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
	speed="$playback_speed_value"
	# atempo поддерживает 0.5-100.0, для значений >2.0 или <0.5 — каскад
	speed_float=$(awk "BEGIN {print $speed}")
	if awk "BEGIN {exit !($speed_float > 2.0)}"; then
		# Каскад atempo: 2.0 * 2.0 * остаток
		atempo_chain=""
		remaining="$speed_float"
		while awk "BEGIN {exit !($remaining > 2.0)}"; do
			atempo_chain="${atempo_chain:+$atempo_chain,}atempo=2.0"
			remaining=$(awk "BEGIN {printf \"%.6f\", $remaining/2.0}")
		done
		atempo_chain="${atempo_chain:+$atempo_chain,}atempo=$remaining"
		af_chain="${af_chain:+$af_chain,}$atempo_chain"
	elif awk "BEGIN {exit !($speed_float < 0.5)}"; then
		atempo_chain=""
		remaining="$speed_float"
		while awk "BEGIN {exit !($remaining < 0.5)}"; do
			atempo_chain="${atempo_chain:+$atempo_chain,}atempo=0.5"
			remaining=$(awk "BEGIN {printf \"%.6f\", $remaining/0.5}")
		done
		atempo_chain="${atempo_chain:+$atempo_chain,}atempo=$remaining"
		af_chain="${af_chain:+$af_chain,}$atempo_chain"
	else
		af_chain="${af_chain:+$af_chain,}atempo=$speed_float"
	fi
fi

# D5. Нормализация звука
if [ "$audio_normalize_status" = "+" ]; then
	case "$audio_normalize_value" in
		loudnorm) af_chain="${af_chain:+$af_chain,}loudnorm=I=-16:TP=-1.5:LRA=11" ;;
		dynaudnorm) af_chain="${af_chain:+$af_chain,}dynaudnorm" ;;
	esac
fi

audio_settings="$set_audio_codec $set_audio_number_channels $set_audio_bitrate $set_audio_sampling_rate"

# --- Потоки ---
thread_args="-threads $threads"

# --- Формат входных файлов ---
format_files_in_pattern="-iname *.${format_files_in//,/ -o -iname *.}"

# --- D8. Логирование ---
log_msg() {
	local level="$1"
	local msg="$2"
	local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
	echo "[$timestamp] [$level] $msg"
	if [ "$enable_log" = "yes" ] && [ -n "$log_file" ]; then
		echo "[$timestamp] [$level] $msg" >> "$log_file"
	fi
}

# --- J2. Счётчики и хелперы ---
results_dir=$(mktemp -d)
start_time_global=$(date +%s)

human_size() {
	local bytes=$1
	if [ "$bytes" -ge $((1024*1024*1024)) ] 2>/dev/null; then
		awk "BEGIN {printf \"%.1f GB\", $bytes/1073741824}"
	elif [ "$bytes" -ge $((1024*1024)) ] 2>/dev/null; then
		awk "BEGIN {printf \"%.1f MB\", $bytes/1048576}"
	else
		awk "BEGIN {printf \"%.0f KB\", $bytes/1024}"
	fi
}

# --- J1. Прогресс-бар в CLI ---
show_progress_bar() {
	local pct=$1 label="$2"
	local filled=$((pct / 2)) empty=$((50 - pct / 2)) bar=""
	for ((j=0; j<filled; j++)); do bar="${bar}#"; done
	for ((j=0; j<empty; j++)); do bar="${bar}."; done
	printf "\r  [%s] %3d%%  %s" "$bar" "$pct" "$(basename "$label")"
}

# --- Функция кодирования одного файла ---
encode_file() {
	local full_path="$1"
	local file_path="$(dirname "$full_path")/"
	local file_name="$(basename "$full_path" | sed 's/\.[^.]*$//')"
	if [ "$save_old_extension" = "yes" ]; then file_name="$(basename "$full_path")"; fi
	file_path="${file_path#$folder_sources}"
	if [ ! -d "$folder_destination$file_path" ]; then mkdir -p "$folder_destination$file_path"; fi

	# --- I. Извлечение аудио без перекодирования ---
	if [ "$extract_audio_copy" = "yes" ]; then
		local codec ext out_audio
		codec=$($ffprobe -v quiet -select_streams a:0 -show_entries stream=codec_name -of csv=p=0 "$full_path" 2>/dev/null)
		case "$codec" in
			aac)    ext="m4a"  ;;
			mp3)    ext="mp3"  ;;
			opus)   ext="opus" ;;
			vorbis) ext="ogg"  ;;
			flac)   ext="flac" ;;
			pcm_*)  ext="wav"  ;;
			*)      ext="mka"  ;;
		esac
		out_audio="${folder_destination}${file_path}${file_name}.${ext}"
		if [ -f "$out_audio" ]; then
			echo "skip" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
			return
		fi
		log_msg "INFO" "Извлечение аудио: $(basename "$full_path")"
		$ffmpeg -hide_banner -strict -2 -i "$full_path" -vn -c:a copy "$out_audio" -y
		if [ $? -ne 0 ]; then
			log_msg "FAIL" "$(basename "$full_path")"
			rm -f "$out_audio"
			echo "fail" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
		else
			local out_sz in_sz
			out_sz=$(stat -c%s "$out_audio" 2>/dev/null || echo 0)
			in_sz=$(stat -c%s "$full_path" 2>/dev/null || echo 0)
			log_msg "OK" "$(basename "$full_path") -> $(basename "$out_audio")"
			echo "ok:${out_sz}:${in_sz}" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
		fi
		return
	fi

	if [ "$create_frame" = "yes" ]; then
		if [ ! -d "${folder_destination}${file_path}${file_name}" ]; then
			mkdir -p "$folder_destination$file_path$file_name"
			log_msg "INFO" "Извлечение кадров: $full_path"
			$ffmpeg -hide_banner -strict -2 -i "$full_path" -r 1/1 "$folder_destination$file_path$file_name/${file_name}_%05d.png"
		fi
		return
	fi

	local current_format_out="$format_files_out"
	if [ -f "${folder_destination}${file_path}${file_name}.${current_format_out}" ]; then
		# E3. Проверка валидности существующего файла
		if $ffmpeg -v error -i "${folder_destination}${file_path}${file_name}.${current_format_out}" -f null - 2>/dev/null; then
			echo "skip" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
			return
		else
			log_msg "WARN" "Удаление битого файла: ${folder_destination}${file_path}${file_name}.${current_format_out}"
			rm -f "${folder_destination}${file_path}${file_name}.${current_format_out}"
		fi
	fi
	if [ -f "${folder_destination}${file_path}${file_name} (part.1).${current_format_out}" ]; then
		echo "skip" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
		return
	fi

	# E4. Получение битрейта через ffprobe
	local src_bitrate=""
	if command -v $ffprobe &> /dev/null; then
		src_bitrate=$($ffprobe -v quiet -show_entries format=bit_rate -of default=noprint_wrappers=1:nokey=1 "$full_path" 2>/dev/null)
		if [ -n "$src_bitrate" ]; then src_bitrate=$((src_bitrate / 1000)); fi
	else
		src_bitrate=$(${ffmpeg} -i "$full_path" 2>&1 | grep -i 'bitrate:' | head -1 | grep -oP 'bitrate: \K[0-9]+')
	fi

	local set_video_bitrate_final=""
	if [ "$video_bitrate_status" = "+" ] && [ "$video_quality_status" != "+" ]; then
		if [ -n "$src_bitrate" ] && [ "$src_bitrate" -lt "$set_video_bitrate_orig" ] 2>/dev/null; then
			set_video_bitrate_final="-b:v ${src_bitrate}k"
		else
			set_video_bitrate_final="-b:v ${set_video_bitrate_orig}k"
		fi
	fi

	local convert_settings
	if [ "$copy_codecs" = "yes" ]; then
		convert_settings="-c copy -map 0"
		current_format_out="${full_path##*.}"
	else
		convert_settings="$video_settings $set_video_bitrate_final $audio_settings"
	fi

	# --- J1. Получение длительности (для прогресс-бара и split) ---
	local file_duration=0
	if command -v $ffprobe &> /dev/null; then
		local dur_raw
		dur_raw=$($ffprobe -v quiet -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$full_path" 2>/dev/null)
		if [ -n "$dur_raw" ]; then
			file_duration=$(awk "BEGIN {printf \"%d\", $dur_raw}")
		fi
	else
		local dur_str=$($ffmpeg -i "$full_path" 2>&1 | grep -i Duration: | grep -oP '\d+:\d+:\d+')
		if [ -n "$dur_str" ]; then
			IFS=':' read -r x y z <<< "$dur_str"
			file_duration=$((${x#0}*3600+${y#0}*60+${z#0}))
		fi
	fi

	# Видео-фильтры
	local vf_args=""
	local current_vf_chain="$vf_chain"
	local af_args=""
	local current_af_chain="$af_chain"

	if [ "$length_coding_status" = "+" ]; then
		local duration="$file_duration"

		if [ "$split_by_silence" = "yes" ]; then
			echo -e "\n\nЖдите! Идёт поиск пауз в файле:\n$full_path\n"
			local search_silence=$($ffmpeg -i "$full_path" -nostats -af "silencedetect=n=${silence_threshold}:d=${silence_duration}" -f null - 2>&1 | grep -i silence_)
			split_points=()
			local silence_start_val=""
			while IFS= read -r line; do
				if [[ "$line" == *"silence_start"* ]]; then
					silence_start_val=$(echo "$line" | grep -oP 'silence_start: \K[0-9.]+')
				fi
				if [[ "$line" == *"silence_end"* ]]; then
					local silence_end_val=$(echo "$line" | grep -oP 'silence_end: \K[0-9.]+')
					split_points+=($(awk "BEGIN {printf \"%d\", ($silence_start_val+$silence_end_val)/2}"))
				fi
			done <<< "$search_silence"
		fi

		num=()
		for ((i=0; i<=999; i++)); do
			local lcv=$((length_coding_value + length_coding_value * (i - 1)))
			if (( i == 0 )); then lcv=0; fi
			eval "length_coding_value_idx${i}=$lcv"
			if ((duration > lcv)); then
				local part_start=$lcv
				if [ "$split_by_silence" = "yes" ] && [ ${#split_points[@]} -gt 0 ]; then
					local best_point=$part_start
					local best_diff=999999
					for p in "${split_points[@]}"; do
						local d=$((p - part_start))
						if (( d < 0 )); then d=$(( -d )); fi
						if (( d < best_diff )); then
							best_diff=$d
							best_point=$p
						fi
					done
					local half_length=$((length_coding_value/2))
					if (( best_diff <= half_length )); then
						local new_part_start=$best_point
					else
						local new_part_start=$part_start
					fi
					num+=("$new_part_start")
					eval "length_coding_value_silent${i}=$((length_coding_value-(part_start-new_part_start)))"
					eval "length_coding_value_idx${i}=$new_part_start"
				else
					num+=("$part_start")
				fi
			else
				break
			fi
		done
	else
		num=(0)
	fi

	if [ "$start_coding_status" = "+" ]; then num=($start_coding_value); fi

	local c=1
	for b in "${num[@]}"; do
		local pref=""
		if [ ${#num[@]} -gt 1 ] || [ "${num[0]}" != "0" ]; then
			pref=" (part.$c)"
		fi

		local current_set_length="$set_length_coding"
		if [ "$split_by_silence" = "yes" ] && [ "$length_coding_status" = "+" ]; then
			local silent_idx=$((c-1))
			eval "current_set_length=\"-t \$length_coding_value_silent${silent_idx}\""
		fi

		# B2. Субтитры с subtitles_style
		local subtitles_params=()
		if [ "$video_subtitles_status" = "+" ] && [ "$copy_codecs" = "no" ]; then
			local sub_found=""
			for ext in srt vtt; do
				if [ -z "$sub_found" ]; then
					local sub_file="${folder_sources}${file_path}${file_name}.${ext}"
					if [ -f "$sub_file" ]; then
						if [ "$video_subtitles_value" = "burn" ]; then
							local sub_escaped=$(echo "$sub_file" | sed "s/'/\\\\'/g" | sed 's/:/\\:/g')
							if [ -n "$subtitles_style" ]; then
								current_vf_chain="${current_vf_chain:+$current_vf_chain,}subtitles='${sub_escaped}':force_style='${subtitles_style}'"
							else
								current_vf_chain="${current_vf_chain:+$current_vf_chain,}subtitles='${sub_escaped}'"
							fi
						fi
						if [ "$video_subtitles_value" = "meta" ]; then
							subtitles_params=(-i "$sub_file" -c:s mov_text -metadata:s:s:0 language=rus)
							convert_settings="$convert_settings -map 0 -map 1"
						fi
						sub_found=1
					fi
				fi
			done
		fi

		# Финализация фильтров
		if [ -n "$current_vf_chain" ]; then vf_args="-vf $current_vf_chain"; else vf_args=""; fi
		if [ -n "$current_af_chain" ]; then af_args="-af $current_af_chain"; else af_args=""; fi

		local out_file="${folder_destination}${file_path}${file_name}${pref}.${current_format_out}"

		# D7. Dry-run
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -hide_banner -strict -2 $hw_decode_args -i \"$full_path\" ${subtitles_params[*]} $convert_settings $thread_args $vf_args $af_args -ss $b $current_set_length \"$out_file\""
		else
			log_msg "INFO" "Кодирование: $(basename "$full_path") -> $(basename "$out_file")"
			local encode_start=$(date +%s)

			# J1. Запуск ffmpeg в фоне с прогресс-файлом
			local progress_file err_file
			progress_file=$(mktemp)
			err_file=$(mktemp)

			$ffmpeg -hide_banner -strict -2 $hw_decode_args \
				-i "$full_path" "${subtitles_params[@]}" \
				$convert_settings $thread_args $vf_args $af_args \
				-ss $b $current_set_length \
				-progress "$progress_file" -nostats \
				"$out_file" -y 2>"$err_file" &
			local ffmpeg_pid=$!

			# Показываем прогресс-бар пока ffmpeg работает
			while kill -0 $ffmpeg_pid 2>/dev/null; do
				sleep 0.4
				if [ "$file_duration" -gt 0 ] 2>/dev/null; then
					local out_time_ms
					out_time_ms=$(grep "^out_time_ms=" "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2)
					if [ -n "$out_time_ms" ] && [[ "$out_time_ms" =~ ^[0-9]+$ ]] && [ "$out_time_ms" -gt 0 ]; then
						local pct=$((out_time_ms / 1000000 * 100 / file_duration))
						[ $pct -gt 100 ] && pct=100
						show_progress_bar $pct "$full_path"
					fi
				fi
			done
			wait $ffmpeg_pid
			local exit_code=$?
			printf "\n"
			rm -f "$progress_file"

			local encode_end=$(date +%s)
			local elapsed=$((encode_end - encode_start))
			local elapsed_min=$((elapsed / 60))
			local elapsed_sec=$((elapsed % 60))

			# E2. Обработка ошибок
			if [ $exit_code -ne 0 ]; then
				log_msg "FAIL" "$(basename "$full_path") (exit code $exit_code, ${elapsed_min}m ${elapsed_sec}s)"
				# Показать последние строки ошибки
				if [ -s "$err_file" ]; then
					tail -3 "$err_file" | while IFS= read -r errline; do
						echo "  $errline"
					done
				fi
				rm -f "$out_file"
				echo "fail" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
			else
				log_msg "OK" "$(basename "$full_path") -> $(basename "$out_file") (${elapsed_min}m ${elapsed_sec}s)"
				local out_sz in_sz
				out_sz=$(stat -c%s "$out_file" 2>/dev/null || echo 0)
				in_sz=$(stat -c%s "$full_path" 2>/dev/null || echo 0)
				echo "ok:${out_sz}:${in_sz}" > "$results_dir/r_$$_$(date +%s%N 2>/dev/null || date +%s)_$RANDOM"
			fi
			rm -f "$err_file"
		fi
		((c+=1))
	done
}

# --- Основная логика ---
if [ "$merge_files" = "yes" ]; then
	while IFS= read -r -d '' full_path; do
		if [ -z "$fname" ]; then fname=$(basename "$full_path"); break; fi
	done < <(find "$folder_sources" \( $format_files_in_pattern \) -print0)
	if [ ! -f "${folder_destination}/${fname}" ]; then
		full_path=$(mktemp)
		find "$folder_sources" \( $format_files_in_pattern \) -printf "file '%p'\n" > "$full_path"
		log_msg "INFO" "Объединение файлов -> ${folder_destination}/${fname}"
		$ffmpeg -hide_banner -strict -2 -f concat -safe 0 -i "$full_path" -c copy -map 0 "$folder_destination/$fname"
		if [ $? -ne 0 ]; then
			log_msg "FAIL" "Объединение файлов"
			echo "fail" > "$results_dir/r_merge"
		else
			log_msg "OK" "Объединение файлов -> ${folder_destination}/${fname}"
			echo "ok:0:0" > "$results_dir/r_merge"
		fi
		rm -f "$full_path"
	fi
else
	# B1b. Параллельная обработка файлов
	if [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		export -f encode_file log_msg show_progress_bar human_size
		export folder_sources folder_destination ffmpeg format_files_out video_settings audio_settings
		export save_old_extension create_frame copy_codecs split_by_silence extract_audio_copy
		export video_bitrate_status set_video_bitrate_orig video_quality_status
		export length_coding_status length_coding_value set_length_coding start_coding_status start_coding_value
		export video_subtitles_status video_subtitles_value subtitles_style
		export vf_chain af_chain hw_decode_args thread_args use_hw_accel
		export silence_threshold silence_duration dry_run enable_log log_file
		export keep_aspect_ratio_status keep_aspect_ratio_value playback_speed_status playback_speed_value
		export results_dir
		find "$folder_sources" \( $format_files_in_pattern \) -print0 | xargs -0 -P "$parallel_count" -I {} bash -c 'encode_file "$@"' _ {}
	else
		find "$folder_sources" \( $format_files_in_pattern \) -print0 | while read -d $'\0' full_path; do
			encode_file "$full_path"
		done
	fi
fi

# --- J2. Итоговая сводка ---
total_ok=0; total_fail=0; total_skip=0
total_out_bytes=0; total_in_bytes=0
for f in "$results_dir"/r_*; do
	[ -f "$f" ] || continue
	content=$(cat "$f")
	case "${content%%:*}" in
		ok)
			((total_ok++))
			IFS=: read -r _ out_sz in_sz <<< "$content"
			total_out_bytes=$((total_out_bytes + ${out_sz:-0}))
			total_in_bytes=$((total_in_bytes + ${in_sz:-0}))
			;;
		fail) ((total_fail++)) ;;
		skip) ((total_skip++)) ;;
	esac
done
rm -rf "$results_dir"

end_time_global=$(date +%s)
elapsed_global=$((end_time_global - start_time_global))
elapsed_global_min=$((elapsed_global / 60))
elapsed_global_sec=$((elapsed_global % 60))

echo -e "\n"
echo "══════════════════════════════════════════════"
echo "  Обработано:  ${total_ok} файлов"
echo "  Пропущено:   ${total_skip} (уже существуют)"
echo "  Ошибки:      ${total_fail}"
printf "  Время:       %d мин %d сек\n" "$elapsed_global_min" "$elapsed_global_sec"
if [ "$total_in_bytes" -gt 0 ]; then
	in_hr=$(human_size $total_in_bytes)
	out_hr=$(human_size $total_out_bytes)
	compress_pct=0
	if [ "$total_in_bytes" -gt 0 ]; then
		compress_pct=$(awk "BEGIN {printf \"%d\", (1 - $total_out_bytes/$total_in_bytes) * 100}")
	fi
	echo "  Вход:        ${in_hr}"
	echo "  Выход:       ${out_hr} (сжатие ${compress_pct}%)"
fi
echo "══════════════════════════════════════════════"
echo -e "\n"
read -p "Нажмите [Enter], чтобы продолжить..."
exit
