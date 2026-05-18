# ============================================================
# FFmpeg Converter Script (PowerShell)
# ============================================================

# Перехват всех ошибок (не даёт исключениям выйти из Runspace в ps2exe)
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
if ($hw_accel_status -eq "+") {
	$encoders_list = & $ffmpeg -encoders 2>&1 | Out-String
	switch ($hw_accel_value) {
		"nvidia" {
			if ($encoders_list -match "nvenc") {
				$use_hw_accel = $true
				$hw_accel_type = "nvidia"
				$hw_decode_args = @("-hwaccel", "cuda", "-hwaccel_output_format", "cuda")
				switch ($set_video_codec) {
					"libx264"   { $set_video_codec = "h264_nvenc" }
					"libx265"   { $set_video_codec = "hevc_nvenc" }
					"libsvtav1" { $set_video_codec = "av1_nvenc" }
				}
			} else {
				Write-Host "[ПРЕДУПРЕЖДЕНИЕ] NVENC не поддерживается данной сборкой ffmpeg."
			}
		}
		"intel" {
			if ($encoders_list -match "qsv") {
				$use_hw_accel = $true
				$hw_accel_type = "intel"
				$hw_decode_args = @("-hwaccel", "qsv", "-hwaccel_output_format", "qsv")
				switch ($set_video_codec) {
					"libx264"   { $set_video_codec = "h264_qsv" }
					"libx265"   { $set_video_codec = "hevc_qsv" }
					"libsvtav1" { $set_video_codec = "av1_qsv" }
				}
			} else {
				Write-Host "[ПРЕДУПРЕЖДЕНИЕ] QSV не поддерживается данной сборкой ffmpeg."
			}
		}
	}
}

# --- Время начала и длительности ---
$_, $start_coding_status, $start_coding_value = $start_coding -split ":"
if ($start_coding_status -eq "+") {
	$x, $y, $z = $start_coding_value -split '-'
	$start_coding_value = [int]$x * 3600 + [int]$y * 60 + [int]$z
	$set_start_coding = "-ss $start_coding_value"
} else {
	$set_start_coding = ""
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
if ($audio_only -eq "yes") {
	$format_files_out = "mp3"
	$video_settings_args = @("-vn")
	$set_audio_codec = "-c:a libmp3lame"
} else {
	# D3. Выходной контейнер
	if ($output_container_status -eq "+") {
		$format_files_out = $output_container_value
	} else {
		$format_files_out = "mp4"
	}

	# E5. Сборка цепочки видео-фильтров
	$vf_parts = @()

	# Поворот
	if ($video_rotation_status -eq "+") {
		if ($hw_accel_type -eq "nvidia") {
			$vf_parts += "transpose_cuda=$video_rotation_value"
		} else {
			$vf_parts += "transpose=$video_rotation_value"
		}
	}

	# D4. Масштабирование с сохранением пропорций
	if ($set_video_resolution) {
		$res_w, $res_h = $set_video_resolution -split 'x'
		if ($keep_aspect_ratio_status -eq "+" -and $keep_aspect_ratio_value -eq "yes") {
			switch ($hw_accel_type) {
				"nvidia" { $vf_parts += "scale_cuda=${res_w}:${res_h}:force_original_aspect_ratio=decrease" }
				"intel"  { $vf_parts += "scale_qsv=${res_w}:${res_h}:force_original_aspect_ratio=decrease" }
				default  { $vf_parts += "scale=${res_w}:${res_h}:force_original_aspect_ratio=decrease,pad=${res_w}:${res_h}:(ow-iw)/2:(oh-ih)/2" }
			}
		} else {
			switch ($hw_accel_type) {
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
		$needs_download = $vf_parts | Where-Object { $_ -notmatch 'scale_cuda|scale_qsv|transpose_cuda|setpts' }
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
			if ($video_quality_status -eq "+") { $gpu_args += @("-cq", $video_quality_value) }
		}
		elseif ($hw_accel_type -eq "intel") {
			if ($video_quality_status -eq "+") { $gpu_args += @("-global_quality", $video_quality_value) }
		}
	}

	# CRF для программных кодеков
	$crf_args = @()
	if (-not $use_hw_accel -and $video_quality_status -eq "+") {
		$crf_args = @("-crf", $video_quality_value)
	}

	$video_settings_args = @("-f", $format_files_out)
	if ($set_video_codec_arg) { $video_settings_args += $set_video_codec_arg -split ' ' }
	if ($set_video_number_frames) { $video_settings_args += $set_video_number_frames -split ' ' }
	$video_settings_args += $gpu_args
	$video_settings_args += $crf_args
}

# D6. Скорость воспроизведения (аудио)
$af_parts = @()
if ($playback_speed_status -eq "+" -and $playback_speed_value -ne "1.0") {
	$speed = [double]$playback_speed_value
	if ($speed -gt 2.0) {
		$remaining = $speed
		while ($remaining -gt 2.0) {
			$af_parts += "atempo=2.0"
			$remaining = $remaining / 2.0
		}
		$af_parts += "atempo=$remaining"
	} elseif ($speed -lt 0.5) {
		$remaining = $speed
		while ($remaining -lt 0.5) {
			$af_parts += "atempo=0.5"
			$remaining = $remaining / 0.5
		}
		$af_parts += "atempo=$remaining"
	} else {
		$af_parts += "atempo=$speed"
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
	param([int]$FilePercent = 0, [string]$CurrentFile = "", [string]$Command = "")
	if (-not $guiProgressFile) { return }
	if ($Command) { $script:_lastCommand = $Command }
	$totalPct = if ($script:totalFiles -gt 0) { [int](($script:fileNum - 1 + $FilePercent / 100) * 100 / $script:totalFiles) } else { 0 }
	$data = [ordered]@{
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
	$file_name = $file.BaseName
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
		if (!(Test-Path "$folder_destination$file_path$file_name")) {
			New-Item -ItemType Directory "$folder_destination$file_path$file_name" | Out-Null
			Log-Msg "INFO" "Извлечение кадров: $full_path"
			& $ffmpeg -hide_banner -strict -2 -i $full_path -r 1/1 "$folder_destination$file_path$file_name\${file_name}_%05d.png"
		}
		return
	}

	$current_format_out = $format_files_out
	$out_base = "$folder_destination$file_path$file_name"

	# E3. Проверка валидности существующего файла
	if (Test-Path "$out_base.$current_format_out") {
		$check = & $ffmpeg -v error -i "$out_base.$current_format_out" -f null - 2>&1
		if (-not $check) {
			$script:countSkip++
			Write-GUIProgress -CurrentFile $file.Name
			return
		} else {
			Log-Msg "WARN" "Удаление битого файла: $out_base.$current_format_out"
			Remove-Item "$out_base.$current_format_out" -Force
		}
	}
	if (Test-Path "$out_base (part.1).$current_format_out") {
		$script:countSkip++
		Write-GUIProgress -CurrentFile $file.Name
		return
	}

	# E4. Получение битрейта
	$src_bitrate = $null
	$bitrate_match = [regex]::Match((& $ffmpeg -i $full_path 2>&1 | Out-String), "bitrate:\s+(\d+)\s*kb/s")
	if ($bitrate_match.Success) { $src_bitrate = [int]$bitrate_match.Groups[1].Value }

	$set_video_bitrate_final = @()
	if ($video_bitrate_status -eq "+" -and $video_quality_status -ne "+") {
		if ($src_bitrate -and $src_bitrate -lt [int]$set_video_bitrate_orig) {
			$set_video_bitrate_final = @("-b:v", "${src_bitrate}k")
		} else {
			$set_video_bitrate_final = @("-b:v", "${set_video_bitrate_orig}k")
		}
	}

	$convert_args = @()
	if ($copy_codecs -eq "yes") {
		$convert_args = @("-c", "copy", "-map", "0")
		$current_format_out = $file.Extension.TrimStart('.')
	} else {
		$convert_args += $video_settings_args
		$convert_args += $set_video_bitrate_final
		$convert_args += $audio_settings_args
	}

	# --- J1. Получение длительности (для прогресс-бара и split) ---
	$fileDuration = 0
	$dur_match = [regex]::Match((& $ffmpeg -i $full_path 2>&1 | Out-String), "Duration:\s+(\d+):(\d+):(\d+)")
	if ($dur_match.Success) {
		$fileDuration = [int]$dur_match.Groups[1].Value * 3600 + [int]$dur_match.Groups[2].Value * 60 + [int]$dur_match.Groups[3].Value
	}

	# Видео/аудио фильтры для текущего файла
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

		$num = @()
		$length_values = @{}
		$length_silent_values = @{}
		for ($i = 0; $i -le 999; $i++) {
			$lcv = if ($i -eq 0) { 0 } else { $length_coding_value * $i }
			$length_values[$i] = $lcv
			if ($duration -gt $lcv) {
				$part_start = $lcv
				if ($split_by_silence -eq "yes" -and $split_points.Count -gt 0) {
					$best_point = $part_start
					$best_diff = 999999
					foreach ($p in $split_points) {
						$d = [Math]::Abs($p - $part_start)
						if ($d -lt $best_diff) { $best_diff = $d; $best_point = $p }
					}
					$half_length = [int]($length_coding_value / 2)
					if ($best_diff -le $half_length) { $new_part_start = $best_point } else { $new_part_start = $part_start }
					$num += $new_part_start
					$length_silent_values[$i] = $length_coding_value - ($part_start - $new_part_start)
					$length_values[$i] = $new_part_start
				} else {
					$num += $part_start
				}
			} else { break }
		}
	} else {
		$num = @(0)
	}

	if ($start_coding_status -eq "+") { $num = @($start_coding_value) }

	$c = 1
	foreach ($b in $num) {
		$pref = ""
		if ($num.Count -gt 1 -or $num[0] -ne 0) { $pref = " (part.$c)" }

		$current_set_length = $set_length_coding
		if ($split_by_silence -eq "yes" -and $length_coding_status -eq "+") {
			$silent_idx = $c - 1
			if ($length_silent_values.ContainsKey($silent_idx)) {
				$current_set_length = "-t $($length_silent_values[$silent_idx])"
			}
		}

		# B2. Субтитры с subtitles_style
		$subtitles_args = @()
		if ($video_subtitles_status -eq "+" -and $copy_codecs -ne "yes") {
			$sub_found = $false
			foreach ($ext in @("srt", "vtt")) {
				if (-not $sub_found) {
					$sub_file = "$folder_sources$file_path$file_name.$ext"
					if (Test-Path $sub_file) {
						if ($video_subtitles_value -eq "burn") {
							$sub_escaped = $sub_file -replace '\\', '\\\\' -replace "'", "\\\'" -replace ":", "\:"
							if ($subtitles_style) {
								$current_vf_parts.Add("subtitles='${sub_escaped}':force_style='${subtitles_style}'") | Out-Null
							} else {
								$current_vf_parts.Add("subtitles='${sub_escaped}'") | Out-Null
							}
						}
						if ($video_subtitles_value -eq "meta") {
							$subtitles_args = @("-i", $sub_file, "-c:s", "mov_text", "-metadata:s:s:0", "language=rus")
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

		# Сборка аргументов (A5 — без Split, через массив).
		# -ss располагается ДО -i: fast seek по контейнеру вместо декодирования от 0.
		$ffmpegArgs = @("-hide_banner", "-strict", "-2")
		$ffmpegArgs += $hw_decode_args
		if ($b -ne 0 -or $set_start_coding) { $ffmpegArgs += @("-ss", "$b") }
		$ffmpegArgs += @("-i", $full_path)
		$ffmpegArgs += $subtitles_args
		$ffmpegArgs += $convert_args
		$ffmpegArgs += $thread_args
		$ffmpegArgs += $vf_args
		$ffmpegArgs += $af_args
		if ($current_set_length) { $ffmpegArgs += $current_set_length -split ' ' }
		$ffmpegArgs += @($out_file, "-y")
		$ffmpegArgs = $ffmpegArgs | Where-Object { $_ -ne "" -and $_ -ne $null }

		# D7. Dry-run
		if ($dry_run -eq "yes") {
			Write-Host "[DRY-RUN] $ffmpeg $($ffmpegArgs -join ' ')"
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
			$proc.StartInfo.CreateNoWindow = $false
			# Аргументы передаём как строку с экранированием
			$proc.StartInfo.Arguments = ($ffmpegArgsWithProgress | ForEach-Object {
				if ($_ -match '[ "\\]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
			}) -join " "
			$proc.Start() | Out-Null

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
				try {
					if (Test-Path $progressTempFile) {
						$fs = [System.IO.FileStream]::new($progressTempFile, 'Open', 'Read', 'ReadWrite')
						$sr = [System.IO.StreamReader]::new($fs)
						$fc = $sr.ReadToEnd()
						$sr.Close()
						$m = [regex]::Matches($fc, "out_time=(\d+):(\d+):(\d+)")
						if ($m.Count -gt 0 -and $fileDuration -gt 0) {
							$last = $m[$m.Count - 1]
							$outSec = [int]$last.Groups[1].Value * 3600 + [int]$last.Groups[2].Value * 60 + [int]$last.Groups[3].Value
							$fpct = [int]($outSec / $fileDuration * 100)
							$fpct = [Math]::Min($fpct, 99)
						}
					}
				} catch {}

				if ($guiProgressFile) {
					Write-GUIProgress -FilePercent $fpct -CurrentFile $file.Name
				} else {
					# CLI: Write-Progress
					Write-Progress -Activity "Кодирование" -Status $file.Name -PercentComplete $fpct
				}
			}

			if (!$proc.HasExited) { $proc.WaitForExit() }
			$exitCode = $proc.ExitCode
			Remove-Item $progressTempFile -Force -ErrorAction SilentlyContinue
			if (-not $guiProgressFile) { Write-Progress -Activity "Кодирование" -Completed }

			$elapsed = (Get-Date) - $startTime
			$elapsedStr = "{0}m {1}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

			# E2. Обработка ошибок
			if ($exitCode -ne 0) {
				Log-Msg "FAIL" "$($file.Name) (exit code $exitCode, $elapsedStr)"
				# Ждём освобождения файла после Kill
				Start-Sleep -Milliseconds 500
				if (Test-Path $out_file) { Remove-Item $out_file -Force -ErrorAction SilentlyContinue }
				$script:countFail++
				Write-GUIProgress -FilePercent 0 -CurrentFile $file.Name
			} else {
				Log-Msg "OK" "$($file.Name) -> $(Split-Path $out_file -Leaf) ($elapsedStr)"
				$script:countOk++
				try { $script:totalInBytes += $file.Length; $script:totalOutBytes += (Get-Item $out_file).Length } catch {}
				Write-GUIProgress -FilePercent 100 -CurrentFile $file.Name
			}
		}
		$c++
	}
}

# --- Основная логика ---
if ($merge_files -eq "yes") {
	$fname = $format_files_in_list[0].Name
	if (!(Test-Path "$folder_destination\$fname")) {
		$tmpFile = [System.IO.Path]::GetTempFileName()
		[System.IO.File]::WriteAllLines($tmpFile, ($format_files_in_list.FullName | ForEach-Object { "file '$_'" }))
		Log-Msg "INFO" "Объединение файлов -> $folder_destination\$fname"
		& $ffmpeg -hide_banner -strict -2 -f concat -safe 0 -i $tmpFile -c copy -map 0 "$folder_destination\$fname"
		if ($LASTEXITCODE -ne 0) {
			Log-Msg "FAIL" "Объединение файлов"
			$script:countFail++
		} else {
			Log-Msg "OK" "Объединение файлов -> $folder_destination\$fname"
			$script:countOk++
		}
		Remove-Item $tmpFile -Force
	}
} else {
	# B1b. Последовательная обработка файлов
	# Параллельная обработка через ForEach-Object -Parallel требует полной передачи
	# всех переменных и функций через $using:, что несовместимо с текущей архитектурой
	# (Encode-File использует $script:-переменные). Используется последовательная обработка.
	foreach ($file in $format_files_in_list) {
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
	# GUI: записываем финальное состояние
	Write-GUIProgress -FilePercent 100 -CurrentFile "Готово"
}

exit
