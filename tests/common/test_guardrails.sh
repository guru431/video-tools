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

summary
