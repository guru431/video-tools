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

# Нормализация адреса: trim пробелов + снять ВСЕ хвостовые слэши. Двойник
# remote_normalize_endpoint из .sh; их равенство сверяет test_23_remote_parity.
# Раньше нормализация жила в трёх местах в трёх разных формах, и один и тот же
# config.ini давал «…/v1//jobs» из CLI и «…/v1/jobs» из GUI.
function Format-RemoteEndpoint {
	param([string]$Value)
	if (-not $Value) { return '' }
	return $Value.Trim().TrimEnd('/')
}

# Ключ службы из внешнего источника. Приоритет: api_key_command → api_key.
# config.ini не коммитится, но остаётся в бэкапах и синхронизируемых папках, а
# переменная окружения видна всему дереву процессов. Выполняется ОДИН раз, в
# preflight: менеджер паролей может спросить пароль.
function Resolve-RemoteApiKey {
	if (-not $remote_api_key_command) { return $true }
	try {
		$out = & ([scriptblock]::Create($remote_api_key_command)) 2>$null
	} catch {
		Write-Host "[ОШИБКА] [remote] api_key_command завершилась с ошибкой — ключ не получен."
		return $false
	}
	$val = (@($out) | Where-Object { $_ } | Select-Object -First 1)
	if ($val) { $val = ([string]$val).Trim() }
	if (-not $val) {
		Write-Host "[ОШИБКА] [remote] api_key_command ничего не напечатала — ключ не получен."
		return $false
	}
	$script:remote_api_key = $val
	return $true
}

# Служба перечисляет ЭНКОДЕРЫ (h264_nvenc, libx264, …), а мы отправляем
# СЕМЕЙСТВО (h264). Поэтому сверка по семейству: наличие h264_nvenc означает,
# что h264 служба посчитает. Литеральная сверка противоречила бы самому
# отображению Get-RemoteCodec, ради которого оно и заведено.
function Test-RemoteCodecSupported {
	param([string]$Family, $Encoders)
	if (-not $Encoders -or @($Encoders).Count -eq 0) { return $true }
	foreach ($e in @($Encoders)) {
		$n = [string]$e
		if ($n -eq $Family -or $n.StartsWith("$Family" + '_')) { return $true }
		switch ($Family) {
			'h264' { if ($n -match 'x264') { return $true } }
			'hevc' { if ($n -match 'x265') { return $true } }
			'av1'  { if ($n -match 'av1')  { return $true } }
		}
	}
	return $false
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

# Уезжает только то, где выигрывает карта. remux, concat, frames, audio и
# extract_audio служба умеет, но карта в них не участвует: гнать гигабайты по
# сети ради `-c copy` заведомо хуже локального прогона. Молчать нельзя —
# режим, который тихо не уехал, неотличим от сломанного удалённого пути.
#
# Два разных «нет» обязаны различаться, поэтому кроме $script:remote_active
# выставляется $script:remote_fatal: локальный по замыслу режим — это работа,
# а отказ preflight — это конец прогона. Слей их, и запуск с пустым ключом
# тихо ушёл бы на локальный процессор — тот самый молчаливый откат, которого
# в этом проекте нет.
function Set-RemoteActive {
	$script:remote_active = 'no'
	$script:remote_fatal = $false
	if ($remote_enabled -ne 'yes') { return $false }
	if ($merge_files -eq 'yes' -or $extract_audio_copy -eq 'yes' -or
	    $create_frame -eq 'yes' -or $copy_codecs -eq 'yes' -or $audio_only -eq 'yes') {
		Write-Host "[ИНФО] Удалённый бэкенд не используется в этом режиме (карта в нём не участвует) — считаем локально"
		return $false
	}
	if (-not (Invoke-RemotePreflight)) { $script:remote_fatal = $true; return $false }
	if ($hw_accel_status -eq '+' -and $hw_accel_value -eq 'intel') {
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] hw_accel = intel: Intel-карты на сервере нет, служба посчитает на процессоре."
	}
	$script:remote_active = 'yes'
	return $true
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
	$script:remote_endpoint = Format-RemoteEndpoint $remote_endpoint
	if (-not $remote_endpoint) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте [remote] endpoint в config.ini (или переменную окружения TRANSCODE_URL)."
		return $false
	}
	if (-not (Resolve-RemoteApiKey)) { return $false }
	if (-not $remote_api_key) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте [remote] api_key (или api_key_command) в config.ini, либо переменную окружения TRANSCODE_API_KEY."
		return $false
	}
	# Версия API живёт В АДРЕСЕ: клиент собирает "<endpoint>/capabilities", а
	# служба слушает /v1/capabilities. Адрес без /vN даёт 404 на первом запросе,
	# и «HTTP 404» человеку ничего не объясняет. Предупреждение, а не отказ: за
	# обратным прокси префикс может добавляться на стороне сервера.
	if ($remote_endpoint -notmatch '/v\d+$') {
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Адрес службы «$remote_endpoint» не оканчивается версией API (/v1). Клиент запрашивает «$remote_endpoint/capabilities», а служба слушает «/v1/capabilities» — вероятен HTTP 404."
	}
	$r = Invoke-RemoteHttp GET '/capabilities'
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Служба конвертации недоступна: HTTP $($r.Code) (запрошено $remote_endpoint/capabilities)."
		if ($r.Code -eq 404) {
			Write-Host "[ОШИБКА] 404 на /capabilities обычно означает адрес без версии API: проверьте, что [remote] endpoint оканчивается на /v1."
		}
		return $false
	}
	$caps = $r.Body | ConvertFrom-Json
	$script:RemoteChunkSize = if ($caps.chunk_size) { [int]$caps.chunk_size } else { 33554432 }
	$script:RemoteArgsVersion = $caps.args_version
	$script:RemoteEncoders = $caps.encoders
	# Энкодер — здесь, а не на каждом файле: отказать на сотом файле из двухсот
	# дороже, чем на нулевом. Раньше список encoders игнорировался вовсе.
	$family = Get-RemoteCodec $set_video_codec
	if (-not $family) {
		Write-Host "[ОШИБКА] Кодек «$set_video_codec» удалённой службе неизвестен (ожидаются h264/hevc/av1-энкодеры)."
		return $false
	}
	if (-not (Test-RemoteCodecSupported $family $caps.encoders)) {
		Write-Host "[ОШИБКА] Служба не умеет кодек «$family» (из [video] codec = $set_video_codec). Служба объявила: $($caps.encoders -join ', ')"
		return $false
	}
	return $true
}

# Сохранённый идентификатор загрузки: без него докачка недостижима в принципе —
# каждый вызов начинался с POST /uploads, то есть просил НОВУЮ загрузку, и
# GET /uploads/<свежий id> честно отвечал received: 0. Путь задаёт вызывающий
# ($script:RemoteUploadSidecar, рядом с manifest'ом).
$script:RemoteUploadSidecar = ''
function Read-RemoteUploadSidecar {
	param([string]$Source, [int64]$Size)
	$f = $script:RemoteUploadSidecar
	if (-not $f -or -not (Test-Path -LiteralPath $f)) { return '' }
	$map = @{}
	foreach ($line in [System.IO.File]::ReadAllLines($f)) {
		$i = $line.IndexOf('=')
		if ($i -gt 0) { $map[$line.Substring(0, $i)] = $line.Substring($i + 1) }
	}
	# Источник изменился или сменилась служба — прежние байты не наши.
	if ($map['size'] -ne "$Size") { return '' }
	if ($map['endpoint'] -ne $remote_endpoint) { return '' }
	return [string]$map['upload_id']
}

function Write-RemoteUploadSidecar {
	param([string]$UploadId, [int64]$Size)
	$f = $script:RemoteUploadSidecar
	if (-not $f) { return }
	try {
		[System.IO.File]::WriteAllLines($f, @("upload_id=$UploadId", "size=$Size", "endpoint=$remote_endpoint"))
	} catch {}
}

function Clear-RemoteUploadSidecar {
	$f = $script:RemoteUploadSidecar
	if ($f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
}

# Повторять имеет смысл обрыв и перегрузку, а не отказ по существу: 413 не
# станет верным с третьей попытки, а три лишних отправки 32 МБ стоят минут.
function Test-RemoteRetryableCode {
	param([int]$Code)
	return ($Code -eq 0 -or $Code -eq 408 -or $Code -eq 429 -or ($Code -ge 500 -and $Code -le 599))
}

# Возобновляемость — не удобство, а условие работоспособности: файлы от
# гигабайта, и одна POST-загрузка на 20 ГБ рвётся и начинается заново.
$script:RemoteUploadDuration = ''
function Send-RemoteUpload {
	param([string]$Path)
	$script:RemoteUploadDuration = ''
	$size = (Get-Item -LiteralPath $Path).Length
	$chunk = $script:RemoteChunkSize
	if (-not $chunk) { $chunk = 33554432 }
	$offset = [int64]0
	$uid = Read-RemoteUploadSidecar $Path $size
	if ($uid) {
		$r = Invoke-RemoteHttp GET "/uploads/$uid"
		if ($r.Code -eq 200) {
			$rec = [int64](($r.Body | ConvertFrom-Json).received)
			if ($rec -ge 0 -and $rec -le $size) { $offset = $rec } else { $offset = 0 }
		} else { $uid = ''; $offset = 0 }
	}
	if (-not $uid) {
		$r = Invoke-RemoteHttp POST '/uploads'
		if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не приняла загрузку: HTTP $($r.Code)."; return $null }
		$u = $r.Body | ConvertFrom-Json
		$uid = $u.upload_id
		if ($u.chunk_size) { $script:RemoteChunkSize = [int]$u.chunk_size; $chunk = [int]$u.chunk_size }
		$offset = [int64]0
		Write-RemoteUploadSidecar $uid $size
	}

	$tmp = [System.IO.Path]::GetTempFileName()
	$fs = [System.IO.File]::OpenRead($Path)
	try {
		while ($offset -lt $size) {
			# Имя $take, а не $this: $this в PowerShell зарезервировано за текущим
			# объектом в блоках-методах, и присваивание ему читается как ошибка.
			$take = [int][Math]::Min([int64]$chunk, $size - $offset)
			$buf = New-Object byte[] $take
			$fs.Seek($offset, 'Begin') | Out-Null
			# Stream.Read по контракту возвращает НЕ БОЛЕЕ запрошенного, и
			# отброшенное возвращаемое значение оставляло недочитанный хвост
			# нулями: Content-Range объявлял полную длину, sha256 считался по
			# настоящему файлу и не сходился — «Служба не подтвердила загрузку»
			# без намёка на причину. Локальный FileStream обычно заполняет буфер
			# целиком, но исходники штатно лежат на сетевых шарах, где короткое
			# чтение — норма.
			$read = 0
			while ($read -lt $take) {
				$n = $fs.Read($buf, $read, $take - $read)
				if ($n -le 0) { break }
				$read += $n
			}
			if ($read -ne $take) {
				Write-Host "[ОШИБКА] Прочитано $read байт вместо $take со смещения $offset — отправка прервана."
				return $null
			}
			[System.IO.File]::WriteAllBytes($tmp, $buf)
			$tries = if ($env:REMOTE_UPLOAD_RETRIES) { [int]$env:REMOTE_UPLOAD_RETRIES } else { 3 }
			$sent = $false
			for ($try = 1; $try -le $tries; $try++) {
				$r = Invoke-RemoteHttp PATCH "/uploads/$uid" '' `
					@{ 'Content-Range' = "bytes $offset-$($offset + $take - 1)/$size" } '' $tmp
				if ($r.Code -eq 200) { $sent = $true; break }
				if (-not (Test-RemoteRetryableCode $r.Code)) { break }
				if ($try -lt $tries) {
					Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Повтор отправки куска $offset (попытка $($try + 1) из $tries)."
					Start-Sleep -Seconds $(if ($env:REMOTE_RETRY_SECONDS) { [int]$env:REMOTE_RETRY_SECONDS } else { 3 })
				}
			}
			if (-not $sent) {
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
	try { $script:RemoteUploadDuration = ($r.Body | ConvertFrom-Json).duration } catch {}
	Clear-RemoteUploadSidecar
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

# $OnCancel — проверка «пользователь нажал Стоп». Ждать здесь может быть долго
# (очередь службы, ожидание карты), и это единственная точка, где удалённый путь
# блокируется: локальная проверка отмены стоит в цикле ffmpeg, которого тут нет.
# Задачу при этом отменяем на сервере — брошенная держала бы карту до таймаута.
#
# Предел ожидания КЛИЕНТСКИЙ и обязателен: `while ($true)` без него означал, что
# задача, застрявшая в running/waiting_gpu, держит прогон вечно. У .sh был хотя
# бы тестовый предохранитель, здесь не было и его. $remote_wait_timeout уезжает
# в тело задачи и трактуется СЛУЖБОЙ; клиенту нужен свой, с запасом на очередь.
function Get-RemoteWaitDeadline {
	$base = if ($remote_wait_timeout) { [int]$remote_wait_timeout } else { 1800 }
	if ($base -le 0) { $base = 1800 }
	$factor = if ($env:REMOTE_WAIT_FACTOR) { [int]$env:REMOTE_WAIT_FACTOR } else { 3 }
	return ($base * $factor)
}

function Wait-RemoteJob {
	param([string]$JobId, [string]$Label, [scriptblock]$OnProgress = $null, [scriptblock]$OnCancel = $null)
	$script:RemoteCurrentJob = $JobId
	$started = Get-Date
	$limit = Get-RemoteWaitDeadline
	while ($true) {
		if ($OnCancel -and (& $OnCancel)) {
			Stop-RemoteJob $JobId
			$script:RemoteCurrentJob = ''
			return $false
		}
		if (((Get-Date) - $started).TotalSeconds -ge $limit) {
			Write-Host "[ОШИБКА] Задача $JobId не завершилась за $limit с — отменяем и считаем файл неудачным."
			Stop-RemoteJob $JobId
			$script:RemoteCurrentJob = ''
			return $false
		}
		$r = Invoke-RemoteHttp GET "/jobs/$JobId"
		if ($r.Code -ne 200) {
			Write-Host "[ОШИБКА] Состояние задачи недоступно: HTTP $($r.Code)."
			$script:RemoteCurrentJob = ''; return $false
		}
		$j = $r.Body | ConvertFrom-Json
		switch ($j.state) {
			'done'      { if ($OnProgress) { & $OnProgress 100 $Label 'кодирование' }; $script:RemoteCurrentJob = ''; return $true }
			'failed'    { Write-Host "[ОШИБКА] Задача провалена: $($j.error)"; $script:RemoteCurrentJob = ''; return $false }
			'cancelled' { Write-Host "[ОШИБКА] Задача отменена."; $script:RemoteCurrentJob = ''; return $false }
			'waiting_gpu' {
				# Ожидание без объяснения неотличимо от зависания. Фаза уходит и
				# в индикатор: в GUI Write-Host из фонового runspace не виден.
				if ($OnProgress) { & $OnProgress ([int]$j.progress) $Label ("ожидание карты: {0} с, не хватает {1} МиБ" -f $j.waiting_seconds, $j.missing_mib) }
				Write-Host ("  ожидание карты: {0} с, не хватает {1} МиБ" -f $j.waiting_seconds, $j.missing_mib)
			}
			default { if ($OnProgress) { & $OnProgress ([int]$j.progress) $Label 'кодирование' } }
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

# Прогресс загрузки. Переопределение живёт в FFmpeg_Converter_script.ps1 и
# объявлено ДО дот-сорса этого модуля — иначе guard ниже победил бы, и фаза
# отправки в GUI осталась бы без индикатора (Write-Progress из фонового
# runspace до формы не доходит), хотя на файле в 3 ГБ это и есть долгая часть.
if (-not (Get-Command Write-RemoteUploadProgress -ErrorAction SilentlyContinue)) {
	function Write-RemoteUploadProgress {
		param([int64]$Done, [int64]$Total)
		if ($Total -gt 0) {
			Write-Progress -Activity "Отправка на сервер" -PercentComplete ([int]($Done * 100 / $Total))
		}
	}
}

# --- Боевая самопроверка удалённого пути (--remote-selftest) ---
# Двойник remote_selftest из .sh: первый настоящий контакт со службой иначе
# происходит на пакете из двухсот файлов. Тестами стык не закрыть — мок не служба.
function Write-RemoteSelftestRow {
	param([string]$Step, [string]$Result, [string]$Time)
	Write-Host ("  {0,-26} {1,-10} {2}" -f $Step, $Result, $Time)
}

function Invoke-RemoteSelftest {
	$tmpd = Join-Path ([System.IO.Path]::GetTempPath()) ("ffconv_selftest_" + [guid]::NewGuid().ToString('N'))
	[System.IO.Directory]::CreateDirectory($tmpd) | Out-Null
	$clip = Join-Path $tmpd 'selftest.mp4'
	$out  = Join-Path $tmpd 'selftest.out'
	$rc = 0

	Write-Host "=== Самопроверка удалённого бэкенда ==="
	Write-Host "Адрес службы: $(if ($remote_endpoint) { $remote_endpoint } else { '<пусто>' })"
	Write-Host "Запрашиваемые URL:"
	foreach ($p in @('/capabilities','/uploads','/uploads/{id}','/uploads/{id}/complete','/jobs','/jobs/{id}','/jobs/{id}/result')) {
		Write-Host "  $remote_endpoint$p"
	}
	Write-Host ""
	Write-RemoteSelftestRow 'шаг' 'итог' 'время'

	$t0 = Get-Date
	if (-not (Invoke-RemotePreflight)) {
		Write-RemoteSelftestRow 'preflight' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}
	Write-RemoteSelftestRow 'preflight' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)

	$t0 = Get-Date
	# testsrc + sine: пробный ролик обязан иметь и видео, и звук, иначе
	# аудио-параметры текущего config.ini на службу вообще не поедут.
	& $ffmpeg -nostdin -hide_banner -v error -y -f lavfi -i "testsrc=size=320x240:rate=25" `
		-f lavfi -i "sine=frequency=440" -t 1 -shortest -pix_fmt yuv420p $clip 2>$null
	if (-not (Test-Path -LiteralPath $clip)) {
		Write-RemoteSelftestRow 'пробный ролик' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}
	Write-RemoteSelftestRow 'пробный ролик' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)

	# Докачка между запусками самопроверке не нужна.
	$savedSidecar = $script:RemoteUploadSidecar
	$script:RemoteUploadSidecar = ''
	$t0 = Get-Date
	$uid = Send-RemoteUpload $clip
	$script:RemoteUploadSidecar = $savedSidecar
	if (-not $uid) {
		Write-RemoteSelftestRow 'загрузка' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}
	Write-RemoteSelftestRow 'загрузка' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)

	$map = Get-RemoteOpForConfig 0 0
	if (-not $map) {
		Write-RemoteSelftestRow 'параметры задачи' 'ОТКАЗ' '-'
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}

	$t0 = Get-Date
	if (Invoke-RemoteDryRun $uid $map.Op $map.Params) {
		Write-RemoteSelftestRow 'холостой прогон' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
	} else {
		Write-RemoteSelftestRow 'холостой прогон' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		$rc = 1
	}

	$t0 = Get-Date
	$jobId = Submit-RemoteJob $uid $map.Op $map.Params
	if (-not $jobId) {
		Write-RemoteSelftestRow 'задача создана' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}
	Write-RemoteSelftestRow 'задача создана' $jobId ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)

	$t0 = Get-Date
	if ((Wait-RemoteJob $jobId 'selftest') -and (Receive-RemoteResult $jobId $out)) {
		Write-RemoteSelftestRow 'кодирование+скачивание' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
	} else {
		Write-RemoteSelftestRow 'кодирование+скачивание' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		Stop-RemoteJob $jobId
		Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
		return 1
	}

	$t0 = Get-Date
	& $ffmpeg -nostdin -v error -i $out -f null - 2>$null
	if ($LASTEXITCODE -eq 0 -and (Get-Item -LiteralPath $out).Length -gt 0) {
		Write-RemoteSelftestRow 'проверка результата' 'ok' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
	} else {
		Write-RemoteSelftestRow 'проверка результата' 'ОТКАЗ' ("{0:n0}с" -f ((Get-Date) - $t0).TotalSeconds)
		$rc = 1
	}

	Stop-RemoteJob $jobId
	Remove-Item -LiteralPath $tmpd -Recurse -Force -ErrorAction SilentlyContinue
	if ($rc -eq 0) {
		Write-Host "Самопроверка пройдена: удалённый путь работает целиком."
	} else {
		Write-Host "[ОШИБКА] Самопроверка выявила расхождения — см. таблицу выше."
	}
	return $rc
}
