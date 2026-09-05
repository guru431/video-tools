# ============================================================
# Удалённый бэкенд — клиент службы конвертации (PowerShell)
#
# Подключается из FFmpeg_Converter_script.ps1 и из GUI. Только функции,
# никаких действий при загрузке: так модуль дот-сорсится в тест без сети.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

# Версия сборщика аргументов, на которую рассчитан ЭТОТ клиент. Бампить вместе с
# изменением набора полей в Get-RemoteOpForConfig/Get-RemoteJobBody. Значение обязано
# совпадать с REMOTE_CLIENT_ARGS_VERSION в .sh — это сверяет test_23_remote_parity.sh.
$script:RemoteClientArgsVersion = '2'

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
# Однократный кэш: --remote-selftest выполняет preflight дважды, и менеджер
# паролей спрашивал пароль два раза подряд на одном прогоне.
$script:RemoteApiKeyResolved = $false
function Resolve-RemoteApiKey {
	if (-not $remote_api_key_command) { return $true }
	if ($script:RemoteApiKeyResolved) { return $true }
	$global:LASTEXITCODE = 0
	try {
		$out = & ([scriptblock]::Create($remote_api_key_command)) 2>$null
	} catch {
		Write-Host "[ОШИБКА] [remote] api_key_command завершилась с ошибкой — ключ не получен."
		return $false
	}
	# Ненулевой код возврата — отказ, а не «ключ получен»: раньше stdout упавшей
	# команды принимался как ключ (в .sh такой ветки нет).
	if ($LASTEXITCODE -ne 0) {
		Write-Host "[ОШИБКА] [remote] api_key_command завершилась с кодом $LASTEXITCODE — ключ не получен."
		return $false
	}
	$val = (@($out) | Where-Object { $_ } | Select-Object -First 1)
	if ($val) { $val = ([string]$val).Trim() }
	if (-not $val) {
		Write-Host "[ОШИБКА] [remote] api_key_command ничего не напечатала — ключ не получен."
		return $false
	}
	$script:remote_api_key = $val
	$script:RemoteApiKeyResolved = $true
	return $true
}

# Всё, что уезжает в JSON без кавычек, обязано быть проверено ДО загрузки гигабайт.
# Нечисловой wait_timeout («30 мин») давал невалидное тело `{"wait_timeout":30 мин}`,
# и обнаруживалось это ПОСЛЕ полной отправки файла. Паритет с remote_validate_config.
function Test-RemoteConfigValues {
	$ok = $true
	if ("$(if ($remote_wait_timeout) { $remote_wait_timeout } else { 1800 })" -notmatch '^\d+$') {
		Write-Host "[ОШИБКА] [remote] wait_timeout должен быть целым числом секунд (получено: '$remote_wait_timeout')."; $ok = $false
	}
	if ("$(if ($remote_stall_timeout) { $remote_stall_timeout } else { 900 })" -notmatch '^\d+$') {
		Write-Host "[ОШИБКА] [remote] stall_timeout должен быть целым числом секунд (получено: '$remote_stall_timeout')."; $ok = $false
	}
	$pref = if ($remote_prefer) { $remote_prefer } else { 'auto' }
	if ($pref -notin @('auto', 'gpu', 'cpu')) {
		Write-Host "[ОШИБКА] [remote] prefer принимает auto, gpu или cpu (получено: '$remote_prefer')."; $ok = $false
	}
	$onf = if ($remote_on_failure) { $remote_on_failure } else { 'abort' }
	if ($onf -notin @('abort', 'local')) {
		Write-Host "[ОШИБКА] [remote] on_failure принимает abort или local (получено: '$remote_on_failure')."; $ok = $false
	}
	if ($video_resolution_status -eq '+' -and $video_resolution_value -notmatch '^\d+x\d+$') {
		Write-Host "[ОШИБКА] [video] resolution ожидается в виде ШИРИНАxВЫСОТА без пробелов (получено: '$video_resolution_value')."; $ok = $false
	}
	if ($video_bitrate_status -eq '+' -and "$video_bitrate_value" -notmatch '^\d+$') {
		Write-Host "[ОШИБКА] [video] bitrate ожидается числом в кбит/с без суффикса (получено: '$video_bitrate_value')."; $ok = $false
	}
	if ($audio_bitrate_status -eq '+' -and "$audio_bitrate_value" -notmatch '^\d+$') {
		Write-Host "[ОШИБКА] [audio] bitrate ожидается числом в кбит/с без суффикса (получено: '$audio_bitrate_value')."; $ok = $false
	}
	return $ok
}

# Служба перечисляет ЭНКОДЕРЫ (h264_nvenc, libx264, …), а мы отправляем
# СЕМЕЙСТВО (h264). Поэтому сверка по семейству: наличие h264_nvenc означает,
# что h264 служба посчитает. Литеральная сверка противоречила бы самому
# отображению Get-RemoteCodec, ради которого оно и заведено.
# Служба объявляет энкодеры ЛИБО плоским списком, ЛИБО объектом по месту счёта
# {"gpu":[…],"cpu":[…]} (args_version 2). У объекта @(...).Count равен единице, а
# не нулю, поэтому проверка «список пуст» не срабатывала, а сверка кодека
# приводила объект к строке и не находила ничего — служба «не умела» ни одного
# кодека. Сводим обе формы к плоскому перечню имён.
function Get-RemoteCapsEncoders {
	param($Encoders)
	if ($null -eq $Encoders) { return @() }
	$flat = @()
	if ($Encoders -is [System.Management.Automation.PSCustomObject]) {
		foreach ($prop in $Encoders.PSObject.Properties) { $flat += @($prop.Value) }
	} else {
		$flat += @($Encoders)
	}
	return @($flat | ForEach-Object { [string]$_ } | Where-Object { $_ })
}

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
	param([int]$StartSec = 0, [int]$LengthSec = 0, [bool]$SubFound = $false)

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
	# Статус ключа значим ровно так же, как значение: локальный путь требует «+», и
	# `keep_aspect_ratio = -yes` локально означает «выключено», а удалённо уезжало
	# как true — один config.ini давал разную геометрию.
	if ($keep_aspect_ratio_status -eq '+' -and $keep_aspect_ratio_value -eq 'yes') { $p += ",`"keep_aspect`":true" } else { $p += ",`"keep_aspect`":false" }
	if ($video_number_frames_status -eq '+') { $p += ",`"fps`":$video_number_frames_value" }
	# rotate служба принимает числом (1 или 2) либо строкой "off": допустимые
	# значения — ("off", 1, 2), и "2" в кавычках в этот список не входит. Отказ
	# приходил 400-м уже ПОСЛЕ полной загрузки файла.
	if ($video_rotation_status -eq '+') {
		if ("$video_rotation_value" -eq '1' -or "$video_rotation_value" -eq '2') {
			$p += ",`"rotate`":$video_rotation_value"
		} else {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] [video] rotation = «$video_rotation_value»: служба принимает только 1 или 2 — поворот на удалённом пути не применяется."
		}
	}
	if ($playback_speed_status -eq '+' -and $playback_speed_value -ne '1.0') {
		$p += ",`"speed`":$playback_speed_value"
	}

	# Поле subtitles уезжает только когда sidecar РЕАЛЬНО найден: `subtitles = +burn`
	# без файла локально означает «кодируем без титров», а службе уходило
	# "subtitles":"burn" без subtitle_upload_id — 400 после полной загрузки видео.
	if ($video_subtitles_status -eq '+' -and $SubFound) {
		$p += ",`"subtitles`":`"$video_subtitles_value`""
		if ($subtitles_style) {
			$p += ",`"subtitle_style`":`"$(ConvertTo-RemoteJsonString $subtitles_style)`""
		}
	}

	# Контейнер — ПО СТАТУСУ, как в локальном пути («+» → значение, иначе mp4).
	# Раньше значение бралось всегда: `container = -mkv` локально давал movie.mp4, а
	# службе уходило "container":"mkv" — публиковался movie.mp4 с MKV внутри.
	if ($output_container_status -eq '+') { $p += ",`"container`":`"$output_container_value`"" } else { $p += ",`"container`":`"mp4`"" }
	$t = if ($threads) { $threads } else { 4 }
	$p += ",`"threads`":$t"

	if ($gpu_preset_status -eq '+') { $p += ",`"preset`":`"$gpu_preset_value`"" }
	if ($gpu_tune_status -eq '+')   { $p += ",`"tune`":`"$gpu_tune_value`"" }
	if ($gpu_rc_status -eq '+')     { $p += ",`"rc`":`"$gpu_rc_value`"" }

	# `codec` без «+» означает «звук не трогаем»: локально -c:a не ставится вовсе,
	# и bitrate/channels/rate при copy противоречивы (служба отвечает 400).
	if ($audio_codec_status -eq '+') {
		$a = "`"codec`":`"$audio_codec_value`""
		if ($audio_bitrate_status -eq '+')         { $a += ",`"bitrate`":$audio_bitrate_value" }
		if ($audio_number_channels_status -eq '+') { $a += ",`"channels`":$audio_number_channels_value" }
		if ($audio_sampling_rate_status -eq '+')   { $a += ",`"rate`":$audio_sampling_rate_value" }
		if ($audio_normalize_status -eq '+')       { $a += ",`"normalize`":`"$audio_normalize_value`"" }
	} else {
		$a = "`"codec`":`"copy`""
	}
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
		[string]$InFile = '',
		# Тело запроса БАЙТАМИ: кусок в 32 МБ раньше проходил через temp-файл
		# (WriteAllBytes → ReadAllBytes), то есть лишняя запись на диск в размер
		# всего исходника плюс второй буфер той же длины в памяти.
		[byte[]]$InBytes = $null,
		# Потолок ожидания ответа. 60 с хватает опросу и отмене, но НЕ хватает
		# POST /uploads/{id}/complete: он заставляет службу посчитать sha256 всего
		# файла, и на 20 ГБ это минуты — клиент получал WebException «HTTP 0» после
		# полностью отправленных гигабайт. Долгие запросы передают свой Timeout.
		[int]$TimeoutMs = 60000
	)
	# Явный TLS 1.2: на .NET Framework старых Windows умолчание — SSL3/TLS1, и
	# HTTPS-служба отвечает «HTTP 0» без единого слова о причине.
	try {
		[Net.ServicePointManager]::SecurityProtocol =
			[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
	} catch {}
	$req = [System.Net.HttpWebRequest]::Create("$remote_endpoint$Path")
	$req.Method = $Method
	$req.Timeout = $TimeoutMs
	$req.ReadWriteTimeout = 600000
	$req.Headers.Add('Authorization', "Bearer $remote_api_key")
	foreach ($k in $Headers.Keys) { $req.Headers.Add($k, $Headers[$k]) }
	try {
		if ($InBytes) {
			$req.ContentType = 'application/octet-stream'
			$req.ContentLength = $InBytes.Length
			$rs = $req.GetRequestStream()
			$rs.Write($InBytes, 0, $InBytes.Length); $rs.Close()
		} elseif ($InFile) {
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
	} catch {
		# Всё остальное — IOException (диск полон при записи результата на 3 ГБ),
		# UnauthorizedAccessException, неразбираемый URI. Раньше такие исключения
		# уходили наверх сквозь Encode-File: в GUI «Сбой выполнения», остаток пакета
		# не обработан. Ошибка одного файла обязана оставаться ошибкой одного файла.
		return [pscustomobject]@{ Code = 0; Body = $_.Exception.Message }
	}
}

# Единая retry-политика для КОРОТКИХ запросов (poll/submit/fetch/cancel): одна
# минутная пауза службы на пакете в 200 файлов давала N провалов и N задач-сирот.
# Паритет с remote_http_retry в .sh.
function Invoke-RemoteHttpRetry {
	param(
		[string]$Method,
		[string]$Path,
		[string]$Body = '',
		[hashtable]$Headers = @{},
		[string]$OutFile = '',
		[string]$InFile = '',
		[byte[]]$InBytes = $null,
		[int]$TimeoutMs = 60000
	)
	$tries = if ($env:REMOTE_HTTP_RETRIES) { [int]$env:REMOTE_HTTP_RETRIES } else { 4 }
	$pause = if ($env:REMOTE_RETRY_SECONDS) { [int]$env:REMOTE_RETRY_SECONDS } else { 3 }
	for ($try = 1; ; $try++) {
		$r = Invoke-RemoteHttp $Method $Path $Body $Headers $OutFile $InFile $InBytes $TimeoutMs
		if ($r.Code -ge 200 -and $r.Code -le 204) { return $r }
		if (-not (Test-RemoteRetryableCode $r.Code)) { return $r }
		if ($try -ge $tries) { return $r }
		$waitS = [Math]::Min($pause, 60)
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Служба ответила HTTP $($r.Code) — повтор через ${waitS}с (попытка $($try + 1) из $tries)."
		Start-Sleep -Seconds $waitS
		$pause = $pause * 2
	}
}

function Invoke-RemotePreflight {
	$script:remote_endpoint = Format-RemoteEndpoint $remote_endpoint
	if (-not $remote_endpoint) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте [remote] endpoint в config.ini (или переменную окружения TRANSCODE_URL)."
		return $false
	}
	if (-not (Test-RemoteConfigValues)) { return $false }
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
	$caps = $null
	try { $caps = $r.Body | ConvertFrom-Json } catch {}
	if ($null -eq $caps) {
		Write-Host "[ОШИБКА] Служба вернула неразбираемый ответ на /capabilities."
		return $false
	}
	# chunk_size живёт в limits (args_version 2); на верхнем уровне его больше
	# нет. .sh находил его текстовым поиском по всему телу и потому уцелел, а
	# здесь значение молча становилось $null и подменялось умолчанием — один
	# ответ службы давал двум платформам разный размер куска.
	$chunkRaw = if ($null -ne $caps.limits -and $caps.limits.chunk_size) { $caps.limits.chunk_size } else { $caps.chunk_size }
	$script:RemoteChunkSize = if ($chunkRaw) { [int]$chunkRaw } else { 33554432 }
	$script:RemoteArgsVersion = $caps.args_version
	$script:RemoteEncoders = Get-RemoteCapsEncoders $caps.encoders
	# Потолок ожидания карты и список контейнеров объявляет служба. Оба уже
	# отвергались 400-м, но ПОСЛЕ отправки файла целиком — то есть цена ошибки
	# равнялась времени загрузки гигабайтов. Спрашиваем здесь.
	$script:RemoteCapsWaitMax = if ($null -ne $caps.limits) { $caps.limits.wait_timeout_max_s } else { $null }
	$script:RemoteCapsContainers = @()
	try { $script:RemoteCapsContainers = @($caps.ops.transcode.values.container) } catch {}
	# Пустой список и отсутствие ключа — разные вещи: первое означает «служба не
	# умеет ничего» и обязано быть отказом, второе — «служба ничего не сказала».
	if (($caps.PSObject.Properties.Name -contains 'encoders') -and @($script:RemoteEncoders).Count -eq 0) {
		Write-Host "[ОШИБКА] Служба объявила пустой список энкодеров — считать нечем."
		return $false
	}
	# Энкодер — здесь, а не на каждом файле: отказать на сотом файле из двухсот
	# дороже, чем на нулевом. Раньше список encoders игнорировался вовсе.
	$family = Get-RemoteCodec $set_video_codec
	if (-not $family) {
		Write-Host "[ОШИБКА] Кодек «$set_video_codec» удалённой службе неизвестен (ожидаются h264/hevc/av1-энкодеры)."
		return $false
	}
	if (-not (Test-RemoteCodecSupported $family $script:RemoteEncoders)) {
		Write-Host "[ОШИБКА] Служба не умеет кодек «$family» (из [video] codec = $set_video_codec). Служба объявила: $($script:RemoteEncoders -join ', ')"
		return $false
	}
	if ($script:RemoteCapsWaitMax -and [int]$script:RemoteCapsWaitMax -gt 0) {
		$wantWait = if ($remote_wait_timeout) { [int]$remote_wait_timeout } else { 1800 }
		if ($wantWait -gt [int]$script:RemoteCapsWaitMax) {
			Write-Host "[ОШИБКА] [remote] wait_timeout = $wantWait больше потолка службы ($($script:RemoteCapsWaitMax) с) — задача была бы отвергнута после загрузки файла."
			return $false
		}
	}
	# Контейнер выхода — тоже 400 после загрузки. Проверяем только когда список
	# разобран: молчание службы не повод отказывать.
	if (@($script:RemoteCapsContainers).Count -gt 0) {
		$wantContainer = if ($output_container_status -eq '+') { "$output_container_value" } else { 'mp4' }
		if ($script:RemoteCapsContainers -notcontains $wantContainer) {
			Write-Host "[ОШИБКА] Служба не умеет контейнер «$wantContainer» (из [video] container). Служба объявила: $($script:RemoteCapsContainers -join ', ')"
			return $false
		}
	}
	# Версия сборщика аргументов службы. Расхождение не запрещает работу, но молча
	# получить файл, собранный логикой, которой у нас нет, — хуже, чем шумно.
	# Ожидаемое значение — КОНСТАНТА клиента: раньше PS1 сохранял args_version и
	# не сравнивал её НИКОГДА, то есть риск из §13 спеки не был закрыт вовсе.
	$known = if ($env:REMOTE_KNOWN_ARGS_VERSION) { $env:REMOTE_KNOWN_ARGS_VERSION } else { $script:RemoteClientArgsVersion }
	if ($known -and $script:RemoteArgsVersion -and "$($script:RemoteArgsVersion)" -ne "$known") {
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Служба собирает аргументы версии $($script:RemoteArgsVersion), клиент рассчитан на $known. Сверьте холостой прогон (--remote-selftest)."
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
	# Время изменения — вторая половина отпечатка: один размер ничего не доказывает,
	# и подмена файла другим той же длины заставляла докачивать ЧУЖИЕ байты в старую
	# загрузку (complete отвечал 409 на верно, по мнению клиента, собранном файле).
	# Старый sidecar без mtime не отвергаем: поле добавлено позже.
	if ($map.ContainsKey('mtime') -and $map['mtime']) {
		$mt = ''
		try { $mt = "$([int64]((Get-Item -LiteralPath $Source).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds)" } catch {}
		if ($mt -and $map['mtime'] -ne $mt) { return '' }
	}
	return [string]$map['upload_id']
}

# Идентификатор задачи живёт рядом с идентификатором загрузки: после падения клиента
# на фазе ожидания или скачивания следующий запуск идёт сразу в GET /jobs/{id} вместо
# повторной отправки гигабайт. Паритет с remote_upload_sidecar_read_job в .sh.
function Read-RemoteUploadSidecarJob {
	$f = $script:RemoteUploadSidecar
	if (-not $f -or -not (Test-Path -LiteralPath $f)) { return '' }
	foreach ($line in [System.IO.File]::ReadAllLines($f)) {
		if ($line -like 'job_id=*') { return $line.Substring(7) }
	}
	return ''
}

function Write-RemoteUploadSidecarJob {
	param([string]$JobId)
	$f = $script:RemoteUploadSidecar
	if (-not $f -or -not $JobId -or -not (Test-Path -LiteralPath $f)) { return }
	try {
		foreach ($line in [System.IO.File]::ReadAllLines($f)) { if ($line -like 'job_id=*') { return } }
		[System.IO.File]::AppendAllText($f, "job_id=$JobId`n")
	} catch {}
}

function Write-RemoteUploadSidecar {
	param([string]$UploadId, [int64]$Size, [string]$Source = '')
	$f = $script:RemoteUploadSidecar
	if (-not $f) { return }
	$mt = '0'
	if ($Source) {
		try { $mt = "$([int64]((Get-Item -LiteralPath $Source).LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds)" } catch {}
	}
	try {
		[System.IO.File]::WriteAllLines($f, @("upload_id=$UploadId", "size=$Size", "mtime=$mt", "endpoint=$remote_endpoint"))
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
# Размер результата из перечня выходов и признак того, что скачанное с ним
# сошлось. Читает Publish-EncodedResult — как REMOTE_RESULT_* в .sh.
$script:RemoteResultSize = ''
$script:RemoteResultVerified = 'no'
function Send-RemoteUpload {
	param([string]$Path)
	$script:RemoteUploadDuration = ''
	$size = (Get-Item -LiteralPath $Path).Length
	$chunk = $script:RemoteChunkSize
	if (-not $chunk) { $chunk = 33554432 }
	$offset = [int64]0
	$uid = Read-RemoteUploadSidecar -Source $Path -Size $size
	if ($uid) {
		$r = Invoke-RemoteHttpRetry GET "/uploads/$uid"
		$rec = -1
		if ($r.Code -eq 200) {
			# ConvertFrom-Json бросает терминирующую ошибку на мусорном ответе —
			# без try она уходила наверх сквозь Encode-File и рушила весь пакет.
			try { $rec = [int64](($r.Body | ConvertFrom-Json).received) } catch { $rec = -1 }
		}
		if ($rec -ge 0 -and $rec -le $size) { $offset = $rec } else { $uid = ''; $offset = 0 }
	}
	if (-not $uid) {
		$r = Invoke-RemoteHttpRetry POST '/uploads'
		if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не приняла загрузку: HTTP $($r.Code)."; return $null }
		$u = $null
		try { $u = $r.Body | ConvertFrom-Json } catch {}
		if ($null -eq $u -or -not $u.upload_id) { Write-Host "[ОШИБКА] Служба не вернула upload_id."; return $null }
		$uid = $u.upload_id
		if ($u.chunk_size) { $script:RemoteChunkSize = [int]$u.chunk_size; $chunk = [int]$u.chunk_size }
		$offset = [int64]0
		Write-RemoteUploadSidecar -UploadId $uid -Size $size -Source $Path
	}

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
			$tries = if ($env:REMOTE_UPLOAD_RETRIES) { [int]$env:REMOTE_UPLOAD_RETRIES } else { 3 }
			$sent = $false
			for ($try = 1; $try -le $tries; $try++) {
				# Байты уходят НАПРЯМУЮ: WriteAllBytes/ReadAllBytes через temp-файл
				# стоили лишней записи на диск в размер всего исходника и второго
				# буфера той же длины в памяти.
				$r = Invoke-RemoteHttp PATCH "/uploads/$uid" '' `
					@{ 'Content-Range' = "bytes $offset-$($offset + $take - 1)/$size" } '' '' $buf
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
			# Stop во время ОТПРАВКИ: фаза длинная (гигабайты), а cancel-файл до неё
			# не доходил вовсе — кнопка «Остановить» не действовала до конца загрузки.
			if ($script:RemoteCancelCheck -and (& $script:RemoteCancelCheck)) {
				Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Отправка прервана пользователем."
				return $null
			}
		}
	} finally { $fs.Dispose() }

	$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
	# complete заставляет службу посчитать sha256 всего файла: на 20 ГБ это минуты,
	# и штатных 60 с не хватало — клиент получал «HTTP 0» после полностью
	# отправленных гигабайт, а sidecar (см. выше) загонял следующий запуск в тот же
	# таймаут. Отдельный потолок в 30 минут.
	$r = Invoke-RemoteHttp POST "/uploads/$uid/complete" "{`"size`":$size,`"sha256`":`"$sha`"}" @{} '' '' $null 1800000
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Служба не подтвердила загрузку: HTTP $($r.Code)."
		# Sidecar здесь ОБЯЗАН исчезнуть: он хранит upload_id, и следующий запуск
		# воскрешал ту же загрузку — GET отвечал received == size, куски не слались,
		# complete снова возвращал 409. Повтор «с нуля» из спеки не происходил никогда.
		Clear-RemoteUploadSidecar
		return $null
	}
	# Ответ на complete содержит только upload_id и status: длительности там нет и
	# не было, то есть запасной источник для тонкого клиента (без локального
	# ffprobe) был мёртв и молча давал пустую строку. Разбор входа отдаёт отдельная
	# ручка; её отказ не фатален — ради длительности ронять загрузку нельзя.
	try { $script:RemoteUploadDuration = ($r.Body | ConvertFrom-Json).duration } catch {}
	if (-not $script:RemoteUploadDuration) {
		$probe = Invoke-RemoteHttp GET "/uploads/$uid/probe"
		if ($probe.Code -eq 200) {
			try { $script:RemoteUploadDuration = ($probe.Body | ConvertFrom-Json).duration } catch {}
		}
	}
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
	$r = Invoke-RemoteHttpRetry POST '/jobs' (Get-RemoteJobBody $UploadId $Op $Params $SubtitleId)
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба отвергла задачу: HTTP $($r.Code) — $($r.Body)"; return $null }
	$j = $null
	try { $j = $r.Body | ConvertFrom-Json } catch {}
	if ($null -eq $j -or -not $j.job_id) { Write-Host "[ОШИБКА] Служба не вернула job_id."; return $null }
	# Паритет с .sh: дедупликация службы — это сообщение пользователю, а не тишина.
	if ($j.reused -eq $true) { Write-Host "[INFO] Служба вернула готовый результат прежней задачи (дедупликация)." }
	Write-RemoteUploadSidecarJob ([string]$j.job_id)
	return [string]$j.job_id
}

# Холостой прогон НЕ загружает исходник: «только показать команды» не имеет права
# стоить часов трафика и гигабайт в хранилище службы. Печатаем тело POST /jobs,
# которое поехало бы; upload_id в нём — плейсхолдер <pending>. Паритет с .sh.
function Invoke-RemoteDryRun {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '')
	$body = Get-RemoteJobBody $UploadId $Op $Params $SubtitleId '"dry_run":true'
	if (-not $UploadId -or $UploadId -eq '<pending>') {
		Write-Host "[DRY-RUN][REMOTE] POST $remote_endpoint/jobs $body"
		Write-Host "[DRY-RUN][REMOTE] Исходник не загружен: холостой прогон не отправляет байты. План службы доступен только после реальной загрузки."
		return $true
	}
	$r = Invoke-RemoteHttp POST '/jobs' $body
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
# Дедлайн считается по ЗАСТРЕВАНИЮ, а не по общему времени задачи. Прежний
# `3 × wait_timeout на всю задачу` выводил предел из параметра с другим смыслом
# ($remote_wait_timeout = «сколько служба ждёт окна на карте»): часовой 4K-файл
# отменялся при живом прогрессе, а prefer = cpu на длинном файле — через 90 минут
# серверной работы. Таймер сбрасывается на каждое изменение state/progress.
# Паритет с remote_stall_seconds в .sh.
function Get-RemoteStallSeconds {
	$s = if ($remote_stall_timeout) { [int]$remote_stall_timeout } else { 900 }
	if ($s -le 0) { $s = 900 }
	return $s
}

function Wait-RemoteJob {
	param([string]$JobId, [string]$Label, [scriptblock]$OnProgress = $null, [scriptblock]$OnCancel = $null)
	$script:RemoteCurrentJob = $JobId
	$lastChange = Get-Date
	$lastSig = ''
	$fails = 0
	$maxFails = if ($env:REMOTE_POLL_MAX_FAILS) { [int]$env:REMOTE_POLL_MAX_FAILS } else { 5 }
	$limit = Get-RemoteStallSeconds
	while ($true) {
		if ($OnCancel -and (& $OnCancel)) {
			Stop-RemoteJob $JobId
			$script:RemoteCurrentJob = ''
			return $false
		}
		if (((Get-Date) - $lastChange).TotalSeconds -ge $limit) {
			Write-Host "[ОШИБКА] Задача $JobId не подаёт признаков движения $limit с — отменяем и считаем файл неудачным."
			Stop-RemoteJob $JobId
			$script:RemoteCurrentJob = ''
			return $false
		}
		$r = Invoke-RemoteHttp GET "/jobs/$JobId"
		if ($r.Code -ne 200) {
			# Один сбойный опрос не должен стоить файла: многочасовая задача
			# опрашивается тысячи раз, и 502 при рестарте службы (или 429, или
			# обрыв) считался фатальным — файл падал, а служба продолжала считать
			# результат, который никто не заберёт.
			$fails++
			if ($fails -ge $maxFails -or -not (Test-RemoteRetryableCode $r.Code)) {
				Write-Host "[ОШИБКА] Состояние задачи недоступно: HTTP $($r.Code) (подряд неудач: $fails) — отменяем задачу."
				Stop-RemoteJob $JobId
				$script:RemoteCurrentJob = ''; return $false
			}
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Опрос задачи не удался (HTTP $($r.Code)), попытка $fails из $maxFails."
			$pollS = if ($env:REMOTE_POLL_SECONDS) { [int]$env:REMOTE_POLL_SECONDS } else { 2 }
			Start-Sleep -Seconds ($pollS * $fails)
			continue
		}
		$fails = 0
		# Невалидный JSON — не повод рушить весь пакет: ConvertFrom-Json бросает
		# терминирующую ошибку, которая уходила наверх сквозь Encode-File.
		$j = $null
		try { $j = $r.Body | ConvertFrom-Json } catch {}
		if ($null -eq $j) {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Служба вернула неразбираемый ответ на опрос задачи — повтор."
			Start-Sleep -Seconds $(if ($env:REMOTE_POLL_SECONDS) { [int]$env:REMOTE_POLL_SECONDS } else { 2 })
			continue
		}
		# Признак живости — пара (state, progress): задача, идущая с 40 % до 41 %,
		# обязана жить дальше; зависшая на одном и том же — быть отменённой.
		$sig = "$($j.state)|$($j.progress)"
		if ($sig -ne $lastSig) { $lastSig = $sig; $lastChange = Get-Date }
		switch ($j.state) {
			'done'      {
				# Состояние задачи не содержит ни sha256, ни размера результата —
				# сверять скачанное было нечем. Размер служба сообщает отдельной
				# ручкой перечня выходов; берём его ТОЛЬКО когда выход один: у
				# нескольких /result отдаёт tar, и его длина с суммой длин файлов не
				# совпадает по определению.
				$script:RemoteResultSize = ''
				$o = Invoke-RemoteHttp GET "/jobs/$JobId/outputs"
				if ($o.Code -eq 200) {
					try {
						$oj = $o.Body | ConvertFrom-Json
						if ([int]$oj.count -eq 1) { $script:RemoteResultSize = "$($oj.outputs[0].bytes)" }
					} catch {}
				}
				if ($OnProgress) { & $OnProgress 100 $Label 'кодирование' }
				$script:RemoteCurrentJob = ''; return $true
			}
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
	# Скачивание результата — долгий запрос, 60 с общего таймаута ему мало.
	$script:RemoteResultVerified = 'no'
	$r = Invoke-RemoteHttpRetry GET "/jobs/$JobId/result" '' @{} $Destination '' $null 3600000
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Результат недоступен: HTTP $($r.Code)."
		Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
		return $false
	}
	# Размер, объявленный службой, отвечает на тот же вопрос, что полный декод
	# `-f null -`, но почти бесплатно: у трёхгигабайтного выхода второй декод стоит
	# минут НА ФАЙЛ. Паритет с .sh (REMOTE_RESULT_VERIFIED).
	if ($script:RemoteResultSize) {
		$got = -1
		try { $got = (Get-Item -LiteralPath $Destination).Length } catch {}
		if ("$got" -ne "$($script:RemoteResultSize)") {
			Write-Host "[ОШИБКА] Размер скачанного результата ($got) не совпал с объявленным службой ($($script:RemoteResultSize))."
			Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
			return $false
		}
		$script:RemoteResultVerified = 'yes'
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
	# try обязателен: без локального ffmpeg (заявленный «тонкий клиент»)
	# CommandNotFoundException — терминирующая и уходила наверх исключением
	# вместо строки «ОТКАЗ» в таблице самопроверки.
	try {
		& $ffmpeg -nostdin -hide_banner -v error -y -f lavfi -i "testsrc=size=320x240:rate=25" `
			-f lavfi -i "sine=frequency=440" -t 1 -shortest -pix_fmt yuv420p $clip 2>$null
	} catch {
		Write-Host "[ОШИБКА] Локальный ffmpeg недоступен — пробный ролик не создать: $($_.Exception.Message)"
	}
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
