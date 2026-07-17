#!/bin/sh
# privacy-scan.sh — generic PII / private-infrastructure scanner for a PUBLIC repo.
#
# Дополняет gitleaks (секреты/ключи) генерик-паттернами, которые до сих пор ловил ТОЛЬКО
# локальный denylist .sanitize-patterns (gitignored) — то есть НЕ web-commit/PR/форк.
# Здесь — универсальные, org-независимые маркеры: приватные IPv4 (RFC1918) и e-mail.
# Конкретные внутренние значения (домены, хосты, ФИО) остаются в локальном denylist:
# они по определению приватные и в публичный репозиторий (включая CI-конфиг) не попадают.
#
#   tools/privacy-scan.sh          # скан всего дерева (как в CI)
#   exit 0 — чисто; exit 1 — найдены совпадения (печатает файл:строку).
set -eu

cd "$(git rev-parse --show-toplevel)"
fail=0

# Приватные IPv4 (RFC1918): 10/8, 172.16/12, 192.168/16. Границы [^0-9.] отсекают
# попадания внутри более длинных чисел/версий (напр. "10.10" в "1010.10").
ip_re='(^|[^0-9.])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3})([^0-9.]|$)'
# E-mail. Плейсхолдеры документации (example.com/org/net, user:pass@) исключаются ниже.
email_re='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'

# Файлы-исключения: бинарники, чек-суммы, картинки и намеренные ПРИМЕРЫ значений
# (.sanitize-patterns.example демонстрирует, что denylist должен ловить, — там 10.10.10.10
# и 192.168.100.100 стоят специально). Сам этот скрипт — тоже (несёт паттерны).
is_excluded() {
    case "$1" in
        *.exe|*.sha256|*.png|*.jpg|*.jpeg|*.ico|*.gif|*.pdf) return 0 ;;
        *.example|*.example.*|.sanitize-patterns.example)    return 0 ;;
        tools/privacy-scan.sh)                               return 0 ;;
    esac
    return 1
}

for f in $(git ls-files); do
    is_excluded "$f" && continue
    [ -f "$f" ] || continue

    ip_hits=$(grep -nE "$ip_re" "$f" 2>/dev/null || true)
    if [ -n "$ip_hits" ]; then
        echo "PRIVACY: приватный IPv4 (RFC1918) в $f:"
        printf '%s\n' "$ip_hits" | sed 's/^/  /'
        fail=1
    fi

    # E-mail: исключаем документационные example-домены (в любой позиции, включая
    # поддомен proxy.example.com) и proxy-плейсхолдеры user:pass@.
    mail_hits=$(grep -noE "$email_re" "$f" 2>/dev/null \
        | grep -viE 'example\.(com|org|net)' \
        | grep -viE '(user:pass|username:password)@' || true)
    if [ -n "$mail_hits" ]; then
        echo "PRIVACY: e-mail адрес в $f:"
        printf '%s\n' "$mail_hits" | sed 's/^/  /'
        fail=1
    fi
done

if [ "$fail" -ne 0 ]; then
    echo ""
    echo "Приватные данные в публичном репозитории. Уберите значения или добавьте в"
    echo "локальный denylist только если это намеренный пример (*.example)."
    exit 1
fi
echo "privacy-scan: чисто"
exit 0
