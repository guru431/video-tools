#!/bin/bash
# Обратное направление той же связки: часть переменных приходит из дот-сорснутого
# скрипта, присваивания в тесте нет (SC2154).
# Путь к дот-сорсимому скрипту вычисляется в рантайме — следовать за `source`
# статический анализатор не может по определению (SC1090).
# shellcheck disable=SC1090,SC2154
# ============================================================
# test_13_parser_parity.sh — Кросс-парсерный паритет config.ini
# Прогоняет ОДИН и тот же каверзный config.ini через два парсера
# (SH read_config и PS1 Read-Config) и проверяет, что вывод идентичен.
# Каверзные строки: значение с '=' внутри, инлайн ' # комментарий',
# key#notcomment, ведущие/хвостовые пробелы, ссылка ${VAR}.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── ОБЕ стороны — настоящие парсеры из production ───────────────────────────
# Раньше здесь лежали ДВЕ inline-копии, и «тест паритета» сравнивал копию с копией:
# о production он не знал ничего и расхождение SH↔PS1 обнаружить не мог в принципе.
# Хуже того, копии закрепляли ложное утверждение: тест уверял, что ffmpeg-парсер не
# делает подстановку ${VAR} и оставляет её литералом. Оба production-парсера её делают.
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RUN_SH="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v20.sh"
RUN_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v20.ps1"
for _f in "$RUN_SH" "$RUN_PS1"; do
    if [ ! -f "$_f" ]; then
        suite "Кросс-парсерный паритет"
        fail "production-скрипт на месте" "$_f" "файл не найден — тест сравнивал бы копии, а не production"
        summary
        exit 1
    fi
done
source "$RUN_SH"

# ── PS1-сторона: настоящая Read-Config из run_v20.ps1 ──────────────────────
HAVE_PS1=true
PS_CMD="powershell"
if command -v pwsh &>/dev/null; then
    PS_CMD="pwsh"
elif ! command -v powershell &>/dev/null; then
    HAVE_PS1=false
fi
RUN_PS1_WIN=$(cygpath -w "$RUN_PS1" 2>/dev/null || echo "$RUN_PS1")

# $env:FFCONV_TEST=1 — гард в run_v20.ps1: дот-сорсим только определения, конвейер
# не запускаем (паритет с SH-гардом BASH_SOURCE == $0).
# 6>$null: WARN разбора PS1 печатает через Write-Host (информационный поток), а
# файл разбирается целиком при первом вызове — без этого WARN про ЛЮБОЙ ключ
# с недопустимым именем смешивался бы с возвращаемым значением каждого ключа.
run_ps1_readconfig() {
    local cfg_win="$1"
    local key="$2"
    local section="$3"
    local default="$4"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$env:FFCONV_TEST = '1'
. '$RUN_PS1_WIN'
\$configFile = '$cfg_win'
Read-Config '$key' '$section' '$default' 6>\$null
" 2>/dev/null | tr -d '\r'
}

# ── Единый каверзный config.ini (одинарные кавычки → ${VAR} не раскрывается) ─
# Всё пишется во временный каталог, а не в репозиторий: парсерам путь задаётся явно
# (CONFIG_FILE / $configFile). Прежде config.ini лежал рядом с тестом, и прерванный
# прогон оставлял его в рабочем дереве — ночной auto-commit подобрал этот артефакт
# как исходник. Уборка — через trap, а не только в конце файла.
CFG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/test_parity_XXXXXX")"
trap 'rm -rf "$CFG_DIR"' EXIT
CONFIG_FILE="$CFG_DIR/config.ini"
cat > "$CONFIG_FILE" << 'EOCONFIG'
[tricky]
embed_eq = a=b=c
inline_cmt = value # это инлайн-комментарий
hash_val = my#file.log
spaced    =    trimmed
var_ref = ${MY_PARITY_VAR}/sub
quoted_dq = "C:/video/in"
quoted_sq = 'C:/video/out'
dup_key = first
dup_key = second
bad_name = ${MY-VAR}/x
digit_name = ${1ABC}/y
amp_ref = ${MY_AMP_VAR}/z
Mixed_Case = mc
quoted_hash = "C:/video #1" # комментарий
quoted_hash_sq = 'a #b.log'
quoted_tail = "x" y # z
no_eq
no_eq = after
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
# `&` в значении: на bash ≥ 5.2 (patsub_replacement) он в строке замены означал
# найденный текст, и значение превращалось в 32 повтора мусора.
export MY_AMP_VAR="a=1&b=2"

# ── Ключи для сравнения ──────────────────────────────────────────────────────
# bad_name/digit_name: имя не идентификатор → литерал на всех платформах. Прежний
# PS1 брал '\$\{(\w+)\}' и ${1ABC} подставлял, а SH оставлял как есть.
# mixed_case: ключ `Mixed_Case` в файле — SH сравнивает через =~ под nocasematch,
# и bash применяет эту опцию и к =~ (ревью 2026-09-26 утверждало обратное).
KEYS=(embed_eq inline_cmt hash_val spaced var_ref quoted_dq quoted_sq dup_key bad_name digit_name amp_ref mixed_case
      quoted_hash quoted_hash_sq quoted_tail no_eq)

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
# Кавычки вокруг значения снимаются: путь, вставленный через «Копировать как путь»
# в проводнике Windows, приходит в кавычках, и без снятия «папка не найдена» на всех
# трёх платформах (а PS1 вдобавок падал исключением IsPathRooted).
assert_eq "quoted_dq: двойные кавычки сняты" "C:/video/in"  "$(read_config quoted_dq tricky '')"
assert_eq "quoted_sq: одинарные кавычки сняты" "C:/video/out" "$(read_config quoted_sq tricky '')"
# Дубликат ключа: побеждает ПЕРВОЕ вхождение — контракт всех платформ. Раньше CMD и
# GUI брали последнее, и один config.ini давал разные кодеки на разных платформах.
assert_eq "dup_key: побеждает первое вхождение" "first" "$(read_config dup_key tricky '')"
assert_eq "bad_name: \${MY-VAR} остаётся литералом"   '${MY-VAR}/x'  "$(read_config bad_name tricky '' 2>/dev/null)"
assert_eq "digit_name: \${1ABC} остаётся литералом"   '${1ABC}/y'    "$(read_config digit_name tricky '' 2>/dev/null)"
assert_contains "недопустимое имя → WARN" "недопустимое имя" "$(read_config bad_name tricky '' 2>&1 >/dev/null)"
assert_eq "amp_ref: '&' в значении переменной не трогается" "a=1&b=2/z" "$(read_config amp_ref tricky '')"
assert_eq "mixed_case: ключ другого регистра найден" "mc" "$(read_config mixed_case tricky '')"
# " #" внутри ведущих кавычек — часть значения: «Копировать как путь» для папки
# «video #1» даёт "C:/video #1", и срез до снятия кавычек оставлял "C:/video.
assert_eq "quoted_hash: ' #' в кавычках сохранён, комментарий после — срезан" "C:/video #1" "$(read_config quoted_hash tricky '')"
assert_eq "quoted_hash_sq: то же в одинарных кавычках" "a #b.log" "$(read_config quoted_hash_sq tricky '')"
# Хвост после закрывающей кавычки — обычный текст: кавычки не снимаются, комментарий режется.
assert_eq "quoted_tail: текст после кавычек остаётся как есть" '"x" y' "$(read_config quoted_tail tricky '')"
# Строка без '=' не присваивает и не «занимает» ключ: действует следующая.
assert_eq "no_eq: строка без '=' пропущена" "after" "$(read_config no_eq tricky '')"
# patsub_replacement выключается только на время разбора и возвращается как был.
if shopt -q patsub_replacement 2>/dev/null; then
    pass "patsub_replacement после read_config восстановлен"
elif shopt patsub_replacement >/dev/null 2>&1; then
    fail "patsub_replacement после read_config восстановлен" "on" "off"
else
    skip "patsub_replacement после read_config восстановлен" "bash ${BASH_VERSION} без этой опции"
fi

# Незаданная переменная → пустая подстановка + предупреждение (значение не остаётся
# литералом ${...}, иначе оно уехало бы в ffmpeg как имя каталога).
unset MY_PARITY_VAR
assert_eq "var_ref: незаданная \${VAR} → пусто, не литерал" "/sub" "$(read_config var_ref tricky '' 2>/dev/null)"
assert_contains "var_ref: незаданная \${VAR} → WARN" "MY_PARITY_VAR не задана" "$(read_config var_ref tricky '' 2>&1 >/dev/null)"
export MY_PARITY_VAR="parity-val-42"

# ══════════════════════════════════════════════════════════════
suite "GUI-ридер: Remove-ConfigComment тот же, что в CLI"
# ══════════════════════════════════════════════════════════════
# У GUI свой разбор config.ini. Обе функции берутся из НАСТОЯЩИХ исходников
# разбором AST и гоняются на одних входах — копий в тесте нет.
if [ "$HAVE_PS1" = true ]; then
    _rcc_ps=$(mktemp_suffix "${TMPDIR:-/tmp}/rcc_" .ps1)
    cat > "$_rcc_ps" <<'PSEOF'
param([string]$Cli, [string]$Gui)
function Get-Fn([string]$File) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($File, [ref]$null, [ref]$null)
    $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Remove-ConfigComment' }, $true)
}
$inputs = @('"C:/video #1" # c', "'a #b.log'", '"x" y # z', 'value # c', 'my#file', '"open #x')
foreach ($side in @(@('CLI', $Cli), @('GUI', $Gui))) {
    $fn = Get-Fn $side[1]
    if (-not $fn) { Write-Output "$($side[0])=NOFUNC"; continue }
    . ([scriptblock]::Create($fn.Extent.Text))
    Write-Output ("{0}={1}" -f $side[0], (($inputs | ForEach-Object { Remove-ConfigComment $_ }) -join '|'))
}
PSEOF
    # cygpath — только в Git Bash; на Linux/macOS (pwsh стоит и там) путь идёт как есть,
    # иначе -File получал пустую строку и сюит падал на обеих POSIX-линиях CI.
    _rcc_ps_w=$(cygpath -w "$_rcc_ps" 2>/dev/null || echo "$_rcc_ps")
    _rcc_gui_w=$(cygpath -w "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v20.ps1" 2>/dev/null || echo "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v20.ps1")
    _rcc_out=$($PS_CMD -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$_rcc_ps_w" \
        -Cli "$RUN_PS1_WIN" -Gui "$_rcc_gui_w" 2>&1 | tr -d '\r')
    rm -f "$_rcc_ps"
    _rcc_want='"C:/video #1"|'"'a #b.log'"'|"x" y|value|my#file|"open'
    assert_contains "CLI: комментарий вне кавычек" "CLI=$_rcc_want" "$_rcc_out"
    assert_contains "GUI: тот же результат"        "GUI=$_rcc_want" "$_rcc_out"
else
    skip "GUI-ридер: Remove-ConfigComment" "PowerShell не найден"
fi

# ══════════════════════════════════════════════════════════════
suite "F28: относительный log_file резолвится от папки скрипта"
# ══════════════════════════════════════════════════════════════
# Контракт (README.md): относительные пути config.ini считаются от папки скрипта.
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
    RUN_CMD_WIN=$(cygpath -w "$FF_DIR/FFmpeg_Converter_run_v20.cmd" 2>/dev/null || echo "$FF_DIR/FFmpeg_Converter_run_v20.cmd")
    cmd_log=$(cmd //c "$RUN_CMD_WIN --print-config" 2>/dev/null | tr -d '\r' | grep '^log_file=' | head -1 | sed 's/^log_file=//')
    case "$cmd_log" in
        /*|[A-Za-z]:*) pass "CMD: log_file абсолютный" ;;
        *) fail "CMD: log_file абсолютный" "абсолютный путь" "$cmd_log" ;;
    esac
else
    skip "CMD: log_file абсолютный" "cmd.exe не доступен"
fi

# ══════════════════════════════════════════════════════════════
suite "config.ini с UTF-8 BOM: первая секция распознаётся на всех платформах"
# ══════════════════════════════════════════════════════════════
# Notepad и часть редакторов Windows сохраняют UTF-8 с BOM по умолчанию. Три байта
# BOM приклеиваются к ПЕРВОЙ строке файла, и regex секции `^\[…\]$` (SH) и проверка
# первого символа на «[» (CMD) на ней не срабатывали: секция [folders] не находилась
# вовсе, скрипт брал умолчания и падал с «Папка источника не найдена: …/_video_/0».
# PS1 читал тот же файл верно — расхождение платформ на обычном пользовательском
# действии «открыл config.ini в блокноте и сохранил».
BOM_CFG="$CFG_DIR/config_bom.ini"
printf '\xEF\xBB\xBF[folders]\r\nsource = C:/bom/in\r\ndestination = C:/bom/out\r\n' > "$BOM_CFG"
# Байты BOM обязаны реально стоять в файле — иначе тест проверяет не то.
_bom_head=$(head -c 3 "$BOM_CFG" | od -An -tx1 | tr -d ' \n')
assert_eq "тестовый файл действительно с BOM" "efbbbf" "$_bom_head"

CONFIG_FILE="$BOM_CFG"
assert_eq "SH: [folders] source читается из файла с BOM" "C:/bom/in" "$(read_config source folders '__MISS__')"
CONFIG_FILE="$CFG_DIR/config.ini"

if [ "$HAVE_PS1" = true ]; then
    BOM_WIN=$(cygpath -w "$BOM_CFG" 2>/dev/null || echo "$BOM_CFG")
    assert_eq "PS1: [folders] source читается из файла с BOM" "C:/bom/in" \
        "$(run_ps1_readconfig "$BOM_WIN" source folders '__MISS__')"
else
    skip "PS1: [folders] source читается из файла с BOM" "PowerShell не найден"
fi

# CMD-сторона: run-скрипт читает config.ini из СВОЕГО каталога, поэтому берётся его
# копия во временном каталоге с BOM-версией рядом (как в test_12). Прежде тест на время
# прогона подменял РАБОЧИЙ ffmpeg/config.ini пользователя: оборванный в этом окне
# прогон оставлял вместо него заглушку, а настоящий конфиг — с адресом и ключом
# службы — в неотслеживаемом и не закрытом .gitignore файле config.ini.parity-bak.
if cmd //c "exit 0" &>/dev/null; then
    mkdir -p "$CFG_DIR/cmd"
    cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v20.cmd" "$CFG_DIR/cmd/"
    cp "$BOM_CFG" "$CFG_DIR/cmd/config.ini"
    RUN_CMD_WIN=$(cygpath -w "$CFG_DIR/cmd/FFmpeg_Converter_run_v20.cmd" 2>/dev/null || echo "$CFG_DIR/cmd/FFmpeg_Converter_run_v20.cmd")
    cmd_src=$(cmd //c "$RUN_CMD_WIN --print-config" < /dev/null 2>/dev/null | tr -d '\r' | grep '^folder_sources=' | head -1 | sed 's/^folder_sources=//')
    assert_eq "CMD: [folders] source читается из файла с BOM" "C:/bom/in" "$cmd_src"
else
    skip "CMD: [folders] source читается из файла с BOM" "cmd.exe не доступен"
fi

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$CFG_DIR"

summary
