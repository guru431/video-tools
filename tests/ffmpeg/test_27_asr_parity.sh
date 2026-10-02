#!/bin/bash
# Тест дот-сорсит настоящий модуль: переменные asr_*, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
# ============================================================
# test_27_asr_parity.sh — .sh и .ps1 считают одинаково: план частей на сетке
# длительностей и пределов, аргументы curl, исходы, адреса и текст расшифровки
# (включая синтетический ответ на 2000 сегментов в двух частях). Обе стороны
# печатают строки KEY=VALUE в файлы, сравнение — одним diff.
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
LIMS="3600,1800,cpu 7200,1800,cuda 3600,600,cpu 1000,1800,cpu"
CLS="0:200 0:400 0:413 0:422 0:401 0:403 0:500 0:502 0:503 0:504 90:000 28:000 26:000 7:000 6:000"

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
        asr_curl_args "$_b" "part_000.flac" "resp_000.json"
        _IFS="$IFS"; IFS='|'; echo "ARGS_${_combo}=${ASR_CURL_ARGS[*]}"; IFS="$_IFS"
    done
    ASR_CURL_ERR="boom"
    for _c in $CLS; do asr_classify "${_c%%:*}" "${_c#*:}" ""; echo "CL_${_c}=$ASR_OUTCOME|$ASR_REASON"; done
    for _e in "  https://a:1/ http://b:2// " "https://only"; do
        asr_split_endpoints "$_e"; _IFS="$IFS"; IFS='|'; echo "EP_${_e}=${ASR_ENDPOINTS[*]}"; IFS="$_IFS"
    done
} > "$WORK/sh.txt"
asr_render "big.mp4" "2026-10-02 12:00" 1500 "$WORK/sh_big.txt" "$WORK/big.json" 0 "$WORK/big.json" 1500

# ── .ps1 ── (harness ASCII-only)
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_par_" .ps1)"
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Work, [string]$Durs, [string]$Lims, [string]$Cls)
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
    $lines.Add("ARGS_${combo}=" + ((Get-AsrCurlArgs $b 'part_000.flac' 'resp_000.json') -join '|'))
}
foreach ($c in $Cls.Split(' ')) {
    $rc, $code = $c.Split(':')
    $o = Get-AsrOutcome ([int]$rc) $code '' 'boom'
    $lines.Add("CL_${c}=" + $o.Outcome + '|' + $o.Reason)
}
foreach ($e in '  https://a:1/ http://b:2// ', 'https://only') { $lines.Add("EP_${e}=" + (@(Format-AsrEndpoints $e) -join '|')) }
[System.IO.File]::WriteAllText((Join-Path $Work 'ps.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$big = Join-Path $Work 'big.json'
$parts = @([pscustomobject]@{ File = $big; Offset = 0 }, [pscustomobject]@{ File = $big; Offset = 1500 })
$null = Write-AsrTranscript 'big.mp4' '2026-10-02 12:00' 1500 (Join-Path $Work 'ps_big.txt') $parts
PSEOF
"$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
    -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Work "$(_w "$WORK")" \
    -Durs "$DURS" -Lims "$LIMS" -Cls "$CLS" >/dev/null 2>&1
rm -f "$HARNESS"

suite "ASR: паритет .sh ↔ .ps1"
assert_not_empty "PS1 отработал" "$(cat "$WORK/ps.txt" 2>/dev/null)"
assert_empty "план, аргументы curl, исходы, адреса совпадают" "$(diff "$WORK/sh.txt" "$WORK/ps.txt" 2>&1)"
if cmp -s "$WORK/sh_big.txt" "$WORK/ps_big.txt"; then pass "2000 сегментов × 2 части: текст байт в байт"
else fail "2000 сегментов × 2 части: текст байт в байт" "совпадение" "$(diff "$WORK/sh_big.txt" "$WORK/ps_big.txt" 2>&1 | head -5)"; fi

rm -rf "$WORK"
summary
