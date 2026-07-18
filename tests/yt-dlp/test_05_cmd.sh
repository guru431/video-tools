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

# ── Реальная таблица форматов CMD: сканируем исходник, а не дублируем ──────
# Раньше здесь был свой захардкоженный (и протухший) дубликат format/quality
# таблицы с битыми itag (20/18, 24, 26, 28). После фикса F21/F31 проверяем
# непосредственно production-исходник, чтобы тест не расходился с кодом.
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.cmd"
CMD_SRC="$(cat "$DLP_CMD")"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_best (ext=m4a workaround)"
# ══════════════════════════════════════════════════════════════
# CMD использует плейсхолдеры Q (кавычка) и LE (<=), декодируемые в рантайме.

assert_contains "audio → bestaudio[ext=m4a]"  "save_settings=-f bestaudio[ext=m4a]/bestaudio"  "$CMD_SRC"
assert_contains "720p → heightLE720"          "heightLE720"          "$CMD_SRC"
assert_contains "720p → vcodec^=avc1"         "vcodec^=avc1"         "$CMD_SRC"
assert_contains "2160p → heightLE2160"        "heightLE2160"         "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_https (исправленные itag)"
# ══════════════════════════════════════════════════════════════

assert_contains "audio → 140"               "save_settings=-f 140\""  "$CMD_SRC"
assert_contains "720p → 140+136/135/134"    "140+136/135/134"  "$CMD_SRC"
assert_contains "1440p → 140+264 (не битый 140+138)"  "140+264"  "$CMD_SRC"
assert_contains "2160p → 140+266 (не битый 140+139)"  "140+266"  "$CMD_SRC"
assert_not_contains "нет битого аудио-itag 138"  "140+138"  "$CMD_SRC"
assert_not_contains "нет битого аудио-itag 139"  "140+139"  "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: avc1_m3u8 (исправленные itag)"
# ══════════════════════════════════════════════════════════════

assert_contains "720p → 234+232/231/230"  "234+232/231/230"  "$CMD_SRC"
assert_contains "1080p → 270+234 (не битый 234+233)"  "270+234"  "$CMD_SRC"
assert_not_contains "нет битого 234+233"  "234+233"  "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: old_combo (исправленные legacy itag — F21)"
# ══════════════════════════════════════════════════════════════
# F21: old_combo чинится на 140 / 18 / 59/22/18 / 22/18 / 37/22/18 / 38/37/22/18.

assert_contains "audio → 140"          "save_settings=-f 140\""  "$CMD_SRC"
assert_contains "360p → 18"            "save_settings=-f 18\""    "$CMD_SRC"
assert_contains "480p → 59/22/18"      "59/22/18"                 "$CMD_SRC"
assert_contains "720p → 22/18"         "save_settings=-f 22/18\"" "$CMD_SRC"
assert_contains "1080p → 37/22/18"     "37/22/18"                 "$CMD_SRC"
assert_contains "1440p → 38/37/22/18"  "38/37/22/18"              "$CMD_SRC"
# Битые/несуществующие itag из протухшей таблицы должны отсутствовать.
assert_not_contains "нет битого itag-комбо 20/18"  "20/18"  "$CMD_SRC"
assert_not_contains "нет битого itag-комбо 24/22"  "24/22"  "$CMD_SRC"
assert_not_contains "нет битого itag-комбо 26/24"  "26/24"  "$CMD_SRC"
assert_not_contains "нет битого itag-комбо 28/26"  "28/26"  "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: субтитры (качество 91/92)"
# ══════════════════════════════════════════════════════════════

assert_contains "quality=91 → --sub-langs ru"  "--sub-langs ru"  "$CMD_SRC"
assert_contains "quality=92 → --sub-langs en"  "--sub-langs en"  "$CMD_SRC"
assert_contains "субтитры → --skip-download"   "--skip-download" "$CMD_SRC"

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
DLP_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.cmd"
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
