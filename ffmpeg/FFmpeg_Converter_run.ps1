# ============================================================
# FFmpeg Converter — Конфигурация (PowerShell)
# ============================================================

$configFile = Join-Path $PSScriptRoot "config.ini"

# --- Авто-определение ffmpeg рядом со скриптом ---
$ffmpeg = if (Test-Path "$PSScriptRoot\ffmpeg.exe") { "$PSScriptRoot\ffmpeg.exe" } else { "ffmpeg" }

# --- Чтение config.ini ---
function Read-Config {
	param([string]$Key, [string]$Section, [string]$Default = "")
	if (-not (Test-Path $configFile)) { return $Default }
	$inSection = $false
	foreach ($line in (Get-Content $configFile -Encoding UTF8)) {
		$line = $line.Trim()
		if ([string]::IsNullOrEmpty($line) -or $line.StartsWith("#")) { continue }
		if ($line -match '^\[([^\]]+)\]$') {
			$inSection = ($Matches[1] -eq $Section)
			continue
		}
		if ($inSection -and $line -match "^${Key}\s*=\s*(.*)") {
			$val = $Matches[1] -replace '\s*#.*', ''
			return $val.Trim()
		}
	}
	return $Default
}

# Конвертирует формат config.ini (+value / -value) в формат скрипта (:+:value / :-:value)
function To-Flag {
	param([string]$Val, [string]$Default)
	if (-not $Val) { return $Default }
	$first = $Val[0]
	$rest = $Val.Substring(1)
	switch ($first) {
		'+' { return ":+:$rest" }
		'-' { return ":-:$rest" }
		default { return ":+:$Val" }
	}
}

# --- Загрузка настроек из config.ini ---
$folder_sources      = Read-Config "source"      "folders" "m:\ffmpeg\0"
$folder_destination  = Read-Config "destination"  "folders" "m:\ffmpeg\1"
if (-not [System.IO.Path]::IsPathRooted($folder_sources))     { $folder_sources     = Join-Path $PSScriptRoot $folder_sources }
if (-not [System.IO.Path]::IsPathRooted($folder_destination)) { $folder_destination = Join-Path $PSScriptRoot $folder_destination }

$audio_only          = Read-Config "audio_only"          "options" "no"
$merge_files         = Read-Config "merge_files"         "options" "no"
$create_frame        = Read-Config "create_frame"        "options" "no"
$copy_codecs         = Read-Config "copy_codecs"         "options" "no"
$extract_audio_copy  = Read-Config "extract_audio_copy"  "options" "no"

$audio_codec             = To-Flag (Read-Config "codec"         "audio" "+aac")       ":+:aac"
$audio_number_channels   = To-Flag (Read-Config "channels"      "audio" "+2")         ":+:2"
$audio_bitrate           = To-Flag (Read-Config "bitrate"       "audio" "+128")       ":+:128"
$audio_sampling_rate     = To-Flag (Read-Config "sampling_rate" "audio" "+48000")     ":+:48000"
$audio_normalize         = To-Flag (Read-Config "normalize"     "audio" "-loudnorm")  ":-:loudnorm"

$video_codec         = To-Flag (Read-Config "codec"            "video" "+libx264")   ":+:libx264"
$video_resolution    = To-Flag (Read-Config "resolution"       "video" "+1280x720")  ":+:1280x720"
$video_bitrate       = To-Flag (Read-Config "bitrate"          "video" "-3000")      ":-:3000"
$video_number_frames = To-Flag (Read-Config "framerate"        "video" "+30")        ":+:30"
$video_rotation      = To-Flag (Read-Config "rotation"         "video" "-2")         ":-:2"
$video_subtitles     = To-Flag (Read-Config "subtitles"        "video" "-burn")      ":-:burn"
$video_quality       = To-Flag (Read-Config "quality"          "video" "-23")        ":-:23"
$keep_aspect_ratio   = To-Flag (Read-Config "keep_aspect_ratio" "video" "+yes")      ":+:yes"
$output_container    = To-Flag (Read-Config "container"        "video" "+mp4")       ":+:mp4"

$multithreads    = To-Flag (Read-Config "threads"        "performance" "+4") ":+:4"
$parallel_files  = To-Flag (Read-Config "parallel_files" "performance" "-2") ":-:2"

$hw_accel   = To-Flag (Read-Config "hw_accel" "gpu" "-nvidia") ":-:nvidia"
$gpu_preset = To-Flag (Read-Config "preset"   "gpu" "-p5")     ":-:p5"
$gpu_tune   = To-Flag (Read-Config "tune"     "gpu" "-hq")     ":-:hq"
$gpu_rc     = To-Flag (Read-Config "rc"       "gpu" "-vbr")    ":-:vbr"

$playback_speed = To-Flag (Read-Config "playback_speed" "speed" "-1.0") ":-:1.0"

$start_coding    = To-Flag (Read-Config "start"  "split" "-01-00-00") ":-:01-00-00"
$length_coding   = To-Flag (Read-Config "length" "split" "-00-05-00") ":-:00-05-00"
$split_by_silence  = Read-Config "split_by_silence"  "split" "no"
$silence_duration  = Read-Config "silence_duration"  "split" "2.0"
$silence_threshold = Read-Config "silence_threshold" "split" "-30dB"

$save_old_extension = Read-Config "save_old_extension" "other" "no"
$format_files_in    = Read-Config "format_files_in"    "other" "3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
$subtitles_style    = Read-Config "subtitles_style"    "other" "FontName=Arial:FontSize=24:PrimaryColour=&HFFFFFF&"
$dry_run            = Read-Config "dry_run"            "other" "no"
$enable_log         = Read-Config "enable_log"         "other" "no"
$log_file           = Read-Config "log_file"           "other" "ffmpeg_convert.log"

# start coding
. "$PSScriptRoot\FFmpeg_Converter_script.ps1"
