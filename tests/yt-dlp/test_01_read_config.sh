#!/bin/bash
# ============================================================
# test_01_read_config.sh — Тест read_config() из yt-dlp скрипта
# Функция идентична ffmpeg, но тестируем на yt-dlp config.ini
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
MY_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ── Настоящая read_config из production-скрипта ────────────────────────────
# Раньше здесь лежала inline-копия, честно подписанная «зеркало реального SH». Зеркало
# успело разойтись с оригиналом и закрепляло УЖЕ ИСПРАВЛЕННЫЙ баг: копия резала значение
# по любому '#' (старый жадный regex), тогда как production режет только по первому
# " #" — то есть `my#file.log` копия обрезала до `my`. Ещё копия не убирала  из CRLF.
# Тест «парсера конфига» проверял НЕ ТОТ парсер; ссылка вела на v11, которого в репозитории
# давно нет, и это тоже никого не смущало. Production сорсится штатно: main() у него
# гардится BASH_SOURCE (гард заведён ровно ради тестов).
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
if [ ! -f "$YT_SH" ]; then
    suite "YT-DLP read_config"
    fail "production-скрипт на месте" "$YT_SH" "файл не найден — тест проверял бы копию, а не production"
    summary
    exit 1
fi
source "$YT_SH"
# Production включает `set -uo pipefail` на верхнем уровне; в тестовой оболочке это
# роняет framework на первой же необъявленной переменной. На саму read_config опции
# не влияют, поэтому снимаем.
set +u +o pipefail

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
suite "read_config: инлайн-комментарий и CRLF (inline-копия их не покрывала)"
# ══════════════════════════════════════════════════════════════
# Ровно те места, где зеркало разошлось с оригиналом. Копия резала по любому '#'
# (старый жадный regex) и не трогала \r — то есть эти ветки production не проверялись
# вовсе, а копия закрепляла поведение, которое production уже исправил.

# '#' без пробела слева — часть значения, а не комментарий. Копия обрезала до "my".
write_config "[output]
template = my#file.log"
assert_eq "'#' без пробела слева — часть значения" "my#file.log" "$(read_config 'template' 'output' '')"
rm -f "$CONFIG_FILE"

# ' #' (пробел+решётка) — инлайн-комментарий, режется по ПЕРВОМУ вхождению.
write_config "[output]
base_dir = /downloads # сюда качаем
template = a # b # c"
assert_eq "' #' срезан, хвост пробелов убран" "/downloads" "$(read_config 'base_dir' 'output' '')"
assert_eq "режется по ПЕРВОМУ ' #', не по последнему" "a" "$(read_config 'template' 'output' '')"
rm -f "$CONFIG_FILE"

# CRLF: config.ini на Windows может быть с \r. Копия его не убирала, поэтому значение
# уезжало с невидимым \r на конце — и сравнение с ожидаемым молча ломалось бы.
CONFIG_FILE=$(mktemp /tmp/test_ytdlp_crlf_XXXXXX.ini)
printf '[download]\r\ndefault_quality = 1080\r\n' > "$CONFIG_FILE"
crlf_val=$(read_config 'default_quality' 'download' '')
assert_eq "CRLF: \\r убран из значения" "1080" "$crlf_val"
assert_eq "CRLF: длина значения без \\r" "4" "${#crlf_val}"
rm -f "$CONFIG_FILE"

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
# F13. Точный handshake вместо поиска по mtime (все 3). --no-mtime и marker'ы удалены
# вместе с самим mtime-механизмом: путь сообщает yt-dlp через --print-to-file.
assert_contains "SH: --print-to-file after_move:filepath"   'after_move:filepath'  "$sh_src"
assert_contains "CMD: --print-to-file after_move:filepath"  'after_move:filepath'  "$cmd_src"
assert_contains "PS1: --print-to-file after_move:filepath"  'after_move:filepath'  "$ps1_src"
assert_not_contains "SH: mtime-поиск удалён"   '--no-mtime'  "$sh_src"
assert_not_contains "CMD: mtime-поиск удалён"  '--no-mtime'  "$cmd_src"
assert_not_contains "PS1: mtime-поиск удалён"  '--no-mtime'  "$ps1_src"
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
