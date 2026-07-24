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
new_repo() {
    local d; d=$(mktemp -d /tmp/test_pscan_XXXXXX)
    git -C "$d" init -q
    git -C "$d" config user.email "t@example.com"
    git -C "$d" config user.name "t"
    mkdir -p "$d/tools"
    cp "$SCANNER" "$d/tools/privacy-scan.sh"
    printf '%s\n' "$d"
}

# Коммитит рабочее дерево (git ls-files видит только tracked) и запускает сканер.
run_scan() {
    local d="$1" out rc
    git -C "$d" add -A >/dev/null 2>&1
    out=$(cd "$d" && bash tools/privacy-scan.sh 2>&1); rc=$?
    printf '%s\nEXIT=%s\n' "$out" "$rc"
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

summary
