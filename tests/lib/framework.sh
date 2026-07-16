#!/bin/bash
# ============================================================
# Test Framework — assert helpers + pass/fail tracking
# ============================================================

TESTS_PASS=0
TESTS_FAIL=0
TESTS_SKIP=0
CURRENT_SUITE=""

# Счётчики держим в файле, а не в переменных. Тесты, которым нужна изоляция,
# зовут pass/fail внутри `( ... )` — это subshell, и инкремент переменной там
# умирает вместе с ним: файл печатал ✗, а summary честно рапортовал 0 провалов
# и exit 0. Обычный subshell наследует переменную, поэтому дописывает в тот же
# файл; export не нужен и вреден — иначе разные test-файлы слили бы счётчики.
TESTS_RESULT_FILE="$(mktemp "${TMPDIR:-/tmp}/tests_counter_XXXXXX")"
TESTS_RESULT_OWNER=$$
trap '[ "${TESTS_RESULT_OWNER:-}" = "$$" ] && rm -f "$TESTS_RESULT_FILE"' EXIT

_tally() { printf '%s\n' "$1" >> "$TESTS_RESULT_FILE"; }
_tally_count() { grep -c "^$1\$" "$TESTS_RESULT_FILE" 2>/dev/null || true; }

# ── Цвета ──────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

suite() {
    CURRENT_SUITE="$1"
    echo -e "\n${CYAN}${BOLD}=== $1 ===${NC}"
}

pass() {
    _tally P
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    _tally F
    echo -e "  ${RED}✗${NC} $1"
    [ -n "${2:-}" ] && echo -e "    ${YELLOW}Ожидалось:${NC} $2"
    [ -n "${3:-}" ] && echo -e "    ${YELLOW}Получено: ${NC} $3"
    return 0
}

skip() {
    _tally S
    echo -e "  ${YELLOW}○${NC} $1 (пропущен: ${2:-})"
}

assert_eq() {
    local name="$1"
    local expected="$2"
    local actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$name"
    else
        fail "$name" "'$expected'" "'$actual'"
    fi
}

assert_contains() {
    local name="$1"
    local pattern="$2"
    local text="$3"
    if echo "$text" | grep -qF -- "$pattern"; then
        pass "$name"
    else
        fail "$name" "содержит: '$pattern'" "в: '$text'"
    fi
}

assert_not_contains() {
    local name="$1"
    local pattern="$2"
    local text="$3"
    if ! echo "$text" | grep -qF -- "$pattern"; then
        pass "$name"
    else
        fail "$name" "НЕ содержит: '$pattern'" "но нашли в: '$text'"
    fi
}

assert_empty() {
    local name="$1"
    local value="$2"
    if [ -z "$value" ]; then
        pass "$name"
    else
        fail "$name" "(пусто)" "'$value'"
    fi
}

assert_not_empty() {
    local name="$1"
    local value="$2"
    if [ -n "$value" ]; then
        pass "$name"
    else
        fail "$name" "(не пусто)" "(пусто)"
    fi
}

assert_file_exists() {
    local name="$1"
    local file="$2"
    if [ -f "$file" ]; then
        pass "$name"
    else
        fail "$name" "файл существует: $file" "файл не найден"
    fi
}

summary() {
    TESTS_PASS=$(_tally_count P); TESTS_PASS=${TESTS_PASS:-0}
    TESTS_FAIL=$(_tally_count F); TESTS_FAIL=${TESTS_FAIL:-0}
    TESTS_SKIP=$(_tally_count S); TESTS_SKIP=${TESTS_SKIP:-0}
    local total=$((TESTS_PASS + TESTS_FAIL + TESTS_SKIP))
    echo -e "\n${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    echo -e "  Всего: $total  |  ${GREEN}✓ $TESTS_PASS${NC}  |  ${RED}✗ $TESTS_FAIL${NC}  |  ${YELLOW}○ $TESTS_SKIP${NC}"
    echo -e "${BOLD}${CYAN}═══════════════════════════════════════${NC}"
    # Machine-readable итог для run_tests.sh: раньше runner вытаскивал числа из
    # ✓/✗/○-глифов человеческой строки выше — это ломается от смены оформления,
    # цветов и локали. Строка ниже — контракт между framework и runner.
    echo "TESTS_RESULT pass=$TESTS_PASS fail=$TESTS_FAIL skip=$TESTS_SKIP"
    if [ "$TESTS_FAIL" -gt 0 ]; then
        return 1
    fi
    return 0
}
