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

# ══════════════════════════════════════════════════════════════
suite "pre-commit: блок 3 (локальный denylist .sanitize-patterns)"
# ══════════════════════════════════════════════════════════════
# Блок denylist'а не был покрыт вовсе, хотя именно он ловит КОНКРЕТНЫЕ значения
# (имена, внутренние хосты), которых generic-форматы не знают по построению.
R=$(new_repo)
# Сам denylist коммитить нельзя НИКОГДА (это список конкретных приватных
# значений), и filename-guard хука блокирует его по имени. В рабочем
# репозитории он gitignored — повторяем это в фикстуре, иначе тест
# проверял бы filename-guard, а не блок 3.
printf '.sanitize-patterns
' > "$R/.gitignore"
printf 'ОченьВнутреннийХост-42\n' > "$R/.sanitize-patterns"
printf 'server = ОченьВнутреннийХост-42\n' > "$R/notes.txt"
OUT=$(try_commit "$R" "denylist value")
assert_contains     "значение из denylist → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "значение из denylist → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

# Тот же denylist, но значения в диффе нет — коммит обязан пройти.
R=$(new_repo)
printf '.sanitize-patterns
' > "$R/.gitignore"
printf 'ОченьВнутреннийХост-42\n' > "$R/.sanitize-patterns"
printf 'server = public.example.com\n' > "$R/notes.txt"
OUT=$(try_commit "$R" "no denylist value")
assert_contains "чистый файл при непустом denylist → коммит создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: блок 4 (секрет внутри бинарного файла)"
# ══════════════════════════════════════════════════════════════
# Текстовый дифф внутрь бинарника не заглядывает, поэтому блок 4 извлекает из
# staged-блоба печатные строки. Проверяем и ASCII-имя, и кириллическое: последнее
# `git diff --numstat` без core.quotePath=false отдаёт экранированным, `git show`
# такой путь не находит, и файл молча пропускался.
R=$(new_repo)
printf 'binary\000data %s trailer\000' "$FAKE_TOKEN" > "$R/data.bin"
OUT=$(try_commit "$R" "binary secret")
assert_contains     "токен в data.bin → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "токен в data.bin → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

R=$(new_repo)
printf 'binary\000data %s trailer\000' "$FAKE_TOKEN" > "$R/данные.bin"
OUT=$(try_commit "$R" "binary secret cyrillic name")
assert_contains     "токен в «данные.bin» → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "токен в «данные.bin» → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: контентная строка, начинающаяся с '+'"
# ══════════════════════════════════════════════════════════════
# `grep -v '^+++'` отбрасывал не только заголовок файла, но и добавленную строку
# вида `++ ghp_…` — например при коммите текста самого патча. Дифф-заголовок
# теперь отбрасывается точным шаблоном.
R=$(new_repo)
printf '++ token %s\n' "$FAKE_TOKEN" > "$R/patch.txt"
OUT=$(try_commit "$R" "plus-plus line")
assert_contains     "строка '++ токен' → BLOCKED" "BLOCKED" "$OUT"
assert_not_contains "строка '++ токен' → коммит НЕ создан" "RC=0" "$OUT"
rm -rf "$R"

# ══════════════════════════════════════════════════════════════
suite "pre-commit: обычные слова с 'sk-' не блокируются"
# ══════════════════════════════════════════════════════════════
# `sk-[A-Za-z0-9_-]{16,}` без левой границы блокировал task-management-system-2026
# и risk-assessment-checklist. Ложные срабатывания приучают к --no-verify, а он
# отключает и все остальные проверки разом — то есть делают барьер вредным.
R=$(new_repo)
printf 'см. task-management-system-2026 и risk-assessment-checklist-2026\n' > "$R/notes.txt"
OUT=$(try_commit "$R" "ordinary words with sk-")
assert_contains     "обычные слова с sk- → коммит создан" "RC=0" "$OUT"
assert_not_contains "обычные слова с sk- → нет BLOCKED" "BLOCKED" "$OUT"
rm -rf "$R"

summary
