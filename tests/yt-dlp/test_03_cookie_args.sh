#!/bin/bash
# ============================================================
# test_03_cookie_args.sh — Тест НАСТОЯЩЕЙ build_cookie_args() из production
#
# Раньше файл держал inline-копию, подписанную «идентично скрипту». Идентичной она
# не была даже приблизительно: копия ЭХОИЛА СТРОКУ с литеральными кавычками
# (`--cookies "путь"`), а production заполняет argv-МАССИВ COOKIE_ARGS_ARR и пишет
# предупреждения. То есть тест проверял реализацию, от которой проект давно ушёл
# (ручная сборка argv-строки прямо запрещена guardrail'ом), и не мог поймать ни
# одной поломки настоящей функции.
#
# Контракт production: COOKIE_ARGS_ARR — массив, значения передаются в yt-dlp как
# отдельные argv-элементы. Именно поэтому путь с пробелами не требует кавычек и не
# разваливается на несколько аргументов — это и проверяем.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.sh"
if [ ! -f "$YT_SH" ]; then
    suite "Cookies: build_cookie_args"
    fail "production-скрипт на месте" "$YT_SH" "файл не найден — тест проверял бы копию, а не production"
    summary
    exit 1
fi
source "$YT_SH"
# Production включает `set -uo pipefail` на верхнем уровне; в тестовой оболочке это
# роняет framework на первой же необъявленной переменной.
set +u +o pipefail

# Хелпер: зовём настоящую функцию и отдаём массив в виде «arg|arg|arg» — так видно
# ГРАНИЦЫ argv-элементов, а не только текст. Строковая копия этого показать не могла.
cookie_call() {
    COOKIE_ARGS_ARR=()
    build_cookie_args "$1" "$2" "$3" >/dev/null 2>&1
    local IFS='|'
    printf '%s' "${COOKIE_ARGS_ARR[*]}"
}

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод none / пустой"
# ══════════════════════════════════════════════════════════════

assert_empty "method=none → массив пуст"  "$(cookie_call "none" "" "")"
assert_empty "method='' → массив пуст"    "$(cookie_call "" "" "")"

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод browser"
# ══════════════════════════════════════════════════════════════

for _b in chrome firefox edge chromium; do
    assert_eq "browser $_b → 2 argv-элемента" "--cookies-from-browser|$_b" "$(cookie_call "browser" "" "$_b")"
done

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод file (файл существует)"
# ══════════════════════════════════════════════════════════════

TMPFILE=$(mktemp /tmp/test_cookies_XXXXXX.txt)
echo "# Netscape HTTP Cookie File" > "$TMPFILE"
assert_eq "file exists → --cookies + путь как ОТДЕЛЬНЫЕ argv" "--cookies|$TMPFILE" "$(cookie_call "file" "$TMPFILE" "")"
rm -f "$TMPFILE"

# Путь с пробелами — то, ради чего массив и заведён. Строковая копия отдавала
# `--cookies "путь с пробелами"`, и кавычки уезжали в yt-dlp литералами.
# Шаблон обязан быть ОДНИМ закавыченным аргументом: BSD mktemp (macOS) принимает
# несколько шаблонов сразу и на `mktemp -d /tmp/test cookies_XXXXXX` создаёт две
# папки, отдавая их двумя строками — путь склеивался через перевод строки.
SPACE_DIR=$(mktemp -d "/tmp/test cookies_XXXXXX")
SPACE_FILE="$SPACE_DIR/my cookies.txt"
echo "# Netscape HTTP Cookie File" > "$SPACE_FILE"
space_res="$(cookie_call "file" "$SPACE_FILE" "")"
assert_eq "путь с пробелами остаётся ОДНИМ argv-элементом" "--cookies|$SPACE_FILE" "$space_res"
# Кавычек в значении быть не должно: их добавлял строковый билдер, и yt-dlp получал
# их как часть имени файла.
if [[ "$space_res" == *'"'* ]]; then
    fail "в argv нет литеральных кавычек" "путь без кавычек" "$space_res"
else
    pass "в argv нет литеральных кавычек"
fi
rm -rf "$SPACE_DIR"

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод file (файл не существует)"
# ══════════════════════════════════════════════════════════════

assert_empty "file not found → массив пуст" "$(cookie_call "file" "/tmp/nonexistent_cookies_$$.txt" "")"
# Молчаливый пропуск был бы хуже ошибки: пользователь задал cookies и вправе узнать,
# что их не применили. Копия предупреждения не выдавала вовсе.
warn_out=$( COOKIE_ARGS_ARR=(); build_cookie_args "file" "/tmp/nonexistent_cookies_$$.txt" "" 2>&1 )
assert_contains "file not found → предупреждение пользователю" "Файл cookies не найден" "$warn_out"

# ══════════════════════════════════════════════════════════════
suite "Cookies: неизвестный метод"
# ══════════════════════════════════════════════════════════════

assert_empty "unknown method → массив пуст (нет краша)" "$(cookie_call "unknown_method" "" "")"
warn_out=$( COOKIE_ARGS_ARR=(); build_cookie_args "unknown_method" "" "" 2>&1 )
assert_contains "unknown method → предупреждение пользователю" "Неизвестный метод cookies" "$warn_out"

summary
