#!/bin/bash
# ============================================================
# test_framework_selfcheck.sh — фреймворк проверяет сам себя.
#
# Находка: assert_contains/assert_not_contains были построены на
# `echo "$text" | grep -qF`. Почти все тесты дот-сорсят production, а тот
# включает `set -o pipefail`. В такой оболочке `grep -q` завершается на первом
# совпадении, пишущий `echo` ловит SIGPIPE и отдаёт 141, и pipefail назначает
# 141 статусом всего пайплайна — хотя паттерн найден.
#
# Эффект зависел от РАЗМЕРА текста: на коротких строках writer успевал
# дописать до выхода grep, и всё выглядело исправным. На файле в ~94 КБ
# (Downloading_from_YouTube_v15.ps1) начиналось расхождение:
#   • assert_contains     — ложный ПРОВАЛ;
#   • assert_not_contains — ложный УСПЕХ, то есть guardrail «запрещённого
#     паттерна нет» оставался зелёным при том, что паттерн в файле есть.
#
# Тест ниже воспроизводит именно те условия (pipefail + большой текст) и
# требует честного ответа в ОБЕ стороны. Без этого регрессия вернётся молча:
# сама поломка выглядит как «зелёные тесты».
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

# Текст заведомо больше буфера пайпа (64 КБ на Linux/Git Bash) — именно на
# таком размере grep -q успевает выйти раньше, чем writer допишет.
BIG_TEXT="$(for i in $(seq 1 4000); do echo "строка наполнителя номер $i — padding padding padding"; done)
МАРКЕР_В_КОНЦЕ_ТЕКСТА
$(for i in $(seq 1 4000); do echo "хвост наполнителя номер $i — padding padding padding"; done)"

# Маркер намеренно в СЕРЕДИНЕ: grep найдёт его задолго до конца ввода и,
# с -q, выйдет — ровно тот момент, когда writer получал SIGPIPE.
MARKER="МАРКЕР_В_КОНЦЕ_ТЕКСТА"

# ══════════════════════════════════════════════════════════════
suite "Ассерты честны при pipefail (условия production-скриптов)"
# ══════════════════════════════════════════════════════════════

set -o pipefail   # ровно то, что протекает из дот-сорснутого production

assert_contains     "assert_contains находит маркер в большом тексте"      "$MARKER"        "$BIG_TEXT"
assert_not_contains "assert_not_contains не находит отсутствующий паттерн" "ZZZ_НЕТ_ZZZ_QQ" "$BIG_TEXT"

# Ключевая проверка: ложная зелёнка. Код возврата самого ассерта смотреть
# бесполезно — fail() намеренно возвращает 0, чтобы тест-файл продолжался.
# Судить надо по СЧЁТЧИКУ провалов, поэтому запускаем отдельный мини-тест-файл
# и читаем его machine-readable маркер TESTS_RESULT.
_probe=$(mktemp "${TMPDIR:-/tmp}/fw_probe_XXXXXX.sh")
cat > "$_probe" << PROBEEOF
source "$TESTS_DIR/lib/framework.sh"
source "$(dirname "$0")/../../yt-dlp/Downloading_from_YouTube_v15.sh" >/dev/null 2>&1
suite "probe"
_big="\$(cat "$(dirname "$0")/../../yt-dlp/Downloading_from_YouTube_v15.ps1")"
assert_not_contains "запрещённый паттерн отсутствует" "Read-Config" "\$_big"
summary
PROBEEOF
_marker=$(bash "$_probe" 2>/dev/null < /dev/null | grep -o 'TESTS_RESULT pass=[0-9]* fail=[0-9]*' | tail -1)
rm -f "$_probe"

# В зонде дот-сорсится настоящий production (pipefail + nounset) и берётся
# настоящий 94-КБ .ps1, где "Read-Config" заведомо есть. Ассерт ОБЯЗАН провалиться.
case "$_marker" in
    *"fail=0") fail "assert_not_contains падает, когда паттерн реально присутствует" \
                    "fail=1" "$_marker — вернулась ложная зелёнка на большом тексте" ;;
    "")        fail "assert_not_contains падает, когда паттерн реально присутствует" \
                    "маркер TESTS_RESULT" "зонд не отработал" ;;
    *)         pass "assert_not_contains падает, когда паттерн реально присутствует" ;;
esac

set +o pipefail

# ══════════════════════════════════════════════════════════════
suite "Ассерты не собраны на пайпе (анти-регресс в исходнике)"
# ══════════════════════════════════════════════════════════════
# Поведенческая проверка выше зависит от размера буфера пайпа в конкретной ОС.
# Здесь фиксируем сам механизм: пайпа в реализации быть не должно.
src_fw="$(cat "$TESTS_DIR/lib/framework.sh")"
assert_contains "поиск идёт через here-string" 'grep -qF -- "$2" <<< "$1"' "$src_fw"

# Проверяем ТЕЛА функций, а не весь файл: в комментариях старая форма
# 'echo | grep' упомянута намеренно (объяснение находки), и грубый grep по
# файлу падал бы на собственной документации.
_bodies=$(awk '/^(assert_contains|assert_not_contains|_text_contains)\(\)/{f=1} f{print} /^\}/{f=0}' "$TESTS_DIR/lib/framework.sh")
assert_not_contains "в телах assert_* нет пайпа в grep" "| grep" "$_bodies"

summary
