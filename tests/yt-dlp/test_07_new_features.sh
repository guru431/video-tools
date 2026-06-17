#!/bin/bash
# ============================================================
# test_07_new_features.sh — opt-in фичи yt-dlp (SPEC A/B/C)
#   A) audio_format   [download] = best(def)|mp3|m4a|opus
#   B) sponsorblock   [download] = off(def)|mark|remove
#   C) download_with_video [subtitles] = off(def)|sidecar|embed
#
# SH: реальный --dry-run печатает итоговую команду yt-dlp — проверяем
#     точные флаги по SPEC. Бинарь yt-dlp подменяется моком через YTDLP_BIN.
# CMD/PS1: source-scan на наличие промптов/контролов и точных флаг-строк
#     (зеркало test_05/test_02 — production-исходник, не дубликат).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
CMD_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
MOCK_YTDLP="$TESTS_DIR/mocks/yt-dlp"

chmod +x "$MOCK_YTDLP" 2>/dev/null

# ── Хелпер: записать временный config.ini ────────────────────────────────────
write_cfg() {
    CFG=$(mktemp /tmp/test_ytfeat_XXXXXX.ini)
    printf '%s\n' "$1" > "$CFG"
}

# ── Хелпер: запустить SH в --dry-run, вернуть строку [DRY-RUN] ───────────────
# Передаём фейковый YouTube-URL и mock yt-dlp; реальный код строит команду.
run_dry() {
    local cfg="$1"; shift
    YTDLP_BIN="$MOCK_YTDLP" bash "$SH_SCRIPT" --config "$cfg" "$@" \
        --dry-run "https://youtube.com/watch?v=abc" 2>&1 | grep '\[DRY-RUN\]'
}

# ══════════════════════════════════════════════════════════════
suite "SH A) audio_format=mp3 + --quality audio → --extract-audio"
# ══════════════════════════════════════════════════════════════

write_cfg "[download]
default_quality = 720
format_preset = avc1_best
use_archive = false
audio_format = mp3
sponsorblock = off
[subtitles]
lang = ru
download_with_video = off"

OUT=$(run_dry "$CFG" --quality audio)
assert_contains "mp3: --extract-audio"        "--extract-audio"   "$OUT"
assert_contains "mp3: --audio-format mp3"      "--audio-format mp3" "$OUT"
assert_contains "mp3: --audio-quality 0"       "--audio-quality 0"  "$OUT"
rm -f "$CFG"

# m4a-вариант
write_cfg "[download]
use_archive = false
audio_format = m4a
[subtitles]
lang = ru"
OUT=$(run_dry "$CFG" --quality audio)
assert_contains "m4a: --audio-format m4a"  "--audio-format m4a"  "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH A) audio_format=mp3 НО качество видео → нет --extract-audio"
# ══════════════════════════════════════════════════════════════
# extract-audio только при quality=audio. Для видео-качества — ничего.

write_cfg "[download]
use_archive = false
audio_format = mp3
[subtitles]
lang = ru"
OUT=$(run_dry "$CFG" --quality 720)
assert_not_contains "видео-качество: нет --extract-audio"  "--extract-audio"  "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH B) sponsorblock=remove → --sponsorblock-remove all"
# ══════════════════════════════════════════════════════════════

write_cfg "[download]
use_archive = false
sponsorblock = remove
[subtitles]
lang = ru"
OUT=$(run_dry "$CFG" --quality 720)
assert_contains "remove: --sponsorblock-remove all"  "--sponsorblock-remove all"  "$OUT"
rm -f "$CFG"

write_cfg "[download]
use_archive = false
sponsorblock = mark
[subtitles]
lang = ru"
OUT=$(run_dry "$CFG" --quality 720)
assert_contains "mark: --sponsorblock-mark all"  "--sponsorblock-mark all"  "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH C) download_with_video=sidecar → --write-subs --sub-langs"
# ══════════════════════════════════════════════════════════════

write_cfg "[download]
use_archive = false
[subtitles]
lang = ru
download_with_video = sidecar"
OUT=$(run_dry "$CFG" --quality 720)
assert_contains "sidecar: --write-subs"        "--write-subs"       "$OUT"
assert_contains "sidecar: --write-auto-subs"   "--write-auto-subs"  "$OUT"
assert_contains "sidecar: --sub-langs ru"      "--sub-langs ru"     "$OUT"
assert_not_contains "sidecar: НЕ embed"        "--embed-subs"       "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH C) download_with_video=embed → дополнительно --embed-subs"
# ══════════════════════════════════════════════════════════════

write_cfg "[download]
use_archive = false
[subtitles]
lang = en
download_with_video = embed"
OUT=$(run_dry "$CFG" --quality 1080)
assert_contains "embed: --write-subs"       "--write-subs"      "$OUT"
assert_contains "embed: --write-auto-subs"  "--write-auto-subs" "$OUT"
assert_contains "embed: --sub-langs en"     "--sub-langs en"    "$OUT"
assert_contains "embed: --embed-subs"       "--embed-subs"      "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH NEGATIVE: дефолты best/off/off → ни одной фичи"
# ══════════════════════════════════════════════════════════════

write_cfg "[download]
use_archive = false
audio_format = best
sponsorblock = off
[subtitles]
lang = ru
download_with_video = off"
OUT=$(run_dry "$CFG" --quality audio)
assert_not_contains "дефолт: нет --extract-audio"  "--extract-audio"  "$OUT"
assert_not_contains "дефолт: нет --sponsorblock"   "--sponsorblock"   "$OUT"
assert_not_contains "дефолт: нет --embed-subs"     "--embed-subs"     "$OUT"
assert_not_contains "дефолт: нет --write-subs"     "--write-subs"     "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "SH NEGATIVE: subtitle-only (--subs) → нет sponsorblock/embed"
# ══════════════════════════════════════════════════════════════
# В режиме только-субтитры (--skip-download) реальные загрузочные фичи
# не применяются, даже если включены в конфиге.

write_cfg "[download]
use_archive = false
sponsorblock = remove
[subtitles]
lang = ru
download_with_video = embed"
OUT=$(run_dry "$CFG" --subs)
assert_contains "subs-only: --skip-download"        "--skip-download"  "$OUT"
assert_not_contains "subs-only: нет sponsorblock"   "--sponsorblock"   "$OUT"
assert_not_contains "subs-only: нет --embed-subs"   "--embed-subs"     "$OUT"
rm -f "$CFG"

# ══════════════════════════════════════════════════════════════
suite "CMD source-scan: промпты + точные флаг-строки (SPEC A/B/C)"
# ══════════════════════════════════════════════════════════════
CMD_SRC="$(cat "$CMD_SCRIPT")"

# A) audio_format
assert_contains "CMD A: --extract-audio mp3"   "--extract-audio --audio-format mp3 --audio-quality 0"   "$CMD_SRC"
assert_contains "CMD A: --extract-audio m4a"   "--extract-audio --audio-format m4a --audio-quality 0"   "$CMD_SRC"
assert_contains "CMD A: --extract-audio opus"  "--extract-audio --audio-format opus --audio-quality 0"  "$CMD_SRC"
# B) sponsorblock
assert_contains "CMD B: --sponsorblock-mark all"    "--sponsorblock-mark all"    "$CMD_SRC"
assert_contains "CMD B: --sponsorblock-remove all"  "--sponsorblock-remove all"  "$CMD_SRC"
# C) субтитры-с-видео
assert_contains "CMD C: sidecar write-subs"  "--write-subs --write-auto-subs --sub-langs ru"  "$CMD_SRC"
assert_contains "CMD C: embed --embed-subs"  "--embed-subs"  "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "PS1 source-scan: контролы + точные флаги (SPEC A/B/C)"
# ══════════════════════════════════════════════════════════════
PS1_SRC="$(cat "$PS1_SCRIPT")"

# Чтение конфига для новых ключей
assert_contains "PS1: читает audio_format"        "audio_format"        "$PS1_SRC"
assert_contains "PS1: читает sponsorblock"         "sponsorblock"        "$PS1_SRC"
assert_contains "PS1: читает download_with_video"  "download_with_video" "$PS1_SRC"
# A) точные флаги
assert_contains "PS1 A: --extract-audio"   "--extract-audio"   "$PS1_SRC"
assert_contains "PS1 A: --audio-quality"   "--audio-quality"   "$PS1_SRC"
# B)
assert_contains "PS1 B: --sponsorblock-mark"    "--sponsorblock-mark"    "$PS1_SRC"
assert_contains "PS1 B: --sponsorblock-remove"  "--sponsorblock-remove"  "$PS1_SRC"
# C)
assert_contains "PS1 C: --write-subs"       "--write-subs"       "$PS1_SRC"
assert_contains "PS1 C: --write-auto-subs"  "--write-auto-subs"  "$PS1_SRC"
assert_contains "PS1 C: --embed-subs"       "--embed-subs"       "$PS1_SRC"

summary
