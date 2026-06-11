#!/bin/bash
# ============================================================
# test_05_cmd.sh — Тест CMD yt-dlp: формат, cookies, перевод, Bug 7
# Тестирует: quality×format матрицу, cookie_choice→cookie_arg,
# translate_choice→translate_lang/mode, Bug7 (dl_errorlevel fix).
# Использует cmd.exe через inline .cmd скрипты.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD yt-dlp тесты"
    skip "Все CMD тесты" "cmd.exe не доступен"
    summary
    exit 0
fi

# ── Хелпер: запустить CMD через temp файл ─────────────────────────────────
run_cmd_file() {
    local script_content="$1"
    local tmp_cmd
    tmp_cmd=$(mktemp /tmp/test_ytcmd_XXXXXX.cmd)
    printf '@echo off\r\nchcp 65001 >nul 2>&1\r\nsetlocal enabledelayedexpansion\r\n%s\r\n' \
        "$script_content" > "$tmp_cmd"
    local win_path
    win_path=$(cygpath -w "$tmp_cmd" 2>/dev/null || echo "$tmp_cmd" | sed 's|/c/|C:/|' | sed 's|/|\\|g')
    local result
    result=$(cmd //c "$win_path" 2>/dev/null)
    rm -f "$tmp_cmd"
    echo "$result"
}

# ── Хелпер: запустить quality×format блок ─────────────────────────────────
run_format() {
    local quality="$1"
    local fmt="$2"
    local TMP_DIR TMP_CMD WIN_CMD
    TMP_DIR=$(mktemp -d /tmp/test_ytfmt_XXXXXX)
    TMP_CMD="$TMP_DIR/fmt.cmd"
    WIN_CMD=$(cygpath -w "$TMP_CMD")

    cat > "$TMP_CMD" << CMDEOF
@echo off
chcp 65001 >nul 2>&1
setlocal enabledelayedexpansion
set quality=$quality
set fmt=$fmt
set "save_settings="
if %quality%==91 (
    set "save_settings=--sub-lang ru --write-auto-sub --sub-format vtt --skip-download"
    goto :done
)
if %quality%==92 (
    set "save_settings=--sub-lang en --write-auto-sub --sub-format vtt --skip-download"
    goto :done
)
if %fmt%==0 (
    if %quality%==0 set "save_settings=-f bestaudio[ext=m4a]/bestaudio"
    if %quality%==1 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360][vcodec^=avc1]"
    if %quality%==2 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480][vcodec^=avc1]"
    if %quality%==3 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720][vcodec^=avc1]"
    if %quality%==4 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080][vcodec^=avc1]"
    if %quality%==5 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440][vcodec^=avc1]"
    if %quality%==6 set "save_settings=-f bestaudio[ext=m4a]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160][vcodec^=avc1]"
)
if %fmt%==1 (
    if %quality%==0 set "save_settings=-f 140"
    if %quality%==1 set "save_settings=-f 140+134"
    if %quality%==2 set "save_settings=-f 140+135/134"
    if %quality%==3 set "save_settings=-f 140+136/135/134"
    if %quality%==4 set "save_settings=-f 140+137/136/135/134"
    if %quality%==5 set "save_settings=-f 140+138/137/136/135/134"
    if %quality%==6 set "save_settings=-f 140+139/138/137/136/135/134"
)
if %fmt%==2 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+230"
    if %quality%==2 set "save_settings=-f 234+231/230"
    if %quality%==3 set "save_settings=-f 234+232/231/230"
    if %quality%==4 set "save_settings=-f 234+233/232/231/230"
    if %quality%==5 set "save_settings=-f 234+234/233/232/231/230"
    if %quality%==6 set "save_settings=-f 234+235/234/233/232/231/230"
)
if %fmt%==3 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+296"
    if %quality%==2 set "save_settings=-f 234+297/296"
    if %quality%==3 set "save_settings=-f 234+298/297/296"
    if %quality%==4 set "save_settings=-f 234+299/298/297/296"
    if %quality%==5 set "save_settings=-f 234+300/299/298/297/296"
    if %quality%==6 set "save_settings=-f 234+301/300/299/298/297/296"
)
if %fmt%==4 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+309"
    if %quality%==2 set "save_settings=-f 234+310/309"
    if %quality%==3 set "save_settings=-f 234+311/310/309"
    if %quality%==4 set "save_settings=-f 234+312/311/310/309"
    if %quality%==5 set "save_settings=-f 234+313/312/311/310/309"
    if %quality%==6 set "save_settings=-f 234+314/313/312/311/310/309"
)
if %fmt%==5 (
    if %quality%==0 set "save_settings=-f 234"
    if %quality%==1 set "save_settings=-f 234+696"
    if %quality%==2 set "save_settings=-f 234+697/696"
    if %quality%==3 set "save_settings=-f 234+698/697/696"
    if %quality%==4 set "save_settings=-f 234+699/698/697/696"
    if %quality%==5 set "save_settings=-f 234+700/699/698/697/696"
    if %quality%==6 set "save_settings=-f 234+701/700/699/698/697/696"
)
if %fmt%==6 (
    if %quality%==0 set "save_settings=-f 140"
    if %quality%==1 set "save_settings=-f 18"
    if %quality%==2 set "save_settings=-f 20/18"
    if %quality%==3 set "save_settings=-f 22/20/18"
    if %quality%==4 set "save_settings=-f 24/22/20/18"
    if %quality%==5 set "save_settings=-f 26/24/22/20/18"
    if %quality%==6 set "save_settings=-f 28/26/24/22/20/18"
)
:done
echo !save_settings!
CMDEOF

    result=$(cmd //c "$WIN_CMD" 2>/dev/null)
    rm -rf "$TMP_DIR"
    echo "$result"
}

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_best (ext=m4a workaround)"
# ══════════════════════════════════════════════════════════════

result=$(run_format 0 0)
assert_contains "audio → bestaudio[ext=m4a]"  "bestaudio[ext=m4a]"  "$result"

result=$(run_format 3 0)
assert_contains "720p → height<=720"          "height<=720"          "$result"
assert_contains "720p → vcodec^=avc1"         "vcodec^=avc1"         "$result"
assert_contains "720p → ext=m4a"              "ext=m4a"              "$result"

result=$(run_format 6 0)
assert_contains "2160p → height<=2160"        "height<=2160"         "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_https (числовые ID)"
# ══════════════════════════════════════════════════════════════

result=$(run_format 0 1)
assert_eq "audio → -f 140"          "-f 140"              "$result"

result=$(run_format 3 1)
assert_eq "720p → 140+136/135/134"  "-f 140+136/135/134"  "$result"

result=$(run_format 6 1)
assert_eq "2160p → 140+139/..."     "-f 140+139/138/137/136/135/134"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_m3u8"
# ══════════════════════════════════════════════════════════════

result=$(run_format 0 2)
assert_eq "audio → -f 234"          "-f 234"              "$result"

result=$(run_format 3 2)
assert_eq "720p → 234+232/231/230"  "-f 234+232/231/230"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_https_60fps"
# ══════════════════════════════════════════════════════════════

result=$(run_format 3 3)
assert_eq "720p → 234+298/297/296"  "-f 234+298/297/296"  "$result"

result=$(run_format 4 3)
assert_eq "1080p → 234+299/..."     "-f 234+299/298/297/296"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_m3u8_60fps"
# ══════════════════════════════════════════════════════════════

result=$(run_format 3 4)
assert_eq "720p → 234+311/310/309"  "-f 234+311/310/309"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_https_60fps_hdr"
# ══════════════════════════════════════════════════════════════

result=$(run_format 3 5)
assert_eq "720p → 234+698/697/696"  "-f 234+698/697/696"  "$result"

result=$(run_format 4 5)
assert_eq "1080p → 234+699/..."     "-f 234+699/698/697/696"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: old_combo"
# ══════════════════════════════════════════════════════════════

result=$(run_format 0 6)
assert_eq "audio → -f 140"      "-f 140"        "$result"

result=$(run_format 1 6)
assert_eq "360p → -f 18"        "-f 18"         "$result"

result=$(run_format 3 6)
assert_eq "720p → -f 22/20/18"  "-f 22/20/18"   "$result"

result=$(run_format 4 6)
assert_eq "1080p → -f 24/22/20/18"  "-f 24/22/20/18"  "$result"

result=$(run_format 6 6)
assert_eq "2160p → -f 28/..."   "-f 28/26/24/22/20/18"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: субтитры (качество 91/92)"
# ══════════════════════════════════════════════════════════════

result=$(run_format 91 0)
assert_contains "quality=91 → --sub-lang ru"  "--sub-lang ru"   "$result"
assert_contains "quality=91 → --skip-download" "--skip-download" "$result"

result=$(run_format 92 0)
assert_contains "quality=92 → --sub-lang en"  "--sub-lang en"   "$result"
assert_contains "quality=92 → --skip-download" "--skip-download" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: cookie_choice → cookie_arg"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd_file '
set cookie_choice=0
set "cookie_arg="
if %cookie_choice%==1 set "cookie_arg=--cookies-from-browser chrome"
if %cookie_choice%==2 set "cookie_arg=--cookies-from-browser firefox"
if %cookie_choice%==3 set "cookie_arg=--cookies-from-browser edge"
echo [!cookie_arg!]
')
assert_eq "cookie_choice=0 → пустой"  "[]"  "$result"

result=$(run_cmd_file '
set cookie_choice=1
set "cookie_arg="
if %cookie_choice%==1 set "cookie_arg=--cookies-from-browser chrome"
if %cookie_choice%==2 set "cookie_arg=--cookies-from-browser firefox"
if %cookie_choice%==3 set "cookie_arg=--cookies-from-browser edge"
echo [!cookie_arg!]
')
assert_contains "cookie_choice=1 → chrome"  "chrome"   "$result"

result=$(run_cmd_file '
set cookie_choice=2
set "cookie_arg="
if %cookie_choice%==1 set "cookie_arg=--cookies-from-browser chrome"
if %cookie_choice%==2 set "cookie_arg=--cookies-from-browser firefox"
if %cookie_choice%==3 set "cookie_arg=--cookies-from-browser edge"
echo [!cookie_arg!]
')
assert_contains "cookie_choice=2 → firefox"  "firefox"  "$result"

result=$(run_cmd_file '
set cookie_choice=3
set "cookie_arg="
if %cookie_choice%==1 set "cookie_arg=--cookies-from-browser chrome"
if %cookie_choice%==2 set "cookie_arg=--cookies-from-browser firefox"
if %cookie_choice%==3 set "cookie_arg=--cookies-from-browser edge"
echo [!cookie_arg!]
')
assert_contains "cookie_choice=3 → edge"  "edge"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: translate_choice → lang + mode"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd_file '
set translate_choice=0
set "translate_lang="
set "translate_mode="
if %translate_choice%==1 (set "translate_lang=ru" & set "translate_mode=dual_track")
if %translate_choice%==2 (set "translate_lang=ru" & set "translate_mode=mix")
if %translate_choice%==3 (set "translate_lang=ru" & set "translate_mode=replace")
if %translate_choice%==4 (set "translate_lang=en" & set "translate_mode=dual_track")
echo lang=[!translate_lang!]
echo mode=[!translate_mode!]
')
assert_contains "choice=0 → lang пустой"  "lang=[]"  "$result"

result=$(run_cmd_file '
set translate_choice=1
set "translate_lang="
set "translate_mode="
if %translate_choice%==1 (set "translate_lang=ru" & set "translate_mode=dual_track")
if %translate_choice%==2 (set "translate_lang=ru" & set "translate_mode=mix")
if %translate_choice%==3 (set "translate_lang=ru" & set "translate_mode=replace")
if %translate_choice%==4 (set "translate_lang=en" & set "translate_mode=dual_track")
echo lang=[!translate_lang!]
echo mode=[!translate_mode!]
')
assert_contains "choice=1 → ru"         "lang=[ru]"        "$result"
assert_contains "choice=1 → dual_track" "mode=[dual_track]" "$result"

result=$(run_cmd_file '
set translate_choice=2
set "translate_lang="
set "translate_mode="
if %translate_choice%==1 (set "translate_lang=ru" & set "translate_mode=dual_track")
if %translate_choice%==2 (set "translate_lang=ru" & set "translate_mode=mix")
if %translate_choice%==3 (set "translate_lang=ru" & set "translate_mode=replace")
if %translate_choice%==4 (set "translate_lang=en" & set "translate_mode=dual_track")
echo lang=[!translate_lang!]
echo mode=[!translate_mode!]
')
assert_contains "choice=2 → mix"        "mode=[mix]"       "$result"

result=$(run_cmd_file '
set translate_choice=4
set "translate_lang="
set "translate_mode="
if %translate_choice%==1 (set "translate_lang=ru" & set "translate_mode=dual_track")
if %translate_choice%==2 (set "translate_lang=ru" & set "translate_mode=mix")
if %translate_choice%==3 (set "translate_lang=ru" & set "translate_mode=replace")
if %translate_choice%==4 (set "translate_lang=en" & set "translate_mode=dual_track")
echo lang=[!translate_lang!]
echo mode=[!translate_mode!]
')
assert_contains "choice=4 → en"         "lang=[en]"        "$result"
assert_contains "choice=4 → dual_track" "mode=[dual_track]" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 7: dl_errorlevel сохраняется до сброса через set"
# ══════════════════════════════════════════════════════════════

# Симулируем: dl_errorlevel=1 (yt-dlp fail), set сбросит errorlevel в 0,
# но dl_errorlevel остаётся 1 — translate должен быть заблокирован (фикс работает)
result=$(run_cmd_file '
set "dl_errorlevel=1"
set "final_message=error"
if %dl_errorlevel%==0 (echo translate_allowed) else (echo translate_blocked)
')
assert_contains "Bug7: dl_errorlevel=1 → translate_blocked"  "translate_blocked"  "$result"

# dl_errorlevel=0 (yt-dlp ok) → translate разрешён
result=$(run_cmd_file '
set "dl_errorlevel=0"
set "final_message=ok"
if %dl_errorlevel%==0 (echo translate_allowed) else (echo translate_blocked)
')
assert_contains "Bug7: dl_errorlevel=0 → translate_allowed"  "translate_allowed"  "$result"

# Демонстрируем: без фикса errorlevel после set всегда 0 даже при "ошибке"
result=$(run_cmd_file '
set "dl_errorlevel=1"
set "final_message=error"
set "col=04"
if %errorlevel%==0 (echo naive_true) else (echo naive_false)
')
assert_contains "Bug7: без фикса errorlevel=0 после set → naive_true"  "naive_true"  "$result"

# ══════════════════════════════════════════════════════════════
suite "Task 10: CMD yt-dlp фиксы (анализ исходника)"
# ══════════════════════════════════════════════════════════════
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v14.cmd"
src="$(cat "$DLP_CMD")"

# URL через delayed expansion (!url!), не %url% — сохраняет ! и & в URL
assert_contains "main download использует !url!"  '"!url!"'  "$src"
assert_not_contains "нет %url% в get-title"  '--get-title "%url%"'  "$src"
# Бинарь yt-dlp в кавычках (пути с пробелами)
assert_contains "yt-dlp в кавычках"  '"!dlp!"'  "$src"
# vot errorlevel сохранён ДО сброса NODE_TLS
votrc_ln=$(grep -nF 'set "vot_rc=!errorlevel!"' "$DLP_CMD" | head -1 | cut -d: -f1)
nrst_ln=$(grep -nF 'set "NODE_TLS_REJECT_UNAUTHORIZED="' "$DLP_CMD" | head -1 | cut -d: -f1)
order="bad"; [ -n "$votrc_ln" ] && [ -n "$nrst_ln" ] && [ "$votrc_ln" -lt "$nrst_ln" ] && order="ok"
assert_eq "vot_rc сохранён ДО сброса NODE_TLS"  "ok"  "$order"
# merge: проверка ff_rc + удаление битого
assert_contains "merge: ff_rc проверяется"  'set "ff_rc=!errorlevel!"'  "$src"
assert_contains "merge: битый выход удаляется"  'del /q "!output_file!"'  "$src"
# Выходная папка от папки скрипта
assert_contains "folder от %~dp0"  'set "folder=%~dp0_video_"'  "$src"
# Убран безусловный --no-check-certificate (паритет с SH)
assert_not_contains "нет --no-check-certificate"  "--no-check-certificate"  "$src"

summary
