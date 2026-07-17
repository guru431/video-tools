#!/bin/bash

# ============================================================
# FFmpeg Converter Script (Bash)
# ============================================================

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

if ! command -v "$ffmpeg" &> /dev/null; then
	echo -e "\n[ОШИБКА] ffmpeg не найден: $ffmpeg\n"
	read -p "Нажмите [Enter], чтобы выйти..."
	exit 1
fi

# --- Парсинг настроек (формат :+:value или :-:value) ---
IFS=':' read -r foo video_codec_status video_codec_value <<< "$video_codec"
IFS=':' read -r foo video_number_frames_status video_number_frames_value <<< "$video_number_frames"
IFS=':' read -r foo video_bitrate_status video_bitrate_value <<< "$video_bitrate"
IFS=':' read -r foo video_resolution_status video_resolution_value <<< "$video_resolution"
IFS=':' read -r foo video_rotation_status video_rotation_value <<< "$video_rotation"
IFS=':' read -r foo video_quality_status video_quality_value <<< "$video_quality"

IFS=':' read -r foo audio_codec_status audio_codec_value <<< "$audio_codec"
IFS=':' read -r foo audio_number_channels_status audio_number_channels_value <<< "$audio_number_channels"
IFS=':' read -r foo audio_bitrate_status audio_bitrate_value <<< "$audio_bitrate"
IFS=':' read -r foo audio_sampling_rate_status audio_sampling_rate_value <<< "$audio_sampling_rate"
IFS=':' read -r foo audio_normalize_status audio_normalize_value <<< "$audio_normalize"

IFS=':' read -r foo multithreads_status multithreads_value <<< "$multithreads"
IFS=':' read -r foo parallel_files_status parallel_files_value <<< "$parallel_files"
IFS=':' read -r foo video_subtitles_status video_subtitles_value <<< "$video_subtitles"
IFS=':' read -r foo hw_accel_status hw_accel_value <<< "$hw_accel"
IFS=':' read -r foo gpu_preset_status gpu_preset_value <<< "$gpu_preset"
IFS=':' read -r foo gpu_tune_status gpu_tune_value <<< "$gpu_tune"
IFS=':' read -r foo gpu_rc_status gpu_rc_value <<< "$gpu_rc"
IFS=':' read -r foo playback_speed_status playback_speed_value <<< "$playback_speed"
IFS=':' read -r foo keep_aspect_ratio_status keep_aspect_ratio_value <<< "$keep_aspect_ratio"
IFS=':' read -r foo output_container_status output_container_value <<< "$output_container"

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
# F33. Сначала РАЗРЕШАЕМ нужный энкодер, затем проверяем, что он есть в сборке,
# и только тогда включаем hardware. Раньше проверка была подстрочной (grep -q nvenc)
# и давала два скрытых дефекта:
#   • сборка с h264_nvenc, но без av1_nvenc, для libsvtav1 подставляла несуществующий
#     av1_nvenc — падал каждый файл;
#   • кодек вне маппинга (например libvpx-vp9) оставался программным, но
#     -hwaccel_output_format cuda уже включался → софт получал hardware-кадры
#     («Impossible to convert between the formats»).
if [ "$hw_accel_status" = "+" ]; then
	hw_suffix=""; hw_label=""
	case "$hw_accel_value" in
		nvidia) hw_suffix="_nvenc"; hw_label="NVENC"; hw_try_args="-hwaccel cuda -hwaccel_output_format cuda"; hw_try_type="nvidia" ;;
		intel)  hw_suffix="_qsv";   hw_label="QSV";   hw_try_args="-hwaccel qsv -hwaccel_output_format qsv";   hw_try_type="intel" ;;
	esac
	if [ -n "$hw_suffix" ]; then
		# Кандидат: маппинг software→GPU либо уже готовое GPU-имя от пользователя.
		hw_candidate=""
		case "$set_video_codec" in
			libx264)   hw_candidate="h264${hw_suffix}" ;;
			libx265)   hw_candidate="hevc${hw_suffix}" ;;
			libsvtav1) hw_candidate="av1${hw_suffix}" ;;
			*${hw_suffix}) hw_candidate="$set_video_codec" ;;
		esac
		if [ -z "$hw_candidate" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] У кодека $set_video_codec нет ${hw_label}-варианта. Используется программное кодирование."
		# Якорим имя по границам столбца: подстрочный grep матчил бы av1_nvenc в
		# строке про av1_nvenc_hypothetical и наоборот.
		elif "$ffmpeg" -encoders 2>/dev/null | grep -qE "^[[:space:]]*[A-Z.]+[[:space:]]+${hw_candidate}([[:space:]]|$)"; then
			use_hw_accel="yes"
			hw_accel_type="$hw_try_type"
			hw_decode_args="$hw_try_args"
			set_video_codec="$hw_candidate"
		else
			echo "[ПРЕДУПРЕЖДЕНИЕ] Энкодер $hw_candidate отсутствует в данной сборке ffmpeg. Используется программное кодирование."
		fi
	fi
fi

# --- Время начала и длительности ---
IFS=':' read -r foo start_coding_status start_coding_value <<< "$start_coding"
if [ "$start_coding_status" = "+" ]; then
	IFS='-' read -r x y z <<< "$start_coding_value"
	start_coding_value=$((${x#0}*3600+${y#0}*60+${z#0}))
	set_start_coding="-ss $start_coding_value"
else
	set_start_coding=""
fi

IFS=':' read -r foo length_coding_status length_coding_value <<< "$length_coding"
if [ "$length_coding_status" = "+" ]; then
	IFS='-' read -r x y z <<< "$length_coding_value"
	length_coding_value=$((${x#0}*3600+${y#0}*60+${z#0}))
	set_length_coding="-t $length_coding_value"
else
	set_length_coding=""
	split_by_silence="no"
fi

# --- A1. Формат и настройки видео/аудио ---
if [ "$audio_only" = "yes" ]; then
	# Контейнер и аудио-кодек выводятся из настроенного [audio] codec, а не жёстко mp3.
	# Сравнение регистронезависимо (паритет с PS1 switch): AAC/FLAC не падают в дефолт.
	case "$(printf '%s' "$audio_codec_value" | tr '[:upper:]' '[:lower:]')" in
		libmp3lame|mp3) format_files_out="mp3";  set_audio_codec="-c:a libmp3lame" ;;
		aac)            format_files_out="m4a";  set_audio_codec="-c:a aac" ;;
		libopus|opus)   format_files_out="opus"; set_audio_codec="-c:a libopus" ;;
		flac)           format_files_out="flac"; set_audio_codec="-c:a flac" ;;
		libvorbis|vorbis) format_files_out="ogg"; set_audio_codec="-c:a libvorbis" ;;
		*)              format_files_out="mp3";  set_audio_codec="-c:a libmp3lame" ;;
	esac
	video_settings="-vn"
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
	# rotation+GPU: CUDA-варианта фильтра поворота не существует. Если включён поворот
	# и используется GPU — вся цепочка фильтров переводится на CPU (transpose+scale),
	# иначе получилась бы несовместимая смесь CPU transpose + scale_cuda/scale_qsv.
	# keep_aspect_ratio+GPU: scale_cuda/scale_qsv не умеют pad hw-кадры → GPU-путь дал бы
	# иную геометрию (без letterbox), чем CPU. Тоже форсим CPU scale+pad для паритета.
	scale_backend="$hw_accel_type"
	if [ "$use_hw_accel" = "yes" ]; then
		if [ "$video_rotation_status" = "+" ]; then
			scale_backend="cpu"
		elif [ "$keep_aspect_ratio_status" = "+" ] && [ "$keep_aspect_ratio_value" = "yes" ] && [ -n "$set_video_resolution" ]; then
			scale_backend="cpu"
		fi
	fi
	# Поворот
	if [ "$video_rotation_status" = "+" ]; then
		vf_chain="${vf_chain:+$vf_chain,}transpose=$video_rotation_value"
	fi
	# D4. Масштабирование с сохранением пропорций
	if [ -n "$set_video_resolution" ]; then
		IFS='x' read -r res_w res_h <<< "$set_video_resolution"
		if [ "$keep_aspect_ratio_status" = "+" ] && [ "$keep_aspect_ratio_value" = "yes" ]; then
			case "$scale_backend" in
				nvidia) vf_chain="${vf_chain:+$vf_chain,}scale_cuda=${res_w}:${res_h}:force_original_aspect_ratio=decrease" ;;
				intel)  vf_chain="${vf_chain:+$vf_chain,}scale_qsv=${res_w}:${res_h}:force_original_aspect_ratio=decrease" ;;
				*)      vf_chain="${vf_chain:+$vf_chain,}scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" ;;
			esac
		else
			case "$scale_backend" in
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
	# Hwdownload если есть фильтры и GPU. Per-element семантика (идентична PS1):
	# скачиваем кадры в RAM, если есть хотя бы один CPU-фильтр (не scale_cuda/scale_qsv/setpts).
	if [ "$use_hw_accel" = "yes" ] && [ -n "$vf_chain" ]; then
		needs_download="no"
		IFS=',' read -ra _vf_elems <<< "$vf_chain"
		for _el in "${_vf_elems[@]}"; do
			case "$_el" in
				scale_cuda*|scale_qsv*|setpts*) ;;
				*) needs_download="yes" ;;
			esac
		done
		if [ "$needs_download" = "yes" ]; then
			vf_chain="hwdownload,format=nv12,${vf_chain}"
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
		fi
	fi
	# Флаг качества по РЕШЁННОМУ энкодеру, а не по use_hw_accel: nvenc/qsv отвергают -crf.
	# Если codec задан напрямую как *_nvenc/*_qsv при выключенном hw_accel, всё равно
	# нужен -cq/-global_quality, иначе ffmpeg падает "Unrecognized option crf".
	crf_args=""
	if [ "$video_quality_status" = "+" ]; then
		case "$set_video_codec" in
			*_nvenc) crf_args="-cq $video_quality_value" ;;
			*_qsv)   crf_args="-global_quality $video_quality_value" ;;
			# AMF (h264_amf/hevc_amf/av1_amf) не имеет одиночного -qp: constant-quality
			# задаётся режимом cqp + отдельными -qp_i/-qp_p/-qp_b. Прежний общий `-qp N`
			# ffmpeg не принимал ("Unrecognized option qp") — каждый AMF-файл падал.
			*_amf)   crf_args="-rc cqp -qp_i $video_quality_value -qp_p $video_quality_value -qp_b $video_quality_value" ;;
			*)       crf_args="-crf $video_quality_value" ;;
		esac
	fi
	# Имя muxer для -f: mkv/ts — это расширения файла, а не имена форматов ffmpeg.
	# Расширение выходного файла не меняется, только аргумент -f.
	case "$format_files_out" in
		mkv) muxer_out="matroska" ;;
		ts)  muxer_out="mpegts" ;;
		*)   muxer_out="$format_files_out" ;;
	esac
	video_settings="-f $muxer_out $set_video_codec_arg $set_video_number_frames $gpu_args $crf_args"
fi

# D6. Скорость воспроизведения (аудио)
af_chain=""
if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
	speed="$playback_speed_value"
	# F15. Предпусковая валидация: каскад ниже делит remaining на 2.0 (или 0.5), поэтому
	# 0 остаётся нулём, а отрицательное уходит в минус — цикл не сходится и скрипт
	# зависает молча, ещё до первого файла. Допустим только конечный 0 < speed <= 100
	# (верхняя граница — предел одного звена atempo).
	if ! awk "BEGIN {v=($speed)+0; exit !(v > 0 && v <= 100)}" </dev/null 2>/dev/null; then
		echo -e "\n[ОШИБКА] playback_speed должен быть числом в диапазоне 0 < speed <= 100 (получено: '$speed')\n"
		read -p "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
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

# --- F8. Кодек субтитров для режима meta зависит от контейнера ---
# mov_text живёт только в mp4/mov; mkv → srt, webm → webvtt. Раньше всегда ставился
# mov_text и ронял mkv/webm-выход. Для прочих контейнеров оставляем mov_text (best-effort).
case "$format_files_out" in
	mkv)  sub_meta_codec="srt" ;;
	webm) sub_meta_codec="webvtt" ;;
	*)    sub_meta_codec="mov_text" ;;
esac

# --- F8. Предпусковая проверка совместимости контейнера и кодеков ---
# Несовместимую пару (напр. webm + libx264/aac) отклоняем ДО пакета с понятной
# причиной, а не роняем каждый файл в процессе. Проверяем только при реальном
# транскодировании в выбранный контейнер (не copy/merge/frame/extract/audio_only).
if [ "$audio_only" != "yes" ] && [ "$copy_codecs" != "yes" ] && [ "$merge_files" != "yes" ] && [ "$create_frame" != "yes" ] && [ "$extract_audio_copy" != "yes" ]; then
	_incompat=""
	case "$format_files_out" in
		webm)
			case "$set_video_codec" in
				""|libvpx|libvpx-vp9|vp8|vp9|av1*|libsvtav1|libaom-av1) ;;
				*) _incompat="  • WebM не поддерживает видеокодек '$set_video_codec' — нужен VP8/VP9/AV1 (смените [video] codec или [video] container)." ;;
			esac
			# Смотрим на РЕАЛЬНО сформированный аргумент, а не на значение из конфига:
			# при `codec = -aac` статус '-' и `-c:a` в ffmpeg не передаётся вовсе —
			# контейнер выберет дефолт сам, отклонять такую конфигурацию не за что.
			_eff_audio_codec="${set_audio_codec#-c:a }"
			case "$(printf '%s' "$_eff_audio_codec" | tr '[:upper:]' '[:lower:]')" in
				""|libopus|opus|libvorbis|vorbis) ;;
				*) _incompat="${_incompat:+$_incompat$'\n'}  • WebM не поддерживает аудиокодек '$_eff_audio_codec' — нужен Opus/Vorbis (смените [audio] codec или [video] container)." ;;
			esac
			;;
	esac
	if [ -n "$_incompat" ]; then
		echo -e "\n[ОШИБКА] Несовместимая комбинация контейнера и кодеков:\n$_incompat\n"
		read -p "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
fi

# --- Потоки ---
thread_args="-threads $threads"

# --- Подпись настроек для manifest ---
# Manifest обязан устаревать при смене ЛЮБОЙ настройки, определяющей содержимое выхода.
# Иначе прогон с другим контейнером/кодеком/фильтрами увидит «complete» от прошлого
# прогона и пропустит файл, так и не создав запрошенный результат. Число потоков и
# overwrite сюда не входят: они влияют на то, КАК считается выход, а не на то, каким он
# получится.
settings_sig=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
	"$video_settings" "$audio_settings" "$vf_chain" "$af_chain" \
	"$format_files_out" "$sub_meta_codec" "$video_subtitles" "$subtitles_style" \
	"$start_coding" "$length_coding" "$split_by_silence")

# --- Формат входных файлов ---
# Предикаты find собираем массивом с quoted-паттернами: строка с *.ext без
# кавычек раскрывается shell-глоббингом по файлам в cwd и ломает выборку find.
format_find_pred=()
IFS=',' read -ra _ff_exts <<< "$format_files_in"
for _ff_e in "${_ff_exts[@]}"; do
	[ ${#format_find_pred[@]} -gt 0 ] && format_find_pred+=(-o)
	format_find_pred+=(-iname "*.${_ff_e}")
done

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
results_dir=$(mktemp -d "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
start_time_global=$(date +%s)

# Cleanup при Ctrl-C/SIGTERM: убить текущий ffmpeg-процесс и удалить temp-каталог
# результатов, иначе остаётся осиротевший ffmpeg и мусор в /tmp. НЕ ловим EXIT —
# нормальное завершение чистит results_dir явно, а trap EXIT клобберил бы trap теста
# (тесты ставят свой trap EXIT для дампа переменных при source).
_current_ffmpeg_pid=""
_cleanup_on_int() {
	[ -n "$_current_ffmpeg_pid" ] && kill "$_current_ffmpeg_pid" 2>/dev/null
	[ -n "$results_dir" ] && rm -rf "$results_dir"
	exit 130
}
trap _cleanup_on_int INT TERM

file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

# --- Транзакционная запись: имя временного файла ---
# Временное имя строится ПРЕФИКСОМ, а не суффиксом, потому что расширение обязано
# сохраниться: без -f ffmpeg выводит muxer из расширения, а режимы copy_codecs и
# merge как раз идут с `-c copy` без -f. Суффиксное `.movie.mp4.partial` давало
# "Error initializing the muxer ... Invalid argument" на настоящем ffmpeg.
partial_path() { printf '%s/.ffconv-partial-%s' "$(dirname "$1")" "$(basename "$1")"; }

# --- Manifest готовности: input → outputs → completion state ---
# Построчный формат (не JSON: CMD его не разберёт), одинаковый на трёх платформах:
#   # ffconv-manifest v1
#   source=<путь>
#   source_size=<байты>
#   output=<байты>|<путь>      ← размер первым: путь может содержать '|'
#   state=complete
# `state=complete` пишется последней строкой и только после успеха ВСЕХ частей,
# поэтому оборванная запись не может выдать себя за готовый результат.
# Сверяем размеры, а не хеши: чтение гигабайтов ради контрольной суммы стоило бы
# сопоставимо с самим перекодированием, а размер ловит обрыв и подмену источника.
manifest_write() {
	local mf="$1" src="$2" sig="$3"; shift 3
	local tmp="${mf}.tmp" o
	{
		echo "# ffconv-manifest v1"
		echo "source=$src"
		echo "source_size=$(file_size "$src")"
		echo "settings=$sig"
		for o in "$@"; do echo "output=$(file_size "$o")|$o"; done
		echo "state=complete"
	} > "$tmp" && mv -f "$tmp" "$mf"
}

manifest_is_complete() {
	local mf="$1" src="$2" sig="$3"
	[ -f "$mf" ] || return 1
	grep -q '^state=complete$' "$mf" 2>/dev/null || return 1
	local rec
	rec=$(grep '^source_size=' "$mf" 2>/dev/null | head -1 | cut -d= -f2)
	[ "$rec" = "$(file_size "$src")" ] || return 1
	# Подпись настроек: смена контейнера/кодека/фильтров обязана обесценить manifest.
	rec=$(grep '^settings=' "$mf" 2>/dev/null | head -1)
	[ "${rec#settings=}" = "$sig" ] || return 1
	local line sz path
	while IFS= read -r line; do
		case "$line" in output=*) ;; *) continue ;; esac
		line="${line#output=}"
		sz="${line%%|*}"; path="${line#*|}"
		[ -f "$path" ] || return 1
		[ "$(file_size "$path")" = "$sz" ] || return 1
	done < "$mf"
	return 0
}

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

# --- Канонизация пути для сравнения input/output ---
# Файл назначения может ещё не существовать, поэтому канонизируем только каталог
# (он гарантированно создан выше через mkdir -p) и приклеиваем basename.
canon_path() {
	local p="$1" d b
	d="$(dirname "$p")"
	b="$(basename "$p")"
	if [ -d "$d" ]; then
		d="$(cd "$d" 2>/dev/null && pwd -P)" || d="$(dirname "$p")"
	fi
	printf '%s/%s' "${d%/}" "$b"
}

# F-collision. Каталоги источника и назначения в каноническом виде. Если dest лежит
# СТРОГО ВНУТРИ source, рекурсивный find подхватывает уже сконвертированные выходы и
# гонит их по кругу (или перекодирует поверх) — такие файлы исключаем из обработки.
# Важно: dest == source (in-place) НЕ считается вложенностью — там файлы это легитимные
# источники, а коллизию «выход совпал со входом» снимает пофайловая проверка F12.
# Канонизация снимает ../ и различия форм пути на всех платформах.
canon_destination="$(canon_path "$folder_destination")"
canon_sources="$(canon_path "$folder_sources")"
dest_inside_source="no"
case "$canon_destination" in
	"$canon_sources"/*) dest_inside_source="yes" ;;
esac

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
	# F-collision. Файл внутри каталога назначения — это наш собственный выход
	# (dest строго внутри source). Пропускаем, иначе перекодируем результаты по кругу.
	if [ "$dest_inside_source" = "yes" ]; then
		case "$(canon_path "$full_path")" in
			"$canon_destination"/*)
				log_msg "SKIP" "внутри каталога назначения (собственный выход): $(basename "$full_path")"
				echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return ;;
		esac
	fi
	local file_path="$(dirname "$full_path")/"
	# F32. Два РАЗНЫХ имени, их нельзя смешивать:
	#   input_stem — имя источника без расширения; по нему ищутся sidecar-субтитры;
	#   file_name  — базовое имя ВЫХОДА (при save_old_extension=yes несёт расширение
	#                источника, чтобы movie.avi -> movie.avi.mp4).
	# Раньше переменная была одна: при save_old_extension=yes она становилась
	# "movie.mp4", и sidecar искался как "movie.mp4.srt" вместо "movie.srt" —
	# burn/meta молча пропускались.
	local input_stem="$(basename "$full_path" | sed 's/\.[^.]*$//')"
	local file_name="$input_stem"
	if [ "$save_old_extension" = "yes" ]; then file_name="$(basename "$full_path")"; fi
	file_path="${file_path:${#folder_sources}}"
	if [ ! -d "$folder_destination$file_path" ]; then mkdir -p "$folder_destination$file_path"; fi

	# --- I. Извлечение аудио без перекодирования ---
	if [ "$extract_audio_copy" = "yes" ]; then
		local codec ext out_audio
		codec=$("$ffmpeg" -i "$full_path" 2>&1 | grep -i 'Audio:' | head -1 | sed 's/.*Audio: \([a-z0-9_]*\).*/\1/')
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
		# Единый overwrite-контракт: как и обычный режим, extract при overwrite_existing=yes
		# перезаписывает готовый файл, а не пропускает его молча (раньше пропуск был
		# безусловным — overwrite_existing=yes для этого режима не работал).
		if [ -f "$out_audio" ]; then
			if [ "$overwrite_existing" = "yes" ]; then
				rm -f "$out_audio"
			else
				echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return
			fi
		fi
		# D7. Dry-run: спецрежим тоже только печатает команду, не создаёт файл.
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 -i \"$full_path\" -vn -c:a copy \"$out_audio\" -y"
			return
		fi
		log_msg "INFO" "Извлечение аудио: $(basename "$full_path")"
		"$ffmpeg" -nostdin -hide_banner -strict -2 -i "$full_path" -vn -c:a copy "$out_audio" -y
		if [ $? -ne 0 ]; then
			log_msg "FAIL" "$(basename "$full_path")"
			rm -f "$out_audio"
			echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		else
			local out_sz in_sz
			out_sz=$(stat -c%s "$out_audio" 2>/dev/null || stat -f%z "$out_audio" 2>/dev/null || echo 0)
			in_sz=$(stat -c%s "$full_path" 2>/dev/null || stat -f%z "$full_path" 2>/dev/null || echo 0)
			log_msg "OK" "$(basename "$full_path") -> $(basename "$out_audio")"
			echo "ok:${out_sz}:${in_sz}" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		fi
		return
	fi

	if [ "$create_frame" = "yes" ]; then
		local frame_dir="${folder_destination}${file_path}${file_name}"
		local frame_done="${frame_dir}/.frames_complete"
		# Готовность каталога кадров определяем по маркеру завершения, а не по факту его
		# существования: прерванный прогон оставлял частичный каталог, который молча
		# пропускался при повторном запуске (кадры так и не догружались).
		if [ -f "$frame_done" ] && [ "$overwrite_existing" != "yes" ]; then
			echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
			return
		fi
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 -i \"$full_path\" -r 1/1 \"$frame_dir/${file_name}_%05d.png\""
			return
		fi
		# Частичный каталог с прошлого прогона удаляем, чтобы кадры не смешивались.
		[ -d "$frame_dir" ] && rm -rf "$frame_dir"
		mkdir -p "$frame_dir"
		log_msg "INFO" "Извлечение кадров: $full_path"
		"$ffmpeg" -nostdin -hide_banner -strict -2 -i "$full_path" -r 1/1 "$frame_dir/${file_name}_%05d.png"
		if [ $? -ne 0 ]; then
			log_msg "FAIL" "$(basename "$full_path")"
			rm -rf "$frame_dir"
			echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		else
			: > "$frame_done"
			log_msg "OK" "Кадры: $(basename "$full_path")"
			echo "ok:0:0" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		fi
		return
	fi

	local current_format_out="$format_files_out"
	# copy_codecs сохраняет исходный контейнер — расширение выхода берём из источника
	# ДО проверки существования, иначе ищем .mp4 вместо, например, .avi и не находим готовый файл.
	if [ "$copy_codecs" = "yes" ]; then current_format_out="${full_path##*.}"; fi

	# F12. Выход не имеет права совпасть со входом. Проверка стоит ДО всего остального:
	# ниже готовый выход при провале ffprobe-валидации удаляется как «битый», а при
	# in==out этим «битым файлом» оказался бы сам оригинал — ещё до кодирования.
	# Разделения на части (pref) коллизию снимают, поэтому сверяем базовое имя.
	if [ "$(canon_path "${folder_destination}${file_path}${file_name}.${current_format_out}")" = "$(canon_path "$full_path")" ]; then
		log_msg "FAIL" "$(basename "$full_path"): выход совпадает с входом — файл пропущен (задайте другой destination, префикс или формат)"
		echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return
	fi

	# Готовность подтверждает manifest: state=complete + неизменившийся источник + все
	# перечисленные выходы на месте. Раньше признаком готовности считалось наличие одной
	# лишь `(part.1)` — если остальные части не создались (обрыв, падение, нехватка
	# места), весь input молча пропускался как «уже готовый» и хвост терялся навсегда.
	local manifest="${folder_destination}${file_path}.${file_name}.ffconv"
	local file_sig="${settings_sig}|fmt=${current_format_out}|copy=${copy_codecs}"
	if [ "$overwrite_existing" != "yes" ] && manifest_is_complete "$manifest" "$full_path" "$file_sig"; then
		echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return
	fi

	# F7. overwrite_existing=yes → готовый файл не считаем финальным и перекодируем с
	# новыми настройками (ffmpeg -y перезапишет). Иначе валидный файл пропускается.
	if [ "$overwrite_existing" != "yes" ]; then
		if [ -f "${folder_destination}${file_path}${file_name}.${current_format_out}" ]; then
			# E3. Проверка валидности существующего файла
			if "$ffmpeg" -nostdin -v error -i "${folder_destination}${file_path}${file_name}.${current_format_out}" -f null - 2>/dev/null; then
				echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return
			else
				log_msg "WARN" "Удаление битого файла: ${folder_destination}${file_path}${file_name}.${current_format_out}"
				rm -f "${folder_destination}${file_path}${file_name}.${current_format_out}"
			fi
		fi
	fi

	# E4 + J1. Один вызов ffmpeg -i для получения битрейта и длительности (раньше
	# запускались два отдельных pipeline'а на тот же файл — лишняя задержка для больших библиотек).
	local ffmpeg_info
	ffmpeg_info=$("$ffmpeg" -i "$full_path" 2>&1)

	# Битрейт ИМЕННО видеопотока: строка `Stream #0:0: Video: ..., 1808 kb/s`.
	# Раньше брали `Duration: ..., bitrate: 2000 kb/s` — это битрейт КОНТЕЙНЕРА
	# (видео + аудио + overhead). Настройка обещает не повышать исходный видеобитрейт,
	# а сравнивала с завышенным числом и потому всё равно его повышала.
	local src_video_bitrate=""
	src_video_bitrate=$(echo "$ffmpeg_info" | grep -i 'Stream #.*Video:' | head -1 \
		| grep -o '[0-9]\+ kb/s' | head -1 | grep -o '[0-9]\+')

	# Часть контейнеров (MKV/WebM) per-stream битрейт не сообщает. Тогда откатываемся
	# на битрейт контейнера — это верхняя оценка, а не битрейт видео, поэтому говорим
	# об этом в лог, а не выдаём молча за исходный видеобитрейт.
	local src_cap="$src_video_bitrate"
	if [ -z "$src_cap" ]; then
		src_cap=$(echo "$ffmpeg_info" | grep -i 'bitrate:' | head -1 | grep -o 'bitrate: [0-9]*' | sed 's/bitrate: //')
		if [ -n "$src_cap" ] && [ "$video_bitrate_status" = "+" ] && [ "$audio_only" != "yes" ]; then
			log_msg "WARN" "$(basename "$full_path"): битрейт видеопотока не сообщён, используется битрейт контейнера (${src_cap}k) — верхняя оценка"
		fi
	fi

	local set_video_bitrate_final=""
	if [ "$audio_only" != "yes" ] && [ "$video_bitrate_status" = "+" ] && [ "$video_quality_status" != "+" ]; then
		if [ -n "$src_cap" ] && [ "$src_cap" -lt "$set_video_bitrate_orig" ] 2>/dev/null; then
			set_video_bitrate_final="-b:v ${src_cap}k"
		else
			set_video_bitrate_final="-b:v ${set_video_bitrate_orig}k"
		fi
	fi

	local convert_settings
	if [ "$copy_codecs" = "yes" ]; then
		convert_settings="-c copy -map 0"
	else
		# -map_metadata 0 сохраняет глобальные теги источника (title/artist/date) при
		# перекодировании; несовместимые с контейнером — ffmpeg тихо отбрасывает.
		convert_settings="$video_settings $set_video_bitrate_final $audio_settings -map_metadata 0"
	fi

	local file_duration=0
	local dur_str=$(echo "$ffmpeg_info" | grep -i Duration: | grep -o '[0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*')
	if [ -n "$dur_str" ]; then
		IFS=':' read -r x y z <<< "$dur_str"
		file_duration=$((${x#0}*3600+${y#0}*60+${z#0}))
	fi

	# Видео-фильтры. vf_args/af_args — argv-массивы: значение фильтра (путь
	# субтитров, force_style с пробелами) проходит как ЕДИНЫЙ токен без word-splitting.
	local -a vf_args=()
	local current_vf_chain="$vf_chain"
	local -a af_args=()
	local current_af_chain="$af_chain"
	# Снимки до per-part модификаций (subtitles burn / meta -map). Восстанавливаются
	# в начале каждой итерации цикла по частям, иначе между частями накапливаются
	# "subtitles=...,subtitles=..." в vf_chain и "-map 0 -map 1 -map 0 -map 1" в convert_settings.
	local convert_settings_base="$convert_settings"
	local vf_chain_base="$current_vf_chain"
	local af_chain_base="$current_af_chain"

	if [ "$length_coding_status" = "+" ]; then
		local duration="$file_duration"

		local -a split_points=()
		if [ "$split_by_silence" = "yes" ]; then
			echo -e "\n\nЖдите! Идёт поиск пауз в файле:\n$full_path\n"
			local search_silence=$("$ffmpeg" -nostdin -i "$full_path" -nostats -af "silencedetect=n=${silence_threshold}:d=${silence_duration}" -f null - 2>&1 | grep -i silence_)
			local silence_start_val=""
			while IFS= read -r line; do
				if [[ "$line" == *"silence_start"* ]]; then
					silence_start_val=$(echo "$line" | grep -o 'silence_start: [0-9.]*' | sed 's/silence_start: //')
				fi
				if [[ "$line" == *"silence_end"* ]]; then
					local silence_end_val=$(echo "$line" | grep -o 'silence_end: [0-9.]*' | sed 's/silence_end: //')
					split_points+=($(awk "BEGIN {printf \"%d\", ($silence_start_val+$silence_end_val)/2}"))
				fi
			done <<< "$search_silence"
		fi

		# F16. Сначала строим МОНОТОННЫЙ массив границ, и только потом считаем длительности
		# как разность соседних границ. Раньше длина i-й части бралась как
		# length_coding_value-(part_start-new_part_start) — то есть в предположении, что
		# СЛЕДУЮЩАЯ граница осталась на номинальном месте. Но она тоже сдвигалась к своей
		# тишине → между частями появлялись зазоры и перекрытия.
		# length_silent[i] хранит длительность i-го куска; "END" = «до конца файла».
		# Локальный массив вместо eval-генерированных глобалов length_coding_value_silent${i} —
		# при экспорте функции для xargs они не дублируются и не пересекаются между файлами.
		local -a num=()
		local -a length_silent=()
		local max_parts=1000
		local i
		for ((i=0; i<max_parts; i++)); do
			local nominal=$((length_coding_value * i))
			if ((duration <= nominal)); then break; fi
			local bnd=$nominal
			# i==0 — начало файла: притягивать его к тишине нельзя, иначе начало срезается.
			if (( i > 0 )) && [ "$split_by_silence" = "yes" ] && [ ${#split_points[@]} -gt 0 ]; then
				local best_point=$nominal
				local best_diff=999999
				for p in "${split_points[@]}"; do
					local d=$((p - nominal))
					if (( d < 0 )); then d=$(( -d )); fi
					if (( d < best_diff )); then
						best_diff=$d
						best_point=$p
					fi
				done
				if (( best_diff <= length_coding_value/2 )); then bnd=$best_point; fi
			fi
			# Монотонность: граница обязана строго расти, иначе получим part нулевой или
			# отрицательной длины (две номинальные точки могли притянуться к одной тишине).
			if (( i > 0 )) && (( bnd <= num[i-1] )); then bnd=$nominal; fi
			if (( i > 0 )) && (( bnd <= num[i-1] )); then break; fi
			num+=("$bnd")
		done
		if (( i >= max_parts )); then
			log_msg "WARN" "Достигнут предел $max_parts частей — хвост файла не обработан: $(basename "$full_path")"
		fi
		# Длительности = разности соседних границ. Последняя часть идёт ДО КОНЦА файла:
		# фиксированный -t обрезал бы хвост, если граница сдвинулась к тишине назад.
		if [ "$split_by_silence" = "yes" ] && [ ${#num[@]} -gt 0 ]; then
			for ((i=0; i<${#num[@]}; i++)); do
				if (( i+1 < ${#num[@]} )); then
					length_silent[$i]=$(( num[i+1] - num[i] ))
				else
					length_silent[$i]="END"
				fi
			done
		fi
	else
		local -a num=(0)
	fi

	# Duration N/A или 0 → num пуст → файл молча пропускался. Обрабатываем целиком.
	if [ ${#num[@]} -eq 0 ]; then
		num=(0)
		log_msg "WARN" "Длительность неизвестна, разбиение пропущено: $(basename "$full_path")"
	fi

	if [ "$start_coding_status" = "+" ]; then num=($start_coding_value); fi

	# Готовые выходы копим, чтобы записать manifest одной транзакцией после цикла.
	local -a produced=()
	local any_fail="no"

	# F29. Размер входа засчитываем ОДИН раз на исходный файл. Раньше запись "ok"
	# писалась на каждую часть и несла полный размер источника, поэтому при разбиении
	# на N частей вход суммировался N раз — сводка показывала завышенное сжатие
	# (а при большом N — «отрицательное»). Выход при этом честно считается по частям.
	local in_reported=0
	local c=1
	for b in "${num[@]}"; do
		local pref=""
		if [ ${#num[@]} -gt 1 ] || [ "${num[0]}" != "0" ]; then
			pref=" (part.$c)"
		fi

		# Сброс из базы — см. _base снимки выше.
		convert_settings="$convert_settings_base"
		current_vf_chain="$vf_chain_base"
		current_af_chain="$af_chain_base"

		local current_set_length="$set_length_coding"
		if [ "$split_by_silence" = "yes" ] && [ "$length_coding_status" = "+" ]; then
			local silent_idx=$((c-1))
			# F16. "END" — последняя часть: -t не ставим вообще, иначе хвост обрезается.
			if [ "${length_silent[$silent_idx]:-}" = "END" ]; then
				current_set_length=""
			elif [ -n "${length_silent[$silent_idx]:-}" ]; then
				current_set_length="-t ${length_silent[$silent_idx]}"
			fi
		fi

		# B2. Субтитры с subtitles_style
		local subtitles_params=()
		local sub_burned="no"
		# audio_only != yes: при -vn прожиг субтитров (-vf) даёт "Video filtergraph but no
		# video output" — каждый файл падает. Субтитры имеют смысл только с видео-выходом.
		if [ "$video_subtitles_status" = "+" ] && [ "$copy_codecs" = "no" ] && [ "$audio_only" != "yes" ]; then
			local sub_found=""
			for ext in srt vtt; do
				if [ -z "$sub_found" ]; then
					# F32. Sidecar ищем по СТЕМУ входа: movie.srt рядом с movie.mp4.
					local sub_file="${folder_sources}${file_path}${input_stem}.${ext}"
					if [ -f "$sub_file" ]; then
						if [ "$video_subtitles_value" = "burn" ]; then
							sub_burned="yes"
							# Экранирование пути для subtitles=: backslash → forward slash (Windows-пути),
							# затем ' : — спецсимволы значения, [ ] ; — разделители graph-синтаксиса
							# фильтров, % — timecode-плейсхолдер. Порядок: слэши первыми.
							local sub_escaped=$(echo "$sub_file" | sed -e 's#\\#/#g' -e "s/'/\\\\'/g" -e 's/:/\\:/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g' -e 's/;/\\;/g' -e 's/%/\\%/g')
							# subtitles — CPU-фильтр: на GPU-кадрах (hwaccel_output_format cuda/qsv)
							# ffmpeg падает: "Impossible to convert between the formats". Скачиваем
							# кадры в системную память перед прожигом. Проверено на RTX 5060 Ti.
							if [ "$use_hw_accel" = "yes" ] && [[ "$current_vf_chain" != *hwdownload* ]]; then
								current_vf_chain="${current_vf_chain:+$current_vf_chain,}hwdownload,format=nv12"
							fi
							if [ -n "$subtitles_style" ]; then
								current_vf_chain="${current_vf_chain:+$current_vf_chain,}subtitles='${sub_escaped}':force_style='${subtitles_style}'"
							else
								current_vf_chain="${current_vf_chain:+$current_vf_chain,}subtitles='${sub_escaped}'"
							fi
						fi
						if [ "$video_subtitles_value" = "meta" ]; then
							subtitles_params=(-i "$sub_file" -c:s "$sub_meta_codec" -metadata:s:s:0 language=rus)
							convert_settings="$convert_settings -map 0 -map 1"
						fi
						sub_found=1
					fi
				fi
			done
		fi

		# Финализация фильтров
		if [ -n "$current_vf_chain" ]; then vf_args=(-vf "$current_vf_chain"); else vf_args=(); fi
		if [ -n "$current_af_chain" ]; then af_args=(-af "$current_af_chain"); else af_args=(); fi
		# copy_codecs несовместим с фильтрами
		if [ "$copy_codecs" = "yes" ]; then vf_args=(); af_args=(); fi

		local out_file="${folder_destination}${file_path}${file_name}${pref}.${current_format_out}"

		# -ss обычно ДО -i: fast seek по контейнеру (мгновенно), не декодируя от 0.
		# F5-исключение: при прожиге субтитров (sub_burned) с ненулевым стартом input-side
		# -ss обнуляет PTS кадров, а фильтр subtitles выбирает события по PTS → титры
		# съезжают/пропадают. Тогда -ss ставим на ВЫХОД (после -i): subtitles видит
		# исходные PTS, лишние кадры отбрасываются после прожига (медленнее, но верно).
		local in_seek="" out_seek=""
		if [ "$b" -gt 0 ] 2>/dev/null; then
			if [ "$sub_burned" = "yes" ]; then out_seek="-ss $b"; else in_seek="-ss $b"; fi
		fi
		# F11. Прогресс — против эффективной длины сегмента, а не полной длительности:
		# с -t L (или split-частями) out_time доходит лишь до L; иначе бар ползёт до крох %.
		local progress_dur="$file_duration"
		if [[ "$current_set_length" == "-t "* ]]; then
			progress_dur="${current_set_length#-t }"
		elif [ "$b" -gt 0 ] 2>/dev/null; then
			progress_dur=$((file_duration - b))
		fi
		[ "${progress_dur:-0}" -gt 0 ] 2>/dev/null || progress_dur="$file_duration"

		# D7. Dry-run
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 $hw_decode_args $in_seek -i \"$full_path\" ${subtitles_params[*]} $convert_settings $thread_args ${vf_args[*]} ${af_args[*]} $current_set_length $out_seek \"$out_file\""
		else
			log_msg "INFO" "Кодирование: $(basename "$full_path") -> $(basename "$out_file")"
			local encode_start=$(date +%s)

			# J1. Запуск ffmpeg в фоне с прогресс-файлом
			local progress_file err_file
			progress_file=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
			err_file=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")

			# Пишем в соседний temp и переименовываем только после rc=0. Прямая запись в
			# out_file означала, что прерванный прогон (Ctrl-C, падение, нехватка места)
			# оставлял обрезанный файл под финальным именем — следующий запуск принимал
			# его за готовый результат и пропускал. Переименование в пределах каталога
			# атомарно, поэтому имя цели появляется только у полностью записанного файла.
			local out_tmp
			out_tmp="$(partial_path "$out_file")"
			rm -f "$out_tmp"

			"$ffmpeg" -nostdin -hide_banner -strict -2 $hw_decode_args \
				$in_seek -i "$full_path" "${subtitles_params[@]}" \
				$convert_settings $thread_args "${vf_args[@]}" "${af_args[@]}" \
				$current_set_length $out_seek \
				-progress "$progress_file" -nostats \
				"$out_tmp" -y 2>"$err_file" &
			local ffmpeg_pid=$!
			_current_ffmpeg_pid=$ffmpeg_pid

			# Показываем прогресс-бар пока ffmpeg работает
			while kill -0 $ffmpeg_pid 2>/dev/null; do
				sleep 0.4
				if [ "$progress_dur" -gt 0 ] 2>/dev/null; then
					local out_time_str
					out_time_str=$(grep "^out_time=" "$progress_file" 2>/dev/null | tail -1 | cut -d= -f2)
					if [ -n "$out_time_str" ]; then
						local oh om os out_sec pct
						oh=$(echo "$out_time_str" | cut -d: -f1)
						om=$(echo "$out_time_str" | cut -d: -f2)
						os=$(echo "$out_time_str" | cut -d: -f3 | cut -d. -f1)
						if [[ "$oh$om$os" =~ ^[0-9]+$ ]] && [ "$progress_dur" -gt 0 ]; then
							out_sec=$(( 10#$oh * 3600 + 10#$om * 60 + 10#$os ))
							if [ "$out_sec" -gt 0 ]; then
								pct=$((out_sec * 100 / progress_dur))
								[ $pct -gt 100 ] && pct=100
								show_progress_bar $pct "$full_path"
							fi
						fi
					fi
				fi
			done
			wait $ffmpeg_pid
			local exit_code=$?
			_current_ffmpeg_pid=""
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
				rm -f "$out_tmp"
				any_fail="yes"
				echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
			else
				mv -f "$out_tmp" "$out_file"
				log_msg "OK" "$(basename "$full_path") -> $(basename "$out_file") (${elapsed_min}m ${elapsed_sec}s)"
				local out_sz in_sz
				out_sz=$(file_size "$out_file")
				# F29. Вход — только с первой удавшейся части (см. in_reported выше).
				in_sz=0
				if [ "$in_reported" -eq 0 ]; then
					in_sz=$(file_size "$full_path")
					in_reported=1
				fi
				produced+=("$out_file")
				echo "ok:${out_sz}:${in_sz}" > "$(mktemp "$results_dir/r_XXXXXXXX")"
			fi
			rm -f "$err_file"
		fi
		((c+=1))
	done

	# Manifest пишем только когда удались ВСЕ части. Именно его отсутствие заставит
	# следующий запуск доделать файл, вместо того чтобы принять уцелевшую (part.1) за
	# готовый результат. Частичный успех manifest'а не получает намеренно.
	if [ "$dry_run" != "yes" ] && [ "$any_fail" = "no" ] && [ ${#produced[@]} -gt 0 ]; then
		manifest_write "$manifest" "$full_path" "$file_sig" "${produced[@]}"
	fi
}

# `sort -z` — GNU-расширение, в штатном macOS/BSD sort его нет, а macOS заявлена
# в поддержке. Проверяем поддержку один раз. Fallback сортирует по \n: имена с
# переводом строки в нём не поддерживаются, и об этом честнее предупредить, чем
# молча выдать другой порядок склейки.
if printf 'a\0' | sort -z >/dev/null 2>&1; then
	sort_null() { sort -z; }
else
	sort_null() {
		[ -n "${_sort_z_warned:-}" ] || log_msg "WARN" "sort без -z (не GNU): порядок объединения не гарантирован для имён с переводом строки"
		_sort_z_warned=1
		tr '\0' '\n' | LC_ALL=C sort | tr '\n' '\0'
	}
fi

# F-modes. Спецрежимы (merge/extract/frame/copy/audio) взаимоисключающи по построению:
# при нескольких включённых часть опций молча игнорируется. Определяем ЭФФЕКТИВНЫЙ режим
# по документированному приоритету и ЯВНО предупреждаем о проигнорированных, а не молчим.
# Приоритет исполнения: merge > extract > frame > copy > audio > (обычный transcode).
_active_modes=""
[ "$merge_files" = "yes" ]        && _active_modes="${_active_modes} merge"
[ "$extract_audio_copy" = "yes" ] && _active_modes="${_active_modes} extract"
[ "$create_frame" = "yes" ]       && _active_modes="${_active_modes} frame"
[ "$copy_codecs" = "yes" ]        && _active_modes="${_active_modes} copy"
[ "$audio_only" = "yes" ]         && _active_modes="${_active_modes} audio"
_active_modes="${_active_modes# }"
if [ "$(printf '%s' "$_active_modes" | wc -w)" -gt 1 ]; then
	_mode_winner="${_active_modes%% *}"
	log_msg "WARN" "Включено несколько взаимоисключающих режимов ($_active_modes). Активен «$_mode_winner» (приоритет merge>extract>frame>copy>audio), остальные проигнорированы."
fi

# --- Основная логика ---
if [ "$merge_files" = "yes" ]; then
	# fname сбрасывается явно: переменная не локальна (merge — top-level, не функция),
	# при повторном source старое значение иначе осталось бы.
	fname=""
	while IFS= read -r -d '' full_path; do
		# F-collision: не берём собственные выходы (dest строго внутри source) как имя цели.
		if [ "$dest_inside_source" = "yes" ]; then
			case "$(canon_path "$full_path")" in "$canon_destination"/*) continue ;; esac
		fi
		if [ -z "$fname" ]; then fname=$(basename "$full_path"); break; fi
	done < <(find "$folder_sources" \( "${format_find_pred[@]}" \) -print0 | sort_null)
	if [ -z "$fname" ]; then
		log_msg "WARN" "Нет файлов для объединения в $folder_sources"
	elif [ "$overwrite_existing" = "yes" ] || [ ! -f "${folder_destination}/${fname}" ]; then
		concat_list=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
		# -printf — GNU-расширение (нет на macOS/BSD). Портативно: -print0 + read.
		# Имена с ' экранируем для concat-формата ffmpeg: ' -> '\''
		while IFS= read -r -d '' mf; do
			# F-collision: собственные выходы (dest строго внутри source) в concat не включаем.
			if [ "$dest_inside_source" = "yes" ]; then
				case "$(canon_path "$mf")" in "$canon_destination"/*) continue ;; esac
			fi
			printf "file '%s'\n" "${mf//\'/\'\\\'\'}" >> "$concat_list"
		done < <(find "$folder_sources" \( "${format_find_pred[@]}" \) -print0 | sort_null)
		# Мержим в соседний temp, а не сразу поверх цели. Прежний вызов шёл без -y на
		# существующий файл: ffmpeg спрашивал «File exists. Overwrite? [y/N]» и висел,
		# ожидая stdin, которого в batch/GUI нет. А упавший мерж оставлял partial под
		# именем цели, и следующий запуск принимал его за готовый результат.
		merge_tmp="$(partial_path "${folder_destination}/${fname}")"
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -hide_banner -nostdin -strict -2 -f concat -safe 0 -i \"$concat_list\" -c copy -map 0 -y \"$merge_tmp\""
			rm -f "$concat_list"
		else
			log_msg "INFO" "Объединение файлов -> ${folder_destination}/${fname}"
			rm -f "$merge_tmp"
			"$ffmpeg" -hide_banner -nostdin -strict -2 -f concat -safe 0 -i "$concat_list" -c copy -map 0 -y "$merge_tmp"
			merge_rc=$?
			# rc=0 сам по себе не гарантирует читаемый контейнер — валидируем тем же
			# `-f null -`, что и обычные выходные файлы, и только потом подменяем цель.
			if [ "$merge_rc" -eq 0 ] && [ -s "$merge_tmp" ] && \
			   "$ffmpeg" -nostdin -v error -i "$merge_tmp" -f null - 2>/dev/null; then
				mv -f "$merge_tmp" "${folder_destination}/${fname}"
				log_msg "OK" "Объединение файлов -> ${folder_destination}/${fname}"
				echo "ok:0:0" > "$results_dir/r_merge"
			else
				log_msg "FAIL" "Объединение файлов"
				rm -f "$merge_tmp"
				echo "fail" > "$results_dir/r_merge"
			fi
			rm -f "$concat_list"
		fi
	fi
else
	# B1b. Параллельная обработка файлов
	if [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		# canon_path/file_size/partial_path/manifest_* обязаны быть в списке: encode_file
		# зовёт их в дочерней оболочке `bash -c`. Без экспорта canon_path обе стороны
		# сравнения «выход == вход» становились пустыми строками — то есть равными, —
		# и в параллельном режиме КАЖДЫЙ файл отклонялся как ложная коллизия.
		export -f encode_file log_msg show_progress_bar human_size \
			canon_path file_size partial_path manifest_write manifest_is_complete
		export audio_only folder_sources folder_destination canon_destination dest_inside_source ffmpeg format_files_out video_settings audio_settings
		export save_old_extension create_frame copy_codecs split_by_silence extract_audio_copy
		export video_bitrate_status set_video_bitrate_orig video_quality_status
		export length_coding_status length_coding_value set_length_coding start_coding_status start_coding_value
		export video_subtitles_status video_subtitles_value subtitles_style
		export vf_chain af_chain hw_decode_args thread_args use_hw_accel
		export silence_threshold silence_duration dry_run enable_log log_file
		export overwrite_existing sub_meta_codec settings_sig
		export keep_aspect_ratio_status keep_aspect_ratio_value playback_speed_status playback_speed_value
		export results_dir
		find "$folder_sources" \( "${format_find_pred[@]}" \) -print0 | xargs -0 -P "$parallel_count" -I {} bash -c 'encode_file "$@"' _ {}
	else
		find "$folder_sources" \( "${format_find_pred[@]}" \) -print0 | while IFS= read -r -d '' full_path; do
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
# Exit code отражает наличие ошибок — cron/CI/GUI могут детектировать провал батча.
[ "$total_fail" -gt 0 ] && exit 1
exit 0
