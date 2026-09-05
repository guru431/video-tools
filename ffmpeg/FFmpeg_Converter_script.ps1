# ============================================================
# FFmpeg Converter Script (PowerShell)
# ============================================================

# Перехват ошибок верхнего уровня: пишем строку с номером в Error-stream и
# пере-выбрасываем (break) как терминирующую — её ловит вызывающий: CLI падает с
# ненулевым кодом, GUI читает через EndInvoke()/$ps.Streams.Error.
trap {
	Write-Error "LINE $($_.InvocationInfo.ScriptLineNumber): $_"
	break
}

# F1. У New-Item нет -LiteralPath ни в одной версии PowerShell, поэтому каталоги/файлы
# по путям из пользовательского дерева создаём через .NET. GetUnresolvedProviderPathFromPSPath
# разворачивает относительный путь по ТЕКУЩЕМУ $PWD провайдера (у голого [IO.Path]::GetFullPath
# берётся process CWD, который в PowerShell расходится с $PWD) и не трогает [ ] ? * как маску.
function New-DirLiteral {
	param([string]$Path)
	[System.IO.Directory]::CreateDirectory(
		$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)) | Out-Null
}
function New-EmptyFileLiteral {
	param([string]$Path)
	[System.IO.File]::WriteAllText(
		$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path), '')
}

# --- F-path. Нормализация корневых путей ---
# config.ini один на три платформы, но нормализация разделителей была односторонней
# ('\' -> разделитель платформы). Два следствия, оба ловятся здесь:
#   1) `source = C:/video/in` работал в SH и ронял PS1: $file.DirectoryName отдаёт
#      'C:\video\in\sub', strip-префикс 'C:/video/in' не срабатывал и путь выхода
#      становился мусором ('C:/video/out' + 'C:\video\in\sub\');
#   2) хвостовой разделитель (`source = D:\video\in\`) съедал ведущий разделитель
#      относительного пути, и выход уезжал в `D:\video\outsub\`.
# Корень диска ('C:\') и корень UNC-шары трогать нельзя — там разделитель значащий.
function Normalize-FolderPath {
	param([string]$Path)
	if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
	$s = [string][System.IO.Path]::DirectorySeparatorChar
	$p = $Path.Replace('/', $s).Replace('\', $s)
	$trimmed = $p.TrimEnd($s[0])
	if ($trimmed.Length -eq 0) { return $p }              # корень POSIX '/'
	if ($trimmed -match '^[A-Za-z]:$') { return $trimmed + $s }   # корень диска 'C:\'
	return $trimmed
}
$folder_sources     = Normalize-FolderPath $folder_sources
$folder_destination = Normalize-FolderPath $folder_destination

# --- E1. Проверка окружения ---
$_isGui = [bool]$env:FFMPEG_GUI_PROGRESS_FILE -or [bool]$guiProgressFile

# Пауза «нажмите Enter» — только в интерактивной консоли. Под GUI её нет по определению,
# а в cron/CI stdin перенаправлен: Read-Host ждал бы EOF, и джоба стояла бы на паузе
# вместо того, чтобы сразу отдать exit code. Паритет с pause_prompt в .sh.
function Pause-Prompt {
	param([string]$Text)
	if ($_isGui) { return }
	try { if ([Console]::IsInputRedirected) { return } } catch {}
	Read-Host $Text | Out-Null
}
if ([string]::IsNullOrWhiteSpace($folder_sources) -or !(Test-Path -LiteralPath $folder_sources)) {
	Write-Host "`n[ОШИБКА] Папка источника не найдена: $folder_sources`n"
	Pause-Prompt "Нажмите [Enter], чтобы выйти..."
	exit 1
}

if ([string]::IsNullOrWhiteSpace($folder_destination)) {
	Write-Host "`n[ОШИБКА] Папка назначения не задана`n"
	Pause-Prompt "Нажмите [Enter], чтобы выйти..."
	exit 1
}
# CreateDirectory идемпотентен — предварительный Test-Path не нужен
New-DirLiteral $folder_destination

# Оба корня приводим к канонической форме СРАЗУ, пока не построен ни один путь: карта
# коллизий выходов склеивает ключ из $folder_destination, а пофайловая проверка
# канонизирует уже созданный каталог. При `destination = ..\out` две формы одного пути
# не совпадали строкой, и конфликт выходов печатался, но не предотвращался.
# Паритет с _canon_root в .sh.
function Resolve-RootPath {
	param([string]$Path)
	try {
		$rp = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath
		if ($rp) { return (Normalize-FolderPath $rp) }
	} catch {}
	return $Path
}
$folder_sources     = Resolve-RootPath $folder_sources
$folder_destination = Resolve-RootPath $folder_destination

# ffmpeg обязателен ровно тогда, когда именно он и считает. При
# [remote] enabled = yes считает служба, и требовать локальный ffmpeg значило бы
# закрывать заявленный сценарий «тонкий клиент». Отсутствие НЕ бесплатно: без
# него недоступны проверка скачанного результата и определение длительности —
# поэтому говорим вслух, а ниже отдельно отказываем там, где без него нельзя.
$ffmpeg_available = $true
try { & $ffmpeg -version 2>&1 | Out-Null } catch { $ffmpeg_available = $false }
if (-not $ffmpeg_available) {
	if ($remote_enabled -eq 'yes') {
		Write-Host "`n[ПРЕДУПРЕЖДЕНИЕ] ffmpeg не найден ($ffmpeg), но [remote] enabled = yes — кодирование считает служба."
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Без локального ffmpeg отключены: проверка скачанного результата и определение длительности.`n"
	} else {
		Write-Host "`n[ОШИБКА] ffmpeg не найден: $ffmpeg`n"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
}

# --- Парсинг настроек (формат :+:value или :-:value) ---
$_, $video_codec_status, $video_codec_value = $video_codec -split ":"
$_, $video_number_frames_status, $video_number_frames_value = $video_number_frames -split ":"
$_, $video_bitrate_status, $video_bitrate_value = $video_bitrate -split ":"
$_, $video_resolution_status, $video_resolution_value = $video_resolution -split ":"
$_, $video_rotation_status, $video_rotation_value = $video_rotation -split ":"
$_, $video_quality_status, $video_quality_value = $video_quality -split ":"
$_, $video_subtitles_status, $video_subtitles_value = $video_subtitles -split ":"

$_, $audio_codec_status, $audio_codec_value = $audio_codec -split ":"
$_, $audio_number_channels_status, $audio_number_channels_value = $audio_number_channels -split ":"
$_, $audio_bitrate_status, $audio_bitrate_value = $audio_bitrate -split ":"
$_, $audio_sampling_rate_status, $audio_sampling_rate_value = $audio_sampling_rate -split ":"
$_, $audio_normalize_status, $audio_normalize_value = $audio_normalize -split ":"

$_, $multithreads_status, $multithreads_value = $multithreads -split ":"
$_, $parallel_files_status, $parallel_files_value = $parallel_files -split ":"
$_, $hw_accel_status, $hw_accel_value = $hw_accel -split ":"
$_, $gpu_preset_status, $gpu_preset_value = $gpu_preset -split ":"
$_, $gpu_tune_status, $gpu_tune_value = $gpu_tune -split ":"
$_, $gpu_rc_status, $gpu_rc_value = $gpu_rc -split ":"
$_, $playback_speed_status, $playback_speed_value = $playback_speed -split ":"
$_, $keep_aspect_ratio_status, $keep_aspect_ratio_value = $keep_aspect_ratio -split ":"
$_, $output_container_status, $output_container_value = $output_container -split ":"

# --- Формирование аудио-параметров ---
$set_audio_codec = if ($audio_codec_status -eq "+") { "-c:a $audio_codec_value" } else { "" }
$set_audio_number_channels = if ($audio_number_channels_status -eq "+") { "-ac $audio_number_channels_value" } else { "" }
$set_audio_bitrate = if ($audio_bitrate_status -eq "+") { "-b:a ${audio_bitrate_value}k" } else { "" }
$set_audio_sampling_rate = if ($audio_sampling_rate_status -eq "+") { "-ar $audio_sampling_rate_value" } else { "" }

# --- Формирование видео-параметров ---
$set_video_codec = if ($video_codec_status -eq "+") { $video_codec_value } else { "" }
$set_video_number_frames = if ($video_number_frames_status -eq "+") { "-r $video_number_frames_value" } else { "" }
$set_video_bitrate_orig = if ($video_bitrate_status -eq "+") { $video_bitrate_value } else { "" }
$set_video_resolution = if ($video_resolution_status -eq "+") { $video_resolution_value } else { "" }

# --- Многопоточность ---
$threads = if ($multithreads_status -eq "+") { $multithreads_value } else { "1" }
# parallel_files реализован ТОЛЬКО в .sh (там пул фоновых подоболочек); в PS1 и CMD параллельной
# ветки нет. Раньше значение просто молча игнорировалось: один и тот же config.ini на
# Linux давал параллель, на Windows — последовательную обработку, и нигде об этом не
# говорилось. Считать $parallel_count незачем — говорим вслух и работаем последовательно.
if ($parallel_files_status -eq "+" -and "$parallel_files_value" -match '^\d+$' -and [int]$parallel_files_value -gt 1) {
	Write-Host "[ПРЕДУПРЕЖДЕНИЕ] parallel_files=$parallel_files_value игнорируется: параллельная обработка файлов реализована только в SH-версии. Файлы обрабатываются последовательно."
}

# --- Аппаратное ускорение (nvidia / intel / off) ---
$use_hw_accel = $false
$hw_accel_type = ""
$hw_decode_args = @()
# F33. Сначала РАЗРЕШАЕМ нужный энкодер, затем проверяем, что он есть в сборке,
# и только тогда включаем hardware. Раньше искали ЛЮБОЕ вхождение имени семейства
# (nvenc/qsv) в списке энкодеров — это давало два скрытых дефекта:
#   • сборка с h264_nvenc, но без av1_nvenc, для libsvtav1 подставляла несуществующий
#     av1_nvenc — падал каждый файл;
#   • кодек вне маппинга (например libvpx-vp9) оставался программным, но
#     -hwaccel_output_format cuda уже включался → софт получал hardware-кадры
#     («Impossible to convert between the formats»).
# Без локального ffmpeg (тонкий клиент, [remote] enabled = yes) спрашивать список
# энкодеров не у кого: CommandNotFoundException — терминирующая, проходит сквозь
# `2>&1 | Out-String` и уходит в top-level trap, обрывая весь пакет ДО первого файла.
# Дефолт шаблона hw_accel = +intel делал это поведением по умолчанию. Паритет с .sh.
if ($hw_accel_status -eq "+" -and -not $ffmpeg_available) {
	Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Локального ffmpeg нет — аппаратное ускорение не проверяется, выбор энкодера остаётся за службой."
}
if ($hw_accel_status -eq "+" -and $ffmpeg_available) {
	$encoders_list = & $ffmpeg -encoders 2>&1 | Out-String
	$hw_suffix = ""; $hw_label = ""; $hw_try_args = @(); $hw_try_type = ""
	switch ($hw_accel_value) {
		"nvidia" { $hw_suffix = "_nvenc"; $hw_label = "NVENC"; $hw_try_type = "nvidia"; $hw_try_args = @("-hwaccel", "cuda", "-hwaccel_output_format", "cuda") }
		"intel"  { $hw_suffix = "_qsv";   $hw_label = "QSV";   $hw_try_type = "intel";  $hw_try_args = @("-hwaccel", "qsv", "-hwaccel_output_format", "qsv") }
		# Опечатка в значении (+nvida, +amd) означала «считаем на процессоре» — молча.
		default  { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Неизвестное значение [performance] hw_accel = '$hw_accel_value' (ожидается nvidia или intel). Кодирование идёт на процессоре." }
	}
	if ($hw_suffix) {
		# Кандидат: маппинг software→GPU либо уже готовое GPU-имя от пользователя.
		$hw_candidate = switch -Regex ($set_video_codec) {
			'^libx264$'    { "h264$hw_suffix"; break }
			'^libx265$'    { "hevc$hw_suffix"; break }
			'^libsvtav1$'  { "av1$hw_suffix";  break }
			([regex]::Escape($hw_suffix) + '$') { $set_video_codec; break }
			default        { "" }
		}
		if (-not $hw_candidate) {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] У кодека $set_video_codec нет $hw_label-варианта. Используется программное кодирование."
		# Якорим имя по границам столбца: подстрочный match поймал бы av1_nvenc
		# в строке про av1_nvenc_hypothetical и наоборот.
		} elseif ($encoders_list -match "(?m)^\s*[A-Z.]+\s+$([regex]::Escape($hw_candidate))(\s|$)") {
			$use_hw_accel = $true
			$hw_accel_type = $hw_try_type
			$hw_decode_args = $hw_try_args
			$set_video_codec = $hw_candidate
		} else {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Энкодер $hw_candidate отсутствует в данной сборке ffmpeg. Используется программное кодирование."
		}
	}
}

# --- Время начала и длительности ---
# «чч-мм-сс» → секунды. Формат проверяем ДО каста: [int]"1:00:00" бросает исключение,
# которое подхватывает trap, и весь батч обрывался невнятной ошибкой вместо указания на
# конкретное поле. Паритет с check_hms в .sh и :check_hms в .cmd.
function ConvertTo-Seconds {
	param([string]$Value, [string]$What)
	if ($Value -notmatch '^\s*(\d{1,2})-(\d{1,2})-(\d{1,2})\s*$') {
		Write-Host "`n[ОШИБКА] ${What}: ожидается чч-мм-сс (например 00-01-30), получено: '$Value'`n"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	return [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3]
}

$_, $start_coding_status, $start_coding_value = $start_coding -split ":"
if ($start_coding_status -eq "+") {
	$start_coding_value = ConvertTo-Seconds "$start_coding_value" "[split] start"
} else {
	$start_coding_value = 0
}

$_, $length_coding_status, $length_coding_value = $length_coding -split ":"
if ($length_coding_status -eq "+") {
	$length_coding_value = ConvertTo-Seconds "$length_coding_value" "[split] length"
	# Нулевая длительность (`length = +00-00-00`) проходила валидацию формата и
	# давала `-t 0`: ffmpeg честно создавал пустые файлы и отчитывался успехом.
	if ($length_coding_value -le 0) {
		Write-Host "`n[ОШИБКА] [split] length: длительность должна быть больше нуля, получено: '00-00-00'`n"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	$set_length_coding = "-t $length_coding_value"
} else {
	$set_length_coding = ""
	$split_by_silence = "no"
}

# Суффикс " (part.N)", известный ЗАРАНЕЕ. При [split] start с ненулевым значением
# $num = @(start), часть всегда одна, и суффикс " (part.1)" добавляется гарантированно —
# значит имя выхода отличается от входа, и проверка «выход == вход» ниже обязана
# сверять имя С суффиксом. Иначе при in-place конвертации (destination == source)
# каждый файл получал ложный FAIL. Для [split] length число частей заранее неизвестно
# (нужна длительность), там проверка остаётся консервативной — см. её комментарий.
$part_suffix_known = ""
if ($start_coding_status -eq "+" -and $start_coding_value -ne 0) { $part_suffix_known = " (part.1)" }

# --- A1. Формат и настройки видео/аудио ---
# Инициализируем ДО ветки audio_only: иначе при audio_only=yes $vf_parts остаётся
# неопределён, а PS1 5.1 даёт `@() + $null` = массив из одного $null (Count=1) →
# осиротевший `-vf` с пустым значением ломает каждый файл.
$vf_parts = @()
if ($audio_only -eq "yes") {
	# Контейнер и аудио-кодек выводятся из настроенного [audio] codec, а не жёстко mp3.
	switch ($audio_codec_value) {
		{ $_ -eq "libmp3lame" -or $_ -eq "mp3" } { $format_files_out = "mp3";  $set_audio_codec = "-c:a libmp3lame"; break }
		"aac"                                    { $format_files_out = "m4a";  $set_audio_codec = "-c:a aac"; break }
		{ $_ -eq "libopus" -or $_ -eq "opus" }   { $format_files_out = "opus"; $set_audio_codec = "-c:a libopus"; break }
		"flac"                                   { $format_files_out = "flac"; $set_audio_codec = "-c:a flac"; break }
		{ $_ -eq "libvorbis" -or $_ -eq "vorbis" } { $format_files_out = "ogg"; $set_audio_codec = "-c:a libvorbis"; break }
		default                                  { $format_files_out = "mp3";  $set_audio_codec = "-c:a libmp3lame" }
	}
	$video_settings_args = @("-vn")
} else {
	# D3. Выходной контейнер.
	#
	# Расширение выхода и имя muxer'а — РАЗНЫЕ вещи, и ffmpeg выводит muxer из
	# расширения. Для части привычных расширений такого muxer'а нет вовсе:
	# `container = +m4v` даёт сырой elementary-stream (файл, который не откроет ни
	# один плеер), `.mpg` и `.wmv` — не те муксеры, `.mts/.m2ts` — не находятся.
	# Отображаем известные случаи и говорим об этом вслух: молча отдать
	# неоткрываемый файл хуже, чем сменить расширение с объяснением.
	if ($output_container_status -eq "+") {
		$format_files_out = $output_container_value
		switch -Regex ($format_files_out) {
			'^m4v$'      { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] [video] container = m4v: ffmpeg выберет по расширению raw-muxer вместо MP4. Использую mp4."; $format_files_out = "mp4" }
			'^mpg$'      { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] [video] container = mpg: корректное имя контейнера — mpeg. Использую mpeg."; $format_files_out = "mpeg" }
			'^wmv$'      { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] [video] container = wmv: контейнер называется asf. Использую asf."; $format_files_out = "asf" }
			'^(mts|m2ts)$' { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] [video] container = $($format_files_out): контейнер называется mpegts. Использую mpegts."; $format_files_out = "mpegts" }
		}
	} else {
		$format_files_out = "mp4"
	}

	# E5. Сборка цепочки видео-фильтров
	# rotation+GPU: CUDA-варианта фильтра поворота не существует. Если включён поворот
	# и используется GPU — вся цепочка фильтров переводится на CPU (transpose+scale),
	# иначе получилась бы несовместимая смесь CPU transpose + scale_cuda/scale_qsv.
	# force_cpu: поворот (нет CUDA-transpose) ИЛИ keep_aspect+разрешение (scale_cuda/qsv не умеют
	# pad hw-кадры → иная геометрия без letterbox). Тогда scale идёт через CPU (паритет с .sh).
	$force_cpu_filters = ($use_hw_accel -and (($video_rotation_status -eq "+") -or ($keep_aspect_ratio_status -eq "+" -and $keep_aspect_ratio_value -eq "yes" -and $set_video_resolution)))
	$scale_backend = if ($force_cpu_filters) { "cpu" } else { $hw_accel_type }

	# Поворот
	if ($video_rotation_status -eq "+") {
		$vf_parts += "transpose=$video_rotation_value"
	}

	# D4. Масштабирование с сохранением пропорций
	if ($set_video_resolution) {
		$res_w, $res_h = $set_video_resolution -split 'x'
		if ($keep_aspect_ratio_status -eq "+" -and $keep_aspect_ratio_value -eq "yes") {
			switch ($scale_backend) {
				"nvidia" { $vf_parts += "scale_cuda=${res_w}:${res_h}:force_original_aspect_ratio=decrease" }
				"intel"  { $vf_parts += "scale_qsv=${res_w}:${res_h}:force_original_aspect_ratio=decrease" }
				# force_divisible_by=2 обязателен: на нестандартных пропорциях
				# force_original_aspect_ratio=decrease даёт нечётную сторону
				# (1366×768 в рамку 1280×720 → 1280×719), а yuv420p-энкодеры такие
				# кадры не принимают — «height not divisible by 2», файл падает.
				default  { $vf_parts += "scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" }
			}
		} else {
			switch ($scale_backend) {
				"nvidia" { $vf_parts += "scale_cuda=${res_w}:${res_h}" }
				"intel"  { $vf_parts += "scale_qsv=${res_w}:${res_h}" }
				default  { $vf_parts += "scale=${res_w}:${res_h}" }
			}
		}
	}

	# D6. Скорость воспроизведения (видео)
	if ($playback_speed_status -eq "+" -and $playback_speed_value -ne "1.0") {
		$vf_parts += "setpts=PTS/$playback_speed_value"
	}

	# Hwdownload если нужен
	if ($use_hw_accel -and $vf_parts.Count -gt 0) {
		$needs_download = $vf_parts | Where-Object { $_ -notmatch '^(scale_cuda|scale_qsv|setpts)' }
		if ($needs_download) {
			$vf_parts = @("hwdownload", "format=nv12") + $vf_parts
		}
	}

	# Формирование codec-строки
	$set_video_codec_arg = if ($set_video_codec) { "-c:v $set_video_codec" } else { "" }

	# Настройки GPU-кодека (NVENC / QSV)
	$gpu_args = @()
	if ($use_hw_accel) {
		if ($gpu_preset_status -eq "+") { $gpu_args += @("-preset", $gpu_preset_value) }
		if ($hw_accel_type -eq "nvidia") {
			if ($gpu_tune_status -eq "+") { $gpu_args += @("-tune", $gpu_tune_value) }
			if ($gpu_rc_status -eq "+") { $gpu_args += @("-rc", $gpu_rc_value) }
		}
	}

	# Флаг качества по РЕШЁННОМУ энкодеру, а не по use_hw_accel: nvenc/qsv отвергают -crf.
	# При codec=*_nvenc/*_qsv с выключенным hw_accel всё равно нужен -cq/-global_quality.
	$crf_args = @()
	if ($video_quality_status -eq "+") {
		$crf_args = switch -Regex ($set_video_codec) {
			'_nvenc$' { @("-cq", $video_quality_value); break }
			'_qsv$'   { @("-global_quality", $video_quality_value); break }
			# AMF не имеет одиночного -qp: constant-quality = режим cqp + -qp_i/-qp_p/-qp_b.
			# Прежний общий `-qp N` ffmpeg отвергал — каждый AMF-файл падал.
			'_amf$'   { @("-rc", "cqp", "-qp_i", $video_quality_value, "-qp_p", $video_quality_value, "-qp_b", $video_quality_value); break }
			default   { @("-crf", $video_quality_value) }
		}
	}

	# Имя muxer для -f: mkv/ts — это расширения файла, а не имена форматов ffmpeg.
	# Расширение выходного файла не меняется, только аргумент -f.
	$muxer_out = switch ($format_files_out) { "mkv" { "matroska" } "ts" { "mpegts" } default { $format_files_out } }
	$video_settings_args = @("-f", $muxer_out)
	if ($set_video_codec_arg) { $video_settings_args += $set_video_codec_arg -split ' ' }
	if ($set_video_number_frames) { $video_settings_args += $set_video_number_frames -split ' ' }
	$video_settings_args += $gpu_args
	$video_settings_args += $crf_args
}

# D6. Скорость воспроизведения (аудио)
$af_parts = @()
if ($playback_speed_status -eq "+" -and $playback_speed_value -ne "1.0") {
	# F15. Предпусковая валидация: каскад ниже делит remaining на 2.0 (или 0.5), поэтому
	# 0 остаётся нулём, а отрицательное уходит в минус — цикл не сходится и скрипт
	# зависает молча, ещё до первого файла. Допустим только конечный 0 < speed <= 100
	# (верхняя граница — предел одного звена atempo).
	$speed = 0.0
	$_speedOk = [double]::TryParse(
		$playback_speed_value,
		[System.Globalization.NumberStyles]::Float,
		[System.Globalization.CultureInfo]::InvariantCulture,
		[ref]$speed)
	if (-not $_speedOk -or [double]::IsNaN($speed) -or [double]::IsInfinity($speed) -or $speed -le 0 -or $speed -gt 100) {
		Write-Host ""
		Write-Host "[ОШИБКА] playback_speed должен быть числом в диапазоне 0 < speed <= 100 (получено: '$playback_speed_value')"
		Write-Host ""
		exit 1
	}
	if ($speed -gt 2.0) {
		$remaining = $speed
		while ($remaining -gt 2.0) {
			$af_parts += "atempo=2.0"
			$remaining = $remaining / 2.0
		}
		$af_parts += "atempo=" + $remaining.ToString([System.Globalization.CultureInfo]::InvariantCulture)
	} elseif ($speed -lt 0.5) {
		$remaining = $speed
		while ($remaining -lt 0.5) {
			$af_parts += "atempo=0.5"
			$remaining = $remaining / 0.5
		}
		$af_parts += "atempo=" + $remaining.ToString([System.Globalization.CultureInfo]::InvariantCulture)
	} else {
		$af_parts += "atempo=" + $speed.ToString([System.Globalization.CultureInfo]::InvariantCulture)
	}
}

# D5. Нормализация звука
if ($audio_normalize_status -eq "+") {
	switch ($audio_normalize_value) {
		"loudnorm"   { $af_parts += "loudnorm=I=-16:TP=-1.5:LRA=11" }
		"dynaudnorm" { $af_parts += "dynaudnorm" }
	}
}

# --- Аудио-настройки в массив ---
$audio_settings_args = @()
if ($set_audio_codec) { $audio_settings_args += $set_audio_codec -split ' ' }
if ($set_audio_number_channels) { $audio_settings_args += $set_audio_number_channels -split ' ' }
if ($set_audio_bitrate) { $audio_settings_args += $set_audio_bitrate -split ' ' }
if ($set_audio_sampling_rate) { $audio_settings_args += $set_audio_sampling_rate -split ' ' }

$thread_args = @("-threads", $threads)

# --- F8. Кодек субтитров для режима meta зависит от контейнера ---
# mov_text живёт только в mp4/mov; mkv → srt, webm → webvtt. Раньше всегда ставился
# mov_text и ронял mkv/webm-выход. Для прочих контейнеров — mov_text (best-effort).
$sub_meta_codec = switch ($format_files_out) { "mkv" { "srt" } "webm" { "webvtt" } default { "mov_text" } }

# --- Подпись настроек для manifest ---
# Manifest обязан устаревать при смене ЛЮБОЙ настройки, определяющей содержимое выхода.
# Иначе прогон с другим контейнером/кодеком/фильтрами увидит «complete» от прошлого
# прогона и пропустит файл, так и не создав запрошенный результат. Число потоков и
# overwrite сюда не входят: они влияют на то, КАК считается выход, а не на то, каким он
# получится. Порядок и состав полей — паритет с SH; побайтового совпадения строки между
# платформами не требуется: чужая подпись просто не совпадёт и вызовет перекодирование —
# безопасное направление ошибки (лишняя работа, а не пропуск незаконченного файла).
# [video] bitrate входит в подпись ОТДЕЛЬНО: он собирается per-file (потолок по
# исходному битрейту), поэтому в $video_settings_args его нет. Без него смена
# `bitrate = +3000` на `+1500` не устаревала manifest, и весь пакет отвечал
# «Обработано: 0, Пропущено: N» без единого вызова ffmpeg.
$settings_sig = @(
	($video_settings_args -join ' '), ($audio_settings_args -join ' '),
	($vf_parts -join ','), ($af_parts -join ','),
	$format_files_out, $sub_meta_codec, $video_subtitles, $subtitles_style,
	$start_coding, $length_coding, $split_by_silence, $video_bitrate
) -join '|'
# При split_by_silence=yes границы частей задаются порогом/длительностью тишины: их смена
# меняет содержимое выходов, поэтому они обязаны обесценивать manifest. Вне режима split
# на выход не влияют — в подпись не добавляем (паритет с SH/CMD).
if ($split_by_silence -eq "yes") {
	$settings_sig = "$settings_sig|sil=$silence_threshold,$silence_duration"
}

# --- F8. Предпусковая проверка совместимости контейнера и кодеков ---
# Несовместимую пару (напр. webm + libx264/aac) отклоняем ДО пакета с понятной причиной.
if ($audio_only -ne "yes" -and $copy_codecs -ne "yes" -and $merge_files -ne "yes" -and $create_frame -ne "yes" -and $extract_audio_copy -ne "yes") {
	$_incompat = @()
	if ($format_files_out -eq "webm") {
		# Набор закреплён с обоих концов: без хвостового якоря `libvpxJUNK` и `vp9foo`
		# проходили бы как валидные. `av1*` — осознанный префикс (av1_nvenc/av1_qsv),
		# паритет с glob'ом `av1*` в SH.
		if ($set_video_codec -and $set_video_codec -notmatch '^(libvpx|libvpx-vp9|vp8|vp9|libsvtav1|libaom-av1)$' -and $set_video_codec -notmatch '^av1') {
			$_incompat += "  • WebM не поддерживает видеокодек '$set_video_codec' — нужен VP8/VP9/AV1 (смените [video] codec или [video] container)."
		}
		# Смотрим на РЕАЛЬНО сформированный аргумент, а не на значение из конфига: при
		# `codec = -aac` статус '-' и `-c:a` в ffmpeg не передаётся вовсе — контейнер
		# выберет дефолт сам, отклонять такую конфигурацию не за что.
		$_effAudioCodec = $set_audio_codec -replace '^-c:a\s+', ''
		if ($_effAudioCodec -and $_effAudioCodec.ToLower() -notmatch '^(libopus|opus|libvorbis|vorbis)$') {
			$_incompat += "  • WebM не поддерживает аудиокодек '$_effAudioCodec' — нужен Opus/Vorbis (смените [audio] codec или [video] container)."
		}
	}
	if ($_incompat.Count -gt 0) {
		Write-Host "`n[ОШИБКА] Несовместимая комбинация контейнера и кодеков:`n$($_incompat -join "`n")`n"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
}

# --- Формат входных файлов ---
# F1. Позиционный -Path глоббит: корень с [ ] ? * превращается в маску и обход даёт 0 файлов
# (батч «успешно» завершается вхолостую). -LiteralPath отключает глоббинг, но при этом МОЛЧА
# игнорирует -Include — поэтому фильтр по расширению перенесён в Where-Object. -File заодно
# отсекает каталоги вида "season.mp4", которые старый -Include пропускал в Encode-File.
$_in_exts = @($format_files_in -split "," | ForEach-Object { "." + $_.Trim().TrimStart('.') } | Where-Object { $_ -ne "." })
# `.ffconv-partial-*` — недобитые temp-файлы прерванного прогона: они подпадают под
# фильтр расширений и в in-place режиме (destination == source) становились входами
# следующего запуска. Паритет с `! -name '.ffconv-partial-*'` в SH.
# -Force обязателен: без него Get-ChildItem пропускает скрытые и системные файлы и
# каталоги, а `find` в .sh и `for /r` в .cmd их обходят. Один и тот же каталог давал
# разный набор входов на разных платформах — молча, без единой строки в сводке.
$format_files_in_list = Get-ChildItem -LiteralPath $folder_sources -Recurse -File -Force |
	Where-Object { $_in_exts -contains $_.Extension -and -not $_.Name.StartsWith('.ffconv-partial-') }

# F-collision. Если каталог назначения лежит СТРОГО ВНУТРИ источника, рекурсивный обход
# подхватывает уже сконвертированные выходы и гонит их по кругу (или перекодирует поверх).
# Исключаем файлы под dest. GetFullPath канонизирует ../ и различия форм пути; сравнение
# регистронезависимое (Windows). dest == source (in-place) вложенностью НЕ считается —
# там файлы это источники, а коллизию «выход==вход» снимает пофайловая проверка ниже.
$_sep = [System.IO.Path]::DirectorySeparatorChar
$canon_sources     = [System.IO.Path]::GetFullPath($folder_sources).TrimEnd('\','/')
$canon_destination = [System.IO.Path]::GetFullPath($folder_destination).TrimEnd('\','/')
$dest_inside_source = $canon_destination.StartsWith($canon_sources + $_sep, [System.StringComparison]::OrdinalIgnoreCase)
if ($dest_inside_source) {
	$format_files_in_list = $format_files_in_list | Where-Object {
		-not ([System.IO.Path]::GetFullPath($_.FullName)).StartsWith($canon_destination + $_sep, [System.StringComparison]::OrdinalIgnoreCase)
	}
}

# --- GUI-прогресс (переменная из Runspace или env) ---
if (-not $guiProgressFile) { $guiProgressFile = $env:FFMPEG_GUI_PROGRESS_FILE }
if (-not $guiCancelFile)   { $guiCancelFile   = $env:FFMPEG_GUI_CANCEL_FILE }

# --- J2. Счётчики ---
$script:totalFiles  = ($format_files_in_list | Measure-Object).Count
$script:fileNum     = 0
$script:countOk     = 0
$script:countFail   = 0
$script:countSkip   = 0
$script:totalInBytes  = 0
$script:totalOutBytes = 0
$script:startTimeAll  = Get-Date

# --- Канонизация пути для сравнения input/output ---
# GetFullPath разворачивает '..' и приводит разделители; файл существовать не обязан.
function Get-CanonPath {
	param([string]$Path)
	try { return [System.IO.Path]::GetFullPath($Path) } catch { return $Path }
}

function Get-FileSize {
	param([string]$Path)
	try { return (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch { return 0 }
}

# --- Относительный путь подпапки источника (с ведущим и хвостовым разделителем) ---
# Обе стороны канонизируем: прежнее regex-вычитание сырой строки $folder_sources
# совпадало только при побайтово совпадающей форме пути. `source = C:/video/in` в SH
# работал, а в PS1 $file.DirectoryName отдаёт 'C:\video\in\sub', вычитание не
# срабатывало и путь выхода становился мусором ('C:/video/out' + 'C:\video\in\sub\').
# Формула одна на Encode-File и на карту коллизий — иначе карта врёт.
function Get-RelDir {
	param([string]$Dir)
	$canonDir = Get-CanonPath $Dir
	if ($canonDir.Length -gt $canon_sources.Length -and
	    $canonDir.StartsWith([string]$canon_sources + [string]$_sep, [System.StringComparison]::OrdinalIgnoreCase)) {
		return $canonDir.Substring($canon_sources.Length) + [string]$_sep
	}
	return [string]$_sep
}

# --- Транзакционная запись: имя временного файла ---
# Временное имя строится ПРЕФИКСОМ, а не суффиксом, потому что расширение обязано
# сохраниться: без -f ffmpeg выводит muxer из расширения, а режимы copy_codecs и
# merge как раз идут с `-c copy` без -f. Суффиксное `.movie.mp4.partial` давало
# "Error initializing the muxer ... Invalid argument" на настоящем ffmpeg.
function Get-PartialPath {
	param([string]$Path)
	$dir = Split-Path $Path -Parent
	$leaf = Split-Path $Path -Leaf
	return (Join-Path $dir ".ffconv-partial-$leaf")
}

# Прогресс отправки в GUI. Объявлено ДО дот-сорса модуля намеренно: модуль
# определяет свою версию (Write-Progress) под guard'ом «функции ещё нет», и
# Write-Progress из фонового runspace до формы не доходит — фаза отправки в GUI
# оставалась без индикатора вовсе, хотя на файле в 3 ГБ это и есть долгая часть.
# Комментарий в модуле обещал это переопределение, а его не существовало.
function Write-RemoteUploadProgress {
	param([int64]$Done, [int64]$Total)
	if ($Total -le 0) { return }
	$pct = [int]($Done * 100 / $Total)
	if ($guiProgressFile) {
		Write-GUIProgress -FilePercent $pct -CurrentFile $script:_remoteUploadName -Phase 'отправка'
	} else {
		Write-Progress -Activity "Отправка на сервер" -PercentComplete $pct
	}
}

# Удалённый бэкенд — отдельный модуль: только объявляет функции, ничего не делает сам.
#
# $PSScriptRoot здесь НЕ работает и не может: GUI подаёт этот файл строкой через
# PowerShell.AddScript(), а у строкового скрипта автоматическая $PSScriptRoot равна
# пустой строке И ПЕРЕКРЫВАЕТ значение, выставленное через SessionStateProxy. Join-Path
# на пустой строке бросает «Cannot bind argument to parameter 'Path'», top-level trap
# делает break — воркер умирал до первого файла, и так вело себя ВСЁ, что запускалось из
# GUI и из EXE. Каталог приходит отдельной переменной $guiAppDir, которую AddScript не
# трогает. В EXE функции модуля вклеены в ту же строку (build_exe.ps1) — тогда искать
# файл не нужно вовсе, и проверка по объявленной функции надёжнее проверки пути.
if (-not (Get-Command Set-RemoteActive -ErrorAction SilentlyContinue)) {
	$_appRoot = if ($guiAppDir) { $guiAppDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
	$_remoteModule = Join-Path $_appRoot 'remote_client.ps1'
	if (Test-Path -LiteralPath $_remoteModule) { . $_remoteModule }
}

# --- Откат на локальный ffmpeg: только по ключу и только шумно ---
# Отказ от МОЛЧАЛИВОГО отката остаётся в силе и обоснован: тихий переход на
# процессор на двухстах файлах неотличим от зависания. Но между «тихо считать
# локально» и «бросить остаток пакета, если служба легла на сотом файле» есть
# третье поведение, и выбирает его пользователь, а не мы за него.
#
# Умолчание [remote] on_failure = abort — прежнее поведение до буквы. При
# on_failure = local каждый откат печатает причину, попадает в отдельный счётчик
# сводки и делает код возврата ненулевым.
$script:countLocalFallback = 0
# Проверку отмены отдаём модулю: длинные фазы (отправка гигабайтов, скачивание
# результата) шли до конца, сколько бы раз пользователь ни нажал «Остановить».
$script:RemoteCancelCheck = { [bool]($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) }

function Test-RemoteFallbackAllowed {
	param([string]$Name, [string]$Reason)
	if ($remote_on_failure -ne 'local') { return $false }
	# Отмена пользователем (Stop) — не «служба недоступна»: считать файл локально
	# после явной остановки значит проигнорировать саму остановку.
	if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
		Log-Msg "WARN" "${Name}: $Reason, но прогон остановлен — локально не считаем"
		return $false
	}
	# Отмена пользователем (Stop) — не «служба недоступна»: считать файл локально
	# после явной остановки значит проигнорировать саму остановку.
	if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
		Log-Msg "WARN" "${Name}: $Reason, но прогон остановлен — локально не считаем"
		return $false
	}
	# Тонкий клиент без ffmpeg откатываться некуда — честнее сказать это вслух.
	if (-not $ffmpeg_available) {
		Log-Msg "WARN" "${Name}: $Reason, а локального ffmpeg нет — откат невозможен"
		return $false
	}
	Write-Host "[ПРЕДУПРЕЖДЕНИЕ] ${Name}: $Reason — считаем локально (on_failure = local)."
	Log-Msg "WARN" "${Name}: $Reason — откат на локальный ffmpeg"
	$script:countLocalFallback++
	return $true
}

# --- Публикация результата: общая для локального и удалённого путей ---
# Логика обязана существовать в одном экземпляре: разойдись она между путями,
# «успех» значил бы разное, и сводка ok/fail перестала бы что-либо значить.
#
# $Verify есть только у удалённого пути и именно поэтому необязателен: размер и
# читаемость проверяются у СКАЧАННОГО файла. Локальный ffmpeg с rc=0 нулевого
# файла не оставляет, а оборванная загрузка — запросто; включать же проверку и
# локально значило бы декодировать каждый выход вторым проходом целиком.
function Publish-EncodedResult {
	param($File, [string]$Tmp, [string]$Destination, $StartTime, [bool]$Verify = $false)
	$elapsed = (Get-Date) - $StartTime
	$elapsedStr = "{0}m {1}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

	if ($Verify) {
		$valid = $false
		if ((Test-Path -LiteralPath $Tmp) -and (Get-Item -LiteralPath $Tmp).Length -gt 0) {
			# Без локального ffmpeg декодировать нечем: остаётся проверка на
			# непустой файл (она уже прошла выше). Пропускать её молча нельзя —
			# оборванная загрузка выглядела бы успехом.
			if ((Get-Command Receive-RemoteResult -ErrorAction SilentlyContinue) -and
			    $script:RemoteResultVerified -eq 'yes') {
				# Служба назвала размер результата, и скачанное с ним сошлось — это
				# ответ на тот же вопрос, что `-f null -`, но почти бесплатно.
				# Второй полный декод трёхгигабайтного выхода стоил бы минут НА ФАЙЛ,
				# и именно поэтому проверка содержимого включена только на удалённом
				# пути. Паритет с publish_result в .sh.
				$valid = $true
			} elseif (-not $ffmpeg_available) {
				Log-Msg "WARN" "$($File.Name): без локального ffmpeg результат проверен только по размеру"
				$valid = $true
			} else {
				& $ffmpeg -nostdin -v error -i $Tmp -f null - 2>$null | Out-Null
				$valid = ($LASTEXITCODE -eq 0)
			}
		}
		if (-not $valid) {
			Log-Msg "FAIL" "$($File.Name): результат не прошёл проверку"
			if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
			$script:anyFail = $true; $script:countFail++
			Write-GUIProgress -FilePercent 0 -CurrentFile $File.Name
			return $false
		}
	}

	# F-rename. Публикацию подтверждаем: Move-Item -ErrorAction Stop И наличие
	# файла-цели. Без -ErrorAction Stop сбой rename нетерминирующий — результат
	# засчитался бы как OK, а manifest записался бы поверх отсутствующего файла.
	try {
		Move-Item -LiteralPath $Tmp -Destination $Destination -Force -ErrorAction Stop
	} catch {
		Log-Msg "FAIL" "$($File.Name): не удалось опубликовать результат (rename): $_"
		if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
		$script:anyFail = $true; $script:countFail++
		Write-GUIProgress -FilePercent 0 -CurrentFile $File.Name
		return $false
	}
	if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
		Log-Msg "FAIL" "$($File.Name): результат не появился по целевому пути"
		$script:anyFail = $true; $script:countFail++
		return $false
	}

	Log-Msg "OK" "$($File.Name) -> $(Split-Path $Destination -Leaf) ($elapsedStr)"
	$script:countOk++
	$script:produced += $Destination
	# F29. Вход — только с первой удавшейся части.
	try {
		if (-not $script:inReported) { $script:totalInBytes += $File.Length; $script:inReported = $true }
		$script:totalOutBytes += (Get-Item -LiteralPath $Destination).Length
	} catch {}
	Write-GUIProgress -FilePercent 100 -CurrentFile $File.Name
	return $true
}

# --- Manifest готовности: input → outputs → completion state ---
# Построчный формат (не JSON: CMD его не разберёт), одинаковый на трёх платформах:
#   # ffconv-manifest v1
#   source=<путь>
#   source_size=<байты>
#   settings=<подпись>
#   output=<байты>|<путь>      ← размер первым: путь может содержать '|'
#   state=complete
# `state=complete` пишется последней строкой и только после успеха ВСЕХ частей,
# поэтому оборванная запись не может выдать себя за готовый результат.
# Сверяем размеры, а не хеши: чтение гигабайтов ради контрольной суммы стоило бы
# сопоставимо с самим перекодированием, а размер ловит обрыв и подмену источника.
function Write-Manifest {
	param([string]$ManifestPath, [string]$Source, [string]$Signature, [string[]]$Outputs)
	$lines = @("# ffconv-manifest v1", "source=$Source", "source_size=$(Get-FileSize $Source)", "settings=$Signature")
	foreach ($o in $Outputs) { $lines += "output=$(Get-FileSize $o)|$o" }
	$lines += "state=complete"
	$tmp = "$ManifestPath.tmp"
	try {
		[System.IO.File]::WriteAllLines($tmp, $lines)
		Move-Item -LiteralPath $tmp -Destination $ManifestPath -Force
	} catch {}
}

function Test-ManifestComplete {
	param([string]$ManifestPath, [string]$Source, [string]$Signature)
	if (!(Test-Path -LiteralPath $ManifestPath)) { return $false }
	try { $lines = [System.IO.File]::ReadAllLines($ManifestPath) } catch { return $false }
	if ($lines -notcontains "state=complete") { return $false }
	$recSize = ($lines | Where-Object { $_ -like "source_size=*" } | Select-Object -First 1)
	if ($null -eq $recSize -or $recSize.Substring(12) -ne [string](Get-FileSize $Source)) { return $false }
	# Подпись настроек: смена контейнера/кодека/фильтров обязана обесценить manifest.
	$recSig = ($lines | Where-Object { $_ -like "settings=*" } | Select-Object -First 1)
	if ($null -eq $recSig -or $recSig.Substring(9) -ne $Signature) { return $false }
	foreach ($l in ($lines | Where-Object { $_ -like "output=*" })) {
		$rest = $l.Substring(7)
		$sep = $rest.IndexOf('|')
		if ($sep -lt 0) { return $false }
		$sz = $rest.Substring(0, $sep); $p = $rest.Substring($sep + 1)
		if (!(Test-Path -LiteralPath $p)) { return $false }
		if ([string](Get-FileSize $p) -ne $sz) { return $false }
	}
	return $true
}

# --- D8. Логирование ---
function Log-Msg {
	param([string]$Level, [string]$Msg)
	$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
	$logLine = "[$timestamp] [$Level] $Msg"
	Write-Host $logLine
	if ($enable_log -eq "yes" -and $log_file) {
		# -Encoding UTF8 обязателен: без него Add-Content пишет в ANSI-кодировке системы,
		# и один и тот же лог, дописанный из .sh и из .ps1, читается наполовину.
		Add-Content -LiteralPath $log_file -Value $logLine -Encoding UTF8
	}
}

# --- Запись GUI-прогресса ---
function Write-GUIProgress {
	# F17. state/exitCode/message — контракт с GUI. Раньше воркер писал финальное
	# «Готово» независимо от countFail, а `exit 1` не создаёт ErrorRecord, поэтому GUI
	# не мог отличить успешный батч от провального и показывал «Готово» после ошибок.
	# $Phase — подпись фазы удалённого пути (отправка → очередь/ожидание карты →
	# кодирование → скачивание). Локальный путь состоит из одной фазы и подписи
	# не ставит; удалённый без неё показывал «ничего не происходит» минутами,
	# что неотличимо от зависания.
	param([int]$FilePercent = 0, [string]$CurrentFile = "", [string]$Command = "",
	      [ValidateSet("running","success","failed","cancelled")][string]$State = "running",
	      [int]$ExitCode = -1, [string]$Message = "", [string]$Phase = "")
	if (-not $guiProgressFile) { return }
	if ($Command) { $script:_lastCommand = $Command }
	$totalPct = if ($script:totalFiles -gt 0) { [int](($script:fileNum - 1 + $FilePercent / 100) * 100 / $script:totalFiles) } else { 0 }
	$data = [ordered]@{
		state        = $State
		exitCode     = $ExitCode
		message      = $Message
		filePercent  = $FilePercent
		totalPercent = $totalPct
		fileNum      = $script:fileNum
		totalFiles   = $script:totalFiles
		currentFile  = if ($CurrentFile) { $CurrentFile } else { "" }
		phase        = $Phase
		ok           = $script:countOk
		fail         = $script:countFail
		skip         = $script:countSkip
		command      = if ($script:_lastCommand) { $script:_lastCommand } else { "" }
		pid          = 0
	}
	# Пишем в соседний temp и подменяем целиком: GUI читает этот файл таймером каждые
	# 400 мс, и при прямой записи он регулярно попадал на полузаписанный JSON —
	# ConvertFrom-Json падал в пустой catch, а прогресс замирал до следующего тика.
	# Замена файла целиком означает, что читатель видит либо старую версию, либо новую.
	# Путь резервной копии обязателен: PowerShell превращает $null в пустую строку, и
	# трёхаргументный Replace падает с «The path is not of a legal form» — прогресс
	# замирал бы на первой же записи. Копию сразу удаляем, она нужна только API.
	# Replace/Move конкурируют с ReadAllText из таймера GUI (400 мс): если тик
	# открыл файл ровно в этот момент, вызов бросает IOException. Одиночная
	# попытка в пустом catch означала потерянную запись — и если терялась
	# ПОСЛЕДНЯЯ, успешный батч показывался как «Ошибка (state='running')».
	# Три коротких повтора закрывают гонку, не удорожая обычный путь.
	for ($_try = 1; $_try -le 3; $_try++) {
		try {
			$_tmp = "$guiProgressFile.tmp"
			[System.IO.File]::WriteAllText($_tmp, ($data | ConvertTo-Json))
			if ([System.IO.File]::Exists($guiProgressFile)) {
				$_bak = "$guiProgressFile.bak"
				[System.IO.File]::Replace($_tmp, $guiProgressFile, $_bak)
				[System.IO.File]::Delete($_bak)
			} else {
				[System.IO.File]::Move($_tmp, $guiProgressFile)
			}
			break
		} catch {
			if ($_try -lt 3) { Start-Sleep -Milliseconds 40 }
		}
	}
}

# --- A5. Функция кодирования одного файла (аргументы через массив, не Split) ---
# F-collision-map. Два РАЗНЫХ входа могут претендовать на ОДИН выход: при
# save_old_extension=no имена movie.avi и movie.mp4 оба дают movie.mp4. Раньше это
# обнаруживалось только по факту — второй файл молча затирал результат первого, и
# пользователь терял данные, не увидев ни одного сообщения. Считаем карту выходов ДО
# кодирования и помечаем всю конфликтующую группу как FAIL (тот же контракт, что и у
# F12 «выход == вход»: файл не обрабатывается, ошибка видна в сводке).
#
# Блок стоит ПОСЛЕ определений Get-CanonPath/Log-Msg: скрипт исполняется сверху вниз,
# выше эти функции ещё не существуют.
#
# Режимы merge (один выход), extract (расширение известно только после probe каждого
# файла) и frame (выход — каталог) сюда не попадают: там формула выхода другая.
$collision_outputs = @{}
if ($merge_files -ne "yes" -and $extract_audio_copy -ne "yes" -and $create_frame -ne "yes") {
	$_cmap = @{}
	foreach ($_f in $format_files_in_list) {
		# Формула обязана совпадать с Encode-File, иначе карта врёт.
		$_dir = Get-RelDir $_f.DirectoryName
		$_name = if ($save_old_extension -eq "yes") { $_f.Name } else { $_f.BaseName }
		$_fmt = if ($copy_codecs -eq "yes") { $_f.Extension.TrimStart('.') } else { $format_files_out }
		$_out = (Get-CanonPath "$folder_destination$_dir$_name$part_suffix_known.$_fmt").ToLowerInvariant()
		if (-not $_cmap.ContainsKey($_out)) { $_cmap[$_out] = @() }
		$_cmap[$_out] += $_f.FullName
	}
	foreach ($_k in $_cmap.Keys) {
		if ($_cmap[$_k].Count -gt 1) {
			$collision_outputs[$_k] = $true
			Log-Msg "FAIL" "Конфликт выходов: на «$_k» претендуют несколько входов — все пропущены (включите save_old_extension=yes либо разнесите файлы):"
			foreach ($_in in $_cmap[$_k]) { Write-Host "    $_in" }
		}
	}
}

function Encode-File {
	param([System.IO.FileInfo]$file)

	$full_path = $file.FullName
	# F32. Два РАЗНЫХ имени, их нельзя смешивать:
	#   $input_stem — имя источника без расширения; по нему ищутся sidecar-субтитры;
	#   $file_name  — базовое имя ВЫХОДА (при save_old_extension=yes несёт расширение
	#                 источника, чтобы movie.avi -> movie.avi.mp4).
	# Раньше переменная была одна: при save_old_extension=yes она становилась
	# "movie.mp4", и sidecar искался как "movie.mp4.srt" вместо "movie.srt" —
	# burn/meta молча пропускались.
	$input_stem = $file.BaseName
	$file_name = $input_stem
	if ($save_old_extension -eq "yes") { $file_name = $file.Name }
	$file_path = Get-RelDir $file.DirectoryName
	# D7. Dry-run только печатает команды — каталоги зеркала не создаём. Иначе
	# «безопасный» прогон оставлял дерево пустых подпапок в destination (и маскировал
	# ошибки в самом пути: пользователь видел созданный каталог и считал путь верным).
	if ($dry_run -ne "yes") { New-DirLiteral "$folder_destination$file_path" }

	$script:fileNum++

	# Проверка отмены из GUI
	if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
		return
	}

	# --- I. Извлечение аудио без перекодирования ---
	if ($extract_audio_copy -eq "yes") {
		$audioLine = (& $ffmpeg -i $full_path 2>&1 | Out-String) -split "`n" | Where-Object { $_ -match 'Audio:' } | Select-Object -First 1
		$codec = if ($audioLine -match 'Audio:\s+(\w+)') { $Matches[1] } else { '' }
		$ext = switch -Regex ($codec) {
			'^aac$'    { 'm4a'  }
			'^mp3$'    { 'mp3'  }
			'^opus$'   { 'opus' }
			'^vorbis$' { 'ogg'  }
			'^flac$'   { 'flac' }
			'^pcm_'    { 'wav'  }
			default    { 'mka'  }
		}
		$outAudio = "$folder_destination$file_path$file_name.$ext"
		# F12 для extract. Расширение выхода выбирается по кодеку ИСХОДНИКА, поэтому при
		# in-place (destination == source) вход song.m4a/song.mp3/song.ogg/song.flac даёт
		# выход, равный входу, и overwrite_existing=yes удалял его ДО запуска ffmpeg —
		# исходник терялся безвозвратно. Проверка стоит ДО overwrite-блока.
		if ((Get-CanonPath $outAudio) -ieq (Get-CanonPath $full_path)) {
			Log-Msg "FAIL" "$($file.Name): выход совпадает с входом (извлечение аудио в тот же файл)"
			$script:countFail++
			Write-GUIProgress -CurrentFile $file.Name
			return
		}
		# Единый overwrite-контракт: при overwrite_existing=yes перезаписываем готовый файл,
		# а не пропускаем молча (раньше пропуск был безусловным — overwrite не работал).
		# D7. Удаление — мутация; при dry_run её делать нельзя, иначе режим, обещающий лишь
		# показать команду, реально уничтожает данные (ffmpeg -y ниже и так перезапишет).
		if (Test-Path -LiteralPath $outAudio) {
			if ($overwrite_existing -eq "yes") {
				if ($dry_run -ne "yes") { Remove-Item -LiteralPath $outAudio -Force -ErrorAction SilentlyContinue }
			} else {
				$script:countSkip++
				Write-GUIProgress -CurrentFile $file.Name
				return
			}
		}
		# D7. Dry-run: спецрежим тоже только печатает команду, не создаёт файл.
		if ($dry_run -eq "yes") {
			$_cmdStr = "$ffmpeg -hide_banner -strict -2 -i `"$full_path`" -vn -c:a copy `"$outAudio`" -y"
			Write-Host "[DRY-RUN] $_cmdStr"
			Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name -Command $_cmdStr
			return
		}
		Log-Msg "INFO" "Извлечение аудио: $($file.Name)"
		$_cmdStr = "$ffmpeg -hide_banner -strict -2 -i `"$full_path`" -vn -c:a copy `"$outAudio`" -y"
		Write-GUIProgress -FilePercent 0 -CurrentFile $file.Name -Command $_cmdStr
		# 2>&1 в конвейер: в hostless-runspace GUI stderr нативной команды иначе оседает
		# в $ps.Streams.Error, и успешный прогон показывался как «Ошибка» с MessageBox.
		& $ffmpeg -nostdin -hide_banner -strict -2 -i $full_path -vn -c:a copy $outAudio -y 2>&1 | ForEach-Object { Write-Host "$_" }
		if ($LASTEXITCODE -ne 0) {
			Log-Msg "FAIL" "$($file.Name)"
			if (Test-Path -LiteralPath $outAudio) { Remove-Item -LiteralPath $outAudio -Force }
			$script:countFail++
		} else {
			Log-Msg "OK" "$($file.Name) -> $(Split-Path $outAudio -Leaf)"
			$script:countOk++
			try { $script:totalInBytes += $file.Length; $script:totalOutBytes += (Get-Item -LiteralPath $outAudio).Length } catch {}
		}
		Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name
		return
	}

	if ($create_frame -eq "yes") {
		$frame_dir = "$folder_destination$file_path$file_name"
		$frame_done = "$frame_dir\.frames_complete"
		# Готовность каталога кадров — по маркеру завершения, а не по факту существования:
		# прерванный прогон оставлял частичный каталог, который молча пропускался.
		if ((Test-Path -LiteralPath $frame_done) -and $overwrite_existing -ne "yes") {
			$script:countSkip++
			Write-GUIProgress -CurrentFile $file.Name
			return
		}
		# F-percent. `%` в имени файла ИЛИ в пути ломает image2-мультиплексор: после `%`
		# он принимает только d/цифру/%. Удваиваем везде, кроме собственного счётчика.
		$frame_out = ($frame_dir -replace '%', '%%') + "\" + ($file_name -replace '%', '%%') + "_%05d.png"
		if ($dry_run -eq "yes") {
			$_cmdStr = "$ffmpeg -hide_banner -strict -2 -i `"$full_path`" -r 1/1 `"$frame_out`""
			Write-Host "[DRY-RUN] $_cmdStr"
			Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name -Command $_cmdStr
			return
		}
		# Частичный каталог с прошлого прогона удаляем, чтобы кадры не смешивались — но
		# ТОЛЬКО если каталог наш. Раньше сносился ЛЮБОЙ существующий каталог с именем
		# стема: при in-place `clip.mp4` рядом с пользовательским каталогом `clip\` тот
		# вычищался без единого сообщения. Признак «наш» — маркер начала или завершения;
		# пустой каталог безопасен.
		$frame_partial = "$frame_dir\.frames_partial"
		if (Test-Path -LiteralPath $frame_dir) {
			if ((Test-Path -LiteralPath $frame_partial) -or (Test-Path -LiteralPath $frame_done)) {
				Remove-Item -LiteralPath $frame_dir -Recurse -Force -ErrorAction SilentlyContinue
			} elseif (@(Get-ChildItem -LiteralPath $frame_dir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
				Log-Msg "FAIL" "$($file.Name): каталог кадров занят посторонними файлами: $frame_dir"
				$script:countFail++
				Write-GUIProgress -CurrentFile $file.Name
				return
			}
		}
		New-DirLiteral $frame_dir
		New-EmptyFileLiteral $frame_partial
		Log-Msg "INFO" "Извлечение кадров: $full_path"
		# 2>&1 в конвейер: в hostless-runspace GUI stderr нативной команды иначе оседает
		# в $ps.Streams.Error, и успешный прогон показывался как «Ошибка» с MessageBox.
		& $ffmpeg -nostdin -hide_banner -strict -2 -i $full_path -r 1/1 $frame_out 2>&1 | ForEach-Object { Write-Host "$_" }
		if ($LASTEXITCODE -ne 0) {
			Log-Msg "FAIL" "$($file.Name)"
			Remove-Item -LiteralPath $frame_dir -Recurse -Force -ErrorAction SilentlyContinue
			$script:countFail++
		} else {
			Remove-Item -LiteralPath $frame_partial -Force -ErrorAction SilentlyContinue
			New-EmptyFileLiteral $frame_done
			Log-Msg "OK" "Кадры: $($file.Name)"
			$script:countOk++
		}
		Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name
		return
	}

	$current_format_out = $format_files_out
	# copy_codecs сохраняет исходный контейнер — расширение выхода берём из источника
	# ДО проверки существования, иначе ищем .mp4 вместо, например, .avi и не находим готовый файл.
	if ($copy_codecs -eq "yes") { $current_format_out = $file.Extension.TrimStart('.') }
	$out_base = "$folder_destination$file_path$file_name"

	# F12. Выход не имеет права совпасть со входом. Проверка стоит ДО всего остального:
	# ниже готовый выход при провале валидации удаляется как «битый», а при in==out
	# этим «битым файлом» оказался бы сам оригинал — ещё до кодирования.
	# Суффикс " (part.N)" коллизию снимает, поэтому заранее известный суффикс
	# ($part_suffix_known — режим [split] start) в сравнение включён. При [split] length
	# число частей зависит от длительности и здесь ещё неизвестно, поэтому сверяем
	# базовое имя — сознательный консерватизм: лучше отклонить файл, чем закодировать
	# его поверх самого себя.
	$canon_out = Get-CanonPath "$out_base$part_suffix_known.$current_format_out"
	if ($canon_out -ieq (Get-CanonPath $full_path)) {
		Log-Msg "FAIL" "$($file.Name): выход совпадает с входом — файл пропущен (задайте другой destination, префикс или формат; при [split] length имя частей заранее неизвестно, поэтому in-place отклоняется)"
		$script:countFail++
		Write-GUIProgress -CurrentFile $file.Name
		return
	}

	# ВАЖЕН ПОРЯДОК: manifest проверяется РАНЬШЕ карты коллизий. При in-place
	# (destination == source) повторный прогон видит и movie.avi, и уже созданный
	# movie.mp4 — оба претендуют на один выход, и карта давала FAIL «конфликт
	# выходов» файлу, который на самом деле давно готов. Готовность старше спора.
	# Готовность подтверждает manifest: state=complete + неизменившийся источник + все
	# перечисленные выходы на месте. Раньше признаком готовности считалось наличие одной
	# лишь `(part.1)` — если остальные части не создались (обрыв, падение, нехватка
	# места), весь input молча пропускался как «уже готовый» и хвост терялся навсегда.
	$manifest = Join-Path "$folder_destination$file_path" ".$file_name.ffconv"
	$file_sig = "$settings_sig|fmt=$current_format_out|copy=$copy_codecs"
	if ($overwrite_existing -ne "yes" -and (Test-ManifestComplete $manifest $full_path $file_sig)) {
		$script:countSkip++
		Write-GUIProgress -CurrentFile $file.Name
		return
	}

	# F-collision-map. Выход этого файла оспаривается другим входом (карта построена
	# до кодирования). Обрабатывать нельзя: кто-то из группы затрёт чужой результат.
	if ($collision_outputs.ContainsKey($canon_out.ToLowerInvariant())) {
		Log-Msg "FAIL" "$($file.Name): конфликт выходов — файл пропущен"
		$script:countFail++
		Write-GUIProgress -CurrentFile $file.Name
		return
	}

	# E3. Проверка валидности существующего файла
	# Судим по exit code (как SH/CMD), а не по тексту stderr: ffmpeg с -v error может
	# вывести не-фатальную диагностику для полностью декодируемого файла — тогда
	# непустой stderr ошибочно удалял бы валидный готовый результат.
	# F7. overwrite_existing=yes → готовый файл не считаем финальным и перекодируем с
	# новыми настройками (ffmpeg -y перезапишет). Иначе валидный файл пропускается.
	if ($overwrite_existing -ne "yes") {
		if (Test-Path -LiteralPath "$out_base$part_suffix_known.$current_format_out") {
			# Без локального ffmpeg (тонкий клиент, [remote] enabled = yes) проверить
			# нечем, и «не прошёл проверку» означало бы УДАЛЕНИЕ готового файла из-за
			# отсутствия инструмента — считаем такой файл готовым. Паритет с .sh.
			if (-not $ffmpeg_available) {
				$script:countSkip++
				Write-GUIProgress -CurrentFile $file.Name
				return
			}
			& $ffmpeg -nostdin -v error -i "$out_base$part_suffix_known.$current_format_out" -f null - 2>&1 | Out-Null
			if ($LASTEXITCODE -eq 0) {
				$script:countSkip++
				Write-GUIProgress -CurrentFile $file.Name
				return
			} elseif ($dry_run -eq "yes") {
				# D7. Dry-run обещает «только показать команды». Удаление битого выхода —
				# мутация, и при холостом прогоне её быть не должно.
				Log-Msg "WARN" "[DRY-RUN] битый файл был бы удалён: $out_base$part_suffix_known.$current_format_out"
			} else {
				Log-Msg "WARN" "Удаление битого файла: $out_base$part_suffix_known.$current_format_out"
				Remove-Item -LiteralPath "$out_base$part_suffix_known.$current_format_out" -Force
			}
		}
	}

	# E4 + J1. Один вызов ffmpeg -i для битрейта и длительности (раньше запускались
	# два отдельных pipeline'а на тот же файл — лишняя задержка для больших библиотек).
	#
	# Склейка строк вручную, а НЕ Out-String: тот переносит вывод по ширине хоста
	# ($Host.UI.RawUI.BufferSize, в hostless-runspace — 80 символов), и строка
	# `Stream #0:0: Video: h264 ..., 4523 kb/s` длиной 150-200 символов рвалась до
	# `kb/s` — регексп F25 не совпадал никогда, битрейт видеопотока не читался,
	# и на каждом файле печаталось ложное предупреждение об откате на битрейт контейнера.
	#
	# Без локального ffmpeg (тонкий клиент) вызывать нечего: CommandNotFoundException —
	# терминирующая и уходит в top-level trap, обрывая весь пакет.
	$ffmpeg_info = ""
	if ($ffmpeg_available) {
		$ffmpeg_info = ((& $ffmpeg -nostdin -i $full_path 2>&1 | ForEach-Object { "$_" }) -join "`n")
	}

	# F25. Битрейт ИМЕННО видеопотока: строка `Stream #...: Video: ..., N kb/s`.
	# Раньше брали `Duration: ..., bitrate: N kb/s` — это битрейт КОНТЕЙНЕРА
	# (видео + аудио + overhead): настройка обещает не повышать исходный видеобитрейт,
	# а сравнивала с завышенным числом и потому всё равно его повышала.
	$src_bitrate = $null
	$vstream_match = [regex]::Match($ffmpeg_info, "Stream #.*Video:.*?(\d+)\s*kb/s")
	if ($vstream_match.Success) { $src_bitrate = [int]$vstream_match.Groups[1].Value }
	# Часть контейнеров (MKV/WebM) per-stream битрейт не сообщает. Тогда откатываемся
	# на битрейт контейнера — это верхняя оценка, а не битрейт видео, поэтому говорим
	# об этом в лог, а не выдаём молча за исходный видеобитрейт.
	if (-not $src_bitrate) {
		$bitrate_match = [regex]::Match($ffmpeg_info, "bitrate:\s+(\d+)\s*kb/s")
		if ($bitrate_match.Success) {
			$src_bitrate = [int]$bitrate_match.Groups[1].Value
			if ($video_bitrate_status -eq "+" -and $audio_only -ne "yes") {
				Log-Msg "WARN" "$($file.Name): битрейт видеопотока не сообщён, используется битрейт контейнера (${src_bitrate}k) — верхняя оценка"
			}
		}
	}

	$set_video_bitrate_final = @()
	if ($audio_only -ne "yes" -and $video_bitrate_status -eq "+" -and $video_quality_status -ne "+") {
		if ($src_bitrate -and $src_bitrate -lt [int]$set_video_bitrate_orig) {
			$set_video_bitrate_final = @("-b:v", "${src_bitrate}k")
		} else {
			$set_video_bitrate_final = @("-b:v", "${set_video_bitrate_orig}k")
		}
	}

	$convert_args = @()
	if ($copy_codecs -eq "yes") {
		$convert_args = @("-c", "copy", "-map", "0")
	} else {
		$convert_args += $video_settings_args
		$convert_args += $set_video_bitrate_final
		$convert_args += $audio_settings_args
			$convert_args += @("-map_metadata", "0")  # сохранить глобальные теги источника
	}

	# Одна загрузка на исходный файл, задач — по одной на часть. Обнуление стоит
	# ДО блока определения длительности: тонкий клиент грузит файл именно там,
	# и сброс после него стёр бы уже полученный идентификатор.
	$script:remoteUploadId = ''
	$script:remoteSubId = ''
	$fileDuration = 0
	$dur_match = [regex]::Match($ffmpeg_info, "Duration:\s+(\d+):(\d+):(\d+)")
	if ($dur_match.Success) {
		$fileDuration = [int]$dur_match.Groups[1].Value * 3600 + [int]$dur_match.Groups[2].Value * 60 + [int]$dur_match.Groups[3].Value
	}

	# Запасной источник длительности — ответ службы на POST /uploads/{id}/complete.
	# Он нужен ДО расчёта границ частей, поэтому загрузку делаем здесь, а не в цикле:
	# иначе `remote_active = yes` + `[split] length` у тонкого клиента давали
	# «Длительность неизвестна, разбиение пропущено», и фолбэк был мёртв. Загрузка
	# одна на файл — блок в цикле по частям её не повторит. Паритет с .sh.
	if ($remote_active -eq 'yes' -and $dry_run -ne 'yes' -and $fileDuration -le 0 -and $length_coding_status -eq '+') {
		Log-Msg "INFO" "Длительность неизвестна локально — берём её у службы: $($file.Name)"
		$script:_remoteUploadName = $file.Name
		$script:RemoteUploadSidecar = "$manifest.upload"
		$script:remoteUploadId = Send-RemoteUpload $full_path
		$script:RemoteUploadSidecar = ''
		if ($script:remoteUploadId -and $script:RemoteUploadDuration) {
			$fileDuration = [int]([double]$script:RemoteUploadDuration)
		}
	}

	# Видео/аудио фильтры для текущего файла. _base — снимок до per-part модификаций
	# (subtitles burn / meta -map). Восстанавливается в начале каждой итерации цикла
	# по частям, иначе значения накапливаются между частями.
	$convert_args_base = @() + $convert_args
	$vf_parts_base = @() + $vf_parts
	$af_parts_base = @() + $af_parts
	$current_vf_parts = [System.Collections.ArrayList]@($vf_parts)
	$current_af_parts = [System.Collections.ArrayList]@($af_parts)

	# Определение длительности и точек разреза
	if ($length_coding_status -eq "+") {
		$duration = [int]$fileDuration

		if ($split_by_silence -eq "yes") {
			Write-Host "`nЖдите! Идёт поиск пауз в файле:`n$full_path`n"
			$search_silence = & $ffmpeg -i $full_path -nostats -af "silencedetect=n=${silence_threshold}:d=${silence_duration}" -f null - 2>&1
			$split_points = @()
			$silence_start_val = $null
			foreach ($line in $search_silence) {
				$lineStr = "$line"
				# Знак обязателен в шаблоне: ffmpeg печатает и отрицательный silence_start
				# (например "silence_start: -0.0261224"). Без минуса строка не матчилась
				# вовсе, и вся пауза молча пропадала из списка точек разбиения.
				if ($lineStr -match "silence_start:\s+(-?[\d.]+)") { $silence_start_val = [double]$matches[1] }
				if ($lineStr -match "silence_end:\s+(-?[\d.]+)" -and $null -ne $silence_start_val) {
					$silence_end_val = [double]$matches[1]
					# Floor, а не [int]: приведение к int в .NET округляет «к ближайшему
					# чётному» (банковское), а printf "%d" в .sh усекает — точка разреза
					# по одной и той же паузе отличалась между платформами на секунду.
					$split_points += [int][Math]::Floor(($silence_start_val + $silence_end_val) / 2)
				}
			}
		}

		# F16. Сначала строим МОНОТОННЫЙ массив границ, и только потом считаем длительности
		# как разность соседних границ. Раньше длина i-й части бралась как
		# length_coding_value-(part_start-new_part_start) — то есть в предположении, что
		# СЛЕДУЮЩАЯ граница осталась на номинальном месте. Но она тоже сдвигалась к своей
		# тишине → между частями появлялись зазоры и перекрытия.
		$num = @()
		$length_silent_values = @{}
		$maxParts = 1000
		for ($i = 0; $i -lt $maxParts; $i++) {
			$nominal = $length_coding_value * $i
			if ($duration -le $nominal) { break }
			$bnd = $nominal
			# i=0 — начало файла: притягивать его к тишине нельзя, иначе начало срезается.
			if ($i -gt 0 -and $split_by_silence -eq "yes" -and $split_points.Count -gt 0) {
				$best_point = $nominal
				$best_diff = 999999
				foreach ($p in $split_points) {
					$d = [Math]::Abs($p - $nominal)
					if ($d -lt $best_diff) { $best_diff = $d; $best_point = $p }
				}
				if ($best_diff -le [int]($length_coding_value / 2)) { $bnd = $best_point }
			}
			# Монотонность: граница обязана строго расти, иначе получим часть нулевой или
			# отрицательной длины (две номинальные точки могли притянуться к одной тишине).
			if ($i -gt 0 -and $bnd -le $num[$i-1]) { $bnd = $nominal }
			if ($i -gt 0 -and $bnd -le $num[$i-1]) { break }
			$num += $bnd
		}
		if ($i -ge $maxParts) {
			Log-Msg "WARN" "Достигнут предел $maxParts частей — хвост файла не обработан: $($file.Name)"
		}
		# Длительности = разности соседних границ. Последняя часть идёт ДО КОНЦА файла:
		# фиксированный -t обрезал бы хвост, если граница сдвинулась к тишине назад.
		if ($split_by_silence -eq "yes" -and $num.Count -gt 0) {
			for ($i = 0; $i -lt $num.Count; $i++) {
				if ($i + 1 -lt $num.Count) {
					$length_silent_values[$i] = $num[$i+1] - $num[$i]
				} else {
					$length_silent_values[$i] = "END"
				}
			}
		}
	} else {
		$num = @(0)
	}

	# Duration N/A или 0 → num пуст → файл молча пропускался. Обрабатываем целиком.
	#
	# «Целиком» обязано означать целиком. Раньше сбрасывался только массив границ, а
	# $current_set_length оставался равным `-t L` — выход без суффикса «(part.N)»
	# содержал ПЕРВЫЕ L секунд, статус OK, manifest записан, и следующий прогон
	# пропускал файл навсегда. Входы с Duration: N/A реальны: недописанные mkv/webm.
	$lengthDisabled = $false
	if ($num.Count -eq 0) {
		$num = @(0)
		if ($set_length_coding) {
			Log-Msg "WARN" "Длительность неизвестна: разбиение пропущено И ограничение длительности снято, файл обрабатывается целиком: $($file.Name)"
			$lengthDisabled = $true
		} else {
			Log-Msg "WARN" "Длительность неизвестна, разбиение пропущено: $($file.Name)"
		}
	}

	if ($start_coding_status -eq "+") { $num = @($start_coding_value) }

	# Готовые выходы копим, чтобы записать manifest одной транзакцией после цикла.
	# $script:, а не локальные: публикацию результата ведёт Publish-EncodedResult,
	# общая с удалённым путём, — из своей области видимости она локальные не увидит
	# и счётчики молча терялись бы.
	$script:produced = @()
	$script:anyFail = $false

	# F29. Размер входа засчитываем ОДИН раз на исходный файл. Раньше он прибавлялся
	# на КАЖДУЮ часть, поэтому при разбиении на N частей вход суммировался N раз —
	# сводка показывала завышенное сжатие. Выход при этом честно считается по частям.
	$script:inReported = $false
	$c = 1
	foreach ($b in $num) {
		$pref = ""
		if ($num.Count -gt 1 -or $num[0] -ne 0) { $pref = " (part.$c)" }

		# Сброс из базы — см. _base снимки выше.
		$convert_args = @() + $convert_args_base; $sub_burned = $false
		$current_vf_parts = [System.Collections.ArrayList]@($vf_parts_base)
		$current_af_parts = [System.Collections.ArrayList]@($af_parts_base)

		$current_set_length = $set_length_coding
		# Длительность неизвестна → -t снят вместе с разбиением (см. выше).
		if ($lengthDisabled) { $current_set_length = "" }
		if ($split_by_silence -eq "yes" -and $length_coding_status -eq "+" -and -not $lengthDisabled) {
			$silent_idx = $c - 1
			if ($length_silent_values.ContainsKey($silent_idx)) {
				# F16. "END" — последняя часть: -t не ставим вообще, иначе хвост обрезается.
				if ($length_silent_values[$silent_idx] -eq "END") {
					$current_set_length = ""
				} else {
					$current_set_length = "-t $($length_silent_values[$silent_idx])"
				}
			}
		}

		# B2. Субтитры с subtitles_style
		$subtitles_args = @()
		if ($video_subtitles_status -eq "+" -and $copy_codecs -ne "yes" -and $audio_only -ne "yes") {
			$sub_found = $false
			foreach ($ext in @("srt", "vtt")) {
				if (-not $sub_found) {
					# F32. Sidecar ищем по СТЕМУ входа: movie.srt рядом с movie.mp4.
					$sub_file = "$folder_sources$file_path$input_stem.$ext"
					if (Test-Path -LiteralPath $sub_file) {
						if ($video_subtitles_value -eq "burn") {
							# Апостроф — единственный символ, которого не спасают кавычки
							# вокруг значения: внутри '…' backslash копируется буквально,
							# а первая же ' закрывает строку. Разбор двухуровневый (граф
							# фильтров → опции фильтра), поэтому экранирований два:
							# уровень опций ' → \' и уровень графа ' → '\'' — вместе \'\''.
							# Проверено на ffmpeg 8.1.2: и \' , и '\'' по отдельности дают
							# «Unable to open …/its video». Паритет с .sh и .cmd.
							$sub_escaped = $sub_file -replace '\\','/'
							$sub_escaped = $sub_escaped.Replace("'", "\'\''")
							$sub_escaped = $sub_escaped -replace ':','\:' -replace '\[','\[' -replace '\]','\]' -replace ';','\;' -replace '%','\%'
							$sub_burned = $true
							# subtitles — CPU-фильтр: на GPU-кадрах (hwaccel_output_format cuda/qsv)
							# ffmpeg падает с "Impossible to convert between the formats". Скачиваем
							# кадры в системную память перед прожигом. Проверено на RTX 5060 Ti.
							if ($use_hw_accel -and ($current_vf_parts -notcontains "hwdownload")) {
								$current_vf_parts.Add("hwdownload") | Out-Null
								$current_vf_parts.Add("format=nv12") | Out-Null
							}
							if ($subtitles_style) {
								$current_vf_parts.Add("subtitles='${sub_escaped}':force_style='${subtitles_style}'") | Out-Null
							} else {
								$current_vf_parts.Add("subtitles='${sub_escaped}'") | Out-Null
							}
						}
						if ($video_subtitles_value -eq "meta") {
							$subtitles_args = @("-i", $sub_file, "-c:s", $sub_meta_codec, "-metadata:s:s:0", "language=rus")
							$convert_args += @("-map", "0", "-map", "1")
						}
						$sub_found = $true
					}
				}
			}
		}

		# Финализация фильтров
		$vf_args = @()
		if ($current_vf_parts.Count -gt 0) { $vf_args = @("-vf", ($current_vf_parts -join ",")) }
		$af_args = @()
		if ($current_af_parts.Count -gt 0) { $af_args = @("-af", ($current_af_parts -join ",")) }
		# copy_codecs несовместим с фильтрами
		if ($copy_codecs -eq "yes") { $vf_args = @(); $af_args = @() }

		$out_file = "$out_base$pref.$current_format_out"
		# F11. Прогресс — против эффективной длины сегмента (-t L или dur-b), не полной длительности.
		$progressDur = if ($current_set_length -match '^-t (\d+)') { [int]$Matches[1] } elseif ($b -gt 0) { $fileDuration - $b } else { $fileDuration }
		if ($progressDur -le 0) { $progressDur = $fileDuration }

		# Сборка аргументов (A5 — без Split, через массив).
		# -ss располагается ДО -i: fast seek по контейнеру вместо декодирования от 0.
		$ffmpegArgs = @("-hide_banner", "-strict", "-2")
		$ffmpegArgs += $hw_decode_args
		# F5: при прожиге субтитров input-side -ss сбивает PTS кадров → -ss на выход (ниже).
		if ($b -gt 0 -and -not $sub_burned) { $ffmpegArgs += @("-ss", "$b") }
		$ffmpegArgs += @("-i", $full_path)
		$ffmpegArgs += $subtitles_args
		$ffmpegArgs += $convert_args
		$ffmpegArgs += $thread_args
		$ffmpegArgs += $vf_args
		$ffmpegArgs += $af_args
		if ($b -gt 0 -and $sub_burned) { $ffmpegArgs += @("-ss", "$b") }
		if ($current_set_length) { $ffmpegArgs += $current_set_length -split ' ' }
		# Пишем в соседний temp и переименовываем в цель только после rc=0. Прямая запись
		# в out_file означала, что прерванный прогон (Kill, падение, нехватка места)
		# оставлял обрезанный файл под финальным именем — следующий запуск принимал его
		# за готовый результат. Переименование в пределах каталога атомарно.
		$out_tmp = Get-PartialPath $out_file
		if (Test-Path -LiteralPath $out_tmp) { Remove-Item -LiteralPath $out_tmp -Force -ErrorAction SilentlyContinue }
		$ffmpegArgs += @($out_tmp, "-y")
		$ffmpegArgs = $ffmpegArgs | Where-Object { $_ -ne "" -and $_ -ne $null }

		# Удалённый бэкенд подменяет РОВНО этот участок: сборку argv и запуск
		# ffmpeg. Всё до и после остаётся общим — поэтому один config.ini даёт
		# один результат на обоих путях.
		#
		# $partRemote — решение ДЛЯ ЭТОЙ ЧАСТИ, а не для прогона: при
		# [remote] on_failure = local неудача службы переводит часть на локальный
		# ffmpeg, и она обязана провалиться в тот же самый код, что и обычный
		# локальный путь. Дубль локальной ветки означал бы два разных
		# «кодирования» из одного config.ini.
		$partRemote = ($remote_active -eq 'yes')
		$partDone = $false
		if ($partRemote) {
			$rLen = 0
			if ($current_set_length -match '^-t\s+(\d+)') { $rLen = [int]$Matches[1] }
			# Третий аргумент — «sidecar найден»: без него поле subtitles уезжало
			# службе и при отсутствующем файле титров.
			$rMap = Get-RemoteOpForConfig ([int]$b) $rLen ([bool]$sub_found)
			if ($null -eq $rMap) {
				Log-Msg "FAIL" "$($file.Name): кодек $set_video_codec служба не поддерживает"
				$script:anyFail = $true; $script:countFail++
				$partRemote = $false; $partDone = $true
			} elseif ($dry_run -eq 'yes') {
				# dry_run НЕ загружает: «только показать команды» не имеет права
				# стоить часов трафика и гигабайт в хранилище службы.
				$script:remoteUploadId = '<pending>'
			} elseif (-not $script:remoteUploadId) {
				Log-Msg "INFO" "Отправка на сервер: $($file.Name)"
				$script:_remoteUploadName = $file.Name
				# Sidecar рядом с manifest'ом: повторный запуск после обрыва
				# доходит до GET /uploads/<id> с настоящим смещением вместо того,
				# чтобы просить новую загрузку и лить гигабайты заново.
				$script:RemoteUploadSidecar = "$manifest.upload"
				$script:remoteUploadId = Send-RemoteUpload $full_path
				$script:RemoteUploadSidecar = ''
				if ($script:remoteUploadId) {
					# Длительность из ответа службы — запасной источник для тонкого
					# клиента без локального ffmpeg.
					# Имя переменной здесь — $fileDuration: писалось $file_duration, а
					# читалось везде $fileDuration, и «запасной источник длительности»
					# был мёртв на этой платформе.
					if ((-not $fileDuration -or $fileDuration -le 0) -and $script:RemoteUploadDuration) {
						$fileDuration = [int]([double]$script:RemoteUploadDuration)
					}
					$script:remoteSubId = ''
					# Файл субтитров приходит той же дорогой, что видео: путей в
					# параметрах служба не принимает по построению.
					# Провал загрузки титров — ПРОВАЛ части, а не тихое «без титров»:
					# раньше задача создавалась без subtitle_upload_id, и файл
					# приезжал без субтитров со статусом OK.
					if ($sub_found -and $sub_file) {
						$script:remoteSubId = Send-RemoteUpload $sub_file
						if (-not $script:remoteSubId) {
							if (Test-RemoteFallbackAllowed $file.Name "загрузка файла субтитров не удалась") {
								$partRemote = $false
							} else {
								Log-Msg "FAIL" "$($file.Name): загрузка файла субтитров не удалась"
								$script:anyFail = $true; $script:countFail++
								$partRemote = $false; $partDone = $true
							}
						}
					}
				} else {
					if (Test-RemoteFallbackAllowed $file.Name "загрузка не удалась") {
						$partRemote = $false
					} else {
						Log-Msg "FAIL" "$($file.Name): загрузка не удалась"
						$script:anyFail = $true; $script:countFail++
						$partRemote = $false; $partDone = $true
					}
				}
			}
		}

		if ($partRemote -and $dry_run -eq 'yes') {
			Invoke-RemoteDryRun $script:remoteUploadId $rMap.Op $rMap.Params $script:remoteSubId | Out-Null
			$partDone = $true
		} elseif ($partRemote) {
			$jobId = Submit-RemoteJob $script:remoteUploadId $rMap.Op $rMap.Params $script:remoteSubId
			if ($jobId) {
				$startTime = Get-Date
				$onProgress = {
					param($pct, $label, $phase)
					Write-GUIProgress -FilePercent $pct -CurrentFile $label -Phase $phase
				}
				$onCancel = { $guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile) }
				if ((Wait-RemoteJob $jobId $file.Name $onProgress $onCancel)) {
					Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name -Phase 'скачивание'
					if (Receive-RemoteResult $jobId $out_tmp) {
						Publish-EncodedResult $file $out_tmp $out_file $startTime $true | Out-Null
						$partDone = $true
					}
				}
				if (-not $partDone -and (Test-Path -LiteralPath $out_tmp)) {
					Remove-Item -LiteralPath $out_tmp -Force -ErrorAction SilentlyContinue
				}
			}
			# Не получилось — либо откат на локальный ffmpeg (шумный, по ключу),
			# либо fail. Молчаливого отката здесь нет ни в одной ветке.
			if (-not $partDone) {
				if (Test-RemoteFallbackAllowed $file.Name "удалённое кодирование не удалось") {
					$partRemote = $false
				} else {
					Log-Msg "FAIL" "$($file.Name)"
					$script:anyFail = $true; $script:countFail++
					$partDone = $true
				}
			}
		}

		if ($partDone) {
			# Часть уже обработана удалённым путём (или явно провалена).
		# D7. Dry-run
		} elseif ($dry_run -eq "yes") {
			Write-Host "[DRY-RUN] $ffmpeg $($ffmpegArgs -join ' ')"
			$_cmdStr = "$ffmpeg $($ffmpegArgs -join ' ')"
			Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name -Command $_cmdStr
		} else {
			Log-Msg "INFO" "Кодирование: $($file.Name) -> $(Split-Path $out_file -Leaf)"
			$_cmdStr = "$ffmpeg $($ffmpegArgs -join ' ')"
			Write-GUIProgress -FilePercent 0 -CurrentFile $file.Name -Command $_cmdStr

			# J1. Запуск ffmpeg с прогресс-файлом
			$progressTempFile = [System.IO.Path]::GetTempFileName()
			$ffmpegArgsWithProgress = $ffmpegArgs[0..($ffmpegArgs.Count-2)] + @("-progress", $progressTempFile) + @($ffmpegArgs[-1])

			$startTime = Get-Date
			$proc = New-Object System.Diagnostics.Process
			$proc.StartInfo.FileName = $ffmpeg
			$proc.StartInfo.UseShellExecute = $false
			$proc.StartInfo.CreateNoWindow = $true
			$proc.StartInfo.RedirectStandardError = $true
			# Аргументы передаём как строку с экранированием по правилам CommandLineToArgvW:
			# backslash перед кавычкой и в конце токена удваиваем, иначе trailing `\`
			# (напр. путь "C:\dir\") экранирует закрывающую кавычку и смещает границу аргумента.
			$proc.StartInfo.Arguments = ($ffmpegArgsWithProgress | ForEach-Object {
				if ($_ -match '[ \t"\\]') {
					$a = [regex]::Replace($_, '(\\*)"', '$1$1\"')
					$a = [regex]::Replace($a, '(\\+)$', '$1$1')
					'"' + $a + '"'
				} else { $_ }
			}) -join " "
			# F08. stderr дренируем АСИНХРОННО в буфер, чтобы не было дедлока с
			# чтением -progress temp-файла; на ошибке покажем последние строки.
			$errBuf = New-Object System.Collections.ArrayList
			$errHandler = {
				if ($null -ne $EventArgs.Data) { [void]$Event.MessageData.Add($EventArgs.Data) }
			}
			$errSub = Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived -Action $errHandler -MessageData $errBuf
			# try/finally вокруг всей жизни процесса. Ctrl+C в CLI останавливает конвейер
			# PowerShell, но НЕ доходит до ffmpeg: он запущен с CreateNoWindow, то есть в
			# собственной скрытой консоли, куда CTRL_C_EVENT родительской консоли не
			# доставляется. Без finally он дописывал файл до конца (часы на большом входе),
			# а .ffconv-partial-* оставался в destination. GUI-путь защищён cancel-файлом,
			# .sh — trap-ом; CLI-PS1 был единственным незакрытым. finally выполняется и при
			# остановке конвейера.
			$procDone = $false
			try {
			$proc.Start() | Out-Null
			$proc.BeginErrorReadLine()

			# Обновляем прогресс в GUI-файл (если GUI) или Write-Progress (если CLI)
			while (!$proc.HasExited) {
				Start-Sleep -Milliseconds 400
				# Проверка отмены
				if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
					try { $proc.Kill() } catch {}
					break
				}
				# Читаем прогресс-файл ffmpeg
				$fpct = 0
				if (Test-Path -LiteralPath $progressTempFile) {
					$fs = $null; $sr = $null
					try {
						$fs = [System.IO.FileStream]::new($progressTempFile, 'Open', 'Read', 'ReadWrite')
						$sr = [System.IO.StreamReader]::new($fs)
						$fc = $sr.ReadToEnd()
						$m = [regex]::Matches($fc, "out_time=(\d+):(\d+):(\d+)")
						if ($m.Count -gt 0 -and $progressDur -gt 0) {
							$last = $m[$m.Count - 1]
							$outSec = [int]$last.Groups[1].Value * 3600 + [int]$last.Groups[2].Value * 60 + [int]$last.Groups[3].Value
							$fpct = [int]($outSec / $progressDur * 100)
							$fpct = [Math]::Min($fpct, 99)
						}
					} catch {} finally {
						# Закрываем в finally — иначе при исключении в ReadToEnd хендл файла течёт
						# каждые 400мс. StreamReader.Dispose() закрывает и нижележащий FileStream.
						if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
					}
				}

				if ($guiProgressFile) {
					Write-GUIProgress -FilePercent $fpct -CurrentFile $file.Name
				} else {
					# CLI: Write-Progress
					Write-Progress -Activity "Кодирование" -Status $file.Name -PercentComplete $fpct
				}
			}

			if (!$proc.HasExited) { $proc.WaitForExit() }
			try { $proc.CancelErrorRead() } catch {}
			if ($errSub) { Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue; Remove-Job $errSub -Force -ErrorAction SilentlyContinue }
			$exitCode = $proc.ExitCode
			Remove-Item $progressTempFile -Force -ErrorAction SilentlyContinue
			if (-not $guiProgressFile) { Write-Progress -Activity "Кодирование" -Completed }

			$elapsed = (Get-Date) - $startTime
			$elapsedStr = "{0}m {1}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

			# E2. Обработка ошибок
			if ($exitCode -ne 0) {
				Log-Msg "FAIL" "$($file.Name) (exit code $exitCode, $elapsedStr)"
				if ($errBuf.Count -gt 0) {
					$errBuf | Select-Object -Last 3 | ForEach-Object { Log-Msg "FAIL" "  $_" }
				}
				# Ждём освобождения файла после Kill
				Start-Sleep -Milliseconds 500
				if (Test-Path -LiteralPath $out_tmp) { Remove-Item -LiteralPath $out_tmp -Force -ErrorAction SilentlyContinue }
				$script:anyFail = $true
				$script:countFail++
				Write-GUIProgress -FilePercent 0 -CurrentFile $file.Name
			} else {
				# Публикация — общая с удалённым путём (см. Publish-EncodedResult выше).
				Publish-EncodedResult $file $out_tmp $out_file $startTime | Out-Null
			}
			$procDone = $true
			} finally {
				if (-not $procDone) {
					try { if ($proc -and -not $proc.HasExited) { $proc.Kill() } } catch {}
					if ($errSub) { Unregister-Event -SourceIdentifier $errSub.Name -ErrorAction SilentlyContinue; Remove-Job $errSub -Force -ErrorAction SilentlyContinue }
					Remove-Item -LiteralPath $progressTempFile -Force -ErrorAction SilentlyContinue
					if (Test-Path -LiteralPath $out_tmp) { Remove-Item -LiteralPath $out_tmp -Force -ErrorAction SilentlyContinue }
				}
			}
		}
		$c++
	}

	# Manifest пишем только когда удались ВСЕ части. Именно его отсутствие заставит
	# следующий запуск доделать файл, вместо того чтобы принять уцелевшую (part.1) за
	# готовый результат. Частичный успех manifest'а не получает намеренно.
	if ($dry_run -ne "yes" -and -not $script:anyFail -and $script:produced.Count -gt 0) {
		Write-Manifest $manifest $full_path $file_sig $script:produced
	}
}

# F-modes. Спецрежимы (merge/extract/frame/copy/audio) взаимоисключающи: при нескольких
# включённых часть опций молча игнорируется. Называем эффективный режим по приоритету
# merge>extract>frame>copy>audio и ЯВНО предупреждаем о проигнорированных.
$_activeModes = @()
if ($merge_files -eq "yes")        { $_activeModes += "merge" }
if ($extract_audio_copy -eq "yes") { $_activeModes += "extract" }
if ($create_frame -eq "yes")       { $_activeModes += "frame" }
if ($copy_codecs -eq "yes")        { $_activeModes += "copy" }
if ($audio_only -eq "yes")         { $_activeModes += "audio" }
if ($_activeModes.Count -gt 1) {
	Log-Msg "WARN" "Включено несколько взаимоисключающих режимов ($($_activeModes -join ' ')). Активен «$($_activeModes[0])» (приоритет merge>extract>frame>copy>audio), остальные проигнорированы."
}

# --- Удалённый бэкенд: включён ли он для ЭТОГО прогона ---
$remote_active = 'no'
if ($remote_enabled -eq 'yes') {
	if (-not (Get-Command Set-RemoteActive -ErrorAction SilentlyContinue)) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но рядом со скриптом нет remote_client.ps1."
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	Set-RemoteActive | Out-Null
	if ($script:remote_fatal) {
		# Preflight не прошёл — не трогаем ни одного файла. Отказать на сотом
		# файле из двухсот дороже, чем на нулевом.
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	$remote_active = $script:remote_active
	if ($remote_active -eq 'yes') {
		if ($remote_on_failure -eq 'local' -and -not $ffmpeg_available) {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] on_failure = local, но локального ffmpeg нет: откатываться будет некуда."
		}
		# Границы «тонкого клиента». Разбиение по тишине читает границы у
		# ЛОКАЛЬНОГО ffmpeg (silencedetect); брать их у службы отклонено спекой
		# (раздел 3.1) как второй источник правды. Без ffmpeg честнее отказать
		# явно, чем молча разбить файл не там.
		if (-not $ffmpeg_available -and $split_by_silence -eq 'yes') {
			Write-Host "[ОШИБКА] split_by_silence = yes требует локального ffmpeg (silencedetect), а он не найден."
			Pause-Prompt "Нажмите [Enter], чтобы выйти..."
			exit 1
		}
		Log-Msg "INFO" "Удалённый бэкенд включён: кодирование уходит на службу конвертации"
	}
	# Режим оказался локальным (merge/copy/frames/audio), а ffmpeg нет — дальше
	# идти некуда, и сказать об этом надо здесь, а не падать на первом файле.
	if ($remote_active -ne 'yes' -and -not $ffmpeg_available) {
		Write-Host "`n[ОШИБКА] ffmpeg не найден ($ffmpeg), а этот режим считается локально.`n"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
}

# --- Боевая самопроверка удалённого пути ---
# Отдельный режим, а не часть прогона: он ничего не конвертирует и обязан
# завершиться до того, как будет тронут хоть один файл пользователя.
if ($env:FFCONV_REMOTE_SELFTEST -eq '1') {
	if ($remote_enabled -ne 'yes') {
		Write-Host "[ОШИБКА] --remote-selftest требует [remote] enabled = yes в config.ini."
		exit 1
	}
	if (-not (Get-Command Invoke-RemoteSelftest -ErrorAction SilentlyContinue)) {
		Write-Host "[ОШИБКА] Рядом со скриптом нет remote_client.ps1 — самопроверка невозможна."
		exit 1
	}
	$_stRc = Invoke-RemoteSelftest
	Pause-Prompt "Нажмите [Enter], чтобы выйти..."
	exit $_stRc
}

# --- Основная логика ---
if ($merge_files -eq "yes") {
	if (($format_files_in_list | Measure-Object).Count -eq 0) {
		Log-Msg "WARN" "Нет файлов для объединения в $folder_sources"
		$script:countSkip++
	} else {
	$_mergeSorted = $format_files_in_list | Sort-Object FullName  # F10: паритет с .sh sort -z
		$fname = $_mergeSorted[0].Name
	if ($overwrite_existing -ne "yes" -and (Test-Path -LiteralPath "$folder_destination\$fname")) {
		# Цель существует, а перезапись выключена — это ПРОПУСК, и он обязан быть
		# назван. Раньше ветки не было вовсе: сводка показывала 0/0/0, rc=0, GUI писал
		# «Готово», и понять, почему объединения не произошло, было нечем.
		Log-Msg "SKIP" "Объединение пропущено: «$folder_destination\$fname» уже существует (overwrite_existing = no)"
		$script:countSkip++
	} else {
		$tmpFile = [System.IO.Path]::GetTempFileName()
		[System.IO.File]::WriteAllLines($tmpFile, ($_mergeSorted.FullName | ForEach-Object { "file '" + ($_ -replace "'", "'\''") + "'" }))
		# Мержим в соседний temp, а не сразу поверх цели. Прежний вызов шёл без -y на
		# существующий файл: ffmpeg спрашивал «File exists. Overwrite? [y/N]» и висел,
		# ожидая stdin, которого в batch/GUI нет. А упавший мерж оставлял partial под
		# именем цели, и следующий запуск принимал его за готовый результат.
		$mergeTarget = "$folder_destination\$fname"
		# F-merge-inplace. Цель не может совпасть ни с одним входом (dest == source): мерж
		# затёр бы источник собой, а следующий прогон задублировал бы объединённый файл.
		$_canonMergeTarget = (Get-CanonPath $mergeTarget)
		$_mergeTargetIsInput = $false
		foreach ($_mi in $_mergeSorted) {
			if ((Get-CanonPath $_mi.FullName) -ieq $_canonMergeTarget) { $_mergeTargetIsInput = $true; break }
		}
		$mergeTmp = Get-PartialPath $mergeTarget
		if ($_mergeTargetIsInput) {
			Log-Msg "FAIL" "Объединение отклонено: результат «$mergeTarget» совпадает с одним из входов (in-place merge затёр бы источник). Задайте другой destination."
			$script:countFail++
			# Временный concat-список удаляем и здесь: без этого отклонённый in-place
			# мерж оставлял файл в %TEMP% на каждом прогоне.
			Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
		} elseif ($dry_run -eq "yes") {
			Write-Host "[DRY-RUN] $ffmpeg -hide_banner -nostdin -strict -2 -f concat -safe 0 -i `"$tmpFile`" -c copy -map 0 -y `"$mergeTmp`""
			Remove-Item $tmpFile -Force
		} else {
			Log-Msg "INFO" "Объединение файлов -> $mergeTarget"
			if (Test-Path -LiteralPath $mergeTmp) { Remove-Item -LiteralPath $mergeTmp -Force -ErrorAction SilentlyContinue }
			# 2>&1 в конвейер: в hostless-runspace GUI stderr нативной команды иначе
			# оседает в $ps.Streams.Error, и успешное объединение показывалось как
			# «Ошибка» с MessageBox.
			& $ffmpeg -hide_banner -nostdin -strict -2 -f concat -safe 0 -i $tmpFile -c copy -map 0 -y $mergeTmp 2>&1 | ForEach-Object { Write-Host "$_" }
			$mergeRc = $LASTEXITCODE
			# rc=0 сам по себе не гарантирует читаемый контейнер — валидируем тем же
			# `-f null -`, что и обычные выходные файлы, и только потом подменяем цель.
			$mergeOk = $false
			if ($mergeRc -eq 0 -and (Test-Path -LiteralPath $mergeTmp) -and (Get-FileSize $mergeTmp) -gt 0) {
				& $ffmpeg -nostdin -v error -i $mergeTmp -f null - 2>&1 | Out-Null
				if ($LASTEXITCODE -eq 0) { $mergeOk = $true }
			}
			if ($mergeOk) {
				# F-rename. Публикацию подтверждаем: -ErrorAction Stop + наличие цели.
				try {
					Move-Item -LiteralPath $mergeTmp -Destination $mergeTarget -Force -ErrorAction Stop
				} catch { $mergeOk = $false }
				if ($mergeOk -and (Test-Path -LiteralPath $mergeTarget -PathType Leaf)) {
					Log-Msg "OK" "Объединение файлов -> $mergeTarget"
					$script:countOk++
				} else {
					Log-Msg "FAIL" "Объединение файлов: не удалось опубликовать результат (rename)"
					if (Test-Path -LiteralPath $mergeTmp) { Remove-Item -LiteralPath $mergeTmp -Force -ErrorAction SilentlyContinue }
					$script:countFail++
				}
			} else {
				Log-Msg "FAIL" "Объединение файлов"
				if (Test-Path -LiteralPath $mergeTmp) { Remove-Item -LiteralPath $mergeTmp -Force -ErrorAction SilentlyContinue }
				$script:countFail++
			}
			Remove-Item $tmpFile -Force
		}
	}
	}
} else {
	# B1b. Последовательная обработка файлов
	# Параллельная обработка через ForEach-Object -Parallel требует полной передачи
	# всех переменных и функций через $using:, что несовместимо с текущей архитектурой
	# (Encode-File использует $script:-переменные). Используется последовательная обработка.
	foreach ($file in $format_files_in_list) {
		if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) { break }
		Encode-File -file $file
	}
}

# --- J2. Итоговая сводка ---
$elapsedAll = (Get-Date) - $script:startTimeAll
$elapsedAllStr = "{0} мин {1} сек" -f [int]$elapsedAll.TotalMinutes, $elapsedAll.Seconds

if (-not $guiProgressFile) {
	# CLI: показываем сводку в консоли
	Write-Host ""
	Write-Host "══════════════════════════════════════════════"
	# Пустой прогон обязан объяснять себя: сводка 0/0/0 без единой строки
	# неотличима от «отработало и ничего не нашло по ошибке в пути», а GUI при
	# этом показывает «Готово».
	if (($format_files_in_list | Measure-Object).Count -eq 0) {
		Write-Host ("  Входных файлов не найдено: в «{0}» нет файлов с расширениями из [files] format_files_in ({1})." -f $folder_sources, $format_files_in)
	}
	Write-Host ("  Обработано:  {0} файлов" -f $script:countOk)
	Write-Host ("  Пропущено:   {0} (уже существуют)" -f $script:countSkip)
	Write-Host ("  Ошибки:      {0}" -f $script:countFail)
	if ($script:countLocalFallback -gt 0) {
		Write-Host ("  Посчитано локально: {0} (служба была недоступна)" -f $script:countLocalFallback)
	}
	Write-Host ("  Время:       {0}" -f $elapsedAllStr)
	if ($script:totalInBytes -gt 0) {
		function Format-Bytes($b) {
			if ($b -ge 1GB) { "{0:F1} GB" -f ($b / 1GB) }
			elseif ($b -ge 1MB) { "{0:F1} MB" -f ($b / 1MB) }
			else { "{0:F0} KB" -f ($b / 1KB) }
		}
		$compressPct = [int]((1 - $script:totalOutBytes / $script:totalInBytes) * 100)
		Write-Host ("  Вход:        {0}" -f (Format-Bytes $script:totalInBytes))
		Write-Host ("  Выход:       {0} (сжатие {1}%)" -f (Format-Bytes $script:totalOutBytes), $compressPct)
	}
	Write-Host "══════════════════════════════════════════════"
	Write-Host ""
	Pause-Prompt "Нажмите [Enter], чтобы продолжить..."
} else {
	# GUI: записываем финальное состояние. F17. Финал обязан назвать исход явно —
	# GUI не видит наш exit code и по одному «Готово» не отличит провал от успеха.
	if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Отменено" -State "cancelled" -ExitCode 1 -Message "Отменено пользователем"
	} elseif ($script:countFail -gt 0) {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Ошибки" -State "failed" -ExitCode 1 -Message "Файлов с ошибками: $($script:countFail)"
	} else {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Готово" -State "success" -ExitCode 0
	}
}

# Exit code отражает наличие ошибок — cron/CI могут детектировать провал батча.
# Откат на локальный ffmpeg тоже даёт ненулевой код: пользователь просил считать
# на сервере, и то, что он получил результат другим способом, обязано быть видно
# и в автоматике, а не только в сводке на экране.
if ($script:countFail -gt 0) { exit 1 }
if ($script:countLocalFallback -gt 0) { exit 1 }
exit 0
