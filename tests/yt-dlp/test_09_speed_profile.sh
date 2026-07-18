#!/bin/bash
# ============================================================
# test_09_speed_profile.sh — [network] speed_profile / limit_rate.
#
# Раньше сетевые флаги (--retries/--fragment-retries/--socket-timeout/
# --concurrent-fragments) были зашиты литералами в ТРЁХ местах: download_url и
# download_batch в .sh плюс сборка $command в .ps1. Подстроить их под медленный
# или, наоборот, быстрый канал было нельзя, а три копии могли разойтись.
#
# Контракт, который здесь закрепляется:
#   1. профиль normal (дефолт) даёт ДОСЛОВНО прежний набор — молчаливой смены
#      поведения при обновлении не происходит;
#   2. careful/fast дают документированные значения;
#   3. .sh и .ps1 дают ОДИН И ТОТ ЖЕ argv для каждого профиля (паритет платформ);
#   4. неизвестное значение не роняет запуск, а откатывается на normal + WARN;
#   5. limit_rate ортогонален профилю и пустым не добавляет флаг.
# Обе стороны — настоящие функции из production (build_net_args / Build-NetArgs).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
for _f in "$SH_SCRIPT" "$PS1_SCRIPT"; do
    if [ ! -f "$_f" ]; then
        suite "[network] speed_profile"
        fail "production-скрипт на месте" "$_f" "файл не найден"
        summary
        exit 1
    fi
done

# main() в .sh гардится BASH_SOURCE, дот-сорсинг безопасен.
source "$SH_SCRIPT" >/dev/null 2>&1

sh_net() {
    # $1 = профиль, $2 = limit_rate
    ( SPEED_PROFILE="$1"; LIMIT_RATE="$2"; build_net_args 2>/dev/null; echo "${NET_ARGS_ARR[*]}" ) < /dev/null
}

# ══════════════════════════════════════════════════════════════
suite "SH: профили дают документированные значения"
# ══════════════════════════════════════════════════════════════

# Ровно та строка, что стояла в коде до появления профилей. Если этот тест
# упадёт — значит дефолт молча поменял поведение всех существующих установок.
LEGACY="--retries 10 --fragment-retries 10 --file-access-retries 5 --socket-timeout 30 --concurrent-fragments 4"
assert_eq "normal == прежний зашитый набор (без регрессии)" "$LEGACY" "$(sh_net normal '')"

assert_eq "careful: 1 фрагмент, 20 попыток, пауза 5с, таймаут 60с" \
    "--retries 20 --fragment-retries 20 --file-access-retries 5 --socket-timeout 60 --concurrent-fragments 1 --retry-sleep 5" \
    "$(sh_net careful '')"

assert_eq "fast: 8 фрагментов, 5 попыток, таймаут 15с" \
    "--retries 5 --fragment-retries 5 --file-access-retries 5 --socket-timeout 15 --concurrent-fragments 8" \
    "$(sh_net fast '')"

# ══════════════════════════════════════════════════════════════
suite "SH: limit_rate ортогонален профилю"
# ══════════════════════════════════════════════════════════════

assert_eq "пустой limit_rate не добавляет флаг" "$LEGACY" "$(sh_net normal '')"
assert_contains "limit_rate=2M → --limit-rate 2M"  "--limit-rate 2M"  "$(sh_net normal '2M')"
assert_contains "limit_rate работает и с careful"  "--limit-rate 500K" "$(sh_net careful '500K')"

# ══════════════════════════════════════════════════════════════
suite "SH: неизвестный профиль не роняет запуск"
# ══════════════════════════════════════════════════════════════
# Опечатка в config.ini не должна приводить к пустому/битому argv.
assert_eq "неизвестный профиль откатывается на normal" "$LEGACY" "$(sh_net bogus '')"

# build_net_args обязана возвращать 0 при ПУСТОМ limit_rate (обычный случай).
# Идиома `[ -n "$X" ] && arr+=(...)` последней строкой делает статусом функции 1,
# и под `set -e` (а production включает set -euo pipefail) запуск бы падал.
_rc=$( ( SPEED_PROFILE=normal; LIMIT_RATE=""; build_net_args >/dev/null 2>&1; echo $? ) < /dev/null )
assert_eq "build_net_args возвращает 0 при пустом limit_rate" "0" "$_rc"
_rc=$( ( SPEED_PROFILE=fast; LIMIT_RATE="2M"; build_net_args >/dev/null 2>&1; echo $? ) < /dev/null )
assert_eq "build_net_args возвращает 0 при заданном limit_rate" "0" "$_rc"
_warn=$( ( SPEED_PROFILE=bogus; LIMIT_RATE=""; build_net_args ) 2>&1 >/dev/null < /dev/null )
assert_contains "неизвестный профиль печатает WARN" "speed_profile" "$_warn"

# ══════════════════════════════════════════════════════════════
suite "Паритет SH ↔ PS1: одинаковый argv для каждого профиля"
# ══════════════════════════════════════════════════════════════
# Именно ради этого таблица профилей вынесена в отдельную функцию в обеих
# платформах: разойтись двум спискам литералов было бы нечем помешать.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    skip "Паритет SH ↔ PS1" "PowerShell не найден"
else
    PS_CMD="powershell"; command -v pwsh &>/dev/null && PS_CMD="pwsh"
    PS1_WIN=$(cygpath -w "$PS1_SCRIPT" 2>/dev/null || echo "$PS1_SCRIPT")

    # Вырезаем НАСТОЯЩУЮ Build-NetArgs из production и исполняем её с нужным
    # профилем. Дот-сорсить весь GUI нельзя — он поднимет WinForms.
    ps1_net() {
        local profile="$1" rate="$2"
        $PS_CMD -NoProfile -NonInteractive -Command "
\$src = Get-Content -LiteralPath '$PS1_WIN' -Raw
\$m = [regex]::Match(\$src, '(?s)function Build-NetArgs \{.*?\n\}')
if (-not \$m.Success) { Write-Output 'BUILD_NET_ARGS_NOT_FOUND'; exit }
\$cfg_speedProfile = '$profile'
\$cfg_limitRate    = '$rate'
Invoke-Expression \$m.Value
(Build-NetArgs) -join ' '
" 2>/dev/null | tr -d '\r' | grep -v '^WARN:' | tail -1
    }

    for _p in normal careful fast; do
        _sh=$(sh_net "$_p" '')
        _ps=$(ps1_net "$_p" '')
        assert_eq "паритет профиля '$_p'" "$_sh" "$_ps"
    done

    _sh=$(sh_net normal '2M')
    _ps=$(ps1_net normal '2M')
    assert_eq "паритет limit_rate=2M" "$_sh" "$_ps"

    # Откат на normal при мусоре тоже обязан совпадать.
    assert_eq "паритет отката с неизвестного профиля" "$(sh_net bogus '')" "$(ps1_net bogus '')"
fi

# ══════════════════════════════════════════════════════════════
suite "Ключи задокументированы и читаются обеими платформами"
# ══════════════════════════════════════════════════════════════
EXAMPLE="$PROJECT_DIR/yt-dlp/config.ini.example"
src_example="$(cat "$EXAMPLE")"
assert_contains "config.ini.example: секция [network]" "[network]"     "$src_example"
assert_contains "config.ini.example: speed_profile"    "speed_profile" "$src_example"
assert_contains "config.ini.example: limit_rate"       "limit_rate"    "$src_example"

src_sh="$(cat "$SH_SCRIPT")"
src_ps1="$(cat "$PS1_SCRIPT")"
assert_contains "SH читает speed_profile из [network]"  'read_config "speed_profile" "network"' "$src_sh"
assert_contains "PS1 читает speed_profile из [network]" 'Read-Config "speed_profile" "network"' "$src_ps1"

# Литералы не должны вернуться в место сборки argv — иначе профиль будет
# «настраиваться», но не влиять ни на что.
assert_not_contains "SH: зашитый --concurrent-fragments 4 убран из сборки cmd" \
    '--socket-timeout 30 --concurrent-fragments 4)' "$src_sh"
assert_not_contains "PS1: зашитый набор убран из сборки \$command" \
    '"--socket-timeout", "30", "--concurrent-fragments", "4"' "$src_ps1"

summary
