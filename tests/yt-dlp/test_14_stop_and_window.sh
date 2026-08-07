#!/bin/bash
# ============================================================
# test_14_stop_and_window.sh — «Остановить» и поведение свёрнутого окна (GUI PS1).
#
# 1. Остановка. yt-dlp.exe собран PyInstaller в режиме onefile: запущенный процесс —
#    это bootloader, который порождает ВТОРОЙ yt-dlp.exe, и качает именно дочерний.
#    Process.Kill() убивал только родителя, поэтому после «Остановить» закачка
#    продолжалась в фоне (замер: после Kill в системе оставался живой yt-dlp.exe,
#    после taskkill /T — ни одного). Kill(entireProcessTree) есть только в .NET Core
#    3.0+, а GUI работает на .NET Framework 4.x → снимаем дерево через taskkill /T /F.
#
# 2. Свёрнутое окно. Запись в контролы свёрнутой формы возвращает её из свёрнутого
#    состояния (замерено: цикл с $progressBar.Value/$form.Text не даёт окну остаться
#    свёрнутым, без них — даёт). WinForms после этого считает окно нормальным, а
#    панель задач — свёрнутым, и клик по кнопке в панели задач его не возвращает.
#    Поэтому пока окно свёрнуто, UI не трогаем, а вывод копим и выливаем при возврате.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.ps1"

source "$TESTS_DIR/lib/framework.sh"

src="$(cat "$DLP_PS1")"

# ══════════════════════════════════════════════════════════════
suite "PS1: остановка снимает дерево процессов"
# ══════════════════════════════════════════════════════════════
assert_contains "Stop-ProcessTree определён"        "function Stop-ProcessTree"  "$src"
assert_contains "снимает дерево через taskkill /T"  '/PID $($Proc.Id) /T /F'     "$src"
assert_contains "taskkill без окна консоли"         '$tk.CreateNoWindow  = $true' "$src"
assert_contains "Stop-Download снимает загрузку"    'Stop-ProcessTree $global:downloadProcess'  "$src"
assert_contains "Stop-Download снимает перевод"     'Stop-ProcessTree $global:translateProcess' "$src"
# Одиночный Kill() оставлял бы дочерний yt-dlp живым — прямых вызовов быть не должно,
# кроме подстраховки внутри самого Stop-ProcessTree (строки-комментарии не считаем).
kill_calls=$(grep -v '^\s*#' "$DLP_PS1" | grep -c '\.Kill()')
assert_eq "прямых .Kill() не осталось (только fallback в Stop-ProcessTree)" "1" "$kill_calls"
assert_not_contains "vot убивается не голым Kill" 'try { $votProc.Kill() } catch {}' "$src"

# ══════════════════════════════════════════════════════════════
suite "PS1: свёрнутое окно не трогаем"
# ══════════════════════════════════════════════════════════════
assert_contains "детектор свёрнутого окна"      "function Test-WindowMinimized"  "$src"
assert_contains "буфер вывода"                  '$global:pendingOutput'          "$src"
assert_contains "Append-Output проверяет окно"  "if (Test-WindowMinimized) {"    "$src"
assert_contains "Set-UiProgress определён"      "function Set-UiProgress"        "$src"
assert_contains "слив буфера при развороте"     "Flush-PendingOutput"            "$src"
assert_contains "обработчик Resize"             '$form.Add_Resize({'             "$src"
# Внутри цикла загрузки прямых обращений к контролам быть не должно — только
# через Set-UiProgress, иначе защита обходится в самом горячем месте.
assert_not_contains "нет прямого progressBar.Value в цикле"  '$progressBar.Value = [math]::Min($pct, 100)'  "$src"
assert_not_contains "нет прямого form.Text в цикле"          '$form.Text         = "Video Downloader (yt-dlp) v16  [$itemNum/$totalItems]  $pct%"'  "$src"
# UI-поток не должен молчать 100 мс подряд: команды окна обрабатывались рывками.
assert_not_contains "нет сплошного Start-Sleep 100 в цикле"  "Start-Sleep -Milliseconds 100"  "$src"
assert_contains "пауза с прокачкой сообщений"   '[System.Threading.Thread]::Sleep(10)'  "$src"

# ══════════════════════════════════════════════════════════════
suite "PS1: Stop-ProcessTree на реальном дереве процессов"
# ══════════════════════════════════════════════════════════════
PS_CMD=""
command -v powershell &>/dev/null && PS_CMD="powershell"
[ -z "$PS_CMD" ] && command -v pwsh &>/dev/null && PS_CMD="pwsh"

winforms_ok=0
if [ -n "$PS_CMD" ]; then
    probe=$($PS_CMD -NoProfile -NonInteractive -Command "try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; 'ok' } catch { 'no' }" 2>/dev/null | tr -d '\r')
    [ "$probe" = "ok" ] && winforms_ok=1
fi

if [ "$winforms_ok" -ne 1 ]; then
    skip "Stop-ProcessTree" "нет Windows PowerShell + WinForms"
else
    win_prod=$(cygpath -w "$DLP_PS1" 2>/dev/null || echo "$DLP_PS1")
    harness=$(mktemp /tmp/test_stoptree_XXXXXX.ps1)
    win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
    # Стенд без сети: cmd.exe порождает ping как дочерний процесс — та же форма
    # «родитель + ребёнок», из-за которой Kill() не останавливал закачку.
    cat > "$harness" << 'PS1EOF'
param([string]$Prod)
$ErrorActionPreference = 'Stop'
$env:YTDLP_TEST = '1'
. $Prod

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName        = "cmd.exe"
$psi.Arguments       = '/c "ping -n 30 127.0.0.1 >nul"'
$psi.UseShellExecute = $false
$psi.CreateNoWindow  = $true
$parent = [System.Diagnostics.Process]::Start($psi)
Start-Sleep -Milliseconds 1200

# conhost.exe тоже числится ребёнком cmd.exe — нас интересует настоящая полезная
# нагрузка (ping), как в реальном случае интересует дочерний yt-dlp.exe.
$kids = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($parent.Id)" |
          Where-Object { $_.Name -match 'PING' })
Write-Output ("children=" + $kids.Count)
$kidIds = @($kids | ForEach-Object { $_.ProcessId })

Stop-ProcessTree $parent
Start-Sleep -Milliseconds 1200

$parentAlive = -not $parent.HasExited
$kidsAlive = 0
foreach ($id in $kidIds) {
    if (Get-Process -Id $id -ErrorAction SilentlyContinue) { $kidsAlive++ }
}
Write-Output ("parent_alive=" + $parentAlive)
Write-Output ("kids_alive=" + $kidsAlive)

# Мёртвый/несуществующий процесс не должен приводить к исключению.
try { Stop-ProcessTree $parent; Stop-ProcessTree $null; Write-Output "safe=True" }
catch { Write-Output "safe=False" }
PS1EOF
    ps_out=$($PS_CMD -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win_harness" "$win_prod" 2>&1 | tr -d '\r')
    rm -f "$harness"
    get_field() { printf '%s\n' "$1" | grep "^${2}=" | sed "s/^${2}=//"; }

    assert_eq "стенд поднял дочерний процесс" "1"     "$(get_field "$ps_out" children)"
    assert_eq "родитель снят"                 "False" "$(get_field "$ps_out" parent_alive)"
    assert_eq "дочерний тоже снят"            "0"     "$(get_field "$ps_out" kids_alive)"
    assert_eq "повтор и \$null безопасны"     "True"  "$(get_field "$ps_out" safe)"
fi

summary
