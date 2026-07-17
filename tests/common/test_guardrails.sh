#!/bin/bash
# ============================================================
# test_guardrails.sh — статические guardrail'ы (read-only grep по исходникам).
# Ловят повторное появление опасных паттернов ДО ревью: ручная сборка argv-строки,
# temp-dir на %RANDOM%, бинарь без резолвинга рядом со скриптом, отключение TLS и т.п.
# Чистый bash, без PowerShell/cmd — идёт на любой платформе.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
YT_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
FF_CMD="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"

ps1="$(cat "$YT_PS1")"
ycmd="$(cat "$YT_CMD")"
ysh="$(cat "$YT_SH")"
ffcmd="$(cat "$FF_CMD")"

# ── yt-dlp PS1: единый argv-квотер, не ручная сборка строки ────────────────
suite "guardrails: yt-dlp PS1 argv/квотирование"
assert_not_contains "нет ручного \$command -join (argv)"  '$command -join'  "$ps1"
assert_contains "Quote-WinArg присутствует"               "function Quote-WinArg"  "$ps1"
assert_contains "Join-WinArgs присутствует"               "function Join-WinArgs"  "$ps1"
# ffmpeg для мержа — через резолвер \$ffmpegBin, не bare `& ffmpeg`.
assert_not_contains "нет bare '& ffmpeg @ffArgs'"         '& ffmpeg @ffArgs'  "$ps1"
assert_contains "мерж через \$ffmpegBin"                  '& $ffmpegBin @ffArgs'  "$ps1"

# ── yt-dlp CMD: GUID temp-dir, резолвер ffmpeg ────────────────────────────
suite "guardrails: yt-dlp CMD temp-dir/ffmpeg"
assert_contains "temp-dir через GUID (не голый %RANDOM%)"  "[guid]::NewGuid"  "$ycmd"
assert_contains "ffmpeg-резолвер (рядом со скриптом)"     '%~dp0ffmpeg.exe'  "$ycmd"
assert_contains "мерж через !ff_cmd!"                     '"!ff_cmd!" -y'  "$ycmd"

# ── ffmpeg CMD: детект имён с '!' ─────────────────────────────────────────
suite "guardrails: ffmpeg CMD '!'-детект"
assert_contains "подпрограмма :warn_bang_names"           ":warn_bang_names"  "$ffcmd"
assert_contains "вызов детекта перед циклом"              "call :warn_bang_names"  "$ffcmd"

# ── Security-инварианты (все yt-dlp платформы) ────────────────────────────
suite "guardrails: security"
assert_not_contains "PS1: нет --no-check-certificate"     "--no-check-certificate"  "$ps1"
assert_not_contains "CMD: нет --no-check-certificate"     "--no-check-certificate"  "$ycmd"
assert_not_contains "SH: нет --no-check-certificate"      "--no-check-certificate"  "$ysh"
# TLS отключается только для vot-cli-live и ОБЯЗАТЕЛЬНО сбрасывается назад.
assert_contains "CMD: NODE_TLS сбрасывается"              'set "NODE_TLS_REJECT_UNAUTHORIZED="'  "$ycmd"

# ── yt-dlp PS1: подписки событий чистятся и на пути исключения (finally) ───
# Register-ObjectEvent создаётся на каждый URL. Штатная очистка живёт в цикле,
# но при исключении между Register и очисткой (напр. Start() без yt-dlp.exe)
# управление ушло бы в catch/finally — поэтому те же Unregister-Event должны
# присутствовать ВТОРОЙ раз в finally (belt-and-suspenders), иначе подписки и
# PSEventJob текут до закрытия GUI.
suite "guardrails: yt-dlp PS1 event-leak (cleanup в finally)"
n_out=$(printf '%s\n' "$ps1" | grep -cF -- 'Unregister-Event -SourceIdentifier $evtOut.Name')
n_err=$(printf '%s\n' "$ps1" | grep -cF -- 'Unregister-Event -SourceIdentifier $evtErr.Name')
assert_eq "evtOut: очистка и в цикле, и в finally"  "2"  "$n_out"
assert_eq "evtErr: очистка и в цикле, и в finally"  "2"  "$n_err"

# ══════════════════════════════════════════════════════════════
suite "Runner не маскирует ненулевой exit suite"
# ══════════════════════════════════════════════════════════════
# Вызываем НАСТОЯЩУЮ run_suite, вырезанную из run_tests.sh: инлайн-копия логики
# подсчёта проходила бы, даже если продакшн-runner снова начнёт врать.
RUNNER="$TESTS_DIR/run_tests.sh"
RUN_SUITE_SRC=$(sed -n '/^run_suite() {/,/^}/p' "$RUNNER")
if [ -z "$RUN_SUITE_SRC" ]; then
    fail "run_suite найдена в run_tests.sh" "найдена" "не найдена"
fi

# Прогоняет один временный suite через настоящую run_suite и печатает итог счётчиков.
probe_runner() {
    local body="$1"
    (
        TMPD=$(mktemp -d /tmp/rs_probe_XXXXXX)
        printf '#!/bin/bash\nsource "%s/lib/framework.sh"\n%s\n' "$TESTS_DIR" "$body" > "$TMPD/probe.sh"
        RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
        TOTAL_PASS=0; TOTAL_FAIL=0; TOTAL_SKIP=0
        SUITE_RESULTS=(); SUITES_FULLY_SKIPPED=0; FULLY_SKIPPED_NAMES=()
        eval "$RUN_SUITE_SRC"
        run_suite "$TMPD/probe.sh" > /dev/null 2>&1
        echo "pass=$TOTAL_PASS fail=$TOTAL_FAIL"
        rm -rf "$TMPD"
    )
}

# Суть находки: assertions прошли, summary напечатан, но suite умер с exit 7.
r=$(probe_runner 'suite "x"; pass "a"; pass "b"
summary
exit 7')
assert_contains "exit 7 после успешного summary → провал" "fail=1" "$r"
assert_contains "exit 7: успешные assertions не потеряны"  "pass=2" "$r"

# Настоящие провалы не должны задваиваться: summary сам возвращает 1 из-за них.
r=$(probe_runner 'suite "x"; pass "a"; fail "b" "ожид" "получ"
summary')
assert_contains "реальный провал считается один раз (без +1 за rc)" "fail=1" "$r"

# Чистый suite остаётся зелёным.
r=$(probe_runner 'suite "x"; pass "a"; pass "b"
summary')
assert_contains "чистый suite → нет провалов" "fail=0" "$r"

# Крах ДО summary (маркера нет вообще) — тоже провал.
r=$(probe_runner 'suite "x"; pass "a"
exit 3')
assert_contains "крах до summary → провал" "fail=1" "$r"

# ══════════════════════════════════════════════════════════════
suite "Сетевой guard: тесты не имеют права ходить в сеть"
# ══════════════════════════════════════════════════════════════
# Суть находки: у YTDLP_BIN был env-override «для тестов», а у VOT_BIN его не было —
# check_translate_deps безусловно перезатирал переменную бинарём рядом со скриптом.
# Тест перевода запустил настоящий vot-cli-live и ~22 секунды ходил во внешний сервис.
# Ниже — три уровня защиты, чтобы это не вернулось незамеченным.

# 1. Каждый внешний бинарь обязан иметь env-override, иначе тест не сможет его подменить.
assert_contains "yt-dlp SH: YTDLP_BIN перекрывается из окружения" 'resolve_bin "${YTDLP_BIN:-}" yt-dlp' "$ysh"
assert_contains "yt-dlp SH: VOT_BIN перекрывается из окружения"   'if [ -n "${VOT_BIN:-}" ]; then'      "$ysh"
# Override обязан стоять ПЕРВЫМ в цепочке резолва: если сначала берётся бинарь рядом
# со скриптом, переменная будет перезатёрта и override уже ничего не решит.
vot_ov_ln=$(grep -n 'if \[ -n "${VOT_BIN:-}" \]; then' "$YT_SH" | head -1 | cut -d: -f1)
vot_sd_ln=$(grep -n 'script_dir/vot-cli-live' "$YT_SH" | head -1 | cut -d: -f1)
if [ -n "$vot_ov_ln" ] && [ -n "$vot_sd_ln" ] && [ "$vot_ov_ln" -lt "$vot_sd_ln" ]; then
    pass "yt-dlp SH: VOT_BIN override проверяется ДО бинаря рядом со скриптом"
else
    fail "yt-dlp SH: VOT_BIN override проверяется первым" "override раньше script_dir" "override=$vot_ov_ln script_dir=$vot_sd_ln"
fi

# 2. Deny-stub в tests/mocks перехватывает резолв через PATH и падает громко.
VOT_STUB="$TESTS_DIR/mocks/vot-cli-live"
assert_file_exists "deny-stub vot-cli-live лежит в tests/mocks" "$VOT_STUB"
if [ -x "$VOT_STUB" ]; then pass "deny-stub исполняемый"; else fail "deny-stub исполняемый" "+x" "нет"; fi
stub_rc=0; stub_out=$("$VOT_STUB" --output=/dev/null "https://example.com" 2>&1) || stub_rc=$?
assert_eq       "deny-stub падает вместо сетевого вызова" "97" "$stub_rc"
assert_contains "deny-stub объясняет причину"             "СЕТЕВОЙ GUARD" "$stub_out"

# 3. Ни один тест не имеет права звать сетевые бинари напрямую по имени.
#    (Настоящий vot-cli-live/curl/wget мимо мока — это и есть выход в сеть.)
net_offenders=""
for _t in "$TESTS_DIR"/ffmpeg/*.sh "$TESTS_DIR"/yt-dlp/*.sh "$TESTS_DIR"/common/*.sh; do
    [ -f "$_t" ] || continue
    case "$(basename "$_t")" in test_guardrails.sh) continue ;; esac
    # Ищем вызов команды в начале строки/после ; или && — не упоминание в строке/комментарии.
    if grep -qE '(^|[;&|]|\$\()[[:space:]]*(vot-cli-live|curl|wget)[[:space:]]' "$_t" 2>/dev/null; then
        net_offenders="$net_offenders $(basename "$_t")"
    fi
done
assert_empty "ни один тест не зовёт сетевые бинари напрямую" "$net_offenders"

# ══════════════════════════════════════════════════════════════
suite "Тесты не держат собственных копий production-функций"
# ══════════════════════════════════════════════════════════════
# Суть находки: тесты переопределяли у себя функции production и проверяли КОПИЮ.
# Копии тихо расходились с оригиналом, и расхождение работало в обе стороны:
#   • yt-dlp read_config — копия резала значение по любому '#' (старый жадный regex),
#     то есть закрепляла баг, который production уже исправил;
#   • yt-dlp build_cookie_args — копия собирала argv СТРОКОЙ с кавычками, хотя
#     production давно перешёл на массив (строчный билдер запрещён guardrail'ом выше);
#   • ffmpeg read_config — в копии не было подстановки ${ENV_VAR} вовсе.
# Во всех трёх случаях production можно было сломать при зелёных тестах. Проверка ниже
# не даёт копиям вернуться: тест обязан дот-сорсить production (main гардится
# BASH_SOURCE) или вырезать нужный кусок из настоящего файла.
PROD_FUNCS="read_config to_flag build_cookie_args build_format_args detect_platform resolve_bin canon_path manifest_is_complete manifest_write partial_path"
copy_offenders=""
for _t in "$TESTS_DIR"/ffmpeg/test_*.sh "$TESTS_DIR"/yt-dlp/test_*.sh "$TESTS_DIR"/common/test_*.sh; do
    [ -f "$_t" ] || continue
    case "$(basename "$_t")" in test_guardrails.sh) continue ;; esac
    for _fn in $PROD_FUNCS; do
        # Определение функции в тесте: `name() {` или `function name`.
        if grep -qE "^[[:space:]]*(function[[:space:]]+)?${_fn}[[:space:]]*\(\)[[:space:]]*\{" "$_t" 2>/dev/null; then
            copy_offenders="$copy_offenders $(basename "$_t"):${_fn}"
        fi
    done
done
assert_empty "ни один тест не переопределяет production-функцию" "$copy_offenders"

# Тесты, разбирающие config.ini, обязаны брать парсер из production, а не свой.
for _pair in "ffmpeg/test_01_config_sh.sh:ffmpeg/FFmpeg_Converter_run_v15.sh" \
             "yt-dlp/test_01_read_config.sh:yt-dlp/Downloading_from_YouTube_v15.sh" \
             "yt-dlp/test_03_cookie_args.sh:yt-dlp/Downloading_from_YouTube_v15.sh"; do
    _tf="${_pair%%:*}"; _pf="${_pair#*:}"
    if grep -q "$(basename "$_pf")" "$TESTS_DIR/$_tf" 2>/dev/null; then
        pass "$(basename "$_tf") ссылается на настоящий $(basename "$_pf")"
    else
        fail "$(basename "$_tf") ссылается на настоящий $(basename "$_pf")" "дот-сорсинг production" "ссылки нет"
    fi
done

# Обе точки входа обязаны иметь main-гард, иначе дот-сорсинг запустит конвейер.
for _g in "ffmpeg/FFmpeg_Converter_run_v15.sh" "yt-dlp/Downloading_from_YouTube_v15.sh"; do
    if grep -qE '\[ "\$\{BASH_SOURCE\[0\]\}" = "\$\{?0\}?" \]' "$PROJECT_DIR/$_g" 2>/dev/null; then
        pass "$(basename "$_g"): main-гард на месте (дот-сорсинг безопасен)"
    else
        fail "$(basename "$_g"): main-гард на месте" 'if [ "${BASH_SOURCE[0]}" = "$0" ]' "гарда нет — дот-сорсинг запустит конвейер"
    fi
done

# Ссылки на исчезнувшие версии: тест на v11 молча «проверял» несуществующий файл.
stale_refs=""
for _t in "$TESTS_DIR"/ffmpeg/test_*.sh "$TESTS_DIR"/yt-dlp/test_*.sh "$TESTS_DIR"/common/test_*.sh; do
    [ -f "$_t" ] || continue
    case "$(basename "$_t")" in test_guardrails.sh) continue ;; esac
    if grep -qE '_v1[0-4]\.(sh|ps1|cmd)' "$_t" 2>/dev/null; then
        stale_refs="$stale_refs $(basename "$_t")"
    fi
done
assert_empty "нет ссылок на устаревшие версии скриптов (v11..v14)" "$stale_refs"

# ══════════════════════════════════════════════════════════════
suite "Допустимые значения config.ini задокументированы"
# ══════════════════════════════════════════════════════════════
# Находка: `default_quality = audio` работал, но config.ini.example перечислял только
# 360..2160 — пользователь не мог узнать о валидном значении. Единственный источник
# истины — validate_enum в SH; example обязан перечислять ровно его значения.
YT_EXAMPLE="$PROJECT_DIR/yt-dlp/config.ini.example"
quality_enum=$(grep -oE 'validate_enum "\$1" "\$2" [0-9a-z ]+' "$YT_SH" 2>/dev/null | head -1 | sed 's/.*"\$2" //')
if [ -z "$quality_enum" ]; then
    fail "enum качества найден в production SH" "validate_enum со списком" "не найден"
else
    quality_doc=$(grep -A1 '^# Качество по умолчанию' "$YT_EXAMPLE" 2>/dev/null | head -2)
    missing=""
    for _v in $quality_enum; do
        case "$quality_doc" in *"$_v"*) ;; *) missing="$missing $_v" ;; esac
    done
    assert_empty "все значения --quality перечислены в config.ini.example" "$missing"
fi

summary
