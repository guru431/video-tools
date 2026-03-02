@echo off
chcp 65001 >nul 2>&1

:: ============================================================
:: FFmpeg Converter — Конфигурация (CMD / Windows)
:: ============================================================

:: general settings
set "folder_sources=m:\ffmpeg\0"
set "folder_destination=m:\ffmpeg\1"

:: options
set "audio_only=no"
set "merge_files=no"
set "create_frame=no"
set "copy_codecs=no"
set "multithreads=:+:4"
set "parallel_files=:-:2"
set "extract_audio_copy=no"

:: audio settings
set "audio_codec=:+:aac"
set "audio_number_channels=:+:2"
set "audio_bitrate=:+:128"
set "audio_sampling_rate=:+:44100"
set "audio_normalize=:-:loudnorm"

:: video settings
set "video_codec=:+:libx264"
set "video_resolution=:+:1280x720"
set "video_bitrate=:+:2000"
set "video_number_frames=:+:25"
set "video_rotation=:-:2"
set "video_subtitles=:-:burn"
set "video_quality=:-:23"
set "keep_aspect_ratio=:+:yes"
set "output_container=:-:mp4"

:: hardware acceleration
set "hw_accel=:-:nvidia"
set "gpu_preset=:-:p5"
set "gpu_tune=:-:hq"
set "gpu_rc=:-:vbr"

:: playback speed
set "playback_speed=:-:1.0"

:: split settings
set "start_coding=:-:01-00-00"
set "length_coding=:-:00-05-00"
set "split_by_silence=no"
set "silence_duration=2.0"
set "silence_threshold=-30dB"

:: other settings
set "ffmpeg=ffmpeg"
set "save_old_extension=no"
set "format_files_in=3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
set "subtitles_style=FontName=Arial:FontSize=24:PrimaryColour=&HFFFFFF&"
set "dry_run=no"
set "enable_log=no"
set "log_file=ffmpeg_convert.log"

:: start coding
call "%~dp0FFmpeg_Converter_script.cmd"
