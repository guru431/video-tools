#!/bin/bash
# ============================================================
# test_16_gui_state.sh — F17: воркер сообщает GUI честный исход батча.
# Раньше финальная запись всегда была «Готово» независимо от countFail, а `exit 1`
# не создаёт ErrorRecord — GUI показывал «Готово» после провального батча.
# Контракт: progress JSON содержит state=running|success|failed|cancelled + exitCode.
# Запускает НАСТОЯЩИЙ FFmpeg_Converter_script.ps1 (dot-source, как делает run_v19.ps1)
# с mock ffmpeg; результат читается из JSON-файла прогресса.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "F17: GUI state воркера"
    skip "Все PS1 GUI-state тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

SCRIPT_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"
WORK=$(mktemp -d /tmp/test_gui_state_XXXXXX)
IN="$WORK/in"; DST="$WORK/out"
mkdir -p "$IN" "$DST"
: > "$IN/a.mp4"

# Запускает воркер с заданным mock-поведением и печатает содержимое progress JSON.
# $1 — MOCK_FFMPEG_FAIL (0/1), $2 — создать ли cancel-файл (yes/no),
# $3 — дополнительные присваивания PowerShell перед запуском (перекрывают базовые).
run_worker() {
    local mock_fail="$1" want_cancel="${2:-no}" extra="${3:-}"
    local prog="$WORK/progress.json" cancel="$WORK/cancel.flag"
    rm -f "$prog" "$cancel"
    [ "$want_cancel" = "yes" ] && : > "$cancel"

    local w_script w_in w_dst w_prog w_cancel w_mock
    w_script=$(cygpath -w "$SCRIPT_PS1"); w_in=$(cygpath -w "$IN"); w_dst=$(cygpath -w "$DST")
    w_prog=$(cygpath -w "$prog"); w_cancel=$(cygpath -w "$cancel")
    w_mock=$(cygpath -w "$TESTS_DIR/mocks/ffmpeg.cmd")

    MOCK_FFMPEG_FAIL="$mock_fail" MOCK_FFMPEG_ENCODERS="" \
    FFMPEG_GUI_PROGRESS_FILE="$w_prog" FFMPEG_GUI_CANCEL_FILE="$w_cancel" \
    "$PS_CMD" -NoProfile -NonInteractive -Command "
\$ErrorActionPreference='Continue'
# cygpath -w отдаёт короткий 8.3-путь (SUPERU~1), а .NET DirectoryName — длинный:
# без нормализации strip-префикса в Encode-File не срабатывает и пути склеиваются.
\$folder_sources=(Get-Item '$w_in').FullName + [IO.Path]::DirectorySeparatorChar
\$folder_destination=(Get-Item '$w_dst').FullName + [IO.Path]::DirectorySeparatorChar
\$ffmpeg='$w_mock'; \$ffprobe='$w_mock'
\$audio_codec=':+:aac'; \$audio_number_channels=':-:2'; \$audio_bitrate=':-:128'
\$audio_sampling_rate=':-:44100'; \$audio_normalize=':-:loudnorm'
\$video_codec=':+:libx264'; \$video_resolution=':-:1280x720'; \$video_bitrate=':-:2000'
\$video_number_frames=':-:25'; \$video_rotation=':-:2'; \$video_subtitles=':-:burn'
\$video_quality=':+:23'; \$keep_aspect_ratio=':+:yes'; \$output_container=':+:mp4'
\$multithreads=':-:4'; \$parallel_files=':-:2'
\$hw_accel=':-:nvidia'; \$gpu_preset=':-:p5'; \$gpu_tune=':-:hq'; \$gpu_rc=':-:vbr'
\$playback_speed=':-:1.0'; \$start_coding=':-:01-00-00'; \$length_coding=':-:00-05-00'
\$split_by_silence='no'; \$silence_duration='2.0'; \$silence_threshold='-30dB'
\$save_old_extension='no'; \$format_files_in='mp4,mkv,avi,webm'
\$subtitles_style=''; \$dry_run='no'; \$enable_log='no'; \$log_file=''
\$audio_only='no'; \$merge_files='no'; \$create_frame='no'
\$copy_codecs='no'; \$extract_audio_copy='no'; \$overwrite_existing='yes'
$extra
. '$w_script'
" > /dev/null 2>&1
    # ConvertTo-Json выравнивает значения переменным числом пробелов ("ok":  0) —
    # схлопываем пробелы, чтобы проверки не зависели от форматирования.
    tr -d " 
" < "$prog" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
suite "F17: воркер сообщает GUI честный исход батча"
# ══════════════════════════════════════════════════════════════

# Успешный батч.
JSON=$(run_worker 0 no)
assert_contains "успех: state=success"          '"state":"success"' "$JSON"
assert_contains "успех: exitCode=0"             '"exitCode":0'      "$JSON"

# Провальный батч: ffmpeg падает → countFail>0. Суть находки — здесь раньше
# писалось «Готово», и GUI не имел ни одного способа узнать об ошибке.
JSON=$(run_worker 1 no)
assert_contains "провал: state=failed"          '"state":"failed"'  "$JSON"
assert_contains "провал: exitCode=1"            '"exitCode":1'      "$JSON"
assert_not_contains "провал: НЕ рапортует success" '"state":"success"' "$JSON"
# Пробелы схлопнуты выше, поэтому сверяем по фрагменту без них.
assert_contains "провал: message объясняет причину" "ошибками:1" "$JSON"

# Отмена пользователем отличается от провала.
JSON=$(run_worker 0 yes)
assert_contains "отмена: state=cancelled"       '"state":"cancelled"' "$JSON"

# Отказ до начала обработки. `exit 1` раньше уходил без финальной записи, и GUI
# показывал «завершился без отчёта о результате (state='')» вместо причины.
# Preflight удалённого бэкенда: пустой адрес → $script:remote_fatal.
JSON=$(run_worker 0 no "\$remote_enabled='yes'; \$remote_endpoint=''; \$remote_api_key=''")
assert_contains "remote preflight: state=failed"   '"state":"failed"'  "$JSON"
assert_contains "remote preflight: exitCode=1"     '"exitCode":1'      "$JSON"
# message называет КОНКРЕТНУЮ причину (первую [ОШИБКА]-строку preflight), а не
# общую фразу «проверка службы не прошла», с которой причину искали в логе.
assert_contains "remote preflight: message с конкретной причиной" 'адресслужбыпуст' "$JSON"
assert_not_contains "remote preflight: не общая фраза" 'проверкаслужбыконвертациинепрошла' "$JSON"
# Ранний отказ ДО строки, где раньше определялась Write-GUIProgress: функция
# обязана быть доступна первой же проверке конфига.
JSON=$(run_worker 0 no "\$playback_speed=':+:0'")
assert_contains "ранний отказ (playback_speed): state=failed" '"state":"failed"' "$JSON"
assert_contains "ранний отказ (playback_speed): message"      'playback_speed'   "$JSON"

# «не задано» в списке пресета GPU уходит в воркер как `:-:` (Get-GpuComboArg ниже),
# и воркер при включённом QSV не передаёт -preset — как CLI с `preset = -p5`.
FFLOG="$WORK/ffmpeg_args.log"; W_FFLOG=$(cygpath -w "$FFLOG")
_qsv_env="\$env:MOCK_FFMPEG_ENCODERS='qsv'; \$env:MOCK_FFMPEG_LOG='$W_FFLOG'; \$hw_accel=':+:intel'"
rm -f "$FFLOG"; run_worker 0 no "$_qsv_env; \$gpu_preset=':-:'" > /dev/null
_enc_line=$(grep -F -- '-c:v h264_qsv' "$FFLOG" 2>/dev/null | head -1)
assert_contains     "QSV + пресет «не задано»: кодирование на h264_qsv" "-c:v h264_qsv" "$_enc_line"
assert_not_contains "QSV + пресет «не задано»: без -preset"            "-preset"       "$_enc_line"
rm -f "$FFLOG"; run_worker 0 no "$_qsv_env; \$gpu_preset=':+:fast'" > /dev/null
_enc_line=$(grep -F -- '-c:v h264_qsv' "$FFLOG" 2>/dev/null | head -1)
assert_contains     "QSV + пресет fast: -preset fast"                   "-preset fast"  "$_enc_line"

# ══════════════════════════════════════════════════════════════
suite "GUI preflight: конфликт режимов и отсутствующий энкодер — ДО запуска"
# ══════════════════════════════════════════════════════════════
# Раньше GUI молча стартовал: часть галок игнорировалась скриптом, а выбранный GPU
# откатывался на CPU — узнать об этом можно было только из лога ПОСЛЕ старта.
# Проверяем source-scan'ом: интерактивные MessageBox в headless-тесте не кликнуть.
GUI_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v19.ps1"
src_gui="$(cat "$GUI_PS1")"

assert_contains "GUI: конфликт режимов детектируется"   '$_modes.Count -gt 1'          "$src_gui"
assert_contains "GUI: конфликт показан пользователю"    'Конфликт режимов'             "$src_gui"
assert_contains "GUI: конфликт можно отменить"          'if ($_ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }' "$src_gui"
assert_contains "GUI: probe энкодера до Run"            '-encoders'                    "$src_gui"
assert_contains "GUI: probe якорит имя по столбцу"      '(?m)^\s*[A-Z.]+\s+$([regex]::Escape($_cand))(\s|$)' "$src_gui"
assert_contains "GUI: сообщает об откате на CPU"        'программное (CPU) кодирование' "$src_gui"
# Резолвинг кандидата обязан совпадать со script.ps1, иначе GUI соврёт.
assert_contains "GUI: маппинг libx264 → h264+suffix"    '^libx264$'                    "$src_gui"
assert_contains "GUI: маппинг libsvtav1 → av1+suffix"   '^libsvtav1$'                  "$src_gui"

# Проверки обязаны стоять ДО запуска runspace, иначе смысла нет.
_gui_modes_line=$(grep -n '\$_modes.Count -gt 1' "$GUI_PS1" | head -1 | cut -d: -f1)
_gui_probe_line=$(grep -n 'Аппаратное ускорение недоступно' "$GUI_PS1" | head -1 | cut -d: -f1)
_gui_run_line=$(grep -n 'Запуск script.ps1 в фоновом Runspace' "$GUI_PS1" | head -1 | cut -d: -f1)
if [ -n "$_gui_modes_line" ] && [ -n "$_gui_run_line" ] && [ "$_gui_modes_line" -lt "$_gui_run_line" ]; then
    pass "GUI: проверка режимов стоит до запуска runspace"
else
    fail "GUI: проверка режимов стоит до запуска runspace" "modes<run" "modes=$_gui_modes_line run=$_gui_run_line"
fi
if [ -n "$_gui_probe_line" ] && [ -n "$_gui_run_line" ] && [ "$_gui_probe_line" -lt "$_gui_run_line" ]; then
    pass "GUI: probe энкодера стоит до запуска runspace"
else
    fail "GUI: probe энкодера стоит до запуска runspace" "probe<run" "probe=$_gui_probe_line run=$_gui_run_line"
fi

# message из прогресс-JSON — причина ОТКАЗА. Добавленное безусловно, оно делало бы
# успешный батч «Ошибкой» при любом информационном сообщении воркера на success.
assert_contains "GUI: message считается ошибкой только вне success" \
    'if ($json.message -and $state -ne "success") { $errParts += [string]$json.message }' "$src_gui"
assert_not_contains "GUI: безусловного добавления message больше нет" \
    'if ($json.message) { $errParts += [string]$json.message }' "$src_gui"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

suite "GUI: группа «Сервер»"
GUI="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v19.ps1"
gui_text="$(cat "$GUI")"
assert_contains "галка удалённого счёта" 'chkRemote'        "$gui_text"
assert_contains "выбор prefer"           'cmbRemotePrefer'  "$gui_text"
assert_contains "поле таймаута"          'txtRemoteWait'    "$gui_text"
# Группа стоит в ОСНОВНЫХ настройках, а не в спойлере «Дополнительные настройки».
# Спрятанная за «нажмите, чтобы развернуть» галка «Считать на сервере» неотличима
# от выключенной, а адрес и ключ надо видеть до запуска, а не после отказа службы.
assert_contains "группа «Сервер» — верхнего уровня" '$_mc.Add($grpRemote)' "$gui_text"
assert_not_contains "группа «Сервер» не в спойлере" '$_goth.Add($grpRemote)' "$gui_text"
# Развернувшийся спойлер обязан СДВИГАТЬ кнопки, а не накрывать их собой: Y задан
# абсолютными числами, а группа добавлена в контейнер раньше кнопок и рисуется поверх.
assert_contains "спойлер сдвигает то, что под ним" '$c.Top = $c.Top + $_delta' "$gui_text"
# Адрес и ключ живут в личном config.ini (он gitignored, как у yt-dlp), а GUI
# показывает их в полях и передаёт в запуск. Раньше здесь стояла метка
# «задано/не задано»: значения приходили только из переменных окружения.
assert_contains "поле ввода адреса"      'txtRemoteEndpoint' "$gui_text"
assert_contains "поле ввода ключа"       'txtRemoteApiKey'   "$gui_text"
# Ключ не должен читаться с экрана через плечо и на скриншотах.
assert_contains "ключ на экране замаскирован" 'txtRemoteApiKey.UseSystemPasswordChar = $true' "$gui_text"
# GUI ничего не пишет в config.ini — паритет с yt-dlp, где запись конфига
# из интерфейса тоже отсутствует. Правка в поле действует на текущий запуск.
assert_not_contains "GUI не сохраняет конфиг" 'Save-Config' "$gui_text"
# Галка без передачи переменных в runspace не делала бы ничего: скрипт читает
# именно эти имена, и без них удалённый бэкенд из GUI не включается вовсе.
for _v in remote_enabled remote_endpoint remote_api_key remote_prefer remote_wait_timeout; do
    assert_contains "$_v уезжает в runspace" "'$_v'" "$gui_text"
done

suite "GUI: группа «Распознавание речи (ASR)»"
assert_contains "галка режима"                'chkAsr'               "$gui_text"
assert_contains "группа — верхнего уровня"    '$_mc.Add($grpAsr)'    "$gui_text"
assert_contains "поле адреса"                 'txtAsrEndpoint'       "$gui_text"
assert_contains "ключ на экране замаскирован" 'txtAsrApiKey.UseSystemPasswordChar = $true' "$gui_text"
assert_contains "незаданная \${VAR} в [asr] без WARN" "(\$curSection -eq 'remote' -or \$curSection -eq 'asr')" "$gui_text"
for _v in asr_enabled asr_endpoint asr_api_key asr_api_key_command asr_pinned_pubkey asr_language asr_diarize asr_num_speakers; do
    assert_contains "$_v уезжает в runspace" "'$_v'" "$gui_text"
done

suite "GUI: значение config.ini вне пунктов списка не схлопывается молча"
# Раньше всё, что не "1", становилось вторым пунктом: `channels = +6` давал в GUI
# стерео, а CLI с тем же config.ini — `-ac 6`. Форму в тесте не открыть, поэтому
# функцию берём из НАСТОЯЩЕГО исходника GUI разбором AST и гоняем на живом ComboBox.
assert_contains "каналы уходят первым словом пункта" \
    "\$_chVal = ([string]\$comboAudioChannels.SelectedItem -split ' ')[0]" "$gui_text"
assert_not_contains "каналы больше не по SelectedIndex+1" 'comboAudioChannels.SelectedIndex + 1' "$gui_text"
_combo_ps=$(mktemp_suffix "${TMPDIR:-/tmp}/gui_combo_" .ps1)
cat > "$_combo_ps" <<'PSEOF'
param([string]$Gui)
Add-Type -AssemblyName System.Windows.Forms
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Select-ConfigComboValue' }, $true)
if (-not $fn) { Write-Output 'NOFUNC'; exit 1 }
. ([scriptblock]::Create($fn.Extent.Text))
function T([string]$Tag, [string[]]$Items, [string]$Value, [string]$Pattern) {
    $script:configWarnings = @()
    $c = [System.Windows.Forms.ComboBox]::new()
    $c.Items.AddRange($Items)
    Select-ConfigComboValue $c $Value 'k' $Pattern '2'
    Write-Output ("{0}={1}|{2}|{3}" -f $Tag, ([string]$c.SelectedItem -split ' ')[0], $c.Items.Count, $script:configWarnings.Count)
}
$ch = @('1 - Mono', '2 - Stereo'); $chP = '^0*[1-9]\d*$'
$rot = @('1 - cw', '2 - ccw'); $rotP = '^[0-3]$'   # ASCII: файл без BOM, PS 5.1 прочёл бы как ANSI
T 'CH1' $ch '1' $chP
T 'CH6' $ch '6' $chP
T 'CH0' $ch '0' $chP
T 'CHX' $ch 'abc' $chP
T 'R3' $rot '3' $rotP
T 'R0' $rot '0' $rotP
T 'R5' $rot '5' $rotP
PSEOF
_combo_out=$("$PS_CMD" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$_combo_ps")" \
    -Gui "$(cygpath -w "$GUI")" 2>&1 | tr -d '\r')
rm -f "$_combo_ps"
# Формат: <выбранное значение>|<пунктов в списке>|<предупреждений>.
assert_contains "channels = 1 — штатный пункт, без WARN"        "CH1=1|2|0" "$_combo_out"
assert_contains "channels = 6 — пункт «из config.ini» + WARN"   "CH6=6|3|1" "$_combo_out"
assert_contains "channels = 0 — откат на 2 + WARN"              "CH0=2|2|1" "$_combo_out"
assert_contains "channels = abc — откат на 2 + WARN"            "CHX=2|2|1" "$_combo_out"
assert_contains "rotation = 3 — пункт «из config.ini» + WARN"   "R3=3|3|1"  "$_combo_out"
assert_contains "rotation = 0 — пункт «из config.ini» + WARN"   "R0=0|3|1"  "$_combo_out"
assert_contains "rotation = 5 — откат на 2 + WARN"              "R5=2|2|1"  "$_combo_out"

suite "GUI: остальные списки из config.ini не схлопываются молча"
# Тот же класс для остальных списков формы: GPU-ускоритель, пресет/tune/rc, режим
# субтитров, prefer удалённого бэкенда. Тест исполняет НАСТОЯЩИЕ операторы исходника:
# из AST берутся заполнение списка (`.Items.AddRange(...)`) и вызов выбора пункта
# для этого списка, и оба гоняются на живом ComboBox. Копий шаблонов допустимых
# значений здесь нет — они живут только в исходнике GUI.
assert_contains "субтитры уходят первым словом пункта" \
    "\$subtitlesMode = ([string]\$comboSubtitlesMode.SelectedItem -split ' ')[0]" "$gui_text"
assert_not_contains "субтитры больше не по SelectedIndex" 'comboSubtitlesMode.SelectedIndex -eq 0' "$gui_text"
assert_contains "пресет GPU уходит через Get-GpuComboArg" \
    "\$script:gpu_preset = Get-GpuComboArg \$comboGpuPreset \$isGpuOn" "$gui_text"
assert_contains "tune GPU уходит через Get-GpuComboArg" \
    "\$script:gpu_tune   = Get-GpuComboArg \$comboGpuTune" "$gui_text"
assert_contains "rc GPU уходит через Get-GpuComboArg" \
    "\$script:gpu_rc     = Get-GpuComboArg \$comboGpuRC" "$gui_text"
assert_contains "пустой [asr] language — предупреждение" '[asr] language пуст' "$gui_text"
_combo2_ps=$(mktemp_suffix "${TMPDIR:-/tmp}/gui_combo2_" .ps1)
cat > "$_combo2_ps" <<'PSEOF'
param([string]$Gui)
Add-Type -AssemblyName System.Windows.Forms
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Gui, [ref]$null, [ref]$null)
foreach ($name in 'Select-ConfigComboValue', 'Select-ConfigComboMapped', 'Select-GpuComboValue', 'Get-GpuComboArg', 'Parse-Flag') {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if (-not $fn) { Write-Output "NOFUNC=$name"; exit 1 }
    . ([scriptblock]::Create($fn.Extent.Text))
}
# The "not set" item text of the GPU lists - the GUI's own assignment.
$unset = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
    $x.Left.Extent.Text -eq '$script:GpuUnsetItem' }, $true)
if (-not $unset) { Write-Output "NOFUNC=GpuUnsetItem"; exit 1 }
. ([scriptblock]::Create($unset.Extent.Text))
# Every form list read through SelectedItem (directly or via Get-GpuComboArg) must be a
# DropDownList: typed text of an editable list has no SelectedItem and reached the
# worker empty (`-preset ""`).
$readers = @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $x.Member.Extent.Text -eq 'SelectedItem' }, $true) | ForEach-Object { $_.Expression.Extent.Text })
$readers += @($ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and
        $x.GetCommandName() -eq 'Get-GpuComboArg' }, $true) | ForEach-Object { $_.CommandElements[1].Extent.Text })
$readers = @($readers | Where-Object { $_ -clike '$combo*' -or $_ -clike '$cmb*' } | Sort-Object -Unique)
Write-Output ("READERS={0}" -f $readers.Count)
foreach ($r in $readers) {
    $dd = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $x.Left.Extent.Text -eq "$r.DropDownStyle" -and $x.Right.Extent.Text -match 'DropDownList' }, $true)
    if (-not $dd) { Write-Output "EDITABLE=$r" }
}
# Fill statement: first "$Combo.Items.AddRange(" whose text contains $Like.
function Get-Fill([string]$Combo, [string]$Like) {
    $n = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $x.Extent.Text.StartsWith("$Combo.Items.AddRange(") -and $x.Extent.Text.Contains($Like) }, $true)
    if ($n) { $n.Extent.Text } else { "throw 'NOFILL $Combo'" }
}
# Select statement: the first call of $Cmd whose first argument is $Combo and whose
# text contains $SelLike (the GPU preset has one call per accelerator family).
function Get-Select([string]$Combo, [string]$Cmd, [string]$SelLike) {
    $n = $ast.Find({ param($x) $x -is [System.Management.Automation.Language.CommandAst] -and
        $x.GetCommandName() -eq $Cmd -and $x.CommandElements.Count -gt 1 -and
        $x.CommandElements[1].Extent.Text -eq $Combo -and $x.Extent.Text.Contains($SelLike) }, $true)
    if ($n) { $n.Extent.Text } else { "throw 'NOSELECT $Combo'" }
}
# Output: TAG=<first word of selected item>|<items>|<warnings>; for the mapped list
# (item text is not the value, and Cyrillic would not survive the console) - #<index>;
# for the GPU lists - what goes to the worker (Get-GpuComboArg with GPU on).
# The config value goes through the GUI's Parse-Flag: '-p5' is a disabled value.
function C([string]$Tag, [string]$Combo, [string]$CfgVar, [string]$Value, [string]$Like = '',
           [string]$SelLike = '', [string]$Cmd = 'Select-ConfigComboValue', [switch]$Raw) {
    $script:configWarnings = @()
    Set-Variable -Name $Combo.TrimStart('$') -Value ([System.Windows.Forms.ComboBox]::new())
    if ($Raw) { Set-Variable -Name $CfgVar -Value $Value }
    else      { Set-Variable -Name $CfgVar -Value (Parse-Flag $Value) }
    try {
        . ([scriptblock]::Create((Get-Fill $Combo $Like)))
        . ([scriptblock]::Create((Get-Select $Combo $Cmd $SelLike)))
    } catch { Write-Output ("{0}=ERR {1}" -f $Tag, $_); return }
    $c = Get-Variable -Name $Combo.TrimStart('$') -ValueOnly
    $w = if ($Cmd -eq 'Select-ConfigComboMapped') { "#$($c.SelectedIndex)" }
         elseif ($Cmd -eq 'Select-GpuComboValue') { Get-GpuComboArg $c $true }
         else { ([string]$c.SelectedItem -split ' ')[0] }
    Write-Output ("{0}={1}|{2}|{3}" -f $Tag, $w, $c.Items.Count, $script:configWarnings.Count)
}
C 'HWN'  '$comboHWAccel' '_cfg_hw_accel' 'nvidia' -Cmd 'Select-ConfigComboMapped'
C 'HWI'  '$comboHWAccel' '_cfg_hw_accel' 'INTEL'  -Cmd 'Select-ConfigComboMapped'
C 'HWO'  '$comboHWAccel' '_cfg_hw_accel' 'off'    -Cmd 'Select-ConfigComboMapped'
C 'HWX'  '$comboHWAccel' '_cfg_hw_accel' 'nvida'  -Cmd 'Select-ConfigComboMapped'
$G = 'Select-GpuComboValue'
C 'PN5'  '$comboGpuPreset' '_cfg_gpu_preset' 'p5'     'p1'       '"p5"'     $G
C 'PNS'  '$comboGpuPreset' '_cfg_gpu_preset' 'slow'   'p1'       '"p5"'     $G
C 'PNX'  '$comboGpuPreset' '_cfg_gpu_preset' 'turbo'  'p1'       '"p5"'     $G
C 'PNO'  '$comboGpuPreset' '_cfg_gpu_preset' '-p5'    'p1'       '"p5"'     $G
C 'PNE'  '$comboGpuPreset' '_cfg_gpu_preset' '+'      'p1'       '"p5"'     $G
C 'PIS'  '$comboGpuPreset' '_cfg_gpu_preset' 'slow'   'veryfast' '"medium"' $G
C 'PIP'  '$comboGpuPreset' '_cfg_gpu_preset' 'p5'     'veryfast' '"medium"' $G
C 'PIO'  '$comboGpuPreset' '_cfg_gpu_preset' '-p5'    'veryfast' '"medium"' $G
C 'TU'   '$comboGpuTune' '_cfg_gpu_tune' 'uhq'  '' '' $G
C 'TX'   '$comboGpuTune' '_cfg_gpu_tune' 'fast' '' '' $G
C 'TO'   '$comboGpuTune' '_cfg_gpu_tune' '-hq'  '' '' $G
C 'RCQ'  '$comboGpuRC' '_cfg_gpu_rc' 'constqp' '' '' $G
C 'RCH'  '$comboGpuRC' '_cfg_gpu_rc' 'vbr_hq'  '' '' $G
C 'RCX'  '$comboGpuRC' '_cfg_gpu_rc' 'abr'     '' '' $G
C 'RCO'  '$comboGpuRC' '_cfg_gpu_rc' '-vbr'    '' '' $G
# GPU off: a chosen preset still goes disabled, with its value (as before).
$cg = [System.Windows.Forms.ComboBox]::new(); $cg.Items.AddRange(@($script:GpuUnsetItem, 'p1', 'p5')); $cg.SelectedIndex = 2
Write-Output ("GOFF={0}" -f (Get-GpuComboArg $cg $false))
C 'SM'   '$comboSubtitlesMode' '_cfg_video_subtitles' 'meta'
C 'SB'   '$comboSubtitlesMode' '_cfg_video_subtitles' 'burn'
C 'SX'   '$comboSubtitlesMode' '_cfg_video_subtitles' 'soft'
C 'RPG'  '$cmbRemotePrefer' '_cfg_remote_pref' 'gpu' -Raw
C 'RPX'  '$cmbRemotePrefer' '_cfg_remote_pref' 'fastest' -Raw
PSEOF
_combo2_out=$("$PS_CMD" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(cygpath -w "$_combo2_ps")" \
    -Gui "$(cygpath -w "$GUI")" 2>&1 | tr -d '\r')
rm -f "$_combo2_ps"
assert_not_contains "функции выбора найдены в исходнике GUI" "NOFUNC" "$_combo2_out"
assert_not_contains "операторы списков найдены в исходнике GUI" "ERR" "$_combo2_out"
# GPU-ускоритель: значение не равно тексту пункта — выбор по таблице.
assert_contains "hw_accel = nvidia — пункт NVIDIA, без WARN"        "HWN=#1|3|0" "$_combo2_out"
assert_contains "hw_accel = INTEL — регистр не важен (как в CLI)"   "HWI=#2|3|0" "$_combo2_out"
assert_contains "hw_accel = off — «Без ускорения», без WARN"        "HWO=#0|3|0" "$_combo2_out"
assert_contains "hw_accel = nvida — «Без ускорения» + WARN"         "HWX=#0|3|1" "$_combo2_out"
# Пресет: NVENC принимает и прежние имена (slow), QSV — только свои семь. Первый
# пункт каждого GPU-списка — «не задано»; в выводе — то, что уходит в воркер.
assert_contains "NVENC preset = p5 — штатный пункт"                 "PN5=:+:p5|8|0"     "$_combo2_out"
assert_contains "NVENC preset = slow — пункт «из config.ini» + WARN" "PNS=:+:slow|9|1"  "$_combo2_out"
assert_contains "NVENC preset = turbo — откат на p5 + WARN"         "PNX=:+:p5|8|1"     "$_combo2_out"
assert_contains "QSV preset = slow — штатный пункт"                 "PIS=:+:slow|8|0"   "$_combo2_out"
assert_contains "QSV preset = p5 — откат на medium + WARN"          "PIP=:+:medium|8|1" "$_combo2_out"
assert_contains "tune = uhq — пункт «из config.ini» + WARN"         "TU=:+:uhq|6|1"     "$_combo2_out"
assert_contains "tune = fast — откат на hq + WARN"                  "TX=:+:hq|5|1"      "$_combo2_out"
assert_contains "rc = constqp — штатный пункт"                      "RCQ=:+:constqp|4|0" "$_combo2_out"
assert_contains "rc = vbr_hq — пункт «из config.ini» + WARN"        "RCH=:+:vbr_hq|5|1" "$_combo2_out"
assert_contains "rc = abr — откат на vbr + WARN"                    "RCX=:+:vbr|4|1"    "$_combo2_out"
# Выключенное или пустое значение — «не задано», в воркер уходит `:-:` (без -preset/
# -tune/-rc, как у CLI). Шаблонный config.ini: preset = -p5 при hw_accel = +intel.
assert_contains "NVENC preset = -p5 — «не задано», без WARN"        "PNO=:-:|8|0"       "$_combo2_out"
assert_contains "NVENC preset = + (пусто) — «не задано», без WARN"  "PNE=:-:|8|0"       "$_combo2_out"
assert_contains "QSV preset = -p5 (шаблон) — «не задано», без WARN" "PIO=:-:|8|0"       "$_combo2_out"
assert_contains "tune = -hq — «не задано», без WARN"                "TO=:-:|5|0"        "$_combo2_out"
assert_contains "rc = -vbr — «не задано», без WARN"                 "RCO=:-:|4|0"       "$_combo2_out"
assert_contains "GPU выключен — пресет уходит выключенным"          "GOFF=:-:p5"        "$_combo2_out"
# Список, читаемый через SelectedItem (напрямую или через Get-GpuComboArg), обязан быть
# DropDownList: набранный руками текст не имеет SelectedItem и уходил пустым.
assert_not_contains "списки, читаемые через SelectedItem, — DropDownList" "EDITABLE=" "$_combo2_out"
assert_not_contains "списки, читаемые через SelectedItem, найдены" "READERS=0" "$_combo2_out"# Субтитры: CLI знает только burn/meta, иное молча не делает ничего — GUI
# не имеет права молча прожигать.
assert_contains "subtitles = meta — пункт meta"                     "SM=meta|2|0"    "$_combo2_out"
assert_contains "subtitles = burn — пункт burn"                     "SB=burn|2|0"    "$_combo2_out"
assert_contains "subtitles = soft — откат на burn + WARN"           "SX=burn|2|1"    "$_combo2_out"
assert_contains "prefer = gpu — пункт gpu"                          "RPG=gpu|3|0"    "$_combo2_out"
assert_contains "prefer = fastest — откат на auto + WARN"           "RPX=auto|3|1"   "$_combo2_out"

summary
