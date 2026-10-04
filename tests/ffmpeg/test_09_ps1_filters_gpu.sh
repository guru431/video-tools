#!/bin/bash
# ============================================================
# test_09_ps1_filters_gpu.sh — Тест PS1: фильтры и GPU
# Тестирует: vf (поворот, масштаб, скорость), af (atempo каскад,
# loudnorm), GPU encoder check (nvidia/intel/off).
# Цепочки vf/af и выбор GPU-энкодера — настоящие функции воркера (разбор AST),
# без запуска полного скрипта.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути). На Linux/CI пропускаем.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "PS1 фильтры и GPU"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"

# ── Цепочки -vf/-af: НАСТОЯЩИЕ функции воркера ───────────────────────────
# Раньше здесь жили инлайн-копии сборки цепочек, и копия уже разошлась с кодом
# (atempo без InvariantCulture, без проверки скорости). Воркер исполняется сверху
# вниз и тест-гарда не имеет, поэтому Get-VideoFilterChain/Get-AudioFilterChain
# берутся из исходника разбором AST — как Select-ConfigComboValue в test_16.
# Все случаи считаются одним процессом PowerShell: строка «ТЕГ=цепочка».
# Аргументы V: тег, поворот (статус, значение), разрешение ('' — выкл.),
# keep_aspect (статус, значение), скорость (статус, значение), GPU ('' — нет).
# Аргументы A: тег, скорость (статус, значение), нормализация (статус, значение).
# Аргументы G (Resolve-HwEncoder — выбор GPU-энкодера; прежняя инлайн-копия искала
# любое вхождение nvenc/qsv и не знала готовых GPU-имён): тег, hw_accel, кодек,
# вывод `ffmpeg -encoders`. Строка: включён|тип|кодек|аргументы декодера|предупреждение(0/1).
_chain_ps=$(mktemp_suffix "${TMPDIR:-/tmp}/ps1_chains_" .ps1)
cat > "$_chain_ps" <<'PSEOF'
param([string]$Script)
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Script, [ref]$null, [ref]$null)
foreach ($name in 'Get-VideoFilterChain', 'Get-AudioFilterChain', 'Resolve-HwEncoder') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { Write-Output "NOFUNC=$name"; exit 1 }
    . ([scriptblock]::Create($fn.Extent.Text))
}
function V([string]$Tag, [string]$RotS, [string]$RotV, [string]$Res, [string]$KarS, [string]$KarV, [string]$SpS, [string]$SpV, [string]$Hw) {
    $p = @(Get-VideoFilterChain -RotationStatus $RotS -RotationValue $RotV -Resolution $Res `
        -KeepAspectStatus $KarS -KeepAspectValue $KarV -SpeedStatus $SpS -SpeedValue $SpV `
        -UseHwAccel ($Hw -ne '') -HwAccelType $Hw)
    Write-Output ("{0}={1}" -f $Tag, ($p -join ','))
}
function A([string]$Tag, [string]$SpS, [string]$SpV, [string]$NS, [string]$NV) {
    $p = @(Get-AudioFilterChain -SpeedStatus $SpS -SpeedValue $SpV -NormalizeStatus $NS -NormalizeValue $NV)
    Write-Output ("{0}={1}" -f $Tag, ($p -join ','))
}
V rot1      '+' '1' ''         '+' 'yes' '-' '1.0' ''
V rot2      '+' '2' ''         '+' 'yes' '-' '1.0' ''
V rotoff    '-' '2' ''         '+' 'yes' '-' '1.0' ''
V rotnv     '+' '2' ''         '+' 'yes' '-' '1.0' 'nvidia'
V rotnvsc   '+' '2' '1280x720' '+' 'yes' '-' '1.0' 'nvidia'
V karnv     '-' '2' '1280x720' '+' 'yes' '-' '1.0' 'nvidia'
V scnv      '-' '2' '1280x720' '+' 'no'  '-' '1.0' 'nvidia'
V scqsv     '-' '2' '1280x720' '+' 'no'  '+' '2.0' 'intel'
V karsc     '-' '1' '1280x720' '+' 'yes' '-' '1.0' ''
V sc        '-' '1' '1280x720' '+' 'no'  '-' '1.0' ''
V resoff    '-' '1' ''         '+' 'yes' '-' '1.0' ''
V sp2       '-' '1' ''         '+' 'yes' '+' '2.0' ''
V sp1       '-' '1' ''         '+' 'yes' '+' '1.0' ''
V spoff     '-' '1' ''         '+' 'yes' '-' '1.5' ''
A a15       '+' '1.5'  '-' 'loudnorm'
A a20       '+' '2.0'  '-' 'loudnorm'
A a05       '+' '0.5'  '-' 'loudnorm'
A a10       '+' '1.0'  '-' 'loudnorm'
A aoff      '-' '1.5'  '-' 'loudnorm'
A a30       '+' '3.0'  '-' 'loudnorm'
A a40       '+' '4.0'  '-' 'loudnorm'
A a025      '+' '0.25' '-' 'loudnorm'
A loud      '-' '1.0'  '+' 'loudnorm'
A dyn       '-' '1.0'  '+' 'dynaudnorm'
A normoff   '-' '1.0'  '-' 'loudnorm'
A spnorm    '+' '1.5'  '+' 'loudnorm'
function G([string]$Tag, [string]$Hw, [string]$Codec, [string]$Enc) {
    $r = Resolve-HwEncoder -HwAccelValue $Hw -VideoCodec $Codec -EncodersList $Enc
    Write-Output ("{0}={1}|{2}|{3}|{4}|{5}" -f $Tag, $r.UseHwAccel, $r.Type, $r.Codec, ($r.DecodeArgs -join ' '), [int][bool]$r.Warning)
}
$nv  = "Encoders:`n V....D h264_nvenc            NVIDIA NVENC H.264 encoder`n V....D hevc_nvenc            NVIDIA NVENC hevc encoder"
$qsv = "Encoders:`n V....D h264_qsv              H.264 QSV encoder`n V....D hevc_qsv              HEVC QSV encoder"
$hyp = "Encoders:`n V....D av1_nvenc_hypothetical  not a real encoder"
G nv264     'nvidia' 'libx264'    $nv
G nvnone    'nvidia' 'libx264'    'no matching encoders'
G nvav1     'nvidia' 'libsvtav1'  $nv
G nvanchor  'nvidia' 'libsvtav1'  $hyp
G nvready   'nvidia' 'hevc_nvenc' $nv
G nvvp9     'nvidia' 'libvpx-vp9' $nv
G nvcase    'NVIDIA' 'libx264'    $nv
G qsv265    'intel'  'libx265'    $qsv
G qsvnone   'intel'  'libx264'    'no matching encoders'
G qsvready  'intel'  'h264_qsv'   $qsv
G typo      'nvida'  'libx264'    $nv
G off       'off'    'libx264'    $nv
# Text of the typo warning: the key lives in [gpu], and off is a valid value.
$w = (Resolve-HwEncoder -HwAccelValue 'nvida' -VideoCodec 'libx264' -EncodersList $nv).Warning
# [audio] normalize outside loudnorm/dynaudnorm: the worker's own if-statement (AST).
$nIf = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
    $n.Clauses[0].Item1.Extent.Text.Contains('$audio_normalize_value -notin') }, $true)
function N([string]$Tag, [string]$S, [string]$V) {
    if (-not $nIf) { Write-Output "$Tag=NOIF"; return }
    $audio_normalize_status = $S; $audio_normalize_value = $V
    $o = (& { . ([scriptblock]::Create($nIf.Extent.Text)) } 6>&1 | ForEach-Object { "$_" }) -join '//'
    Write-Output ("{0}={1}|{2}" -f $Tag, [int][bool]$o, ($o.Contains("[audio] normalize = '$V' (") -and $o.Contains('dynaudnorm).')))
}
N nwarn  '+' 'loudness'
N nok    '+' 'loudnorm'
N nokdyn '+' 'dynaudnorm'
N noff   '-' 'loudness'
Write-Output ("typotext={0}|{1}" -f $w.Contains("[gpu] hw_accel = 'nvida'"), ($w.Contains('nvidia, intel') -and $w.Contains(' off)')))
# Canonical case of enum values (it is what goes into the remote service JSON): the worker's own ifs (AST).
$cIfs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.IfStatementAst] -and
    ($n.Clauses[0].Item1.Extent.Text -match '^\$(hw_accel|audio_normalize)_value -in ') }, $true))
$hw_accel_value = 'NVIDIA'; $audio_normalize_value = 'LoudNorm'
foreach ($i in $cIfs) { . ([scriptblock]::Create($i.Extent.Text)) }
Write-Output ("canon={0}|{1}|{2}" -f $cIfs.Count, $hw_accel_value, $audio_normalize_value)
$hw_accel_value = 'Nvida'; $audio_normalize_value = 'Loudness'
foreach ($i in $cIfs) { . ([scriptblock]::Create($i.Extent.Text)) }
Write-Output ("canonkeep={0}|{1}" -f $hw_accel_value, $audio_normalize_value)
PSEOF
_chains_out=$("$PS_CMD" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$_chain_ps")" \
    -Script "$(cygpath -w "$SCRIPT_PS1")" 2>&1)
rm -f "$_chain_ps"

# chain ТЕГ → $result: цепочка из строки «ТЕГ=…» (без процесса и без $( )).
chain() {
    local _l
    result="НЕТ_СТРОКИ_$1"
    while IFS= read -r _l; do
        _l="${_l%$'\r'}"
        if [ "${_l%%=*}" = "$1" ]; then result="${_l#*=}"; return; fi
    done <<< "$_chains_out"
}

assert_not_contains "функции цепочек найдены в настоящем воркере" "NOFUNC" "$_chains_out"
src_ps1="$(cat "$SCRIPT_PS1")"
# Функции обязаны быть именно тем, чем воркер строит -vf/-af, а не мёртвым кодом.
assert_contains "воркер строит -vf через Get-VideoFilterChain"  '$vf_parts = @(Get-VideoFilterChain' "$src_ps1"
assert_contains "воркер строит -af через Get-AudioFilterChain"  '$af_parts = @(Get-AudioFilterChain' "$src_ps1"

assert_contains "воркер выбирает GPU-энкодер через Resolve-HwEncoder" \
    '$hw = Resolve-HwEncoder -HwAccelValue $hw_accel_value -VideoCodec $set_video_codec -EncodersList $encoders_list' "$src_ps1"
# Выключенный hw_accel (`-nvidia`) до функции не доходит: проверка статуса — у вызова.
assert_contains "выбор GPU-энкодера только при включённом hw_accel" \
    'if ($hw_accel_status -eq "+" -and $ffmpeg_available) {' "$src_ps1"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (поворот)"
# ══════════════════════════════════════════════════════════════
KAR_PAD="scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2,pad=1280:720:(ow-iw)/2:(oh-ih)/2"

chain rot1;   assert_eq "rotation +1 → transpose=1"     "transpose=1"  "$result"
chain rot2;   assert_eq "rotation +2 → transpose=2"     "transpose=2"  "$result"
chain rotoff; assert_eq "rotation off → no transpose"   ""             "$result"

# rotation + nvidia: transpose_cuda не существует → обычный transpose + CPU-цепочка
chain rotnv
assert_eq "rotation +2 + nvidia → hwdownload + transpose=2"  "hwdownload,format=nv12,transpose=2"  "$result"
assert_not_contains "rotation + nvidia → нет transpose_cuda"  "transpose_cuda"  "$result"

chain rotnvsc
assert_eq "rotation+nvidia+scale → CPU scale+pad (не scale_cuda)" \
    "hwdownload,format=nv12,transpose=2,$KAR_PAD" "$result"

# keep_aspect + nvidia без поворота: тоже CPU scale+pad (force_cpu), не scale_cuda
chain karnv
assert_eq "keep_ar+nvidia → hwdownload + CPU scale+pad с force_divisible_by" \
    "hwdownload,format=nv12,$KAR_PAD" "$result"

# Без keep_aspect и поворота GPU-масштаб остаётся на карте, hwdownload не нужен
chain scnv;  assert_eq "nvidia без keep_ar → scale_cuda"              "scale_cuda=1280:720"              "$result"
chain scqsv; assert_eq "intel без keep_ar + скорость → scale_qsv,setpts" "scale_qsv=1280:720,setpts=PTS/2.0" "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (масштаб с сохранением пропорций)"
# ══════════════════════════════════════════════════════════════

chain karsc;  assert_eq "scale 1280x720 keep_ar → scale+pad"   "$KAR_PAD"        "$result"
chain sc;     assert_eq "scale без keep_ar → scale=1280:720"   "scale=1280:720"  "$result"
chain resoff; assert_eq "resolution off → нет scale"           ""                "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: видео-фильтры (скорость видео)"
# ══════════════════════════════════════════════════════════════

chain sp2;   assert_eq "playback_speed 2.0 → setpts"            "setpts=PTS/2.0"  "$result"
chain sp1;   assert_eq "playback_speed 1.0 → нет setpts"        ""                "$result"
chain spoff; assert_eq "playback_speed выключена → нет setpts"  ""                "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио-фильтры (atempo)"
# ══════════════════════════════════════════════════════════════

chain a15;  assert_eq "atempo 1.5 → одиночный atempo"          "atempo=1.5"  "$result"
# PS1 печатает double 2.0 как «2» — эквивалентно для ffmpeg
chain a20;  assert_eq "atempo 2.0 → одиночный atempo"          "atempo=2"    "$result"
chain a05;  assert_eq "atempo 0.5 → одиночный atempo"          "atempo=0.5"  "$result"
chain a10;  assert_eq "atempo 1.0 → нет фильтра"               ""            "$result"
chain aoff; assert_eq "playback_speed выключена → нет atempo"  ""            "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: atempo каскад (скорость > 2.0 и < 0.5)"
# ══════════════════════════════════════════════════════════════

chain a30;  assert_eq "speed 3.0 → atempo=2.0 каскад + остаток 1.5"  "atempo=2.0,atempo=1.5"  "$result"
# PS1 выводит atempo=2 (не 2.0) когда double 4.0/2.0=2 — эквивалентно для ffmpeg
chain a40;  assert_eq "speed 4.0 → два atempo= каскад"               "atempo=2.0,atempo=2"    "$result"
chain a025; assert_eq "speed 0.25 → atempo=0.5 каскад"               "atempo=0.5,atempo=0.5"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: аудио-фильтры (нормализация)"
# ══════════════════════════════════════════════════════════════

chain loud;    assert_eq "loudnorm → loudnorm=I=-16"           "loudnorm=I=-16:TP=-1.5:LRA=11"  "$result"
chain dyn;     assert_eq "dynaudnorm → dynaudnorm"             "dynaudnorm"                     "$result"
chain normoff; assert_eq "normalize выключена → нет фильтра"   ""                               "$result"
chain spnorm;  assert_eq "скорость + loudnorm → atempo первым" "atempo=1.5,loudnorm=I=-16:TP=-1.5:LRA=11" "$result"
# Значение вне loudnorm/dynaudnorm функция не применяет — воркер предупреждает
# (настоящий оператор if воркера из AST; текст как в SH/CMD).
chain nwarn;   assert_eq "normalize +loudness → предупреждение с ключом и списком" "1|True"  "$result"
chain nok;     assert_eq "normalize +loudnorm → без предупреждения"              "0|False" "$result"
chain nokdyn;  assert_eq "normalize +dynaudnorm → без предупреждения"            "0|False" "$result"
chain noff;    assert_eq "normalize выключена → без предупреждения"              "0|False" "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: GPU encoder check (NVIDIA)"
# ══════════════════════════════════════════════════════════════

CUDA="-hwaccel cuda -hwaccel_output_format cuda"
QSVA="-hwaccel qsv -hwaccel_output_format qsv"
chain nv264;    assert_eq "nvidia + h264_nvenc в сборке → libx264 → h264_nvenc"   "True|nvidia|h264_nvenc|$CUDA|0" "$result"
chain nvnone;   assert_eq "nvidia без nvenc → CPU, кодек прежний, WARN"           "False||libx264||1"              "$result"
# F33: сборка с h264_nvenc, но без av1_nvenc — нельзя подставлять несуществующий av1_nvenc.
chain nvav1;    assert_eq "nvidia: av1_nvenc нет в сборке → CPU + WARN"           "False||libsvtav1||1"            "$result"
# Якорь по столбцу: av1_nvenc_hypothetical не означает наличия av1_nvenc.
chain nvanchor; assert_eq "nvidia: имя ищется целиком, а не подстрокой"            "False||libsvtav1||1"            "$result"
chain nvready;  assert_eq "nvidia: готовое GPU-имя hevc_nvenc принимается"         "True|nvidia|hevc_nvenc|$CUDA|0" "$result"
# Кодек вне маппинга: hardware-декод не включается (иначе софт получал cuda-кадры).
chain nvvp9;    assert_eq "nvidia: libvpx-vp9 без NVENC-варианта → CPU + WARN"     "False||libvpx-vp9||1"           "$result"
chain nvcase;   assert_eq "nvidia: регистр значения не важен"                     "True|nvidia|h264_nvenc|$CUDA|0" "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: GPU encoder check (Intel QSV)"
# ══════════════════════════════════════════════════════════════

chain qsv265;   assert_eq "intel + hevc_qsv в сборке → libx265 → hevc_qsv"        "True|intel|hevc_qsv|$QSVA|0"    "$result"
chain qsvnone;  assert_eq "intel без qsv → CPU, кодек прежний, WARN"              "False||libx264||1"              "$result"
chain qsvready; assert_eq "intel: готовое GPU-имя h264_qsv принимается"           "True|intel|h264_qsv|$QSVA|0"    "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1: значение hw_accel"
# ══════════════════════════════════════════════════════════════

chain typo;     assert_eq "hw_accel = nvida (опечатка) → CPU + WARN"              "False||libx264||1"              "$result"
chain typotext; assert_eq "WARN опечатки: секция [gpu], off в списке допустимых"   "True|True"                      "$result"
# off документирован в config.ini.example и раньше печатал «неизвестное значение».
chain off;      assert_eq "hw_accel = off → CPU без предупреждения"               "False||libx264||0"              "$result"
assert_contains "без ffmpeg off не печатает «ускорение не проверяется»" \
    'if ($hw_accel_status -eq "+" -and $hw_accel_value -ne "off" -and -not $ffmpeg_available) {' "$src_ps1"
# Регистр: локально switch/-eq и так без учёта регистра, но в JSON удалённой службы
# значение уезжает как есть — воркер приводит его к каноническому виду (паритет с .sh).
chain canon;     assert_eq "NVIDIA/LoudNorm → nvidia/loudnorm (оба if найдены)"   "2|nvidia|loudnorm"  "$result"
chain canonkeep; assert_eq "неизвестные значения не трогаются (их ловит WARN)"   "Nvida|Loudness"     "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 script.ps1: фиксы Task 3 (анализ исходника)"
# ══════════════════════════════════════════════════════════════

# (а) $vf_parts инициализируется ДО ветки audio_only — иначе осиротевший -vf (PS1 5.1: @()+$null = Count 1)
init_ln=$(grep -nF '$vf_parts = @()' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
ao_ln=$(grep -nF 'if ($audio_only -eq "yes")' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
order="bad"; [ -n "$init_ln" ] && [ -n "$ao_ln" ] && [ "$init_ln" -lt "$ao_ln" ] && order="ok"
assert_eq "vf_parts инициализирован ДО audio_only (нет осиротевшего -vf)"  "ok"  "$order"

# (б) -ss добавляется только при $b -gt 0 (иначе -ss 0 с -c copy дропает видео)
assert_contains "-ss guard: if (\$b -gt 0)"  'if ($b -gt 0 -and -not $sub_burned) { $ffmpegArgs += @("-ss"'  "$src_ps1"
assert_not_contains "старое условие -ss убрано"  'if ($b -ne 0 -or $set_start_coding)'  "$src_ps1"

# (в) muxer map mkv->matroska / ts->mpegts; -f использует $muxer_out
assert_contains "muxer map: matroska"  'matroska'  "$src_ps1"
assert_contains "muxer map: mpegts"  'mpegts'  "$src_ps1"
assert_contains "-f использует \$muxer_out"  '@("-f", $muxer_out)'  "$src_ps1"

# (г) transpose_cuda не существует — удалён из всего скрипта
assert_not_contains "нет несуществующего transpose_cuda"  'transpose_cuda'  "$src_ps1"

# ══════════════════════════════════════════════════════════════
suite "PS1 script.ps1: фиксы Task 6 (copy_codecs ext, Duration N/A)"
# ══════════════════════════════════════════════════════════════
# copy_codecs: current_format_out из источника ДО existence-check (Test-Path)
cc_ln=$(grep -nF '$current_format_out = $file.Extension.TrimStart' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
# Локатор не привязан ни к параметрам Test-Path, ни к точному составу имени выхода:
# раньше искалась строка `Test-Path "$out_base..."`, и добавление -LiteralPath (F1)
# обнулило поиск; затем в имя вошёл `$part_suffix_known` — и снова обнулило. Оба раза
# инвариант порядка оставался верным, а тест «падал» на своей же формулировке.
chk_ln=$(grep -nE 'Test-Path .*\$out_base.*\$current_format_out' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
order="bad"; [ -n "$cc_ln" ] && [ -n "$chk_ln" ] && [ "$cc_ln" -lt "$chk_ln" ] && order="ok"
assert_eq "copy_codecs ext вычислен ДО existence-check"  "ok"  "$order"
# Duration N/A → $num = @(0) fallback
assert_contains "Duration N/A → num fallback"  'if ($num.Count -eq 0) {'  "$src_ps1"

# ══════════════════════════════════════════════════════════════
suite "F25 PS1: потолок битрейта из видеопотока, а не контейнера"
# ══════════════════════════════════════════════════════════════
# Сначала per-stream `Stream #...: Video: ..., N kb/s`; контейнерный bitrate — только
# fallback и обязан сопровождаться WARN (иначе завышенный потолок поднимает видеобитрейт).
assert_contains "PS1: приоритет битрейта видеопотока"  'Stream #.*Video:.*?(\d+)\s*kb/s'  "$src_ps1"
assert_contains "PS1: fallback на контейнер сопровождается WARN"  "битрейт видеопотока не сообщён"  "$src_ps1"
# Порядок: video-stream match идёт ДО container match
vs_ln=$(grep -nF 'Stream #.*Video:.*?(\d+)\s*kb/s' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
ct_ln=$(grep -nF 'bitrate:\s+(\d+)\s*kb/s' "$SCRIPT_PS1" | head -1 | cut -d: -f1)
order="bad"; [ -n "$vs_ln" ] && [ -n "$ct_ln" ] && [ "$vs_ln" -lt "$ct_ln" ] && order="ok"
assert_eq "PS1: видеопоток проверяется до контейнера"  "ok"  "$order"

# AMF: constant-quality через cqp + qp_i/qp_p/qp_b, а не несуществующий одиночный -qp.
assert_contains     "PS1 AMF: режим cqp + qp_i/qp_p/qp_b"  '"-rc", "cqp", "-qp_i"' "$src_ps1"
assert_not_contains "PS1 AMF: нет одиночного @(\"-qp\", ...)" '@("-qp", $video_quality_value)' "$src_ps1"

# F-modes/#7: конфликт спецрежимов → WARN; extract уважает overwrite_existing.
assert_contains "PS1: WARN о взаимоисключающих режимах" "взаимоисключающих режимов" "$src_ps1"
assert_contains "PS1: extract уважает overwrite_existing" 'if ($overwrite_existing -eq "yes") {' "$src_ps1"

summary
