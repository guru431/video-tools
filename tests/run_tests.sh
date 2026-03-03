#!/bin/bash
# ============================================================
# run_tests.sh — Точка входа для всей системы тестирования
#
# Использование:
#   bash tests/run_tests.sh           # все тесты
#   bash tests/run_tests.sh ffmpeg    # только ffmpeg
#   bash tests/run_tests.sh yt-dlp    # только yt-dlp
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FILTER="${1:-all}"

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_RESULTS=()

# ── Запуск одного тест-файла в субоболочке ───────────────────────────────────
run_suite() {
    local test_file="$1"
    local suite_name
    suite_name=$(basename "$test_file" .sh)

    echo -e "\n${BOLD}${CYAN}▶ $suite_name${NC}"

    # Запускаем тест-файл, захватываем вывод и exit code
    local output
    output=$(bash "$test_file" 2>&1)
    local exit_code=$?

    echo "$output"

    # Парсим итоговую строку Results из вывода
    local pass fail skip
    pass=$(echo "$output" | grep -o '✓ [0-9]*' | grep -o '[0-9]*' | tail -1)
    fail=$(echo "$output" | grep -o '✗ [0-9]*' | grep -o '[0-9]*' | tail -1)
    skip=$(echo "$output" | grep -o '○ [0-9]*' | grep -o '[0-9]*' | tail -1)

    pass="${pass:-0}"
    fail="${fail:-0}"
    skip="${skip:-0}"

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    if [ "$fail" -gt 0 ]; then
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name ($fail failures)")
    else
        SUITE_RESULTS+=("${GREEN}✓${NC} $suite_name")
    fi
}

# ── Определяем какие тесты запускать ─────────────────────────────────────────
FFMPEG_TESTS=(
    "$TESTS_DIR/ffmpeg/test_01_config_sh.sh"
    "$TESTS_DIR/ffmpeg/test_02_config_ps1.sh"
    "$TESTS_DIR/ffmpeg/test_03_audio_args.sh"
    "$TESTS_DIR/ffmpeg/test_04_video_args.sh"
    "$TESTS_DIR/ffmpeg/test_05_filters.sh"
    "$TESTS_DIR/ffmpeg/test_06_gpu.sh"
    "$TESTS_DIR/ffmpeg/test_07_integration.sh"
)

YTDLP_TESTS=(
    "$TESTS_DIR/yt-dlp/test_01_read_config.sh"
    "$TESTS_DIR/yt-dlp/test_02_format_args.sh"
    "$TESTS_DIR/yt-dlp/test_03_cookie_args.sh"
    "$TESTS_DIR/yt-dlp/test_04_integration.sh"
)

# ── Баннер ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║          Система тестирования видео-скриптов     ║"
echo "║          ffmpeg converter + yt-dlp downloader    ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

# ── Запуск тестов ────────────────────────────────────────────────────────────
case "$FILTER" in
    ffmpeg)
        echo -e "${BOLD}Модуль: FFmpeg Converter${NC}"
        for test_file in "${FFMPEG_TESTS[@]}"; do
            [ -f "$test_file" ] && run_suite "$test_file"
        done
        ;;
    yt-dlp|ytdlp)
        echo -e "${BOLD}Модуль: YT-DLP Downloader${NC}"
        for test_file in "${YTDLP_TESTS[@]}"; do
            [ -f "$test_file" ] && run_suite "$test_file"
        done
        ;;
    all|*)
        echo -e "${BOLD}Модуль: FFmpeg Converter${NC}"
        for test_file in "${FFMPEG_TESTS[@]}"; do
            [ -f "$test_file" ] && run_suite "$test_file"
        done
        echo ""
        echo -e "${BOLD}Модуль: YT-DLP Downloader${NC}"
        for test_file in "${YTDLP_TESTS[@]}"; do
            [ -f "$test_file" ] && run_suite "$test_file"
        done
        ;;
esac

# ── Итоговый отчёт ───────────────────────────────────────────────────────────
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║                 ИТОГОВЫЙ ОТЧЁТ                  ║${NC}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════╣${NC}"

for result in "${SUITE_RESULTS[@]}"; do
    echo -e "║  $(echo -e "$result")${NC}"
done

echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${CYAN}║${NC}  Всего: $TOTAL  |  ${GREEN}✓ $TOTAL_PASS пройдено${NC}  |  ${RED}✗ $TOTAL_FAIL провалено${NC}  |  ${YELLOW}○ $TOTAL_SKIP пропущено${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}ПРОВАЛЕНО: $TOTAL_FAIL тест(ов)${NC}"
    exit 1
else
    echo -e "\n${GREEN}${BOLD}ВСЕ ТЕСТЫ ПРОЙДЕНЫ${NC}"
    exit 0
fi
