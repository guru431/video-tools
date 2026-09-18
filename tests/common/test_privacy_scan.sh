#!/bin/bash
# ============================================================
# test_privacy_scan.sh — tools/privacy-scan.sh на НАСТОЯЩЕМ временном репозитории.
# Сканер приватных данных (RFC1918 IP / e-mail) для публичного репо не имел тестов.
#
# Ловит две находки:
#   • `for f in $(git ls-files)` бил путь по пробелам → файл с пробелом в имени
#     сканировался по несуществующим фрагментам, т.е. не сканировался вовсе;
#   • blanket-исключение всего класса *.example глушило IP/e-mail-скан там, где
#     допустимы лишь пустые/фиктивные значения (случайная реальная вставка прошла бы CI).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SCANNER="$PROJECT_DIR/tools/privacy-scan.sh"

if [ ! -f "$SCANNER" ]; then
    suite "privacy-scan"
    fail "сканер на месте" "$SCANNER" "файл не найден"
    summary
    exit 1
fi

# Временный git-репозиторий с копией сканера в tools/.
# Каждый шаг проверяется: молчаливый сбой подготовки давал НЕОТЛИЧИМЫЙ от
# настоящего провал ассерта — репозиторий без индекса сканируется «чисто», и
# однассертный suite показывает ровно «1 failure» без единого намёка на причину
# (так и выглядела находка 2026-09-16: упало под нагрузкой полного прогона,
# а какой именно assert и почему — установить было нечем).
new_repo() {
    local d; d=$(mktemp -d /tmp/test_pscan_XXXXXX) || return 1
    git -C "$d" init -q            || { echo "NEW_REPO_FAILED: git init" >&2; return 1; }
    git -C "$d" config user.email "t@example.com" || return 1
    git -C "$d" config user.name "t"              || return 1
    mkdir -p "$d/tools"            || return 1
    cp "$SCANNER" "$d/tools/privacy-scan.sh" || { echo "NEW_REPO_FAILED: cp" >&2; return 1; }
    printf '%s\n' "$d"
}

# Индексирует рабочее дерево (git ls-files видит только tracked) и запускает сканер.
# Код возврата `git add` и список проиндексированных путей попадают в вывод: без них
# сбой подготовки выглядел как «сканер не нашёл утечку», и различить эти два случая
# по результату теста было невозможно.
run_scan() {
    local d="$1" out rc add_out add_rc tracked
    add_out=$(git -C "$d" add -A 2>&1); add_rc=$?
    tracked=$(git -C "$d" ls-files 2>&1 | tr '\n' ' ')
    out=$(cd "$d" && bash tools/privacy-scan.sh 2>&1); rc=$?
    printf '%s\nEXIT=%s\nGIT_ADD_RC=%s %s\nTRACKED=%s\n' "$out" "$rc" "$add_rc" "$add_out" "$tracked"
}

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: файл с пробелом в имени сканируется (не пропускается)"
# ══════════════════════════════════════════════════════════════
# Суть находки: word-splitting раньше дробил "my config.txt" на "my" + "config.txt",
# оба не существуют как файлы → приватный IP внутри уходил незамеченным.
R=$(new_repo)
printf 'server = 10.1.2.3\n' > "$R/my config.txt"
OUT=$(run_scan "$R")
assert_contains "приватный IP в файле с пробелом → найден" "PRIVACY" "$OUT"
assert_not_contains "приватный IP в файле с пробелом → exit != 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: обычный *.example больше НЕ исключён из скана"
# ══════════════════════════════════════════════════════════════
# Реальный private IP, случайно вписанный в config.ini.example, обязан ловиться.
R=$(new_repo)
printf 'host = 192.168.5.10\n' > "$R/config.ini.example"
OUT=$(run_scan "$R")
assert_contains "private IP в config.ini.example → найден" "PRIVACY" "$OUT"
assert_not_contains "private IP в config.ini.example → exit != 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: .sanitize-patterns.example с плейсхолдерами остаётся исключён"
# ══════════════════════════════════════════════════════════════
# Единственный пример, которому RFC1918-плейсхолдеры нужны по определению.
R=$(new_repo)
printf '10.10.10.10\n192.168.100.100\n' > "$R/.sanitize-patterns.example"
OUT=$(run_scan "$R")
assert_not_contains ".sanitize-patterns.example с плейсхолдерами не флагуется" "PRIVACY" "$OUT"
assert_contains ".sanitize-patterns.example → exit 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: e-mail — реальный ловится, example-домен нет"
# ══════════════════════════════════════════════════════════════
R=$(new_repo)
printf 'contact = real.person@internal-corp.io\n' > "$R/notes.txt"
OUT=$(run_scan "$R")
assert_contains "реальный e-mail → найден" "PRIVACY: e-mail" "$OUT"
rm -rf "$R"

R=$(new_repo)
printf 'contact = john@example.com\n' > "$R/notes.txt"
OUT=$(run_scan "$R")
assert_not_contains "example.com e-mail не флагуется" "PRIVACY" "$OUT"
assert_contains "чистый (example.com) → exit 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: чистый репозиторий проходит"
# ══════════════════════════════════════════════════════════════
R=$(new_repo)
printf 'просто текст без приватных данных\n' > "$R/readme.txt"
OUT=$(run_scan "$R")
assert_contains "чистый репозиторий → exit 0" "EXIT=0" "$OUT"
assert_not_contains "чистый репозиторий → нет PRIVACY" "PRIVACY" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: IP с точкой в конце предложения"
# ══════════════════════════════════════════════════════════════
# Правая граница класса была [^0-9.], поэтому «сервер 10.1.2.3.» не совпадало
# вовсе: барьер молчал ровно там, где утечка выглядит естественнее всего —
# в обычном русском тексте документации.
R=$(new_repo)
printf 'Рабочий сервер — 10.1.2.3.\n' > "$R/notes.txt"
OUT=$(run_scan "$R")
assert_contains "IP с точкой в конце → найден" "PRIVACY: приватный IPv4" "$OUT"
assert_not_contains "IP с точкой в конце → exit != 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: файл с кириллическим именем сканируется"
# ══════════════════════════════════════════════════════════════
# `git ls-files` без -z ЭКРАНИРУЕТ такие пути в кавычки с октальными
# последовательностями, `[ -f "$f" ]` на них ложен, и файл не сканировался вовсе.
# Репозиторий русскоязычный, так что это вопрос времени, а не гипотеза.
R=$(new_repo)
printf 'сервер 192.168.10.20\n' > "$R/заметки.txt"
OUT=$(run_scan "$R")
assert_contains "IP в «заметки.txt» → найден" "PRIVACY: приватный IPv4" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: git@host из SSH-clone URL не флагуется"
# ══════════════════════════════════════════════════════════════
# `git@github.com:user/repo.git` — обычная строка в инструкции по клонированию.
# Ложные срабатывания на документации приучают обходить проверку целиком.
R=$(new_repo)
printf 'git clone git@github.com:user/repo.git\n' > "$R/README.md"
OUT=$(run_scan "$R")
assert_not_contains "git@github.com не флагуется как e-mail" "PRIVACY: e-mail" "$OUT"
assert_contains "SSH-clone URL → exit 0" "EXIT=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "privacy-scan: сломанный барьер падает, а не рапортует «чисто»"
# ══════════════════════════════════════════════════════════════
# Сканер жил на `cd "$(git rev-parse --show-toplevel)"`. При любом сбое git
# подстановка отдавала пусто, `cd ""` завершался успешно, `git ls-files` падал
# внутри process substitution (там set -e слеп) — и барьер печатал «чисто» с
# exit 0 НА ДЕРЕВЕ С ПРИВАТНЫМ IP. Это хуже отсутствия проверки: CI не просто
# пропускал утечку, а подтверждал её отсутствие. Здесь — оба сбоя подряд.
NOREPO=$(mktemp -d /tmp/test_pscan_norepo_XXXXXX)
mkdir -p "$NOREPO/tools"
cp "$SCANNER" "$NOREPO/tools/privacy-scan.sh"
printf 'server = 10.1.2.3\n' > "$NOREPO/leak.txt"
OUT=$(cd "$NOREPO" && bash tools/privacy-scan.sh 2>&1; printf 'EXIT=%s\n' "$?")
assert_not_contains "вне git-репозитория сканер НЕ печатает «чисто»" "privacy-scan: чисто" "$OUT"
assert_not_contains "вне git-репозитория сканер НЕ возвращает 0" "EXIT=0" "$OUT"
assert_contains "вне git-репозитория сказано, что проверка не выполнена" "ПРОВЕРКА НЕ ВЫПОЛНЕНА" "$OUT"
rm -rf "$NOREPO"

# Пустой индекс — это «не просканировано ничего». Ровно так выглядит молчаливо
# сорвавшийся `git add`, и раньше он давал «чисто» с exit 0.
R=$(new_repo)
printf 'server = 10.1.2.3\n' > "$R/leak.txt"   # файл есть, но НЕ проиндексирован
OUT=$(cd "$R" && bash tools/privacy-scan.sh 2>&1; printf 'EXIT=%s\n' "$?")
assert_contains "пустой индекс → проверка не выполнена" "ПРОВЕРКА НЕ ВЫПОЛНЕНА" "$OUT"
assert_not_contains "пустой индекс → НЕ «чисто»" "privacy-scan: чисто" "$OUT"
assert_not_contains "пустой индекс → exit != 0" "EXIT=0" "$OUT"
rm -rf "$R"

summary
