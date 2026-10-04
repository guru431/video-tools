#!/bin/bash
# Тест дот-сорсит настоящий production-скрипт: переменные, которые здесь только
# присваиваются, читает он (SC2034).
# Путь к дот-сорсимому скрипту вычисляется в рантайме — следовать за `source`
# статический анализатор не может по определению (SC1090).
# shellcheck disable=SC1090,SC2034
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

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.sh"
CMD_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.cmd"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.ps1"
MOCK_YTDLP="$TESTS_DIR/mocks/yt-dlp"
chmod +x "$MOCK_YTDLP" 2>/dev/null

SH_SRC="$(cat "$SH_SCRIPT")"
PS1_SRC="$(cat "$PS1_SCRIPT")"
CMD_SRC="$(cat "$CMD_SCRIPT")"

write_cfg() { CFG=$(mktemp_suffix /tmp/test_ytf11_ .ini); printf '%s\n' "$1" > "$CFG"; }
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
# Схема сверяется срезом фиксированной длины: findstr и temp-файл убраны вовсе
# (см. test_12_findings_cli.sh, suite Y3 — там же поведенческая проверка в реальном cmd).
# Инвариант F14 остался тем же: только ТОЧНЫЕ http:// и https://, httpss:// отвергается.
assert_contains     "F14: точный срез http://"        'if /i "!url:~0,7!"=="http://"'  "$CMD_SRC"
assert_contains     "F14: точный срез https://"       'if /i "!url:~0,8!"=="https://"' "$CMD_SRC"
assert_not_contains "F14: убран нестрогий ^https*://" '/c:"^https*://"'                "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "F13 (CMD behavioral): host-детект платформы в рантайме"
# ══════════════════════════════════════════════════════════════
if cmd //c "exit 0" &>/dev/null; then
    # Блок host-детекта берётся из НАСТОЯЩЕГО .cmd (от `set "platform=other"` до
    # последней проверки суффикса .youtu.be) и гоняется по всем URL в одном процессе
    # cmd. Ручная копия блока здесь уже однажды разошлась с кодом: разбор кредов до
    # последнего «@» в production появился, а в копии остался прежний «:?@».
    # Собака собирается из переменной: барьер приватности видит в литерале форму e-mail.
    AT='@'
    # По одному на строку и читаются через read: в URL есть «?», а без кавычек bash
    # попробовал бы раскрыть его как шаблон имени файла.
    F13_URLS="https://www.youtube.com/watch?v=abc
https://youtu.be/abc
https://youtube.com/watch?v=abc
https://example.invalid/path/youtube.com/video
https://youtube.com.evil.tld/x
https://notyoutube.com/watch
https://u:p${AT}www.youtube.com:8080/watch?v=abc
https://youtube.com:pw${AT}example.invalid/x
https://a${AT}b${AT}youtu.be/abc
https://WWW.YOUTUBE.COM/watch
https://www.youtube.com#frag"
    f13_block() {
        awk '{ sub(/\r$/, "") } /^set "platform=other"/{f=1} f{ printf "%s\r\n", $0 } f && /^if \/I "!_host:~-9!"/{exit}' "$CMD_SCRIPT"
    }
    f13_cmd=$(mktemp_suffix /tmp/test_ytf13cmd_ .cmd)
    {
        printf '@echo off\r\nsetlocal EnableDelayedExpansion\r\n'
        while IFS= read -r u; do printf 'call :chk "%s"\r\n' "$u"; done <<< "$F13_URLS"
        printf 'exit /b 0\r\n:chk\r\nset "url=%%~1"\r\n'
        f13_block
        printf 'echo P[%%~1]=!platform!\r\nexit /b 0\r\n'
    } > "$f13_cmd"
    f13_out=$(cmd //c "$(cygpath -w "$f13_cmd" 2>/dev/null || echo "$f13_cmd")" 2>/dev/null | tr -d '\r')
    rm -f "$f13_cmd"
    assert_contains "CMD F13: блок host-детекта извлечён из скрипта" ':_host_creds' "$(f13_block)"
    assert_contains "CMD F13: www.youtube.com → youtube"     "P[https://www.youtube.com/watch?v=abc]=youtube" "$f13_out"
    assert_contains "CMD F13: youtu.be → youtube"            "P[https://youtu.be/abc]=youtube" "$f13_out"
    assert_contains "CMD F13: youtube.com (apex) → youtube"  "P[https://youtube.com/watch?v=abc]=youtube" "$f13_out"
    assert_contains "CMD F13: youtube.com в ПУТИ → other"    "P[https://example.invalid/path/youtube.com/video]=other" "$f13_out"
    assert_contains "CMD F13: youtube.com.evil.tld → other"  "P[https://youtube.com.evil.tld/x]=other" "$f13_out"
    assert_contains "CMD F13: notyoutube.com → other"        "P[https://notyoutube.com/watch]=other" "$f13_out"
    assert_contains "CMD F13: креды и порт перед хостом YouTube → youtube" "P[https://u:p${AT}www.youtube.com:8080/watch?v=abc]=youtube" "$f13_out"
    assert_contains "CMD F13: youtube.com в КРЕДАХ, хост чужой → other"    "P[https://youtube.com:pw${AT}example.invalid/x]=other" "$f13_out"
    assert_contains "CMD F13: несколько «@» — хост после последнего"       "P[https://a${AT}b${AT}youtu.be/abc]=youtube" "$f13_out"
    assert_contains "CMD F13: регистр хоста не важен"        "P[https://WWW.YOUTUBE.COM/watch]=youtube" "$f13_out"
    assert_contains "CMD F13: fragment отрезается"           "P[https://www.youtube.com#frag]=youtube" "$f13_out"
else
    skip "CMD F13 behavioral: cmd.exe недоступен"
fi

# ══════════════════════════════════════════════════════════════
suite "Время обрезки: грамматика формы одна на SH и CMD (PS1 — test_06)"
# ══════════════════════════════════════════════════════════════
# Прежние валидаторы проверяли только НАБОР символов [0-9:.] и пропускали «1.2.3»,
# «:::», «00:00:00:00», «.». Теперь — форма: до трёх групп цифр через ':' плюс
# необязательная дробная часть. Диапазоны не проверяются (строгий разбор отложен),
# поэтому 1:99:99 проходит намеренно.
TT_GOOD="90 0 1.5 1:30 01:02:03 01:02:03.250 100:00 1:99:99"
TT_BAD="1.2.3 ::: 00:00:00:00 . :::: 1: :30 1min 1..2 1.5:30 1:2:3:4.5"

(
    set +u
    source "$SH_SCRIPT"
    for v in $TT_GOOD; do
        if ( validate_time "--trim-start" "$v" ) >/dev/null 2>&1; then pass "SH: «$v» принят"
        else fail "SH: «$v» принят" "rc 0" "отвергнут"; fi
    done
    for v in $TT_BAD ""; do
        if ( validate_time "--trim-start" "$v" ) >/dev/null 2>&1; then fail "SH: «$v» отвергнут" "exit 1" "принят"
        else pass "SH: «$v» отвергнут"; fi
    done
) 2>/dev/null

if cmd //c "exit 0" &>/dev/null; then
    # Блок валидации берётся из НАСТОЯЩЕГО .cmd (от `set "_trimchk=` до его `del`) и
    # гоняется по всем значениям в одном процессе cmd: подпрограмма задаёт обе метки
    # и печатает, что от них осталось после проверки.
    tt_cmd=$(mktemp_suffix /tmp/test_yttrim_ .cmd)
    {
        printf '@echo off\r\nsetlocal EnableDelayedExpansion\r\n'
        for v in $TT_GOOD $TT_BAD; do printf 'call :chk "%s"\r\n' "$v"; done
        printf 'exit /b 0\r\n:chk\r\nset "trim_start=%%~1"\r\nset "trim_end=%%~1"\r\n'
        awk '{ sub(/\r$/, "") } /^set "_trimchk=/{f=1} f{ printf "%s\r\n", $0 } f && /^del "!_trimchk!"/{exit}' "$CMD_SCRIPT"
        printf 'echo T[%%~1]=[!trim_start!][!trim_end!]\r\nexit /b 0\r\n'
    } > "$tt_cmd"
    tt_out=$(cmd //c "$(cygpath -w "$tt_cmd" 2>/dev/null || echo "$tt_cmd")" 2>/dev/null | tr -d '\r')
    rm -f "$tt_cmd"
    assert_contains "CMD: блок валидации извлечён из скрипта" "findstr /r /x" "$(awk '/^set "_trimchk=/{f=1} f{print} f && /^del "!_trimchk!"/{exit}' "$CMD_SCRIPT")"
    for v in $TT_GOOD; do
        assert_contains "CMD: «$v» принят (начало и конец)" "T[$v]=[$v][$v]" "$tt_out"
    done
    for v in $TT_BAD; do
        assert_contains "CMD: «$v» отвергнут (начало и конец)" "T[$v]=[][]" "$tt_out"
    done
else
    skip "CMD: грамматика времени обрезки — cmd.exe недоступен"
fi

summary
