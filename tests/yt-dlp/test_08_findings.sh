#!/bin/bash
# ============================================================
# test_08_findings.sh — Фиксы аудита F1/F2/F3/F4 (yt-dlp):
#   F3 — архив (--download-archive) не добавляется для «только субтитры» (--subs);
#   F1/F2 — AI-перевод отключается с ЯВНЫМ сообщением при audio/плейлисте/trim/
#           SponsorBlock remove (vot переводит по URL → иначе молчит или рассинхрон);
#   F4 — мерж перевода сохраняет субтитры/вложения (-map 0:s? -map 0:t? -c:s copy).
# SH — реальный --dry-run (mock yt-dlp) + прямой вызов translate_audio (mock ffmpeg/vot);
# CMD/PS1 — source-scan production-исходника (паритет с test_07).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
CMD_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
MOCK_YTDLP="$TESTS_DIR/mocks/yt-dlp"
chmod +x "$MOCK_YTDLP" 2>/dev/null

write_cfg() { CFG=$(mktemp /tmp/test_ytf8_XXXXXX.ini); printf '%s\n' "$1" > "$CFG"; }
# Полный вывод SH (не только строки [DRY-RUN]) — нужен, чтобы поймать [WARN]-guardrail'ы.
run_full() { local cfg="$1"; shift; YTDLP_BIN="$MOCK_YTDLP" bash "$SH_SCRIPT" --config "$cfg" "$@" 2>&1; }
dry_line() { printf '%s\n' "$1" | grep '\[DRY-RUN\]'; }

# ══════════════════════════════════════════════════════════════
suite "F3 (SH): архив не добавляется для «только субтитры»"
# ══════════════════════════════════════════════════════════════
write_cfg "[download]
use_archive = true
[subtitles]
lang = ru"

OUT=$(run_full "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc")
assert_contains     "видео: --download-archive присутствует" "--download-archive" "$(dry_line "$OUT")"
OUT=$(run_full "$CFG" --dry-run --subs "https://youtube.com/watch?v=abc")
assert_contains     "субтитры: --skip-download"              "--skip-download"    "$(dry_line "$OUT")"
assert_not_contains "субтитры: НЕТ --download-archive (F3)"  "--download-archive" "$(dry_line "$OUT")"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "F1/F2 (SH): AI-перевод отключается с явным сообщением"
# ══════════════════════════════════════════════════════════════
BASE_CFG="[download]
use_archive = false
default_quality = 720
[translation]
enabled = true
target_lang = ru"

# audio → блок
write_cfg "$BASE_CFG"
OUT=$(run_full "$CFG" --dry-run --quality audio "https://youtube.com/watch?v=abc")
assert_contains "audio: сообщение об отключении перевода" "перевод не поддерживается для загрузки только аудио" "$OUT"
assert_not_contains "audio: перевод отключён → нет манифеста (F13)" "after_move:filepath" "$(dry_line "$OUT")"

# playlist → блок
OUT=$(run_full "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc&list=PL123")
assert_contains "playlist: сообщение об отключении перевода" "недоступен для плейлистов" "$OUT"

# trim → блок
OUT=$(run_full "$CFG" --dry-run --quality 720 --trim-start 00:00:10 "https://youtube.com/watch?v=abc")
assert_contains "trim: сообщение об отключении перевода" "несовместим с обрезкой" "$OUT"
assert_not_contains "trim: перевод отключён → нет манифеста (F13)" "after_move:filepath" "$(dry_line "$OUT")"
rm -f "$CFG"

# sponsorblock remove → блок
write_cfg "[download]
use_archive = false
default_quality = 720
sponsorblock = remove
[translation]
enabled = true
target_lang = ru"
OUT=$(run_full "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc")
assert_contains "sponsorblock: сообщение об отключении перевода" "SponsorBlock remove" "$OUT"
assert_contains "sponsorblock: сам SponsorBlock всё равно применён" "--sponsorblock-remove all" "$(dry_line "$OUT")"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "F4 (SH): мерж перевода сохраняет субтитры/вложения"
# ══════════════════════════════════════════════════════════════
WORK=$(mktemp -d /tmp/test_ytf8_tr_XXXXXX)
FF_LOG="$WORK/ff.log"
mkdir -p "$WORK/bin" "$WORK/vid"
# mock vot — кладёт mp3 в --output=DIR
cat > "$WORK/bin/vot" <<'VOTEOF'
#!/bin/bash
od=""
for a in "$@"; do case "$a" in --output=*) od="${a#--output=}";; esac; done
[ -n "$od" ] && touch "$od/translation.mp3"
exit 0
VOTEOF
chmod +x "$WORK/bin/vot"
# mock ffmpeg — логирует argv и создаёт выходной файл (последний аргумент)
cat > "$WORK/bin/ffmpeg" <<FFEOF
#!/bin/bash
echo "\$@" >> "$FF_LOG"
for last in "\$@"; do :; done
touch "\$last" 2>/dev/null
exit 0
FFEOF
chmod +x "$WORK/bin/ffmpeg"

run_translate() {
    local mode="$1"
    rm -f "$FF_LOG"
    : > "$WORK/vid/clip.mp4"
    (
        set +u
        source "$SH_SCRIPT"       # main() под guard BASH_SOURCE — не запустится
        export PATH="$WORK/bin:$PATH"
        VOT_BIN="$WORK/bin/vot"
        translate_audio "$WORK/vid/clip.mp4" "http://u" ru live "$mode" en 0.3 1.0 "" >/dev/null 2>&1
    )
}

for m in dual_track replace mix; do
    run_translate "$m"
    if grep -qF -- "-map 0:s?" "$FF_LOG" 2>/dev/null; then pass "$m: -map 0:s? (субтитры сохранены)"; else fail "$m: -map 0:s?" "есть" "нет в argv ffmpeg"; fi
    if grep -qF -- "-c:s copy" "$FF_LOG" 2>/dev/null; then pass "$m: -c:s copy"; else fail "$m: -c:s copy" "есть" "нет"; fi
    if grep -qF -- "-map 0:t?" "$FF_LOG" 2>/dev/null; then pass "$m: -map 0:t? (вложения)"; else fail "$m: -map 0:t?" "есть" "нет"; fi
done
rm -rf "$WORK"

# ══════════════════════════════════════════════════════════════
suite "F13 (SH): перевод берёт путь из манифеста yt-dlp, а не самый свежий файл"
# ══════════════════════════════════════════════════════════════
# Суть P1: рядом лежит более свежий файл чужого процесса. Поиск по mtime выбрал бы
# именно его и подменил бы чужой результат переведённым аудио.
W2=$(mktemp -d /tmp/test_ytf13_XXXXXX)
mkdir -p "$W2/bin" "$W2/dl"
FF2_LOG="$W2/ff.log"
cat > "$W2/bin/vot-cli-live" <<'VOTEOF'
#!/bin/bash
od=""
for a in "$@"; do case "$a" in --output=*) od="${a#--output=}";; esac; done
[ -n "$od" ] && touch "$od/translation.mp3"
exit 0
VOTEOF
cat > "$W2/bin/ffmpeg" <<FFEOF
#!/bin/bash
echo "\$@" >> "$FF2_LOG"
for last in "\$@"; do :; done
touch "\$last" 2>/dev/null
exit 0
FFEOF
cat > "$W2/bin/ffprobe" <<'FPEOF'
#!/bin/bash
echo "120"
exit 0
FPEOF
chmod +x "$W2/bin/vot-cli-live" "$W2/bin/ffmpeg" "$W2/bin/ffprobe"

write_cfg "[output]
base_dir = $W2/dl
[download]
use_archive = false
default_quality = 720
[translation]
enabled = true
target_lang = ru"

# Чужой файл заведомо новее того, что «скачает» мок.
: > "$W2/dl/foreign.mp4"
touch -d '+1 hour' "$W2/dl/foreign.mp4" 2>/dev/null || touch "$W2/dl/foreign.mp4"

rm -f "$FF2_LOG"
OUT=$(
    export PATH="$W2/bin:$PATH"
    export MOCK_YTDLP_OUTFILE="$W2/dl/mine.mp4"
    export MOCK_YTDLP_LOG="$W2/ytdlp.log"
    YTDLP_BIN="$MOCK_YTDLP" VOT_BIN="$W2/bin/vot-cli-live" \
        bash "$SH_SCRIPT" --config "$CFG" --quality 720 "https://youtube.com/watch?v=abc" 2>&1
)
assert_contains "manifest: yt-dlp получил --print-to-file after_move:filepath" "after_move:filepath" "$(cat "$W2/ytdlp.log" 2>/dev/null)"
if grep -qF -- "mine.mp4" "$FF2_LOG" 2>/dev/null; then pass "manifest: переведён именно свой файл"; else fail "manifest: переведён именно свой файл" "mine.mp4 в argv ffmpeg" "нет"; fi
if grep -qF -- "foreign.mp4" "$FF2_LOG" 2>/dev/null; then fail "manifest: чужой свежий файл НЕ тронут" "нет foreign.mp4" "попал в argv ffmpeg"; else pass "manifest: чужой свежий файл НЕ тронут"; fi
if [ -s "$W2/dl/foreign.mp4" ]; then fail "manifest: чужой файл не перезаписан" "пустой (нетронутый)" "изменён"; else pass "manifest: чужой файл не перезаписан"; fi

# F14: запрошенный перевод без единого медиафайла — это провал, а не тихий успех.
rm -f "$FF2_LOG"
OUT=$(
    export PATH="$W2/bin:$PATH"
    export MOCK_YTDLP_OUTFILE=""
    YTDLP_BIN="$MOCK_YTDLP" VOT_BIN="$W2/bin/vot-cli-live" \
        bash "$SH_SCRIPT" --config "$CFG" --quality 720 "https://youtube.com/watch?v=abc" 2>&1
)
RC14=$?
assert_contains "F14: пустой манифест → явная ошибка" "не сообщил ни одного медиафайла" "$OUT"
rm -f "$CFG"; rm -rf "$W2"

# ══════════════════════════════════════════════════════════════
suite "F18 (SH): value-опции требуют значение и валидируют его"
# ══════════════════════════════════════════════════════════════
# Суть: `--quality --dry-run URL` съедал safety-флаг как значение и начинал
# РЕАЛЬНУЮ загрузку; `--quality` последним аргументом ронял скрипт set -u.
write_cfg "[download]
use_archive = false"

OUT=$(run_full "$CFG" --quality --dry-run "https://youtube.com/watch?v=abc"); RC=$?
assert_contains     "--quality --dry-run: явная ошибка"        "требует значения" "$OUT"
assert_not_contains "--quality --dry-run: НЕ ушёл в загрузку"  "[DRY-RUN]"        "$OUT"
assert_eq           "--quality --dry-run: exit 1" "1" "$RC"

OUT=$(run_full "$CFG" --dry-run "https://youtube.com/watch?v=abc" --quality); RC=$?
assert_contains "--quality в конце argv: явная ошибка, не set -u" "требует значения" "$OUT"
assert_eq       "--quality в конце argv: exit 1" "1" "$RC"

OUT=$(run_full "$CFG" --dry-run --quality 999 "https://youtube.com/watch?v=abc"); RC=$?
assert_contains "--quality 999: отвергнут enum'ом" "Недопустимое значение" "$OUT"
assert_eq       "--quality 999: exit 1" "1" "$RC"

OUT=$(run_full "$CFG" --dry-run --format bogus_preset "https://youtube.com/watch?v=abc"); RC=$?
assert_contains "--format bogus: отвергнут enum'ом" "Недопустимое значение" "$OUT"

OUT=$(run_full "$CFG" --dry-run --trim-start "abc" "https://youtube.com/watch?v=abc"); RC=$?
assert_contains "--trim-start abc: отвергнут валидатором времени" "ожидается ЧЧ:ММ:СС" "$OUT"

# Валидные значения по-прежнему проходят.
OUT=$(run_full "$CFG" --dry-run --quality 1080 --format avc1_best "https://youtube.com/watch?v=abc")
assert_contains "валидные --quality/--format проходят" "[DRY-RUN]" "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "F19 (SH): Windows-пути (drive/UNC) считаются абсолютными"
# ══════════════════════════════════════════════════════════════
# Суть: `C:/Downloads` признавался относительным → $SCRIPT_DIR/C:/Downloads.
(
    set +u
    source "$SH_SCRIPT"
    for p in "/posix/abs" "C:/Downloads" "D:\\cookies.txt" "\\\\srv\\share\\x" "//srv/share/x"; do
        if is_abs_path "$p"; then pass "абсолютный: $p"; else fail "абсолютный: $p" "abs" "relative"; fi
    done
    for p in "cookies.txt" "sub/dir/x" "./x"; do
        if is_abs_path "$p"; then fail "относительный: $p" "relative" "abs"; else pass "относительный: $p"; fi
    done
) 2>/dev/null

write_cfg "[output]
base_dir = C:/Downloads
[download]
use_archive = false"
OUT=$(dry_line "$(run_full "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc")")
assert_contains     "base_dir=C:/Downloads используется как есть" "C:/Downloads/" "$OUT"
assert_not_contains "base_dir=C:/Downloads не склеен со SCRIPT_DIR" "yt-dlp/C:/Downloads" "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "F20 (SH): регистр хоста не меняет platform detection"
# ══════════════════════════════════════════════════════════════
(
    set +u
    source "$SH_SCRIPT"
    assert_eq "HTTPS://YOUTUBE.COM → youtube"      "youtube" "$(detect_platform 'HTTPS://YOUTUBE.COM/watch?v=a')"
    assert_eq "https://YouTu.Be → youtube"         "youtube" "$(detect_platform 'https://YouTu.Be/abc')"
    assert_eq "HTTPS://WWW.VK.COM → vk"            "vk"      "$(detect_platform 'HTTPS://WWW.VK.COM/video1')"
    assert_eq "RuTube.Ru → rutube"                 "rutube"  "$(detect_platform 'https://RuTube.Ru/video/x/')"
    # Якорь домена не должен ослабнуть от нормализации регистра.
    assert_eq "notyoutube.com → other"             "other"   "$(detect_platform 'https://notyoutube.com/watch?v=a')"
    assert_eq "YOUTUBE.COM.evil.tld → other"       "other"   "$(detect_platform 'https://YOUTUBE.COM.evil.tld/x')"
    # Регистр пути/query не трогаем — нормализуется только host.
    assert_eq "путь в верхнем регистре → youtube"  "youtube" "$(detect_platform 'https://youtube.com/WATCH?V=AbC')"
) 2>/dev/null

# ══════════════════════════════════════════════════════════════
suite "F21 (SH): local-first резолвер ffmpeg/ffprobe"
# ══════════════════════════════════════════════════════════════
W3=$(mktemp -d /tmp/test_ytf21_XXXXXX)
# Результаты собираем в файл и проверяем в основном шелле: pass/fail внутри ( ... )
# исполняются в subshell — печатались бы, но в итог не попадали.
: > "$W3/ffmpeg.exe"
(
    set +u
    source "$SH_SCRIPT"
    echo "override=$(resolve_bin "/custom/ff" ffmpeg)"
    echo "path=$(resolve_bin "" ffmpeg)"
    SCRIPT_DIR="$W3"
    echo "local=$(resolve_bin "" ffmpeg)"
) > "$W3/out.txt" 2>/dev/null
R3="$(cat "$W3/out.txt")"
assert_contains "FFMPEG_BIN override выигрывает"   "override=/custom/ff"    "$R3"
assert_contains "без override и локального → PATH" "path=ffmpeg"            "$R3"
assert_contains "локальный ffmpeg.exe побеждает PATH (с .exe, не голый путь)" \
                "local=$W3/ffmpeg.exe" "$R3"
rm -rf "$W3"
# Перевод обязан звать резолвнутый бинарь, а не bare `ffmpeg`.
SH_SRC="$(cat "$SH_SCRIPT")"
assert_contains     "check_translate_deps проверяет \$FFMPEG"  'check_dependency "$FFMPEG"' "$SH_SRC"
assert_not_contains "мерж не зовёт bare ffmpeg"                '            ffmpeg -y -i'   "$SH_SRC"

# ══════════════════════════════════════════════════════════════
suite "F22 (SH): vot получает windows-путь, dual_track считает индекс дорожки"
# ══════════════════════════════════════════════════════════════
W4=$(mktemp -d /tmp/test_ytf22_XXXXXX)
mkdir -p "$W4/bin" "$W4/vid"
FF4_LOG="$W4/ff.log"; VOT4_LOG="$W4/vot.log"
cat > "$W4/bin/vot" <<VOTEOF
#!/bin/bash
echo "\$@" >> "$VOT4_LOG"
od=""
for a in "\$@"; do case "\$a" in --output=*) od="\${a#--output=}";; esac; done
# Эмулируем native-бинарь: понимаем ТОЛЬКО windows-путь; POSIX-каталог игнорируем.
case "\$od" in
    [A-Za-z]:[/\\\\]*) command -v cygpath >/dev/null && od="\$(cygpath -u "\$od")" ;;
    *) exit 0 ;;
esac
[ -d "\$od" ] && touch "\$od/translation.mp3"
exit 0
VOTEOF
cat > "$W4/bin/ffmpeg" <<FFEOF
#!/bin/bash
echo "\$@" >> "$FF4_LOG"
for last in "\$@"; do :; done
touch "\$last" 2>/dev/null
exit 0
FFEOF
# ffprobe сообщает ДВЕ оригинальные аудиодорожки.
cat > "$W4/bin/ffprobe" <<'FPEOF'
#!/bin/bash
echo "1"
echo "2"
exit 0
FPEOF
chmod +x "$W4/bin/vot" "$W4/bin/ffmpeg" "$W4/bin/ffprobe"

: > "$W4/vid/clip.mp4"
(
    set +u
    source "$SH_SCRIPT"
    export PATH="$W4/bin:$PATH"
    VOT_BIN="$W4/bin/vot"
    translate_audio "$W4/vid/clip.mp4" "http://u" ru live dual_track en 0.3 1.0 "" >/dev/null 2>&1
)

if command -v cygpath >/dev/null 2>&1; then
    if grep -qE -- '--output=[A-Za-z]:\\' "$VOT4_LOG" 2>/dev/null; then
        pass "vot получил windows-путь (--output=C:\\...)"
    else
        fail "vot получил windows-путь" "--output=<drive>:\\..." "$(cat "$VOT4_LOG" 2>/dev/null)"
    fi
    # Главное следствие: файл перевода найден и мерж состоялся.
    if grep -qF -- "translation.mp3" "$FF4_LOG" 2>/dev/null; then
        pass "перевод найден → мерж запущен (Git Bash)"
    else
        fail "перевод найден → мерж запущен" "translation.mp3 в argv ffmpeg" "мерж не запускался"
    fi
    # При 2 оригинальных дорожках перевод — это a:2, а не a:1.
    if grep -qF -- "-c:a:2" "$FF4_LOG" 2>/dev/null; then
        pass "dual_track: перевод кодируется как a:2 (2 оригинала)"
    else
        fail "dual_track: индекс дорожки перевода" "-c:a:2" "$(cat "$FF4_LOG" 2>/dev/null)"
    fi
    if grep -qF -- '-metadata:s:a:2' "$FF4_LOG" 2>/dev/null; then
        pass "dual_track: metadata перевода на a:2, не на втором оригинале"
    else
        fail "dual_track: metadata перевода" "-metadata:s:a:2" "$(cat "$FF4_LOG" 2>/dev/null)"
    fi
else
    skip "vot windows-путь: cygpath недоступен (не Git Bash)"
    skip "перевод найден → мерж запущен: cygpath недоступен"
    skip "dual_track a:2: cygpath недоступен"
    skip "dual_track metadata a:2: cygpath недоступен"
fi
rm -rf "$W4"

# ══════════════════════════════════════════════════════════════
suite "F31: «только субтитры» не теряет авторские captions"
# ══════════════════════════════════════════════════════════════
# Суть: все платформы слали только --write-auto-sub, хотя ни UI, ни docs не обещают
# «только автоматические» — авторские (обычно точнее) молча пропадали. При этом режим
# «субтитры вместе с видео» уже запрашивал оба вида: один продукт, две политики.
write_cfg "[download]
use_archive = false
[subtitles]
lang = ru
format = srt"
OUT=$(run_full "$CFG" --dry-run --subs "https://youtube.com/watch?v=abc")
DRY=$(dry_line "$OUT")
assert_contains "SH: --write-subs (авторские) запрошены"   "--write-subs"      "$DRY"
assert_contains "SH: --write-auto-subs (fallback) остался" "--write-auto-subs" "$DRY"
assert_contains "SH: --skip-download сохранён"             "--skip-download"   "$DRY"
# Формат и язык — из конфига, а не захардкожены.
assert_contains "SH: --sub-format из конфига (srt)"        "--sub-format srt"  "$DRY"
assert_contains "SH: --sub-langs из конфига (ru)"          "--sub-langs ru"    "$DRY"
rm -f "$CFG"

# PS1: формат из конфига (был захардкожен vtt → ключ [subtitles] format не работал).
PS1_SRC_F31="$(cat "$PS1_SCRIPT")"
assert_contains "PS1: format читается из конфига"    'Read-Config "format"              "subtitles" "vtt"' "$PS1_SRC_F31"
assert_contains "PS1: --write-subs в режиме субтитров" '"--write-subs", "--write-auto-subs", "--sub-langs", "ru"' "$PS1_SRC_F31"
assert_not_contains "PS1: vtt больше не захардкожен"  '"--sub-format", "vtt"' "$PS1_SRC_F31"

# CMD: интерактивный CLI, config.ini не читает (санкционированное исключение),
# поэтому vtt здесь остаётся — но авторские субтитры обязаны запрашиваться.
CMD_SRC_F31="$(cat "$CMD_SCRIPT")"
assert_contains "CMD: --write-subs в режиме субтитров" "--write-subs --write-auto-subs --sub-langs ru" "$CMD_SRC_F31"
assert_not_contains "CMD: legacy --write-auto-sub без --write-subs" "--sub-lang ru --write-auto-sub" "$CMD_SRC_F31"

# ══════════════════════════════════════════════════════════════
suite "F30: '--' закрывает опции перед позиционным URL"
# ══════════════════════════════════════════════════════════════
# Суть: без end-of-options строка вида '--version' исполнялась бы yt-dlp как ОПЦИЯ
# (вместо загрузки), а '-U' мог обновить/подменить сам бинарь.
write_cfg "[download]
use_archive = false
default_quality = 720"
OUT=$(run_full "$CFG" --dry-run --quality 720 "https://youtube.com/watch?v=abc")
DRY=$(dry_line "$OUT")
assert_contains "SH: '--' присутствует в argv" " -- " "$DRY"
# '--' обязан стоять непосредственно перед URL, иначе он не защищает.
case "$DRY" in
    *"-- https://youtube.com/watch?v=abc"*) pass "SH: '--' стоит прямо перед URL" ;;
    *) fail "SH: '--' стоит прямо перед URL" "-- <URL> подряд" "$DRY" ;;
esac
rm -f "$CFG"

# PS1 GUI: валидация ввода + '--' перед URL (source-scan, паритет с test_07).
PS1_SRC_F30="$(cat "$PS1_SCRIPT")"
assert_contains "PS1: ввод валидируется как http(s)-URL" "notmatch '^https?://" "$PS1_SRC_F30"
assert_contains "PS1: '--' перед позиционным URL"        '$command += "--"'     "$PS1_SRC_F30"

# ══════════════════════════════════════════════════════════════
suite "CMD source-scan: F1/F2 guardrail + F4 мерж-мэпы"
# ══════════════════════════════════════════════════════════════
CMD_SRC="$(cat "$CMD_SCRIPT")"
assert_contains "CMD F1/F2: сообщение об отключении перевода" "AI-перевод отключён" "$CMD_SRC"
assert_contains "CMD F1/F2: детект плейлиста (is_playlist)"   "is_playlist"        "$CMD_SRC"
assert_contains "CMD F4: -map 0:s? -map 0:t?"                 "-map 0:s? -map 0:t?" "$CMD_SRC"
assert_contains "CMD F4: -c:s copy"                          "-c:s copy"          "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "PS1 source-scan: F1/F2 guardrail + F3 архив + F4 мерж-мэпы"
# ══════════════════════════════════════════════════════════════
PS1_SRC="$(cat "$PS1_SCRIPT")"
assert_contains "PS1 F1/F2: сообщение об отключении перевода" "AI-перевод отключён:" "$PS1_SRC"
assert_contains "PS1 F1/F2: проверка плейлиста в переводе"    "недоступен для плейлистов" "$PS1_SRC"
assert_contains "PS1 F3: архив внутри qi-гейта (комментарий)" "только для реальных загрузок" "$PS1_SRC"
assert_contains "PS1 F4: map 0:s?"                           '"0:s?"'            "$PS1_SRC"
assert_contains "PS1 F4: -c:s copy"                          '"-c:s", "copy"'    "$PS1_SRC"

# ══════════════════════════════════════════════════════════════
suite "F22 (паритет): индекс дорожки перевода считается на всех платформах"
# ══════════════════════════════════════════════════════════════
# Захардкоженный a:1 — это и есть баг: при 2+ оригинальных дорожках metadata
# перевода садится на второй оригинал. Ни одна платформа не должна к нему вернуться.
assert_contains     "PS1: ffprobe считает оригинальные дорожки" '-select_streams a'    "$PS1_SRC"
assert_contains     "PS1: индекс перевода — переменная"         '"-c:a:$origACount"'   "$PS1_SRC"
assert_not_contains "PS1: нет захардкоженного -c:a:1"           '"-c:a:1"'             "$PS1_SRC"
assert_not_contains "PS1: нет захардкоженного -metadata:s:a:1"  '"-metadata:s:a:1"'    "$PS1_SRC"

assert_contains     "CMD: ffprobe считает оригинальные дорожки" '-select_streams a'    "$CMD_SRC"
assert_contains     "CMD: индекс перевода — переменная"         '-c:a:!orig_a_count!'  "$CMD_SRC"
assert_not_contains "CMD: нет захардкоженного -c:a:1 "          '-c:a:1 '              "$CMD_SRC"
assert_not_contains "CMD: нет захардкоженного -metadata:s:a:1 " '-metadata:s:a:1 '     "$CMD_SRC"

assert_contains     "SH: индекс перевода — переменная"          '-c:a:$orig_a_count'   "$SH_SRC"
assert_not_contains "SH: нет захардкоженного -c:a:1 "           '-c:a:1 '              "$SH_SRC"

summary
