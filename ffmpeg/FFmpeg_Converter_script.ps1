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

# --- E1. Проверка окружения ---
$_isGui = [bool]$env:FFMPEG_GUI_PROGRESS_FILE -or [bool]$guiProgressFile
if ([string]::IsNullOrWhiteSpace($folder_sources) -or !(Test-Path $folder_sources)) {
	Write-Host "`n[ОШИБКА] Папка источника не найдена: $folder_sources`n"
	if (-not $_isGui) { Read-Host "Нажмите [Enter], чтобы выйти..." }
	exit 1
}

if ([string]::IsNullOrWhiteSpace($folder_destination)) {
	Write-Host "`n[ОШИБКА] Папка назначения не задана`n"
	if (-not $_isGui) { Read-Host "Нажмите [Enter], чтобы выйти..." }
	exit 1
}
if (!(Test-Path $folder_destination)) {
	New-Item -ItemType Directory $folder_destination -Force | Out-Null
}

try { & $ffmpeg -version 2>&1 | Out-Null } catch {
	Write-Host "`n[ОШИБКА] ffmpeg не найден: $ffmpeg`n"
	if (-not $_isGui) { Read-Host "Нажмите [Enter], чтобы выйти..." }
	exit 1
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
$parallel_count = if ($parallel_files_status -eq "+") { [int]$parallel_files_value } else { 1 }

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
if ($hw_accel_status -eq "+") {
	$encoders_list = & $ffmpeg -encoders 2>&1 | Out-String
	$hw_suffix = ""; $hw_label = ""; $hw_try_args = @(); $hw_try_type = ""
	switch ($hw_accel_value) {
		"nvidia" { $hw_suffix = "_nvenc"; $hw_label = "NVENC"; $hw_try_type = "nvidia"; $hw_try_args = @("-hwaccel", "cuda", "-hwaccel_output_format", "cuda") }
		"intel"  { $hw_suffix = "_qsv";   $hw_label = "QSV";   $hw_try_type = "intel";  $hw_try_args = @("-hwaccel", "qsv", "-hwaccel_output_format", "qsv") }
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
$_, $start_coding_status, $start_coding_value = $start_coding -split ":"
if ($start_coding_status -eq "+") {
	$x, $y, $z = $start_coding_value -split '-'
	$start_coding_value = [int]$x * 3600 + [int]$y * 60 + [int]$z
} else {
	$start_coding_value = 0
}

$_, $length_coding_status, $length_coding_value = $length_coding -split ":"
if ($length_coding_status -eq "+") {
	$x, $y, $z = $length_coding_value -split '-'
	$length_coding_value = [int]$x * 3600 + [int]$y * 60 + [int]$z
	$set_length_coding = "-t $length_coding_value"
} else {
	$set_length_coding = ""
	$split_by_silence = "no"
}

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
	# D3. Выходной контейнер
	if ($output_container_status -eq "+") {
		$format_files_out = $output_container_value
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
				default  { $vf_parts += "scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" }
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
			'_amf$'   { @("-qp", $video_quality_value); break }
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
$settings_sig = @(
	($video_settings_args -join ' '), ($audio_settings_args -join ' '),
	($vf_parts -join ','), ($af_parts -join ','),
	$format_files_out, $sub_meta_codec, $video_subtitles, $subtitles_style,
	$start_coding, $length_coding, $split_by_silence
) -join '|'

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
		if (-not $_isGui) { Read-Host "Нажмите [Enter], чтобы выйти..." }
		exit 1
	}
}

# --- Формат входных файлов ---
$format_files_in_list = Get-ChildItem $folder_sources -Recurse -Include ($format_files_in -split "," | ForEach-Object { "*.$_" })

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
		Add-Content -Path $log_file -Value $logLine
	}
}

# --- Запись GUI-прогресса ---
function Write-GUIProgress {
	# F17. state/exitCode/message — контракт с GUI. Раньше воркер писал финальное
	# «Готово» независимо от countFail, а `exit 1` не создаёт ErrorRecord, поэтому GUI
	# не мог отличить успешный батч от провального и показывал «Готово» после ошибок.
	param([int]$FilePercent = 0, [string]$CurrentFile = "", [string]$Command = "",
	      [ValidateSet("running","success","failed","cancelled")][string]$State = "running",
	      [int]$ExitCode = -1, [string]$Message = "")
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
		ok           = $script:countOk
		fail         = $script:countFail
		skip         = $script:countSkip
		command      = if ($script:_lastCommand) { $script:_lastCommand } else { "" }
		pid          = 0
	}
	try {
		$data | ConvertTo-Json | Set-Content -Path $guiProgressFile -Encoding UTF8 -NoNewline
	} catch {}
}

# --- A5. Функция кодирования одного файла (аргументы через массив, не Split) ---
function Encode-File {
	param([System.IO.FileInfo]$file)

	$full_path = $file.FullName
	$file_path = "$($file.DirectoryName)\"
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
	$file_path = $file_path -replace [regex]::Escape($folder_sources), ''
	if (!(Test-Path "$folder_destination$file_path")) { New-Item -ItemType Directory "$folder_destination$file_path" -Force | Out-Null }

	$script:fileNum++

	# Проверка отмены из GUI
	if ($guiCancelFile -and (Test-Path $guiCancelFile)) {
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
		if (Test-Path $outAudio) {
			$script:countSkip++
			Write-GUIProgress -CurrentFile $file.Name
			return
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
		& $ffmpeg -hide_banner -strict -2 -i $full_path -vn -c:a copy $outAudio -y
		if ($LASTEXITCODE -ne 0) {
			Log-Msg "FAIL" "$($file.Name)"
			if (Test-Path $outAudio) { Remove-Item $outAudio -Force }
			$script:countFail++
		} else {
			Log-Msg "OK" "$($file.Name) -> $(Split-Path $outAudio -Leaf)"
			$script:countOk++
			try { $script:totalInBytes += $file.Length; $script:totalOutBytes += (Get-Item $outAudio).Length } catch {}
		}
		Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name
		return
	}

	if ($create_frame -eq "yes") {
		$frame_dir = "$folder_destination$file_path$file_name"
		$frame_done = "$frame_dir\.frames_complete"
		# Готовность каталога кадров — по маркеру завершения, а не по факту существования:
		# прерванный прогон оставлял частичный каталог, который молча пропускался.
		if ((Test-Path $frame_done) -and $overwrite_existing -ne "yes") {
			$script:countSkip++
			Write-GUIProgress -CurrentFile $file.Name
			return
		}
		if ($dry_run -eq "yes") {
			$_cmdStr = "$ffmpeg -hide_banner -strict -2 -i `"$full_path`" -r 1/1 `"$frame_dir\${file_name}_%05d.png`""
			Write-Host "[DRY-RUN] $_cmdStr"
			Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name -Command $_cmdStr
			return
		}
		# Частичный каталог с прошлого прогона удаляем, чтобы кадры не смешивались.
		if (Test-Path $frame_dir) { Remove-Item $frame_dir -Recurse -Force -ErrorAction SilentlyContinue }
		New-Item -ItemType Directory $frame_dir -Force | Out-Null
		Log-Msg "INFO" "Извлечение кадров: $full_path"
		& $ffmpeg -hide_banner -strict -2 -i $full_path -r 1/1 "$frame_dir\${file_name}_%05d.png"
		if ($LASTEXITCODE -ne 0) {
			Log-Msg "FAIL" "$($file.Name)"
			Remove-Item $frame_dir -Recurse -Force -ErrorAction SilentlyContinue
			$script:countFail++
		} else {
			New-Item -ItemType File $frame_done -Force | Out-Null
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
	# Разделения на части (part.N) коллизию снимают, поэтому сверяем базовое имя.
	if ((Get-CanonPath "$out_base.$current_format_out") -ieq (Get-CanonPath $full_path)) {
		Log-Msg "FAIL" "$($file.Name): выход совпадает с входом — файл пропущен (задайте другой destination, префикс или формат)"
		$script:countFail++
		Write-GUIProgress -CurrentFile $file.Name
		return
	}

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

	# E3. Проверка валидности существующего файла
	# Судим по exit code (как SH/CMD), а не по тексту stderr: ffmpeg с -v error может
	# вывести не-фатальную диагностику для полностью декодируемого файла — тогда
	# непустой stderr ошибочно удалял бы валидный готовый результат.
	# F7. overwrite_existing=yes → готовый файл не считаем финальным и перекодируем с
	# новыми настройками (ffmpeg -y перезапишет). Иначе валидный файл пропускается.
	if ($overwrite_existing -ne "yes") {
		if (Test-Path "$out_base.$current_format_out") {
			& $ffmpeg -v error -i "$out_base.$current_format_out" -f null - 2>&1 | Out-Null
			if ($LASTEXITCODE -eq 0) {
				$script:countSkip++
				Write-GUIProgress -CurrentFile $file.Name
				return
			} else {
				Log-Msg "WARN" "Удаление битого файла: $out_base.$current_format_out"
				Remove-Item "$out_base.$current_format_out" -Force
			}
		}
	}

	# E4 + J1. Один вызов ffmpeg -i для битрейта и длительности (раньше запускались
	# два отдельных pipeline'а на тот же файл — лишняя задержка для больших библиотек).
	$ffmpeg_info = (& $ffmpeg -i $full_path 2>&1 | Out-String)

	$src_bitrate = $null
	$bitrate_match = [regex]::Match($ffmpeg_info, "bitrate:\s+(\d+)\s*kb/s")
	if ($bitrate_match.Success) { $src_bitrate = [int]$bitrate_match.Groups[1].Value }

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

	$fileDuration = 0
	$dur_match = [regex]::Match($ffmpeg_info, "Duration:\s+(\d+):(\d+):(\d+)")
	if ($dur_match.Success) {
		$fileDuration = [int]$dur_match.Groups[1].Value * 3600 + [int]$dur_match.Groups[2].Value * 60 + [int]$dur_match.Groups[3].Value
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
				if ($lineStr -match "silence_start:\s+([\d.]+)") { $silence_start_val = [double]$matches[1] }
				if ($lineStr -match "silence_end:\s+([\d.]+)" -and $null -ne $silence_start_val) {
					$silence_end_val = [double]$matches[1]
					$split_points += [int](($silence_start_val + $silence_end_val) / 2)
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
	if ($num.Count -eq 0) {
		$num = @(0)
		Log-Msg "WARN" "Длительность неизвестна, разбиение пропущено: $($file.Name)"
	}

	if ($start_coding_status -eq "+") { $num = @($start_coding_value) }

	# Готовые выходы копим, чтобы записать manifest одной транзакцией после цикла.
	$produced = @()
	$anyFail = $false

	# F29. Размер входа засчитываем ОДИН раз на исходный файл. Раньше он прибавлялся
	# на КАЖДУЮ часть, поэтому при разбиении на N частей вход суммировался N раз —
	# сводка показывала завышенное сжатие. Выход при этом честно считается по частям.
	$inReported = $false
	$c = 1
	foreach ($b in $num) {
		$pref = ""
		if ($num.Count -gt 1 -or $num[0] -ne 0) { $pref = " (part.$c)" }

		# Сброс из базы — см. _base снимки выше.
		$convert_args = @() + $convert_args_base; $sub_burned = $false
		$current_vf_parts = [System.Collections.ArrayList]@($vf_parts_base)
		$current_af_parts = [System.Collections.ArrayList]@($af_parts_base)

		$current_set_length = $set_length_coding
		if ($split_by_silence -eq "yes" -and $length_coding_status -eq "+") {
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
					if (Test-Path $sub_file) {
						if ($video_subtitles_value -eq "burn") {
							$sub_escaped = $sub_file -replace '\\','/' -replace "'","\'" -replace ':','\:' -replace '\[','\[' -replace '\]','\]' -replace ';','\;' -replace '%','\%'; $sub_burned = $true
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

		# D7. Dry-run
		if ($dry_run -eq "yes") {
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
			$proc.Start() | Out-Null
			$proc.BeginErrorReadLine()

			# Обновляем прогресс в GUI-файл (если GUI) или Write-Progress (если CLI)
			while (!$proc.HasExited) {
				Start-Sleep -Milliseconds 400
				# Проверка отмены
				if ($guiCancelFile -and (Test-Path $guiCancelFile)) {
					try { $proc.Kill() } catch {}
					break
				}
				# Читаем прогресс-файл ffmpeg
				$fpct = 0
				if (Test-Path $progressTempFile) {
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
				$anyFail = $true
				$script:countFail++
				Write-GUIProgress -FilePercent 0 -CurrentFile $file.Name
			} else {
				Move-Item -LiteralPath $out_tmp -Destination $out_file -Force
				Log-Msg "OK" "$($file.Name) -> $(Split-Path $out_file -Leaf) ($elapsedStr)"
				$script:countOk++
				$produced += $out_file
				# F29. Вход — только с первой удавшейся части (см. $inReported выше).
				try {
					if (-not $inReported) { $script:totalInBytes += $file.Length; $inReported = $true }
					$script:totalOutBytes += (Get-Item $out_file).Length
				} catch {}
				Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name
			}
		}
		$c++
	}

	# Manifest пишем только когда удались ВСЕ части. Именно его отсутствие заставит
	# следующий запуск доделать файл, вместо того чтобы принять уцелевшую (part.1) за
	# готовый результат. Частичный успех manifest'а не получает намеренно.
	if ($dry_run -ne "yes" -and -not $anyFail -and $produced.Count -gt 0) {
		Write-Manifest $manifest $full_path $file_sig $produced
	}
}

# --- Основная логика ---
if ($merge_files -eq "yes") {
	if (($format_files_in_list | Measure-Object).Count -eq 0) {
		Log-Msg "WARN" "Нет файлов для объединения в $folder_sources"
	} else {
	$_mergeSorted = $format_files_in_list | Sort-Object FullName  # F10: паритет с .sh sort -z
		$fname = $_mergeSorted[0].Name
	if ($overwrite_existing -eq "yes" -or !(Test-Path "$folder_destination\$fname")) {
		$tmpFile = [System.IO.Path]::GetTempFileName()
		[System.IO.File]::WriteAllLines($tmpFile, ($_mergeSorted.FullName | ForEach-Object { "file '" + ($_ -replace "'", "'\''") + "'" }))
		# Мержим в соседний temp, а не сразу поверх цели. Прежний вызов шёл без -y на
		# существующий файл: ffmpeg спрашивал «File exists. Overwrite? [y/N]» и висел,
		# ожидая stdin, которого в batch/GUI нет. А упавший мерж оставлял partial под
		# именем цели, и следующий запуск принимал его за готовый результат.
		$mergeTarget = "$folder_destination\$fname"
		$mergeTmp = Get-PartialPath $mergeTarget
		if ($dry_run -eq "yes") {
			Write-Host "[DRY-RUN] $ffmpeg -hide_banner -nostdin -strict -2 -f concat -safe 0 -i `"$tmpFile`" -c copy -map 0 -y `"$mergeTmp`""
			Remove-Item $tmpFile -Force
		} else {
			Log-Msg "INFO" "Объединение файлов -> $mergeTarget"
			if (Test-Path -LiteralPath $mergeTmp) { Remove-Item -LiteralPath $mergeTmp -Force -ErrorAction SilentlyContinue }
			& $ffmpeg -hide_banner -nostdin -strict -2 -f concat -safe 0 -i $tmpFile -c copy -map 0 -y $mergeTmp
			$mergeRc = $LASTEXITCODE
			# rc=0 сам по себе не гарантирует читаемый контейнер — валидируем тем же
			# `-f null -`, что и обычные выходные файлы, и только потом подменяем цель.
			$mergeOk = $false
			if ($mergeRc -eq 0 -and (Test-Path -LiteralPath $mergeTmp) -and (Get-FileSize $mergeTmp) -gt 0) {
				& $ffmpeg -nostdin -v error -i $mergeTmp -f null - 2>&1 | Out-Null
				if ($LASTEXITCODE -eq 0) { $mergeOk = $true }
			}
			if ($mergeOk) {
				Move-Item -LiteralPath $mergeTmp -Destination $mergeTarget -Force
				Log-Msg "OK" "Объединение файлов -> $mergeTarget"
				$script:countOk++
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
		if ($guiCancelFile -and (Test-Path $guiCancelFile)) { break }
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
	Write-Host ("  Обработано:  {0} файлов" -f $script:countOk)
	Write-Host ("  Пропущено:   {0} (уже существуют)" -f $script:countSkip)
	Write-Host ("  Ошибки:      {0}" -f $script:countFail)
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
	Read-Host "Нажмите [Enter], чтобы продолжить..."
} else {
	# GUI: записываем финальное состояние. F17. Финал обязан назвать исход явно —
	# GUI не видит наш exit code и по одному «Готово» не отличит провал от успеха.
	if ($guiCancelFile -and (Test-Path $guiCancelFile)) {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Отменено" -State "cancelled" -ExitCode 1 -Message "Отменено пользователем"
	} elseif ($script:countFail -gt 0) {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Ошибки" -State "failed" -ExitCode 1 -Message "Файлов с ошибками: $($script:countFail)"
	} else {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Готово" -State "success" -ExitCode 0
	}
}

# Exit code отражает наличие ошибок — cron/CI могут детектировать провал батча.
if ($script:countFail -gt 0) { exit 1 }
exit 0
