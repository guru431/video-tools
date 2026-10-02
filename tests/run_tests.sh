#!/bin/bash
# ============================================================
# run_tests.sh — Точка входа для всей системы тестирования
#
# Использование:
#   bash tests/run_tests.sh           # все тесты (полный уровень)
#   bash tests/run_tests.sh ffmpeg    # только ffmpeg
#   bash tests/run_tests.sh yt-dlp    # только yt-dlp
#   bash tests/run_tests.sh common    # только кросс-платформенные инварианты
#   bash tests/run_tests.sh --fast    # быстрый уровень: без файлов, поднимающих PowerShell/CMD/GUI
#   bash tests/run_tests.sh --fast ffmpeg              # быстрый уровень одного модуля
#   bash tests/run_tests.sh --list [--fast] [модуль]   # только список файлов, без запуска
#
# Таймаут на файл: TEST_FILE_TIMEOUT=<секунды> (умолчания — ниже, у FAST).
#
# Маркеры для внешнего ночного свипа тестов (с начала строки, без цвета):
#   TESTS_DURATION <сек>s <модуль>/<файл>.sh    — время каждого файла
#   TESTS_TIMEOUT <модуль>/<файл>.sh after=<N>s  — файл снят по таймауту (= провал)
#   TESTS_RESULT pass=N fail=N skip=N            — итог прогона, ПОСЛЕДНЯЯ такая строка
# Команды уровней объявлены в контракте тестов свипа (поле `tests` проекта).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

FAST=0
LIST=0
FILTER="all"
for _arg in "$@"; do
    case "$_arg" in
        --fast) FAST=1 ;;
        --list) LIST=1 ;;
        -*)
            echo -e "${RED}Неизвестный ключ: '$_arg'${NC}"
            echo "Использование: bash tests/run_tests.sh [--fast] [--list] [all|ffmpeg|yt-dlp|common]"
            exit 2
            ;;
        *) FILTER="$_arg" ;;
    esac
done

# Таймаут на ОДИН файл теста. Зависший файл раньше держал прогон до таймаута агента;
# теперь он снимается, считается провалом и печатается маркером TESTS_TIMEOUT.
# Запас — кратный над самым долгим нормальным файлом своего уровня на загруженной
# машине (замер 2026-09-30 на Windows-машине разработки; сами времена печатает раннер).
if [ "$FAST" = "1" ]; then
    TEST_FILE_TIMEOUT="${TEST_FILE_TIMEOUT:-180}"
else
    # Самый долгий файл — ffmpeg/test_15_findings: ~95 с (2026-10-01); до сокращения
    # числа процессов он шёл 241 с на свободной машине и 703 с под нагрузкой.
    TEST_FILE_TIMEOUT="${TEST_FILE_TIMEOUT:-1800}"
fi

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
SUITE_RESULTS=()
# Suite, пропущенный ЦЕЛИКОМ (0 pass, 0 fail, >0 skip) — платформенный инструмент
# недоступен (cmd/powershell). Именно это ловит STRICT_SKIP (см. конец файла).
SUITES_FULLY_SKIPPED=0
FULLY_SKIPPED_NAMES=()

# ── Хелперы без форков ───────────────────────────────────────────────────────
# Результат — в глобальной переменной, а не через `$(...)`: на Windows каждый
# форк Git Bash стоит 30–250 мс (антивирус проверяет каждый процесс), и раннер
# с подстановками на каждый файл сам по себе ел заметную долю бюджета.

# NOW_MS ← текущее время в мс. EPOCHREALTIME есть с bash 5; системный bash 3.2 на
# macOS его не знает — там точность до секунды через date, для отчёта хватает.
now_ms() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        local t="${EPOCHREALTIME//[.,]/}"
        NOW_MS=$(( 10#$t / 1000 ))
    else
        NOW_MS=$(( $(date +%s) * 1000 ))
    fi
}

# FMT_S ← миллисекунды $1 в виде «12.3»
fmt_s() {
    printf -v FMT_S '%d.%d' $(( $1 / 1000 )) $(( ($1 % 1000) / 100 ))
}

# REL ← «<модуль>/<файл>.sh» для пути $1
rel_of() {
    local dir="${1%/*}"
    REL="${dir##*/}/${1##*/}"
}

# ── GNU timeout ──────────────────────────────────────────────────────────────
# Только coreutils: на Windows в PATH может оказаться C:\Windows\System32\timeout.exe
# (пауза cmd с другим синтаксисом), на macOS coreutils из brew ставит gtimeout.
# Нет ни одного — файлы идут без таймаута, и раннер говорит об этом явно.
find_timeout_bin() {
    local c
    for c in timeout gtimeout; do
        if "$c" --version 2>/dev/null | grep -q 'GNU coreutils'; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# ── Исполнение одного тест-файла ─────────────────────────────────────────────
# Пишет <prefix>.out (вывод), <prefix>.rc (код возврата), <prefix>.ms (время).
# Вывод — в файл, а не в `$(...)`: подстановка ждёт EOF канала, а осиротевший
# внук (powershell.exe) после снятия по таймауту держал бы канал открытым, и
# раннер висел бы дальше. stdin — /dev/null: чтение с терминала в фоновой
# группе процессов останавливало бы файл навсегда.
exec_suite() {
    local test_file="$1" prefix="$2" limit="${TEST_FILE_TIMEOUT:-1800}" t0 rc
    now_ms; t0=$NOW_MS
    if [ -n "${TIMEOUT_BIN:-}" ]; then
        "$TIMEOUT_BIN" -k 10 "$limit" bash "$test_file" > "$prefix.out" 2>&1 < /dev/null
    else
        bash "$test_file" > "$prefix.out" 2>&1 < /dev/null
    fi
    rc=$?
    now_ms
    echo "$rc" > "$prefix.rc"
    echo $(( NOW_MS - t0 )) > "$prefix.ms"
}

# ── Запуск одного тест-файла и учёт его итога ────────────────────────────────
# $2 — префикс файла, уже исполненного параллельно (быстрый уровень); без него файл
# исполняется здесь же.
run_suite() {
    local test_file="$1" prefix="${2:-}"
    local base="${test_file##*/}"
    local suite_name="${base%.sh}" rel
    rel_of "$test_file"; rel=$REL

    echo -e "\n${BOLD}${CYAN}▶ $suite_name${NC}"

    local output exit_code ms dur limit="${TEST_FILE_TIMEOUT:-1800}" own=0
    if [ -z "$prefix" ]; then
        prefix="${TMPDIR:-/tmp}/run_suite_$$_${RANDOM}${RANDOM}"
        own=1
        exec_suite "$test_file" "$prefix"
    fi
    read -r exit_code < "$prefix.rc"
    read -r ms < "$prefix.ms"
    LAST_MS=$ms
    fmt_s "$ms"; dur=$FMT_S
    output=$(< "$prefix.out")

    # Итог берём из machine-readable маркера framework (TESTS_RESULT pass=N fail=N skip=N),
    # а не из ✓/✗/○-глифов: те зависят от оформления, цветов и локали. Последний
    # маркер в выводе; разбор без grep-конвейеров — те стоили десяток форков на файл.
    local re='TESTS_RESULT pass=([0-9]+) fail=([0-9]+) skip=([0-9]+)'
    local line marker="" pass=0 fail=0 skip=0
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ $re ]]; then
            marker="${BASH_REMATCH[0]}"
            pass="${BASH_REMATCH[1]}"; fail="${BASH_REMATCH[2]}"; skip="${BASH_REMATCH[3]}"
        fi
    done < "$prefix.out"
    rm -f "$prefix.out" "$prefix.rc" "$prefix.ms"
    [ "$own" = "1" ] && rm -f "$prefix"

    echo "$output"
    echo "TESTS_DURATION ${dur}s $rel"

    # 124 — timeout послал TERM, 137 — пришлось добивать KILL. Время сверяем, чтобы
    # собственный `exit 124` файла не выдать за зависание.
    if [ -n "${TIMEOUT_BIN:-}" ] && { [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; } \
        && [ "$ms" -ge $(( limit * 1000 )) ]; then
        echo "TESTS_TIMEOUT $rel after=${limit}s"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name (снят по таймауту ${limit}s)")
        return
    fi

    # Маркер ОБЯЗАТЕЛЕН. Без него pass=fail=skip=0, и suite с rc=0 уходил в зелёную
    # ветку как «✓» — то есть одна забытая `summary` перед `exit 0` делала целый файл
    # невидимкой на всех линиях CI. Нарушителей сейчас нет (все ранние выходы PS1/CMD
    # тестов идут через summary), и правило существует ровно затем, чтобы так и осталось.
    if [ -z "$marker" ]; then
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name (нет маркера TESTS_RESULT: suite не вызвал summary)")
        return
    fi

    # STRICT_SKIP (Windows-CI и release-гейт) падает не только на ЦЕЛИКОМ пропущенном
    # suite, но и на частичных пропусках «инструмент не найден»: они означают, что
    # проверка не выполнялась, а не что она не нужна. Причины ищем в тексте вывода —
    # framework печатает их рядом с ○.
    if [ "${STRICT_SKIP:-0}" = "1" ] && [ "$skip" -gt 0 ]; then
        local why
        why=$(printf '%s' "$output" | grep -oE '○[^
]*(не найден|недоступен|не установлен|не был вызван)[^
]*' | head -3)
        if [ -n "$why" ]; then
            TOTAL_FAIL=$((TOTAL_FAIL + 1))
            SUITE_RESULTS+=("${RED}✗${NC} $suite_name (STRICT_SKIP: пропуск из-за отсутствующего инструмента)")
            TOTAL_PASS=$((TOTAL_PASS + pass))
            TOTAL_SKIP=$((TOTAL_SKIP + skip))
            return
        fi
    fi

    # Любой ненулевой rc обязан дать провал. Если fail>0 — он уже посчитан (summary
    # возвращает 1 именно из-за этих провалов, второй раз добавлять нельзя). Если
    # fail==0, то suite умер по иной причине: крах до/после summary, set -e, exit N.
    # Раньше здесь дополнительно требовалось pass==0, поэтому suite с успешными
    # assertions и последующим `exit 7` уходил в зелёную ветку.
    if [ "$exit_code" -ne 0 ] && [ "$fail" -eq 0 ]; then
        TOTAL_PASS=$((TOTAL_PASS + pass))
        TOTAL_SKIP=$((TOTAL_SKIP + skip))
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name (rc=$exit_code, assertions ok: $pass)")
        return
    fi

    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    # Полностью пропущенный suite (0/0/>0) = платформенный инструмент недоступен.
    if [ "$skip" -gt 0 ] && [ "$pass" -eq 0 ] && [ "$fail" -eq 0 ]; then
        SUITES_FULLY_SKIPPED=$((SUITES_FULLY_SKIPPED + 1))
        FULLY_SKIPPED_NAMES+=("$suite_name")
    fi

    if [ "$fail" -gt 0 ]; then
        SUITE_RESULTS+=("${RED}✗${NC} $suite_name ($fail failures, ${dur}s)")
    else
        SUITE_RESULTS+=("${GREEN}✓${NC} $suite_name (${dur}s)")
    fi
}

# ── Запуск, либо провал если зарегистрированный файл исчез ────────────────────
# Раньше: `[ -f "$f" ] && run_suite "$f"` — удалённый/переименованный тест молча
# пропадал из результата. Теперь отсутствие зарегистрированного файла = провал.
run_or_missing() {
    local test_file="$1"
    if [ -f "$test_file" ]; then
        run_suite "$test_file" "${2:-}"
    else
        local base="${test_file##*/}"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        SUITE_RESULTS+=("${RED}✗${NC} ${base%.sh} (файл отсутствует)")
    fi
}

# ── Уровни ───────────────────────────────────────────────────────────────────
# Быстрый уровень (--fast, бюджет 60 с) — ТОЛЬКО файлы из списка ниже: чистый Bash
# на заглушках и общие инварианты, без PowerShell/CMD/GUI. Отбор — по замеру, а не
# по признаку «нет PowerShell»: время набора определяло число процессов (форк Git
# Bash на Windows-машине разработки стоит 30–250 мс), и самыми долгими были как раз
# чисто Bash-евые файлы, дот-сорсящие production-скрипт десятки раз. После того как
# скрипты и фреймворк перестали плодить процессы (2026-10-01), они ужались в разы:
# ffmpeg/test_15 703 → ~95 с, guardrails 455 → 30–70 с, ffmpeg/test_21 371 → ~50 с,
# yt-dlp/test_07 280 → ~5 с, — и уровень вырос с 9 файлов до 16.
# Всё, что не в списке, — только полный уровень; новый файл тоже (бюджет быстрого
# уровня не срывается молча). Добавляя файл сюда — замерь его: раннер печатает
# TESTS_DURATION. Замер уровня целиком (2026-10-01, шесть дорожек, бюджет 60 с):
# 22–33 с при обычной фоновой нагрузке, 53 с при загрузке CPU посторонними
# процессами ~55 % — тогда самые долгие файлы идут втрое медленнее.
# Порядок — по убыванию времени: файлы раздаются по дорожкам параллели по кругу.
# Формат «<модуль>/<файл>.sh» без $TESTS_DIR: guardrail считает регистрации по
# строкам с `TESTS_DIR/<модуль>/`, и этот список их не задваивает.
FAST_LEVEL="
ffmpeg/test_06_gpu.sh
ffmpeg/test_19_findings_paths.sh
ffmpeg/test_18_findings_audit.sh
ffmpeg/test_01_config_sh.sh
ffmpeg/test_14_audio_only_codec.sh
common/test_docs_links.sh
common/test_config_contract.sh
yt-dlp/test_07_new_features.sh
common/test_config_keys.sh
common/test_encoding.sh
common/test_framework_selfcheck.sh
yt-dlp/test_10_archive_skip_parity.sh
yt-dlp/test_01_read_config.sh
yt-dlp/test_02_format_args.sh
ffmpeg/test_20_remote_map.sh
yt-dlp/test_03_cookie_args.sh
"

# Число параллельных дорожок быстрого уровня. Замер 2026-09-30 под нагрузкой:
# одна дорожка — 166 с, четыре — 119 с. Повторный замер 2026-10-01 (16 файлов, фоновая
# нагрузка): четыре — 38–57 с, шесть — 22–33 с, восемь — 28–38 с. На шести самые
# долгие файлы перестают делить дорожку; дальше выигрыша нет: узкое место — проверка
# антивирусом каждого нового процесса, а не CPU.
FAST_JOBS=6

is_fast_level() {
    rel_of "$1"
    case "$FAST_LEVEL" in
        *"
$REL
"*) return 0 ;;
    esac
    return 1
}

# Файл не входит в выбранный уровень (только полный, а идёт --fast)
skip_in_level() {
    [ "$FAST" = "1" ] && ! is_fast_level "$1"
}

# ── Определяем какие тесты запускать ─────────────────────────────────────────
FFMPEG_TESTS=(
    "$TESTS_DIR/ffmpeg/test_01_config_sh.sh"
    "$TESTS_DIR/ffmpeg/test_02_config_ps1.sh"
    "$TESTS_DIR/ffmpeg/test_03_audio_args.sh"
    "$TESTS_DIR/ffmpeg/test_04_video_args.sh"
    "$TESTS_DIR/ffmpeg/test_05_filters.sh"
    "$TESTS_DIR/ffmpeg/test_06_gpu.sh"
    "$TESTS_DIR/ffmpeg/test_07_integration.sh"
    "$TESTS_DIR/ffmpeg/test_08_ps1_audio_video.sh"
    "$TESTS_DIR/ffmpeg/test_09_ps1_filters_gpu.sh"
    "$TESTS_DIR/ffmpeg/test_10_cmd.sh"
    "$TESTS_DIR/ffmpeg/test_11_cmd_smoke.sh"
    "$TESTS_DIR/ffmpeg/test_12_cmd_run_parser.sh"
    "$TESTS_DIR/ffmpeg/test_13_parser_parity.sh"
    "$TESTS_DIR/ffmpeg/test_14_audio_only_codec.sh"
    "$TESTS_DIR/ffmpeg/test_15_findings.sh"
    "$TESTS_DIR/ffmpeg/test_16_gui_state.sh"
    "$TESTS_DIR/ffmpeg/test_17_literal_paths.sh"
    "$TESTS_DIR/ffmpeg/test_18_findings_audit.sh"
    "$TESTS_DIR/ffmpeg/test_19_findings_paths.sh"
    "$TESTS_DIR/ffmpeg/test_20_remote_map.sh"
    "$TESTS_DIR/ffmpeg/test_21_remote_client.sh"
    "$TESTS_DIR/ffmpeg/test_22_remote_ps1.sh"
    "$TESTS_DIR/ffmpeg/test_23_remote_parity.sh"
    "$TESTS_DIR/ffmpeg/test_24_gui_worker_runspace.sh"
    "$TESTS_DIR/ffmpeg/test_25_asr_client.sh"
    "$TESTS_DIR/ffmpeg/test_26_asr_ps1.sh"
    "$TESTS_DIR/ffmpeg/test_27_asr_parity.sh"
    "$TESTS_DIR/ffmpeg/test_28_asr_integration.sh"
)

YTDLP_TESTS=(
    "$TESTS_DIR/yt-dlp/test_01_read_config.sh"
    "$TESTS_DIR/yt-dlp/test_02_format_args.sh"
    "$TESTS_DIR/yt-dlp/test_03_cookie_args.sh"
    "$TESTS_DIR/yt-dlp/test_04_integration.sh"
    "$TESTS_DIR/yt-dlp/test_05_cmd.sh"
    "$TESTS_DIR/yt-dlp/test_06_ps1.sh"
    "$TESTS_DIR/yt-dlp/test_07_new_features.sh"
    "$TESTS_DIR/yt-dlp/test_08_findings.sh"
    "$TESTS_DIR/yt-dlp/test_09_speed_profile.sh"
    "$TESTS_DIR/yt-dlp/test_10_archive_skip_parity.sh"
    "$TESTS_DIR/yt-dlp/test_11_findings_f4_f15.sh"
    "$TESTS_DIR/yt-dlp/test_12_findings_cli.sh"
    "$TESTS_DIR/yt-dlp/test_13_path_limit.sh"
    "$TESTS_DIR/yt-dlp/test_14_stop_and_window.sh"
    "$TESTS_DIR/yt-dlp/test_15_cmd_smoke.sh"
)

# Кросс-платформенные инварианты (кодировки, паритет ключей config.ini, guardrail'ы)
COMMON_TESTS=(
    "$TESTS_DIR/common/test_framework_selfcheck.sh"
    "$TESTS_DIR/common/test_encoding.sh"
    "$TESTS_DIR/common/test_config_keys.sh"
    "$TESTS_DIR/common/test_config_contract.sh"
    "$TESTS_DIR/common/test_guardrails.sh"
    "$TESTS_DIR/common/test_docs_links.sh"
    "$TESTS_DIR/common/test_pre_commit_hook.sh"
    "$TESTS_DIR/common/test_privacy_scan.sh"
    "$TESTS_DIR/common/test_path_matrix.sh"
    "$TESTS_DIR/common/test_ytdlp_preset_parity.sh"
    "$TESTS_DIR/common/test_build_strip.sh"
)

# MOD_FILES ← файлы модуля $1, MOD_TITLE ← его заголовок (bash 3.2: без nameref).
module_files() {
    case "$1" in
        ffmpeg) MOD_FILES=("${FFMPEG_TESTS[@]}"); MOD_TITLE="FFmpeg Converter" ;;
        yt-dlp) MOD_FILES=("${YTDLP_TESTS[@]}"); MOD_TITLE="YT-DLP Downloader" ;;
        common) MOD_FILES=("${COMMON_TESTS[@]}"); MOD_TITLE="Общие инварианты" ;;
    esac
}

case "$FILTER" in
    ffmpeg|yt-dlp|common) MODULES=("$FILTER") ;;
    ytdlp) MODULES=(yt-dlp) ;;
    all) MODULES=(ffmpeg yt-dlp common) ;;
    *)
        # Опечатка в фильтре («commmon») раньше молча трактовалась как all: прогон
        # выглядел успешным, а запрошенный набор не запускался никогда.
        echo -e "${RED}Неизвестный фильтр: '$FILTER'${NC}"
        echo "Использование: bash tests/run_tests.sh [--fast] [--list] [all|ffmpeg|yt-dlp|common]"
        exit 2
        ;;
esac

if [ "$LIST" = "1" ]; then
    for _m in "${MODULES[@]}"; do
        module_files "$_m"
        for _f in "${MOD_FILES[@]}"; do
            skip_in_level "$_f" && continue
            rel_of "$_f"; echo "$REL"
        done
    done
    exit 0
fi

TIMEOUT_BIN=$(find_timeout_bin) || TIMEOUT_BIN=""

# Параллельно — только быстрый уровень: его файлы общих путей не пишут. В полном
# уровне это не так — tests/ffmpeg/config.ini пишут ffmpeg/test_01/02/13, а test_13
# ещё и подменяет рабочий ffmpeg/config.ini, который читает common/test_config_keys.
PARALLEL=0
[ "$FAST" = "1" ] && PARALLEL=1

LANE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/run_tests_XXXXXX")
LANE_PIDS=""
trap 'rm -rf "$LANE_DIR"' EXIT
trap '[ -n "$LANE_PIDS" ] && kill $LANE_PIDS 2>/dev/null; exit 130' INT TERM

# ── Баннер ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════╗"
echo "║          Система тестирования видео-скриптов     ║"
echo "║          ffmpeg converter + yt-dlp downloader    ║"
echo "╚══════════════════════════════════════════════════╝"
echo -e "${NC}"
if [ "$FAST" = "1" ]; then
    echo -e "${BOLD}Уровень: быстрый (--fast)${NC} — файлы из FAST_LEVEL, дорожек: $FAST_JOBS; вывод — после завершения всех"
else
    echo -e "${BOLD}Уровень: полный${NC}"
fi
if [ -n "$TIMEOUT_BIN" ]; then
    echo "Таймаут на файл: ${TEST_FILE_TIMEOUT}s"
else
    echo -e "${YELLOW}GNU timeout не найден — файлы идут без таймаута${NC}"
fi

now_ms; RUN_T0=$NOW_MS

# ── Параллельное исполнение (итог учитывается ниже, в порядке регистрации) ──
# Файлы раздаются по дорожкам по кругу в порядке FAST_LEVEL (он по убыванию
# времени), каждая дорожка исполняет свои последовательно.
if [ "$PARALLEL" = "1" ]; then
    mkdir -p "$LANE_DIR/ffmpeg" "$LANE_DIR/yt-dlp" "$LANE_DIR/common"
    _sel=" ${MODULES[*]} "
    _lane_files=()
    _i=0
    for _rel in $FAST_LEVEL; do
        case "$_sel" in *" ${_rel%%/*} "*) ;; *) continue ;; esac
        [ -f "$TESTS_DIR/$_rel" ] || continue
        _l=$(( _i % FAST_JOBS ))
        _lane_files[_l]="${_lane_files[_l]:-} $_rel"
        _i=$((_i + 1))
    done
    for _l in "${!_lane_files[@]}"; do
        (
            for _rel in ${_lane_files[$_l]}; do
                exec_suite "$TESTS_DIR/$_rel" "$LANE_DIR/${_rel%.sh}"
            done
        ) &
        LANE_PIDS="$LANE_PIDS $!"
    done
    wait
    LANE_PIDS=""
fi

# ── Запуск тестов / учёт итогов ──────────────────────────────────────────────
# Время модуля — в человеческой строке; маркер TESTS_DURATION — только у файлов:
# свип берёт пять самых долгих, и суммы модулей вытеснили бы из пятёрки сами файлы.
_first=1
for _m in "${MODULES[@]}"; do
    module_files "$_m"
    [ "$_first" = "1" ] || echo ""
    _first=0
    echo -e "${BOLD}Модуль: $MOD_TITLE${NC}"
    now_ms; _t0=$NOW_MS
    _n_full=0
    _sum_ms=0
    for _f in "${MOD_FILES[@]}"; do
        if skip_in_level "$_f"; then
            _n_full=$((_n_full + 1))
            continue
        fi
        LAST_MS=0
        if [ "$PARALLEL" = "1" ]; then
            rel_of "$_f"
            run_or_missing "$_f" "$LANE_DIR/${REL%.sh}"
        else
            run_or_missing "$_f"
        fi
        _sum_ms=$((_sum_ms + LAST_MS))
    done
    if [ "$PARALLEL" = "1" ]; then
        fmt_s "$_sum_ms"
        echo -e "
${BOLD}⏱ Модуль $_m: ${FMT_S}s (сумма времени файлов; шли параллельно)${NC}"
    else
        now_ms; fmt_s $(( NOW_MS - _t0 ))
        echo -e "
${BOLD}⏱ Модуль $_m: ${FMT_S}s${NC}"
    fi
    [ "$_n_full" -gt 0 ] && echo -e "${YELLOW}  Только в полном уровне (не запускались): $_n_full файл(ов)${NC}"
done

# ── Итоговый отчёт ───────────────────────────────────────────────────────────
TOTAL=$((TOTAL_PASS + TOTAL_FAIL + TOTAL_SKIP))
now_ms; fmt_s $(( NOW_MS - RUN_T0 ))

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║                 ИТОГОВЫЙ ОТЧЁТ                  ║${NC}"
echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════╣${NC}"

for result in "${SUITE_RESULTS[@]}"; do
    echo -e "║  ${result}${NC}"
done

echo -e "${BOLD}${CYAN}╠══════════════════════════════════════════════════╣${NC}"
echo -e "${BOLD}${CYAN}║${NC}  Всего: $TOTAL  |  ${GREEN}✓ $TOTAL_PASS пройдено${NC}  |  ${RED}✗ $TOTAL_FAIL провалено${NC}  |  ${YELLOW}○ $TOTAL_SKIP пропущено${NC}  |  ⏱ ${FMT_S}s"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"

# Итог всего прогона для внешнего свипа. Строки TESTS_RESULT отдельных файлов выше
# тоже есть в выводе — свип берёт ПОСЛЕДНЮЮ, поэтому эта печатается после них.
echo "TESTS_RESULT pass=$TOTAL_PASS fail=$TOTAL_FAIL skip=$TOTAL_SKIP"

# STRICT_SKIP=1 (Windows CI): ошибка, только если suite пропущен ЦЕЛИКОМ (cmd/powershell
# недоступен → теряется SH/CMD/PS1 паритет). Частичные окружения-скипы внутри запущенного
# suite'а (напр. интеграционный тест без реального ffmpeg) — допустимы. На Linux переменную
# не выставляют: там CMD/PS1 suite'ы ожидаемо пропускаются целиком.
if [ "${STRICT_SKIP:-0}" = "1" ] && [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}STRICT_SKIP: $SUITES_FULLY_SKIPPED suite(ов) пропущено целиком (нет cmd/powershell): ${FULLY_SKIPPED_NAMES[*]}${NC}"
    exit 1
fi

if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo -e "\n${RED}${BOLD}ПРОВАЛЕНО: $TOTAL_FAIL тест(ов)${NC}"
    exit 1
elif [ "$TOTAL_SKIP" -gt 0 ] || [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
    # «ВСЕ ТЕСТЫ ПРОЙДЕНЫ» при пропусках — это ложное успокоение: на WSL/Linux
    # PS1/CMD-suite'ы пропускаются целиком, и та же строка означала «проверено всё»,
    # хотя половина платформ не запускалась вовсе. Пройдено ≠ проверено.
    echo -e "\n${GREEN}${BOLD}ПРОВАЛОВ НЕТ${NC}${YELLOW} — но проверено НЕ всё${NC}"
    [ "$TOTAL_SKIP" -gt 0 ] && echo -e "${YELLOW}  Пропущено тестов: $TOTAL_SKIP${NC}"
    if [ "$SUITES_FULLY_SKIPPED" -gt 0 ]; then
        echo -e "${YELLOW}  Suite'ов пропущено целиком: $SUITES_FULLY_SKIPPED — ${FULLY_SKIPPED_NAMES[*]}${NC}"
        echo -e "${YELLOW}  Требуется полное покрытие? Запустите с STRICT_SKIP=1 (нужны cmd + powershell).${NC}"
    fi
    exit 0
else
    echo -e "\n${GREEN}${BOLD}ВСЕ ТЕСТЫ ПРОЙДЕНЫ${NC}"
    exit 0
fi
