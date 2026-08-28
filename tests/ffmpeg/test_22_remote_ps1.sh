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
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '')
	\$range = if (\$Headers.ContainsKey('Content-Range')) { \$Headers['Content-Range'] } else { '' }
	[void]\$script:calls.Add("\$Method \$Path \$range \$Body")
	if (\$Method -eq 'POST' -and \$Path -eq '/uploads') {
		return [pscustomobject]@{ Code = 200; Body = '{"upload_id":"up-99","chunk_size":1024}' }
	}
	if (\$Method -eq 'GET' -and \$Path -like '/uploads/*') {
		return [pscustomobject]@{ Code = 200; Body = '{"received":0}' }
	}
	return [pscustomobject]@{ Code = 200; Body = '{}' }
}
\$uid = Send-RemoteUpload '$_payload_win'
Write-Output "UID=\$uid"
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
rm -f "$_harness" "$_payload"

summary
