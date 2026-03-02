#!/bin/bash

# ============================================================
# FFmpeg Converter — Конфигурация (Bash / Linux)
# ============================================================

# general settings
folder_sources="/mnt/share/_Downloads/ffmpeg/0"		# Здесь не должно быть скобок и восклицательных знаков
folder_destination="/mnt/share/_Downloads/ffmpeg/1"	# Здесь не должно быть восклицательных знаков

# options
audio_only="no"						# Сохранить только аудио (при включенном "audio_only" все настройки "video settings" игнорируются)
merge_files="no"					# Объединить файлы
create_frame="no"					# Разбить видео на кадры (при включенном "create_frame" все другие настройки игнорируются)
copy_codecs="no"					# Выполнить без перекодирования (при включенном "copy_codecs" все настройки "audio settings" и "video settings" игнорируются)
multithreads=":+:4"					# Число потоков ffmpeg (для программных кодеков: libx264, libx265)
parallel_files=":-:2"				# Количество файлов для одновременной обработки
extract_audio_copy="no"				# Извлечь аудио без перекодирования (копирует аудио-дорожку как есть; игнорирует все audio/video settings)

# audio settings
audio_codec=":+:aac"				# Аудио кодек (для видео на Apple - aac, для mp3 - libmp3lame)
audio_number_channels=":+:2"		# Число каналов: 1 - mono, 2 - stereo
audio_bitrate=":+:128"				# Аудио битрейт (если в исходном файле битрейт аудио меньше, то при кодировании он будет повышен)
audio_sampling_rate=":+:44100"		# Частота дискретизации (ниже 32000 опускать не рекомендуется, максимум - 48000)
audio_normalize=":-:loudnorm"		# Нормализация звука: loudnorm (EBU R128), dynaudnorm, off

# video settings
video_codec=":+:libx264"			# Видео кодек. Программные: libx264, libx265, libsvtav1. GPU (NVIDIA): h264_nvenc, hevc_nvenc, av1_nvenc. Intel: h264_qsv
video_resolution=":+:1280x720"		# Разрешение видео (примеры (16:9): 1080p - 1920x1080; 720p - 1280x720; 360p - 640x360)
video_bitrate=":+:2000"				# Видео битрейт (если в исходном файле битрейт видео меньше, то при кодировании он изменяться не будет)
video_number_frames=":+:25"			# Количество кадров в секунду
video_rotation=":-:2"				# Повернуть видео: 1 - по часовой стрелке, 2 - против часовой стрелки
video_subtitles=":-:burn"			# Добавить субтитры: burn - накладывать на видео, meta - добавить отдельной дорожкой
video_quality=":-:23"				# Постоянное качество (CRF/CQ): 0-51, ниже = лучше. Когда включён — video_bitrate игнорируется
keep_aspect_ratio=":+:yes"			# Сохранять пропорции при изменении разрешения
output_container=":-:mp4"			# Выходной контейнер: mp4, mkv, webm, avi, ts

# hardware acceleration
hw_accel=":-:nvidia"				# Аппаратное ускорение: nvidia (NVENC/CUVID), intel (QSV), off
gpu_preset=":-:p5"					# Пресет GPU: NVENC p1-p7, QSV veryfast/faster/fast/medium/slow/slower/veryslow
gpu_tune=":-:hq"					# Tune (только NVIDIA): hq, ll, ull, lossless
gpu_rc=":-:vbr"					# Rate control (только NVIDIA): constqp, vbr, cbr

# playback speed
playback_speed=":-:1.0"			# Скорость воспроизведения: 1.0 = нормальная, 2.0 = ускорение x2, 0.5 = замедление x2

# split settings
#######################################:
# Если необходимо разрезать файл на части определенной продолжительности, то "start_coding" отключаем, а в "length_coding" указываем продолжительность одного куска
# Если необходимо вырезать фрагмент из середины файла, то в "start_coding" указываем с какого момента начинать вырезать, а в "length_coding" продолжительность вырезаемого фрагмента
# Если необходимо обрезать начало файла, то в "start_coding" указываем с какого момента начать вырезать, а "length_coding" отключаем
#######################################:
start_coding=":-:01-00-00"			# Время начала кодирования
length_coding=":-:00-05-00"			# Длительность фрагмента (17000 секунд = 04-43-20)
split_by_silence="no"				# Разрезать по тишине (если есть рядом паузы с тишиной, разрез будет в этом месте)
silence_duration="2.0"				# Минимальная длительность тишины для разрезания (в секундах)
silence_threshold="-30dB"			# Порог тишины для обнаружения

# other settings
ffmpeg="ffmpeg"						# Путь к ffmpeg
save_old_extension="no"				# Оставлять старое расширение файла в названии (например, <file_name>.avi.mp4)
format_files_in="3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"		# Формат файлов на входе
subtitles_style="FontName=Arial:FontSize=24:PrimaryColour=&HFFFFFF&"									# Стиль субтитров
dry_run="no"						# Только показать команды, не запускать
enable_log="no"						# Писать лог в файл
log_file="ffmpeg_convert.log"		# Путь к файлу лога

# start coding #
source "$(dirname "$0")/FFmpeg_Converter_script.sh"
