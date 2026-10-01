#!/bin/bash
# Тест дот-сорсит настоящий production-скрипт: переменные, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
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

# ── Временный файл С РАСШИРЕНИЕМ ───────────────────────────
# $1 = префикс пути (каталог + начало имени), $2 = расширение вместе с точкой.
#   tmp=$(mktemp_suffix /tmp/test_dump_ .txt)   → /tmp/test_dump_a1B2c3.txt
#
# Писать шаблон как `mktemp /tmp/test_dump_XXXXXX.txt` НЕЛЬЗЯ: у BSD mktemp (macOS)
# шаблон обязан ОКАНЧИВАТЬСЯ на X, иначе подстановки не происходит вовсе и создаётся
# буквальный файл с шестью иксами в имени. Первый вызов проходит, второй подряд падает
# «mkstemp failed: File exists», переменная остаётся пустой, вывод уходит в никуда — и
# тест молча проверяет не то, что собирался (так упал macOS-джоб CI 2026-08-15).
# Расширение при этом нужно по делу: powershell не исполняет файл без .ps1, cmd.exe —
# без .cmd. Поэтому имя с суффиксом создаём сами: случайная часть из $RANDOM, а
# уникальность держит noclobber (`>` под `set -C` создаёт файл через O_EXCL и
# занятое имя не перезапишет — тогда берётся следующее). Прежние mktemp + mv
# стоили двух процессов на каждый из сотен вызовов набора.
mktemp_suffix() {
    local prefix="$1" ext="${2:-}" f n=0 set_c=""
    case "$-" in *C*) ;; *) set -C; set_c=1 ;; esac
    while [ "$n" -lt 100 ]; do
        f="${prefix}${RANDOM}${RANDOM}${ext}"
        n=$((n + 1))
        { [ -e "$f" ] || [ -L "$f" ]; } && continue
        if { : > "$f"; } 2>/dev/null; then
            [ -n "$set_c" ] && set +C
            printf '%s' "$f"
            return 0
        fi
    done
    [ -n "$set_c" ] && set +C
    return 1
}

# ── Сетевой guard ──────────────────────────────────────────
# Тесты НИКОГДА не должны ходить в сеть. Инцидент: у VOT_BIN не было env-override,
# и check_translate_deps безусловно перезатирал переменную бинарём рядом со скриптом —
# тест перевода запускал настоящий vot-cli-live и ~22 с стучался во внешний сервис.
# Override добавлен, но без guard'а регрессия вернулась бы незамеченной. Здесь мы
# кладём в НАЧАЛО PATH poison-заглушки для сетевых инструментов: если production-код
# в обход мока вызовет bare-бинарь, заглушка громко упадёт (exit 97) вместо тихого
# сетевого вызова, и наблюдающий тест провалится. Легитимные тесты перевода передают
# мок через VOT_BIN/YTDLP_BIN и prepend'ят mocks-каталог — те имеют приоритет.
if [ -z "${TEST_NET_GUARD_DIR:-}" ]; then
    TEST_NET_GUARD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tests_netguard_XXXXXX")"
    TEST_NET_GUARD_OWNER=$$
    # printf, а не `cat <<`, и один chmod на все заглушки: это начало КАЖДОГО
    # тест-файла, а каждый лишний процесс здесь стоит десятки миллисекунд.
    # $(basename …) в одинарных кавычках — текст заглушки: раскрывается при её
    # запуске, а не здесь (SC2016).
    for _bin in vot-cli-live vot-cli-live.exe curl; do
        # shellcheck disable=SC2016
        printf '%s\n' '#!/bin/bash' \
            'echo "NETWORK GUARD: реальный '"'"'$(basename "$0")'"'"' вызван в тесте — сетевые вызовы запрещены. Передайте мок через VOT_BIN/CURL_BIN." >&2' \
            'exit 97' > "$TEST_NET_GUARD_DIR/$_bin"
    done
    chmod +x "$TEST_NET_GUARD_DIR/vot-cli-live" "$TEST_NET_GUARD_DIR/vot-cli-live.exe" "$TEST_NET_GUARD_DIR/curl"
    export PATH="$TEST_NET_GUARD_DIR:$PATH"
    export TEST_NET_GUARD_DIR
    trap '[ "${TESTS_RESULT_OWNER:-}" = "$$" ] && rm -f "$TESTS_RESULT_FILE"; [ "${TEST_NET_GUARD_OWNER:-}" = "$$" ] && rm -rf "$TEST_NET_GUARD_DIR"' EXIT
fi

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

# Поиск подстроки БЕЗ пайпа — это принципиально, а не стилистика.
#
# Раньше было `echo "$text" | grep -qF`. Тесты, которые дот-сорсят production
# (а это теперь почти все), наследуют его `set -o pipefail`. Дальше `grep -q`
# завершается на ПЕРВОМ совпадении, пишущий `echo` получает SIGPIPE и отдаёт
# 141, и pipefail делает статусом всего пайплайна именно 141 — при том что
# паттерн найден. Срабатывает только когда текст достаточно велик, чтобы grep
# успел выйти раньше конца записи (~десятки КБ), поэтому на коротких строках
# всё выглядело исправным.
#
# Последствия были в обе стороны, и вторая опаснее первой:
#   • assert_contains     — ложный ПРОВАЛ на большом файле;
#   • assert_not_contains — ложный УСПЕХ: запрещённый паттерн в файле есть,
#     а guardrail зелёный. Проверено на .ps1 в 94 КБ.
# Here-string читается grep'ом из временного файла, пайплайна нет вовсе,
# поэтому ни SIGPIPE, ни pipefail на результат не влияют.
#
# Однострочный паттерн сравнивается самим bash, без grep: ассерт с grep — это
# процесс, а процесс в Git Bash стоит 30–250 мс (замер 2026-10-01: 84 мс против
# 0,8 мс на тексте в 140 КБ), и на тысячах ассертов набора это минуты. Паттерн в
# кавычках, поэтому `*`, `?` и `[` в нём — обычные символы, как у `grep -F`.
# Многострочный паттерн `grep -F` понимает как СПИСОК паттернов (совпадение
# любого), и эта семантика сохраняется — он по-прежнему идёт через grep.
_text_contains() {
    case "$2" in
        *$'\n'*) grep -qF -- "$2" <<< "$1" ;;
        *) [[ $1 == *"$2"* ]] ;;
    esac
}

assert_contains() {
    local name="$1"
    local pattern="$2"
    local text="$3"
    # Пустой паттерн ВСЕГДА совпадает, то есть ассерт становится вечнозелёным.
    # Причина почти всегда одна: слева стоит `$(…)`, вернувшая пусто, — тогда тест
    # проверяет не то, что собирался, и молчит об этом.
    if [ -z "$pattern" ]; then
        fail "$name" "непустой паттерн" "паттерн пуст — ассерт был бы вечнозелёным"
        return
    fi
    if _text_contains "$text" "$pattern"; then
        pass "$name"
    else
        fail "$name" "содержит: '$pattern'" "в: '$text'"
    fi
}

assert_not_contains() {
    local name="$1"
    local pattern="$2"
    local text="$3"
    if ! _text_contains "$text" "$pattern"; then
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
    # Подсчёт — циклом самого bash, а не тремя `grep -c`: те стоили шесть
    # процессов на каждый тест-файл.
    local _t
    TESTS_PASS=0; TESTS_FAIL=0; TESTS_SKIP=0
    while IFS= read -r _t; do
        case "$_t" in
            P) TESTS_PASS=$((TESTS_PASS + 1)) ;;
            F) TESTS_FAIL=$((TESTS_FAIL + 1)) ;;
            S) TESTS_SKIP=$((TESTS_SKIP + 1)) ;;
        esac
    done 2>/dev/null < "$TESTS_RESULT_FILE"
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
