#!/bin/bash
# Тест дот-сорсит настоящий production-скрипт: переменные, которые здесь только
# присваиваются, читает он (SC2034).
# Путь к дот-сорсимому скрипту вычисляется в рантайме — следовать за `source`
# статический анализатор не может по определению (SC1090).
# shellcheck disable=SC1090,SC2034
# ============================================================
# test_10_archive_skip_parity.sh — учёт archive-skip во всех путях.
#
# Контракт (введён вместе с манифестом, F13): архив включён, yt-dlp отработал
# успешно, но не переместил НИ ОДНОГО файла → значит, всё уже было в архиве.
# Это ПРОПУСК, а не загрузка. Иначе сводка врёт: полностью архивная очередь
# рапортует «скачано N», хотя сеть не трогали.
#
# Контракт соблюдался только в download_url (.sh). Два пути его теряли:
#   1. `.sh` download_batch — свой массив cmd, манифест туда не передавался
#      вовсе, поэтому COUNT_SKIP в batch-режиме навсегда оставался 0, а канал,
#      где новых видео нет, засчитывался как успешно скачанный;
#   2. `.ps1` GUI — манифест создавался ТОЛЬКО под AI-перевод, поэтому при
#      выключенном переводе archive-skip не определялся вовсе: URL целиком из
#      архива попадал в successCount и печатался как «Готово».
#
# Мок yt-dlp повторяет контракт --print-to-file: пустой MOCK_YTDLP_OUTFILE →
# ничего не пишет в манифест → эмуляция «всё уже в архиве».
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.sh"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.ps1"
for _f in "$SH_SCRIPT" "$PS1_SCRIPT"; do
    if [ ! -f "$_f" ]; then
        suite "archive-skip parity"
        fail "production-скрипт на месте" "$_f" "файл не найден"
        summary
        exit 1
    fi
done

source "$SH_SCRIPT" >/dev/null 2>&1

WORK=$(mktemp -d /tmp/test_arch_skip_XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Запускает download_batch с mock yt-dlp и печатает итоговые счётчики.
# $1 = MOCK_YTDLP_OUTFILE (пусто → манифест пустой → «всё в архиве»)
# $2 = MOCK_YTDLP_RC — код возврата мока (по умолчанию 0)
run_batch() {
    local outfile="$1"
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_YTDLP_LOG="$WORK/mock.log"
        export MOCK_YTDLP_OUTFILE="$outfile"
        export MOCK_YTDLP_RC="${2:-0}"
        : > "$WORK/mock.log"

        YTDLP="$TESTS_DIR/mocks/yt-dlp"
        CHANNELS_FILE="$WORK/channels.txt"
        BASE_DIR="$WORK/out"
        ARCHIVE_FILE="archive.txt"
        USE_ARCHIVE="true"
        DRY_RUN="false"
        QUALITY="720"; FORMAT_PRESET="auto"; AUDIO_FORMAT="best"
        OUTPUT_TEMPLATE='%(title)s.%(ext)s'
        PLAYLIST_TEMPLATE='%(playlist)s/%(title)s.%(ext)s'
        SUB_LANG="ru"; SUB_FORMAT="vtt"; SUBS_WITH_VIDEO="off"
        CONTINUE_ON_ERROR="true"; SPONSORBLOCK="off"; PROXY_URL=""
        SPEED_PROFILE="normal"; LIMIT_RATE=""
        COOKIE_ARGS_ARR=()
        COUNT_OK=0; COUNT_FAIL=0; COUNT_SKIP=0
        mkdir -p "$BASE_DIR"
        printf 'tech|somehandle|videos\n' > "$CHANNELS_FILE"

        download_batch "false" >/dev/null 2>&1
        echo "ok=$COUNT_OK skip=$COUNT_SKIP fail=$COUNT_FAIL"
    ) < /dev/null
}

# ══════════════════════════════════════════════════════════════
suite "SH batch: пустой манифест при архиве = пропуск, не загрузка"
# ══════════════════════════════════════════════════════════════

# Ничего не перемещено → всё уже в архиве.
RES=$(run_batch "")
assert_contains "канал без новых видео → skip=1"  "skip=1"  "$RES"
assert_contains "канал без новых видео → ok=0"    "ok=0"    "$RES"
assert_contains "канал без новых видео → fail=0"  "fail=0"  "$RES"

# Есть новый файл → это настоящая загрузка.
RES=$(run_batch "$WORK/out/new_video.mp4")
assert_contains "канал с новым видео → ok=1"      "ok=1"    "$RES"
assert_contains "канал с новым видео → skip=0"    "skip=0"  "$RES"

# ══════════════════════════════════════════════════════════════
suite "SH batch: код 101 (--break-on-reject) — штатный конец обхода"
# ══════════════════════════════════════════════════════════════
# yt-dlp на любом DownloadCancelled возвращает 101; в режиме каналов это каждый
# прогон, где у канала есть ролики старше date_range. Раньше такой канал шёл в
# ошибки, и штатный повторный прогон заканчивался exit 1.
RES=$(run_batch "$WORK/out/new_video.mp4" 101)
assert_contains "101 с новым видео → ok=1"   "ok=1"   "$RES"
assert_contains "101 с новым видео → fail=0" "fail=0" "$RES"
RES=$(run_batch "" 101)
assert_contains "101 без новых видео → skip=1" "skip=1" "$RES"
assert_contains "101 без новых видео → fail=0" "fail=0" "$RES"
# Настоящая ошибка по-прежнему ошибка.
RES=$(run_batch "$WORK/out/new_video.mp4" 1)
assert_contains "код 1 → fail=1" "fail=1" "$RES"
assert_contains "код 1 → ok=0"   "ok=0"   "$RES"

# ══════════════════════════════════════════════════════════════
suite "SH download_url: код 101 — штатная остановка, как в batch"
# ══════════════════════════════════════════════════════════════
# Одиночная загрузка получает 101, когда --max-downloads/--break-on-existing/
# --break-on-reject задал внешний конфиг yt-dlp. Раньше это шло в ошибки, тогда
# как download_batch уже трактовал 101 как штатный конец. Логика ok/skip — та же.
# $1 = MOCK_YTDLP_OUTFILE (пусто → манифест пустой → «уже в архиве»), $2 = код мока.
run_url() {
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_YTDLP_LOG="$WORK/mock.log"
        export MOCK_YTDLP_OUTFILE="$1"
        export MOCK_YTDLP_RC="$2"
        YTDLP="$TESTS_DIR/mocks/yt-dlp"
        DRY_RUN="false"; FORMAT_PRESET="auto"; AUDIO_FORMAT="best"
        SUB_LANG="ru"; SUB_FORMAT="vtt"; SUBS_WITH_VIDEO="off"
        CONTINUE_ON_ERROR="true"; SPONSORBLOCK="off"; PROXY_URL=""
        SPEED_PROFILE="normal"; LIMIT_RATE=""
        COOKIE_ARGS_ARR=()
        COUNT_OK=0; COUNT_FAIL=0; COUNT_SKIP=0
        : > "$WORK/url_manifest.txt"
        DL_MANIFEST="$WORK/url_manifest.txt" download_url "https://example.invalid/v" \
            "$WORK/out/%(title)s.%(ext)s" "720" "false" "archive.txt" >/dev/null 2>&1
        echo "rc=$? ok=$COUNT_OK skip=$COUNT_SKIP fail=$COUNT_FAIL"
    ) < /dev/null
}
assert_eq "101 с новым файлом → загрузка (rc 0)"  "rc=0 ok=1 skip=0 fail=0" "$(run_url "$WORK/out/v.mp4" 101)"
assert_eq "101 без новых файлов → пропуск (rc 2)" "rc=2 ok=0 skip=1 fail=0" "$(run_url "" 101)"
assert_eq "код 1 → по-прежнему ошибка"          "rc=1 ok=0 skip=0 fail=1" "$(run_url "$WORK/out/v.mp4" 1)"
assert_eq "код 0 не изменился"                    "rc=0 ok=1 skip=0 fail=0" "$(run_url "$WORK/out/v.mp4" 0)"

# ══════════════════════════════════════════════════════════════
suite "SH batch: манифест реально доезжает до argv yt-dlp"
# ══════════════════════════════════════════════════════════════
# Без этого проверка выше прошла бы и на «манифест всегда пуст, потому что его
# никто не заполняет» — то есть по случайной причине, а не по контракту.
run_batch "" >/dev/null
assert_contains "batch передаёт --print-to-file after_move:filepath" \
    "--print-to-file after_move:filepath" "$(cat "$WORK/mock.log")"

# Временный манифест не должен оставаться после прогона.
# tr — BSD wc (macOS) выравнивает счётчик пробелами слева, сравнение строк ломается.
_leftover=$(find /tmp -maxdepth 1 -name 'ytdlp_batch_manifest_*' 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "временный манифест batch удалён" "0" "$_leftover"

# ══════════════════════════════════════════════════════════════
suite "PS1 GUI: манифест создаётся и под архив, не только под перевод"
# ══════════════════════════════════════════════════════════════
# GUI headless не запустить (WinForms), поэтому проверяем контракт по исходнику.
src_ps1="$(cat "$PS1_SCRIPT")"

assert_contains "манифест создаётся и при use_archive, а не только при переводе" \
    '$chkTranslate.Checked -or ($cfg_useArchive -eq "true"' "$src_ps1"
assert_contains "PS1 считает пропуски (паритет с COUNT_SKIP)" '$skipCount++' "$src_ps1"
# Пустота манифеста проверяется по СОДЕРЖИМОМУ, а не по длине файла: `Set-Content
# -Encoding UTF8` в PS 5.1 пишет 3 байта BOM даже в пустой файл, поэтому условие
# `Length -eq 0` не выполнялось НИКОГДА — пропуск по архиву засчитывался как загрузка,
# ровно тот баг завышенной сводки, который этот файл и охраняет.
# Чтение вынесено в Get-ManifestLines: Get-Content без -Encoding в PS 5.1 декодирует
# файл без BOM как ANSI, и кириллический путь становился mojibake (перевод не находил
# файл). Проверяем и вызов, и то, что читатель задаёт UTF-8 явно.
assert_contains "PS1 определяет archive-skip по содержимому манифеста" \
    'Get-ManifestLines $dlManifest |' "$src_ps1"
assert_contains "манифест читается явно как UTF-8, а не в ANSI-кодировке системы" \
    '[System.IO.File]::ReadAllLines($Path, [System.Text.UTF8Encoding]::new($false))' "$src_ps1"
assert_not_contains "пропуск НЕ определяется по длине файла (BOM даёт Length=3)" \
    '(Get-Item -LiteralPath $dlManifest).Length -eq 0' "$src_ps1"
assert_contains "манифест создаётся без BOM" \
    '[System.IO.File]::WriteAllText($dlManifest, "")' "$src_ps1"
assert_contains "PS1 печатает пропуск отдельно от «Готово»" \
    'Пропущено (уже в архиве)' "$src_ps1"
assert_contains "PS1 показывает пропуски в итоговой сводке" \
    'Пропущено (в архиве): $skipCount' "$src_ps1"

# Ключевое: на пропуске successCount расти НЕ должен — иначе «Готово: N/M» врёт.
# Проверяем, что инкремент успеха лежит в else-ветке archive-skip.
_ps_block=$(awk '/\$archiveSkipped = \$false/{f=1} f{print} /конец ветки/{if(f) exit}' "$PS1_SCRIPT")
assert_contains "successCount увеличивается только в ветке реальной загрузки" \
    '$successCount++' "$_ps_block"
assert_contains "skipCount увеличивается в ветке пропуска" '$skipCount++' "$_ps_block"
# Код 101 ведёт в ту же ветку «Готово/пропуск», что и 0 (паритет с .sh; CMD
# проверяется сквозным прогоном в test_15). Сам обработчик живёт в WinForms-клике.
assert_contains "PS1: код 101 — штатная остановка, не «Ошибка»" \
    'if ($exitCode -eq 0 -or $exitCode -eq 101) {' "$src_ps1"

# ══════════════════════════════════════════════════════════════
suite "Общий контракт: пропуск не запускает AI-перевод"
# ══════════════════════════════════════════════════════════════
# В .sh это `return 2` (перевод — потребитель dl_rc==0), в .ps1 перевод лежит
# внутри else-ветки. Переводить на пропуске нечего: файла нет.
src_sh="$(cat "$SH_SCRIPT")"
assert_contains "SH: пропуск возвращает отдельный код 2" "return 2" "$src_sh"

summary
