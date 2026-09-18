#!/bin/bash
# ============================================================
# test_24_gui_worker_runspace.sh — воркер ffmpeg запускается ТАК ЖЕ, как его
# запускает GUI: RunspaceFactory + SessionStateProxy + AddScript(<строка>).
#
# Зачем отдельный файл. test_16_gui_state.sh дот-сорсит FFmpeg_Converter_script.ps1
# ИЗ ФАЙЛА, а GUI подаёт его СТРОКОЙ. Разница не косметическая: у строкового
# скрипта автоматическая $PSScriptRoot равна пустой строке и ПЕРЕКРЫВАЕТ значение,
# выставленное через SessionStateProxy. `Join-Path $PSScriptRoot 'remote_client.ps1'`
# бросал «Cannot bind argument to parameter 'Path'», top-level trap делал break —
# и воркер умирал до первого файла ВО ВСЕХ режимах, в .ps1-GUI и в собранном EXE.
# Ни один тест этого не видел, потому что все они запускали воркер иначе.
#
# Второй класс, невидимый при дот-сорсинге: в hostless-runspace PowerShell пишет
# stderr нативной команды в $ps.Streams.Error, а GUI считает успехом только
# state=success ПРИ ПУСТОМ Error-stream. Полностью успешный extract/frames/merge
# показывался как «Ошибка» с MessageBox.
#
# Поэтому здесь проверяется ровно то, что видит GUI: state из JSON-прогресса и
# Streams.Error.Count. Раскладка EXE (remote_client.ps1 вклеен в ту же строку)
# проверяется отдельным прогоном — там дот-сорсинг модуля не должен происходить.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

WORKER="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"
REMOTE="$PROJECT_DIR/ffmpeg/remote_client.ps1"
GUI="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v18.ps1"
MOCK_CMD="$TESTS_DIR/mocks/ffmpeg.cmd"

for _f in "$WORKER" "$REMOTE" "$GUI" "$MOCK_CMD"; do
    if [ ! -f "$_f" ]; then
        suite "GUI-путь воркера"
        fail "файл на месте" "$_f" "не найден"
        summary
        exit 1
    fi
done

PS_BIN=""
command -v powershell &>/dev/null && PS_BIN="powershell"
[ -z "$PS_BIN" ] && command -v pwsh &>/dev/null && PS_BIN="pwsh"

# ══════════════════════════════════════════════════════════════
suite "GUI-путь: контракт в исходниках"
# ══════════════════════════════════════════════════════════════
# Статическая половина работает везде, включая Linux-линию CI, где PowerShell'а нет.
worker_src="$(cat "$WORKER")"
gui_src="$(cat "$GUI")"
assert_contains "GUI передаёт guiAppDir в runspace" 'SetVariable("guiAppDir"' "$gui_src"
assert_contains "воркер берёт каталог из guiAppDir" '$guiAppDir' "$worker_src"
assert_contains "модуль подключается по отсутствию функции, а не по пути" \
    'Get-Command Set-RemoteActive' "$worker_src"
# stderr нативных команд обязан уходить в конвейер, иначе он оседает в Streams.Error.
for _m in "-vn -c:a copy" "-r 1/1" "-f concat -safe 0"; do
    _line=$(grep -F -- "$_m" "$WORKER" | grep -F '& $ffmpeg' | head -1)
    assert_contains "stderr дренируется в конвейер: $_m" '2>&1 | ForEach-Object' "$_line"
done

if [ -z "$PS_BIN" ]; then
    skip "прогон воркера через AddScript" "PowerShell не найден"
    summary
    exit 0
fi

# Одного PowerShell мало: воркеру нужен ещё и Windows. Мок ffmpeg здесь — `.cmd`
# (см. MOCK_CMD выше), вне Windows его не запустить ничем, поэтому воркер не доходит
# до первого файла, progress.json не появляется и все шесть проверок видят state=none.
# На раннерах GitHub pwsh стоит и в Linux, и в macOS, так что гард «есть PowerShell»
# их пропускал — обе линии CI стояли красными на тесте, который там и не мог пройти.
# Проверяется именно GUI-путь, а GUI — WinForms, то есть Windows по построению:
# покрытия вне Windows здесь нет и быть не может.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *)
        skip "прогон воркера через AddScript" "GUI-воркер — Windows-путь (мок ffmpeg это .cmd)"
        summary
        exit 0 ;;
esac

# ══════════════════════════════════════════════════════════════
suite "GUI-путь: прогон воркера через RunspaceFactory + AddScript"
# ══════════════════════════════════════════════════════════════
WORK=$(mktemp -d "${TMPDIR:-/tmp}/test_gui_worker_XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/in" "$WORK/out"
: > "$WORK/in/clip.mp4"

WORK_WIN=$(cygpath -w "$WORK" 2>/dev/null || echo "$WORK")
WORKER_WIN=$(cygpath -w "$WORKER" 2>/dev/null || echo "$WORKER")
APPDIR_WIN=$(cygpath -w "$PROJECT_DIR/ffmpeg" 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")
MOCK_WIN=$(cygpath -w "$MOCK_CMD" 2>/dev/null || echo "$MOCK_CMD")

HARNESS=$(mktemp_suffix "${TMPDIR:-/tmp}/gui_worker_" .ps1)
cat > "$HARNESS" <<'PSEOF'
param([string]$Worker, [string]$AppDir, [string]$Work, [string]$Ffmpeg, [string]$Mode, [switch]$EmbedRemote)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Worker text exactly as GUI/build_exe prepares it: a STRING. With -EmbedRemote
# the module is glued into the same string - the layout of the built EXE.
$script = [System.IO.File]::ReadAllText($Worker, [System.Text.Encoding]::UTF8)
if ($EmbedRemote) {
    $remote = [System.IO.File]::ReadAllText((Join-Path $AppDir 'remote_client.ps1'), [System.Text.Encoding]::UTF8)
    $script = $remote + "`n" + $script
}

$progress = Join-Path $Work 'progress.json'
$vars = @{
    folder_sources = (Join-Path $Work 'in'); folder_destination = (Join-Path $Work 'out')
    audio_only = 'no'; merge_files = 'no'; create_frame = 'no'; copy_codecs = 'no'
    extract_audio_copy = 'no'; overwrite_existing = 'no'
    multithreads = ':+:4'; parallel_files = ':-:1'
    audio_codec = ':+:aac'; audio_number_channels = ':+:2'; audio_bitrate = ':+:128'
    audio_sampling_rate = ':+:48000'; audio_normalize = ':-:loudnorm'
    video_codec = ':+:libx264'; video_resolution = ':-:1280x720'; video_bitrate = ':-:3000'
    video_number_frames = ':-:30'; video_rotation = ':-:2'; video_subtitles = ':-:burn'
    video_quality = ':+:23'; keep_aspect_ratio = ':+:yes'; output_container = ':+:mp4'
    hw_accel = ':-:intel'; gpu_preset = ':-:p5'; gpu_tune = ':-:hq'; gpu_rc = ':-:vbr'
    playback_speed = ':-:1.0'
    start_coding = ':-:01-00-00'; length_coding = ':-:00-05-00'; split_by_silence = 'no'
    silence_duration = '2.0'; silence_threshold = '-30dB'
    ffmpeg = $Ffmpeg; save_old_extension = 'no'
    format_files_in = 'mp4,mkv,avi'; subtitles_style = ''
    dry_run = 'no'; enable_log = 'no'; log_file = (Join-Path $Work 'x.log')
    remote_enabled = 'no'; remote_endpoint = ''; remote_api_key = ''
    remote_api_key_command = ''; remote_prefer = 'auto'; remote_wait_timeout = '1800'
    remote_stall_timeout = '900'; remote_on_failure = 'abort'
}
switch ($Mode) {
    'extract' { $vars.extract_audio_copy = 'yes' }
    'frames'  { $vars.create_frame = 'yes' }
    'merge'   { $vars.merge_files = 'yes' }
    'audio'   { $vars.audio_only = 'yes' }
}

$rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
$rs.Open()
foreach ($kv in $vars.GetEnumerator()) { $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value) }
# Exactly as GUI does: PSScriptRoot is set, but must not be relied upon.
$rs.SessionStateProxy.SetVariable('PSScriptRoot', $AppDir)
$rs.SessionStateProxy.SetVariable('guiAppDir', $AppDir)
$rs.SessionStateProxy.SetVariable('guiProgressFile', $progress)
$rs.SessionStateProxy.SetVariable('guiCancelFile', (Join-Path $Work 'cancel.flag'))

$ps = [System.Management.Automation.PowerShell]::Create()
$ps.Runspace = $rs
[void]$ps.AddScript($script)
$h = $ps.BeginInvoke()
if (-not $h.AsyncWaitHandle.WaitOne(120000)) { Write-Output "TIMEOUT=1"; exit 1 }
try { $ps.EndInvoke($h) | Out-Null } catch { Write-Output ("EXC=" + $_.Exception.Message) }

$errCount = $ps.Streams.Error.Count
Write-Output ("ERRCOUNT=" + $errCount)
if ($errCount -gt 0) { Write-Output ("ERR1=" + $ps.Streams.Error[0].ToString()) }
$state = 'none'
if (Test-Path -LiteralPath $progress) {
    try { $state = ([System.IO.File]::ReadAllText($progress) | ConvertFrom-Json).state } catch {}
}
Write-Output ("STATE=" + $state)
$ps.Dispose(); $rs.Close()
PSEOF
HARNESS_WIN=$(cygpath -w "$HARNESS" 2>/dev/null || echo "$HARNESS")

run_mode() {
    local mode="$1" embed="$2"
    rm -rf "$WORK/out"; mkdir -p "$WORK/out"
    : > "$WORK/in/clip.mp4"
    local args=(-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$HARNESS_WIN"
        -Worker "$WORKER_WIN" -AppDir "$APPDIR_WIN" -Work "$WORK_WIN" -Ffmpeg "$MOCK_WIN" -Mode "$mode")
    [ "$embed" = "embed" ] && args+=(-EmbedRemote)
    "$PS_BIN" "${args[@]}" 2>&1 | tr -d '\r'
}

get_field() { printf '%s\n' "$1" | grep "^${2}=" | head -1 | sed "s/^${2}=//"; }

for mode in transcode extract frames merge audio; do
    out=$(run_mode "$mode" "")
    assert_eq "режим $mode: state=success"        "success" "$(get_field "$out" STATE)"
    assert_eq "режим $mode: Streams.Error пуст"   "0"       "$(get_field "$out" ERRCOUNT)"
done

# ══════════════════════════════════════════════════════════════
suite "GUI-путь: раскладка EXE (remote_client вклеен в ту же строку)"
# ══════════════════════════════════════════════════════════════
# В EXE функции модуля уже объявлены, и дот-сорсинг выполняться не должен вовсе.
out=$(run_mode "transcode" "embed")
assert_eq "EXE-раскладка: state=success"      "success" "$(get_field "$out" STATE)"
assert_eq "EXE-раскладка: Streams.Error пуст" "0"       "$(get_field "$out" ERRCOUNT)"

rm -f "$HARNESS"
summary
