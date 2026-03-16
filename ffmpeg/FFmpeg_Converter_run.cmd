@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion

:: ============================================================
:: FFmpeg Converter — Конфигурация (CMD / Windows)
:: ============================================================

:: --- Авто-определение ffmpeg рядом со скриптом ---
if exist "%~dp0ffmpeg.exe" (set "ffmpeg=%~dp0ffmpeg.exe") else (set "ffmpeg=ffmpeg")

:: --- Значения по умолчанию ---
set "folder_sources=m:\ffmpeg\0"
set "folder_destination=m:\ffmpeg\1"
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
set "hw_accel=:-:nvidia"
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
for /f "usebackq tokens=* delims=" %%L in ("%CONFIG_FILE%") do (
	set "_line=%%L"
	:: Убрать пробелы в начале
	for /f "tokens=* delims= " %%T in ("!_line!") do set "_line=%%T"
	:: Пропустить пустые строки и комментарии
	if defined _line if not "!_line:~0,1!"=="#" (
		:: Секция?
		echo !_line! | findstr /r "^\[.*\]$" >nul 2>&1
		if !errorlevel! equ 0 (
			set "_section=!_line:~1,-1!"
		) else (
			:: Парсинг key = value
			for /f "tokens=1,* delims==" %%K in ("!_line!") do (
				set "_key=%%K"
				set "_val=%%~L"
				:: Убрать пробелы из ключа
				for /f "tokens=* delims= " %%T in ("!_key!") do set "_key=%%T"
				:: Убрать пробелы из значения и инлайн-комментарии
				for /f "tokens=1 delims=#" %%V in ("%%~L") do (
					for /f "tokens=* delims= " %%T in ("%%V") do set "_val=%%T"
					:: Убрать trailing spaces из значения
					call :trim_val
				)
				:: Присвоить переменную по секции+ключу
				call :assign_var
			)
		)
	)
)
goto :start_coding

:trim_val
:: Убрать trailing spaces
if defined _val (
	for /l %%i in (1,1,3) do if "!_val:~-1!"==" " set "_val=!_val:~0,-1!"
)
exit /b

:assign_var
:: Вспомогательная: конвертировать +val/-val в :+:val/:-:val
:: Простые значения (yes/no/числа/пути) — напрямую
if "!_section!"=="folders" (
	if "!_key!"=="source" set "folder_sources=!_val!"
	if "!_key!"=="destination" set "folder_destination=!_val!"
)
if "!_section!"=="options" (
	if "!_key!"=="audio_only" set "audio_only=!_val!"
	if "!_key!"=="merge_files" set "merge_files=!_val!"
	if "!_key!"=="create_frame" set "create_frame=!_val!"
	if "!_key!"=="copy_codecs" set "copy_codecs=!_val!"
	if "!_key!"=="extract_audio_copy" set "extract_audio_copy=!_val!"
)
if "!_section!"=="audio" (
	if "!_key!"=="codec" call :to_flag "!_val!" "audio_codec"
	if "!_key!"=="channels" call :to_flag "!_val!" "audio_number_channels"
	if "!_key!"=="bitrate" call :to_flag "!_val!" "audio_bitrate"
	if "!_key!"=="sampling_rate" call :to_flag "!_val!" "audio_sampling_rate"
	if "!_key!"=="normalize" call :to_flag "!_val!" "audio_normalize"
)
if "!_section!"=="video" (
	if "!_key!"=="codec" call :to_flag "!_val!" "video_codec"
	if "!_key!"=="resolution" call :to_flag "!_val!" "video_resolution"
	if "!_key!"=="bitrate" call :to_flag "!_val!" "video_bitrate"
	if "!_key!"=="framerate" call :to_flag "!_val!" "video_number_frames"
	if "!_key!"=="rotation" call :to_flag "!_val!" "video_rotation"
	if "!_key!"=="subtitles" call :to_flag "!_val!" "video_subtitles"
	if "!_key!"=="quality" call :to_flag "!_val!" "video_quality"
	if "!_key!"=="keep_aspect_ratio" call :to_flag "!_val!" "keep_aspect_ratio"
	if "!_key!"=="container" call :to_flag "!_val!" "output_container"
)
if "!_section!"=="performance" (
	if "!_key!"=="threads" call :to_flag "!_val!" "multithreads"
	if "!_key!"=="parallel_files" call :to_flag "!_val!" "parallel_files"
)
if "!_section!"=="gpu" (
	if "!_key!"=="hw_accel" call :to_flag "!_val!" "hw_accel"
	if "!_key!"=="preset" call :to_flag "!_val!" "gpu_preset"
	if "!_key!"=="tune" call :to_flag "!_val!" "gpu_tune"
	if "!_key!"=="rc" call :to_flag "!_val!" "gpu_rc"
)
if "!_section!"=="speed" (
	if "!_key!"=="playback_speed" call :to_flag "!_val!" "playback_speed"
)
if "!_section!"=="split" (
	if "!_key!"=="start" call :to_flag "!_val!" "start_coding"
	if "!_key!"=="length" call :to_flag "!_val!" "length_coding"
	if "!_key!"=="split_by_silence" set "split_by_silence=!_val!"
	if "!_key!"=="silence_duration" set "silence_duration=!_val!"
	if "!_key!"=="silence_threshold" set "silence_threshold=!_val!"
)
if "!_section!"=="other" (
	if "!_key!"=="save_old_extension" set "save_old_extension=!_val!"
	if "!_key!"=="format_files_in" set "format_files_in=!_val!"
	if "!_key!"=="subtitles_style" set "subtitles_style=!_val!"
	if "!_key!"=="dry_run" set "dry_run=!_val!"
	if "!_key!"=="enable_log" set "enable_log=!_val!"
	if "!_key!"=="log_file" set "log_file=!_val!"
)
exit /b

:to_flag
:: Конвертирует +val/-val в :+:val/:-:val и присваивает переменной %2
set "_fv=%~1"
set "_fn=%~2"
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
echo !folder_sources! | findstr /r "^[a-zA-Z]:\\ ^\\\\">nul 2>&1
if !errorlevel! neq 0 set "folder_sources=%~dp0!folder_sources!"
echo !folder_destination! | findstr /r "^[a-zA-Z]:\\ ^\\\\">nul 2>&1
if !errorlevel! neq 0 set "folder_destination=%~dp0!folder_destination!"

:: start coding
call "%~dp0FFmpeg_Converter_script.cmd"
