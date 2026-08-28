# ============================================================
# Удалённый бэкенд — клиент службы конвертации (PowerShell)
#
# Подключается из FFmpeg_Converter_script.ps1 и из GUI. Только функции,
# никаких действий при загрузке: так модуль дот-сорсится в тест без сети.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

function Get-RemoteCodec {
	param([string]$Encoder)
	switch -Regex ($Encoder) {
		'^(libx264|h264_nvenc|h264_qsv)$'  { return 'h264' }
		'^(libx265|hevc_nvenc|hevc_qsv)$'  { return 'hevc' }
		'^(libsvtav1|av1_nvenc|av1_qsv)$'  { return 'av1'  }
	}
	return ''
}

function ConvertTo-RemoteJsonString {
	param([string]$Value)
	return $Value.Replace('\', '\\').Replace('"', '\"')
}

# Порядок полей здесь — контракт с .sh, а не вкус: тест паритета сравнивает
# строки целиком. Меняя одну платформу, поменяйте вторую.
function Get-RemoteOpForConfig {
	param([int]$StartSec = 0, [int]$LengthSec = 0)

	$codec = Get-RemoteCodec $set_video_codec
	if (-not $codec) { return $null }

	$op = 'transcode'
	$p = "`"codec`":`"$codec`""

	if ($video_quality_status -eq '+') {
		$p += ",`"quality`":$video_quality_value"
	} elseif ($video_bitrate_status -eq '+') {
		$p += ",`"bitrate`":$([int]$video_bitrate_value * 1000),`"bitrate_cap_source`":true"
	}

	if ($video_resolution_status -eq '+') { $p += ",`"resolution`":`"$video_resolution_value`"" }
	if ($keep_aspect_ratio_value -eq 'yes') { $p += ",`"keep_aspect`":true" } else { $p += ",`"keep_aspect`":false" }
	if ($video_number_frames_status -eq '+') { $p += ",`"fps`":$video_number_frames_value" }
	if ($video_rotation_status -eq '+') { $p += ",`"rotate`":`"$video_rotation_value`"" }
	if ($playback_speed_status -eq '+' -and $playback_speed_value -ne '1.0') {
		$p += ",`"speed`":$playback_speed_value"
	}

	if ($video_subtitles_status -eq '+') {
		$p += ",`"subtitles`":`"$video_subtitles_value`""
		if ($subtitles_style) {
			$p += ",`"subtitle_style`":`"$(ConvertTo-RemoteJsonString $subtitles_style)`""
		}
	}

	$p += ",`"container`":`"$output_container_value`""
	$t = if ($threads) { $threads } else { 4 }
	$p += ",`"threads`":$t"

	if ($gpu_preset_status -eq '+') { $p += ",`"preset`":`"$gpu_preset_value`"" }
	if ($gpu_tune_status -eq '+')   { $p += ",`"tune`":`"$gpu_tune_value`"" }
	if ($gpu_rc_status -eq '+')     { $p += ",`"rc`":`"$gpu_rc_value`"" }

	$a = if ($audio_codec_status -eq '+') { "`"codec`":`"$audio_codec_value`"" } else { "`"codec`":`"copy`"" }
	if ($audio_bitrate_status -eq '+')         { $a += ",`"bitrate`":$audio_bitrate_value" }
	if ($audio_number_channels_status -eq '+') { $a += ",`"channels`":$audio_number_channels_value" }
	if ($audio_sampling_rate_status -eq '+')   { $a += ",`"rate`":$audio_sampling_rate_value" }
	if ($audio_normalize_status -eq '+')       { $a += ",`"normalize`":`"$audio_normalize_value`"" }
	$p += ",`"audio`":{$a}"

	# Отрезок — op: cut, а не op: split: имена part.N и manifest строит клиент.
	if ($StartSec -gt 0 -or $LengthSec -gt 0) {
		$op = 'cut'
		$p = "`"start`":$StartSec,`"reencode`":true," + $p
		if ($LengthSec -gt 0) { $p = "`"end`":$($StartSec + $LengthSec)," + $p }
	}

	return [pscustomobject]@{ Op = $op; Params = "{$p}" }
}

# --- HTTP ---
# Единственная точка выхода в сеть. Тест подменяет ЭТУ функцию — поэтому все
# остальные обязаны ходить только через неё.
#
# Не Invoke-WebRequest: в PowerShell 5.1 он буферизует тело целиком в память,
# и результат на 3 ГБ убил бы процесс.
function Invoke-RemoteHttp {
	param(
		[string]$Method,
		[string]$Path,
		[string]$Body = '',
		[hashtable]$Headers = @{},
		[string]$OutFile = '',
		[string]$InFile = ''
	)
	$req = [System.Net.HttpWebRequest]::Create("$remote_endpoint$Path")
	$req.Method = $Method
	$req.Timeout = 60000
	$req.ReadWriteTimeout = 600000
	$req.Headers.Add('Authorization', "Bearer $remote_api_key")
	foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
	try {
		if ($InFile) {
			$req.ContentType = 'application/octet-stream'
			$bytes = [System.IO.File]::ReadAllBytes($InFile)
			$req.ContentLength = $bytes.Length
			$rs = $req.GetRequestStream()
			$rs.Write($bytes, 0, $bytes.Length); $rs.Close()
		} elseif ($Body) {
			$req.ContentType = 'application/json'
			$bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
			$req.ContentLength = $bytes.Length
			$rs = $req.GetRequestStream()
			$rs.Write($bytes, 0, $bytes.Length); $rs.Close()
		}
		$resp = $req.GetResponse()
		$code = [int]$resp.StatusCode
		if ($OutFile) {
			# Потоком в файл: тело может быть в гигабайты.
			$src = $resp.GetResponseStream()
			$dst = [System.IO.File]::Create($OutFile)
			try { $src.CopyTo($dst, 1048576) } finally { $dst.Dispose(); $src.Dispose() }
			$text = ''
		} else {
			$sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
			$text = $sr.ReadToEnd(); $sr.Dispose()
		}
		$resp.Close()
		return [pscustomobject]@{ Code = $code; Body = $text }
	} catch [System.Net.WebException] {
		$code = 0
		$text = ''
		if ($_.Exception.Response) {
			$code = [int]$_.Exception.Response.StatusCode
			try {
				$sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
				$text = $sr.ReadToEnd(); $sr.Dispose()
			} catch {}
		}
		return [pscustomobject]@{ Code = $code; Body = $text }
	}
}

function Invoke-RemotePreflight {
	if (-not $remote_endpoint) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте переменную окружения TRANSCODE_URL."
		return $false
	}
	if (-not $remote_api_key) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте переменную окружения TRANSCODE_API_KEY."
		return $false
	}
	$r = Invoke-RemoteHttp GET '/capabilities'
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Служба конвертации недоступна: HTTP $($r.Code)."
		return $false
	}
	$caps = $r.Body | ConvertFrom-Json
	$script:RemoteChunkSize = if ($caps.chunk_size) { [int]$caps.chunk_size } else { 33554432 }
	$script:RemoteArgsVersion = $caps.args_version
	return $true
}

# Возобновляемость — не удобство, а условие работоспособности: файлы от
# гигабайта, и одна POST-загрузка на 20 ГБ рвётся и начинается заново.
function Send-RemoteUpload {
	param([string]$Path)
	$size = (Get-Item -LiteralPath $Path).Length
	$r = Invoke-RemoteHttp POST '/uploads'
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не приняла загрузку: HTTP $($r.Code)."; return $null }
	$u = $r.Body | ConvertFrom-Json
	$uid = $u.upload_id
	if ($u.chunk_size) { $script:RemoteChunkSize = [int]$u.chunk_size }
	$chunk = $script:RemoteChunkSize
	if (-not $chunk) { $chunk = 33554432 }

	$offset = [int64]0
	$r = Invoke-RemoteHttp GET "/uploads/$uid"
	if ($r.Code -eq 200) { $offset = [int64](($r.Body | ConvertFrom-Json).received) }

	$tmp = [System.IO.Path]::GetTempFileName()
	$fs = [System.IO.File]::OpenRead($Path)
	try {
		while ($offset -lt $size) {
			# Имя $take, а не $this: $this в PowerShell зарезервировано за текущим
			# объектом в блоках-методах, и присваивание ему читается как ошибка.
			$take = [int][Math]::Min([int64]$chunk, $size - $offset)
			$buf = New-Object byte[] $take
			$fs.Seek($offset, 'Begin') | Out-Null
			$fs.Read($buf, 0, $take) | Out-Null
			[System.IO.File]::WriteAllBytes($tmp, $buf)
			$r = Invoke-RemoteHttp PATCH "/uploads/$uid" '' `
				@{ 'Content-Range' = "bytes $offset-$($offset + $take - 1)/$size" } '' $tmp
			if ($r.Code -ne 200) {
				Write-Host "[ОШИБКА] Служба отвергла кусок $offset : HTTP $($r.Code)."
				return $null
			}
			$offset += $take
			Write-RemoteUploadProgress $offset $size
		}
	} finally { $fs.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

	$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
	$r = Invoke-RemoteHttp POST "/uploads/$uid/complete" "{`"size`":$size,`"sha256`":`"$sha`"}"
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не подтвердила загрузку: HTTP $($r.Code)."; return $null }
	return $uid
}

# Тело задачи собирается в одном месте: боевой путь и холостой прогон обязаны
# отправлять одинаковое тело, иначе сверка планов проверяет не то, что поедет.
function Get-RemoteJobBody {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '', [string]$Extra = '')
	$p = $Params
	if ($SubtitleId) { $p = $p.Substring(0, $p.Length - 1) + ",`"subtitle_upload_id`":`"$SubtitleId`"}" }
	$b = "{`"upload_id`":`"$UploadId`",`"op`":`"$Op`",`"params`":$p"
	$pref = if ($remote_prefer) { $remote_prefer } else { 'auto' }
	$wt   = if ($remote_wait_timeout) { $remote_wait_timeout } else { 1800 }
	$b += ",`"prefer`":`"$pref`",`"wait_timeout`":$wt"
	# overwrite_existing = yes обязан отключить дедупликацию службы: иначе
	# «перезаписать заново» вернуло бы прежний результат с reused: true.
	if ($overwrite_existing -eq 'yes') { $b += ",`"no_reuse`":true" }
	if ($Extra) { $b += ",$Extra" }
	return "$b}"
}

function Submit-RemoteJob {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '')
	$r = Invoke-RemoteHttp POST '/jobs' (Get-RemoteJobBody $UploadId $Op $Params $SubtitleId)
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба отвергла задачу: HTTP $($r.Code) — $($r.Body)"; return $null }
	return ($r.Body | ConvertFrom-Json).job_id
}

function Invoke-RemoteDryRun {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '')
	$r = Invoke-RemoteHttp POST '/jobs' (Get-RemoteJobBody $UploadId $Op $Params $SubtitleId '"dry_run":true')
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Холостой прогон отвергнут: HTTP $($r.Code) — $($r.Body)"; return $false }
	# Печатаем ПЛАН целиком, а не одну команду: длинный файл служба режет,
	# кодирует посегментно, склеивает и отдельным проходом обрабатывает звук.
	Write-Host "[DRY-RUN][REMOTE] $($r.Body)"
	return $true
}

function Wait-RemoteJob {
	param([string]$JobId, [string]$Label, [scriptblock]$OnProgress = $null)
	$script:RemoteCurrentJob = $JobId
	while ($true) {
		$r = Invoke-RemoteHttp GET "/jobs/$JobId"
		if ($r.Code -ne 200) {
			Write-Host "[ОШИБКА] Состояние задачи недоступно: HTTP $($r.Code)."
			$script:RemoteCurrentJob = ''; return $false
		}
		$j = $r.Body | ConvertFrom-Json
		switch ($j.state) {
			'done'      { if ($OnProgress) { & $OnProgress 100 $Label }; $script:RemoteCurrentJob = ''; return $true }
			'failed'    { Write-Host "[ОШИБКА] Задача провалена: $($j.error)"; $script:RemoteCurrentJob = ''; return $false }
			'cancelled' { Write-Host "[ОШИБКА] Задача отменена."; $script:RemoteCurrentJob = ''; return $false }
			'waiting_gpu' {
				# Ожидание без объяснения неотличимо от зависания.
				Write-Host ("  ожидание карты: {0} с, не хватает {1} МиБ" -f $j.waiting_seconds, $j.missing_mib)
			}
			default { if ($OnProgress) { & $OnProgress ([int]$j.progress) $Label } }
		}
		Start-Sleep -Seconds $(if ($env:REMOTE_POLL_SECONDS) { [int]$env:REMOTE_POLL_SECONDS } else { 2 })
	}
}

function Receive-RemoteResult {
	param([string]$JobId, [string]$Destination)
	$r = Invoke-RemoteHttp GET "/jobs/$JobId/result" '' @{} $Destination
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Результат недоступен: HTTP $($r.Code)."
		Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
		return $false
	}
	return $true
}

# Брошенная задача продолжит держать карту, ради вежливости к которой служба
# и построена. Поэтому DELETE шлём даже когда уходим по прерыванию.
function Stop-RemoteJob {
	param([string]$JobId)
	if (-not $JobId) { return }
	Invoke-RemoteHttp DELETE "/jobs/$JobId" | Out-Null
}

# Прогресс загрузки. В GUI переопределяется — см. FFmpeg_Converter_script.ps1.
if (-not (Get-Command Write-RemoteUploadProgress -ErrorAction SilentlyContinue)) {
	function Write-RemoteUploadProgress {
		param([int64]$Done, [int64]$Total)
		if ($Total -gt 0) {
			Write-Progress -Activity "Отправка на сервер" -PercentComplete ([int]($Done * 100 / $Total))
		}
	}
}
