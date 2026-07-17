#!/bin/bash
# ============================================================
# test_13_parser_parity.sh — Кросс-парсерный паритет config.ini
# Прогоняет ОДИН и тот же каверзный config.ini через два парсера
# (SH read_config и PS1 Read-Config) и проверяет, что вывод идентичен.
# Каверзные строки: значение с '=' внутри, инлайн ' # комментарий',
# key#notcomment, ведущие/хвостовые пробелы, ссылка ${VAR}.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── ОБЕ стороны — настоящие парсеры из production ───────────────────────────
# Раньше здесь лежали ДВЕ inline-копии, и «тест паритета» сравнивал копию с копией:
# о production он не знал ничего и расхождение SH↔PS1 обнаружить не мог в принципе.
# Хуже того, копии закрепляли ложное утверждение: тест уверял, что ffmpeg-парсер не
# делает подстановку ${VAR} и оставляет её литералом. Оба production-парсера её делают.
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RUN_SH="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v15.sh"
RUN_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v15.ps1"
for _f in "$RUN_SH" "$RUN_PS1"; do
    if [ ! -f "$_f" ]; then
        suite "Кросс-парсерный паритет"
        fail "production-скрипт на месте" "$_f" "файл не найден — тест сравнивал бы копии, а не production"
        summary
        exit 1
    fi
done
source "$RUN_SH"

# ── PS1-сторона: настоящая Read-Config из run_v15.ps1 ──────────────────────
HAVE_PS1=true
PS_CMD="powershell"
if command -v pwsh &>/dev/null; then
    PS_CMD="pwsh"
elif ! command -v powershell &>/dev/null; then
    HAVE_PS1=false
fi
RUN_PS1_WIN=$(cygpath -w "$RUN_PS1" 2>/dev/null || echo "$RUN_PS1")

# $env:FFCONV_TEST=1 — гард в run_v15.ps1: дот-сорсим только определения, конвейер
# не запускаем (паритет с SH-гардом BASH_SOURCE == $0).
run_ps1_readconfig() {
    local cfg_win="$1"
    local key="$2"
    local section="$3"
    local default="$4"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$env:FFCONV_TEST = '1'
. '$RUN_PS1_WIN'
\$configFile = '$cfg_win'
Read-Config '$key' '$section' '$default'
" 2>/dev/null | tr -d '\r'
}

# ── Единый каверзный config.ini (одинарные кавычки → ${VAR} не раскрывается) ─
CONFIG_FILE="$MY_DIR/config.ini"
cat > "$CONFIG_FILE" << 'EOCONFIG'
[tricky]
embed_eq = a=b=c
inline_cmt = value # это инлайн-комментарий
hash_val = my#file.log
spaced    =    trimmed
var_ref = ${MY_PARITY_VAR}/sub
EOCONFIG

CFG_WIN=$(cygpath -w "$CONFIG_FILE" 2>/dev/null || echo "$CONFIG_FILE")

# Задаём ДО сравнения: обе стороны должны подставить значение, а не предупреждать.
# Незаданная переменная — отдельный случай ниже: там расходятся ПОТОКИ (SH пишет WARN
# в stderr, PS1 — через Write-Host на консоль), и сравнивать stdout процессов там
# бессмысленно. В production это безвредно: `$x = Read-Config ...` берёт только
# возвращаемое значение, вывод Write-Host в конвейер не попадает.
# Значение намеренно НЕ похоже на путь: Git Bash (MSYS) переписывает POSIX-пути в
# Windows-вид при передаче в нативный процесс, и `/mnt/data` доехало бы до PowerShell
# как `C:/Program Files/Git/mnt/data` — тест ловил бы MSYS, а не расхождение парсеров.
export MY_PARITY_VAR="parity-val-42"

# ── Ключи для сравнения ──────────────────────────────────────────────────────
KEYS=(embed_eq inline_cmt hash_val spaced var_ref)

# ══════════════════════════════════════════════════════════════
suite "Кросс-парсерный паритет: SH read_config vs PS1 Read-Config"
# ══════════════════════════════════════════════════════════════

if [ "$HAVE_PS1" != true ]; then
    skip "Паритет SH↔PS1" "PowerShell не найден"
    summary
    exit 0
fi

for k in "${KEYS[@]}"; do
    sh_val=$(read_config "$k" "tricky" "__MISS__")
    ps1_val=$(run_ps1_readconfig "$CFG_WIN" "$k" "tricky" "__MISS__")
    assert_eq "паритет '$k': SH == PS1"  "$sh_val"  "$ps1_val"
done

# ── Дополнительно: фиксируем сами ожидаемые значения (детерминизм) ───────────
# Значение с '=' внутри сохраняется целиком.
assert_eq "embed_eq: значение с '=' целиком"   "a=b=c"  "$(read_config embed_eq tricky '')"
# Инлайн ' # …' срезается.
assert_eq "inline_cmt: ' #' срезан"            "value"  "$(read_config inline_cmt tricky '')"
# '#' без пробела слева — часть значения.
assert_eq "hash_val: my#file.log целиком"      "my#file.log"  "$(read_config hash_val tricky '')"
# Ведущие/хвостовые пробелы убраны.
assert_eq "spaced: пробелы обрезаны"           "trimmed"  "$(read_config spaced tricky '')"
# ${VAR} ПОДСТАВЛЯЕТСЯ из окружения. Прежний тест утверждал обратное — «остаётся
# литералом, ffmpeg-парсер не делает подстановку», — и это утверждение держалось
# только потому, что проверялась inline-копия без этой ветки. Оба production-парсера
# (SH и PS1) подстановку делают, так что тест закреплял ложь о собственном коде.
assert_eq "var_ref: \${VAR} подставлена из окружения" "parity-val-42/sub" "$(read_config var_ref tricky '')"

# Незаданная переменная → пустая подстановка + предупреждение (значение не остаётся
# литералом ${...}, иначе оно уехало бы в ffmpeg как имя каталога).
unset MY_PARITY_VAR
assert_eq "var_ref: незаданная \${VAR} → пусто, не литерал" "/sub" "$(read_config var_ref tricky '' 2>/dev/null)"
assert_contains "var_ref: незаданная \${VAR} → WARN" "MY_PARITY_VAR не задана" "$(read_config var_ref tricky '' 2>&1 >/dev/null)"
export MY_PARITY_VAR="parity-val-42"

# ══════════════════════════════════════════════════════════════
suite "F28: относительный log_file резолвится от папки скрипта"
# ══════════════════════════════════════════════════════════════
# Контракт (CLAUDE.md): относительные пути config.ini считаются от папки скрипта.
# source/destination так и делали, а log_file оставался относительно cwd процесса —
# запуск из другого каталога (ярлык, планировщик) уносил лог в случайное место.
# В репозиторном config.ini log_file задан относительным, поэтому после резолвинга
# он обязан стать абсолютным и лежать рядом со скриптом.
FF_DIR="$PROJECT_DIR/ffmpeg"

# SH: $log_file уже посчитан при source "$RUN_SH" выше (конвейер под main-гардом).
case "$log_file" in
    /*|[A-Za-z]:*) pass "SH: log_file абсолютный" ;;
    *) fail "SH: log_file абсолютный" "абсолютный путь" "$log_file" ;;
esac
assert_contains "SH: log_file указывает в папку скрипта" "ffmpeg" "$log_file"

# PS1: тот же гард FFCONV_TEST, что и для Read-Config выше.
if [ "$HAVE_PS1" = true ]; then
    ps1_log=$($PS_CMD -NoProfile -NonInteractive -Command "
\$env:FFCONV_TEST = '1'
. '$RUN_PS1_WIN'
Write-Output \$log_file
" 2>/dev/null | tr -d '\r' | tail -1)
    case "$ps1_log" in
        /*|[A-Za-z]:*) pass "PS1: log_file абсолютный" ;;
        *) fail "PS1: log_file абсолютный" "абсолютный путь" "$ps1_log" ;;
    esac
else
    skip "PS1: log_file абсолютный" "PowerShell не найден"
fi

# CMD: штатный хук --print-config печатает разобранные переменные и выходит.
if cmd //c "exit 0" &>/dev/null; then
    # Полный windows-путь: cmd //c не наследует cwd bash-субоболочки.
    RUN_CMD_WIN=$(cygpath -w "$FF_DIR/FFmpeg_Converter_run_v15.cmd" 2>/dev/null || echo "$FF_DIR/FFmpeg_Converter_run_v15.cmd")
    cmd_log=$(cmd //c "$RUN_CMD_WIN --print-config" 2>/dev/null | tr -d '\r' | grep '^log_file=' | head -1 | sed 's/^log_file=//')
    case "$cmd_log" in
        /*|[A-Za-z]:*) pass "CMD: log_file абсолютный" ;;
        *) fail "CMD: log_file абсолютный" "абсолютный путь" "$cmd_log" ;;
    esac
else
    skip "CMD: log_file абсолютный" "cmd.exe не доступен"
fi

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$CONFIG_FILE"

summary
