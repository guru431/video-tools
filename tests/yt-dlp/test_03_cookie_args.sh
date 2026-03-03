#!/bin/bash
# ============================================================
# test_03_cookie_args.sh — Тест build_cookie_args()
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Inline определение функции (идентично скрипту)
build_cookie_args() {
    local method="$1"
    local cookie_file="$2"
    local cookie_browser="$3"

    case "$method" in
        file)
            if [ -f "$cookie_file" ]; then
                echo "--cookies \"$cookie_file\""
            else
                : # файл не найден — нет вывода
            fi
            ;;
        browser)
            echo "--cookies-from-browser $cookie_browser"
            ;;
        none|"")
            ;;
        *)
            : # неизвестный метод — нет вывода
            ;;
    esac
}

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод none / пустой"
# ══════════════════════════════════════════════════════════════

r=$(build_cookie_args "none" "" "")
assert_empty "method=none → пустой вывод"  "$r"

r=$(build_cookie_args "" "" "")
assert_empty "method='' → пустой вывод"  "$r"

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод browser"
# ══════════════════════════════════════════════════════════════

r=$(build_cookie_args "browser" "" "chrome")
assert_eq "browser chrome"   "--cookies-from-browser chrome"   "$r"

r=$(build_cookie_args "browser" "" "firefox")
assert_eq "browser firefox"  "--cookies-from-browser firefox"  "$r"

r=$(build_cookie_args "browser" "" "edge")
assert_eq "browser edge"     "--cookies-from-browser edge"     "$r"

r=$(build_cookie_args "browser" "" "chromium")
assert_eq "browser chromium" "--cookies-from-browser chromium" "$r"

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод file (файл существует)"
# ══════════════════════════════════════════════════════════════

TMPFILE=$(mktemp /tmp/test_cookies_XXXXXX.txt)
echo "# Netscape HTTP Cookie File" > "$TMPFILE"

r=$(build_cookie_args "file" "$TMPFILE" "")
assert_contains "file exists → --cookies path"  "--cookies"  "$r"
assert_contains "file path присутствует"        "$TMPFILE"   "$r"

rm -f "$TMPFILE"

# ══════════════════════════════════════════════════════════════
suite "Cookies: метод file (файл не существует)"
# ══════════════════════════════════════════════════════════════

r=$(build_cookie_args "file" "/tmp/nonexistent_cookies_$$.txt" "")
assert_empty "file not found → пустой вывод"  "$r"

# ══════════════════════════════════════════════════════════════
suite "Cookies: неизвестный метод"
# ══════════════════════════════════════════════════════════════

r=$(build_cookie_args "unknown_method" "" "")
assert_empty "unknown method → пустой вывод (нет краша)"  "$r"

summary
