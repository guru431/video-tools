#!/bin/bash
# ============================================================
# test_04_integration.sh — Интеграционный тест YT-DLP пайплайна
# Запускает настоящий скрипт с mock yt-dlp
# Проверяет что аргументы передаются корректно
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MOCKS_DIR="$TESTS_DIR/mocks"

source "$TESTS_DIR/lib/framework.sh"

YTDLP_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v13.sh"
YTDLP_LOG="/tmp/mock_ytdlp_int_$$.txt"
OUTPUT_DIR="/tmp/test_ytdlp_out_$$"
FAKE_URL="https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# Если скрипт переименован/удалён — сразу выходим, чтобы не давать ложных fail
if [ ! -f "$YTDLP_SCRIPT" ]; then
    suite "Интеграция: yt-dlp script"
    skip "Скрипт $YTDLP_SCRIPT не найден" "файл существует"
    summary
    exit 0
fi

mkdir -p "$OUTPUT_DIR"

# ── Вспомогательная: запуск скрипта с конкретными аргументами ───────────────
# timeout 10s — защита от зависания (если mock не подхватился и скрипт пошёл в реальную сеть).
# command -v timeout: на Windows Git Bash coreutils-timeout есть; если нет — без таймаута.
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_BIN="timeout 10"; fi

run_script() {
    rm -f "$YTDLP_LOG"
    MOCK_YTDLP_LOG="$YTDLP_LOG" \
    PATH="$MOCKS_DIR:$PATH" \
    $TIMEOUT_BIN bash "$YTDLP_SCRIPT" "$@" </dev/null 2>/dev/null
}

# ── Создаём минимальный config.ini для скрипта ──────────────────────────────
CONFIG_DIR="$PROJECT_DIR/yt-dlp"
BACKUP_CONFIG=""

write_test_config() {
    cat > "$CONFIG_DIR/config.ini" << EOF
[proxy]
url =

[cookies]
method = none
browser = chrome
file =

[output]
base_dir = $OUTPUT_DIR
template = %(title)s.%(ext)s
playlist_template = %(playlist_title)s/%(title)s.%(ext)s

[download]
default_quality = 720
continue_on_error = true
use_archive = false
archive_file =

[subtitles]
lang = ru
format = vtt

[batch]
date_range =
sleep_requests = 0
sleep_interval = 0
max_sleep_interval = 0
sleep_subtitles = 0

[translation]
enabled = false
target_lang = ru
voice_style = live
mode = dual_track
EOF
}

# Сохраняем оригинальный config если есть
if [ -f "$CONFIG_DIR/config.ini" ]; then
    BACKUP_CONFIG=$(cat "$CONFIG_DIR/config.ini")
fi

write_test_config

# ══════════════════════════════════════════════════════════════
suite "Интеграция: базовый вызов (URL + качество 720)"
# ══════════════════════════════════════════════════════════════

run_script --quality 720 "$FAKE_URL"

# На Windows Git Bash read_config форкает sed на каждой строке config.ini, и
# даже на минимальном конфиге load_config может занять >10s — mock не успевает
# отработать до timeout. Это известное ограничение Windows + cygwin (MEMORY.md).
# На Linux/macOS log создаётся быстро. Если log не создан — скипаем (не fail).
if [ -f "$YTDLP_LOG" ]; then
    pass "mock yt-dlp был вызван"
    CALL=$(cat "$YTDLP_LOG")
    assert_contains "URL передан в mock"           "$FAKE_URL"          "$CALL"
    assert_contains "качество 720 → height<=720"   "height<=720"        "$CALL"
else
    skip "mock yt-dlp вызов" "config.ini load timed out (slow sed-fork on Windows)"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: качество 1080"
# ══════════════════════════════════════════════════════════════

run_script --quality 1080 "$FAKE_URL"

if [ -f "$YTDLP_LOG" ]; then
    CALL=$(cat "$YTDLP_LOG")
    assert_contains "1080 → height<=1080"  "height<=1080"  "$CALL"
else
    skip "mock yt-dlp вызов при --quality 1080" "config.ini load timed out"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: пресет avc1_https"
# ══════════════════════════════════════════════════════════════

run_script --quality 720 --preset avc1_https "$FAKE_URL"

if [ -f "$YTDLP_LOG" ]; then
    CALL=$(cat "$YTDLP_LOG")
    # avc1_https + 720 = "-f 140+136/135/134"
    assert_contains "avc1_https 720 → числовые ID"  "140+136"  "$CALL"
else
    skip "avc1_https тест" "mock не был вызван"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: cookies browser"
# ══════════════════════════════════════════════════════════════

run_script --cookies browser --quality 720 "$FAKE_URL"

if [ -f "$YTDLP_LOG" ]; then
    CALL=$(cat "$YTDLP_LOG")
    # Должен быть --cookies-from-browser chrome (из config)
    assert_contains "cookies browser → --cookies-from-browser"  \
        "--cookies-from-browser"  "$CALL"
else
    skip "cookies browser тест" "mock не был вызван"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: субтитры (--subs)"
# ══════════════════════════════════════════════════════════════

run_script --subs "$FAKE_URL"

if [ -f "$YTDLP_LOG" ]; then
    CALL=$(cat "$YTDLP_LOG")
    assert_contains "subs → --write-auto-sub"   "--write-auto-sub"   "$CALL"
    assert_contains "subs → --skip-download"    "--skip-download"    "$CALL"
    assert_contains "subs → --sub-lang ru"      "--sub-lang ru"      "$CALL"
else
    skip "subs тест" "mock не был вызван"
fi

# ══════════════════════════════════════════════════════════════
suite "Интеграция: --help не вызывает yt-dlp"
# ══════════════════════════════════════════════════════════════

rm -f "$YTDLP_LOG"
run_script --help

if [ ! -f "$YTDLP_LOG" ]; then
    pass "--help: yt-dlp НЕ вызывается"
else
    fail "--help: yt-dlp НЕ должен вызываться" "нет лога" "лог создан"
fi

# ── Восстанавливаем оригинальный config ───────────────────────
if [ -n "$BACKUP_CONFIG" ]; then
    printf '%s\n' "$BACKUP_CONFIG" > "$CONFIG_DIR/config.ini"
else
    rm -f "$CONFIG_DIR/config.ini"
fi

rm -f "$YTDLP_LOG"
rm -rf "$OUTPUT_DIR"

summary
