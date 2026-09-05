#!/bin/bash

# ============================================================
# FFmpeg Converter Script (Bash)
# ============================================================

# --- F-path. Нормализация корневых путей ---
# Хвостовой разделитель в [folders] source/destination — обычный пользовательский ввод,
# но относительный путь подпапки считается ВЫЧИТАНИЕМ строки folder_sources из каталога
# файла (${file_path:${#folder_sources}}). Лишний '/' съедал ведущий разделитель, и
# склейка давала `.../outsub/movie.mp4` вместо `.../out/sub/movie.mp4` — каталог молча
# создавался, файлы уезжали рядом с destination. Корень ('/' и 'C:/') не трогаем.
norm_folder() {
	local p="$1"
	while [ ${#p} -gt 1 ] && [ "${p: -1}" = "/" ]; do
		case "$p" in ?:/) break ;; esac
		p="${p%/}"
	done
	printf '%s' "$p"
}
folder_sources="$(norm_folder "$folder_sources")"
folder_destination="$(norm_folder "$folder_destination")"

# --- Пауза «нажмите Enter» — только при интерактивном stdin ---
# Скрипт отдаёт exit code для cron/CI, но безусловный `read` ждал EOF: неинтерактивная
# джоба висела на паузе, а код возврата приходил с опозданием (или не приходил вовсе —
# по таймауту раннера). Терминала нет → паузы нет, поведение в консоли не меняется.
pause_prompt() {
	if [ -t 0 ]; then read -p "$1" _; fi
}

# --- E1. Проверка окружения ---
if [ ! -d "$folder_sources" ]; then
	echo -e "\n[ОШИБКА] Папка источника не найдена: $folder_sources\n"
	pause_prompt "Нажмите [Enter], чтобы выйти..."
	exit 1
fi

if [ ! -d "$folder_destination" ]; then
	mkdir -p "$folder_destination"
	if [ $? -ne 0 ]; then
		echo -e "\n[ОШИБКА] Не удалось создать папку назначения: $folder_destination\n"
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
fi

# Оба корня приводим к канонической форме СРАЗУ, пока не построен ни один путь.
# Карта коллизий выходов строит ключ склейкой `$folder_destination` с относительным
# путём, а пофайловая проверка канонизирует уже созданный каталог: при
# `destination = ../out` (или симлинке `~/Videos -> /mnt/nas`) ключ карты содержал
# `.../e2e/../out/sub/movie.mp4`, а проверка — `.../out/sub/movie.mp4`, и точное
# сравнение не находило совпадения — конфликт печатался, но второй вход всё равно
# кодировался поверх первого. Канонизация одна на прогон снимает весь класс.
_canon_root() {
	local p="$1"
	[ -d "$p" ] || { printf '%s' "$p"; return; }
	( cd "$p" 2>/dev/null && pwd -P ) || printf '%s' "$p"
}
folder_sources="$(norm_folder "$(_canon_root "$folder_sources")")"
folder_destination="$(norm_folder "$(_canon_root "$folder_destination")")"

# ffmpeg обязателен ровно тогда, когда именно он и считает. При
# [remote] enabled = yes считает служба, и требовать локальный ffmpeg значило бы
# закрывать заявленный сценарий «тонкий клиент»: слабая машина гонит пакет, не
# имея ffmpeg вовсе. Отсутствие при этом НЕ бесплатно — без него недоступны
# проверка скачанного результата и локальное определение длительности, поэтому
# говорим об этом вслух, а ниже отдельно отказываем там, где без него нельзя.
ffmpeg_available="yes"
if ! command -v "$ffmpeg" &> /dev/null; then
	if [ "${remote_enabled:-no}" = "yes" ]; then
		ffmpeg_available="no"
		echo -e "\n[ПРЕДУПРЕЖДЕНИЕ] ffmpeg не найден ($ffmpeg), но [remote] enabled = yes — кодирование считает служба."
		echo -e "[ПРЕДУПРЕЖДЕНИЕ] Без локального ffmpeg отключены: проверка скачанного результата и определение длительности.\n"
	else
		echo -e "\n[ОШИБКА] ffmpeg не найден: $ffmpeg\n"
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
fi

# Удалённый бэкенд — отдельный модуль. Подключаем всегда: он ничего не делает
# сам, только объявляет функции, а условие включения проверяется ниже.
# BASH_SOURCE, а не $0: скрипт дот-сорсится и из run.sh, и из тестов — $0 там
# указывает на вызывающий файл, и модуль искался бы не в той папке.
_ffconv_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "${_ffconv_script_dir}/remote_client.sh" ]; then
	source "${_ffconv_script_dir}/remote_client.sh"
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
		# Опечатка в значении (+nvida, +amd) означала «считаем на процессоре» — молча,
		# и пользователь узнавал об этом только по времени кодирования.
		*) echo "[ПРЕДУПРЕЖДЕНИЕ] Неизвестное значение [performance] hw_accel = '$hw_accel_value' (ожидается nvidia или intel). Кодирование идёт на процессоре." ;;
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
# Формат проверяем ДО арифметики: "1:00:00" (двоеточия вместо дефисов) или любой другой
# текст уходил прямо в $(( )), давал сырую "syntax error in expression" и оставлял
# значение пустым — разбиение молча работало не по тем границам. Паритет с
# ConvertTo-Seconds в .ps1 и :check_hms в .cmd.
check_hms() {
	local what="$1" val="$2"
	if [[ ! "$val" =~ ^[0-9]{1,2}-[0-9]{1,2}-[0-9]{1,2}$ ]]; then
		echo -e "\n[ОШИБКА] ${what}: ожидается чч-мм-сс (например 00-01-30), получено: '$val'\n"
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
}

IFS=':' read -r foo start_coding_status start_coding_value <<< "$start_coding"
if [ "$start_coding_status" = "+" ]; then
	check_hms "[split] start" "$start_coding_value"
	IFS='-' read -r x y z <<< "$start_coding_value"
	# 10# явно объявляет десятичную систему. Прежнее ${x#0} срезало ведущий ноль,
	# чтобы восьмеричная запись не превратила "09" в ошибку, — но на однозначном
	# поле ("0-5-0", валидном по регэкспу) оно давало ПУСТУЮ строку, $(( ))
	# печатал «arithmetic syntax error», значение оставалось текстом «0-5-0»,
	# -ss не подставлялся, а суффикс «(part.1)» ставился: файл кодировался
	# целиком под именем части, «Обработано: 1», rc=0. PS1 тот же ввод считал верно.
	start_coding_value=$((10#$x*3600 + 10#$y*60 + 10#$z))
fi
# Переменной set_start_coding здесь больше нет: она присваивалась и НИКОГДА не
# читалась. Смещение подставляется per-file через in_seek/out_seek (F5: при прожиге
# субтитров -ss обязан стоять на выходе), а призрачная переменная создавала ложное
# впечатление второго, работающего механизма.

IFS=':' read -r foo length_coding_status length_coding_value <<< "$length_coding"
if [ "$length_coding_status" = "+" ]; then
	check_hms "[split] length" "$length_coding_value"
	IFS='-' read -r x y z <<< "$length_coding_value"
	length_coding_value=$((10#$x*3600 + 10#$y*60 + 10#$z))
	# Нулевая длительность (`length = +00-00-00`) проходила валидацию и давала
	# `-t 0`: ffmpeg честно создавал пустые файлы и отчитывался успехом.
	if [ "$length_coding_value" -le 0 ]; then
		echo -e "
[ОШИБКА] [split] length: длительность должна быть больше нуля, получено: '00-00-00'
"
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
	set_length_coding="-t $length_coding_value"
else
	set_length_coding=""
	split_by_silence="no"
fi

# Суффикс " (part.N)", известный ЗАРАНЕЕ. При [split] start с ненулевым значением
# num = (start), часть всегда одна, и суффикс " (part.1)" добавляется гарантированно —
# значит имя выхода отличается от входа, и проверка «выход == вход» ниже обязана
# сверять имя С суффиксом. Иначе при in-place конвертации (destination == source)
# каждый файл получал ложный FAIL. Для [split] length число частей заранее неизвестно
# (нужна длительность), там проверка остаётся консервативной — см. её комментарий.
part_suffix_known=""
if [ "$start_coding_status" = "+" ] && [ "${start_coding_value:-0}" -ne 0 ] 2>/dev/null; then
	part_suffix_known=" (part.1)"
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
	# D3. Выходной контейнер.
	#
	# Расширение выхода и имя muxer'а — РАЗНЫЕ вещи, и ffmpeg выводит muxer из
	# расширения. Для части привычных расширений такого muxer'а нет вовсе:
	# `container = +m4v` даёт сырой elementary-stream (файл, который не откроет ни
	# один плеер), `.mpg` и `.wmv` — не те муксеры, `.mts/.m2ts` — не находятся.
	# Отображаем известные случаи и говорим об этом вслух: молча отдать
	# неоткрываемый файл хуже, чем сменить расширение с объяснением.
	if [ "$output_container_status" = "+" ]; then
		format_files_out="$output_container_value"
		case "$format_files_out" in
			m4v)        echo "[ПРЕДУПРЕЖДЕНИЕ] [video] container = m4v: ffmpeg выберет по расширению raw-muxer вместо MP4. Использую mp4."; format_files_out="mp4" ;;
			mpg)        echo "[ПРЕДУПРЕЖДЕНИЕ] [video] container = mpg: корректное имя контейнера — mpeg. Использую mpeg."; format_files_out="mpeg" ;;
			wmv)        echo "[ПРЕДУПРЕЖДЕНИЕ] [video] container = wmv: контейнер называется asf. Использую asf."; format_files_out="asf" ;;
			mts|m2ts)   echo "[ПРЕДУПРЕЖДЕНИЕ] [video] container = $format_files_out: контейнер называется mpegts. Использую mpegts."; format_files_out="mpegts" ;;
		esac
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
				# force_divisible_by=2 обязателен: на нестандартных пропорциях
			# force_original_aspect_ratio=decrease даёт нечётную сторону
			# (1366×768 в рамку 1280×720 → 1280×719), а yuv420p-энкодеры такие
			# кадры не принимают — «height not divisible by 2», файл падает.
			*)      vf_chain="${vf_chain:+$vf_chain,}scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" ;;
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
		pause_prompt "Нажмите [Enter], чтобы выйти..."
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
		pause_prompt "Нажмите [Enter], чтобы выйти..."
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
# [video] bitrate входит в подпись ОТДЕЛЬНО: он собирается per-file (потолок по
# исходному битрейту), поэтому в $video_settings его нет. Без него смена
# `bitrate = +3000` на `+1500` не устаревала manifest, и весь пакет отвечал
# «Обработано: 0, Пропущено: N» без единого вызова ffmpeg — при том что
# config.ini.example прямо обещает: при выключенном quality значим битрейт.
# Тот же класс уже закрывали для silence_* — закрываем и здесь.
settings_sig=$(printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s' \
	"$video_settings" "$audio_settings" "$vf_chain" "$af_chain" \
	"$format_files_out" "$sub_meta_codec" "$video_subtitles" "$subtitles_style" \
	"$start_coding" "$length_coding" "$split_by_silence" "$video_bitrate")
# При split_by_silence=yes границы частей задаются порогом/длительностью тишины: их смена
# меняет содержимое выходов, поэтому они обязаны обесценивать manifest. Вне режима split
# эти настройки на выход не влияют — в подпись их не добавляем (как потоки/overwrite).
if [ "$split_by_silence" = "yes" ]; then
	settings_sig="${settings_sig}|sil=${silence_threshold},${silence_duration}"
fi

# --- Формат входных файлов ---
# Предикаты find собираем массивом с quoted-паттернами: строка с *.ext без
# кавычек раскрывается shell-глоббингом по файлам в cwd и ломает выборку find.
#
# Пробелы вокруг элементов снимаются: `format_files_in = mp4, avi` — обычная запись
# через запятую с пробелом, и без trim предикат становился `-iname "*. avi"`, который
# не совпадает ни с чем: расширение молча выпадало из выборки. PS1 триммил, SH и CMD —
# нет; один config.ini обрабатывал разные наборы файлов на разных платформах.
# Ведущая точка тоже снимается (`.mp4` и `mp4` — одно и то же), пустые элементы
# отбрасываются: `mp4,,avi` иначе давал предикат `-iname "*."`.
format_find_pred=()
IFS=',' read -ra _ff_exts <<< "$format_files_in"
for _ff_e in "${_ff_exts[@]}"; do
	_ff_e="${_ff_e#"${_ff_e%%[![:space:]]*}"}"
	_ff_e="${_ff_e%"${_ff_e##*[![:space:]]}"}"
	_ff_e="${_ff_e#.}"
	[ -n "$_ff_e" ] || continue
	[ ${#format_find_pred[@]} -gt 0 ] && format_find_pred+=(-o)
	format_find_pred+=(-iname "*.${_ff_e}")
done
if [ ${#format_find_pred[@]} -eq 0 ]; then
	echo -e "\n[ОШИБКА] [files] format_files_in не содержит ни одного расширения: '$format_files_in'\n"
	pause_prompt "Нажмите [Enter], чтобы выйти..."
	exit 1
fi

# Относительный путь подпапки = каталог файла минус корень источника. Длину корня
# берём БЕЗ хвостового разделителя: у корня диска («D:/») и у POSIX-корня («/») он
# значащий и norm_folder его сохраняет, поэтому вычитание полной длины съедало
# ведущий разделитель относительного пути — склейка давала «E:/outDCIM/movie.mp4»
# вместо «E:/out/DCIM/movie.mp4», а файлы верхнего уровня уезжали в «E:/outmovie.mp4».
# Источником-корнем работает, например, вставленная SD-карта.
_src_prefix_len=${#folder_sources}
case "$folder_sources" in
	*/) _src_prefix_len=$((_src_prefix_len - 1)) ;;
esac

# Единая выборка входов для всех веток (карта коллизий, merge, параллель, цикл).
#   -type f — каталог, чьё имя оканчивается на расширение из format_files_in
#     ("season.mp4"), иначе попадал во вход: ffmpeg падал на нём лишним FAIL, а его
#     «выход» занимал имя, под которым должен быть создан каталог зеркала.
#     Фикс уже был в .ps1 (Get-ChildItem -File) — здесь паритет.
#   ! -name '.ffconv-partial-*' — недобитые temp-файлы прерванного прогона подпадают
#     под -iname "*.mp4" и в in-place режиме (destination == source) становились
#     входами следующего запуска.
find_inputs() {
	find "$folder_sources" -type f ! -name '.ffconv-partial-*' \( "${format_find_pred[@]}" \) -print0
}

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
_any_input="no"

# Cleanup при Ctrl-C/SIGTERM: убить текущий ffmpeg-процесс и удалить temp-каталог
# результатов, иначе остаётся осиротевший ffmpeg и мусор в /tmp. НЕ ловим EXIT —
# нормальное завершение чистит results_dir явно, а trap EXIT клобберил бы trap теста
# (тесты ставят свой trap EXIT для дампа переменных при source).
_current_ffmpeg_pid=""
_current_out_tmp=""
# Прочие временные файлы прогона: progress/err текущего ffmpeg, карта коллизий,
# concat-список и temp объединения, кусок для отправки на службу. Регистрируются
# по мере создания — иначе Ctrl+C оставлял их в /tmp и в destination.
_tmp_files=()
_register_tmp() { [ -n "$1" ] && _tmp_files+=("$1"); }
_cleanup_on_int() {
	# Брошенная задача продолжила бы держать карту на сервере до своего таймаута.
	[ -n "${REMOTE_CURRENT_JOB:-}" ] && remote_cancel "$REMOTE_CURRENT_JOB"
	[ -n "$_current_ffmpeg_pid" ] && kill "$_current_ffmpeg_pid" 2>/dev/null
	[ -n "$_current_out_tmp" ] && rm -f "$_current_out_tmp"
	# Параллельный режим: дети не увидят сигнал, если он пришёл только родителю
	# (`kill <pid>` от timeout/systemd, в отличие от Ctrl+C по всей process group).
	# Шлём им TERM явно — каждый выполнит _cleanup_child_on_int и уберёт свой хвост.
	local _kids
	_kids="$(jobs -p 2>/dev/null)"
	if [ -n "$_kids" ]; then
		kill -TERM $_kids 2>/dev/null
		wait 2>/dev/null
	fi
	local _t
	for _t in "${_tmp_files[@]}"; do [ -n "$_t" ] && rm -f "$_t"; done
	[ -n "$results_dir" ] && rm -rf "$results_dir"
	[ -n "${collisions_file:-}" ] && rm -f "$collisions_file"
	exit 130
}
trap _cleanup_on_int INT TERM

# Cleanup для дочерних `bash -c` из параллельной ветки. Своего trap'а у них не было:
# при SIGTERM (закрытие из GUI, kill по PID) родитель успевал снести results_dir, а
# осиротевшие ffmpeg продолжали писать .ffconv-partial-* в destination. Ctrl-C спасала
# только доставка сигнала всей process group. results_dir/collisions_file дочерний
# процесс НЕ трогает — они общие, их чистит родитель.
_cleanup_child_on_int() {
	[ -n "${REMOTE_CURRENT_JOB:-}" ] && remote_cancel "$REMOTE_CURRENT_JOB"
	[ -n "${_current_ffmpeg_pid:-}" ] && kill "$_current_ffmpeg_pid" 2>/dev/null
	[ -n "${_current_out_tmp:-}" ] && rm -f "$_current_out_tmp"
	# Свои temp-файлы (progress/err текущего ffmpeg, кусок для отправки) ребёнок
	# регистрирует в собственной копии массива — родитель их не видит.
	local _t
	for _t in "${_tmp_files[@]}"; do [ -n "$_t" ] && rm -f "$_t"; done
	exit 130
}

file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }

# --- Транзакционная запись: имя временного файла ---
# Временное имя строится ПРЕФИКСОМ, а не суффиксом, потому что расширение обязано
# сохраниться: без -f ffmpeg выводит muxer из расширения, а режимы copy_codecs и
# merge как раз идут с `-c copy` без -f. Суффиксное `.movie.mp4.partial` давало
# "Error initializing the muxer ... Invalid argument" на настоящем ffmpeg.
partial_path() { printf '%s/.ffconv-partial-%s' "$(dirname "$1")" "$(basename "$1")"; }

# --- Публикация результата: общая для локального и удалённого путей ---
# Вынесена, чтобы переименование, лог и учёт байтов существовали в ОДНОМ
# экземпляре: разойдись они, «успех» на одном пути значил бы не то же, что на
# другом, и сводка ok/fail перестала бы что-либо значить.
#
# Пятый аргумент — проверять ли содержимое (`-s` и `-f null -`). Он есть только
# у удалённого пути и именно поэтому необязателен: локальный ffmpeg с rc=0
# нулевого или битого файла не оставляет, а оборванная загрузка — запросто.
# Включать проверку и локально значило бы декодировать КАЖДЫЙ выход целиком
# вторым проходом — на многогигабайтном пакете это минуты на файл ни за что.
publish_result() {
	local src="$1" tmp="$2" dst="$3" started="$4" verify="${5:-no}"
	local elapsed=$(( $(date +%s) - started ))
	# Без локального ffmpeg декодировать нечем: остаётся проверка на непустой
	# файл. Пропускать её молча нельзя — оборванная загрузка выглядит успехом.
	# Служба сообщила sha256 (или размер) результата, и скачанное с ним сошлось —
	# это ответ на тот же вопрос, что и `-f null -`, но точнее и почти бесплатно.
	# Второй полный декод трёхгигабайтного выхода стоил бы минут НА ФАЙЛ, и именно
	# поэтому проверка содержимого включена только на удалённом пути.
	if [ "$verify" = "yes" ] && [ "${REMOTE_RESULT_VERIFIED:-no}" = "yes" ]; then
		verify="hash-ok"
	fi
	if [ "$verify" = "yes" ] && [ "$ffmpeg_available" != "yes" ]; then
		verify="size-only"
		log_msg "WARN" "$(basename "$src"): без локального ffmpeg результат проверен только по размеру"
	fi
	if [ "$verify" = "hash-ok" ] && [ ! -s "$tmp" ]; then
		log_msg "FAIL" "$(basename "$src"): скачан пустой результат"
		rm -f "$tmp"
		any_fail="yes"
		echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return 1
	fi
	if [ "$verify" = "size-only" ] && [ ! -s "$tmp" ]; then
		log_msg "FAIL" "$(basename "$src"): скачан пустой результат"
		rm -f "$tmp"
		any_fail="yes"
		echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return 1
	fi
	if [ "$verify" = "yes" ]; then
		if [ ! -s "$tmp" ] || ! "$ffmpeg" -nostdin -v error -i "$tmp" -f null - 2>/dev/null; then
			log_msg "FAIL" "$(basename "$src"): результат не прошёл проверку"
			rm -f "$tmp"
			any_fail="yes"
			echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
			return 1
		fi
	fi
	# F-rename. Публикацию подтверждаем: успех mv И наличие файла-цели. Молчаливый
	# провал rename (цель заблокирована, нет места) иначе выдал бы отсутствующий или
	# старый результат за успех — с записью manifest поверх него.
	if mv -f "$tmp" "$dst" 2>/dev/null && [ -f "$dst" ]; then
		log_msg "OK" "$(basename "$src") -> $(basename "$dst") ($((elapsed / 60))m $((elapsed % 60))s)"
		local out_sz in_sz=0
		out_sz=$(file_size "$dst")
		# F29. Вход — только с первой удавшейся части (см. in_reported выше).
		if [ "$in_reported" -eq 0 ]; then in_sz=$(file_size "$src"); in_reported=1; fi
		produced+=("$dst")
		echo "ok:${out_sz}:${in_sz}" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return 0
	fi
	log_msg "FAIL" "$(basename "$src"): не удалось опубликовать результат (rename)"
	rm -f "$tmp"
	any_fail="yes"
	echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
	return 1
}

# --- Откат на локальный ffmpeg: только по ключу и только шумно ---
# Отказ от МОЛЧАЛИВОГО отката остаётся в силе и обоснован: тихий переход на
# процессор на двухстах файлах неотличим от зависания. Но между «тихо считать
# локально» и «бросить остаток пакета, если служба легла на сотом файле» есть
# третье поведение, и выбирает его пользователь, а не мы за него.
#
# Умолчание [remote] on_failure = abort — прежнее поведение до буквы. При
# on_failure = local каждый откат печатает причину, попадает в отдельный счётчик
# сводки и делает код возврата ненулевым: тишины по-прежнему нет ни в одной точке,
# снимается только потеря работы.
remote_fallback_allowed() {
	local src="$1" reason="$2"
	[ "${remote_on_failure:-abort}" = "local" ] || return 1
	# Тонкий клиент без ffmpeg откатываться некуда — честнее сказать это вслух.
	if ! command -v "$ffmpeg" >/dev/null 2>&1; then
		log_msg "WARN" "$(basename "$src"): $reason, а локального ffmpeg нет — откат невозможен"
		return 1
	fi
	# Отмена пользователем (Stop/Ctrl+C) — не «служба недоступна»: считать файл
	# локально после явной остановки значит проигнорировать саму остановку.
	if [ -n "${guiCancelFile:-}" ] && [ -f "${guiCancelFile:-/dev/null}" ]; then
		log_msg "WARN" "$(basename "$src"): $reason, но прогон остановлен — локально не считаем"
		return 1
	fi
	echo "[ПРЕДУПРЕЖДЕНИЕ] $(basename "$src"): $reason — считаем локально (on_failure = local)."
	log_msg "WARN" "$(basename "$src"): $reason — откат на локальный ffmpeg"
	# Маркер пишется ЗДЕСЬ, до локального кодирования, и это осознанно: строка сводки
	# называется «Посчитано локально», то есть считает ПЕРЕВЕДЁННЫЕ на локальный путь
	# файлы, а не успешные. Провалившийся откат отдельно попадёт в «Ошибки» — двойного
	# учёта нет, потому что счётчики разные и печатаются разными строками.
	echo "local" > "$(mktemp "$results_dir/lf_XXXXXXXX")"
	return 0
}

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

# Ключ карты коллизий. На NTFS (Git Bash) и APFS (macOS) регистр в именах не значим,
# поэтому «Movie.avi» и «movie.mp4» претендуют на ОДИН выход — а точное сравнение строк
# этого не видело: SH кодировал оба в один файл и отчитывался «Обработано: 2», тогда как
# PS1 и CMD давали обоим FAIL. Регистр опускаем ровно там, где ФС его игнорирует, —
# на Linux (case-sensitive) это дало бы ложные конфликты.
_fs_case_insensitive="no"
case "$(uname -s 2>/dev/null)" in
	MINGW*|MSYS*|CYGWIN*|Darwin) _fs_case_insensitive="yes" ;;
esac
collision_key() {
	if [ "$_fs_case_insensitive" = "yes" ]; then
		printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'
	else
		printf '%s' "$1"
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
# Третий аргумент — ПОДПИСЬ ФАЗЫ, и она отделена от имени файла намеренно.
# Локальный путь состоит из одной фазы, поэтому подписи там нет; удалённый — из
# четырёх (отправка → очередь/ожидание карты → кодирование → скачивание), и
# раньше каждая называла себя по-своему: слово «отправка» подставлялось ВМЕСТО
# имени файла, ожидание карты печатало свою строку поверх бара, а скачивание не
# показывало ничего. На файле в 3 ГБ «ничего не происходит» длится минуты и
# неотличимо от зависания — ровно того, ради недопущения которого писалась вся
# политика отказов удалённого пути.
show_progress_bar() {
	local pct="$1" label="$2" phase="${3:-}"
	# Процент приходит и из ответа службы: там он бывает пустым (поля нет),
	# «null» или дробным («42.5»). `printf %d` на таком значении печатает
	# «invalid number», а `$(( ))` — «arithmetic syntax error», и это на КАЖДОМ
	# опросе задачи. Приводим к целому здесь, а не в каждом вызывающем.
	pct="${pct%%.*}"
	case "$pct" in
		''|*[!0-9]*) pct=0 ;;
	esac
	[ "$pct" -gt 100 ] 2>/dev/null && pct=100
	# Параллельный режим: N подоболочек пишут в один терминал, и `\r`-бары рисуются
	# поверх друг друга — на экране мелькает мешанина, по которой не видно ни одного
	# файла целиком. Тогда переходим на построчный вывод и печатаем не чаще, чем раз
	# в REPORT-секунд на файл: это читаемо и не заливает лог.
	if [ "${parallel_count:-1}" -gt 1 ] 2>/dev/null; then
		local now; now=$(date +%s)
		local every="${FFCONV_PARALLEL_REPORT_SECONDS:-5}"
		if [ "$pct" -ge 100 ] || [ -z "${_pp_last:-}" ] || [ $((now - _pp_last)) -ge "$every" ]; then
			_pp_last="$now"
			printf '  %s: %d%%%s\n' "$(basename "$label")" "$pct" "${phase:+  · $phase}"
		fi
		return
	fi
	local filled=$((pct / 2)) empty=$((50 - pct / 2)) bar=""
	for ((j=0; j<filled; j++)); do bar="${bar}#"; done
	for ((j=0; j<empty; j++)); do bar="${bar}."; done
	printf "\r  [%s] %3d%%  %s%s" "$bar" "$pct" "$(basename "$label")" "${phase:+  · $phase}"
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
	file_path="${file_path:$_src_prefix_len}"
	# D7. Dry-run только печатает команды — каталоги зеркала не создаём. Иначе
	# «безопасный» прогон оставлял дерево пустых подпапок в destination (и маскировал
	# ошибки в самом пути: пользователь видел созданный каталог и считал путь верным).
	if [ "$dry_run" != "yes" ] && [ ! -d "$folder_destination$file_path" ]; then mkdir -p "$folder_destination$file_path"; fi

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
		# F12 для extract. Расширение выхода выбирается по кодеку ИСХОДНИКА, поэтому при
		# in-place (destination == source) вход вида song.m4a/song.mp3/song.ogg/song.flac
		# даёт выход, равный входу. Дальше overwrite_existing=yes удалял этот файл ДО
		# запуска ffmpeg — и ffmpeg падал на несуществующем входе, а исходник был потерян
		# безвозвратно. Проверка стоит ДО overwrite-блока и до любой мутации.
		if [ "$(canon_path "$out_audio")" = "$(canon_path "$full_path")" ]; then
			log_msg "FAIL" "$(basename "$full_path"): выход совпадает с входом (извлечение аудио в тот же файл)"
			echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
			return
		fi
		# Единый overwrite-контракт: как и обычный режим, extract при overwrite_existing=yes
		# перезаписывает готовый файл, а не пропускает его молча (раньше пропуск был
		# безусловным — overwrite_existing=yes для этого режима не работал).
		# D7. Удаление готового файла — мутация; при dry_run её делать нельзя, иначе режим,
		# обещающий лишь показать команду, реально уничтожает данные (ffmpeg -y ниже и так
		# перезапишет выход при настоящем прогоне).
		if [ -f "$out_audio" ]; then
			if [ "$overwrite_existing" = "yes" ]; then
				[ "$dry_run" = "yes" ] || rm -f "$out_audio"
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
		# F-percent. `%` в имени файла ИЛИ в пути ломает image2-мультиплексор: после `%`
		# он принимает только d/цифру/%, всё прочее — «Invalid argument». Удваиваем `%`
		# везде, кроме нашего собственного счётчика `%05d`, — image2 читает `%%` как один
		# литеральный `%`. Файл «50% off.mp4» до этого падал на каждом прогоне.
		local frame_out="${frame_dir//%/%%}/${file_name//%/%%}_%05d.png"
		if [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 -i \"$full_path\" -r 1/1 \"$frame_out\""
			return
		fi
		# Частичный каталог с прошлого прогона удаляем, чтобы кадры не смешивались — но
		# ТОЛЬКО если каталог наш. Рекурсивное удаление раньше применялось к ЛЮБОМУ
		# существующему каталогу с именем стема: при in-place `clip.mp4` рядом с
		# пользовательским каталогом `clip/` тот вычищался без единого сообщения.
		# Признак «наш» — маркер начала или завершения внутри; пустой каталог безопасен.
		local frame_partial="${frame_dir}/.frames_partial"
		if [ -d "$frame_dir" ]; then
			if [ -f "$frame_partial" ] || [ -f "$frame_done" ]; then
				rm -rf "$frame_dir"
			elif [ -n "$(ls -A "$frame_dir" 2>/dev/null)" ]; then
				log_msg "FAIL" "$(basename "$full_path"): каталог кадров занят посторонними файлами: $frame_dir"
				echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return
			fi
		fi
		mkdir -p "$frame_dir"
		: > "$frame_partial"
		log_msg "INFO" "Извлечение кадров: $full_path"
		"$ffmpeg" -nostdin -hide_banner -strict -2 -i "$full_path" -r 1/1 "$frame_out"
		if [ $? -ne 0 ]; then
			log_msg "FAIL" "$(basename "$full_path")"
			rm -rf "$frame_dir"
			echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		else
			rm -f "$frame_partial"
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
	# Суффикс " (part.N)" коллизию снимает, поэтому заранее известный суффикс
	# (part_suffix_known — режим [split] start) в сравнение включён. При [split] length
	# число частей зависит от длительности и здесь ещё неизвестно, поэтому сверяем
	# базовое имя — сознательный консерватизм: лучше отклонить файл, чем закодировать
	# его поверх самого себя.
	local canon_out="$(canon_path "${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}")"
	if [ "$canon_out" = "$(canon_path "$full_path")" ]; then
		log_msg "FAIL" "$(basename "$full_path"): выход совпадает с входом — файл пропущен (задайте другой destination, префикс или формат; при [split] length имя частей заранее неизвестно, поэтому in-place отклоняется)"
		echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return
	fi

	# ВАЖЕН ПОРЯДОК: manifest проверяется РАНЬШЕ карты коллизий. При in-place
	# (destination == source) повторный прогон видит и movie.avi, и уже созданный
	# movie.mp4 — оба претендуют на один выход, и карта давала FAIL «конфликт
	# выходов» файлу, который на самом деле давно готов. Готовность старше спора.
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

	# F-collision-map. Выход этого файла оспаривается другим входом (карта построена
	# до кодирования). Обрабатывать нельзя: кто-то из группы затрёт чужой результат.
	if [ -n "${collisions_file:-}" ] && [ -s "${collisions_file:-/dev/null}" ] \
		&& LC_ALL=C grep -qxF -- "$(collision_key "$canon_out")" "$collisions_file"; then
		log_msg "FAIL" "$(basename "$full_path"): конфликт выходов — файл пропущен"
		echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return
	fi

	# F7. overwrite_existing=yes → готовый файл не считаем финальным и перекодируем с
	# новыми настройками (ffmpeg -y перезапишет). Иначе валидный файл пропускается.
	if [ "$overwrite_existing" != "yes" ]; then
		if [ -f "${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}" ]; then
			# E3. Проверка валидности существующего файла. Без локального ffmpeg
			# проверить нечем, и «не прошёл проверку» означало бы УДАЛЕНИЕ готового
			# файла из-за отсутствия инструмента — считаем такой файл готовым.
			if [ "$ffmpeg_available" != "yes" ]; then
				echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return
			elif "$ffmpeg" -nostdin -v error -i "${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}" -f null - 2>/dev/null; then
				echo "skip" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				return
			elif [ "$dry_run" = "yes" ]; then
				# D7. Dry-run обещает «только показать команды». Удаление битого выхода —
				# мутация, и при холостом прогоне её быть не должно.
				log_msg "WARN" "[DRY-RUN] битый файл был бы удалён: ${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}"
			else
				log_msg "WARN" "Удаление битого файла: ${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}"
				rm -f "${folder_destination}${file_path}${file_name}${part_suffix_known}.${current_format_out}"
			fi
		fi
	fi

	# E4 + J1. Один вызов ffmpeg -i для получения битрейта и длительности (раньше
	# запускались два отдельных pipeline'а на тот же файл — лишняя задержка для больших библиотек).
	local ffmpeg_info=""
	if [ "$ffmpeg_available" = "yes" ]; then
		ffmpeg_info=$("$ffmpeg" -i "$full_path" 2>&1)
	fi

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

	# Идентификатор загрузки объявляем ЗДЕСЬ, до расчёта границ частей: тонкому
	# клиенту без локального ffmpeg длительность известна только из ответа службы,
	# а нужна она раньше — иначе «запасной источник длительности», обещанный
	# CLAUDE.md, мёртв, и [split] length у тонкого клиента не работает вовсе.
	# Загрузка одна на исходный файл; блок в цикле по частям её не повторит.
	local remote_upload_id="" remote_sub_id=""
	local file_duration=0
	local dur_str=$(echo "$ffmpeg_info" | grep -i Duration: | grep -o '[0-9][0-9]*:[0-9][0-9]*:[0-9][0-9]*')
	if [ -n "$dur_str" ]; then
		IFS=':' read -r x y z <<< "$dur_str"
		# 10#, а не ${x#0}: на однозначном поле срез ведущего нуля даёт пустую
		# строку и «arithmetic syntax error» (см. check_hms выше).
		file_duration=$((10#$x*3600 + 10#$y*60 + 10#$z))
	fi

	# Запасной источник длительности — ответ службы на POST /uploads/{id}/complete.
	# Он нужен ДО расчёта границ частей, поэтому загрузку делаем здесь, а не в цикле:
	# иначе `remote_active = yes` + `[split] length` у тонкого клиента давали
	# «Длительность неизвестна, разбиение пропущено», и обещанный фолбэк был мёртв.
	# Условия узкие намеренно: обычный клиент с ffmpeg сюда не заходит вовсе, а
	# dry_run не грузит байты по определению.
	if [ "$remote_active" = "yes" ] && [ "$dry_run" != "yes" ] && \
	   [ "${file_duration:-0}" -le 0 ] 2>/dev/null && [ "$length_coding_status" = "+" ]; then
		log_msg "INFO" "Длительность неизвестна локально — берём её у службы: $(basename "$full_path")"
		REMOTE_UPLOAD_SIDECAR="${manifest}.upload"
		if remote_upload "$full_path"; then
			remote_upload_id="$REMOTE_UPLOAD_ID"
			printf "\n"
			[ -n "${REMOTE_UPLOAD_DURATION:-}" ] && file_duration="${REMOTE_UPLOAD_DURATION%%.*}"
		else
			printf "\n"
		fi
		REMOTE_UPLOAD_SIDECAR=""
		[ "${file_duration:-0}" -gt 0 ] 2>/dev/null || file_duration=0
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
			# Знак обязателен в шаблоне: ffmpeg печатает и отрицательный silence_start
			# (например "silence_start: -0.0261224"), а шаблон без минуса давал ПУСТОЕ
			# значение — следующая же строка silence_end роняла awk синтаксической
			# ошибкой на "(+12.3)/2" и разбиение по паузам молча теряло точку.
			while IFS= read -r line; do
				if [[ "$line" == *"silence_start"* ]]; then
					silence_start_val=$(echo "$line" | grep -oE 'silence_start: -?[0-9.]+' | sed 's/silence_start: //')
				fi
				if [[ "$line" == *"silence_end"* ]]; then
					local silence_end_val=$(echo "$line" | grep -oE 'silence_end: -?[0-9.]+' | sed 's/silence_end: //')
					if [ -n "$silence_start_val" ] && [ -n "$silence_end_val" ]; then
						split_points+=($(awk "BEGIN {printf \"%d\", ($silence_start_val+$silence_end_val)/2}"))
					fi
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
		# в параллельном режиме каждая подоболочка получает свою копию, и границы частей
		# одного файла не протекают в соседний.
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
	#
	# «Целиком» обязано означать целиком. Раньше сбрасывался только массив границ, а
	# current_set_length оставался равным `-t L` — выход без суффикса «(part.N)»
	# содержал ПЕРВЫЕ L секунд, статус OK, manifest записан, и следующий прогон
	# пропускал файл навсегда. Входы с Duration: N/A реальны: недописанные mkv/webm,
	# часть .vob/.mts. Обрезать втихую то, что обещали обработать целиком, нельзя.
	local length_disabled="no"
	if [ ${#num[@]} -eq 0 ]; then
		num=(0)
		if [ -n "$set_length_coding" ]; then
			log_msg "WARN" "Длительность неизвестна: разбиение пропущено И ограничение длительности снято, файл обрабатывается целиком: $(basename "$full_path")"
			length_disabled="yes"
		else
			log_msg "WARN" "Длительность неизвестна, разбиение пропущено: $(basename "$full_path")"
		fi
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
		# Длительность неизвестна → -t снят вместе с разбиением (см. выше).
		[ "$length_disabled" = "yes" ] && current_set_length=""
		if [ "$split_by_silence" = "yes" ] && [ "$length_coding_status" = "+" ] && [ "$length_disabled" != "yes" ]; then
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
							#
							# Апостроф — единственный символ, которого не спасают кавычки вокруг
							# значения: по правилам ffmpeg («Quoting and Escaping», av_get_token)
							# внутри '…' backslash копируется буквально, а первая же ' закрывает
							# строку. Разбор двухуровневый (граф фильтров → опции фильтра),
							# поэтому и экранирований нужно два:
							#   уровень опций: ' → \'
							#   уровень графа: ' → '\''
							# вместе: ' → \'\''. Проверено на ffmpeg 8.1.2 прямым прогоном:
							# и \' , и '\'' по отдельности дают «Unable to open …/its video»
							# (апостроф просто съедается), а force_style после этого
							# разбирается как продолжение имени файла — падал каждый файл
							# в папке вроде «John's videos».
							local _sq="'" _sq_esc="\\'\\''"
							local sub_escaped="${sub_file//\\//}"
							sub_escaped="${sub_escaped//$_sq/$_sq_esc}"
							sub_escaped="${sub_escaped//:/\\:}"
							sub_escaped="${sub_escaped//\[/\\[}"
							sub_escaped="${sub_escaped//\]/\\]}"
							sub_escaped="${sub_escaped//;/\\;}"
							sub_escaped="${sub_escaped//%/\\%}"
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

		# Удалённый бэкенд подменяет РОВНО этот участок: сборку argv и запуск
		# ffmpeg. Всё до (manifest, коллизии, имена частей) и всё после
		# (валидация, mv, сводка, manifest_write) остаётся общим — именно
		# поэтому один config.ini даёт один результат на обоих путях.
		#
		# part_remote — решение ДЛЯ ЭТОЙ ЧАСТИ, а не для прогона: при
		# [remote] on_failure = local неудача службы переводит часть на
		# локальный ffmpeg, и она обязана провалиться в тот же самый код, что
		# и обычный локальный путь. Дубль локальной ветки означал бы два
		# разных «кодирования» из одного config.ini — ровно то, что
		# publish_result держит в одном экземпляре.
		local part_remote="$remote_active"
		local part_done="no"
		if [ "$part_remote" = "yes" ]; then
			local r_len=0
			[[ "$current_set_length" == "-t "* ]] && r_len="${current_set_length#-t }"
			local r_op r_params r_out
			# Третий аргумент — «sidecar найден»: без него поле subtitles уезжало
			# службе и при отсутствующем файле титров.
			r_out="$(remote_op_for_config "${b:-0}" "$r_len" "${sub_found:-0}")" || {
				log_msg "FAIL" "$(basename "$full_path"): кодек $set_video_codec служба не поддерживает"
				any_fail="yes"
				echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				((c+=1)); continue
			}
			r_op="$(printf '%s' "$r_out" | head -1)"
			r_params="$(printf '%s' "$r_out" | tail -1)"

			# Загрузка одна на файл, задач — по одной на часть. Второй раз те же
			# гигабайты не отправляются.
			#
			# remote_upload и remote_submit возвращают результат ПЕРЕМЕННОЙ
			# (REMOTE_UPLOAD_ID / REMOTE_JOB_ID), а не через stdout. Вызов через
			# `$( )` складывал в переменную прогресс-бар и строки лога вместе с
			# идентификатором — служба обязана была отвечать 400 на каждом файле.
			# dry_run НЕ загружает: «только показать команды» не имеет права стоить
			# часов трафика и гигабайт в хранилище службы (задача при этом не
			# создаётся и место не освобождает). Тело запроса печатается ниже.
			if [ "$part_remote" = "yes" ] && [ "$dry_run" = "yes" ]; then
				remote_upload_id="<pending>"
			elif [ "$part_remote" = "yes" ] && [ -z "${remote_upload_id:-}" ]; then
				log_msg "INFO" "Отправка на сервер: $(basename "$full_path")"
				# Sidecar рядом с manifest'ом: повторный запуск после обрыва
				# доходит до GET /uploads/<id> с настоящим смещением вместо того,
				# чтобы просить новую загрузку и лить гигабайты заново.
				REMOTE_UPLOAD_SIDECAR="${manifest}.upload"
				if remote_upload "$full_path"; then
					remote_upload_id="$REMOTE_UPLOAD_ID"
					printf "\n"
					# Длительность из ответа службы — запасной источник для тонкого
					# клиента без локального ffmpeg (см. remote_active ниже).
					if [ "${file_duration:-0}" -le 0 ] 2>/dev/null && \
					   [ -n "${REMOTE_UPLOAD_DURATION:-}" ]; then
						file_duration="${REMOTE_UPLOAD_DURATION%%.*}"
					fi
					# Файл субтитров приходит той же дорогой, что видео: путей в
					# параметрах служба не принимает по построению.
					# Провал загрузки титров — ПРОВАЛ части, а не тихое «без титров».
					# Раньше задача создавалась без subtitle_upload_id, и файл
					# приезжал без субтитров со статусом OK: пользователь узнавал
					# об этом только просмотром результата.
					remote_sub_id=""
					if [ "$sub_found" = "1" ] && [ -n "${sub_file:-}" ]; then
						local _sub_sidecar_saved="$REMOTE_UPLOAD_SIDECAR"
						REMOTE_UPLOAD_SIDECAR=""
						if remote_upload "$sub_file"; then
							remote_sub_id="$REMOTE_UPLOAD_ID"
						else
							printf "\n"
							REMOTE_UPLOAD_SIDECAR="$_sub_sidecar_saved"
							if remote_fallback_allowed "$full_path" "загрузка файла субтитров не удалась"; then
								part_remote="no"
							else
								log_msg "FAIL" "$(basename "$full_path"): загрузка файла субтитров не удалась"
								any_fail="yes"
								echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
								REMOTE_UPLOAD_SIDECAR=""
								((c+=1)); continue
							fi
						fi
						REMOTE_UPLOAD_SIDECAR="$_sub_sidecar_saved"
					fi
				else
					printf "\n"
					if remote_fallback_allowed "$full_path" "загрузка не удалась"; then
						part_remote="no"
					else
						log_msg "FAIL" "$(basename "$full_path"): загрузка не удалась"
						any_fail="yes"
						echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
						REMOTE_UPLOAD_SIDECAR=""
						((c+=1)); continue
					fi
				fi
				REMOTE_UPLOAD_SIDECAR=""
			fi
		fi

		if [ "$part_remote" = "yes" ] && [ "$dry_run" = "yes" ]; then
			remote_dry_run "$remote_upload_id" "$r_op" "$r_params" "${remote_sub_id:-}"
			part_done="yes"
		elif [ "$part_remote" = "yes" ]; then
			local r_job
			# job_id живёт в sidecar рядом с upload_id: после падения клиента на фазе
			# ожидания или скачивания следующий запуск идёт сразу в GET /jobs/{id},
			# вместо повторной отправки гигабайт. Дедупликация службы спасает саму
			# задачу, но не трафик и не время.
			REMOTE_UPLOAD_SIDECAR="${manifest}.upload"
			if remote_submit "$remote_upload_id" "$r_op" "$r_params" "${remote_sub_id:-}"; then
				r_job="$REMOTE_JOB_ID"
				remote_upload_sidecar_write_job "$r_job"
				REMOTE_UPLOAD_SIDECAR=""
				local out_tmp; out_tmp="$(partial_path "$out_file")"
				rm -f "$out_tmp"
				_current_out_tmp="$out_tmp"
				local encode_start=$(date +%s)
				if remote_wait "$r_job" "$full_path" && remote_fetch "$r_job" "$out_tmp" "$full_path"; then
					publish_result "$full_path" "$out_tmp" "$out_file" "$encode_start" "yes"
					part_done="yes"
				else
					rm -f "$out_tmp"
				fi
				_current_out_tmp=""
			fi
			# Не получилось — либо откат на локальный ffmpeg (шумный, по ключу),
			# либо fail. Молчаливого отката здесь нет ни в одной ветке.
			if [ "$part_done" = "no" ]; then
				if remote_fallback_allowed "$full_path" "удалённое кодирование не удалось"; then
					part_remote="no"
				else
					log_msg "FAIL" "$(basename "$full_path")"
					any_fail="yes"
					echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
					((c+=1)); continue
				fi
			fi
		fi

		if [ "$part_done" = "yes" ]; then
			:
		# D7. Dry-run
		elif [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 $hw_decode_args $in_seek -i \"$full_path\" ${subtitles_params[*]} $convert_settings $thread_args ${vf_args[*]} ${af_args[*]} $current_set_length $out_seek \"$out_file\""
		else
			log_msg "INFO" "Кодирование: $(basename "$full_path") -> $(basename "$out_file")"
			local encode_start=$(date +%s)

			# J1. Запуск ffmpeg в фоне с прогресс-файлом
			local progress_file err_file
			progress_file=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
			err_file=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
			_register_tmp "$progress_file"; _register_tmp "$err_file"

			# Пишем в соседний temp и переименовываем только после rc=0. Прямая запись в
			# out_file означала, что прерванный прогон (Ctrl-C, падение, нехватка места)
			# оставлял обрезанный файл под финальным именем — следующий запуск принимал
			# его за готовый результат и пропускал. Переименование в пределах каталога
			# атомарно, поэтому имя цели появляется только у полностью записанного файла.
			local out_tmp
			out_tmp="$(partial_path "$out_file")"
			rm -f "$out_tmp"
			# Регистрируем temp для trap'а: при INT/TERM он удаляет недобитый файл,
			# иначе .ffconv-partial-* остаётся в destination после прерванного прогона.
			_current_out_tmp="$out_tmp"

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
			_current_out_tmp=""
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
			# Публикация — общая с удалённым путём (см. publish_result выше).
			else
				publish_result "$full_path" "$out_tmp" "$out_file" "$encode_start"
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
	# Здесь и в F-collision-map подстановка обязана быть в скобках: следом идёт «»», и в
	# локали, где старший байт считается буквой (macOS + bash 3.2), он утягивается в имя
	# переменной — та становится неопределённой, и значение из сообщения пропадает.
	log_msg "WARN" "Включено несколько взаимоисключающих режимов ($_active_modes). Активен «${_mode_winner}» (приоритет merge>extract>frame>copy>audio), остальные проигнорированы."
fi

# F-collision-map. Два РАЗНЫХ входа могут претендовать на ОДИН выход: при
# save_old_extension=no имена movie.avi и movie.mp4 оба дают movie.mp4. Раньше это
# обнаруживалось только по факту — второй файл молча затирал результат первого, и
# пользователь терял данные, не увидев ни одного сообщения. Считаем карту выходов ДО
# кодирования и помечаем всю конфликтующую группу как FAIL (тот же контракт, что и у
# F12 «выход == вход»: файл не обрабатывается, ошибка видна в сводке).
#
# Режимы merge (один выход), extract (расширение известно только после ffprobe каждого
# файла) и frame (выход — каталог) сюда не попадают: там формула выхода другая.
collisions_file=""
if [ "$merge_files" != "yes" ] && [ "$extract_audio_copy" != "yes" ] && [ "$create_frame" != "yes" ]; then
	_cmap=$(mktemp "${TMPDIR:-/tmp}/ffconv_map.XXXXXXXX")
	collisions_file=$(mktemp "${TMPDIR:-/tmp}/ffconv_col.XXXXXXXX")
	_register_tmp "$_cmap"
	while IFS= read -r -d '' _pf_path; do
		# dest строго внутри source — собственные выходы в карту не берём (их и так пропустят).
		if [ "$dest_inside_source" = "yes" ]; then
			case "$(canon_path "$_pf_path")" in "$canon_destination"/*) continue ;; esac
		fi
		# Формула обязана совпадать с encode_file, иначе карта врёт.
		_pf_dir="$(dirname "$_pf_path")/"
		_pf_dir="${_pf_dir:$_src_prefix_len}"
		_pf_name="$(basename "$_pf_path" | sed 's/\.[^.]*$//')"
		[ "$save_old_extension" = "yes" ] && _pf_name="$(basename "$_pf_path")"
		_pf_fmt="$format_files_out"
		[ "$copy_codecs" = "yes" ] && _pf_fmt="${_pf_path##*.}"
		_pf_out="$(canon_path "${folder_destination}${_pf_dir}${_pf_name}${part_suffix_known}.${_pf_fmt}")"
		# TAB-разделитель: в путях он практически не встречается, а перевод строки
		# ломал бы группировку — такие имена отсеиваем явно.
		case "$_pf_out$_pf_path" in
			*"$(printf '\t')"*) log_msg "WARN" "Табуляция в имени — файл исключён из карты коллизий: $_pf_path"; continue ;;
		esac
		# Три колонки: нормализованный ключ (по нему группируем), выход В ИСХОДНОМ
		# регистре (его показываем человеку) и сам вход.
		printf '%s\t%s\t%s\n' "$(collision_key "$_pf_out")" "$_pf_out" "$_pf_path" >> "$_cmap"
	done < <(find_inputs)

	# Ключи, встретившиеся больше одного раза, — и есть коллизии.
	LC_ALL=C sort "$_cmap" | LC_ALL=C awk -F'\t' '{c[$1]++} END {for (k in c) if (c[k] > 1) print k}' > "$collisions_file"
	if [ -s "$collisions_file" ]; then
		while IFS= read -r _col_key; do
			_col_ins=$(LC_ALL=C awk -F'\t' -v k="$_col_key" '$1 == k {print "    " $3}' "$_cmap")
			_col_out=$(LC_ALL=C awk -F'\t' -v k="$_col_key" '$1 == k {print $2; exit}' "$_cmap")
			log_msg "FAIL" "Конфликт выходов: на «${_col_out}» претендуют несколько входов — все пропущены (включите save_old_extension=yes либо разнесите файлы):"
			printf '%s\n' "$_col_ins"
		done < "$collisions_file"
	fi
	rm -f "$_cmap"
fi

# --- Удалённый бэкенд: включён ли он для ЭТОГО прогона ---
# Уезжает только то, где выигрывает карта. remux, concat, frames, audio и
# extract_audio служба умеет, но карта в них не участвует: там ffmpeg либо
# переливает байты, либо считает на процессоре — гнать по сети гигабайты ради
# `-c copy` заведомо хуже локального прогона. Молчать об этом нельзя: режим,
# который тихо не уехал, неотличим от сломанного удалённого пути.
remote_active="no"
if [ "$remote_enabled" = "yes" ]; then
	if ! type remote_preflight >/dev/null 2>&1; then
		echo "[ОШИБКА] [remote] enabled = yes, но рядом со скриптом нет remote_client.sh." >&2
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
	if [ "$merge_files" = "yes" ] || [ "$extract_audio_copy" = "yes" ] || \
	   [ "$create_frame" = "yes" ] || [ "$copy_codecs" = "yes" ] || \
	   [ "$audio_only" = "yes" ]; then
		log_msg "INFO" "Удалённый бэкенд не используется в этом режиме (карта в нём не участвует) — считаем локально"
	elif [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] parallel_files на удалённом пути игнорируется: параллельность задаёт очередь службы."
		parallel_count=1
		remote_active="yes"
	else
		remote_active="yes"
	fi
	if [ "$remote_active" = "yes" ]; then
		# Всё, что делает невозможным весь прогон, выясняем ДО первого файла.
		if ! remote_preflight; then
			pause_prompt "Нажмите [Enter], чтобы выйти..."
			exit 1
		fi
		if [ "$hw_accel_status" = "+" ] && [ "$hw_accel_value" = "intel" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] hw_accel = intel: Intel-карты на сервере нет, служба посчитает на процессоре."
		fi
		if [ "${remote_on_failure:-abort}" = "local" ] && [ "$ffmpeg_available" != "yes" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] on_failure = local, но локального ffmpeg нет: откатываться будет некуда."
		fi
		# Границы «тонкого клиента». Разбиение по тишине читает границы у
		# ЛОКАЛЬНОГО ffmpeg (silencedetect); брать их у службы отклонено спекой
		# (раздел 3.1) как второй источник правды. Без ffmpeg честнее отказать
		# явно, чем молча разбить файл не там.
		if [ "$ffmpeg_available" != "yes" ] && [ "$split_by_silence" = "yes" ]; then
			echo "[ОШИБКА] split_by_silence = yes требует локального ffmpeg (silencedetect), а он не найден." >&2
			pause_prompt "Нажмите [Enter], чтобы выйти..."
			exit 1
		fi
		log_msg "INFO" "Удалённый бэкенд включён: кодирование уходит на службу конвертации"
	fi
	# Режим оказался локальным (merge/copy/frames/audio), а ffmpeg нет — дальше
	# идти некуда, и сказать об этом надо здесь, а не падать на первом файле.
	if [ "$remote_active" != "yes" ] && [ "$ffmpeg_available" != "yes" ]; then
		echo -e "\n[ОШИБКА] ffmpeg не найден ($ffmpeg), а этот режим считается локально.\n" >&2
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
fi

# --- Боевая самопроверка удалённого пути ---
# Отдельный режим, а не часть прогона: он ничего не конвертирует и обязан
# завершиться до того, как будет тронут хоть один файл пользователя.
if [ "${FFCONV_REMOTE_SELFTEST:-}" = "1" ]; then
	if [ "$remote_enabled" != "yes" ]; then
		echo "[ОШИБКА] --remote-selftest требует [remote] enabled = yes в config.ini." >&2
		exit 1
	fi
	if ! type remote_selftest >/dev/null 2>&1; then
		echo "[ОШИБКА] Рядом со скриптом нет remote_client.sh — самопроверка невозможна." >&2
		exit 1
	fi
	remote_selftest; _st_rc=$?
	rm -rf "$results_dir"
	pause_prompt "Нажмите [Enter], чтобы выйти..."
	exit "$_st_rc"
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
		_any_input="yes"
		if [ -z "$fname" ]; then fname=$(basename "$full_path"); break; fi
	done < <(find_inputs | sort_null)
	if [ -z "$fname" ]; then
		log_msg "WARN" "Нет файлов для объединения в $folder_sources"
		echo "skip" > "$results_dir/r_merge"
	elif [ "$overwrite_existing" != "yes" ] && [ -f "${folder_destination}/${fname}" ]; then
		# Цель существует, а перезапись выключена — это ПРОПУСК, и он обязан быть
		# назван. Раньше ветка отсутствовала вовсе: сводка показывала 0/0/0, rc=0,
		# GUI писал «Готово», и пользователь не имел ни одного способа понять,
		# почему объединения не произошло.
		log_msg "SKIP" "Объединение пропущено: «${folder_destination}/${fname}» уже существует (overwrite_existing = no)"
		echo "skip" > "$results_dir/r_merge"
	else
		# F-merge-inplace. Цель объединения = ${folder_destination}/${fname}. Если она
		# канонически совпадает с одним из входов (dest == source, in-place), мерж затёр бы
		# этот источник СОБОЙ ЖЕ: оригинал теряется, а следующий прогон снова возьмёт
		# объединённый файл во вход и задублирует содержимое. Такой мерж невозможен без
		# потери данных — отклоняем его так же явно, как F12 «выход == вход».
		canon_merge_target="$(canon_path "${folder_destination}/${fname}")"
		merge_target_collision="no"
		concat_list=$(mktemp "${TMPDIR:-/tmp}/ffconv.XXXXXXXX")
		_register_tmp "$concat_list"
		# -printf — GNU-расширение (нет на macOS/BSD). Портативно: -print0 + read.
		# Имена с ' экранируем для concat-формата ffmpeg: ' -> '\''
		while IFS= read -r -d '' mf; do
			# F-collision: собственные выходы (dest строго внутри source) в concat не включаем.
			if [ "$dest_inside_source" = "yes" ]; then
				case "$(canon_path "$mf")" in "$canon_destination"/*) continue ;; esac
			fi
			[ "$(canon_path "$mf")" = "$canon_merge_target" ] && merge_target_collision="yes"
			printf "file '%s'\n" "${mf//\'/\'\\\'\'}" >> "$concat_list"
		done < <(find_inputs | sort_null)
		if [ "$merge_target_collision" = "yes" ]; then
			log_msg "FAIL" "Объединение отклонено: результат «${folder_destination}/${fname}» совпадает с одним из входов (in-place merge затёр бы источник). Задайте другой destination."
			echo "fail" > "$results_dir/r_merge"
			rm -f "$concat_list"
			concat_list=""
		fi
		if [ -n "$concat_list" ]; then
		# Мержим в соседний temp, а не сразу поверх цели. Прежний вызов шёл без -y на
		# существующий файл: ffmpeg спрашивал «File exists. Overwrite? [y/N]» и висел,
		# ожидая stdin, которого в batch/GUI нет. А упавший мерж оставлял partial под
		# именем цели, и следующий запуск принимал его за готовый результат.
		merge_tmp="$(partial_path "${folder_destination}/${fname}")"
		_register_tmp "$merge_tmp"
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
			# F-rename. Результат mv проверяем: цель может быть заблокирована/недоступна.
			# Молчаливый провал rename выдал бы отсутствующий результат за успех.
			if [ "$merge_rc" -eq 0 ] && [ -s "$merge_tmp" ] && \
			   "$ffmpeg" -nostdin -v error -i "$merge_tmp" -f null - 2>/dev/null \
			   && mv -f "$merge_tmp" "${folder_destination}/${fname}" 2>/dev/null \
			   && [ -f "${folder_destination}/${fname}" ]; then
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
	fi
else
	# B1b. Параллельная обработка файлов — пул фоновых подоболочек.
	#
	# Раньше здесь был `xargs -0 -P N bash -c ...`, и он требовал протащить в дочерний
	# процесс ВСЁ состояние через окружение: `export -f` на девять функций плюс четыре
	# десятка переменных. На Windows-раннере CI это его и убивало — msys2-xargs считает
	# доступную длину аргументов как ARG_MAX минус размер окружения и падает ассертом
	# «bc_ctl.arg_max >= LINE_MAX failed (xargs.c:512)», как только окружение вырастает.
	# Раннер приносит свои переменные, экспортированные функции добавляют десятки
	# килобайт — и параллельная ветка не обрабатывала НИ ОДНОГО файла (красный F27).
	#
	# Подоболочка `( ... ) &` наследует и функции, и переменные напрямую, без
	# сериализации в окружение: экспорт не нужен вовсе, а значит нет и потолка,
	# в который упирался xargs. Заодно исчезает зависимость от того, какой `bash`
	# найдётся в PATH (на Windows это мог быть System32\bash.exe от WSL).
	# Результаты, как и раньше, каждый процесс пишет файлом в $results_dir.
	# Оба цикла идут в ОСНОВНОЙ оболочке: `find_inputs | while …` выполнял бы правую
	# часть конвейера в подоболочке, а там (а) сброшены traps, (б) присваивания
	# _current_ffmpeg_pid/_current_out_tmp невидимы родителю, где живёт _cleanup_on_int.
	# Следствия были ровно три и все наблюдаемые: `kill -TERM <pid>` (timeout, systemd,
	# cron) откладывался до конца foreground-конвейера — пакет дорабатывал до последнего
	# файла, а потом trap срабатывал с пустыми переменными и ffmpeg не убивался вовсе;
	# Ctrl+C оставлял `.ffconv-partial-*` в destination; в параллельном режиме сигнал не
	# доходил до детей. `done < <(…)` держит цикл в основной оболочке — process
	# substitution есть и в bash 3.2 (macOS-CI).
	if [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		while IFS= read -r -d '' full_path; do
			_any_input="yes"
			# Держим не больше $parallel_count живых задач. `wait -n` есть с bash 4.3;
			# на bash 3.2 (macOS) он ругается и возвращает ненулевой код — тогда
			# просто ждём фиксированный интервал и проверяем счётчик заново.
			while [ "$(jobs -rp | wc -l)" -ge "$parallel_count" ]; do
				wait -n 2>/dev/null || sleep 0.2
			done
			( trap _cleanup_child_on_int INT TERM; encode_file "$full_path" ) &
		done < <(find_inputs)
		wait
	else
		while IFS= read -r -d '' full_path; do
			_any_input="yes"
			encode_file "$full_path"
		done < <(find_inputs)
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
# Откаты на локальный ffmpeg считаются отдельно и отдельной же строкой видны в
# сводке: «посчитано локально» не должно раствориться внутри «обработано».
total_local=0
for f in "$results_dir"/lf_*; do
	[ -f "$f" ] || continue
	((total_local++))
done
rm -rf "$results_dir"
[ -n "$collisions_file" ] && rm -f "$collisions_file"

end_time_global=$(date +%s)
elapsed_global=$((end_time_global - start_time_global))
elapsed_global_min=$((elapsed_global / 60))
elapsed_global_sec=$((elapsed_global % 60))

echo -e "\n"
echo "══════════════════════════════════════════════"
# Пустой прогон обязан объяснять себя. Сводка 0/0/0 без единой строки неотличима от
# «отработало и ничего не нашло по ошибке в пути»: пользователь видел «Готово» в GUI
# и rc=0 в консоли на каталоге, где просто не совпало ни одно расширение.
if [ "${_any_input:-no}" != "yes" ]; then
	echo "  Входных файлов не найдено: в «${folder_sources}» нет файлов с расширениями из [files] format_files_in (${format_files_in})."
fi
echo "  Обработано:  ${total_ok} файлов"
echo "  Пропущено:   ${total_skip} (уже существуют)"
echo "  Ошибки:      ${total_fail}"
[ "$total_local" -gt 0 ] && echo "  Посчитано локально: ${total_local} (служба была недоступна)"
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
pause_prompt "Нажмите [Enter], чтобы продолжить..."
# Exit code отражает наличие ошибок — cron/CI/GUI могут детектировать провал батча.
# Откат на локальный ffmpeg тоже даёт ненулевой код: пользователь просил считать
# на сервере, и то, что он получил результат другим способом, обязано быть видно
# и в автоматике, а не только в сводке на экране.
[ "$total_fail" -gt 0 ] && exit 1
[ "$total_local" -gt 0 ] && exit 1
exit 0
