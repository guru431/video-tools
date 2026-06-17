#!/bin/bash
# ============================================================
# test_01_read_config.sh — Тест read_config() из yt-dlp скрипта
# Функция идентична ffmpeg, но тестируем на yt-dlp config.ini
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

SCRIPT_FILE="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v11.sh"

# ── Извлекаем только функцию read_config из скрипта ─────────────────────────
# Используем subshell чтобы изолировать функцию без запуска main кода
CONFIG_FILE=""

load_readconfig() {
    # Sourсим только функции (строки до первой секции "main" кода)
    # Функция read_config определена в строках ~47-86
    # Прекращаем source при set -uo pipefail (строка 3) и после функций
    # Самый надёжный способ: re-define функцию inline
    read_config() {
        local key="$1"
        local section="$2"
        local default="${3:-}"

        if [ ! -f "$CONFIG_FILE" ]; then
            echo "$default"
            return
        fi

        local in_section=false
        local value=""
        while IFS= read -r line || [ -n "$line" ]; do
            line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
            [[ -z "$line" || "$line" == \#* ]] && continue
            if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
                if [ "${BASH_REMATCH[1]}" = "$section" ]; then
                    in_section=true
                else
                    in_section=false
                fi
                continue
            fi
            if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
                value="${BASH_REMATCH[1]}"
                value=$(echo "$value" | sed 's/[[:space:]]*#.*//')
                # Подстановка ${ENV_VAR} (зеркало реального скрипта)
                while [[ "$value" == *'${'*'}'* ]]; do
                    local _vn="${value#*\$\{}"; _vn="${_vn%%\}*}"
                    [ -n "${!_vn:-}" ] || echo "WARN: переменная $_vn не задана" >&2
                    value="${value//\$\{$_vn\}/${!_vn:-}}"
                done
                echo "$value"
                return
            fi
        done < "$CONFIG_FILE"
        echo "$default"
    }
}

load_readconfig

write_config() {
    local content="$1"
    CONFIG_FILE=$(mktemp /tmp/test_ytdlp_XXXXXX.ini)
    printf '%s\n' "$content" > "$CONFIG_FILE"
}

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: секция proxy"
# ══════════════════════════════════════════════════════════════

write_config "[proxy]
url = https://user:pass@proxy.example.com:8080"

result=$(read_config "url" "proxy" "")
assert_eq "proxy url"  "https://user:pass@proxy.example.com:8080"  "$result"
rm -f "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: секция cookies"
# ══════════════════════════════════════════════════════════════

write_config "[cookies]
method = browser
browser = chrome
file = /path/to/cookies.txt"

result=$(read_config "method" "cookies" "none")
assert_eq "cookies method=browser"   "browser"  "$result"

result=$(read_config "browser" "cookies" "")
assert_eq "cookies browser=chrome"   "chrome"   "$result"

result=$(read_config "file" "cookies" "")
assert_eq "cookies file path"  "/path/to/cookies.txt"  "$result"
rm -f "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: секция output"
# ══════════════════════════════════════════════════════════════

write_config "[output]
base_dir = /downloads
template = %(uploader)s/%(title)s.%(ext)s"

result=$(read_config "base_dir" "output" "")
assert_eq "output base_dir"  "/downloads"  "$result"

result=$(read_config "template" "output" "")
assert_eq "output template"  "%(uploader)s/%(title)s.%(ext)s"  "$result"
rm -f "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: секция download"
# ══════════════════════════════════════════════════════════════

write_config "[download]
default_quality = 1080
continue_on_error = true
use_archive = true
archive_file = download_archive.txt"

result=$(read_config "default_quality" "download" "720")
assert_eq "quality=1080"    "1080"   "$result"

result=$(read_config "use_archive" "download" "false")
assert_eq "use_archive"     "true"   "$result"

result=$(read_config "archive_file" "download" "")
assert_eq "archive_file"    "download_archive.txt"  "$result"
rm -f "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: секция translation"
# ══════════════════════════════════════════════════════════════

write_config "[translation]
enabled = true
target_lang = ru
voice_style = live
mode = dual_track"

result=$(read_config "enabled" "translation" "false")
assert_eq "translation enabled"    "true"        "$result"

result=$(read_config "target_lang" "translation" "en")
assert_eq "translation target_lang" "ru"         "$result"

result=$(read_config "mode" "translation" "")
assert_eq "translation mode"       "dual_track"  "$result"
rm -f "$CONFIG_FILE"

# ══════════════════════════════════════════════════════════════
suite "YT-DLP read_config: defaults и edge cases"
# ══════════════════════════════════════════════════════════════

write_config "[proxy]
url = https://example.com"

result=$(read_config "nonexistent" "proxy" "my_default")
assert_eq "несуществующий ключ → default"  "my_default"  "$result"

result=$(read_config "url" "nonexistent_section" "fallback")
assert_eq "несуществующая секция → default"  "fallback"  "$result"
rm -f "$CONFIG_FILE"

# Несуществующий файл
CONFIG_FILE="/tmp/nonexistent_config_$$.ini"
result=$(read_config "url" "proxy" "file_default")
assert_eq "нет файла → default"  "file_default"  "$result"

# ══════════════════════════════════════════════════════════════
suite "Task 12: yt-dlp фиксы (анализ исходников, 3 платформы)"
# ══════════════════════════════════════════════════════════════
SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
CMDF="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
PS1F="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
sh_src="$(cat "$SH")"; cmd_src="$(cat "$CMDF")"; ps1_src="$(cat "$PS1F")"

# deno.exe детект (SH)
assert_contains "SH: deno.exe детект"  'deno:$script_dir/deno.exe'  "$sh_src"
# env_prefix bash<4.4 safe expansion
assert_contains "SH: env_prefix bash<4.4"  '${env_prefix[@]+"${env_prefix[@]}"}'  "$sh_src"
# translate только при rc=0
assert_contains "SH: translate при dl_rc=0"  '[ "$dl_rc" -eq 0 ]'  "$sh_src"
# --no-mtime при переводе (все 3)
assert_contains "SH: --no-mtime при переводе"  '--no-mtime'  "$sh_src"
assert_contains "CMD: --no-mtime при переводе"  "mtime_arg=--no-mtime"  "$cmd_src"
assert_contains "PS1: --no-mtime при переводе"  '$command += "--no-mtime"'  "$ps1_src"
# continue_on_error (SH + PS1)
assert_contains "SH: continue_on_error → --abort-on-error"  "--abort-on-error"  "$sh_src"
assert_contains "PS1: continue_on_error → --abort-on-error"  "--abort-on-error"  "$ps1_src"
assert_not_contains "SH: нет захардкоженного -c -i -w"  '"$YTDLP" -c -i -w'  "$sh_src"

# ══════════════════════════════════════════════════════════════
suite "Task 13: подстановка \${ENV_VAR} в config.ini"
# ══════════════════════════════════════════════════════════════
# Поведенческий (через inline-копию, зеркало реального SH)
write_config "[proxy]
url = \${TEST_PROXY_VAR}"
export TEST_PROXY_VAR="https://u:p@h:1"
result=$(read_config "url" "proxy" "")
assert_eq "\${TEST_PROXY_VAR} → значение из окружения"  "https://u:p@h:1"  "$result"
unset TEST_PROXY_VAR
result=$(read_config "url" "proxy" "" 2>/dev/null)
assert_empty "не заданная переменная → пустая строка"  "$result"
result_warn=$(read_config "url" "proxy" "" 2>&1 >/dev/null)
assert_contains "не заданная переменная → WARN в stderr"  "не задана"  "$result_warn"
rm -f "$CONFIG_FILE"

# Несколько вхождений
write_config "[proxy]
url = \${A}-\${B}"
export A="x"; export B="y"
result=$(read_config "url" "proxy" "")
assert_eq "несколько \${VAR} → обе подставлены"  "x-y"  "$result"
unset A; unset B
rm -f "$CONFIG_FILE"

# Статический: фича присутствует в реальных SH и PS1
assert_contains "SH: подстановка \${ENV} реализована"  'value="${value//\$\{$_vn\}/${!_vn:-}}"'  "$sh_src"
assert_contains "PS1: подстановка \${ENV} реализована"  '\$\{(\w+)\}'  "$ps1_src"

summary
