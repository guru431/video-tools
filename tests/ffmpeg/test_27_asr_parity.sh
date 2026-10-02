#!/bin/bash
# Тест дот-сорсит настоящий модуль: переменные asr_*, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
# ============================================================
# test_27_asr_parity.sh — .sh и .ps1 считают одинаково: план частей на сетке
# длительностей и пределов, аргументы curl, исходы, адреса и текст расшифровки
# (включая синтетический ответ на 2000 сегментов в двух частях); странные данные
# сервера — разбор /speech/limits, detail ошибки, NUL и одиночные суррогаты в
# тексте. Обе стороны печатают строки KEY=VALUE в файлы, сравнение — одним diff.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/asr_client.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "ASR: паритет .sh ↔ .ps1"
    skip "паритет" "PowerShell не найден"
    summary
    exit 0
fi

_w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_par_XXXXXX")"
DURS="1 59 2999 3000 3001 4500 5999 6000 6001 9000 10801 36001"
LIMS="3600,1800,cpu 7200,1800,cuda 3600,600,cpu 1000,1800,cpu 3600,1800,CPU"
CLS="0:200 0:400 0:413 0:422 0:401 0:403 0:500 0:502 0:503 0:504 90:000 28:000 26:000 7:000 6:000"
BYTES="0 1 65000000"

# Странные ответы сервера — общие входы: /speech/limits и detail ошибки.
_i=0
for _b in '{"max_seconds":3600,"max_bytes":524288000,"job_timeout_sec":1800,"device":"cpu","languages":["en","ru"]}' \
          '{"max_seconds":"3600","job_timeout_sec":1800.7,"device":"CPU","languages":null,"max_bytes":"x"}' \
          '{"max_seconds":"0036","job_timeout_sec":1800,"languages":["ru",null,"en"]}' \
          '{"max_seconds":7200,"job_timeout_sec":1800,"device":"cuda","languages":"ru"}' \
          '{"max_seconds":"abc","job_timeout_sec":1800}' '{"max_seconds":null,"job_timeout_sec":1800}' \
          '{"max_seconds":-5,"job_timeout_sec":1800}' '{"max_seconds":99999999999999999999,"job_timeout_sec":1800}' \
          '{"max_seconds":1,"job_timeout_sec":1800}' '{"max_seconds":3600,"job_timeout_sec":1,"device":"cpu"}' \
          '{"max_seconds":true,"job_timeout_sec":1800}' '<html>502</html>'; do
    printf '%s' "$_b" > "$WORK/lim_$_i.json"; _i=$((_i + 1))
done
N_LIM=$_i
_i=0
for _b in '{"detail":"q \"x\" s \\ да 😀 \ud800! \udc00 \u0000end \/ tab\there"}' \
          '{"detail":"plain"}' '{"detail":[{"msg":"field required"}]}' '{"detail":"\\u0000 literal"}'; do
    printf '%s' "$_b" > "$WORK/det_$_i.json"; _i=$((_i + 1))
done
N_DET=$_i
# \u0000 и одиночные суррогаты в тексте, метке и предупреждении; экранированный слэш перед u0000.
printf '%s' '{"asr_ver":"x\u0000y","segments":[{"start":0,"text":"\u0000","speaker":"SPEAKER_00"},{"start":1,"text":" \u0000 hi","speaker":"\u0000"},{"start":2,"text":"a\ud800b \udc00 😀","speaker":"SPEAKER_01"},{"start":3,"text":"\\u0000 lit","speaker":"SPEAKER_01"}],"warnings":["\u0000w\ud800"],"stages":{"transcribe":{"status":"ok"}},"audio_seconds":4,"processing_seconds":1}' > "$WORK/odd.json"

# Синтетический большой ответ — общий вход обеих сторон.
{
    printf '{"asr_ver":"x","segments":['
    for (( _i = 0; _i < 2000; _i++ )); do
        [ "$_i" -gt 0 ] && printf ','
        printf '{"start":%d.25,"end":%d.9,"text":" r%d \\u0434 \\"q\\"","speaker":"SPEAKER_0%d","confidence":0.%d,"words":[]}' \
            "$_i" "$_i" "$_i" $(( _i % 3 )) $(( _i % 10 ))
    done
    printf '],"stages":{"transcribe":{"status":"ok"},"diarize":{"status":"failed"}},"warnings":["w"],"audio_seconds":2000.5,"processing_seconds":999.9}'
} > "$WORK/big.json"

# ── .sh ──
{
    for _l in $LIMS; do
        IFS=, read -r ASR_LIM_MAX_SECONDS ASR_LIM_JOB_TIMEOUT ASR_LIM_DEVICE <<< "$_l"
        for _d in $DURS; do asr_plan_parts "$_d"; echo "PLAN_${_l}_${_d}=$ASR_PLAN|$ASR_PLAN_LEN|$ASR_PLAN_WHOLE"; done
    done
    ASR_LIM_JOB_TIMEOUT=1800
    for _combo in "https://h:1,,yes," "https://h:1,sha256//P=,yes," "http://h:2,sha256//P=,no,7"; do
        IFS=, read -r _b asr_pinned_pubkey asr_diarize asr_num_speakers <<< "$_combo"
        asr_language="ru"
        for _by in $BYTES; do
            asr_curl_args "$_b" "part_000.flac" "resp_000.json" "$_by"
            _IFS="$IFS"; IFS='|'; echo "ARGS_${_combo}_${_by}=${ASR_CURL_ARGS[*]}"; IFS="$_IFS"
        done
    done
    ASR_CURL_ERR="boom"
    for _c in $CLS; do asr_classify "${_c%%:*}" "${_c#*:}" ""; echo "CL_${_c}=$ASR_OUTCOME|$ASR_REASON"; done
    for _e in "  https://a:1/ http://b:2// " "https://only"; do
        asr_split_endpoints "$_e"; _IFS="$IFS"; IFS='|'; echo "EP_${_e}=${ASR_ENDPOINTS[*]}"; IFS="$_IFS"
    done
    for (( _i = 0; _i < N_LIM; _i++ )); do
        IFS= read -r -d '' _body < "$WORK/lim_$_i.json"
        if asr_parse_limits "$_body"; then
            echo "LIMP_$_i=0|$ASR_LIM_MAX_SECONDS|${ASR_LIM_MAX_BYTES:-0}|$ASR_LIM_JOB_TIMEOUT|$ASR_LIM_LANGUAGES|$ASR_PLAN_WHOLE"
        else echo "LIMP_$_i=1"; fi
    done
    for (( _i = 0; _i < N_DET; _i++ )); do asr_detail "$WORK/det_$_i.json"; echo "DET_$_i=$ASR_DETAIL"; done
} > "$WORK/sh.txt"
asr_render "big.mp4" "2026-10-02 12:00" 1500 "$WORK/sh_big.txt" "$WORK/big.json" 0 "$WORK/big.json" 1500
asr_render "odd.mp4" "2026-10-02 12:00" 4 "$WORK/sh_odd.txt" "$WORK/odd.json" 0

# ── .ps1 ── (harness ASCII-only)
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_par_" .ps1)"
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Work, [string]$Durs, [string]$Lims, [string]$Cls, [string]$Bytes, [int]$NLim, [int]$NDet)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Log-Msg { param($L, $M) }
. $Module
$lines = New-Object System.Collections.Generic.List[string]
foreach ($l in $Lims.Split(' ')) {
    $ms, $jt, $dev = $l.Split(',')
    foreach ($d in $Durs.Split(' ')) {
        $p = Get-AsrPlan ([int64]$d) ([int64]$ms) ([int64]$jt) $dev
        $lines.Add("PLAN_${l}_${d}=" + ($p.Parts -join ' ') + '|' + $p.PartLen + '|' + $p.Whole)
    }
}
$script:AsrLimits = [pscustomobject]@{ JobTimeout = [int64]1800 }
foreach ($combo in 'https://h:1,,yes,', 'https://h:1,sha256//P=,yes,', 'http://h:2,sha256//P=,no,7') {
    $b, $asr_pinned_pubkey, $asr_diarize, $asr_num_speakers = $combo.Split(',')
    $asr_language = 'ru'
    foreach ($by in $Bytes.Split(' ')) {
        $lines.Add("ARGS_${combo}_${by}=" + ((Get-AsrCurlArgs $b 'part_000.flac' 'resp_000.json' ([int64]$by)) -join '|'))
    }
}
foreach ($c in $Cls.Split(' ')) {
    $rc, $code = $c.Split(':')
    $o = Get-AsrOutcome ([int]$rc) $code '' 'boom'
    $lines.Add("CL_${c}=" + $o.Outcome + '|' + $o.Reason)
}
foreach ($e in '  https://a:1/ http://b:2// ', 'https://only') { $lines.Add("EP_${e}=" + (@(Format-AsrEndpoints $e) -join '|')) }
for ($i = 0; $i -lt $NLim; $i++) {
    $l = Get-AsrLimits ([System.IO.File]::ReadAllText((Join-Path $Work "lim_$i.json")))
    if ($l) { $lines.Add("LIMP_$i=0|$($l.MaxSeconds)|$($l.MaxBytes)|$($l.JobTimeout)|$($l.Languages)|" + (Get-AsrPlan 0 $l.MaxSeconds $l.JobTimeout $l.Device).Whole) }
    else { $lines.Add("LIMP_$i=1") }
}
for ($i = 0; $i -lt $NDet; $i++) { $lines.Add("DET_$i=" + (Get-AsrDetail (Join-Path $Work "det_$i.json"))) }
[System.IO.File]::WriteAllText((Join-Path $Work 'ps.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$big = Join-Path $Work 'big.json'
$parts = @([pscustomobject]@{ File = $big; Offset = 0 }, [pscustomobject]@{ File = $big; Offset = 1500 })
$null = Write-AsrTranscript 'big.mp4' '2026-10-02 12:00' 1500 (Join-Path $Work 'ps_big.txt') $parts
$null = Write-AsrTranscript 'odd.mp4' '2026-10-02 12:00' 4 (Join-Path $Work 'ps_odd.txt') @([pscustomobject]@{ File = (Join-Path $Work 'odd.json'); Offset = 0 })
PSEOF
"$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
    -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Work "$(_w "$WORK")" \
    -Durs "$DURS" -Lims "$LIMS" -Cls "$CLS" -Bytes "$BYTES" -NLim "$N_LIM" -NDet "$N_DET" >/dev/null 2>&1
rm -f "$HARNESS"

suite "ASR: паритет .sh ↔ .ps1"
assert_not_empty "PS1 отработал" "$(cat "$WORK/ps.txt" 2>/dev/null)"
assert_empty "план, аргументы curl, исходы, адреса, пределы, detail совпадают" "$(diff "$WORK/sh.txt" "$WORK/ps.txt" 2>&1)"
if cmp -s "$WORK/sh_big.txt" "$WORK/ps_big.txt"; then pass "2000 сегментов × 2 части: текст байт в байт"
else fail "2000 сегментов × 2 части: текст байт в байт" "совпадение" "$(diff "$WORK/sh_big.txt" "$WORK/ps_big.txt" 2>&1 | head -5)"; fi
if cmp -s "$WORK/sh_odd.txt" "$WORK/ps_odd.txt"; then pass "NUL и одиночные суррогаты: текст байт в байт"
else fail "NUL и одиночные суррогаты: текст байт в байт" "совпадение" "$(diff "$WORK/sh_odd.txt" "$WORK/ps_odd.txt" 2>&1 | head -8)"; fi

rm -rf "$WORK"
summary
