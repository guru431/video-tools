#!/bin/bash
# ============================================================
# test_26_asr_ps1.sh — PS1-модуль распознавания (дот-сорсинг настоящего
# asr_client.ps1): те же случаи, что test_25 для .sh, и те же ожидаемые .txt из
# tests/fixtures/asr; плюс настоящий запуск curl.exe и отмена (только Windows).
# Один запуск PowerShell на весь файл: процесс дорог.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "ASR PS1"
    skip "PS1-модуль распознавания" "PowerShell не найден"
    summary
    exit 0
fi

_w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
FIX="$TESTS_DIR/fixtures/asr"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_ps1_XXXXXX")"
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_ps1_" .ps1)"

# Harness ASCII-only: пишется без BOM, а PowerShell 5.1 читает такой файл в ANSI.
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Fix, [string]$Work)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Log-Msg { param([string]$Level, [string]$Msg) Write-Output "LOG=[$Level] $Msg" }
function Write-GUIProgress { param([int]$FilePercent = 0, [string]$CurrentFile = '', [string]$Phase = '') }
. $Module
function J { param([object[]]$A) return ($A -join '|') }

Write-Output ("EP=" + (J @(Format-AsrEndpoints '  https://a.example:30010/  http://b.example:30000//  ')))
Write-Output ("EP_EMPTY=" + @(Format-AsrEndpoints '').Count)

$l = Get-AsrLimits ([System.IO.File]::ReadAllText((Join-Path $Fix 'limits.json')))
Write-Output ("LIM=" + (J @($l.MaxSeconds, $l.MaxBytes, $l.JobTimeout, $l.Device, $l.Diarization, $l.Ver)))
Write-Output ("LANGS=" + $l.Languages)
Write-Output ("LIM_BAD=" + [string]($null -eq (Get-AsrLimits '<html>502</html>')))
$o = Get-AsrLimits '{"max_seconds":"3600","job_timeout_sec":1800.7,"device":"CPU","languages":null,"max_bytes":"x"}'
Write-Output ("LIM_ODD=" + (J @($o.MaxSeconds, $o.MaxBytes, $o.JobTimeout, $o.Languages, (Get-AsrPlan 0 $o.MaxSeconds $o.JobTimeout $o.Device).Whole)))
$rej = @('{"max_seconds":"abc","job_timeout_sec":1800}', '{"max_seconds":null,"job_timeout_sec":1800}',
         '{"max_seconds":-5,"job_timeout_sec":1800}', '{"max_seconds":99999999999999999999,"job_timeout_sec":1800}',
         '{"max_seconds":1,"job_timeout_sec":1800}', '{"max_seconds":3600,"job_timeout_sec":1,"device":"cpu"}')
Write-Output ("LIM_REJ=" + (J @($rej | ForEach-Object { [int]($null -eq (Get-AsrLimits $_)) })))

foreach ($d in 2999, 3000, 3001, 5400) { Write-Output ("PLAN_cpu_$d=" + ((Get-AsrPlan $d 3600 1800 'cpu').Parts -join ' ')) }
$p = Get-AsrPlan 3001 3600 1800 'cpu'
Write-Output ("PLANLEN=" + $p.PartLen + '|' + $p.Whole)
foreach ($d in 7200, 7201) { Write-Output ("PLAN_cuda_$d=" + ((Get-AsrPlan $d 7200 1800 'cuda').Parts -join ' ')) }

$script:AsrLimits = $l
$asr_language = 'ru'; $asr_diarize = 'yes'; $asr_num_speakers = ''; $asr_pinned_pubkey = ''
Write-Output ("ARGS_NOPIN=" + (J @(Get-AsrCurlArgs 'https://h.example:30010' 'part_000.flac' 'resp_000.json')))
$asr_pinned_pubkey = 'sha256//AAA='
Write-Output ("ARGS_PIN=" + (J @(Get-AsrCurlArgs 'https://h.example:30010' 'part_000.flac' 'resp_000.json')))
Write-Output ("ARGS_HTTP=" + (J @(Get-AsrCurlArgs 'http://h.example:30000' 'part_000.flac' 'resp_000.json')))
$asr_diarize = 'no'; $asr_num_speakers = '4'
Write-Output ("ARGS_N=" + (J @(Get-AsrCurlArgs 'http://h.example:30000' 'part_001.flac' 'resp_001.json')))
Write-Output ("ARGS_BYTES=" + (J @(Get-AsrCurlArgs 'http://h.example:30000' 'part_000.flac' 'resp_000.json' 65000000)))
Write-Output ("FF=" + (J @(Get-AsrFfArgs '/in/a b.mp4' 1001 999 3 'part_001.flac')))
Write-Output ("FF_LAST=" + (J @(Get-AsrFfArgs '/in/a.mp3' 2002 '' 3 'part_002.flac')))
$asr_diarize = 'yes'; $asr_num_speakers = ''; $asr_pinned_pubkey = ''

foreach ($c in '0|200|', '0|400|bad-lang', '0|413|', '0|401|', '0|500|', '0|504|', '90|000|', '28|000|', '26|000|', '7|000|') {
    $rc, $code, $det = $c.Split('|')
    $o = Get-AsrOutcome ([int]$rc) $code $det 'Failed to connect'
    Write-Output ("CL_${rc}_$code=" + $o.Outcome + '|' + $o.Reason)
}

$cases = @(
    @{ Want = 'basic.txt';   Src = 'meeting.mp4'; Len = 480;  Parts = @(,@('basic.json', 0)) },
    @{ Want = 'escapes.txt'; Src = 'escapes.mkv'; Len = 76;   Parts = @(,@('escapes.json', 0)) },
    @{ Want = 'chunks.txt';  Src = 'long.mp4';    Len = 1001; Parts = @(@('basic.json', 0), @('escapes.json', 1001)) },
    @{ Want = 'empty.txt';   Src = 'silence.wav'; Len = 10;   Parts = @(,@('empty.json', 0)) },
    @{ Want = 'monologue.txt'; Src = 'lecture.mp3'; Len = 130; Parts = @(,@('monologue.json', 0)) }
)
foreach ($case in $cases) {
    $parts = @($case.Parts | ForEach-Object { [pscustomobject]@{ File = (Join-Path $Fix $_[0]); Offset = [int64]$_[1] } })
    $s = Write-AsrTranscript $case.Src '2026-10-02 12:00' $case.Len (Join-Path $Work ('ps_' + $case.Want)) $parts
    Write-Output ("SUM_" + $case.Want + "=" + $s.Speakers + '|' + $s.Low + '|' + $s.Bad)
}
$one = [pscustomobject]@{ File = (Join-Path $Fix 'basic.json'); Offset = 0 }
$two = [pscustomobject]@{ File = (Join-Path $Fix 'escapes.json'); Offset = 1001 }
Write-AsrJson (Join-Path $Work 'ps_one.json') @($one)
Write-AsrJson (Join-Path $Work 'ps_two.json') @($one, $two)
try {
    $tw = [System.IO.File]::ReadAllText((Join-Path $Work 'ps_two.json')) | ConvertFrom-Json
    Write-Output ("TWO=" + $tw.chunks.Count + '|' + $tw.chunks[1].offset_seconds)
} catch { Write-Output 'TWO=parse-error' }

$vc = @('https://a:1|ru|yes|', '|ru|yes|', 'ftp://a|ru|yes|', 'https://a:1||yes|', 'https://a:1|ru|maybe|',
        'https://a:1|ru|yes|0', 'https://a:1|ru|yes|51', 'https://a:1|ru|yes|abc', 'https://a:1|ru|yes|1', 'https://a:1|ru|yes|50',
        'https://a:1|ru|yes|99999999999999999999', 'https://a:1|ru|yes|05')
for ($i = 0; $i -lt $vc.Count; $i++) {
    $asr_endpoint, $asr_language, $asr_diarize, $asr_num_speakers = $vc[$i].Split('|')
    $ok = Test-AsrConfigValues
    Write-Output ("VC_$i=" + [int](-not $ok))
}
$asr_endpoint = ''; $asr_language = 'ru'; $asr_diarize = 'yes'; $asr_num_speakers = ''

$script:AsrApiKeyResolved = $false; $asr_api_key = ''; $asr_api_key_command = 'Write-Output "  cmd-key  "'
$r = Resolve-AsrApiKey
Write-Output ("KEYCMD=" + $r + '|' + $asr_api_key)
$asr_api_key_command = ''

# Real Invoke-AsrCurl: a fake curl (.cmd) and cancellation. Windows only.
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $fake = Join-Path $Work 'fakecurl.cmd'
    [System.IO.File]::WriteAllText($fake, "@echo off`r`necho %* > `"%~dp0args.txt`"`r`nfindstr `"^`" > `"%~dp0stdin.txt`"`r`necho 200`r`nexit /b 0`r`n")
    $env:CURL_BIN = $fake
    $asr_api_key = 'k-123'
    # Console in UTF-8 (chcp 65001, "UTF-8 for worldwide language support"): .NET opens the
    # child's stdin with Console.InputEncoding, i.e. UTF-8 WITH a BOM, and curl rejects a
    # config that starts with it ("option --config: is unknown"). Reproduce that condition.
    $savedIn = $null
    try { $savedIn = [Console]::InputEncoding; [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
    $r = Invoke-AsrCurl $Work @('-sS', '-o', 'x.json', '-w', '%{http_code}', 'https://h.example/speech/limits')
    if ($savedIn) { try { [Console]::InputEncoding = $savedIn } catch {} }
    Write-Output ("REAL_RC=" + $r.Rc + '|' + $r.Code)
    $stdinBytes = [System.IO.File]::ReadAllBytes((Join-Path $Work 'stdin.txt'))
    Write-Output ("REAL_STDIN_FIRST=" + $(if ($stdinBytes.Length) { $stdinBytes[0] } else { -1 }))
    Write-Output ("REAL_STDIN=" + ([System.IO.File]::ReadAllText((Join-Path $Work 'stdin.txt'))).Trim())
    Write-Output ("REAL_ARGS=" + ([System.IO.File]::ReadAllText((Join-Path $Work 'args.txt'))).Trim())
    $slow = Join-Path $Work 'slowcurl.cmd'
    [System.IO.File]::WriteAllText($slow, "@echo off`r`nping -n 8 127.0.0.1 >nul`r`necho 200`r`n")
    $env:CURL_BIN = $slow
    $script:AsrCancelCheck = { $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-AsrCurl $Work @('-sS', 'https://h.example/x')
    Write-Output ("CANCEL=" + $r.Cancelled + '|' + [int]($sw.Elapsed.TotalSeconds -lt 5))
    # The run dir is removed right after a cancel: the killed process must be gone by then.
    Write-Output ("CANCEL_DEAD=" + [int]($r.Pid -gt 0 -and $null -eq (Get-Process -Id $r.Pid -ErrorAction SilentlyContinue)))
    # Audio extraction: the same cancellation, and the first non-empty stderr line as the reason.
    $ffmpeg = Join-Path $Work 'slowff.cmd'
    [System.IO.File]::WriteAllText($ffmpeg, "@echo off`r`nping -n 8 127.0.0.1 >nul`r`n")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $x = Invoke-AsrExtract @('-nostdin', '-i', 'in.mp4', 'out.flac')
    Write-Output ("EX_CANCEL=" + $x.Cancelled + '|' + [int]($sw.Elapsed.TotalSeconds -lt 5))
    $script:AsrCancelCheck = $null
    $ffmpeg = Join-Path $Work 'badff.cmd'
    [System.IO.File]::WriteAllText($ffmpeg, "@echo off`r`necho.>&2`r`necho moov atom not found>&2`r`necho Error opening input file>&2`r`nexit /b 3`r`n")
    $x = Invoke-AsrExtract @('-nostdin', '-i', 'in.mp4', 'out.flac')
    Write-Output ("EX_FAIL=" + $x.Rc + '|' + $x.Err + '|' + $x.Cancelled)
    Remove-Item Env:CURL_BIN
} else { Write-Output 'REAL=skip' }

# Substituted Invoke-AsrCurl: endpoint selection and a part request.
$script:AsrRunDir = $Work
$script:codes = @(); $script:calls = 0; $script:body = ''
function Invoke-AsrCurl {
    param([string]$Dir, [string[]]$CurlArgs)
    $script:calls++
    if ($script:cancelAll) { return [pscustomobject]@{ Rc = -1; Code = '000'; Err = 'cancelled'; Cancelled = $true } }
    $url = $CurlArgs[-1]
    if ($url -like 'https://a.example*') { return [pscustomobject]@{ Rc = 7; Code = '000'; Err = 'Failed to connect'; Cancelled = $false } }
    $i = [array]::IndexOf($CurlArgs, '-o')
    $out = Join-Path $Dir $CurlArgs[$i + 1]
    if ($url -like '*/speech/limits') {
        [System.IO.File]::WriteAllText($out, [System.IO.File]::ReadAllText((Join-Path $Fix 'limits.json')))
        return [pscustomobject]@{ Rc = 0; Code = '200'; Err = ''; Cancelled = $false }
    }
    $code = '200'
    if ($script:codes.Count -gt 0) { $code = $script:codes[0]; $script:codes = @($script:codes | Select-Object -Skip 1) }
    [System.IO.File]::WriteAllText($out, $script:body)
    return [pscustomobject]@{ Rc = 0; Code = $code; Err = ''; Cancelled = $false }
}
$asr_endpoint = 'https://a.example:30010 https://b.example:30010'
# Stop pressed while the first address is being asked: no second address, the reason is "cancelled".
$script:cancelAll = $true; $script:calls = 0
$ok = Select-AsrEndpoint
Write-Output ("SEL_CANCEL=" + $ok + '|' + $script:calls + '|' + $script:AsrStopReason)
$script:cancelAll = $false
$ok = Select-AsrEndpoint
Write-Output ("SEL=" + $ok + '|' + $script:AsrBase + '|' + $script:AsrLimits.JobTimeout)
$env:ASR_RETRY_WAIT = '0'
$script:body = [System.IO.File]::ReadAllText((Join-Path $Fix 'basic.json'))
$script:codes = @('503', '503', '200'); $script:calls = 0
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_RETRY=" + $o.Outcome + '|' + $script:calls)
$env:ASR_RETRIES = '2'; $script:codes = @('503', '503', '503', '503'); $script:calls = 0
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_FULL=" + $o.Outcome + '|' + $script:calls)
Remove-Item Env:ASR_RETRIES
$script:body = '<html>gateway</html>'; $script:codes = @('200')
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_HTML=" + $o.Outcome + '|' + $o.Reason)
PSEOF

out="$("$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
    -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Fix "$(_w "$FIX")" -Work "$(_w "$WORK")" 2>&1 | tr -d '\r')"
rm -f "$HARNESS"
get_field() { printf '%s\n' "$out" | grep "^${1}=" | head -1 | sed "s/^${1}=//"; }

suite "ASR PS1: адреса и пределы"
assert_eq "два адреса, слэши сняты" "https://a.example:30010|http://b.example:30000" "$(get_field EP)"
assert_eq "пустая строка — ни одного" "0" "$(get_field EP_EMPTY)"
assert_eq "пределы" "3600|524288000|1800|cpu|true|large-v3-turbo.cpu.int8.v1" "$(get_field LIM)"
assert_eq "языки" "en ru" "$(get_field LANGS)"
assert_eq "не пределы — null" "True" "$(get_field LIM_BAD)"
assert_eq "числа строкой, CPU, languages: null, нечисловой max_bytes" "3600|0|1800||3000" "$(get_field LIM_ODD)"
assert_eq "нечисловое, null, отрицательное, огромное, W < 2 — не пределы (без исключения)" "1|1|1|1|1|1" "$(get_field LIM_REJ)"

suite "ASR PS1: план частей — те же числа, что в .sh"
assert_eq "2999" "0:2999" "$(get_field PLAN_cpu_2999)"
assert_eq "3000" "0:3000" "$(get_field PLAN_cpu_3000)"
assert_eq "3001" "0:1001 1001:1001 2002:999" "$(get_field PLAN_cpu_3001)"
assert_eq "5400" "0:1350 1350:1350 2700:1350 4050:1350" "$(get_field PLAN_cpu_5400)"
assert_eq "длина и предел" "1001|3000" "$(get_field PLANLEN)"
assert_eq "cuda 7200" "0:7200" "$(get_field PLAN_cuda_7200)"
assert_eq "cuda 7201" "0:2401 2401:2401 4802:2399" "$(get_field PLAN_cuda_7201)"

suite "ASR PS1: аргументы curl и ffmpeg"
assert_eq "https без пина" \
    "-sS|--connect-timeout|10|--max-time|2100|-F|file=@part_000.flac;type=audio/flac|-F|model=whisperx|-F|language=ru|-F|diarize=true|-o|resp_000.json|-w|%{http_code}|https://h.example:30010/speech/transcriptions" \
    "$(get_field ARGS_NOPIN)"
assert_contains "https с пином" "--max-time|2100|-k|--pinnedpubkey|sha256//AAA=|-F" "$(get_field ARGS_PIN)"
assert_not_contains "http — без -k" "|-k|" "$(get_field ARGS_HTTP)"
assert_contains "diarize=false и num_speakers" "-F|diarize=false|-F|num_speakers=4|-o" "$(get_field ARGS_N)"
assert_contains "--max-time с отправкой части" "--max-time|2620|" "$(get_field ARGS_BYTES)"
assert_eq "извлечение части" "-nostdin|-v|error|-y|-ss|1001|-t|999|-i|/in/a b.mp4|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_001.flac" "$(get_field FF)"
assert_eq "последняя часть — без -t" "-nostdin|-v|error|-y|-ss|2002|-i|/in/a.mp3|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_002.flac" "$(get_field FF_LAST)"

suite "ASR PS1: исходы"
assert_eq "200" "ok|" "$(get_field CL_0_200)"
assert_eq "400" "file|HTTP 400: bad-lang" "$(get_field CL_0_400)"
assert_eq "413" "file|HTTP 413" "$(get_field CL_0_413)"
assert_eq "401" "stop|ключ не принят (HTTP 401)" "$(get_field CL_0_401)"
assert_eq "500" "stop|HTTP 500" "$(get_field CL_0_500)"
assert_contains "504" "stop|сервер не уложился" "$(get_field CL_0_504)"
assert_eq "curl 90" "stop|сертификат сервера не совпал с закреплённым ключом (curl 90)" "$(get_field CL_90_000)"
assert_contains "curl 28" "stop|истёк таймаут" "$(get_field CL_28_000)"
assert_contains "curl 26 — файл" "не смог прочитать извлечённый звук" "$(get_field CL_26_000)"
assert_eq "curl 7" "stop|сетевая ошибка (curl 7: Failed to connect)" "$(get_field CL_7_000)"

suite "ASR PS1: текст — те же ожидаемые .txt, что у .sh"
for _f in basic escapes chunks empty monologue; do
    if cmp -s "$FIX/$_f.txt" "$WORK/ps_$_f.txt"; then pass "$_f.txt: байт в байт"
    else fail "$_f.txt: байт в байт" "$(cat "$FIX/$_f.txt")" "$(cat "$WORK/ps_$_f.txt" 2>/dev/null)"; fi
done
assert_eq "сводка basic" "2|1|" "$(get_field SUM_basic.txt)"
assert_eq "сводка chunks" "2,1|2|ч.2: align=unavailable, ч.2: diarize=failed" "$(get_field SUM_chunks.txt)"
assert_eq "одна часть — JSON без изменений" "$(cat "$FIX/basic.json")" "$(cat "$WORK/ps_one.json" 2>/dev/null)"
assert_eq "две части — валидная обёртка" "2|1001" "$(get_field TWO)"

suite "ASR PS1: проверка конфига и ключ из команды"
_want=(0 1 1 1 1 1 1 1 0 0 1 0)
for _i in 0 1 2 3 4 5 6 7 8 9 10 11; do assert_eq "случай $_i" "${_want[_i]}" "$(get_field "VC_$_i")"; done
assert_eq "api_key_command" "True|cmd-key" "$(get_field KEYCMD)"

suite "ASR PS1: выбор адреса и запрос части (подменённый curl)"
assert_eq "«Остановить» при выборе адреса — конец выбора" "False|1|отменено пользователем" "$(get_field SEL_CANCEL)"
assert_eq "недоступный первый пропущен" "True|https://b.example:30010|1800" "$(get_field SEL)"
assert_eq "два 503 и успех" "ok|3" "$(get_field TP_RETRY)"
assert_eq "503 и после повторов — прогон" "stop|3" "$(get_field TP_FULL)"
assert_eq "200 без segments" "file|сервер ответил 200, но без поля segments" "$(get_field TP_HTML)"

suite "ASR PS1: настоящий запуск curl и отмена"
if [ "$(get_field REAL)" = "skip" ]; then
    skip "запуск curl.exe и отмена" "нужен Windows (поддельный curl — .cmd)"
else
    assert_eq "код и HTTP-код" "0|200" "$(get_field REAL_RC)"
    assert_eq "ключ — заголовком в stdin" 'header = "Authorization: Bearer k-123"' "$(get_field REAL_STDIN)"
    # 104 = 'h'. BOM (239) в начале конфига curl отвергает целиком — живой прогон
    # 2026-10-02 упал на этом при консоли в UTF-8, а проверка выше BOM не видит:
    # ReadAllText срезает его молча.
    assert_eq "stdin curl'а начинается без BOM" "104" "$(get_field REAL_STDIN_FIRST)"
    assert_contains "конфиг со stdin" "--config - -sS" "$(get_field REAL_ARGS)"
    assert_not_contains "ключа нет в аргументах" "k-123" "$(get_field REAL_ARGS)"
    assert_eq "отмена убивает curl быстро" "True|1" "$(get_field CANCEL)"
    assert_eq "после отмены процесса curl нет" "1" "$(get_field CANCEL_DEAD)"
    assert_eq "отмена прерывает извлечение звука" "True|1" "$(get_field EX_CANCEL)"
    assert_eq "сбой извлечения: код и первая непустая строка stderr" "3|moov atom not found|False" "$(get_field EX_FAIL)"
fi

rm -rf "$WORK"
summary
