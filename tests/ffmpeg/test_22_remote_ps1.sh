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
