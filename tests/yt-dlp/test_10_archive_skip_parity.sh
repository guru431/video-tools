#!/bin/bash
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

SH_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.sh"
PS1_SCRIPT="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.ps1"
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
run_batch() {
    local outfile="$1"
    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_YTDLP_LOG="$WORK/mock.log"
        export MOCK_YTDLP_OUTFILE="$outfile"
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
assert_contains "PS1 определяет archive-skip по пустому манифесту" \
    '$archiveSkipped = ((Get-Item -LiteralPath $dlManifest).Length -eq 0)' "$src_ps1"
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

# ══════════════════════════════════════════════════════════════
suite "Общий контракт: пропуск не запускает AI-перевод"
# ══════════════════════════════════════════════════════════════
# В .sh это `return 2` (перевод — потребитель dl_rc==0), в .ps1 перевод лежит
# внутри else-ветки. Переводить на пропуске нечего: файла нет.
src_sh="$(cat "$SH_SCRIPT")"
assert_contains "SH: пропуск возвращает отдельный код 2" "return 2" "$src_sh"

summary
