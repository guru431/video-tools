#!/bin/bash
# ============================================================
# test_29_asr_ps1_integration.sh — режим распознавания сквозь настоящий
# FFmpeg_Converter_script.ps1: мок ffmpeg.cmd и подменённый Invoke-AsrCurl,
# настоящие выборка входов, зеркало подпапок, пропуск готового, конфликт
# выходов, исходы «файл / прогон», части, сводка и код возврата. Те же
# сценарии, что test_28 для .sh: файловый цикл .ps1 — основной путь в
# Windows (GUI и EXE). Один процесс PowerShell на сценарий: воркер кончается exit.
# Исход сверяется по счётчику «Ошибки» в сводке, а не по коду процесса: `exit`
# дот-сорснутого воркера в PS 5.1 под -File даёт процессу 0 — давний дефект
# CLI-обёртки, записан в FINDINGS.md (2026-10-02).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

PS_BIN=""
for _c in powershell.exe powershell; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
# Мок ffmpeg для воркера .ps1 — это .cmd: вне Windows его не запустить.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) ;; *) PS_BIN="" ;; esac
if [ -z "$PS_BIN" ]; then
    suite "ASR PS1: сквозной прогон воркера"
    skip "сквозной прогон воркера .ps1" "нужен Windows PowerShell (мок ffmpeg — .cmd)"
    summary
    exit 0
fi

_w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
FIX="$TESTS_DIR/fixtures/asr"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_ps1int_XXXXXX")"
IN="$WORK/in"; OUT="$WORK/out"
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_ps1int_" .ps1)"

# Harness ASCII-only: пишется без BOM, а PowerShell 5.1 читает такой файл в ANSI.
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Worker, [string]$MockFf, [string]$Fix, [string]$In, [string]$Out, [string]$Overwrite = 'no')
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$folder_sources = $In; $folder_destination = $Out
$audio_only = 'no'; $merge_files = 'no'; $create_frame = 'no'; $copy_codecs = 'no'
$extract_audio_copy = 'no'; $overwrite_existing = $Overwrite
$multithreads = ':+:4'; $parallel_files = ':-:1'
$audio_codec = ':+:aac'; $audio_number_channels = ':+:2'; $audio_bitrate = ':+:128'
$audio_sampling_rate = ':+:48000'; $audio_normalize = ':-:loudnorm'
$video_codec = ':+:libx264'; $video_resolution = ':-:1280x720'; $video_bitrate = ':-:3000'
$video_number_frames = ':-:30'; $video_rotation = ':-:2'; $video_subtitles = ':-:burn'
$video_quality = ':+:23'; $keep_aspect_ratio = ':+:yes'; $output_container = ':+:mp4'
$hw_accel = ':-:intel'; $gpu_preset = ':-:p5'; $gpu_tune = ':-:hq'; $gpu_rc = ':-:vbr'
$playback_speed = ':-:1.0'
$start_coding = ':-:01-00-00'; $length_coding = ':-:00-05-00'; $split_by_silence = 'no'
$silence_duration = '2.0'; $silence_threshold = '-30dB'
$ffmpeg = $MockFf; $save_old_extension = 'no'
$format_files_in = 'mp4,mkv,avi'; $subtitles_style = ''
$dry_run = 'no'; $enable_log = 'no'; $log_file = (Join-Path $Out 'x.log')
$remote_enabled = 'no'; $remote_endpoint = ''; $remote_api_key = ''
$remote_api_key_command = ''; $remote_prefer = 'auto'; $remote_wait_timeout = '1800'
$remote_stall_timeout = '900'; $remote_on_failure = 'abort'
$asr_enabled = 'yes'; $asr_endpoint = 'https://asr.example:30010'; $asr_api_key = 'int-secret-key'
$asr_api_key_command = ''; $asr_pinned_pubkey = ''; $asr_language = 'ru'; $asr_diarize = 'yes'; $asr_num_speakers = ''
. $Module
# The network: limits from the fixture; transcription answers with ASR_T_CODE.
function Invoke-AsrCurl {
    param([string]$Dir, [string[]]$CurlArgs)
    $url = $CurlArgs[-1]
    Add-Content -LiteralPath $env:ASR_T_LOG -Value $url
    $i = [array]::IndexOf($CurlArgs, '-o')
    $o = Join-Path $Dir $CurlArgs[$i + 1]
    if ($url -like '*/speech/limits') {
        [System.IO.File]::WriteAllText($o, [System.IO.File]::ReadAllText((Join-Path $Fix 'limits.json')))
        return [pscustomobject]@{ Rc = 0; Code = '200'; Err = ''; Cancelled = $false }
    }
    $code = $env:ASR_T_CODE
    $body = if ($code -eq '200') { [System.IO.File]::ReadAllText((Join-Path $Fix 'basic.json')) } else { '{"detail":"bad-thing"}' }
    [System.IO.File]::WriteAllText($o, $body)
    return [pscustomobject]@{ Rc = 0; Code = $code; Err = ''; Cancelled = $false }
}
. $Worker
PSEOF

# RUN_OUT ← вывод воркера; $1 — HTTP-код распознавания,
# $2 — overwrite_existing, $3 — каталог назначения (по умолчанию $OUT).
run_ps() {
    local code="$1" ow="${2:-no}" out="${3:-$OUT}"
    ASR_T_CODE="$code" ASR_T_LOG="$(_w "$WORK/curl.log")" MOCK_FFMPEG_LOG="$WORK/ff.log" \
    FFCONV_ASR_NOW="2026-10-02 12:00" ASR_RETRY_WAIT=0 \
        "$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
        -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Worker "$(_w "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")" \
        -MockFf "$(_w "$TESTS_DIR/mocks/ffmpeg.cmd")" -Fix "$(_w "$FIX")" \
        -In "$(_w "$IN")" -Out "$(_w "$out")" -Overwrite "$ow" > "$WORK/run.raw" 2>&1 < /dev/null
    RUN_OUT="$(tr -d '\r' < "$WORK/run.raw")"
}
reset_dirs() { rm -rf "$IN" "$OUT" "$WORK/ff.log" "$WORK/curl.log"; mkdir -p "$IN" "$OUT"; }
posts() { POSTS=0; [ -f "$WORK/curl.log" ] && POSTS="$(grep -c 'speech/transcriptions' "$WORK/curl.log")"; }

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: файл целиком — кириллица и пробел, зеркало подпапки"
# ══════════════════════════════════════════════════════════════
reset_dirs; mkdir -p "$IN/sub"; : > "$IN/sub/Встреча 1.mp4"
run_ps 200
assert_contains "ошибок нет" "Ошибки:      0" "$RUN_OUT"
_txt="$OUT/sub/Встреча 1.txt"
assert_file_exists "расшифровка в зеркале подпапки" "$_txt"
assert_eq "шапка называет исходный файл" "# Расшифровка: Встреча 1.mp4" "$(head -1 "$_txt" 2>/dev/null)"
assert_eq "остальное — как у фикстуры" "$(tail -n +2 "$FIX/basic.txt")" "$(tail -n +2 "$_txt" 2>/dev/null)"
assert_eq "сырой ответ сохранён" "$(cat "$FIX/basic.json")" "$(cat "$OUT/sub/Встреча 1.asr.json" 2>/dev/null)"
posts; assert_eq "один запрос" "1" "$POSTS"
assert_contains "сводка" "Обработано:  1" "$RUN_OUT"
assert_not_contains "ключ не печатается" "int-secret-key" "$RUN_OUT"
assert_empty "временных файлов в назначении нет" "$(find "$OUT" -name '.ffconv-partial-*')"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: готовое пропускается; overwrite_existing = yes — пересчёт"
# ══════════════════════════════════════════════════════════════
rm -f "$WORK/curl.log"
run_ps 200
assert_contains "повтор — ошибок нет" "Ошибки:      0" "$RUN_OUT"
assert_contains "пропуск назван" "расшифровка уже есть" "$RUN_OUT"
posts; assert_eq "повтор не отправляет запись" "0" "$POSTS"
rm -f "$WORK/curl.log"
run_ps 200 yes
posts; assert_eq "overwrite — запрос снова" "1" "$POSTS"
assert_contains "overwrite — ошибок нет" "Ошибки:      0" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: два входа на один .txt"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/x.mp4"; : > "$IN/x.mkv"
run_ps 200
assert_contains "коллизия — одна ошибка" "Ошибки:      1" "$RUN_OUT"
assert_contains "конфликт назван" "конфликт выходов" "$RUN_OUT"
posts; assert_eq "отправлен только первый" "1" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: 400 — провален файл, прогон продолжается"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
run_ps 400
assert_contains "две ошибки" "Ошибки:      2" "$RUN_OUT"
posts; assert_eq "оба файла отправлены" "2" "$POSTS"
assert_contains "detail дословно" "HTTP 400: bad-thing" "$RUN_OUT"
assert_not_contains "прогон не останавливался" "Остановлено:" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: 401 — прогон остановлен, остаток не тронут"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
run_ps 401
assert_contains "одна ошибка" "Ошибки:      1" "$RUN_OUT"
posts; assert_eq "только один запрос" "1" "$POSTS"
assert_contains "причина в сводке" "Остановлено: ключ не принят (HTTP 401)" "$RUN_OUT"
assert_contains "остаток посчитан" "Не обработано: 1" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: длинная запись — части, смещения, последняя без -t"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/long.mp4"
MOCK_FFMPEG_DURATION=01:00:00.00 run_ps 200
assert_contains "ошибок нет" "Ошибки:      0" "$RUN_OUT"
posts; assert_eq "три запроса" "3" "$POSTS"
_j="$(cat "$OUT/long.asr.json" 2>/dev/null)"
assert_contains "обёртка частей" '{"chunks":[{"offset_seconds":0,"response":' "$_j"
assert_contains "смещение третьей" '"offset_seconds":2402,"response":' "$_j"
assert_contains "шапка о частях" "# Частей: 3 по ≈00:20:01 — метки говорящих в разных частях независимы" "$(cat "$OUT/long.txt" 2>/dev/null)"
_ff="$(cat "$WORK/ff.log" 2>/dev/null)"
assert_contains "вторая часть с длиной" "-ss 1201 -t 1201" "$_ff"
assert_not_contains "у последней части нет -t" "-t 1199" "$_ff"

# ══════════════════════════════════════════════════════════════
suite "ASR PS1: destination = source"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"
run_ps 200 no "$IN"
assert_file_exists "рядом с записью" "$IN/a.txt"
rm -f "$WORK/curl.log"
run_ps 200 no "$IN"
posts; assert_eq "повтор in-place не отправляет" "0" "$POSTS"

rm -f "$HARNESS"
rm -rf "$WORK"
summary
