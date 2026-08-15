#!/bin/bash
# ============================================================
# test_13_path_limit.sh — Лимит длины пути в шаблоне -o.
#
# Причина: Windows MAX_PATH = 260 символов (259 + NUL). yt-dlp падал с
#   "unable to open for writing: [Errno 2] No such file or directory"
# на .part-файлах, потому что путь
#   <база 45> \ <uploader 8> \ <playlist 88> \ <001 - title(100)>.f140.m4a.part
# давал 264 символа. Папка (143) создавалась, а файл открыть уже нельзя —
# Win32 отдаёт ERROR_PATH_NOT_FOUND, Python переводит его в ENOENT, поэтому
# сообщение врёт про «нет такого файла».
#
# Защита живёт В ПРОГРАММЕ, а не в config.ini: лимиты проставляются в шаблон
# перед запуском yt-dlp, даже если ini отсутствует или задаёт шаблон без лимитов.
#
# Контракт (одинаков в SH/PS1/CMD):
#   budget = 259 - len(base) - 1(разделитель) - 32(резерв на .fNNN.m4a.part,
#            -FragNNN, .temp) ; длинным полям назначаются лимиты, при нехватке
#            бюджета ужимаются в порядке title → playlist → uploader.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v17.sh"
DLP_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v17.ps1"
DLP_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v17.cmd"

source "$TESTS_DIR/lib/framework.sh"

BASE45='C:\000\!_git\Downloading_from_YouTube\_video_'
TPL_PL='%(uploader)s\%(playlist)s\%(playlist_index)03d - %(title).100U.%(ext)s'
TPL_SINGLE='%(uploader)s\%(upload_date)s - %(title).100U.%(ext)s'
# Предел пути передаём ТРЕТЬИМ аргументом, а не полагаемся на определение по uname:
# ожидания ниже описывают поведение под Windows, а CI гоняет тот же .sh на Linux и
# macOS, где production-ветка считает бюджет от лимита компонента (255 байт) и даёт
# другие числа. Без явного аргумента тест был зелёным локально и красным в CI.
WIN_LIMIT=259

# ══════════════════════════════════════════════════════════════
suite "SH: limit_output_template — бюджет от длины базовой папки"
# ══════════════════════════════════════════════════════════════

# shellcheck disable=SC1090
source "$DLP_SH" > /dev/null 2>&1 < /dev/null

if ! declare -f limit_output_template > /dev/null; then
    skip "limit_output_template" "функция не определена в $DLP_SH"
else
    # База 45 символов → budget 181; дефолты (uploader 30 + playlist 45 +
    # playlist_index 4 + title 100 + ext 5 + литералы 6) = 190 → дефицит 9
    # снимается с title: 100 → 91.
    out=$(limit_output_template "$BASE45" "$TPL_PL" "$WIN_LIMIT")
    assert_eq "плейлист: title ужат до 91" \
        '%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).91U.%(ext)s' "$out"

    # Короткая база → бюджета хватает, title остаётся на дефолтных 100,
    # но playlist/uploader всё равно получают лимиты (их длина непредсказуема).
    out=$(limit_output_template 'C:\dl' "$TPL_PL" "$WIN_LIMIT")
    assert_eq "короткая база: title 100, лимиты проставлены" \
        '%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).100U.%(ext)s' "$out"

    # Поля без лимита обязаны его получить — иначе бюджет не гарантирован.
    out=$(limit_output_template 'C:\dl' '%(playlist)s\%(title)s.%(ext)s' "$WIN_LIMIT")
    assert_contains "playlist без лимита получает лимит" '%(playlist).45s' "$out"
    assert_contains "title без лимита получает лимит"    '%(title).100s'   "$out"

    # Пользовательский лимит меньше дефолта — уважается, не раздувается.
    out=$(limit_output_template 'C:\dl' '%(title).50U.%(ext)s' "$WIN_LIMIT")
    assert_contains "пользовательский .50U сохранён" '%(title).50U' "$out"

    # Пользовательский лимит больше бюджета — ужимается.
    out=$(limit_output_template "$BASE45" '%(playlist).200B\%(title).150U.%(ext)s' "$WIN_LIMIT")
    assert_not_contains "чрезмерный лимит playlist снят" '%(playlist).200B' "$out"
    assert_not_contains "чрезмерный лимит title снят"    '%(title).150U'    "$out"

    # Экстремально длинная база — минимумы, но шаблон остаётся валидным.
    long_base="C:\\$(printf 'x%.0s' $(seq 1 235))"
    out=$(limit_output_template "$long_base" "$TPL_PL" "$WIN_LIMIT")
    assert_contains "длинная база: title к минимуму 25"    '%(title).25U'    "$out"
    assert_contains "длинная база: playlist к минимуму 15" '%(playlist).15s' "$out"
    assert_contains "длинная база: uploader к минимуму 10" '%(uploader).10s' "$out"

    # Шаблон без «длинных» полей не трогаем.
    out=$(limit_output_template 'C:\dl' '%(id)s.%(ext)s' "$WIN_LIMIT")
    assert_eq "шаблон без длинных полей не меняется" '%(id)s.%(ext)s' "$out"

    # Идемпотентность: повторный прогон ничего не меняет (важно, потому что
    # GUI пересобирает команду на каждый URL очереди).
    once=$(limit_output_template "$BASE45" "$TPL_PL" "$WIN_LIMIT")
    twice=$(limit_output_template "$BASE45" "$once" "$WIN_LIMIT")
    assert_eq "идемпотентно" "$once" "$twice"

    # Одиночное видео: upload_date короткий, бюджета хватает.
    out=$(limit_output_template "$BASE45" "$TPL_SINGLE" "$WIN_LIMIT")
    assert_contains "одиночное видео: uploader лимитирован" '%(uploader).30s' "$out"
    assert_contains "одиночное видео: title 100"            '%(title).100U'   "$out"

    # Прямые слэши в шаблоне (формат config.ini) не должны ломать разбор.
    out=$(limit_output_template 'C:\dl' '%(uploader)s/%(playlist)s/%(title)s.%(ext)s' "$WIN_LIMIT")
    assert_contains "прямые слэши: playlist лимитирован" '%(playlist).45s' "$out"
    assert_contains "прямые слэши сохранены"             '%(uploader).30s/' "$out"

    # Вне Windows длину пути целиком никто не ограничивает — бьёт лимит ОДНОГО
    # компонента (255 байт, кириллица по два байта на символ), поэтому бюджет
    # считается от длины базы + 127 символов. Числа тут другие, и это нормально.
    posix_limit=$(( ${#BASE45} + 1 + 127 ))
    out=$(limit_output_template "$BASE45" "$TPL_PL" "$posix_limit")
    assert_eq "POSIX-режим: компонентный бюджет" \
        '%(uploader).30s\%(playlist).25s\%(playlist_index)03d - %(title).25U.%(ext)s' "$out"

    # Без третьего аргумента — платформенное значение: под Git Bash (MINGW) оно
    # обязано совпасть с явным 259, иначе production на Windows считает не то.
    if [ "$(uname -s 2>/dev/null | cut -c1-5)" = "MINGW" ]; then
        auto=$(limit_output_template "$BASE45" "$TPL_PL")
        assert_eq "автоопределение под Windows = 259" \
            "$(limit_output_template "$BASE45" "$TPL_PL" "$WIN_LIMIT")" "$auto"
    else
        auto=$(limit_output_template "$BASE45" "$TPL_PL")
        assert_eq "автоопределение вне Windows = компонентный лимит" \
            "$(limit_output_template "$BASE45" "$TPL_PL" "$posix_limit")" "$auto"
    fi
fi

# ══════════════════════════════════════════════════════════════
suite "SH: шаблон уходит в yt-dlp уже ограниченным"
# ══════════════════════════════════════════════════════════════
sh_src="$(cat "$DLP_SH")"
assert_contains "limit_output_template определена"  "limit_output_template()"  "$sh_src"
# Обе точки сборки -o (download_url и download_batch) обязаны звать лимитер:
# иначе защита работает в одном режиме и молча отсутствует в другом.
limit_calls=$(grep -c '$(limit_output_template "' "$DLP_SH")
assert_eq "лимитер вызван на всех 4 точках сборки шаблона" "4" "$limit_calls"

# ══════════════════════════════════════════════════════════════
suite "CMD: :limit_template (реальные подпрограммы из production)"
# ══════════════════════════════════════════════════════════════
cmd_src="$(cat "$DLP_CMD")"
assert_contains "CMD: шаблон строится через :limit_template" 'call :limit_template' "$cmd_src"
assert_not_contains "CMD: нет захардкоженного .100U в шаблоне" 'set "output_tpl=%%(uploader)s' "$cmd_src"

if ! cmd //c "exit 0" &>/dev/null; then
    skip "CMD: расчёт бюджета" "cmd.exe не доступен"
else
    # Подпрограммы берём ИЗ production-файла (не копия) — иначе тест зеленеет
    # на устаревшей копии, как это уже было с таблицей форматов.
    run_limit() {
        local folder="$1"
        local tmp_cmd; tmp_cmd=$(mktemp_suffix /tmp/test_ytlimit_ .cmd)
        {
            printf '@echo off\nchcp 65001 >nul 2>&1\nsetlocal enabledelayedexpansion\n'
            printf 'set "folder=%s"\n' "$folder"
            printf 'call :limit_template\n'
            printf 'echo PL=!playlist_tpl!\n'
            printf 'echo SG=!output_tpl!\n'
            printf 'exit /b 0\n'
            sed -n '/^:limit_template/,$p' "$DLP_CMD"
        } | sed 's/$/\r/' > "$tmp_cmd"   # CMD требует CRLF, иначе блоки ( … ) склеиваются
        local win_path; win_path=$(cygpath -w "$tmp_cmd" 2>/dev/null || echo "$tmp_cmd")
        cmd //c "$win_path" 2>/dev/null | tr -d '\r'
        rm -f "$tmp_cmd"
    }

    # База той же длины (45), но без '!': одиночный '!' съедается при записи строки
    # в .cmd с delayed expansion, и папка стала бы на символ короче — проверялся бы
    # не расчёт, а экранирование. Путь с '!' проверяется отдельным кейсом ниже.
    out=$(run_limit 'C:\000\x_git\Downloading_from_YouTube\_video_')
    assert_eq "CMD плейлист = SH/PS1" \
        'PL=%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).91U.%(ext)s' \
        "$(printf '%s\n' "$out" | grep '^PL=')"
    assert_eq "CMD одиночное видео = SH" \
        'SG=%(uploader).30s\%(upload_date)s - %(title).100U.%(ext)s' \
        "$(printf '%s\n' "$out" | grep '^SG=')"

    out=$(run_limit 'C:\dl')
    assert_contains "CMD короткая база: title 100" '%(title).100U' "$(printf '%s\n' "$out" | grep '^PL=')"

    long_base="C:\\$(printf 'x%.0s' $(seq 1 235))"
    out=$(run_limit "$long_base")
    pl_line=$(printf '%s\n' "$out" | grep '^PL=')
    assert_contains "CMD длинная база: title к минимуму 25"    '%(title).25U'    "$pl_line"
    assert_contains "CMD длинная база: playlist к минимуму 15" '%(playlist).15s' "$pl_line"
    assert_contains "CMD длинная база: uploader к минимуму 10" '%(uploader).10s' "$pl_line"

    # :strlen должен считать путь с '!' верно (реальный путь из бага: C:\000\!_git\…).
    # В .cmd одиночный '!' при delayed expansion съедается, поэтому экранируем.
    out=$(run_limit 'C:\000\^!_git\Downloading_from_YouTube\_video_')
    assert_eq "CMD путь с '!' считается как 45 символов" \
        'PL=%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).91U.%(ext)s' \
        "$(printf '%s\n' "$out" | grep '^PL=')"
fi

# ══════════════════════════════════════════════════════════════
suite "PS1: Limit-OutputTemplate (реальная функция)"
# ══════════════════════════════════════════════════════════════
PS_CMD=""
command -v powershell &>/dev/null && PS_CMD="powershell"
[ -z "$PS_CMD" ] && command -v pwsh &>/dev/null && PS_CMD="pwsh"

winforms_ok=0
if [ -n "$PS_CMD" ]; then
    probe=$($PS_CMD -NoProfile -NonInteractive -Command "try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; 'ok' } catch { 'no' }" 2>/dev/null | tr -d '\r')
    [ "$probe" = "ok" ] && winforms_ok=1
fi

if [ "$winforms_ok" -ne 1 ]; then
    skip "Limit-OutputTemplate" "нет Windows PowerShell + WinForms"
else
    win_prod=$(cygpath -w "$DLP_PS1" 2>/dev/null || echo "$DLP_PS1")
    harness=$(mktemp_suffix /tmp/test_pathlimit_ .ps1)
    win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
    cat > "$harness" << 'PS1EOF'
param([string]$Prod)
$ErrorActionPreference = 'Stop'
$env:YTDLP_TEST = '1'
. $Prod
$base45 = 'C:\000\!_git\Downloading_from_YouTube\_video_'
$tplPl  = '%(uploader)s\%(playlist)s\%(playlist_index)03d - %(title).100U.%(ext)s'
$WIN = 259   # предел передаём явно — паритет с .sh сверяется по одинаковым числам
Write-Output ("pl="     + (Limit-OutputTemplate $base45 $tplPl $WIN))
Write-Output ("short="  + (Limit-OutputTemplate 'C:\dl' $tplPl $WIN))
Write-Output ("nolimit="+ (Limit-OutputTemplate 'C:\dl' '%(playlist)s\%(title)s.%(ext)s' $WIN))
Write-Output ("user50=" + (Limit-OutputTemplate 'C:\dl' '%(title).50U.%(ext)s' $WIN))
Write-Output ("plain="  + (Limit-OutputTemplate 'C:\dl' '%(id)s.%(ext)s' $WIN))
$long = 'C:\' + ('x' * 235)
Write-Output ("long="   + (Limit-OutputTemplate $long $tplPl $WIN))
$once = Limit-OutputTemplate $base45 $tplPl $WIN
Write-Output ("idem="   + ((Limit-OutputTemplate $base45 $once $WIN) -eq $once))
# Без третьего аргумента production обязан взять те же 259 — иначе GUI считает не то.
Write-Output ("default="+ ((Limit-OutputTemplate $base45 $tplPl) -eq $once))
PS1EOF
    ps_out=$($PS_CMD -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$win_harness" "$win_prod" 2>&1 | tr -d '\r')
    rm -f "$harness"

    get_field() { printf '%s\n' "$1" | grep "^${2}=" | sed "s/^${2}=//"; }

    assert_eq "PS1 плейлист = SH" \
        '%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).91U.%(ext)s' \
        "$(get_field "$ps_out" pl)"
    assert_eq "PS1 короткая база = SH" \
        '%(uploader).30s\%(playlist).45s\%(playlist_index)03d - %(title).100U.%(ext)s' \
        "$(get_field "$ps_out" short)"
    assert_contains "PS1 playlist без лимита"  '%(playlist).45s'  "$(get_field "$ps_out" nolimit)"
    assert_contains "PS1 пользовательский .50U" '%(title).50U'    "$(get_field "$ps_out" user50)"
    assert_eq "PS1 шаблон без длинных полей"    '%(id)s.%(ext)s'  "$(get_field "$ps_out" plain)"
    assert_contains "PS1 длинная база → минимум" '%(title).25U'   "$(get_field "$ps_out" long)"
    assert_eq "PS1 идемпотентно"                "True"            "$(get_field "$ps_out" idem)"
    assert_eq "PS1 без аргумента = 259"         "True"            "$(get_field "$ps_out" default)"
fi

summary
