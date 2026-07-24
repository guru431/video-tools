#!/bin/bash
# ============================================================
# test_11_findings_f4_f15.sh — Фиксы аудита F4/F6/F8/F9/F11/F13/F14/F15 (yt-dlp):
#   F4  — финальный rename перевода проверяется (mv/move/Move-Item), не выдаётся
#         за успех вслепую (SH/PS1/CMD);
#   F6  — --dry-run с --translate печатает план и НЕ падает ошибкой (SH);
#   F8  — PS1 GUI сохраняет exit code vot-cli-live до Dispose и не считает
#         частичный/прерванный результат успехом;
#   F9  — dual_track требует рабочий ffprobe (иначе индекс дорожки не определить);
#   F11 — CMD-манифест перевода уникален по GUID, а не %random%;
#   F13 — платформа определяется по ХОСТУ, а не по подстроке всего URL (PS1/CMD);
#   F14 — CMD принимает только точные схемы http:// и https:// (не httpsss://);
#   F15 — SH читает секции/ключи config.ini регистронезависимо (паритет с PS1).
# SH — behavioral (mock yt-dlp/ffmpeg/ffprobe/vot); PS1/CMD — source-scan (паритет с test_08).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.sh"
CMD_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.cmd"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.ps1"
MOCK_YTDLP="$TESTS_DIR/mocks/yt-dlp"
chmod +x "$MOCK_YTDLP" 2>/dev/null

SH_SRC="$(cat "$SH_SCRIPT")"
PS1_SRC="$(cat "$PS1_SCRIPT")"
CMD_SRC="$(cat "$CMD_SCRIPT")"

write_cfg() { CFG=$(mktemp /tmp/test_ytf11_XXXXXX.ini); printf '%s\n' "$1" > "$CFG"; }
dry_line() { printf '%s\n' "$1" | grep '\[DRY-RUN\]'; }

# ══════════════════════════════════════════════════════════════
suite "F15 (SH): секции/ключи config.ini читаются регистронезависимо"
# ══════════════════════════════════════════════════════════════
# [DOWNLOAD]/Default_Quality раньше работали в GUI (PowerShell hashtable
# регистронезависим), но в SH молча давали default. Теперь — паритет.
write_cfg "[DOWNLOAD]
Default_Quality = 1080
Use_Archive = false
Format_Preset = avc1_best"
OUT=$(YTDLP_BIN="$MOCK_YTDLP" bash "$SH_SCRIPT" --config "$CFG" --dry-run "https://youtube.com/watch?v=abc" 2>&1)
DRY=$(dry_line "$OUT")
assert_contains "F15: [DOWNLOAD]/Default_Quality (1080) прочитан из mixed-case" "height<=1080" "$DRY"
rm -f "$CFG"
# Регрессия: lowercase по-прежнему работает.
write_cfg "[download]
default_quality = 360
use_archive = false
format_preset = avc1_best"
OUT=$(YTDLP_BIN="$MOCK_YTDLP" bash "$SH_SCRIPT" --config "$CFG" --dry-run "https://youtube.com/watch?v=abc" 2>&1)
assert_contains "F15: lowercase-конфиг не сломан (360)" "height<=360" "$(dry_line "$OUT")"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "F6 (SH): --dry-run с --translate печатает план, а не падает ошибкой"
# ══════════════════════════════════════════════════════════════
W6=$(mktemp -d /tmp/test_ytf6_XXXXXX)
mkdir -p "$W6/bin"
for b in ffmpeg ffprobe vot-cli-live; do
    printf '#!/bin/bash\nexit 0\n' > "$W6/bin/$b"; chmod +x "$W6/bin/$b"
done
write_cfg "[download]
use_archive = false
default_quality = 720
[translation]
enabled = true
target_lang = ru"
OUT=$(
    export PATH="$W6/bin:$PATH"
    YTDLP_BIN="$MOCK_YTDLP" FFMPEG_BIN="$W6/bin/ffmpeg" FFPROBE_BIN="$W6/bin/ffprobe" VOT_BIN="$W6/bin/vot-cli-live" \
        bash "$SH_SCRIPT" --config "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc" 2>&1
); RC6=$?
assert_contains     "F6: печатается план перевода"            "[DRY-RUN] AI-перевод" "$OUT"
assert_not_contains "F6: НЕ трактуется как «переводить нечего»" "переводить нечего"    "$OUT"
assert_eq           "F6: dry-run+translate → exit 0"          "0"                    "$RC6"
rm -f "$CFG"; rm -rf "$W6"

# ══════════════════════════════════════════════════════════════
suite "F9 (SH): dual_track требует ffprobe; mix/replace — нет"
# ══════════════════════════════════════════════════════════════
W9=$(mktemp -d /tmp/test_ytf9_XXXXXX)
mkdir -p "$W9/bin" "$W9/vid"
cat > "$W9/bin/vot" <<'VOTEOF'
#!/bin/bash
od=""
for a in "$@"; do case "$a" in --output=*) od="${a#--output=}";; esac; done
[ -n "$od" ] && touch "$od/translation.mp3"
exit 0
VOTEOF
cat > "$W9/bin/ffmpeg" <<'FFEOF'
#!/bin/bash
for last in "$@"; do :; done
touch "$last" 2>/dev/null
exit 0
FFEOF
chmod +x "$W9/bin/vot" "$W9/bin/ffmpeg"
# ffprobe заведомо отсутствует (bogus-путь).
run_tr_f9() {
    local mode="$1"
    : > "$W9/vid/clip.mp4"
    (
        set +u
        source "$SH_SCRIPT"
        export PATH="$W9/bin:$PATH"
        VOT_BIN="$W9/bin/vot"
        FFPROBE="$W9/bin/ffprobe_missing_$$"   # не существует
        translate_audio "$W9/vid/clip.mp4" "http://u" ru live "$mode" en 0.3 1.0 "" 2>&1
    )
}
OUT=$(run_tr_f9 dual_track); RC=$?
assert_contains "F9: dual_track без ffprobe → явная ошибка" "требует ffprobe" "$OUT"
assert_eq       "F9: dual_track без ffprobe → rc=1"         "1"               "$RC"
OUT=$(run_tr_f9 mix); RC=$?
assert_contains "F9: mix без ffprobe работает (fallback=1)" "Перевод добавлен" "$OUT"
assert_eq       "F9: mix без ffprobe → rc=0"                "0"                "$RC"
rm -rf "$W9"

# ══════════════════════════════════════════════════════════════
suite "F4 (SH): rename перевода проверяется, а не выдаётся за успех"
# ══════════════════════════════════════════════════════════════
# Behavioral: подсовываем в PATH `mv`, который всегда падает (exit 1) — эмуляция
# заблокированного файла/нет прав. Функция обязана вернуть ошибку, а не «Перевод добавлен».
W4=$(mktemp -d /tmp/test_ytf4_XXXXXX)
mkdir -p "$W4/bin" "$W4/vid"
cat > "$W4/bin/vot" <<'VOTEOF'
#!/bin/bash
od=""
for a in "$@"; do case "$a" in --output=*) od="${a#--output=}";; esac; done
[ -n "$od" ] && touch "$od/translation.mp3"
exit 0
VOTEOF
cat > "$W4/bin/ffmpeg" <<'FFEOF'
#!/bin/bash
for last in "$@"; do :; done
touch "$last" 2>/dev/null
exit 0
FFEOF
cat > "$W4/bin/ffprobe" <<'FPEOF'
#!/bin/bash
echo "1"
exit 0
FPEOF
# mv, который всегда падает — эмуляция неудачного финального rename.
printf '#!/bin/bash\nexit 1\n' > "$W4/bin/mv"
chmod +x "$W4/bin/vot" "$W4/bin/ffmpeg" "$W4/bin/ffprobe" "$W4/bin/mv"
: > "$W4/vid/clip.mp4"
OUT=$(
    set +u
    source "$SH_SCRIPT"
    export PATH="$W4/bin:$PATH"
    VOT_BIN="$W4/bin/vot"; FFPROBE="$W4/bin/ffprobe"
    translate_audio "$W4/vid/clip.mp4" "http://u" ru live replace en 0.3 1.0 "" 2>&1
); RC=$?
assert_not_contains "F4: отказ rename НЕ рапортует «Перевод добавлен»" "Перевод добавлен" "$OUT"
assert_contains     "F4: отказ rename даёт явную ошибку"               "Не удалось заменить оригинал" "$OUT"
assert_eq           "F4: отказ rename → rc=1"                          "1" "$RC"
rm -rf "$W4"
# Source-scan: mv/Move-Item/move проверяются на всех платформах.
assert_contains "F4 (SH): mv в условии (проверка exit code)"  "if mv \"\$output_file\" \"\$video_file\"" "$SH_SRC"
assert_contains "F4 (PS1): Move-Item -ErrorAction Stop"       'Move-Item -LiteralPath $outputFile -Destination $latestVideo.FullName -Force -ErrorAction Stop' "$PS1_SRC"
assert_contains "F4 (CMD): errorlevel move проверяется"       'set "mv_rc=!errorlevel!"' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F8 (PS1 source-scan): exit code vot сохранён до Dispose"
# ══════════════════════════════════════════════════════════════
assert_contains     "F8: exit code читается до Dispose"       '$votExit = $votProc.ExitCode' "$PS1_SRC"
assert_contains     "F8: флаг прерывания (Stop/таймаут)"      '$_votAborted = $true'          "$PS1_SRC"
assert_contains     "F8: успех только при чистом выходе"      'if (-not $_votAborted -and $votExit -eq 0)' "$PS1_SRC"
assert_contains     "F8: требуется непустой файл"             '$_.Length -gt 0'               "$PS1_SRC"

# ══════════════════════════════════════════════════════════════
suite "F9 (PS1/CMD source-scan): dual_track требует ffprobe"
# ══════════════════════════════════════════════════════════════
assert_contains "F9 (PS1): ветка dual_track проверяет ffprobe" "Режим «2 дорожки» требует ffprobe" "$PS1_SRC"
assert_contains "F9 (CMD): ветка dual_track проверяет ffprobe" "режим dual_track требует ffprobe"  "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F11 (CMD source-scan): манифест перевода уникален по GUID"
# ══════════════════════════════════════════════════════════════
assert_contains     "F11: манифест через GUID (powershell NewGuid)"  'ytdlp_manifest_%%g.txt' "$CMD_SRC"
assert_not_contains "F11: манифест НЕ через голый %random%"          'ytdlp_manifest_%random%.txt' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F13 (CMD source-scan): платформа по хосту, а не по всему URL"
# ══════════════════════════════════════════════════════════════
assert_contains "F13 (CMD): host извлекается (2-й /-токен)" 'for /f "tokens=2 delims=/" %%h in ("!url!")' "$CMD_SRC"
assert_contains "F13 (CMD): apex-совпадение youtube.com"   'if /I "!_host!"=="youtube.com"' "$CMD_SRC"
assert_contains "F13 (CMD): суффикс-якорь .youtube.com"    'if /I "!_host:~-12!"==".youtube.com"' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F14 (CMD source-scan): только точные схемы http/https"
# ══════════════════════════════════════════════════════════════
assert_contains     "F14: точные /c:^http:// и /c:^https://" '/c:"^http://" /c:"^https://"' "$CMD_SRC"
assert_not_contains "F14: убран нестрогий ^https*://"        '/c:"^https*://"'               "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F13 (CMD behavioral): host-детект платформы в рантайме"
# ══════════════════════════════════════════════════════════════
if cmd //c "exit 0" &>/dev/null; then
    run_cmd_file() {
        local body="$1" tmp_cmd win_path result
        tmp_cmd=$(mktemp /tmp/test_ytf13cmd_XXXXXX.cmd)
        printf '@echo off\r\nchcp 65001 >nul 2>&1\r\nsetlocal enabledelayedexpansion\r\n%s\r\n' "$body" > "$tmp_cmd"
        win_path=$(cygpath -w "$tmp_cmd" 2>/dev/null || echo "$tmp_cmd")
        result=$(cmd //c "$win_path" 2>/dev/null)
        rm -f "$tmp_cmd"
        echo "$result"
    }
    # Ровно тот же блок host-детекта, что в продакшне (см. Downloading_from_YouTube_v16.cmd).
    detect_platform_cmd() {
        run_cmd_file "set \"url=$1\"
set \"platform=other\"
set \"_host=\"
for /f \"tokens=2 delims=/\" %%h in (\"!url!\") do set \"_host=%%h\"
for /f \"tokens=1 delims=:?@ \" %%h in (\"!_host!\") do set \"_host=%%h\"
if /I \"!_host!\"==\"youtube.com\"       set \"platform=youtube\"
if /I \"!_host!\"==\"youtu.be\"          set \"platform=youtube\"
if /I \"!_host:~-12!\"==\".youtube.com\" set \"platform=youtube\"
if /I \"!_host:~-9!\"==\".youtu.be\"     set \"platform=youtube\"
echo PLATFORM=!platform!" | tr -d '\r'
    }
    assert_contains "CMD F13: www.youtube.com → youtube"  "PLATFORM=youtube" "$(detect_platform_cmd 'https://www.youtube.com/watch?v=abc')"
    assert_contains "CMD F13: youtu.be → youtube"         "PLATFORM=youtube" "$(detect_platform_cmd 'https://youtu.be/abc')"
    assert_contains "CMD F13: youtube.com (apex) → youtube" "PLATFORM=youtube" "$(detect_platform_cmd 'https://youtube.com/watch?v=abc')"
    assert_contains "CMD F13: youtube.com в ПУТИ → other"  "PLATFORM=other"   "$(detect_platform_cmd 'https://example.invalid/path/youtube.com/video')"
    assert_contains "CMD F13: youtube.com.evil.tld → other" "PLATFORM=other"  "$(detect_platform_cmd 'https://youtube.com.evil.tld/x')"
    assert_contains "CMD F13: notyoutube.com → other"     "PLATFORM=other"   "$(detect_platform_cmd 'https://notyoutube.com/watch')"
else
    skip "CMD F13 behavioral: cmd.exe недоступен"
fi

summary
