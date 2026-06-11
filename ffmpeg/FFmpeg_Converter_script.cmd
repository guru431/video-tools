@echo off
setlocal enabledelayedexpansion

rem ============================================================
rem FFmpeg Converter Script (CMD)
rem Известное ограничение: имена файлов с ! повреждаются (delayed expansion);
rem символы % и ^ после call также могут искажаться. Для таких имён — SH/PS1.
rem ============================================================

rem --- E1. Проверка окружения ---
if not exist "%folder_sources%\" (
	echo.
	echo [ОШИБКА] Папка источника не найдена: %folder_sources%
	echo.
	pause
	exit /b 1
)

if not exist "%folder_destination%\" (
	mkdir "%folder_destination%"
	if errorlevel 1 (
		echo.
		echo [ОШИБКА] Не удалось создать папку назначения: %folder_destination%
		echo.
		pause
		exit /b 1
	)
)

"%ffmpeg%" -version >nul 2>&1
if errorlevel 1 (
	echo.
	echo [ОШИБКА] ffmpeg не найден: %ffmpeg%
	echo.
	pause
	exit /b 1
)

rem --- Парсинг настроек ---
for /f "tokens=1,2 delims=:" %%a in ("%video_codec%") do (set "video_codec_status=%%a" & set "video_codec_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_number_frames%") do (set "video_number_frames_status=%%a" & set "video_number_frames_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_bitrate%") do (set "video_bitrate_status=%%a" & set "video_bitrate_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_resolution%") do (set "video_resolution_status=%%a" & set "video_resolution_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_rotation%") do (set "video_rotation_status=%%a" & set "video_rotation_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_quality%") do (set "video_quality_status=%%a" & set "video_quality_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%video_subtitles%") do (set "video_subtitles_status=%%a" & set "video_subtitles_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%keep_aspect_ratio%") do (set "keep_aspect_ratio_status=%%a" & set "keep_aspect_ratio_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%output_container%") do (set "output_container_status=%%a" & set "output_container_value=%%b")

for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "audio_codec_status=%%a" & set "audio_codec_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_number_channels%") do (set "audio_number_channels_status=%%a" & set "audio_number_channels_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_bitrate%") do (set "audio_bitrate_status=%%a" & set "audio_bitrate_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_sampling_rate%") do (set "audio_sampling_rate_status=%%a" & set "audio_sampling_rate_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_normalize%") do (set "audio_normalize_status=%%a" & set "audio_normalize_value=%%b")

for /f "tokens=1,2 delims=:" %%a in ("%multithreads%") do (set "multithreads_status=%%a" & set "multithreads_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%parallel_files%") do (set "parallel_files_status=%%a" & set "parallel_files_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%hw_accel%") do (set "hw_accel_status=%%a" & set "hw_accel_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%gpu_preset%") do (set "gpu_preset_status=%%a" & set "gpu_preset_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%gpu_tune%") do (set "gpu_tune_status=%%a" & set "gpu_tune_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%gpu_rc%") do (set "gpu_rc_status=%%a" & set "gpu_rc_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%playback_speed%") do (set "playback_speed_status=%%a" & set "playback_speed_value=%%b")

rem --- Формирование аудио-параметров ---
if "!audio_codec_status!"=="+" (set "set_audio_codec=-c:a !audio_codec_value!") else (set "set_audio_codec=")
if "!audio_number_channels_status!"=="+" (set "set_audio_number_channels=-ac !audio_number_channels_value!") else (set "set_audio_number_channels=")
if "!audio_bitrate_status!"=="+" (set "set_audio_bitrate=-b:a !audio_bitrate_value!k") else (set "set_audio_bitrate=")
if "!audio_sampling_rate_status!"=="+" (set "set_audio_sampling_rate=-ar !audio_sampling_rate_value!") else (set "set_audio_sampling_rate=")

rem --- Формирование видео-параметров ---
if "!video_codec_status!"=="+" (set "set_video_codec=!video_codec_value!") else (set "set_video_codec=")
if "!video_number_frames_status!"=="+" (set "set_video_number_frames=-r !video_number_frames_value!") else (set "set_video_number_frames=")
if "!video_bitrate_status!"=="+" (set "set_video_bitrate_orig=!video_bitrate_value!") else (set "set_video_bitrate_orig=")

rem --- Многопоточность ---
if "!multithreads_status!"=="+" (set "threads=!multithreads_value!") else (set "threads=1")

rem --- C1. Аппаратное ускорение (NVIDIA / Intel) ---
set "use_hw_accel=no"
set "hw_accel_type="
set "hw_decode_args="
if "!hw_accel_status!"=="+" (
	if "!hw_accel_value!"=="nvidia" (
		set "encoder_check="
		for /f "tokens=*" %%i in ('""%ffmpeg%" -encoders 2^>^&1 ^| findstr /i "h264_nvenc hevc_nvenc av1_nvenc""') do set "encoder_check=%%i"
		if defined encoder_check (
			set "use_hw_accel=yes"
			set "hw_accel_type=nvidia"
			set "hw_decode_args=-hwaccel cuda -hwaccel_output_format cuda"
			if "!set_video_codec!"=="libx264" set "set_video_codec=h264_nvenc"
			if "!set_video_codec!"=="libx265" set "set_video_codec=hevc_nvenc"
			if "!set_video_codec!"=="libsvtav1" set "set_video_codec=av1_nvenc"
		) else (echo [WARN] NVIDIA NVENC encoder not available, using software encoding)
	)
	if "!hw_accel_value!"=="intel" (
		set "encoder_check="
		for /f "tokens=*" %%i in ('""%ffmpeg%" -encoders 2^>^&1 ^| findstr /i "h264_qsv hevc_qsv av1_qsv""') do set "encoder_check=%%i"
		if defined encoder_check (
			set "use_hw_accel=yes"
			set "hw_accel_type=intel"
			set "hw_decode_args=-hwaccel qsv -hwaccel_output_format qsv"
			if "!set_video_codec!"=="libx264" set "set_video_codec=h264_qsv"
			if "!set_video_codec!"=="libx265" set "set_video_codec=hevc_qsv"
			if "!set_video_codec!"=="libsvtav1" set "set_video_codec=av1_qsv"
		) else (echo [WARN] Intel QSV encoder not available, using software encoding)
	)
)

rem --- Время начала и длительности ---
for /f "tokens=1,2 delims=:" %%a in ("%start_coding%") do (set "start_coding_status=%%a" & set "start_coding_value=%%b")
if "!start_coding_status!"=="+" (
	for /f "tokens=1,2,3 delims=-" %%i in ("!start_coding_value!") do set "x=1%%i" & set "y=1%%j" & set "z=1%%k"
	set /a "start_coding_value=(x-100)*3600+(y-100)*60+(z-100)"
	set "set_start_coding=-ss !start_coding_value!"
) else (
	set "set_start_coding="
)

for /f "tokens=1,2 delims=:" %%a in ("%length_coding%") do (set "length_coding_status=%%a" & set "length_coding_value=%%b")
if "!length_coding_status!"=="+" (
	for /f "tokens=1,2,3 delims=-" %%i in ("!length_coding_value!") do set "x=1%%i" & set "y=1%%j" & set "z=1%%k"
	set /a "length_coding_value=(x-100)*3600+(y-100)*60+(z-100)"
	set "set_length_coding=-t !length_coding_value!"
) else (
	set "set_length_coding="
	set "split_by_silence=no"
)

rem split_by_silence требует float-арифметики для привязки к паузам — в CMD
rem недоступно (как atempo cascade). Откатываемся на разбиение по времени.
if "!split_by_silence!"=="yes" (
	echo [WARN] split_by_silence недоступен в CMD-версии, используйте SH/PS1 — разбиение по времени.
	set "split_by_silence=no"
)

rem --- A1. Формат и настройки видео/аудио ---
if "%audio_only%"=="yes" (
	set "format_files_out=mp3"
	set "video_settings=-vn"
	set "set_audio_codec=-c:a libmp3lame"
) else (
	if "!output_container_status!"=="+" (set "format_files_out=!output_container_value!") else (set "format_files_out=mp4")
	rem E5. Сборка цепочки видео-фильтров
	rem rotation+GPU: CUDA-варианта фильтра поворота нет → при повороте на GPU вся
	rem цепочка на CPU (иначе несовместимая смесь transpose + scale_cuda/scale_qsv).
	set "force_cpu_filters="
	if "!video_rotation_status!"=="+" if "!use_hw_accel!"=="yes" set "force_cpu_filters=1"
	set "vf_chain="
	if "!video_rotation_status!"=="+" (
		set "vf_chain=transpose=!video_rotation_value!"
	)
	rem D4. Масштабирование
	if "!video_resolution_status!"=="+" (
		for /f "tokens=1,2 delims=x" %%a in ("!video_resolution_value!") do set "res_w=%%a" & set "res_h=%%b"
		rem scale-фильтр по типу GPU; при force_cpu — обычный CPU scale
		set "scale_filter=scale"
		if not defined force_cpu_filters (
			if "!hw_accel_type!"=="nvidia" set "scale_filter=scale_cuda"
			if "!hw_accel_type!"=="intel" set "scale_filter=scale_qsv"
		)
		rem keep_ar предвычисляем — иначе else-binding отключал бы scale при статусе "-"
		set "keep_ar=no"
		if "!keep_aspect_ratio_status!"=="+" if "!keep_aspect_ratio_value!"=="yes" set "keep_ar=yes"
		if "!keep_ar!"=="yes" (
			if "!scale_filter!"=="scale" (
				if defined vf_chain (set "vf_chain=!vf_chain!,scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease,pad=!res_w!:!res_h!:(ow-iw)/2:(oh-ih)/2") else (set "vf_chain=scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease,pad=!res_w!:!res_h!:(ow-iw)/2:(oh-ih)/2")
			) else (
				if defined vf_chain (set "vf_chain=!vf_chain!,!scale_filter!=!res_w!:!res_h!:force_original_aspect_ratio=decrease") else (set "vf_chain=!scale_filter!=!res_w!:!res_h!:force_original_aspect_ratio=decrease")
			)
		) else (
			if defined vf_chain (set "vf_chain=!vf_chain!,!scale_filter!=!res_w!:!res_h!") else (set "vf_chain=!scale_filter!=!res_w!:!res_h!")
		)
	)
	rem D6. Скорость воспроизведения — видео
	if "!playback_speed_status!"=="+" if not "!playback_speed_value!"=="1.0" (
		if defined vf_chain (set "vf_chain=!vf_chain!,setpts=PTS/!playback_speed_value!") else (set "vf_chain=setpts=PTS/!playback_speed_value!")
	)
	rem Hwdownload: если в цепочке есть CPU-фильтр на GPU-кадрах — скачиваем кадры
	rem в системную память — иначе ffmpeg: "filter not supported on hardware frames".
	rem Паритет с .sh/.ps1; findstr-проверка = "нет ни одного GPU-фильтра в цепочке".
	if "!use_hw_accel!"=="yes" if defined vf_chain (
		echo !vf_chain! | findstr /i "scale_cuda scale_qsv setpts" >nul
		if errorlevel 1 set "vf_chain=hwdownload,format=nv12,!vf_chain!"
	)
	rem Формирование codec-строки
	if defined set_video_codec (set "set_video_codec_arg=-c:v !set_video_codec!") else (set "set_video_codec_arg=")
	rem C2. Настройки GPU: NVIDIA / Intel
	set "gpu_args="
	if "!use_hw_accel!"=="yes" (
		if "!gpu_preset_status!"=="+" set "gpu_args=!gpu_args! -preset !gpu_preset_value!"
		if "!hw_accel_type!"=="nvidia" (
			if "!gpu_tune_status!"=="+" set "gpu_args=!gpu_args! -tune !gpu_tune_value!"
			if "!gpu_rc_status!"=="+" set "gpu_args=!gpu_args! -rc !gpu_rc_value!"
			if "!video_quality_status!"=="+" set "gpu_args=!gpu_args! -cq !video_quality_value!"
		)
		if "!hw_accel_type!"=="intel" (
			if "!video_quality_status!"=="+" set "gpu_args=!gpu_args! -global_quality !video_quality_value!"
		)
	)
	rem D2. CRF для программных кодеков
	set "crf_args="
	if not "!use_hw_accel!"=="yes" if "!video_quality_status!"=="+" (
		set "crf_args=-crf !video_quality_value!"
	)
	rem Имя muxer для -f: mkv/ts — расширения файла, а не имена форматов ffmpeg.
	rem Расширение выходного файла не меняется, только аргумент -f.
	set "muxer_out=!format_files_out!"
	if "!format_files_out!"=="mkv" set "muxer_out=matroska"
	if "!format_files_out!"=="ts" set "muxer_out=mpegts"
	set "video_settings=-f !muxer_out! !set_video_codec_arg! !set_video_number_frames! !gpu_args! !crf_args!"
)

rem D6. Скорость воспроизведения (аудио)
set "af_chain="
rem atempo поддерживает диапазон 0.5-2.0. Для значений вне диапазона строится каскад
rem (atempo=2.0,atempo=2.0,... или atempo=0.5,...) через целочисленную milli-арифметику
rem в подпрограмме :build_atempo (у CMD нет float-math). In-range — значение напрямую.
if "!playback_speed_status!"=="+" if not "!playback_speed_value!"=="1.0" call :build_atempo "!playback_speed_value!"

rem D5. Нормализация звука
if "!audio_normalize_status!"=="+" (
	if "!audio_normalize_value!"=="loudnorm" (
		if defined af_chain (set "af_chain=!af_chain!,loudnorm=I=-16:TP=-1.5:LRA=11") else (set "af_chain=loudnorm=I=-16:TP=-1.5:LRA=11")
	)
	if "!audio_normalize_value!"=="dynaudnorm" (
		if defined af_chain (set "af_chain=!af_chain!,dynaudnorm") else (set "af_chain=dynaudnorm")
	)
)

set "audio_settings=!set_audio_codec! !set_audio_number_channels! !set_audio_bitrate! !set_audio_sampling_rate!"
set "thread_args=-threads !threads!"
set "format_files_in_pattern=*.%format_files_in:,= *.%"

rem --- J2. Счётчики ---
set total_ok=0
set total_fail=0
set total_skip=0
rem Засекаем время через временный файл (чч:мм:сс)
set "start_hh=%time:~0,2%"
set "start_mm=%time:~3,2%"
set "start_ss=%time:~6,2%"
rem %time% при часе <10 даёт пробел (" 9") → set /a octal-ошибка; пробел→0, затем
rem приём "префикс 1, минус 100" против октальной трактовки ведущих нулей.
set "start_hh=%start_hh: =0%"
set "start_mm=%start_mm: =0%"
set "start_ss=%start_ss: =0%"
set /a "start_total_sec=(1%start_hh%-100)*3600+(1%start_mm%-100)*60+(1%start_ss%-100)"

rem --- Основная логика ---
if "%merge_files%"=="yes" (
	for /r "%folder_sources%" %%a in (%format_files_in_pattern%) do (if not defined fname set "fname=%%~nxa")
	if not exist "%folder_destination%\!fname!" (
		set "full_path=%temp%\%random%.tmp"
		cmd /u /c "(for /r "%folder_sources%" %%a in (%format_files_in_pattern%) do @echo file '%%a')" > "!full_path!.u16"
		powershell "[System.IO.File]::WriteAllLines('!full_path!', (Get-Content -Encoding unicode '!full_path!.u16'))"
		echo [INFO] Объединение файлов
		"%ffmpeg%" -hide_banner -strict -2 -f concat -safe 0 -i "!full_path!" -c copy -map 0 "%folder_destination%\!fname!"
		if errorlevel 1 (
			echo [FAIL] Объединение файлов
			set /a "total_fail+=1"
		) else (
			echo [OK] Объединение файлов
			set /a "total_ok+=1"
		)
		del "!full_path!" "!full_path!.u16" 2>nul
	)
) else (
	for /r "%folder_sources%" %%a in (%format_files_in_pattern%) do (
		set "pf_full=%%~fa" & set "pf_dp=%%~dpa" & set "pf_n=%%~na" & set "pf_nx=%%~nxa" & set "pf_x=%%~xa"
		call :process_file
	)
)
goto :after_files

rem --- Обработка одного файла; вызывается из for /r выше.
rem Вход: pf_full/pf_dp/pf_n/pf_nx/pf_x — полный путь и его компоненты (через
rem переменные, не аргумент: call %~1 повторно раскрывает %-expansion и съедает
rem литеральные % в имени файла, например "50% off.mp4" -> "50 off.mp4").
rem Тело вынесено из блока for: label внутри скобочного блока ломает парсер CMD,
rem а goto из тела for обрывал бы перечисление файлов. Счётчики total_* общие.
:process_file
		set "full_path=!pf_full!"
		set "file_path=!pf_dp!"
		set "file_name=!pf_n!"
		if "%save_old_extension%"=="yes" (set "file_name=!pf_nx!")

		set "file_path=!file_path:%folder_sources%=!"
		call set "file_path=!file_path:%%=%%%%!"
		if not exist "%folder_destination%!file_path!" md "%folder_destination%!file_path!"

		rem --- I. Извлечение аудио без перекодирования ---
		if "%extract_audio_copy%"=="yes" (
			set "audio_ext=mka"
			set "audio_line="
			for /f "delims=" %%c in ('""%ffmpeg%" -i "!full_path!" 2^>^&1 ^| find "Audio:""') do if not defined audio_line set "audio_line=%%c"
			if not "!audio_line!"=="" (
				if not "!audio_line:Audio: aac=!"=="!audio_line!" set "audio_ext=m4a"
				if not "!audio_line:Audio: mp3=!"=="!audio_line!" set "audio_ext=mp3"
				if not "!audio_line:Audio: opus=!"=="!audio_line!" set "audio_ext=opus"
				if not "!audio_line:Audio: vorbis=!"=="!audio_line!" set "audio_ext=ogg"
				if not "!audio_line:Audio: flac=!"=="!audio_line!" set "audio_ext=flac"
				if not "!audio_line:Audio: pcm_=!"=="!audio_line!" set "audio_ext=wav"
			)
			set "out_audio=%folder_destination%!file_path!!file_name!.!audio_ext!"
			if not exist "!out_audio!" (
				echo [INFO] Извлечение аудио: !file_name!
				"%ffmpeg%" -hide_banner -strict -2 -i "!full_path!" -vn -c:a copy "!out_audio!" -y
				if errorlevel 1 (
					echo [FAIL] !file_name!
					if exist "!out_audio!" del "!out_audio!"
					set /a "total_fail+=1"
				) else (
					echo [OK] !file_name! -^> !out_audio!
					set /a "total_ok+=1"
				)
			) else (
				set /a "total_skip+=1"
			)
			exit /b
		)

		if "%create_frame%"=="yes" (
			if not exist "%folder_destination%!file_path!!file_name!" (
				md "%folder_destination%!file_path!!file_name!"
				echo [INFO] Извлечение кадров: !full_path!
				"%ffmpeg%" -hide_banner -strict -2 -i "!full_path!" -r 1/1 "%folder_destination%!file_path!!file_name!\!file_name!_%%05d.png"
			)
			exit /b
		)

		rem E3. Валидность существующего выхода (паритет с SH/PS1): битый файл удаляем,
		rem чтобы перекодировать заново, а не пропустить как готовый.
		set "_existing_out=%folder_destination%!file_path!!file_name!.!format_files_out!"
		if exist "!_existing_out!" (
			"%ffmpeg%" -v error -i "!_existing_out!" -f null - >nul 2>&1
			if errorlevel 1 (
				echo [WARN] Удаление битого файла: !_existing_out!
				del "!_existing_out!"
			)
		)

		if not exist "%folder_destination%!file_path!!file_name!.!format_files_out!" (
			if not exist "%folder_destination%!file_path!!file_name! (part.1).!format_files_out!" (
				rem P3. Один вызов ffmpeg -i на файл — раньше было 2: bitrate + Duration.
				rem ffmpeg печатает metadata в stderr → перенаправляем в файл, stdout → nul.
				set "_ff_info_tmp=%temp%\ffinfo_!random!.txt"
				"%ffmpeg%" -i "!full_path!" 1>nul 2>"!_ff_info_tmp!"
				rem E4. Получение битрейта.
				rem Берём подстроку после "bitrate: " и первый токен — число кб/с; надёжнее
				rem позиционного tokens=6, который ломался при смене формата строки. Если ffmpeg
				rem вернёт N/A, токен будет не-числом → digit-check ниже отсекает, а fallback
				rem гарантирует, что -b:v всегда задан — иначе ffmpeg уйдёт в неограниченный битрейт.
				set "set_video_bitrate_final="
				if "!video_bitrate_status!"=="+" if not "!video_quality_status!"=="+" (
					for /f "delims=" %%i in ('findstr /i "bitrate:" "!_ff_info_tmp!"') do (
						set "_br_line=%%i"
						set "_br_line=!_br_line:*bitrate: =!"
						for /f "tokens=1" %%j in ("!_br_line!") do set "_br_raw=%%j"
						set "_br_digits="
						for /f "delims=0123456789" %%n in ("!_br_raw!a") do set "_br_digits=%%n"
						if "!_br_digits!"=="a" (
							if !_br_raw! lss !set_video_bitrate_orig! (set "set_video_bitrate_final=-b:v !_br_raw!k") else (set "set_video_bitrate_final=-b:v !set_video_bitrate_orig!k")
						)
					)
					if not defined set_video_bitrate_final set "set_video_bitrate_final=-b:v !set_video_bitrate_orig!k"
				)

				if "%copy_codecs%"=="yes" (
					set "convert_settings=-c copy -map 0"
					rem pf_x содержит расширение с ведущей точкой ".mp4"; ниже out_file
					rem собирается как "имя.current_format_out", поэтому точку убираем.
					set "current_format_out=!pf_x!"
					if defined current_format_out set "current_format_out=!current_format_out:~1!"
				) else (
					set "convert_settings=!video_settings! !set_video_bitrate_final! !audio_settings!"
					set "current_format_out=!format_files_out!"
				)

				rem Видео/аудио фильтры
				set "vf_args="
				set "current_vf=!vf_chain!"
				set "af_args="
				set "current_af=!af_chain!"
				rem База до per-part модификаций: subtitles burn / meta -map. Восстанавливается
				rem в начале каждой итерации цикла по частям, иначе значения накапливаются:
				rem для части 2 получится "base,subtitles=...,subtitles=..." и "-map 0 -map 1 -map 0 -map 1".
				set "_cs_base=!convert_settings!"
				set "_vf_base=!current_vf!"
				set "_af_base=!current_af!"

				if "!length_coding_status!"=="+" (
					rem Парсинг Duration. Если ffmpeg вернёт "Duration: N/A" — бывает на потоках и
					rem повреждённых контейнерах — %%i будет нечисловым "N" → set /a даст 0
					rem или ошибку. Проверяем что результат цифровой; иначе duration=0, и split
					rem пропускается, файл обрабатывается целиком.
					set "x=" & set "y=" & set "z="
					for /f "tokens=2,3,4 delims=:. " %%i in ('findstr /i "Duration:" "!_ff_info_tmp!"') do set "x=1%%i" & set "y=1%%j" & set "z=1%%k"
					set "duration=0"
					if defined x if defined y if defined z (
						set "_dur_check="
						for /f "delims=0123456789" %%n in ("!x!!y!!z!a") do set "_dur_check=%%n"
						if "!_dur_check!"=="a" set /a "duration=(x-100)*3600+(y-100)*60+(z-100)"
					)
					if !duration! lss 1 echo [WARN] Длительность не определена, разбиение пропущено: !full_path!

					if "!split_by_silence!"=="yes" (
						echo.
						echo Ждите! Идёт поиск пауз в файле:
						echo !full_path!
						echo.
						for /f "tokens=4-5 delims=: " %%a in ('""%ffmpeg%" -i "!full_path!" -nostats -af "silencedetect^=n^=!silence_threshold!:d^=!silence_duration!" -f null - 2>&1>nul | find /i "silence_""') do (
							if "%%a"=="silence_start" (set "silence_start=%%b")
							if "%%a"=="silence_end" (
								set "silence_end=%%b"
								set /a "silence_mid=(silence_start+silence_end)/2"
								set "split_points=!split_points! !silence_mid!"
							)
						)
					)

					set "num="
					set "d="
					for /l %%i in (0,1,999) do (
						if not defined d (
							if %%i==0 (set /a "lcv%%i=0") else (set /a "lcv%%i=length_coding_value*%%i")
							if !duration! gtr !lcv%%i! (
								set "part_start=!lcv%%i!"
								if "!split_by_silence!"=="yes" (
									set "diff_start="
									for %%p in (!split_points!) do (
										set /a "diff=%%p - part_start"
										if !diff! lss 0 set /a "diff=-diff"
										if not defined diff_start (
											set "diff_start=!diff!"
											set "part_start_with_silence=%%p"
										) else (
											if !diff! lss !diff_start! (
												set "diff_start=!diff!"
												set "part_start_with_silence=%%p"
											)
										)
									)
									set /a "half_length=length_coding_value/2"
									if !diff_start! leq !half_length! (set "new_part_start=!part_start_with_silence!") else (set "new_part_start=!part_start!")
									if defined num (set "num=!num! !new_part_start!") else (set "num=!new_part_start!")
									set /a "lcv_silent%%i=length_coding_value - (part_start - new_part_start)"
									set "lcv%%i=!new_part_start!"
								) else (if defined num (set "num=!num! !part_start!") else (set "num=!part_start!"))
							) else (set "d=1")
						)
					)
				) else (set "num=0")
				if "!start_coding_status!"=="+" (set "num=!start_coding_value!")

				rem P3. _ff_info_tmp больше не нужен — bitrate и Duration уже прочитаны.
				if defined _ff_info_tmp del "!_ff_info_tmp!" 2>nul

				set "c=1"
				for %%b in (!num!) do (
					if "!num!"=="0" (set "pref=") else (set "pref= (part.!c!)")

					rem Сброс из базы — см. _cs_base / _vf_base / _af_base выше.
					set "convert_settings=!_cs_base!"
					set "current_vf=!_vf_base!"
					set "current_af=!_af_base!"

					set "current_set_length=!set_length_coding!"
					if "!split_by_silence!"=="yes" (set /a "cc=c-1" & call set "current_set_length=-t %%lcv_silent!cc!%%")

					rem B2. Субтитры с subtitles_style
					set "subtitles_params="
					if "!video_subtitles_status!"=="+" if not "%copy_codecs%"=="yes" (
						set "sub_found="
						for %%e in (srt vtt) do (
							if not "!sub_found!"=="1" (
								set "sub_file=!folder_sources!!file_path!!file_name!.%%e"
								if exist "!sub_file!" (
									if "!video_subtitles_value!"=="burn" (
										rem Экранирование пути для subtitles= (схема едина с .sh/.ps1):
										rem backslash → forward slash (Windows-пути), затем ' : —
										rem спецсимволы значения; [ ] ; — graph-синтаксис; % — timecode.
										set "sub_escaped=!sub_file:\=/!"
										set "sub_escaped=!sub_escaped:'=\'!"
										set "sub_escaped=!sub_escaped::=\:!"
										set "sub_escaped=!sub_escaped:[=\[!"
										set "sub_escaped=!sub_escaped:]=\]!"
										set "sub_escaped=!sub_escaped:;=\;!"
										set "sub_escaped=!sub_escaped:%%=\%%!"
										rem subtitles — CPU-фильтр на GPU-кадрах падает; качаем кадры в RAM — RTX 5060 Ti.
										if "!use_hw_accel!"=="yes" (
											if defined current_vf (set "current_vf=!current_vf!,hwdownload,format=nv12") else (set "current_vf=hwdownload,format=nv12")
										)
										if defined subtitles_style (
											if defined current_vf (set "current_vf=!current_vf!,subtitles='!sub_escaped!':force_style='!subtitles_style!'") else (set "current_vf=subtitles='!sub_escaped!':force_style='!subtitles_style!'")
										) else (
											if defined current_vf (set "current_vf=!current_vf!,subtitles='!sub_escaped!'") else (set "current_vf=subtitles='!sub_escaped!'")
										)
									)
									if "!video_subtitles_value!"=="meta" (
										set "subtitles_params=-i "!sub_file!" -c:s mov_text -metadata:s:s:0 language=rus"
										set "convert_settings=!convert_settings! -map 0 -map 1"
									)
									set "sub_found=1"
								)
							)
						)
					)

					rem Финализация фильтров. Значение -vf/-af берём в кавычки: путь субтитров
					rem или force_style с пробелами иначе разбивается на несколько argv для ffmpeg.
					if defined current_vf (set "vf_args=-vf "!current_vf!"")
					if defined current_af (set "af_args=-af "!current_af!"")
					rem copy_codecs несовместим с фильтрами
					if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")

					set "out_file=%folder_destination%!file_path!!file_name!!pref!.!current_format_out!"

					rem D7. Dry-run
					rem -ss располагается ДО -i: fast seek по контейнеру вместо декодирования от 0.
					if %%b==0 (set "seek_arg=") else (set "seek_arg=-ss %%b")
					if "%dry_run%"=="yes" (
						echo [DRY-RUN] "%ffmpeg%" -hide_banner -strict -2 !hw_decode_args! !seek_arg! -i "!full_path!" !subtitles_params! !convert_settings! !thread_args! !vf_args! !af_args! !current_set_length! "!out_file!"
					) else (
						echo [INFO] Кодирование: !full_path!
						"%ffmpeg%" -hide_banner -strict -2 !hw_decode_args! !seek_arg! -i "!full_path!" !subtitles_params! !convert_settings! !thread_args! !vf_args! !af_args! !current_set_length! "!out_file!" -y
						if errorlevel 1 (
							echo [FAIL] !full_path!
							if exist "!out_file!" del "!out_file!"
							if "%enable_log%"=="yes" echo [FAIL] !full_path! >> "%log_file%"
							set /a "total_fail+=1"
						) else (
							echo [OK] !full_path! -^> !out_file!
							if "%enable_log%"=="yes" echo [OK] !full_path! -^> !out_file! >> "%log_file%"
							set /a "total_ok+=1"
						)
					)
					set /a "c+=1"
				)
			) else (
				set /a "total_skip+=1"
			)
		) else (
			set /a "total_skip+=1"
		)
exit /b

:after_files

rem --- J2. Итоговая сводка ---
set "end_hh=%time:~0,2%"
set "end_mm=%time:~3,2%"
set "end_ss=%time:~6,2%"
set "end_hh=%end_hh: =0%"
set "end_mm=%end_mm: =0%"
set "end_ss=%end_ss: =0%"
set /a "end_total_sec=(1%end_hh%-100)*3600+(1%end_mm%-100)*60+(1%end_ss%-100)"
set /a "elapsed_sec=end_total_sec - start_total_sec"
if !elapsed_sec! lss 0 set /a "elapsed_sec+=86400"
set /a "elapsed_min=elapsed_sec/60"
set /a "elapsed_sec_rem=elapsed_sec%%60"

echo.
echo ============================================
echo   Обработано:  !total_ok! файлов
echo   Пропущено:   !total_skip! (уже существуют)
echo   Ошибки:      !total_fail!
echo   Время:       !elapsed_min! мин !elapsed_sec_rem! сек
echo ============================================
echo.
echo.
pause
exit

rem --- D6. Построение каскада atempo (milli-арифметика, без float) ---
rem %1 = playback_speed (например 3.0, 0.25, 1.5). Результат -> af_chain.
:build_atempo
set "_spd=%~1"
for /f "tokens=1,2 delims=." %%a in ("%_spd%") do (set "_bi=%%a" & set "_bf=%%b")
if not defined _bf set "_bf=0"
rem Дробную часть нормализуем до 3 знаков (milli). Префикс "1" + вычет 1000 убирает
rem октальную трактовку ведущих нулей в set /a (например "050" -> 50, а не ошибка).
set "_bf3=!_bf!000"
set "_bf3=!_bf3:~0,3!"
set /a "_bmilli=_bi*1000 + (1!_bf3! - 1000)"
set "af_chain="
set /a "_brem=_bmilli"
:_bt_hi
if !_brem! gtr 2000 (
	if defined af_chain (set "af_chain=!af_chain!,atempo=2.0") else (set "af_chain=atempo=2.0")
	set /a "_brem=_brem/2"
	goto :_bt_hi
)
:_bt_lo
if !_brem! lss 500 (
	if defined af_chain (set "af_chain=!af_chain!,atempo=0.5") else (set "af_chain=atempo=0.5")
	set /a "_brem=_brem*2"
	goto :_bt_lo
)
rem Остаток milli -> строка D.DDD
set /a "_bri=_brem/1000"
set /a "_brf=_brem %% 1000"
set "_brf3=000!_brf!"
set "_brf3=!_brf3:~-3!"
if defined af_chain (set "af_chain=!af_chain!,atempo=!_bri!.!_brf3!") else (set "af_chain=atempo=!_bri!.!_brf3!")
exit /b
