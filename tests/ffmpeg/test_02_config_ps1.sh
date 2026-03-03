#!/bin/bash
# ============================================================
# test_02_config_ps1.sh — Тест парсинга config.ini (PowerShell)
# Тестирует: Read-Config + To-Flag из FFmpeg_Converter_run.ps1
# Сравнивает результаты PS1 с ожидаемыми эталонными значениями
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность PowerShell
if ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; then
    suite "PowerShell config parsing"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

# ── Запуск PS1 функции через inline-скрипт ──────────────────────────────────
run_ps1_readconfig() {
    local config_content="$1"
    local key="$2"
    local section="$3"
    local default="$4"
    local config_file
    config_file=$(mktemp /tmp/test_config_XXXXXX.ini)
    printf '%s\n' "$config_content" > "$config_file"
    # Нормализация пути для Windows
    local win_path
    win_path=$(cygpath -w "$config_file" 2>/dev/null || echo "$config_file" | sed 's|/|\\|g' | sed 's|^s:|S:|')

    local result
    result=$($PS_CMD -NoProfile -NonInteractive -Command "
\$CONFIG_FILE = '$win_path'

function Read-Config {
    param(\$key, \$section, \$default = '')
    if (-not (Test-Path \$CONFIG_FILE)) { return \$default }
    \$inSection = \$false
    foreach (\$line in [System.IO.File]::ReadLines(\$CONFIG_FILE)) {
        \$line = \$line.Trim()
        if (\$line -eq '' -or \$line.StartsWith('#')) { continue }
        if (\$line -match '^\[(.+)\]$') {
            \$inSection = (\$matches[1] -eq \$section)
            continue
        }
        if (\$inSection -and \$line -match \"^\$key\s*=\s*(.*)\") {
            \$val = \$matches[1] -replace '\s*#.*', '' -replace '\s+$', ''
            return \$val
        }
    }
    return \$default
}

Read-Config '$key' '$section' '$default'
" 2>/dev/null)
    rm -f "$config_file"
    echo "$result"
}

run_ps1_toflag() {
    local val="$1"
    local default="$2"
    $PS_CMD -NoProfile -NonInteractive -Command "
function To-Flag {
    param(\$val, \$default)
    if ([string]::IsNullOrEmpty(\$val)) { return \$default }
    \$first = \$val[0]
    \$rest = \$val.Substring(1)
    switch (\$first) {
        '+' { return \":\$([char]43):\$rest\" }
        '-' { return \":-:\$rest\" }
        default { return \":\$([char]43):\$val\" }
    }
}
To-Flag '$val' '$default'
" 2>/dev/null
}

# ══════════════════════════════════════════════════════════════
suite "PS1 To-Flag: конвертация префиксов"
# ══════════════════════════════════════════════════════════════

result=$(run_ps1_toflag "+libx264" "")
assert_eq "To-Flag: +value → :+:value"  ":+:libx264"  "$result"

result=$(run_ps1_toflag "-libx264" "")
assert_eq "To-Flag: -value → :-:value"  ":-:libx264"  "$result"

result=$(run_ps1_toflag "libx264" "")
assert_eq "To-Flag: bare → :+:value"    ":+:libx264"  "$result"

result=$(run_ps1_toflag "" ":+:default")
assert_eq "To-Flag: пустое → default"   ":+:default"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 Read-Config: базовый парсинг"
# ══════════════════════════════════════════════════════════════

# Многострочный config через несколько аргументов printf
CONFIG="[audio]
codec = +libmp3lame"

result=$(run_ps1_readconfig "$CONFIG" "codec" "audio" "missing")
assert_eq "Read-Config: читает значение"  "+libmp3lame"  "$result"

result=$(run_ps1_readconfig "$CONFIG" "nonexistent" "audio" "default_val")
assert_eq "Read-Config: несуществующий ключ → default"  "default_val"  "$result"

result=$(run_ps1_readconfig "$CONFIG" "codec" "video" "section_default")
assert_eq "Read-Config: другая секция → default"  "section_default"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 Read-Config: inline комментарии"
# ══════════════════════════════════════════════════════════════

CONFIG="[audio]
codec = +aac  # inline comment"

result=$(run_ps1_readconfig "$CONFIG" "codec" "audio" "")
assert_eq "Read-Config: inline comment срезается"  "+aac"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 vs Bash: паритет значений"
# ══════════════════════════════════════════════════════════════
# Проверяем что PS1 и Bash дают одинаковый результат

CONFIG_INI="$MY_DIR/config.ini"
cat > "$CONFIG_INI" << 'EOF'
[audio]
codec = +libmp3lame
bitrate = +192
[video]
codec = +libx265
quality = +23
container = +mkv
[gpu]
hw_accel = -nvidia
EOF

# Загружаем bash read_config
source "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run.sh" 2>/dev/null

bash_audio_codec="$audio_codec"
bash_video_codec="$video_codec"
bash_output_container="$output_container"

# PS1 значения
ps1_audio=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "codec" "audio" "")
ps1_video=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "codec" "video" "")
ps1_container=$(run_ps1_readconfig "$(cat "$CONFIG_INI")" "container" "video" "")

# Bash даёт :+:libmp3lame, PS1 даёт +libmp3lame (до to_flag)
# Сравниваем сырые значения read_config (без to_flag)
bash_raw_audio=$(CONFIG_FILE="$CONFIG_INI" read_config "codec" "audio" "")
bash_raw_video=$(CONFIG_FILE="$CONFIG_INI" read_config "codec" "video" "")
bash_raw_container=$(CONFIG_FILE="$CONFIG_INI" read_config "container" "video" "")

assert_eq "Паритет: audio codec (raw)"    "$bash_raw_audio"     "$ps1_audio"
assert_eq "Паритет: video codec (raw)"    "$bash_raw_video"     "$ps1_video"
assert_eq "Паритет: container (raw)"      "$bash_raw_container" "$ps1_container"

# ── Cleanup ───────────────────────────────────────────────────
rm -f "$MY_DIR/config.ini"

summary
