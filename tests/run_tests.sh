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
# Suite, пропущенный ЦЕЛИКОМ (0 pass, 0 fail, >0 skip) — платформенный инструмент
# недоступен (cmd/powershell). Именно это ловит STRICT_SKIP (см. конец файла).
SUITES_FULLY_SKIPPED=0
FULLY_SKIPPED_NAMES=()

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

    # Итог берём из machine-readable маркера framework (TESTS_RESULT pass=N fail=N skip=N),
    # а не из ✓/✗/○-глифов: те зависят от оформления, цветов и локали.
    local marker pass fail skip
    marker=$(echo "$output" | grep -o 'TESTS_RESULT pass=[0-9]* fail=[0-9]* skip=[0-9]*' | tail -1)
    pass=$(echo "$marker" | grep -o 'pass=[0-9]*' | grep -o '[0-9]*')
    fail=$(echo "$marker" | grep -o 'fail=[0-9]*' | grep -o '[0-9]*')
    skip=$(echo "$marker" | grep -o 'skip=[0-9]*' | grep -o '[0-9]*')

    pass="${pass:-0}"
    fail="${fail:-0}"
    skip="${skip:-0}"

    # Любой ненулевой rc обязан дать провал. Если fail>0 — он уже посчитан (summary
    # возвращает 1 именно из-за этих провалов, второй раз добавлять нельзя). Если
    # fail==0, то suite умер по иной причине: крах до/после summary, set -e, exit N.
    # Раньше здесь дополнительно требовалось pass==0, поэтому suite с успешными
    # assertions и последующим `exit 7` уходил в зелёную ветку.
    if [ "$exit_code" -ne 0 ] && [ "$fail" -eq 0 ]; then
        TOTAL_PASS=$((TOTAL_PASS + pass))
        TOTAL_SKIP=$((TOTAL_SKIP + skip))
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name (rc=$exit_code, assertions ok: $pass)")
        return
    fi

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    # Полностью пропущенный suite (0/0/>0) = платформенный инструмент недоступен.
    if [ "$skip" -gt 0 ] && [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
        SUITES_FULLY_SKIPPED=$((SUITES_FULLY_SKIPPED + 1))
        FULLY_SKIPPED_NAMES+=("$suite_name")
    fi

    if [ "$fail" -gt 0 ]; then
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name ($fail failures)")
    else
        SUITE_RESULTS+=("${GREEN}✓${NC} $suite_name")
    fi
}

# ── Запуск, либо провал если зарегистрированный файл исчез ────────────────────
# Раньше: `[ -f "$f" ] && run_suite "$f"` — удалённый/переименованный тест молча
# пропадал из результата. Теперь отсутствие зарегистрированного файла = провал.
run_or_missing() {
    local test_file="$1"
    if [ -f "$test_file" ]; then
        run_suite "$test_file"
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} $(basename "$test_file" .sh) (файл отсутствует)")
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
    "$TESTS_DIR/ffmpeg/test_08_ps1_audio_video.sh"
    "$TESTS_DIR/ffmpeg/test_09_ps1_filters_gpu.sh"
    "$TESTS_DIR/ffmpeg/test_10_cmd.sh"
    "$TESTS_DIR/ffmpeg/test_11_cmd_smoke.sh"
    "$TESTS_DIR/ffmpeg/test_12_cmd_run_parser.sh"
    "$TESTS_DIR/ffmpeg/test_13_parser_parity.sh"
    "$TESTS_DIR/ffmpeg/test_14_audio_only_codec.sh"
    "$TESTS_DIR/ffmpeg/test_15_findings.sh"
    "$TESTS_DIR/ffmpeg/test_16_gui_state.sh"
)

YTDLP_TESTS=(
    "$TESTS_DIR/yt-dlp/test_01_read_config.sh"
    "$TESTS_DIR/yt-dlp/test_02_format_args.sh"
    "$TESTS_DIR/yt-dlp/test_03_cookie_args.sh"
    "$TESTS_DIR/yt-dlp/test_04_integration.sh"
    "$TESTS_DIR/yt-dlp/test_05_cmd.sh"
    "$TESTS_DIR/yt-dlp/test_06_ps1.sh"
    "$TESTS_DIR/yt-dlp/test_07_new_features.sh"
    "$TESTS_DIR/yt-dlp/test_08_findings.sh"
)

# Кросс-платформенные инварианты (кодировки, паритет ключей config.ini, guardrail'ы)
COMMON_TESTS=(
    "$TESTS_DIR/common/test_encoding.sh"
    "$TESTS_DIR/common/test_config_keys.sh"
    "$TESTS_DIR/common/test_config_contract.sh"
    "$TESTS_DIR/common/test_guardrails.sh"
    "$TESTS_DIR/common/test_pre_commit_hook.sh"
    "$TESTS_DIR/common/test_path_matrix.sh"
    "$TESTS_DIR/common/test_ytdlp_preset_parity.sh"
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
            run_or_missing "$test_file"
        done
        ;;
    yt-dlp|ytdlp)
        echo -e "${BOLD}Модуль: YT-DLP Downloader${NC}"
        for test_file in "${YTDLP_TESTS[@]}"; do
            run_or_missing "$test_file"
        done
        ;;
    common)
        echo -e "${BOLD}Модуль: Общие инварианты${NC}"
        for test_file in "${COMMON_TESTS[@]}"; do
            run_or_missing "$test_file"
        done
        ;;
    all|*)
        echo -e "${BOLD}Модуль: FFmpeg Converter${NC}"
        for test_file in "${FFMPEG_TESTS[@]}"; do
            run_or_missing "$test_file"
        done
        echo ""
        echo -e "${BOLD}Модуль: YT-DLP Downloader${NC}"
        for test_file in "${YTDLP_TESTS[@]}"; do
            run_or_missing "$test_file"
        done
        echo ""
        echo -e "${BOLD}Модуль: Общие инварианты${NC}"
        for test_file in "${COMMON_TESTS[@]}"; do
            run_or_missing "$test_file"
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

# STRICT_SKIP=1 (Windows CI): ошибка, только если suite пропущен ЦЕЛИКОМ (cmd/powershell
# недоступен → теряется SH/CMD/PS1 паритет). Частичные окружения-скипы внутри запущенного
# suite'а (напр. интеграционный тест без реального ffmpeg) — допустимы. На Linux переменную
# не выставляют: там CMD/PS1 suite'ы ожидаемо пропускаются целиком.
if [ "${STRICT_SKIP:-0}" = "1" ] && [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}STRICT_SKIP: $SUITES_FULLY_SKIPPED suite(ов) пропущено целиком (нет cmd/powershell): ${FULLY_SKIPPED_NAMES[*]}${NC}"
    exit 1
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}ПРОВАЛЕНО: $TOTAL_FAIL тест(ов)${NC}"
    exit 1
elif [ "$TOTAL_SKIP" -gt 0 ] || [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
    # «ВСЕ ТЕСТЫ ПРОЙДЕНЫ» при пропусках — это ложное успокоение: на WSL/Linux
    # PS1/CMD-suite'ы пропускаются целиком, и та же строка означала «проверено всё»,
    # хотя половина платформ не запускалась вовсе. Пройдено ≠ проверено.
    echo -e "\n${GREEN}${BOLD}ПРОВАЛОВ НЕТ${NC}${YELLOW} — но проверено НЕ всё${NC}"
    [ "$TOTAL_SKIP" -gt 0 ] && echo -e "${YELLOW}  Пропущено тестов: $TOTAL_SKIP${NC}"
    if [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
        echo -e "${YELLOW}  Suite'ов пропущено целиком: $SUITES_FULLY_SKIPPED — ${FULLY_SKIPPED_NAMES[*]}${NC}"
        echo -e "${YELLOW}  Требуется полное покрытие? Запустите с STRICT_SKIP=1 (нужны cmd + powershell).${NC}"
    fi
    exit 0
else
    echo -e "\n${GREEN}${BOLD}ВСЕ ТЕСТЫ ПРОЙДЕНЫ${NC}"
    exit 0
fi
