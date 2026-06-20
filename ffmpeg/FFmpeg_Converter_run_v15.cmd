@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: ============================================================
:: FFmpeg Converter — Конфигурация (CMD / Windows)
:: ============================================================

:: --- Авто-определение ffmpeg рядом со скриптом ---
if exist "%~dp0ffmpeg.exe" (set "ffmpeg=%~dp0ffmpeg.exe") else (set "ffmpeg=ffmpeg")

:: --- Значения по умолчанию ---
set "folder_sources=_video_\0"
set "folder_destination=_video_\1"
set "audio_only=no"
set "merge_files=no"
set "create_frame=no"
set "copy_codecs=no"
set "extract_audio_copy=no"
set "audio_codec=:+:aac"
set "audio_number_channels=:+:2"
set "audio_bitrate=:+:128"
set "audio_sampling_rate=:+:48000"
set "audio_normalize=:-:loudnorm"
set "video_codec=:+:libx264"
set "video_resolution=:+:1280x720"
set "video_bitrate=:-:3000"
set "video_number_frames=:+:30"
set "video_rotation=:-:2"
set "video_subtitles=:-:burn"
set "video_quality=:-:23"
set "keep_aspect_ratio=:+:yes"
set "output_container=:+:mp4"
set "multithreads=:+:4"
set "parallel_files=:-:2"
set "hw_accel=:-:intel"
set "gpu_preset=:-:p5"
set "gpu_tune=:-:hq"
set "gpu_rc=:-:vbr"
set "playback_speed=:-:1.0"
set "start_coding=:-:01-00-00"
set "length_coding=:-:00-05-00"
set "split_by_silence=no"
set "silence_duration=2.0"
set "silence_threshold=-30dB"
set "save_old_extension=no"
set "format_files_in=3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
set "subtitles_style=FontName=Arial:FontSize=24:PrimaryColour=&HFFFFFF&"
set "dry_run=no"
set "enable_log=no"
set "log_file=ffmpeg_convert.log"

:: --- Чтение config.ini ---
set "CONFIG_FILE=%~dp0config.ini"
if not exist "%CONFIG_FILE%" goto :start_coding

set "_section="
:: Ограничение CMD: значения с '!' (напр. C:\My!Folder!) не поддерживаются — enabledelayedexpansion
:: раскрывает '!...!' при чтении строки, а отключить его нельзя без потери поддержки '&' в значениях
:: (напр. дефолтный subtitles_style=...&HFFFFFF&). Для путей с '!' используйте SH/PS1.
for /f "usebackq tokens=* delims=" %%L in ("%CONFIG_FILE%") do (
	set "_line=%%L"
	:: Убрать пробелы/табы в начале (delims = пробел+TAB)
	for /f "tokens=* delims=	 " %%T in ("!_line!") do set "_line=%%T"
	:: Пропустить пустые строки и комментарии
	if defined _line if not "!_line:~0,1!"=="#" (
		:: Секция? Без echo|findstr — пайп исполнял & из значений, а якорь $ не работал
		set "_is_section="
		if "!_line:~0,1!"=="[" if "!_line:~-1!"=="]" set "_is_section=1"
		if defined _is_section (
			set "_section=!_line:~1,-1!"
		) else (
			:: Парсинг key = value
			for /f "tokens=1,* delims==" %%K in ("!_line!") do (
				set "_key=%%K"
				set "_val=%%~L"
				:: Убрать пробелы/табы из ключа (ведущие + хвостовые)
				for /f "tokens=* delims=	 " %%T in ("!_key!") do set "_key=%%T"
				call :trim_key
				rem Инлайн-комментарий режем только по " #" (см. :strip_inline_comment).
				call :strip_inline_comment
				:: Убрать ведущие пробелы/табы и trailing
				for /f "tokens=* delims=	 " %%T in ("!_val!") do set "_val=%%T"
				call :trim_val
				:: Подстановка ${ENV_VAR} из окружения (паритет с yt-dlp/SH/PS1)
				call :expand_env
				:: Присвоить переменную по секции+ключу
				call :assign_var
			)
		)
	)
)
goto :start_coding

:trim_val
:: Убрать все trailing spaces/tabs из значения
if not defined _val exit /b
if "!_val:~-1!"==" " (set "_val=!_val:~0,-1!" & goto :trim_val)
if "!_val:~-1!"=="	" (set "_val=!_val:~0,-1!" & goto :trim_val)
exit /b

:trim_key
:: Убрать все trailing spaces/tabs из ключа
if not defined _key exit /b
if "!_key:~-1!"==" " (set "_key=!_key:~0,-1!" & goto :trim_key)
if "!_key:~-1!"=="	" (set "_key=!_key:~0,-1!" & goto :trim_key)
exit /b

:strip_inline_comment
:: Режем инлайн-комментарий только по " #" (пробел+решётка), не по любому #,
:: иначе значения вида my#file.log теряют хвост. Пайп-маркер |CUT| безопасен здесь
:: (call-контекст, не for-блок), где | внутри кавычек не трактуется как пайп.
if not defined _val exit /b
set "_val_nc=!_val: #=|CUT|!"
for /f "tokens=1 delims=|" %%V in ("!_val_nc!") do set "_val=%%V"
exit /b

:expand_env
:: Подстановка ${ENV_VAR} из окружения (паритет с yt-dlp/SH/PS1). Не задана → пусто.
:: Substring-проверка на ${ вместо echo|findstr (пайп исполнял бы & из значения).
:: Ограничение: значения env-переменной с '!' не поддерживаются (см. шапку про delayed expansion).
if not defined _val exit /b
:_ee_loop
if "!_val!"=="!_val:${=!" exit /b
for /f "tokens=2 delims={}" %%V in ("!_val!") do set "_ee_name=%%V"
call set "_ee_val=%%%_ee_name%%%"
set "_val=!_val:${%_ee_name%}=%_ee_val%!"
goto :_ee_loop

:assign_var
:: Вспомогательная: конвертировать +val/-val в :+:val/:-:val
:: Простые значения (yes/no/числа/пути) — напрямую
if /i "!_section!"=="folders" (
	if /i "!_key!"=="source" set "folder_sources=!_val!"
	if /i "!_key!"=="destination" set "folder_destination=!_val!"
)
if /i "!_section!"=="options" (
	if /i "!_key!"=="audio_only" set "audio_only=!_val!"
	if /i "!_key!"=="merge_files" set "merge_files=!_val!"
	if /i "!_key!"=="create_frame" set "create_frame=!_val!"
	if /i "!_key!"=="copy_codecs" set "copy_codecs=!_val!"
	if /i "!_key!"=="extract_audio_copy" set "extract_audio_copy=!_val!"
)
if /i "!_section!"=="audio" (
	if /i "!_key!"=="codec" call :to_flag "!_val!" "audio_codec"
	if /i "!_key!"=="channels" call :to_flag "!_val!" "audio_number_channels"
	if /i "!_key!"=="bitrate" call :to_flag "!_val!" "audio_bitrate"
	if /i "!_key!"=="sampling_rate" call :to_flag "!_val!" "audio_sampling_rate"
	if /i "!_key!"=="normalize" call :to_flag "!_val!" "audio_normalize"
)
if /i "!_section!"=="video" (
	if /i "!_key!"=="codec" call :to_flag "!_val!" "video_codec"
	if /i "!_key!"=="resolution" call :to_flag "!_val!" "video_resolution"
	if /i "!_key!"=="bitrate" call :to_flag "!_val!" "video_bitrate"
	if /i "!_key!"=="framerate" call :to_flag "!_val!" "video_number_frames"
	if /i "!_key!"=="rotation" call :to_flag "!_val!" "video_rotation"
	if /i "!_key!"=="subtitles" call :to_flag "!_val!" "video_subtitles"
	if /i "!_key!"=="quality" call :to_flag "!_val!" "video_quality"
	if /i "!_key!"=="keep_aspect_ratio" call :to_flag "!_val!" "keep_aspect_ratio"
	if /i "!_key!"=="container" call :to_flag "!_val!" "output_container"
)
if /i "!_section!"=="performance" (
	if /i "!_key!"=="threads" call :to_flag "!_val!" "multithreads"
	if /i "!_key!"=="parallel_files" call :to_flag "!_val!" "parallel_files"
)
if /i "!_section!"=="gpu" (
	if /i "!_key!"=="hw_accel" call :to_flag "!_val!" "hw_accel"
	if /i "!_key!"=="preset" call :to_flag "!_val!" "gpu_preset"
	if /i "!_key!"=="tune" call :to_flag "!_val!" "gpu_tune"
	if /i "!_key!"=="rc" call :to_flag "!_val!" "gpu_rc"
)
if /i "!_section!"=="speed" (
	if /i "!_key!"=="playback_speed" call :to_flag "!_val!" "playback_speed"
)
if /i "!_section!"=="split" (
	if /i "!_key!"=="start" call :to_flag "!_val!" "start_coding"
	if /i "!_key!"=="length" call :to_flag "!_val!" "length_coding"
	if /i "!_key!"=="split_by_silence" set "split_by_silence=!_val!"
	if /i "!_key!"=="silence_duration" set "silence_duration=!_val!"
	if /i "!_key!"=="silence_threshold" set "silence_threshold=!_val!"
)
if /i "!_section!"=="other" (
	if /i "!_key!"=="save_old_extension" set "save_old_extension=!_val!"
	if /i "!_key!"=="format_files_in" set "format_files_in=!_val!"
	if /i "!_key!"=="subtitles_style" set "subtitles_style=!_val!"
	if /i "!_key!"=="dry_run" set "dry_run=!_val!"
	if /i "!_key!"=="enable_log" set "enable_log=!_val!"
	if /i "!_key!"=="log_file" set "log_file=!_val!"
)
exit /b

:to_flag
:: Конвертирует +val/-val в :+:val/:-:val и присваивает переменной %2
:: Пустое значение — оставить дефолт
set "_fv=%~1"
set "_fn=%~2"
if not defined _fv exit /b
if "!_fv:~0,1!"=="+" (
	set "!_fn!=:+:!_fv:~1!"
) else if "!_fv:~0,1!"=="-" (
	set "!_fn!=:-:!_fv:~1!"
) else (
	set "!_fn!=:+:!_fv!"
)
exit /b

:start_coding
:: --- Резолвинг относительных путей от директории скрипта ---
:: Детект абсолютного пути без echo|findstr — пайп исполнял & из значений
set "_abs="
if "!folder_sources:~1,2!"==":\" set "_abs=1"
if "!folder_sources:~1,2!"==":/" set "_abs=1"
if "!folder_sources:~0,2!"=="\\" set "_abs=1"
if "!folder_sources:~0,2!"=="//" set "_abs=1"
if not defined _abs set "folder_sources=%~dp0!folder_sources!"
set "_abs="
if "!folder_destination:~1,2!"==":\" set "_abs=1"
if "!folder_destination:~1,2!"==":/" set "_abs=1"
if "!folder_destination:~0,2!"=="\\" set "_abs=1"
if "!folder_destination:~0,2!"=="//" set "_abs=1"
if not defined _abs set "folder_destination=%~dp0!folder_destination!"

rem Тестовый хук: --print-config печатает распарсенные переменные и выходит, не запуская script
if "%~1"=="--print-config" (
	for %%V in (folder_sources folder_destination audio_only merge_files create_frame copy_codecs extract_audio_copy audio_codec audio_number_channels audio_bitrate audio_sampling_rate audio_normalize video_codec video_resolution video_bitrate video_number_frames video_rotation video_subtitles video_quality keep_aspect_ratio output_container multithreads parallel_files hw_accel gpu_preset gpu_tune gpu_rc playback_speed start_coding length_coding split_by_silence silence_duration silence_threshold save_old_extension format_files_in subtitles_style dry_run enable_log log_file) do echo %%V=!%%V!
	exit /b 0
)

:: start coding
if not exist "%~dp0FFmpeg_Converter_script.cmd" (
	echo Ошибка: не найден FFmpeg_Converter_script.cmd рядом с этим файлом.
	exit /b 1
)
call "%~dp0FFmpeg_Converter_script.cmd"
