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

# ── SH read_config (копия логики из FFmpeg_Converter_run_v15.sh) ────────────
read_config() {
    local key="$1"
    local section="$2"
    local default="${3:-}"
    if [ ! -f "$CONFIG_FILE" ]; then echo "$default"; return; fi
    local result="$default"
    local saved_ncm; saved_ncm=$(shopt -p nocasematch)
    shopt -s nocasematch
    local in_section=false
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            [[ "${BASH_REMATCH[1]}" == "$section" ]] && in_section=true || in_section=false
            continue
        fi
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            local value="${BASH_REMATCH[1]}"
            if [[ "$value" == *" #"* ]]; then
                value="${value%% #*}"
                value="${value%"${value##*[![:space:]]}"}"
            fi
            result="$value"
            break
        fi
    done < "$CONFIG_FILE"
    eval "$saved_ncm"
    echo "$result"
}

# ── PS1 Read-Config (inline, копия логики из FFmpeg_Converter_run_v15.ps1) ──
HAVE_PS1=true
PS_CMD="powershell"
if command -v pwsh &>/dev/null; then
    PS_CMD="pwsh"
elif ! command -v powershell &>/dev/null; then
    HAVE_PS1=false
fi

run_ps1_readconfig() {
    local cfg_win="$1"
    local key="$2"
    local section="$3"
    local default="$4"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$CONFIG_FILE = '$cfg_win'
function Read-Config {
    param(\$key, \$section, \$default = '')
    if (-not (Test-Path \$CONFIG_FILE)) { return \$default }
    \$inSection = \$false
    foreach (\$line in (Get-Content \$CONFIG_FILE -Encoding UTF8)) {
        \$line = \$line.Trim()
        if ([string]::IsNullOrEmpty(\$line) -or \$line.StartsWith('#')) { continue }
        if (\$line -match '^\[([^\]]+)\]\$') {
            \$inSection = (\$Matches[1] -eq \$section)
            continue
        }
        if (\$inSection -and \$line -match \"^\$key\s*=\s*(.*)\") {
            \$val = \$Matches[1] -replace '\s+#.*', ''
            return \$val.Trim()
        }
    }
    return \$default
}
Read-Config '$key' '$section' '$default'
" 2>/dev/null
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
# ${VAR} остаётся литералом (ffmpeg-парсер не делает подстановку).
assert_eq "var_ref: \${VAR} литералом"         '${MY_PARITY_VAR}/sub'  "$(read_config var_ref tricky '')"

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$CONFIG_FILE"

summary
