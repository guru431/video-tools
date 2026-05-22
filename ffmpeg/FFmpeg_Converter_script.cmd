@echo off
setlocal enabledelayedexpansion

:: ============================================================
:: FFmpeg Converter Script (CMD)
:: ============================================================

:: --- E1. Проверка окружения ---
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

:: --- Парсинг настроек ---
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

:: --- Формирование аудио-параметров ---
if "!audio_codec_status!"=="+" (set "set_audio_codec=-c:a !audio_codec_value!") else (set "set_audio_codec=")
if "!audio_number_channels_status!"=="+" (set "set_audio_number_channels=-ac !audio_number_channels_value!") else (set "set_audio_number_channels=")
if "!audio_bitrate_status!"=="+" (set "set_audio_bitrate=-b:a !audio_bitrate_value!k") else (set "set_audio_bitrate=")
if "!audio_sampling_rate_status!"=="+" (set "set_audio_sampling_rate=-ar !audio_sampling_rate_value!") else (set "set_audio_sampling_rate=")

:: --- Формирование видео-параметров ---
if "!video_codec_status!"=="+" (set "set_video_codec=!video_codec_value!") else (set "set_video_codec=")
if "!video_number_frames_status!"=="+" (set "set_video_number_frames=-r !video_number_frames_value!") else (set "set_video_number_frames=")
if "!video_bitrate_status!"=="+" (set "set_video_bitrate_orig=!video_bitrate_value!") else (set "set_video_bitrate_orig=")

:: --- Многопоточность ---
if "!multithreads_status!"=="+" (set "threads=!multithreads_value!") else (set "threads=1")

:: --- C1. Аппаратное ускорение (NVIDIA / Intel) ---
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

:: --- Время начала и длительности ---
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

:: --- A1. Формат и настройки видео/аудио ---
if "%audio_only%"=="yes" (
	set "format_files_out=mp3"
	set "video_settings=-vn"
	set "set_audio_codec=-c:a libmp3lame"
) else (
	if "!output_container_status!"=="+" (set "format_files_out=!output_container_value!") else (set "format_files_out=mp4")
	:: E5. Сборка цепочки видео-фильтров
	set "vf_chain="
	if "!video_rotation_status!"=="+" (
		if "!hw_accel_type!"=="nvidia" (
			set "vf_chain=transpose_cuda=!video_rotation_value!"
		) else (
			set "vf_chain=transpose=!video_rotation_value!"
		)
	)
	:: D4. Масштабирование
	if "!video_resolution_status!"=="+" (
		for /f "tokens=1,2 delims=x" %%a in ("!video_resolution_value!") do set "res_w=%%a" & set "res_h=%%b"
		:: Определяем scale-фильтр по типу GPU
		set "scale_filter=scale"
		if "!hw_accel_type!"=="nvidia" set "scale_filter=scale_cuda"
		if "!hw_accel_type!"=="intel" set "scale_filter=scale_qsv"
		if "!keep_aspect_ratio_status!"=="+" if "!keep_aspect_ratio_value!"=="yes" (
			if "!use_hw_accel!"=="yes" (
				if defined vf_chain (set "vf_chain=!vf_chain!,!scale_filter!=!res_w!:!res_h!:force_original_aspect_ratio=decrease") else (set "vf_chain=!scale_filter!=!res_w!:!res_h!:force_original_aspect_ratio=decrease")
			) else (
				if defined vf_chain (set "vf_chain=!vf_chain!,scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease,pad=!res_w!:!res_h!:(ow-iw)/2:(oh-ih)/2") else (set "vf_chain=scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease,pad=!res_w!:!res_h!:(ow-iw)/2:(oh-ih)/2")
			)
		) else (
			if "!use_hw_accel!"=="yes" (
				if defined vf_chain (set "vf_chain=!vf_chain!,!scale_filter!=!res_w!:!res_h!") else (set "vf_chain=!scale_filter!=!res_w!:!res_h!")
			) else (
				if defined vf_chain (set "vf_chain=!vf_chain!,scale=!res_w!:!res_h!") else (set "vf_chain=scale=!res_w!:!res_h!")
			)
		)
	)
	:: D6. Скорость воспроизведения (видео)
	if "!playback_speed_status!"=="+" if not "!playback_speed_value!"=="1.0" (
		if defined vf_chain (set "vf_chain=!vf_chain!,setpts=PTS/!playback_speed_value!") else (set "vf_chain=setpts=PTS/!playback_speed_value!")
	)
	:: Формирование codec-строки
	if defined set_video_codec (set "set_video_codec_arg=-c:v !set_video_codec!") else (set "set_video_codec_arg=")
	:: C2. Настройки GPU (NVIDIA / Intel)
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
	:: D2. CRF для программных кодеков
	set "crf_args="
	if not "!use_hw_accel!"=="yes" if "!video_quality_status!"=="+" (
		set "crf_args=-crf !video_quality_value!"
	)
	set "video_settings=-f !format_files_out! !set_video_codec_arg! !set_video_number_frames! !gpu_args! !crf_args!"
)

:: D6. Скорость воспроизведения (аудио)
set "af_chain="
:: atempo supports range 0.5-2.0. Каскадирование для значений вне диапазона
:: не реализовано в CMD (нет float math). При попытке — предупреждение и пропуск,
:: чтобы ffmpeg не падал. Для скоростей >2.0 или <0.5 используйте .sh или .ps1.
if "!playback_speed_status!"=="+" if not "!playback_speed_value!"=="1.0" (
	for /f "tokens=1,2 delims=." %%a in ("!playback_speed_value!") do (
		set "_int=%%a"
		set "_frac=%%b"
	)
	if not defined _frac set "_frac=0"
	set "_oor=0"
	if !_int! geq 3 set "_oor=1"
	if !_int!==2 if not "!_frac!"=="0" set "_oor=1"
	if !_int!==0 if !_frac! lss 5 set "_oor=1"
	if "!_oor!"=="1" (
		echo [WARN] atempo=!playback_speed_value! вне диапазона 0.5-2.0; пропуск ^(используйте .sh/.ps1 для каскада^)
	) else (
		set "af_chain=atempo=!playback_speed_value!"
	)
)

:: D5. Нормализация звука
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

:: --- J2. Счётчики ---
set total_ok=0
set total_fail=0
set total_skip=0
:: Засекаем время через временный файл (чч:мм:сс)
set "start_hh=%time:~0,2%"
set "start_mm=%time:~3,2%"
set "start_ss=%time:~6,2%"
set /a "start_total_sec=(%start_hh%*3600+%start_mm%*60+%start_ss%)"

:: --- Основная логика ---
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
		set "full_path=%%~fa"
		set "file_path=%%~dpa"
		set "file_name=%%~na"
		if "%save_old_extension%"=="yes" (set "file_name=%%~nxa")

		set "file_path=!file_path:%folder_sources%=!"
		call set "file_path=!file_path:%%=%%%%!"
		if not exist "%folder_destination%!file_path!" md "%folder_destination%!file_path!"

		:: --- I. Извлечение аудио без перекодирования ---
		if "%extract_audio_copy%"=="yes" (
			set "audio_ext=mka"
			set "audio_line="
			for /f "delims=" %%c in ('""%ffmpeg%" -i "!full_path!" 2^>^&1 ^| find "Audio:""') do set "audio_line=%%c"
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
			goto :continue_next_file
		)

		if "%create_frame%"=="yes" (
			if not exist "%folder_destination%!file_path!!file_name!" (
				md "%folder_destination%!file_path!!file_name!"
				echo [INFO] Извлечение кадров: !full_path!
				"%ffmpeg%" -hide_banner -strict -2 -i "!full_path!" -r 1/1 "%folder_destination%!file_path!!file_name!\!file_name!_%%05d.png"
			)
			goto :continue_next_file
		)

		if not exist "%folder_destination%!file_path!!file_name!.!format_files_out!" (
			if not exist "%folder_destination%!file_path!!file_name! (part.1).!format_files_out!" (
				:: P3. Один вызов ffmpeg -i на файл (раньше было 2: bitrate + Duration).
				:: ffmpeg печатает metadata в stderr → перенаправляем в файл, stdout → nul.
				set "_ff_info_tmp=%temp%\ffinfo_!random!.txt"
				"%ffmpeg%" -i "!full_path!" 1>nul 2>"!_ff_info_tmp!"
				:: E4. Получение битрейта.
				:: tokens=6 хрупкий — если ffmpeg вернёт N/A или формат изменится, %%i
				:: будет не-числом и `if lss` сравнит лексически. Fallback ниже гарантирует,
				:: что -b:v всегда задан, иначе ffmpeg уйдёт в дефолт/неограниченный битрейт.
				set "set_video_bitrate_final="
				if "!video_bitrate_status!"=="+" if not "!video_quality_status!"=="+" (
					for /f "tokens=6 delims= " %%i in ('findstr /i "bitrate:" "!_ff_info_tmp!"') do (
						set "_br_raw=%%i"
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
					:: %%~xa возвращает расширение с ведущей точкой (".mp4"); ниже out_file
					:: собирается как "<name>.<current_format_out>", поэтому точку убираем.
					set "current_format_out=%%~xa"
					if defined current_format_out set "current_format_out=!current_format_out:~1!"
				) else (
					set "convert_settings=!video_settings! !set_video_bitrate_final! !audio_settings!"
					set "current_format_out=!format_files_out!"
				)

				:: Видео/аудио фильтры
				set "vf_args="
				set "current_vf=!vf_chain!"
				set "af_args="
				set "current_af=!af_chain!"
				:: База до per-part модификаций (subtitles burn / meta -map). Восстанавливается
				:: в начале каждой итерации цикла по частям, иначе значения накапливаются:
				:: для части 2 получится "<base>,subtitles=...,subtitles=..." и "-map 0 -map 1 -map 0 -map 1".
				set "_cs_base=!convert_settings!"
				set "_vf_base=!current_vf!"
				set "_af_base=!current_af!"

				if "!length_coding_status!"=="+" (
					:: Парсинг Duration. Если ffmpeg вернёт "Duration: N/A" (бывает на потоках/
					:: повреждённых контейнерах), %%i будет нечисловым ("N") → set /a даст 0
					:: или ошибку. Проверяем что результат цифровой; иначе duration=0, и split
					:: пропускается (файл обрабатывается целиком).
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
									set "num=!num! !new_part_start!"
									set /a "lcv_silent%%i=length_coding_value - (part_start - new_part_start)"
									set "lcv%%i=!new_part_start!"
								) else (set "num=!num! !part_start!")
							) else (set "d=1")
						)
					)
				) else (set "num=0")
				if "!start_coding_status!"=="+" (set "num=!start_coding_value!")

				:: P3. _ff_info_tmp больше не нужен — bitrate и Duration уже прочитаны.
				if defined _ff_info_tmp del "!_ff_info_tmp!" 2>nul

				set "c=1"
				for %%b in (!num!) do (
					if "!num!"=="0" (set "pref=") else (set "pref= (part.!c!)")

					:: Сброс из базы — см. _cs_base / _vf_base / _af_base выше.
					set "convert_settings=!_cs_base!"
					set "current_vf=!_vf_base!"
					set "current_af=!_af_base!"

					set "current_set_length=!set_length_coding!"
					if "!split_by_silence!"=="yes" (set /a "cc=c-1" & call set "current_set_length=-t %%lcv_silent!cc!%%")

					:: B2. Субтитры с subtitles_style
					set "subtitles_params="
					if "!video_subtitles_status!"=="+" if not "%copy_codecs%"=="yes" (
						set "sub_found="
						for %%e in (srt vtt) do (
							if not "!sub_found!"=="1" (
								set "sub_file=!folder_sources!!file_path!!file_name!.%%e"
								if exist "!sub_file!" (
									if "!video_subtitles_value!"=="burn" (
										:: Экранирование пути для subtitles=:
										:: \ : ' — спецсимволы внутри значения фильтра;
										:: [ ] ; — спецсимволы graph-синтаксиса (разделители labels и фильтров);
										:: % — раскрывается ffmpeg как timecode-плейсхолдер.
										set "sub_escaped=!sub_file:\=\\\\!"
										set "sub_escaped=!sub_escaped:'=\\\'!"
										set "sub_escaped=!sub_escaped::=\'\:!"
										set "sub_escaped=!sub_escaped:[=\[!"
										set "sub_escaped=!sub_escaped:]=\]!"
										set "sub_escaped=!sub_escaped:;=\;!"
										set "sub_escaped=!sub_escaped:%%=\%%!"
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

					:: Финализация фильтров
					if defined current_vf (set "vf_args=-vf !current_vf!")
					if defined current_af (set "af_args=-af !current_af!")
					:: copy_codecs несовместим с фильтрами
					if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")

					set "out_file=%folder_destination%!file_path!!file_name!!pref!.!current_format_out!"

					:: D7. Dry-run
					:: -ss располагается ДО -i: fast seek по контейнеру вместо декодирования от 0.
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

		:continue_next_file
	)
)

:: --- J2. Итоговая сводка ---
set "end_hh=%time:~0,2%"
set "end_mm=%time:~3,2%"
set "end_ss=%time:~6,2%"
set /a "end_total_sec=(%end_hh%*3600+%end_mm%*60+%end_ss%)"
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
