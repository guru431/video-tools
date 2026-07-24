#!/bin/bash
# ============================================================
# test_pre_commit_hook.sh — .githooks/pre-commit на НАСТОЯЩЕМ временном репозитории.
# Хук не имел тестов вовсе, хотя это последний барьер перед публичным репо.
#
# Ключевая находка: сканер читал весь staged diff, включая строки с '-'. Поэтому
# коммит, УДАЛЯЮЩИЙ уже утёкший токен, блокировался — ровно тогда, когда обязан
# пройти. Это подталкивало к --no-verify, который отключает и все прочие проверки.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

HOOK="$PROJECT_DIR/.githooks/pre-commit"

if [ ! -f "$HOOK" ]; then
    suite "pre-commit hook"
    fail "хук на месте" "$HOOK" "файл не найден"
    summary
    exit 1
fi

# Готовит временный репозиторий с хуком и возвращает его путь.
new_repo() {
    local d; d=$(mktemp -d /tmp/test_hook_XXXXXX)
    git -C "$d" init -q
    git -C "$d" config user.email "t@example.com"
    git -C "$d" config user.name "t"
    git -C "$d" config commit.gpgsign false
    mkdir -p "$d/.githooks"
    cp "$HOOK" "$d/.githooks/pre-commit"
    chmod +x "$d/.githooks/pre-commit"
    git -C "$d" config core.hooksPath .githooks
    printf '%s\n' "$d"
}

# Пытается закоммитить и печатает RC + вывод.
try_commit() {
    local d="$1" msg="$2"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -q -m "$msg" 2>&1
    printf 'RC=%s\n' "$?"
}

# Фиктивный токен нужного формата (ghp_ + 20+ символов).
FAKE_TOKEN="ghp_$(printf 'A%.0s' $(seq 1 30))"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: добавление секрета блокируется"
# ══════════════════════════════════════════════════════════════
R=$(new_repo)
printf 'token = %s\n' "$FAKE_TOKEN" > "$R/conf.txt"
OUT=$(try_commit "$R" "add secret")
assert_contains "добавление ghp_-токена → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "добавление ghp_-токена → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: удаление уже попавшего секрета разрешено"
# ══════════════════════════════════════════════════════════════
# Суть находки: секрет уже в истории (закоммичен в обход хука). Коммит, который
# его УДАЛЯЕТ, обязан пройти — иначе чинить утечку можно только через --no-verify.
R=$(new_repo)
printf 'token = %s\n' "$FAKE_TOKEN" > "$R/conf.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q --no-verify -m "leak (bypassed hook)" >/dev/null 2>&1
# Теперь убираем секрет — это remediation-коммит.
printf 'token = ${GITHUB_TOKEN}\n' > "$R/conf.txt"
OUT=$(try_commit "$R" "remove secret")
assert_not_contains "удаление секрета НЕ блокируется" "BLOCKED" "$OUT"
assert_contains     "удаление секрета → коммит создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: чистый коммит проходит"
# ══════════════════════════════════════════════════════════════
R=$(new_repo)
printf 'просто текст без секретов\n' > "$R/readme.txt"
OUT=$(try_commit "$R" "clean")
assert_not_contains "чистый коммит не блокируется" "BLOCKED" "$OUT"
assert_contains     "чистый коммит создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: документированные placeholder'ы не ложные срабатывания"
# ══════════════════════════════════════════════════════════════
R=$(new_repo)
printf 'proxy = http://username:password@host:8080\n' > "$R/config.ini.example"
OUT=$(try_commit "$R" "placeholder")
assert_not_contains "username:password@ (шаблон) не блокируется" "BLOCKED" "$OUT"
assert_contains     "username:password@ → коммит создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: составное .env.*-имя блокируется"
# ══════════════════════════════════════════════════════════════
# .env.production.local — типовое имя с секретами (Next.js/Node). Старый filename-guard
# (regex с одним alnum-суффиксом) его не ловил; если содержимое не похоже на токен-формат,
# публичный репо принял бы файл. Содержимое НАРОЧНО не токен-формат — проверяем block 1.
R=$(new_repo)
printf 'DB_PASSWORD=plain-not-a-token-format\n' > "$R/.env.production.local"
OUT=$(try_commit "$R" "add composite env")
assert_contains     "добавление .env.production.local → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains ".env.production.local → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

# .env.example остаётся разрешённым шаблоном (без секретов).
R=$(new_repo)
printf 'DB_PASSWORD=\n' > "$R/.env.example"
OUT=$(try_commit "$R" "add env example")
assert_not_contains ".env.example (шаблон) не блокируется" "BLOCKED" "$OUT"
assert_contains     ".env.example → коммит создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: rename tracked-файла в чувствительное имя блокируется"
# ══════════════════════════════════════════════════════════════
# Статус R (не A), и чистый rename не даёт '+'-строк — content-скан (block 2) его не видит.
# Filename-guard обязан ловить НАЗНАЧЕНИЕ rename через --diff-filter=ACR -M. Содержимое
# нарочно не токен-формат, чтобы проверялся именно filename-guard, а не совпадение по токену.
R=$(new_repo)
printf 'DB_PASSWORD=plain-not-a-token-format\n' > "$R/notes.txt"
git -C "$R" add -A >/dev/null 2>&1
git -C "$R" commit -q --no-verify -m "seed notes" >/dev/null 2>&1
git -C "$R" mv notes.txt .env >/dev/null 2>&1
OUT=$(try_commit "$R" "rename to .env")
assert_contains     "rename notes.txt → .env → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "rename → .env → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

summary
