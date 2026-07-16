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

summary
