# ============================================================
# Распознавание речи (ASR) — клиент сервера WhisperX (PowerShell)
#
# Подключается из FFmpeg_Converter_script.ps1; в EXE вклеен в ту же строку
# (build_exe.ps1). Только функции, никаких действий при загрузке: модуль
# дот-сорсится в тест без сети. Двойник asr_client.sh: равенство плана частей,
# аргументов curl, исходов и текста сверяет test_27_asr_parity.sh.
#
# curl.exe, а не HttpWebRequest, как в remote_client.ps1: у сервера
# самоподписанный сертификат, проверка TLS заменена закреплением открытого
# ключа. curl делает это флагом --pinnedpubkey (системный curl.exe 8.x на
# Schannel — тоже); в .NET Framework пришлось бы разбирать DER сертификата
# руками в callback'е проверки, который вдобавок вызывается вне runspace.
#
# Спека: docs/superpowers/specs/2026-10-02-ffmpeg-asr-design.md
# ============================================================

$script:AsrLowConfidence = 0.6
$script:AsrApiKeyResolved = $false
$script:AsrBase = ''
$script:AsrLimits = $null
$script:AsrRunDir = ''
$script:AsrStopReason = ''
$script:AsrPreflightError = ''
$script:AsrNotProcessed = 0
$script:AsrClaimed = @{}

function Format-AsrEndpoints {
	param([string]$Value)
	if (-not $Value) { return @() }
	return @($Value.Trim() -split '\s+' | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $_ })
}

function ConvertTo-AsrConfigString {
	param([string]$Value)
	return $Value.Replace('\', '\\').Replace('"', '\"')
}

# -k только вместе с пином: см. asr_tls_args в .sh. -clike: регистр схемы — как в .sh.
function Get-AsrTlsArgs {
	param([string]$Base)
	if ($Base -clike 'https://*' -and $asr_pinned_pubkey) { return @('-k', '--pinnedpubkey', $asr_pinned_pubkey) }
	return @()
}

function Get-AsrLimits {
	param([string]$Body)
	try { $j = $Body | ConvertFrom-Json } catch { return $null }
	if ($null -eq $j -or $null -eq $j.max_seconds -or $null -eq $j.job_timeout_sec) { return $null }
	return [pscustomobject]@{
		MaxSeconds  = [int64][math]::Truncate([double]$j.max_seconds)
		MaxBytes    = if ($null -ne $j.max_bytes) { [int64][math]::Truncate([double]$j.max_bytes) } else { [int64]0 }
		JobTimeout  = [int64][math]::Truncate([double]$j.job_timeout_sec)
		Device      = [string]$j.device
		Languages   = (@($j.languages | Where-Object { $_ }) -join ' ')
		Diarization = if ($null -ne $j.diarization) { ([string]$j.diarization).ToLowerInvariant() } else { '' }
		Ver         = [string]$j.asr_ver
	}
}

# План частей — спека §6, та же целочисленная формула, что asr_plan_parts.
function Get-AsrPlan {
	param([int64]$Duration, [int64]$MaxSeconds, [int64]$JobTimeout, [string]$Device)
	$lim = if ($Device -eq 'cpu') { [int64][math]::Floor($JobTimeout * 10 / 6) } else { $JobTimeout * 10 }
	$w = [int64][math]::Min($MaxSeconds, $lim)
	if ($Duration -le $w) { return [pscustomobject]@{ Parts = @("0:$Duration"); PartLen = $Duration; Whole = $w } }
	$p = [int64][math]::Floor($w / 2)
	$n = [int64][math]::Ceiling($Duration / $p)
	$l = [int64][math]::Ceiling($Duration / $n)
	$parts = @()
	for ($i = 0; $i -lt $n; $i++) {
		$off = $i * $l
		$len = [int64][math]::Min($l, $Duration - $off)
		if ($len -le 0) { break }
		$parts += "${off}:${len}"
	}
	return [pscustomobject]@{ Parts = $parts; PartLen = $l; Whole = $w }
}

# Порядок — контракт с asr_curl_args (test_27). Часть и ответ — относительными
# именами: curl запускается из каталога прогона (WorkingDirectory).
function Get-AsrCurlArgs {
	param([string]$Base, [string]$Part, [string]$Out)
	$d = if ($asr_diarize) { $asr_diarize } else { 'yes' }
	$diar = if ($d -ceq 'yes') { 'true' } else { 'false' }
	$a = @('-sS', '--connect-timeout', '10', '--max-time', [string]($script:AsrLimits.JobTimeout + 300))
	$a += @(Get-AsrTlsArgs $Base)
	$a += @('-F', "file=@$Part;type=audio/flac", '-F', 'model=whisperx', '-F', "language=$asr_language", '-F', "diarize=$diar")
	if ($asr_num_speakers) { $a += @('-F', "num_speakers=$asr_num_speakers") }
	$a += @('-o', $Out, '-w', '%{http_code}', "$Base/speech/transcriptions")
	return $a
}

function Get-AsrFfArgs {
	param([string]$In, [int64]$Offset, [int64]$Length, [int]$Count, [string]$Out)
	$a = @('-nostdin', '-v', 'error', '-y')
	if ($Count -gt 1) { $a += @('-ss', [string]$Offset, '-t', [string]$Length) }
	$a += @('-i', $In, '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'flac', $Out)
	return $a
}

function Format-AsrTs {
	param([double]$Seconds)
	$s = [int64][math]::Truncate($Seconds)
	return ('{0:D2}:{1:D2}:{2:D2}' -f [int64][math]::Truncate($s / 3600), [int64][math]::Truncate(($s % 3600) / 60), [int64]($s % 60))
}

# Только \r \n \t → пробел и обрезка пробелов: .Trim() без аргументов режет и
# NBSP, и текст разошёлся бы с awk-версией.
function Get-AsrClean {
	param([string]$Text)
	if (-not $Text) { return '' }
	return $Text.Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim(' ')
}

function Test-AsrConfigValues {
	$errors = @()
	$eps = @(Format-AsrEndpoints $asr_endpoint)
	if ($eps.Count -eq 0) { $errors += '[asr] endpoint пуст: задайте адрес сервера распознавания (или ${ASR_URL}).' }
	foreach ($e in $eps) { if ($e -cnotmatch '^https?://.') { $errors += "[asr] endpoint: '$e' — адрес должен начинаться с http:// или https://." } }
	if (-not $asr_language) { $errors += '[asr] language пуст: укажите язык записи (ru, en).' }
	$d = if ($asr_diarize) { $asr_diarize } else { 'yes' }
	if ($d -cne 'yes' -and $d -cne 'no') { $errors += "[asr] diarize = '$asr_diarize': ожидается yes или no." }
	if ($asr_num_speakers) {
		if ($asr_num_speakers -notmatch '^[0-9]+$' -or [int64]$asr_num_speakers -lt 1 -or [int64]$asr_num_speakers -gt 50) {
			$errors += "[asr] num_speakers = '$asr_num_speakers': целое от 1 до 50 или пусто."
		}
	}
	foreach ($m in $errors) { Write-Host "[ОШИБКА] $m" }
	if ($errors.Count -gt 0) { $script:AsrPreflightError = $errors[0]; return $false }
	return $true
}

function Resolve-AsrApiKey {
	if (-not $asr_api_key_command) { return $true }
	if ($script:AsrApiKeyResolved) { return $true }
	$global:LASTEXITCODE = 0
	try {
		$out = & ([scriptblock]::Create($asr_api_key_command)) 2>$null
	} catch {
		Write-Host '[ОШИБКА] [asr] api_key_command завершилась с ошибкой — ключ не получен.'
		$script:AsrPreflightError = '[asr] api_key_command завершилась с ошибкой'
		return $false
	}
	if ($LASTEXITCODE -ne 0) {
		Write-Host "[ОШИБКА] [asr] api_key_command завершилась с кодом $LASTEXITCODE — ключ не получен."
		$script:AsrPreflightError = "[asr] api_key_command завершилась с кодом $LASTEXITCODE"
		return $false
	}
	$val = (@($out) | Where-Object { $_ } | Select-Object -First 1)
	if ($val) { $val = ([string]$val).Trim() }
	if (-not $val) {
		Write-Host '[ОШИБКА] [asr] api_key_command ничего не напечатала — ключ не получен.'
		$script:AsrPreflightError = '[asr] api_key_command ничего не напечатала'
		return $false
	}
	$script:asr_api_key = $val
	$script:AsrApiKeyResolved = $true
	return $true
}

# Именно curl.exe: в Windows PowerShell 5.1 `curl` — алиас Invoke-WebRequest.
function Get-AsrCurlExe {
	if ($env:CURL_BIN) { return $env:CURL_BIN }
	foreach ($n in 'curl.exe', 'curl') {
		$c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($c) { return $c.Source }
	}
	return ''
}

# Та же склейка, что у запуска ffmpeg в FFmpeg_Converter_script.ps1: обратные
# слэши перед кавычкой и в конце аргумента удваиваются.
function ConvertTo-AsrArgLine {
	param([string[]]$Items)
	return (($Items | ForEach-Object {
		if ($_ -eq '' -or $_ -match '[ \t"\\]') {
			$a = [regex]::Replace($_, '(\\*)"', '$1$1\"')
			$a = [regex]::Replace($a, '(\\+)$', '$1$1')
			'"' + $a + '"'
		} else { $_ }
	}) -join ' ')
}

# Единственная точка выхода в сеть — её подменяют тесты. Ключ уходит конфигом
# на stdin, а не аргументом. Запрос молчит до получаса: каждые 0.5 с проверяется
# отмена ($script:AsrCancelCheck — кнопка «Остановить» GUI), раз в 5 с —
# $script:AsrTick (строка прогресса). finally добивает curl при Ctrl+C в CLI:
# CTRL_C в его скрытую консоль не доставляется.
function Invoke-AsrCurl {
	param([string]$Dir, [string[]]$CurlArgs)
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = Get-AsrCurlExe
	$psi.Arguments = ConvertTo-AsrArgLine (@('--config', '-') + $CurlArgs)
	$psi.WorkingDirectory = $Dir
	$psi.UseShellExecute = $false
	$psi.RedirectStandardInput = $true
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$p = $null; $done = $false
	try {
		$p = [System.Diagnostics.Process]::Start($psi)
		$p.StandardInput.Write('header = "Authorization: Bearer ' + (ConvertTo-AsrConfigString ([string]$asr_api_key)) + '"' + "`n")
		$p.StandardInput.Close()
		$outTask = $p.StandardOutput.ReadToEndAsync()
		$errTask = $p.StandardError.ReadToEndAsync()
		$t0 = [DateTime]::UtcNow; $tick = 0
		while (-not $p.WaitForExit(500)) {
			if ($script:AsrCancelCheck -and (& $script:AsrCancelCheck)) {
				try { $p.Kill() } catch {}
				$done = $true
				return [pscustomobject]@{ Rc = -1; Code = '000'; Err = 'отменено'; Cancelled = $true }
			}
			$el = [int]([DateTime]::UtcNow - $t0).TotalSeconds
			if ($script:AsrTick -and $el -ge $tick + 5) { $tick = $el; & $script:AsrTick $el }
		}
		$p.WaitForExit()
		$done = $true
		$code = ([string]$outTask.Result).Trim()
		if ($code -notmatch '^[0-9]+$') { $code = '000' }
		$err = [string](([string]$errTask.Result -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1))
		return [pscustomobject]@{ Rc = $p.ExitCode; Code = $code; Err = $err; Cancelled = $false }
	} catch {
		$done = $true
		return [pscustomobject]@{ Rc = -2; Code = '000'; Err = $_.Exception.Message; Cancelled = $false }
	} finally {
		if (-not $done -and $p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
	}
}

function Select-AsrEndpoint {
	$tried = @()
	$script:AsrBase = ''; $script:AsrStopReason = ''
	foreach ($u in @(Format-AsrEndpoints $asr_endpoint)) {
		$lim = Join-Path $script:AsrRunDir 'limits.json'
		Remove-Item -LiteralPath $lim -Force -ErrorAction SilentlyContinue
		$r = Invoke-AsrCurl $script:AsrRunDir (@('-sS', '--connect-timeout', '5', '--max-time', '15') + @(Get-AsrTlsArgs $u) + @('-o', 'limits.json', '-w', '%{http_code}', "$u/speech/limits"))
		if ($r.Rc -eq 90) {
			$script:AsrStopReason = "сертификат $u не совпал с закреплённым ключом [asr] pinned_pubkey (curl 90) — соединение оборвано"
			return $false
		}
		if ($r.Code -eq '200') {
			$l = $null
			if (Test-Path -LiteralPath $lim) { $l = Get-AsrLimits ([System.IO.File]::ReadAllText($lim, [System.Text.Encoding]::UTF8)) }
			if ($l) { $script:AsrBase = $u; $script:AsrLimits = $l; return $true }
			$tried += "$u → 200, но ответ не похож на /speech/limits"
		} elseif ($r.Code -eq '401' -or $r.Code -eq '403') {
			$script:AsrStopReason = "${u}: ключ не принят (HTTP $($r.Code)) — проверьте [asr] api_key"
			return $false
		} elseif ($r.Rc -ne 0) {
			$hint = if (($r.Rc -eq 35 -or $r.Rc -eq 60) -and -not $asr_pinned_pubkey) { ' — для самоподписанного сертификата задайте [asr] pinned_pubkey' } else { '' }
			$e = if ($r.Err) { " ($($r.Err))" } else { '' }
			$tried += "$u → curl $($r.Rc)$e$hint"
		} else {
			$tried += "$u → HTTP $($r.Code)"
		}
	}
	$script:AsrStopReason = 'сервер распознавания недоступен: ' + ($tried -join '; ')
	return $false
}

function Get-AsrDetail {
	param([string]$File)
	if (-not $File -or -not (Test-Path -LiteralPath $File)) { return '' }
	try { $j = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return '' }
	if ($j -and $j.detail -is [string]) { return $j.detail }
	return ''
}

# Тексты причин — контракт с asr_classify (test_27).
function Get-AsrOutcome {
	param([int]$Rc, [string]$Code, [string]$Detail, [string]$CurlErr)
	$d = if ($Detail) { ": $Detail" } else { '' }
	if ($Rc -ne 0) {
		if ($Rc -eq 90) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'сертификат сервера не совпал с закреплённым ключом (curl 90)' } }
		if ($Rc -eq 28) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'истёк таймаут ожидания ответа (curl 28); задача на сервере может ещё выполняться' } }
		if ($Rc -eq 26) { return [pscustomobject]@{ Outcome = 'file'; Reason = 'curl не смог прочитать извлечённый звук (curl 26)' } }
		$e = if ($CurlErr) { ": $CurlErr" } else { '' }
		return [pscustomobject]@{ Outcome = 'stop'; Reason = "сетевая ошибка (curl $Rc$e)" }
	}
	switch ($Code) {
		'200' { return [pscustomobject]@{ Outcome = 'ok'; Reason = '' } }
		{ $_ -in '400', '413', '422' } { return [pscustomobject]@{ Outcome = 'file'; Reason = "HTTP $Code$d" } }
		{ $_ -in '401', '403' } { return [pscustomobject]@{ Outcome = 'stop'; Reason = "ключ не принят (HTTP $Code)$d" } }
		'503' { return [pscustomobject]@{ Outcome = 'stop'; Reason = "очередь сервера заполнена (HTTP 503) и после повторов$d" } }
		'504' { return [pscustomobject]@{ Outcome = 'stop'; Reason = "сервер не уложился в свой предел (HTTP 504); задача на сервере продолжает выполняться — повторите позже$d" } }
	}
	return [pscustomobject]@{ Outcome = 'stop'; Reason = "HTTP $Code$d" }
}

function Invoke-AsrTranscribePart {
	param([string]$Part, [string]$Resp)
	$tries = if ($env:ASR_RETRIES) { [int]$env:ASR_RETRIES } else { 5 }
	$wait = if ($env:ASR_RETRY_WAIT) { [int]$env:ASR_RETRY_WAIT } else { 60 }
	$respPath = Join-Path $script:AsrRunDir $Resp
	$try = 1
	while ($true) {
		Remove-Item -LiteralPath $respPath -Force -ErrorAction SilentlyContinue
		$r = Invoke-AsrCurl $script:AsrRunDir @(Get-AsrCurlArgs $script:AsrBase $Part $Resp)
		if ($r.Cancelled) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'отменено пользователем' } }
		if ($r.Rc -eq 0 -and $r.Code -eq '503' -and $try -le $tries) {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Очередь сервера заполнена (HTTP 503) — повтор через $wait с (попытка $try из $tries)."
			for ($s = 0; $s -lt $wait; $s++) {
				if ($script:AsrCancelCheck -and (& $script:AsrCancelCheck)) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'отменено пользователем' } }
				Start-Sleep -Seconds 1
			}
			$try++
			continue
		}
		break
	}
	$detail = if ($r.Code -ne '200') { Get-AsrDetail $respPath } else { '' }
	$o = Get-AsrOutcome $r.Rc $r.Code $detail $r.Err
	if ($o.Outcome -eq 'ok') {
		$txt = if (Test-Path -LiteralPath $respPath) { [System.IO.File]::ReadAllText($respPath, [System.Text.Encoding]::UTF8) } else { '' }
		if (-not $txt.Contains('"segments"')) { $o = [pscustomobject]@{ Outcome = 'file'; Reason = 'сервер ответил 200, но без поля segments' } }
	}
	return $o
}

function Write-AsrJson {
	param([string]$Out, [object[]]$Parts)
	$utf8 = New-Object System.Text.UTF8Encoding($false)
	if ($Parts.Count -eq 1) { Copy-Item -LiteralPath $Parts[0].File -Destination $Out -Force; return }
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append('{"chunks":[')
	for ($i = 0; $i -lt $Parts.Count; $i++) {
		if ($i -gt 0) { [void]$sb.Append(',') }
		[void]$sb.Append('{"offset_seconds":' + $Parts[$i].Offset + ',"response":')
		[void]$sb.Append([System.IO.File]::ReadAllText($Parts[$i].File, $utf8))
		[void]$sb.Append('}')
	}
	[void]$sb.Append("]}`n")
	[System.IO.File]::WriteAllText($Out, $sb.ToString(), $utf8)
}

# Правила шапки и реплик — спека §9.2; обязаны совпадать с awk в asr_client.sh
# байт в байт (общие фикстуры tests/fixtures/asr, test_25/26/27).
function Write-AsrTranscript {
	param([string]$Src, [string]$Date, [int64]$PartLen, [string]$Out, [object[]]$Parts)
	$np = $Parts.Count
	$aud = 0.0; $audOk = $true; $prc = 0.0; $prcOk = $true; $ver = ''
	$bad = New-Object System.Collections.Generic.List[string]
	$warn = New-Object System.Collections.Generic.List[string]
	$reps = New-Object System.Collections.Generic.List[string]
	$spk = New-Object System.Collections.Generic.List[string]
	$low = 0
	$lowList = New-Object System.Collections.Generic.List[string]
	for ($pi = 0; $pi -lt $np; $pi++) {
		$r = [System.IO.File]::ReadAllText($Parts[$pi].File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
		$off = [double]$Parts[$pi].Offset
		$tag = if ($np -gt 1) { "ч.$($pi + 1): " } else { '' }
		if ($null -ne $r.audio_seconds) { $aud += [double]$r.audio_seconds } else { $audOk = $false }
		if ($null -ne $r.processing_seconds) { $prc += [double]$r.processing_seconds } else { $prcOk = $false }
		if (-not $ver -and $r.asr_ver) { $ver = [string]$r.asr_ver }
		if ($null -ne $r.stages) {
			foreach ($pp in $r.stages.PSObject.Properties) {
				$st = if ($null -ne $pp.Value -and $null -ne $pp.Value.status) { [string]$pp.Value.status } else { '?' }
				if ($st -cne 'ok') { $bad.Add("$tag$($pp.Name)=$st") }
			}
		}
		foreach ($w in @($r.warnings)) { if ($null -ne $w) { $warn.Add($tag + (Get-AsrClean ([string]$w))) } }
		$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
		$cur = ''; $buf = ''; $t0 = 0.0
		foreach ($seg in @($r.segments)) {
			if ($null -eq $seg) { continue }
			$t = Get-AsrClean ([string]$seg.text)
			if (-not $t) { continue }
			$sp = if ($null -ne $seg.speaker -and [string]$seg.speaker -ne '') { [string]$seg.speaker } else { 'SPEAKER_?' }
			if ($sp -cne 'SPEAKER_?') { [void]$seen.Add($sp) }
			$start = if ($null -ne $seg.start) { [double]$seg.start } else { 0.0 }
			$st = $start + $off
			if ($null -ne $seg.confidence -and [double]$seg.confidence -lt $script:AsrLowConfidence) {
				$low++
				if ($lowList.Count -lt 3) { $lowList.Add((Format-AsrTs $st)) }
			}
			if ($buf -ne '' -and $sp -cne $cur) { $reps.Add("[$(Format-AsrTs $t0)] ${cur}: $buf"); $buf = '' }
			if ($buf -eq '') { $cur = $sp; $t0 = $st; $buf = $t } else { $buf = "$buf $t" }
		}
		if ($buf -ne '') { $reps.Add("[$(Format-AsrTs $t0)] ${cur}: $buf") }
		$spk.Add([string]$seen.Count)
	}
	$lines = New-Object System.Collections.Generic.List[string]
	$lines.Add("# Расшифровка: $Src")
	$lines.Add("# Дата: $Date")
	$lines.Add('# Модель: ' + $(if ($ver) { $ver } else { '?' }))
	$audS = if ($audOk) { Format-AsrTs $aud } else { '?' }
	$prcS = if ($prcOk) { Format-AsrTs $prc } else { '?' }
	$lines.Add("# Длительность записи: $audS, обработка: $prcS")
	if ($np -eq 1) {
		$lines.Add("# Говорящих: $($spk[0])")
	} else {
		$lines.Add('# Говорящих по частям: ' + ($spk -join ', '))
		$lines.Add("# Частей: $np по ≈$(Format-AsrTs $PartLen) — метки говорящих в разных частях независимы")
	}
	$lowTail = if ($low -gt 0) { '; первые: ' + ($lowList -join ', ') } else { '' }
	$lines.Add("# Сомнительных сегментов (confidence < 0.6): $low$lowTail")
	if ($bad.Count -gt 0) { $lines.Add('# Этапы с ошибкой: ' + ($bad -join ', ')) }
	foreach ($w in $warn) { $lines.Add("# Предупреждение: $w") }
	$lines.Add('')
	foreach ($x in $reps) { $lines.Add($x) }
	[System.IO.File]::WriteAllText($Out, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
	return [pscustomobject]@{ Speakers = ($spk -join ','); Low = $low; Bad = ($bad -join ', ') }
}

function Remove-AsrRunDir {
	if ($script:AsrRunDir -and (Test-Path -LiteralPath $script:AsrRunDir)) {
		Remove-Item -LiteralPath $script:AsrRunDir -Recurse -Force -ErrorAction SilentlyContinue
	}
	$script:AsrRunDir = ''
}

function Set-AsrPreflightError {
	param([string]$Message)
	Write-Host "[ОШИБКА] $Message"
	$script:AsrPreflightError = $Message
	return $false
}

function Invoke-AsrPreflight {
	$script:AsrPreflightError = ''
	if (-not (Test-AsrConfigValues)) { return $false }
	if (-not $ffmpeg_available) { return (Set-AsrPreflightError "Распознавание речи требует локального ffmpeg: им извлекается звук ($ffmpeg не найден).") }
	if (-not (Get-AsrCurlExe)) { return (Set-AsrPreflightError 'curl не найден — распознавание речи невозможно.') }
	if (-not (Resolve-AsrApiKey)) { return $false }
	if (-not $asr_api_key) { return (Set-AsrPreflightError '[asr] ключ не задан: api_key, api_key_command или ${ASR_API_KEY}.') }
	$script:AsrRunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ffconv_asr_' + [guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $script:AsrRunDir -Force | Out-Null
	if (-not (Select-AsrEndpoint)) { Remove-AsrRunDir; return (Set-AsrPreflightError $script:AsrStopReason) }
	$langs = $script:AsrLimits.Languages
	if ($langs -and (" $langs " -cnotlike "* $asr_language *")) {
		Remove-AsrRunDir
		return (Set-AsrPreflightError "[asr] language = '$asr_language': сервер его не принимает (доступны: $langs).")
	}
	if ($script:AsrBase -clike 'http://*') { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] $($script:AsrBase) — открытый http: ключ и звук идут по сети незашифрованными." }
	if ($asr_diarize -ne 'no' -and $script:AsrLimits.Diarization -eq 'false') { Write-Host '[ПРЕДУПРЕЖДЕНИЕ] Сервер сообщает diarization = false: говорящих в расшифровке может не быть.' }
	$script:AsrStopReason = ''
	$l = $script:AsrLimits
	$whole = (Get-AsrPlan 0 $l.MaxSeconds $l.JobTimeout $l.Device).Whole
	$ver = if ($l.Ver) { $l.Ver } else { '?' }
	$dev = if ($l.Device) { $l.Device } else { '?' }
	Log-Msg 'INFO' "Распознавание речи: $($script:AsrBase) ($ver, $dev); целиком — до $whole с, длиннее — равными частями"
	return $true
}

function Clear-AsrFileTemp {
	if (-not $script:AsrRunDir) { return }
	Get-ChildItem -LiteralPath $script:AsrRunDir -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -like 'part_*.flac' -or $_.Name -like 'resp_*.json' } |
		Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-AsrFileFail {
	param([string]$Name, [string]$Reason)
	Log-Msg 'FAIL' "${Name}: $Reason"
	$script:anyFail = $true
	$script:countFail++
	Write-GUIProgress -CurrentFile $Name
}

function Invoke-AsrFile {
	param([System.IO.FileInfo]$File)
	$name = $File.Name
	$script:fileNum++
	$stem = if ($save_old_extension -eq 'yes') { $File.Name } else { $File.BaseName }
	$outDir = "$folder_destination$(Get-RelDir $File.DirectoryName)"
	$outTxt = "$outDir$stem.txt"; $outJson = "$outDir$stem.asr.json"
	$claim = (Get-CanonPath $outTxt).ToLowerInvariant()
	if ($script:AsrClaimed.ContainsKey($claim)) {
		Write-AsrFileFail $name "конфликт выходов — «$stem.txt» уже занят другим входом (включите save_old_extension = yes либо разнесите файлы)"
		return
	}
	$script:AsrClaimed[$claim] = $true
	if ($overwrite_existing -ne 'yes' -and (Test-Path -LiteralPath $outTxt)) {
		Log-Msg 'SKIP' "${name}: расшифровка уже есть ($stem.txt)"
		$script:countSkip++
		Write-GUIProgress -CurrentFile $name
		return
	}
	$info = ((& $ffmpeg -nostdin -i $File.FullName 2>&1 | ForEach-Object { "$_" }) -join "`n")
	if ($info -notmatch 'Stream #.*Audio:') { Write-AsrFileFail $name 'нет звуковой дорожки'; return }
	$m = [regex]::Match($info, 'Duration:\s+(\d+):(\d+):(\d+)')
	if (-not $m.Success) { Write-AsrFileFail $name 'длительность не читается'; return }
	$dur = [int64]$m.Groups[1].Value * 3600 + [int64]$m.Groups[2].Value * 60 + [int64]$m.Groups[3].Value + 1
	$lim = $script:AsrLimits
	$plan = Get-AsrPlan $dur $lim.MaxSeconds $lim.JobTimeout $lim.Device
	$n = $plan.Parts.Count
	if ($dry_run -eq 'yes') {
		Write-Host "[DRY-RUN] ${name}: частей $n (по ≈$(Format-AsrTs $plan.PartLen)) → $outTxt"
		for ($i = 0; $i -lt $n; $i++) {
			$off, $len = $plan.Parts[$i].Split(':')
			$part = 'part_{0:D3}.flac' -f $i; $resp = 'resp_{0:D3}.json' -f $i
			Write-Host "[DRY-RUN] $ffmpeg $((Get-AsrFfArgs $File.FullName $off $len $n $part) -join ' ')"
			Write-Host "[DRY-RUN] curl $((Get-AsrCurlArgs $script:AsrBase $part $resp) -join ' ')"
		}
		return
	}
	New-DirLiteral $outDir
	$started = Get-Date
	$pairs = @()
	for ($i = 0; $i -lt $n; $i++) {
		$off, $len = $plan.Parts[$i].Split(':')
		$part = 'part_{0:D3}.flac' -f $i; $resp = 'resp_{0:D3}.json' -f $i
		$partPath = Join-Path $script:AsrRunDir $part
		$ffArgs = @(Get-AsrFfArgs $File.FullName $off $len $n $partPath)
		& $ffmpeg @ffArgs 2>&1 | Out-Null
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $partPath) -or (Get-FileSize $partPath) -le 0) {
			Clear-AsrFileTemp; Write-AsrFileFail $name "не удалось извлечь звук (часть $($i + 1)/$n)"; return
		}
		if ($lim.MaxBytes -gt 0 -and (Get-FileSize $partPath) -gt $lim.MaxBytes) {
			Clear-AsrFileTemp; Write-AsrFileFail $name "часть $($i + 1)/$n больше предела сервера ($($lim.MaxBytes) байт)"; return
		}
		Log-Msg 'INFO' "${name}: распознавание, часть $($i + 1)/$n ($(Format-AsrTs $len) записи) — ждём ответ сервера"
		$script:AsrTickFile = $name
		$script:AsrTickPercent = [int]($i * 100 / $n)
		$script:AsrTickPhase = "распознавание, часть $($i + 1)/$n"
		Write-GUIProgress -FilePercent $script:AsrTickPercent -CurrentFile $name -Phase $script:AsrTickPhase
		$t0 = Get-Date
		$o = Invoke-AsrTranscribePart $part $resp
		if ($o.Outcome -ne 'ok') {
			Clear-AsrFileTemp
			if ($o.Outcome -eq 'stop') { $script:AsrStopReason = $o.Reason }
			Write-AsrFileFail $name $o.Reason
			return
		}
		Log-Msg 'INFO' "${name}: часть $($i + 1)/$n распознана за $(Format-AsrTs ((Get-Date) - $t0).TotalSeconds)"
		Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
		$pairs += [pscustomobject]@{ File = (Join-Path $script:AsrRunDir $resp); Offset = [int64]$off }
	}
	$tmpJson = Get-PartialPath $outJson; $tmpTxt = Get-PartialPath $outTxt
	$date = if ($env:FFCONV_ASR_NOW) { $env:FFCONV_ASR_NOW } else { Get-Date -Format 'yyyy-MM-dd HH:mm' }
	try {
		Write-AsrJson $tmpJson $pairs
		$sum = Write-AsrTranscript $name $date $plan.PartLen $tmpTxt $pairs
	} catch {
		Remove-Item -LiteralPath $tmpJson, $tmpTxt -Force -ErrorAction SilentlyContinue
		Clear-AsrFileTemp
		Write-AsrFileFail $name "не удалось собрать расшифровку из ответа сервера: $($_.Exception.Message)"
		return
	}
	try {
		Move-Item -LiteralPath $tmpJson -Destination $outJson -Force -ErrorAction Stop
		Move-Item -LiteralPath $tmpTxt -Destination $outTxt -Force -ErrorAction Stop
	} catch {
		Remove-Item -LiteralPath $tmpJson, $tmpTxt -Force -ErrorAction SilentlyContinue
		Clear-AsrFileTemp
		Write-AsrFileFail $name 'не удалось опубликовать результат (rename)'
		return
	}
	Clear-AsrFileTemp
	$el = (Get-Date) - $started
	$extra = if ($sum.Bad) { ", этапы с ошибкой: $($sum.Bad)" } else { '' }
	Log-Msg 'OK' ("{0} -> {1}.txt (говорящих: {2}, сомнительных сегментов: {3}{4}) ({5}m {6}s)" -f $name, $stem, $sum.Speakers, $sum.Low, $extra, [int][math]::Floor($el.TotalMinutes), $el.Seconds)
	$script:countOk++
	Write-GUIProgress -FilePercent 100 -CurrentFile $name
}

function Invoke-AsrRun {
	param([object[]]$Files)
	$script:AsrClaimed = @{}
	$script:AsrStopReason = ''
	$script:AsrNotProcessed = 0
	try {
		foreach ($f in @($Files | Sort-Object FullName)) {
			if (-not $script:AsrStopReason -and $script:AsrCancelCheck -and (& $script:AsrCancelCheck)) { $script:AsrStopReason = 'отменено пользователем' }
			if ($script:AsrStopReason) { $script:AsrNotProcessed++; continue }
			Invoke-AsrFile $f
		}
	} finally {
		Remove-AsrRunDir
	}
}
