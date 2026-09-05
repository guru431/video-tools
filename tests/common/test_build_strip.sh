#!/bin/bash
# ============================================================
# test_build_strip.sh — комментарии не попадают в собранный EXE.
#
# Почему это отдельный барьер. Вердикт антивируса выносит облачная эвристика по
# СУММЕ признаков, и в этом репозитории уже ИЗМЕРЕНО, что текст комментариев
# входит в эту сумму: v17 загрузчика блокировался Kaspersky, v16 — нет, а откат
# по одному изменению за раз назвал причиной ~1.6 КБ дописанных комментариев
# (docs/knowledge-base.md). Ревизия 2026-09-05 добавила в исходники конвертера
# ~32 КБ комментариев — и Kaspersky начал ругаться на конвертер.
#
# Прежним «барьером» было правило стиля в CLAUDE.md («комментарии в GUI
# загрузчика — короткие»). Оно не работает: к моменту этой ревизии в том же файле
# уже лежали 37 блоков по три и более строк, то есть правило разошлось с файлом
# молча и задолго до того, как кто-то это заметил. Поэтому ограничение перенесено
# туда, где его можно проверить, — в сборку: Remove-PsComments снимает
# комментарии с упаковываемой копии, а исходники в репозитории сохраняют
# домашний стиль подробных «почему»-врезок.
#
# Здесь проверяются обе половины: что сборка действительно зовёт вырезание, и
# что вырезание не трогает ничего, кроме комментариев.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# ══════════════════════════════════════════════════════════════
suite "Сборка EXE: комментарии снимаются с упаковываемой копии"
# ══════════════════════════════════════════════════════════════
FF_BUILD="$(cat "$PROJECT_DIR/ffmpeg/build_exe.ps1")"
YT_BUILD="$(cat "$PROJECT_DIR/yt-dlp/build_exe.ps1")"
COMMON="$(cat "$PROJECT_DIR/tools/_build_common.ps1")"

assert_contains "Remove-PsComments объявлен один раз в общем модуле" "function Remove-PsComments" "$COMMON"
# Все три исходника конвертера попадают в один EXE — снимать надо с каждого.
# Считаем ВЫЗОВЫ, а не упоминания: имя функции встречается и в поясняющем
# комментарии рядом, и `grep -c` по голому имени зеленел бы от него одного.
ff_calls=$(printf '%s\n' "$FF_BUILD" | grep -cF 'Remove-PsComments ([System.IO.File]::ReadAllText')
assert_eq "ffmpeg: вырезание применено к трём исходникам" "3" "$ff_calls"
assert_contains "ffmpeg: встраиваемый script.ps1 без комментариев" 'Remove-PsComments ([System.IO.File]::ReadAllText($scriptPs1' "$FF_BUILD"
assert_contains "ffmpeg: встраиваемый remote_client.ps1 без комментариев" 'Remove-PsComments ([System.IO.File]::ReadAllText($remotePs1' "$FF_BUILD"
assert_contains "ffmpeg: сам GUI без комментариев" 'Remove-PsComments ([System.IO.File]::ReadAllText($src' "$FF_BUILD"
# У загрузчика ps2exe читает файл с диска, поэтому копия обязана быть временной,
# а не правкой исходника на месте.
assert_contains "yt-dlp: собирается из временной копии" '-inputFile  $tmpSrc' "$YT_BUILD"
assert_contains "yt-dlp: копия — результат вырезания" 'Remove-PsComments ([System.IO.File]::ReadAllText($src' "$YT_BUILD"
assert_not_contains "yt-dlp: исходник в ps2exe не уходит" '-inputFile  $src' "$YT_BUILD"
# Временная копия не должна пережить сборку (в ней тот же код, но без объяснений).
tmp_cleanup=$(printf '%s\n' "$YT_BUILD" | grep -c 'Remove-Item -LiteralPath $tmpSrc')
assert_eq "yt-dlp: временная копия удаляется и при провале, и при успехе" "2" "$tmp_cleanup"

# ── Функциональная часть: нужен Windows PowerShell ────────────────────────
PS_CMD=""
for c in powershell powershell.exe; do
    if command -v "$c" >/dev/null 2>&1; then PS_CMD="$c"; break; fi
done
if [ -z "$PS_CMD" ]; then
    suite "Remove-PsComments: поведение"
    skip "Проверка вырезания на настоящих файлах" "powershell не доступен"
    summary
    exit 0
fi

# Harness намеренно ASCII-only: он пишется без BOM, а PowerShell 5.1 читает
# .ps1 без BOM в ANSI-кодировке — кириллица в нём разваливает разбор строк.
harness=$(mktemp_suffix /tmp/test_strip_harness_ .ps1)
win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
cat > "$harness" << 'PS1EOF'
param([string]$Root)
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'tools/_build_common.ps1')

function Count-Comments([string]$t) {
    $e = $null
    $toks = [System.Management.Automation.PSParser]::Tokenize($t, [ref]$e)
    return @($toks | Where-Object { $_.Type -eq 'Comment' }).Count
}

$files = @(
    'ffmpeg/FFmpeg_Converter_run_win_v18.ps1',
    'ffmpeg/FFmpeg_Converter_script.ps1',
    'ffmpeg/remote_client.ps1',
    'yt-dlp/Downloading_from_YouTube_v18.ps1'
)
foreach ($f in $files) {
    $full = Join-Path $Root $f
    $src  = [System.IO.File]::ReadAllText($full, [System.Text.Encoding]::UTF8)
    $out  = Remove-PsComments $src
    $key  = ($f -replace '[^A-Za-z0-9]', '_')
    Write-Output ("before_$key=" + (Count-Comments $src))
    Write-Output ("after_$key=" + (Count-Comments $out))
    Write-Output ("shrank_$key=" + [int]($out.Length -lt $src.Length))
}

# '#' вне комментария: в строке, в here-string и в пути. Построчный фильтр
# испортил бы эти данные молча, токенайзер - нет. Строки собираем массивом:
# вложенные here-string внутри этого harness сами по себе ломают разбор.
$q  = [char]34
$bs = [char]92
$trickyLines = @(
    ('$a = ' + $q + 'value # not a comment' + $q),
    ('$b = @' + $q),
    'line one # still data',
    ($q + '@'),
    ('$c = ' + "'" + 'C:' + $bs + 'dir#1' + $bs + 'file.txt' + "'" + '   # this one IS a comment'),
    'function f {',
    '    # whole-line comment',
    '    return $a + $b + $c',
    '}'
)
$tricky = $trickyLines -join [System.Environment]::NewLine
$strippedTricky = Remove-PsComments $tricky
Write-Output ("tricky_comments_left=" + (Count-Comments $strippedTricky))
Write-Output ("tricky_keeps_string=" + [int]($strippedTricky -match 'value # not a comment'))
Write-Output ("tricky_keeps_here=" + [int]($strippedTricky -match 'line one # still data'))
Write-Output ("tricky_keeps_path=" + [int]($strippedTricky -match 'dir#1'))

# #requires — директива, а не комментарий: её вырезание изменило бы поведение.
$req = "#requires -Version 5" + [System.Environment]::NewLine + "# plain comment" + [System.Environment]::NewLine + '$x = 1'
$strippedReq = Remove-PsComments $req
Write-Output ("requires_kept=" + [int]($strippedReq -match '#requires'))
Write-Output ("requires_plain_gone=" + [int](-not ($strippedReq -match 'plain comment')))

# Защита от собственной ошибки: если вырезание тронет код, функция обязана
# УПАСТЬ, а не отдать испорченный текст. Проверяем, что проверка вообще живая.
$guard = 'none'
try {
    $null = Remove-PsComments 'function broken { if ($a -eq 1) { '
    $guard = 'no-throw'
} catch { $guard = 'threw' }
Write-Output ("bad_input_throws=" + $guard)
PS1EOF

out=$($PS_CMD -NoProfile -NonInteractive -File "$win_harness" \
        -Root "$(cygpath -w "$PROJECT_DIR" 2>/dev/null || echo "$PROJECT_DIR")" 2>&1 | tr -d '\r')
rm -f "$harness"

get_field() { printf '%s\n' "$out" | grep "^${1}=" | sed "s/^${1}=//"; }

# ══════════════════════════════════════════════════════════════
suite "Remove-PsComments: на настоящих исходниках"
# ══════════════════════════════════════════════════════════════
for f in ffmpeg_FFmpeg_Converter_run_win_v18_ps1 \
         ffmpeg_FFmpeg_Converter_script_ps1 \
         ffmpeg_remote_client_ps1 \
         yt_dlp_Downloading_from_YouTube_v18_ps1; do
    before=$(get_field "before_$f")
    # Файл без единого комментария означал бы, что мы тестируем не то.
    if [ -z "$before" ] || [ "$before" = "0" ]; then
        fail "$f: в исходнике есть комментарии" "больше 0" "$before"
    else
        pass "$f: в исходнике есть комментарии ($before)"
    fi
    assert_eq "$f: в упакованной копии комментариев нет" "0" "$(get_field "after_$f")"
    assert_eq "$f: копия короче исходника"                "1" "$(get_field "shrank_$f")"
done

# ══════════════════════════════════════════════════════════════
suite "Remove-PsComments: '#' вне комментария не трогается"
# ══════════════════════════════════════════════════════════════
assert_eq "комментариев не осталось"            "0" "$(get_field tricky_comments_left)"
assert_eq "'#' внутри строки сохранён"          "1" "$(get_field tricky_keeps_string)"
assert_eq "'#' внутри here-string сохранён"     "1" "$(get_field tricky_keeps_here)"
assert_eq "'#' внутри пути сохранён"            "1" "$(get_field tricky_keeps_path)"
assert_eq "#requires сохранён (это директива)"  "1" "$(get_field requires_kept)"
assert_eq "обычный комментарий рядом удалён"    "1" "$(get_field requires_plain_gone)"
assert_eq "неразбираемый вход роняет сборку"    "threw" "$(get_field bad_input_throws)"

summary
