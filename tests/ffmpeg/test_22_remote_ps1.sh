#!/bin/bash
# ============================================================
# test_22_remote_ps1.sh — реальный PS1-модуль клиента (дот-сорсинг).
# Нужен Windows PowerShell; иначе набор пропускается.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "remote PS1"
    skip "PS1-модуль клиента" "PowerShell не найден"
    summary
    exit 0
fi

MODULE="$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/remote_client.ps1"

run_ps() {
    "$PS_BIN" -NoProfile -NonInteractive -Command "
        . '$MODULE'
        $1
    " 2>&1 | tr -d '\r'
}

suite "remote PS1: отображение кодеков"
assert_eq "libx264 → h264"  "h264" "$(run_ps 'Get-RemoteCodec libx264')"
assert_eq "hevc_nvenc → hevc" "hevc" "$(run_ps 'Get-RemoteCodec hevc_nvenc')"
assert_eq "libsvtav1 → av1" "av1"  "$(run_ps 'Get-RemoteCodec libsvtav1')"
assert_empty "неизвестный кодек" "$(run_ps 'Get-RemoteCodec libvpx-vp9')"

suite "remote PS1: операция и параметры"
_setup='
$set_video_codec="libx264"
$video_quality_status="+";       $video_quality_value="23"
$video_bitrate_status="-";       $video_bitrate_value="3000"
$video_resolution_status="+";    $video_resolution_value="1280x720"
$video_number_frames_status="+"; $video_number_frames_value="30"
$video_rotation_status="-";      $video_rotation_value="2"
$video_subtitles_status="-";     $video_subtitles_value="burn"
$keep_aspect_ratio_value="yes";  $output_container_value="mp4"
$audio_codec_status="+";           $audio_codec_value="aac"
$audio_number_channels_status="+"; $audio_number_channels_value="2"
$audio_bitrate_status="+";         $audio_bitrate_value="128"
$audio_sampling_rate_status="+";   $audio_sampling_rate_value="48000"
$audio_normalize_status="-";       $audio_normalize_value="loudnorm"
$playback_speed_status="-";      $playback_speed_value="1.0"
$gpu_preset_status="-"; $gpu_preset_value="p5"
$gpu_tune_status="-";   $gpu_tune_value="hq"
$gpu_rc_status="-";     $gpu_rc_value="vbr"
$threads=4; $subtitles_style=""
'
out="$(run_ps "$_setup; (Get-RemoteOpForConfig 0 0).Op")"
assert_eq "без отрезка → transcode" "transcode" "$out"
params="$(run_ps "$_setup; (Get-RemoteOpForConfig 0 0).Params")"
assert_contains "кодек"      '"codec":"h264"'          "$params"
assert_contains "качество"   '"quality":23'            "$params"
assert_contains "контейнер"  '"container":"mp4"'       "$params"
assert_contains "звук"       '"audio":{"codec":"aac"'  "$params"
# audio.bitrate — кбит/с (служба: 8–640), в отличие от video.bitrate в бит/с.
assert_contains "аудиобитрейт в кбит/с" '"audio":{"codec":"aac","bitrate":128,' "$params"

out="$(run_ps "$_setup; (Get-RemoteOpForConfig 60 300).Op")"
assert_eq "с отрезком → cut" "cut" "$out"
params="$(run_ps "$_setup; (Get-RemoteOpForConfig 60 300).Params")"
assert_contains "начало"  '"start":60'      "$params"
assert_contains "конец"   '"end":360'       "$params"
assert_contains "перекод" '"reencode":true' "$params"

# Invoke-RemoteHttp — единственная точка выхода в сеть, и ровно поэтому её
# подменяем: без этого набора нарезка на куски и докачка в .ps1 не проверены
# вовсе, хотя в .sh покрыты (test_21). Именно здесь ловится расхождение,
# которое на живом файле в 3 ГБ стоило бы часа.
suite "remote PS1: загрузка кусками через подменённый HTTP-слой"
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_up_" .ps1)"
_payload="$(mktemp "${TMPDIR:-/tmp}/remote_payload_XXXXXX")"
head -c 3000 /dev/zero | tr '\0' 'x' > "$_payload"
_payload_win="$(cygpath -w "$_payload" 2>/dev/null || echo "$_payload")"

cat > "$_harness" <<PSEOF
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
# Подмена: сети нет, ответы консервированные, вызовы записываются.
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [byte[]]\$InBytes = \$null, [int]\$TimeoutMs = 60000)
	\$range = if (\$Headers.ContainsKey('Content-Range')) { \$Headers['Content-Range'] } else { '' }
	[void]\$script:calls.Add("\$Method \$Path \$range \$Body")
	if (\$Method -eq 'POST' -and \$Path -eq '/uploads') {
		return [pscustomobject]@{ Code = 200; Body = '{"upload_id":"up-99","chunk_size":1024}' }
	}
	if (\$Method -eq 'GET' -and \$Path -like '/uploads/*') {
		return [pscustomobject]@{ Code = 200; Body = '{"received":0}' }
	}
	if (\$Path -like '*/complete') { return [pscustomobject]@{ Code = 200; Body = '{"duration":42}' } }
	return [pscustomobject]@{ Code = 200; Body = '{}' }
}
\$uid = Send-RemoteUpload '$_payload_win'
Write-Output "UID=\$uid"
Write-Output "DUR=\$(\$script:RemoteUploadDuration)"
\$script:calls | ForEach-Object { Write-Output \$_ }
PSEOF

_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
assert_contains "идентификатор загрузки" "UID=up-99" "$_out"
assert_contains "первый кусок"  "bytes 0-1023/3000"    "$_out"
assert_contains "второй кусок"  "bytes 1024-2047/3000" "$_out"
assert_contains "третий кусок"  "bytes 2048-2999/3000" "$_out"
assert_contains "завершение"    "/uploads/up-99/complete" "$_out"
assert_contains "хеш отправлен" '"sha256"' "$_out"
# Тот же вход, что в .sh-тесте: хеш обязан совпасть на обеих платформах.
assert_not_contains "хеш не пустой" '"sha256":""' "$_out"
assert_contains "длительность из complete запомнена" "DUR=" "$_out"
rm -f "$_harness" "$_payload"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: нормализация адреса и экранирование"
# ══════════════════════════════════════════════════════════════
# Двойники remote_normalize_endpoint / remote_json_escape из .sh. Их равенство
# и есть предмет паритета: раньше .sh снимал один хвостовой слэш, PS1 — все,
# а Trim пробелов был только в GUI.
assert_eq "один хвостовой слэш" "http://h/v1" "$(run_ps "Format-RemoteEndpoint 'http://h/v1/'")"
assert_eq "несколько слэшей"    "http://h/v1" "$(run_ps "Format-RemoteEndpoint 'http://h/v1//'")"
assert_eq "пробелы по краям"    "http://h/v1" "$(run_ps "Format-RemoteEndpoint '  http://h/v1  '")"
assert_eq "обратный слэш удваивается" 'a\\b\"c/\\d' "$(run_ps "ConvertTo-RemoteJsonString 'a\\b\"c/\\d'")"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: сверка кодека по семейству"
# ══════════════════════════════════════════════════════════════
# Служба перечисляет энкодеры, мы отправляем семейство: наличие h264_nvenc
# означает, что h264 она посчитает. Литеральная сверка противоречила бы
# отображению Get-RemoteCodec.
assert_eq "h264 при h264_nvenc" "True"  "$(run_ps "Test-RemoteCodecSupported 'h264' @('h264_nvenc','hevc_nvenc')")"
assert_eq "h264 при libx264"    "True"  "$(run_ps "Test-RemoteCodecSupported 'h264' @('libx264')")"
assert_eq "h264 без h264"       "False" "$(run_ps "Test-RemoteCodecSupported 'h264' @('hevc_nvenc','av1_nvenc')")"
assert_eq "пустой список не отказ" "True" "$(run_ps "Test-RemoteCodecSupported 'h264' @()")"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: контракт службы args_version 2"
# ══════════════════════════════════════════════════════════════
# Служба отдаёт encoders ОБЪЕКТОМ по месту счёта. У объекта @(...).Count равен
# единице, поэтому проверка «список пуст» не срабатывала, а сверка кодека
# приводила объект к строке и не находила ничего: служба «не умела» ни одного
# кодека. Сводим обе формы к плоскому перечню — как это делает .sh.
# Выражение уходит в переменную, а подстановка вызывается ВНЕ внешних кавычек —
# и то, и другое обязательно. В bash 3.2 (системный на macOS) внутри `"$( … )"`
# вложенные двойные кавычки не образуют строку, содержимое оказывается голым, и
# `@{gpu=…,…}` попадает под BRACE EXPANSION: фигурные скобки исчезают, PowerShell
# получает «[pscustomobject]@gpu=@('h264_nvenc')» и падает с ParserError. Видно это
# только у шаблонов С ЗАПЯТОЙ внутри скобок — соседние строки без запятой проходят,
# поэтому дефект жил в macOS-линии CI незамеченным.
_caps_obj="(Get-RemoteCapsEncoders ([pscustomobject]@{gpu=@('h264_nvenc','hevc_nvenc');cpu=@('libx264')})) -join ' '"
_caps_out=$(run_ps "$_caps_obj")
assert_eq "объект {gpu,cpu} разворачивается" "h264_nvenc hevc_nvenc libx264" "$_caps_out"
assert_eq "плоский список остаётся собой" "h264_nvenc libx264"     "$(run_ps "(Get-RemoteCapsEncoders @('h264_nvenc','libx264')) -join ' '")"
assert_eq "пустые группы дают пустой перечень" "0"     "$(run_ps "@(Get-RemoteCapsEncoders ([pscustomobject]@{gpu=@();cpu=@()})).Count")"
assert_eq "отсутствие поля даёт пустой перечень" "0"     "$(run_ps "@(Get-RemoteCapsEncoders \$null).Count")"
# Имена групп — не энкодеры: попав в перечень, они выглядели бы объявленными кодеками.
assert_eq "имена групп не попадают в перечень" "False"     "$(run_ps "((Get-RemoteCapsEncoders ([pscustomobject]@{gpu=@('h264_nvenc')})) -contains 'gpu').ToString()")"
# Сверка семейства обязана работать поверх развёрнутого перечня.
assert_eq "h264 находится в группе gpu" "True"     "$(run_ps "Test-RemoteCodecSupported 'h264' (Get-RemoteCapsEncoders ([pscustomobject]@{gpu=@('h264_nvenc');cpu=@('libx265')}))")"
assert_eq "av1 не находится, когда его нет" "False"     "$(run_ps "Test-RemoteCodecSupported 'av1' (Get-RemoteCapsEncoders ([pscustomobject]@{gpu=@('h264_nvenc');cpu=@('libx264')}))")"
# Версия сборщика аргументов у обеих платформ одна: расхождение означало бы, что
# одна из них молча собирает тело по контракту, которого у службы больше нет.
assert_eq "версия сборщика = 2" "2" "$(run_ps "\$script:RemoteClientArgsVersion")"

# Служба, не объявившая контейнеров (ключа ops нет вовсе — прежняя версия за
# прокси), обязана приниматься: «молчание службы не повод отказывать». В PS1
# @($null) давал массив из ОДНОГО элемента, проверка «список разобран»
# срабатывала, и preflight отвергал каждый запуск с пустым «Служба объявила: ».
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_pf_" .ps1)"
cat > "$_harness" <<'PSEOF'
param([string]$Module)
. $Module
$script:capsBody = ''
function Invoke-RemoteHttp {
	param([string]$Method, [string]$Path, [string]$Body = '', [hashtable]$Headers = @{},
	      [string]$OutFile = '', [string]$InFile = '', [byte[]]$InBytes = $null, [int]$TimeoutMs = 60000)
	return [pscustomobject]@{ Code = 200; Body = $script:capsBody }
}
$remote_endpoint = 'http://mock.invalid/v1'; $remote_api_key = 'k'
$set_video_codec = 'libx264'; $output_container_status = '+'; $output_container_value = 'mp4'
$script:capsBody = '{"args_version":"2","chunk_size":1048576}'
Write-Output ("NOOPS=" + [bool](Invoke-RemotePreflight 6>$null))
$script:capsBody = '{"args_version":"2","chunk_size":1048576,"ops":{"transcode":{"values":{"container":["mkv"]}}}}'
Write-Output ("MKVONLY=" + [bool](Invoke-RemotePreflight 6>$null))
# Причина отказа запоминается для итогового сообщения GUI: первая [ОШИБКА]-строка.
$script:capsBody = '{"args_version":"2","chunk_size":1048576}'
Write-Output ("MKVERR=" + $script:RemotePreflightError)
$remote_endpoint = ''
[void](Invoke-RemotePreflight 6>$null)
Write-Output ("EMPTYERR=" + $script:RemotePreflightError)
$remote_endpoint = 'http://mock.invalid/v1'
# Две ошибки конфига подряд — главной остаётся первая.
$video_quality_status = '+'; $video_quality_value = 'x'; $threads = 'y'
[void](Invoke-RemotePreflight 6>$null)
Write-Output ("CFGERR=" + $script:RemotePreflightError)
$video_quality_status = '-'; $threads = 4
# Успешный повтор сбрасывает прежнюю причину.
[void](Invoke-RemotePreflight 6>$null)
Write-Output ("RESETERR=[" + $script:RemotePreflightError + "]")
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" -Module "$MODULE" 2>&1 | tr -d '\r')"
_f() { printf '%s\n' "$_out" | grep "^${1}=" | sed "s/^${1}=//"; }
assert_eq "контейнеры не объявлены — служба принята" "True"  "$(_f NOOPS)"
assert_eq "объявлен только mkv — mp4 отвергнут"       "False" "$(_f MKVONLY)"
assert_contains "причина отказа запомнена (контейнер)" "mkv" "$(_f MKVERR)"
assert_contains "причина отказа: пустой адрес"        "TRANSCODE_URL" "$(_f EMPTYERR)"
assert_contains "главная причина — первая ошибка"      "quality" "$(_f CFGERR)"
assert_not_contains "вторая ошибка не перетирает первую" "threads" "$(_f CFGERR)"
assert_eq "успешный preflight сбрасывает причину"     "[]" "$(_f RESETERR)"
rm -f "$_harness"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: короткое чтение и повтор куска"
# ══════════════════════════════════════════════════════════════
# Stream.Read по контракту возвращает НЕ БОЛЕЕ запрошенного; отброшенное
# возвращаемое значение оставляло хвост куска нулями, и sha256 в complete не
# сходился. Сетевые шары, где короткое чтение — норма, для этого проекта штатны.
# Здесь проверяем сами отправленные БАЙТЫ: позиционная разметка показывает,
# что уехало ровно содержимое файла, а не буфер с нулями.
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_short_" .ps1)"
_payload="$(mktemp "${TMPDIR:-/tmp}/remote_payload_XXXXXX")"
: > "$_payload"
for _i in 0 1 2; do
    printf 'BLOCK%d' "$_i" >> "$_payload"
    head -c 1018 /dev/zero | tr '\0' "$_i" >> "$_payload"
done                                    # 3 блока по 1024 = 3072
_payload_win="$(cygpath -w "$_payload" 2>/dev/null || echo "$_payload")"

cat > "$_harness" <<PSEOF
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
\$script:patchCount = 0
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [byte[]]\$InBytes = \$null, [int]\$TimeoutMs = 60000)
	if (\$Method -eq 'POST' -and \$Path -eq '/uploads') {
		return [pscustomobject]@{ Code = 200; Body = '{"upload_id":"up-77","chunk_size":1024}' }
	}
	if (\$Method -eq 'PATCH') {
		\$script:patchCount++
		# Кусок приходит БАЙТАМИ, а не temp-файлом: WriteAllBytes/ReadAllBytes на
		# каждый кусок стоили лишней записи на диск в размер всего исходника.
		\$head = [System.Text.Encoding]::ASCII.GetString(\$InBytes, 0, 6)
		[void]\$script:calls.Add("PATCH \$(\$Headers['Content-Range']) HEAD=\$head")
		# Первый кусок отвергаем с 503: повтор обязан пройти.
		if (\$script:patchCount -eq 1) { return [pscustomobject]@{ Code = 503; Body = '{}' } }
		return [pscustomobject]@{ Code = 200; Body = '{}' }
	}
	if (\$Path -like '*/complete') { return [pscustomobject]@{ Code = 200; Body = '{"duration":7}' } }
	return [pscustomobject]@{ Code = 200; Body = '{}' }
}
\$env:REMOTE_RETRY_SECONDS = '0'
\$uid = Send-RemoteUpload '$_payload_win'
Write-Output "UID=\$uid"
Write-Output "PATCHES=\$(\$script:patchCount)"
Write-Output "DUR=\$(\$script:RemoteUploadDuration)"
\$script:calls | ForEach-Object { Write-Output \$_ }
PSEOF

_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
assert_contains "загрузка завершилась"      "UID=up-77"  "$_out"
assert_contains "503 повторён, а не провален" "PATCHES=4" "$_out"
assert_contains "длительность из complete"  "DUR=7"      "$_out"
assert_contains "кусок 0 несёт свои байты"  "bytes 0-1023/3072 HEAD=BLOCK0"    "$_out"
assert_contains "кусок 1 несёт свои байты"  "bytes 1024-2047/3072 HEAD=BLOCK1" "$_out"
assert_contains "кусок 2 несёт свои байты"  "bytes 2048-3071/3072 HEAD=BLOCK2" "$_out"
rm -f "$_harness" "$_payload"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: клиентский предел ожидания задачи"
# ══════════════════════════════════════════════════════════════
# `while ($true)` без предела означал, что застрявшая в running задача держит
# прогон вечно. Предел считается по ЗАСТРЕВАНИЮ (state/progress не меняются), а не
# по общему времени: «3 × wait_timeout» выводил дедлайн из параметра с другим
# смыслом и отменял часовой 4K-файл при живом прогрессе.
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_wait_" .ps1)"
cat > "$_harness" <<PSEOF
# Консоль PowerShell по умолчанию отдаёт вывод в OEM-кодировке (866), и
# кириллица в сообщении об ошибке приходит в bash мусором. Ассерт по русскому
# тексту без этой строки проверял бы не текст, а кодировку.
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [int]\$TimeoutMs = 60000)
	[void]\$script:calls.Add("\$Method \$Path")
	return [pscustomobject]@{ Code = 200; Body = '{"state":"running","progress":10}' }
}
# Время виртуальное (как в сценариях ожидания карты ниже): пауза опроса двигает часы.
\$script:now = [datetime]'2026-01-01T00:00:00'
function Get-Date { return \$script:now }
function Start-Sleep { param([int]\$Seconds) \$script:now = \$script:now.AddSeconds(\$Seconds) }
\$remote_stall_timeout = 1
\$env:REMOTE_POLL_SECONDS = '1'
\$ok = Wait-RemoteJob 'job-5' 'файл'
Write-Output "OK=\$ok"
\$script:calls | ForEach-Object { Write-Output \$_ }
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
assert_contains "застрявшая задача не ждётся вечно" "OK=False" "$_out"
assert_contains "задача отменена на сервере"        "DELETE /jobs/job-5" "$_out"
assert_contains "предел назван словами"             "не подаёт признаков движения"  "$_out"
assert_eq "предел берётся из stall_timeout" "900" \
  "$(run_ps '$remote_stall_timeout = 900; Get-RemoteStallSeconds')"
assert_eq "пустой stall_timeout → умолчание 900" "900" \
  "$(run_ps '$remote_stall_timeout = ""; Get-RemoteStallSeconds')"
rm -f "$_harness"

# Ожидание карты: процент там не растёт по определению, и здоровая задача, честно
# ждущая окна, отменялась через stall_timeout, хотя службе разрешено ждать
# wait_timeout. Порог в waiting_gpu — wait_timeout + stall_timeout (здесь 20 + 10).
# Время ВИРТУАЛЬНОЕ: Get-Date и Start-Sleep подменены функциями (функция побеждает
# командлет), пауза опроса двигает часы — реального ожидания нет. Три сценария —
# в одном процессе PowerShell: его запуск дороже самих проверок.
assert_eq "порог ожидания карты = wait_timeout + stall_timeout" "2700" \
  "$(run_ps '$remote_stall_timeout = 900; $remote_wait_timeout = 1800; Get-RemoteStallSeconds waiting_gpu')"
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_gpu_" .ps1)"
cat > "$_harness" <<'PSEOF'
param([string]$Module)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. $Module
function Get-Date { return $script:now }
function Start-Sleep { param([int]$Seconds) $script:now = $script:now.AddSeconds($Seconds) }
function Invoke-RemoteHttp {
	param([string]$Method, [string]$Path, [string]$Body = '', [hashtable]$Headers = @{},
	      [string]$OutFile = '', [string]$InFile = '', [byte[]]$InBytes = $null, [int]$TimeoutMs = 60000)
	if ($Method -eq 'DELETE') { $script:deleted = $true; return [pscustomobject]@{ Code = 200; Body = '{}' } }
	$script:polls++
	# После $script:maxPolls опросов карта «освобождается» — задача готова.
	if ($script:maxPolls -gt 0 -and $script:polls -gt $script:maxPolls) {
		return [pscustomobject]@{ Code = 200; Body = '{"state":"done","progress":100}' }
	}
	return [pscustomobject]@{ Code = 200; Body = ('{"state":"' + $script:state + '","progress":0,"waiting_seconds":5,"missing_mib":1}') }
}
$remote_stall_timeout = 10; $remote_wait_timeout = 20
$env:REMOTE_POLL_SECONDS = '11'
# Опрос раз в 11 с. GPUOK: две проверки после старта — на 11-й и 22-й секунде, дольше
# stall_timeout, но меньше суммы, затем карта дана. Без «дана» отмена — на 33-й.
foreach ($case in @(@('GPUOK','waiting_gpu',2), @('GPUSTALL','waiting_gpu',0), @('RUN','running',0))) {
	$script:now = [datetime]'2026-01-01T00:00:00'
	$script:polls = 0; $script:deleted = $false
	$script:state = $case[1]; $script:maxPolls = $case[2]
	# Write-Host — поток 6; сливаем его с выводом, чтобы прочитать сообщение об отмене
	# («Задача job-8 не подаёт признаков движения N с»). Шаблон — без кириллицы:
	# harness без BOM, и PowerShell 5.1 прочёл бы её в ANSI-кодировке.
	$msg = (Wait-RemoteJob 'job-8' 'f' 6>&1 | Out-String)
	$m = [regex]::Match($msg, 'job-8\D+(\d+)')
	Write-Output ("{0}=stalled:{1} deleted:{2} limit:{3}" -f $case[0], $m.Success, $script:deleted, $m.Groups[1].Value)
}
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" -Module "$MODULE" 2>&1 | tr -d '\r')"
assert_contains "ожидание карты дольше stall_timeout не отменяется" "GPUOK=stalled:False deleted:False" "$_out"
assert_contains "ожидание карты дольше суммы отменяется" "GPUSTALL=stalled:True deleted:True limit:30" "$_out"
assert_contains "running отменяется по stall_timeout" "RUN=stalled:True deleted:True limit:10" "$_out"
rm -f "$_harness"

# Серия сбойных опросов: 502 при рестарте службы не должен стоить файла с первой
# же попытки, но и вечно повторяться не должен.
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_poll_" .ps1)"
cat > "$_harness" <<PSEOF
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [int]\$TimeoutMs = 60000)
	[void]\$script:calls.Add("\$Method \$Path")
	if (\$Method -eq 'DELETE') { return [pscustomobject]@{ Code = 200; Body = '{}' } }
	return [pscustomobject]@{ Code = 502; Body = 'bad gateway' }
}
# Пауза между сбойными опросами — виртуальная: реального ожидания нет.
\$script:now = [datetime]'2026-01-01T00:00:00'
function Get-Date { return \$script:now }
function Start-Sleep { param([int]\$Seconds) \$script:now = \$script:now.AddSeconds(\$Seconds) }
\$env:REMOTE_POLL_SECONDS = '1'
\$env:REMOTE_POLL_MAX_FAILS = '2'
\$ok = Wait-RemoteJob 'job-6' 'файл'
Write-Output "OK=\$ok"
Write-Output ("POLLS=" + (@(\$script:calls | Where-Object { \$_ -like 'GET *' }).Count))
\$script:calls | ForEach-Object { Write-Output \$_ }
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
assert_contains "серия сбойных опросов заканчивается отказом" "OK=False" "$_out"
assert_contains "сбойный опрос повторяется, а не валит сразу" "POLLS=2" "$_out"
assert_contains "после серии сбоев задача отменена" "DELETE /jobs/job-6" "$_out"
rm -f "$_harness"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: возобновление задачи из sidecar"
# ══════════════════════════════════════════════════════════════
# Двойник suite'а «возобновление задачи из sidecar» в test_21: обещание «после
# падения клиента на ожидании следующий запуск идёт в GET /jobs/{id}» здесь было
# недостижимо так же — sidecar удалялся сразу после complete, а запись job_id молча
# выходила по отсутствию файла. Ключ несёт номер части и подпись настроек.
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_jsc_" .ps1)"
_src="$(mktemp "${TMPDIR:-/tmp}/remote_jsrc_XXXXXX")"
printf 'source-bytes' > "$_src"
_src_win="$(cygpath -w "$_src" 2>/dev/null || echo "$_src")"
_sc="$(mktemp "${TMPDIR:-/tmp}/remote_jsc_file_XXXXXX")"; rm -f "$_sc"
_sc_win="$(cygpath -w "$_sc" 2>/dev/null || echo "$_sc")"
cat > "$_harness" <<PSEOF
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. '$MODULE'
\$remote_endpoint = 'http://mock.invalid/v1'
\$script:RemoteUploadSidecar = '$_sc_win'
\$src = '$_src_win'
\$it = Get-Item -LiteralPath \$src
\$mt = "\$([int64](\$it.LastWriteTimeUtc - [datetime]'1970-01-01').TotalSeconds)"
[System.IO.File]::WriteAllLines(\$script:RemoteUploadSidecar, @(
	'upload_id=up-70', "size=\$(\$it.Length)", "mtime=\$mt",
	"endpoint=\$remote_endpoint", 'sig=SIG-A', 'job.1=job-71', 'job.2=job-72'))
Write-Output ("P1=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-A'))
Write-Output ("P2=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 2 -Signature 'SIG-A'))
Write-Output ("P3=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 3 -Signature 'SIG-A'))
Write-Output ("SIGB=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-B'))
# Смена настроек: прежние задачи обязаны исчезнуть вместе с подписью.
Write-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-B' -JobId 'job-80'
Write-Output ("NEW=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-B'))
Write-Output ("OLD2=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 2 -Signature 'SIG-B'))
Write-Output ("KEEPUID=" + [bool]((Get-Content -LiteralPath \$script:RemoteUploadSidecar -Raw) -match 'up-70'))
# Файла может не быть — запись обязана его создать.
Remove-Item -LiteralPath \$script:RemoteUploadSidecar -Force
Write-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-C' -JobId 'job-90'
Write-Output ("CREATED=" + (Test-Path -LiteralPath \$script:RemoteUploadSidecar))
Write-Output ("AFTER=" + (Read-RemoteUploadSidecarJob -Source \$src -Part 1 -Signature 'SIG-C'))
# Запись — через соседний .tmp и File.Replace: WriteAllLines/AppendAllText прямо в
# целевой файл сперва его усекали, и обрыв стоил полной повторной загрузки.
# Сорванная запись (место .tmp занято каталогом) обязана оставить sidecar целым.
\$before = [System.IO.File]::ReadAllText(\$script:RemoteUploadSidecar)
[void](New-Item -ItemType Directory -Path "\$(\$script:RemoteUploadSidecar).tmp")
Write-RemoteUploadSidecar -UploadId 'up-99' -Size 1 -Source \$src
Set-RemoteUploadSidecarCompleted
Write-Output ("INTACT=" + (\$before -eq [System.IO.File]::ReadAllText(\$script:RemoteUploadSidecar)))
Remove-Item -LiteralPath "\$(\$script:RemoteUploadSidecar).tmp" -Force
Set-RemoteUploadSidecarCompleted
\$txt = [System.IO.File]::ReadAllText(\$script:RemoteUploadSidecar)
Write-Output ("MARKED=" + [bool](\$txt -match 'complete=yes'))
Write-Output ("JOBKEPT=" + [bool](\$txt -match 'job\.1=job-90'))
Write-Output ("NOTMP=" + (-not (Test-Path -LiteralPath "\$(\$script:RemoteUploadSidecar).tmp")))
# Подтверждённая загрузка не отправляется заново и НЕ подтверждается повторно.
[System.IO.File]::WriteAllLines(\$script:RemoteUploadSidecar, @(
	'upload_id=up-70', "size=\$(\$it.Length)", "mtime=\$mt",
	"endpoint=\$remote_endpoint", 'complete=yes'))
\$script:calls = New-Object System.Collections.ArrayList
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [byte[]]\$InBytes = \$null, [int]\$TimeoutMs = 60000)
	[void]\$script:calls.Add("\$Method \$Path")
	if (\$Path -like '*/probe') { return [pscustomobject]@{ Code = 200; Body = '{"duration":42}' } }
	if (\$Method -eq 'GET' -and \$Path -like '/uploads/*') {
		return [pscustomobject]@{ Code = 200; Body = ('{"received":' + \$it.Length + '}') }
	}
	if (\$Method -eq 'GET' -and \$Path -eq '/jobs/job-live') { return [pscustomobject]@{ Code = 200; Body = '{"state":"running"}' } }
	if (\$Method -eq 'GET' -and \$Path -eq '/jobs/job-dead') { return [pscustomobject]@{ Code = 404; Body = '{}' } }
	if (\$Method -eq 'GET' -and \$Path -eq '/jobs/job-bad')  { return [pscustomobject]@{ Code = 200; Body = '{"state":"failed"}' } }
	return [pscustomobject]@{ Code = 200; Body = '{}' }
}
function Invoke-RemoteHttpRetry { param([string]\$Method, [string]\$Path, [string]\$Body = '') return (Invoke-RemoteHttp \$Method \$Path \$Body) }
\$uid = Send-RemoteUpload \$src
Write-Output ("SKIPUID=\$uid")
Write-Output ("SKIPDUR=\$(\$script:RemoteUploadDuration)")
Write-Output ("PATCHED=" + [bool](\$script:calls -match '^PATCH'))
Write-Output ("RECOMPLETE=" + [bool](\$script:calls -match '/complete'))
Write-Output ("LIVE=" + (Test-RemoteJobUsable 'job-live'))
Write-Output ("DEAD=" + (Test-RemoteJobUsable 'job-dead'))
Write-Output ("BAD="  + (Test-RemoteJobUsable 'job-bad'))
Write-Output ("EMPTY=" + (Test-RemoteJobUsable ''))
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
_f() { printf '%s\n' "$_out" | grep "^${1}=" | sed "s/^${1}=//"; }
assert_eq "часть 1 читает свою задачу"        "job-71" "$(_f P1)"
assert_eq "часть 2 читает свою задачу"        "job-72" "$(_f P2)"
assert_empty "части без записи — пусто"                "$(_f P3)"
assert_empty "другая подпись настроек — пусто"         "$(_f SIGB)"
assert_eq "новая задача под новой подписью"   "job-80" "$(_f NEW)"
assert_empty "задача прежней подписи удалена"          "$(_f OLD2)"
assert_eq "upload_id пережил перезапись"      "True"   "$(_f KEEPUID)"
assert_eq "sidecar создан при записи задачи"  "True"   "$(_f CREATED)"
assert_eq "задача читается из созданного"     "job-90" "$(_f AFTER)"
assert_eq "сорванная запись не тронула sidecar" "True"  "$(_f INTACT)"
assert_eq "complete=yes дописан"              "True"   "$(_f MARKED)"
assert_eq "задача пережила пометку complete"  "True"   "$(_f JOBKEPT)"
assert_eq "временный .tmp не остаётся"        "True"   "$(_f NOTMP)"
assert_eq "идентификатор взят из sidecar"     "up-70"  "$(_f SKIPUID)"
assert_eq "длительность взята у probe"        "42"     "$(_f SKIPDUR)"
assert_eq "байты заново не отправляются"      "False"  "$(_f PATCHED)"
assert_eq "повторного complete нет"           "False"  "$(_f RECOMPLETE)"
assert_eq "живая задача годна"                "True"   "$(_f LIVE)"
assert_eq "исчезнувшая задача негодна"        "False"  "$(_f DEAD)"
assert_eq "провалившаяся задача негодна"      "False"  "$(_f BAD)"
assert_eq "пустой идентификатор негоден"      "False"  "$(_f EMPTY)"
rm -f "$_harness" "$_src" "$_sc"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: тонкий клиент + [split] length — субтитры с каждой частью"
# ══════════════════════════════════════════════════════════════
# Двойник suite'а в test_07. Без локального ffmpeg длительность знает только
# служба, поэтому видео грузится ДО цикла по частям, и загрузка субтитров, жившая
# внутри ветки «видео ещё не загружено», не исполнялась ни для одной части.
# Настоящий script.ps1; модуль подключён заранее, поэтому скрипт его не
# перечитывает, и подменённый Invoke-RemoteHttp остаётся в силе.
_tc_in="$(mktemp -d "${TMPDIR:-/tmp}/remote_tc_in_XXXXXX")"
_tc_out="$(mktemp -d "${TMPDIR:-/tmp}/remote_tc_out_XXXXXX")"
printf 'video-bytes' > "$_tc_in/clip.mp4"
printf '1\n00:00:01,000 --> 00:00:02,000\nhello\n' > "$_tc_in/clip.srt"
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_tc_" .ps1)"
cat > "$_harness" <<PSEOF
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
\$env:REMOTE_POLL_SECONDS = '0'
\$env:REMOTE_RETRY_SECONDS = '0'
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '',
	      [byte[]]\$InBytes = \$null, [int]\$TimeoutMs = 60000)
	[void]\$script:calls.Add("\$Method \$Path \$Body")
	\$b = switch ("\$Method \$Path") {
		'GET /capabilities'             { '{"args_version":"2","chunk_size":1048576}' }
		'POST /uploads'                 { '{"upload_id":"up-1"}' }
		'PATCH /uploads/up-1'           { '{}' }
		'POST /uploads/up-1/complete'   { '{"upload_id":"up-1","status":"complete"}' }
		'GET /uploads/up-1/probe'       { '{"duration":20}' }
		'POST /jobs'                    { '{"job_id":"job-1","state":"queued"}' }
		'GET /jobs/job-1'               { '{"job_id":"job-1","state":"failed","error":"test"}' }
		'DELETE /jobs/job-1'            { '{}' }
		default                         { \$null }
	}
	if (\$null -eq \$b) { return [pscustomobject]@{ Code = 404; Body = '{}' } }
	return [pscustomobject]@{ Code = 200; Body = \$b }
}
\$ErrorActionPreference = 'Continue'
\$folder_sources = (Get-Item -LiteralPath '$(cygpath -w "$_tc_in" 2>/dev/null || echo "$_tc_in")').FullName + [IO.Path]::DirectorySeparatorChar
\$folder_destination = (Get-Item -LiteralPath '$(cygpath -w "$_tc_out" 2>/dev/null || echo "$_tc_out")').FullName + [IO.Path]::DirectorySeparatorChar
\$ffmpeg = 'C:\nonexistent\ffmpeg-does-not-exist.exe'; \$ffprobe = \$ffmpeg
\$audio_codec=':+:aac'; \$audio_number_channels=':-:2'; \$audio_bitrate=':-:128'
\$audio_sampling_rate=':-:44100'; \$audio_normalize=':-:loudnorm'
\$video_codec=':+:libx264'; \$video_resolution=':-:1280x720'; \$video_bitrate=':-:2000'
\$video_number_frames=':-:25'; \$video_rotation=':-:2'; \$video_subtitles=':+:burn'
\$video_quality=':+:23'; \$keep_aspect_ratio=':+:yes'; \$output_container=':+:mp4'
\$multithreads=':-:4'; \$parallel_files=':-:2'
\$hw_accel=':-:nvidia'; \$gpu_preset=':-:p5'; \$gpu_tune=':-:hq'; \$gpu_rc=':-:vbr'
\$playback_speed=':-:1.0'; \$start_coding=':-:01-00-00'; \$length_coding=':+:00-00-10'
\$split_by_silence='no'; \$silence_duration='2.0'; \$silence_threshold='-30dB'
\$save_old_extension='no'; \$format_files_in='mp4'
\$subtitles_style=''; \$dry_run='no'; \$enable_log='no'; \$log_file=''
\$audio_only='no'; \$merge_files='no'; \$create_frame='no'
\$copy_codecs='no'; \$extract_audio_copy='no'; \$overwrite_existing='yes'
\$remote_enabled='yes'; \$remote_endpoint='http://mock.invalid/v1'; \$remote_api_key='k'
\$remote_api_key_command=''; \$remote_prefer='auto'; \$remote_wait_timeout='60'
\$remote_stall_timeout='60'; \$remote_on_failure='abort'
try { . '$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/FFmpeg_Converter_script.ps1' } catch {}
\$jobs = @(\$script:calls | Where-Object { \$_ -like 'POST /jobs *' })
Write-Output ("JOBS=" + \$jobs.Count)
Write-Output ("WITHSUB=" + @(\$jobs | Where-Object { \$_ -match 'subtitle_upload_id' }).Count)
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 < /dev/null | tr -d '\r')"
_f() { printf '%s\n' "$_out" | grep "^${1}=" | sed "s/^${1}=//"; }
assert_eq "задач создано по числу частей"          "2" "$(_f JOBS)"
assert_eq "каждая задача несёт subtitle_upload_id" "2" "$(_f WITHSUB)"
rm -f "$_harness"; rm -rf "$_tc_in" "$_tc_out"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: сбой записи результата не повторяется"
# ══════════════════════════════════════════════════════════════
# Общий catch в Invoke-RemoteHttp отдавал Code = 0 на ЛЮБОЕ исключение, включая
# ошибку записи результата на диск, а 0 считается обрывом связи — результат на
# 3 ГБ выкачивался заново до четырёх раз при заведомо неустранимой причине.
# Здесь настоящий Invoke-RemoteHttp против локального TCP-сервера (без http.sys и
# URL ACL): служба отвечает 200, а путь назначения ведёт в несуществующий каталог.
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_wr_" .ps1)"
_nodir="$(mktemp -d "${TMPDIR:-/tmp}/remote_wr_dir_XXXXXX")"
_nodir_win="$(cygpath -w "$_nodir" 2>/dev/null || echo "$_nodir")"
cat > "$_harness" <<PSEOF
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
. '$MODULE'
\$env:REMOTE_RETRY_SECONDS = '0'
\$tl = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
\$tl.Start()
\$hits = [hashtable]::Synchronized(@{ n = 0; mode = 'ok' })
\$srv = [PowerShell]::Create().AddScript({
	param(\$tl, \$hits)
	while (\$true) {
		\$c = \$tl.AcceptTcpClient(); \$hits.n++
		try {
			\$s = \$c.GetStream(); \$b = New-Object byte[] 8192; [void]\$s.Read(\$b, 0, \$b.Length)
			\$head = "HTTP/1.1 200 OK\`r\`nContent-Length: 6\`r\`nConnection: close\`r\`n\`r\`n"
			# silent — соединение принято, заголовков нет; stall — заголовки сразу, тело с паузой.
			if (\$hits.mode -eq 'silent') { Start-Sleep -Milliseconds 900 }
			if (\$hits.mode -eq 'stall') {
				\$r = [System.Text.Encoding]::ASCII.GetBytes(\$head + 'RES'); \$s.Write(\$r, 0, \$r.Length); \$s.Flush()
				Start-Sleep -Milliseconds 900
				\$r = [System.Text.Encoding]::ASCII.GetBytes('ULT')
			} else {
				\$r = [System.Text.Encoding]::ASCII.GetBytes(\$head + 'RESULT')
			}
			\$s.Write(\$r, 0, \$r.Length); \$s.Flush()
		} catch {}
		\$c.Close()
	}
}).AddArgument(\$tl).AddArgument(\$hits)
[void]\$srv.BeginInvoke()
\$remote_endpoint = "http://127.0.0.1:\$(\$tl.LocalEndpoint.Port)/v1"
\$remote_api_key = 'k'
\$ok = Join-Path '$_nodir_win' 'ok.bin'
\$r = Invoke-RemoteHttpRetry GET '/jobs/j/result' '' @{} \$ok '' \$null 5000
Write-Output ("OKCODE=" + \$r.Code)
Write-Output ("OKBODY=" + [System.IO.File]::ReadAllText(\$ok))
\$hits.n = 0
\$bad = Join-Path '$_nodir_win' 'no-such-dir\res.bin'
\$r = Invoke-RemoteHttpRetry GET '/jobs/j/result' '' @{} \$bad '' \$null 5000
Write-Output ("BADCODE=" + \$r.Code)
Write-Output ("BADHITS=" + \$hits.n)
Write-Output ("RECV=" + (Receive-RemoteResult 'j' \$bad))
# Timeout у HttpWebRequest ограничивает путь ДО заголовков, а не чтение тела — на
# этом стоит короткий таймаут скачивания в Receive-RemoteResult. Проверяем на живом
# сокете обе стороны: молчащая служба отваливается по Timeout, а тело, идущее дольше
# Timeout с паузой, читается целиком (его стережёт ReadWriteTimeout).
# Порядок важен: сервер однопоточный, и после молчащего ответа он ещё спит, а это
# съело бы Timeout следующего запроса. Поэтому сначала тело с паузой, потом молчание.
\$hits.mode = 'stall'
Remove-Item -LiteralPath \$ok -Force -ErrorAction SilentlyContinue
\$r = Invoke-RemoteHttp GET '/jobs/j/result' '' @{} \$ok '' \$null 400
Write-Output ("STALLCODE=" + \$r.Code)
Write-Output ("STALLBODY=" + [System.IO.File]::ReadAllText(\$ok))
\$hits.mode = 'silent'
\$r = Invoke-RemoteHttp GET '/jobs/j/result' '' @{} \$ok '' \$null 400
Write-Output ("SILENTCODE=" + \$r.Code)
\$tl.Stop()
# Какой Timeout Receive-RemoteResult на самом деле передаёт в HTTP-слой.
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '', [hashtable]\$Headers = @{},
	      [string]\$OutFile = '', [string]\$InFile = '', [byte[]]\$InBytes = \$null, [int]\$TimeoutMs = 60000)
	\$script:seenTimeout = \$TimeoutMs
	return [pscustomobject]@{ Code = 200; Body = '' }
}
[void](Receive-RemoteResult 'j' \$ok)
Write-Output ("RESULTTIMEOUT=" + \$script:seenTimeout)
PSEOF
_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
_f() { printf '%s\n' "$_out" | grep "^${1}=" | sed "s/^${1}=//"; }
assert_eq "исправный путь: результат записан"      "200"    "$(_f OKCODE)"
assert_eq "исправный путь: содержимое целиком"     "RESULT" "$(_f OKBODY)"
assert_eq "сбой записи — отдельный код -1"          "-1"     "$(_f BADCODE)"
assert_eq "сбой записи не повторяется"              "1"      "$(_f BADHITS)"
assert_eq "Receive-RemoteResult отдаёт отказ"       "False"  "$(_f RECV)"
assert_contains "причина названа, а не «HTTP -1»"   "запись на диск не удалась" "$_out"
assert_eq "молчащая служба: отказ по Timeout, а не ожидание" "0"      "$(_f SILENTCODE)"
assert_eq "тело дольше Timeout не обрывается"                "200"    "$(_f STALLCODE)"
assert_eq "тело с паузой дочитано целиком"                   "RESULT" "$(_f STALLBODY)"
# Прежний час означал, что принявшая соединение и молчащая служба вешала клиента на час.
# 600 с — паритет с .sh (--speed-limit 1 --speed-time 600 и до заголовков, и на тело).
assert_eq "скачивание результата — Timeout 600 с, как у .sh"  "600000" "$(_f RESULTTIMEOUT)"
rm -f "$_harness"; rm -rf "$_nodir"

# ══════════════════════════════════════════════════════════════
suite "remote PS1: валидация числовых значений config.ini"
# ══════════════════════════════════════════════════════════════
# Паритет с suite'ом «валидация числовых значений config.ini» в test_21: всё, что
# уезжает в JSON без кавычек, обязано проверяться ДО загрузки гигабайт. Проверялся
# здесь только bitrate, хотя «23 кбит» в quality давало невалидное тело.
_vsetup='
$remote_wait_timeout=1800; $remote_stall_timeout=900
$remote_prefer="auto"; $remote_on_failure="abort"
$video_resolution_status="-"; $video_bitrate_status="-"; $audio_bitrate_status="-"
$video_number_frames_status="-"; $audio_number_channels_status="-"
$audio_sampling_rate_status="-"; $playback_speed_status="-"; $threads=4
$video_quality_status="+"; $video_quality_value="23"
'
assert_eq "числовой quality проходит" "True" \
  "$(run_ps "$_vsetup; Test-RemoteConfigValues" | tail -1)"
_out="$(run_ps "$_vsetup; \$video_quality_value='23 кбит'; Test-RemoteConfigValues")"
assert_contains "нечисловой quality отклонён" "quality" "$_out"
assert_contains "и результат — отказ"         "False"   "$_out"
_out="$(run_ps "$_vsetup; \$video_number_frames_status='+'; \$video_number_frames_value='30fps'; Test-RemoteConfigValues")"
assert_contains "нечисловой fps отклонён" "number_frames" "$_out"
assert_eq "дробная скорость проходит" "True" \
  "$(run_ps "$_vsetup; \$playback_speed_status='+'; \$playback_speed_value='1.5'; Test-RemoteConfigValues" | tail -1)"
_out="$(run_ps "$_vsetup; \$playback_speed_status='+'; \$playback_speed_value='1,5'; Test-RemoteConfigValues")"
assert_contains "запятая в скорости отклонена" "playback_speed" "$_out"
_out="$(run_ps "$_vsetup; \$threads='много'; Test-RemoteConfigValues")"
assert_contains "нечисловые threads отклонены" "threads" "$_out"

summary
