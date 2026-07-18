#!/bin/bash
# ============================================================
# test_path_matrix.sh — adversarial матрица имён/путей для Windows-оболочек.
#   A. Quote-WinArg (production PS1) на сложных аргументах: пробел, %, ^, &, ', #,
#      кавычка, хвостовой backslash, пустой. Проверяет CommandLineToArgvW-корректность
#      (метасимволы cmd.exe — литералы, кавычим только при пробеле/кавычке).
#   B. ffmpeg CMD '!'-детект: имена с '!' помечаются, а пробел/%/& — нет.
# Каждая часть скипается, если нет нужной оболочки.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v16.ps1"

# ══════════════════════════════════════════════════════════════
# Часть A — Quote-WinArg (production), широкая матрица.
# ══════════════════════════════════════════════════════════════
PS_CMD=""
command -v powershell &>/dev/null && PS_CMD="powershell"
[ -z "$PS_CMD" ] && command -v pwsh &>/dev/null && PS_CMD="pwsh"
winforms_ok=0
if [ -n "$PS_CMD" ]; then
    probe=$($PS_CMD -NoProfile -NonInteractive -Command "try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop; 'ok' } catch { 'no' }" 2>/dev/null | tr -d '\r')
    [ "$probe" = "ok" ] && winforms_ok=1
fi

suite "path matrix: Quote-WinArg (CommandLineToArgvW)"
if [ "$winforms_ok" -ne 1 ]; then
    skip "Quote-WinArg матрица" "нет Windows PowerShell + WinForms"
else
    win_prod=$(cygpath -w "$YT_PS1" 2>/dev/null || echo "$YT_PS1")
    harness=$(mktemp /tmp/test_pathmx_XXXXXX.ps1)
    win_harness=$(cygpath -w "$harness" 2>/dev/null || echo "$harness")
    # Матрица (arg, key) задана в самом harness — избегаем bash-экранирования " ' & % ^.
    cat > "$harness" << 'PS1EOF'
param([string]$Prod)
$ErrorActionPreference = 'Stop'
$env:YTDLP_TEST = '1'
. $Prod
$cases = @(
    @('m_pct',    'a%b'),
    @('m_caret',  'a^b'),
    @('m_amp',    'a&b'),
    @('m_squote', "a'b"),
    @('m_hash',   'a#b'),
    @('m_plain',  'plain-best[height<=720]'),
    @('m_sppct',  'a b%c&d'),
    @('m_quote',  'a"b c'),
    @('m_tailbs', 'C:\a b\'),
    @('m_empty',  '')
)
foreach ($c in $cases) { Write-Output ($c[0] + '=' + (Quote-WinArg $c[1])) }
PS1EOF
    out=$($PS_CMD -NoProfile -NonInteractive -File "$win_harness" -Prod "$win_prod" 2>/dev/null | tr -d '\r')
    rm -f "$harness"
    gf() { printf '%s\n' "$out" | grep "^${1}=" | sed "s/^${1}=//"; }

    # Метасимволы cmd.exe (% ^ & ' #) без пробела/кавычки → НЕ квотируются.
    assert_eq "a%b без изменений"    "a%b"  "$(gf m_pct)"
    assert_eq "a^b без изменений"    "a^b"  "$(gf m_caret)"
    assert_eq "a&b без изменений"    "a&b"  "$(gf m_amp)"
    assert_eq "a'b без изменений"    "a'b"  "$(gf m_squote)"
    assert_eq "a#b без изменений"    "a#b"  "$(gf m_hash)"
    assert_eq "plain без изменений"  "plain-best[height<=720]"  "$(gf m_plain)"
    # Пробел → кавычки; спецсимволы внутри остаются литералами.
    assert_eq "'a b%c&d' → в кавычках"  '"a b%c&d"'  "$(gf m_sppct)"
    # Кавычка → \" + пробел → всё в кавычках.
    assert_eq "'a\"b c' → экранирование"  '"a\"b c"'  "$(gf m_quote)"
    # Хвостовой backslash перед закрывающей кавычкой удваивается.
    assert_eq "'C:\\a b\\' → \\\\ в конце"  '"C:\a b\\"'  "$(gf m_tailbs)"
    assert_eq "пустой → \"\""  '""'  "$(gf m_empty)"
fi

# ══════════════════════════════════════════════════════════════
# Часть B — ffmpeg CMD '!'-детект на adversarial именах.
# ══════════════════════════════════════════════════════════════
suite "path matrix: ffmpeg CMD '!'-детект"
have_cmd=0
command -v cmd &>/dev/null && have_cmd=1
if [ "$have_cmd" -ne 1 ]; then
    skip "'!'-детект матрица" "нет cmd (не Windows)"
else
    workdir=$(mktemp -d /tmp/test_bang_XXXXXX)
    : > "$workdir/plain.mp4"
    : > "$workdir/with space.mp4"
    : > "$workdir/pct%.mp4"
    : > "$workdir/amp&.mp4"
    : > "$workdir/bang!.mp4"
    : > "$workdir/two!!.mp4"
    drv=$(mktemp /tmp/test_bang_drv_XXXXXX.cmd)
    cat > "$drv" << 'CMDEOF'
@echo off
setlocal enabledelayedexpansion
set "folder_sources=%~1"
set "format_files_in=mp4"
set "format_files_in_pattern=*.%format_files_in:,= *.%"
call :warn_bang_names
exit /b
:warn_bang_names
setlocal disabledelayedexpansion
set "_bang_tmp=%temp%\ffbang_%random%.txt"
(for /r "%folder_sources%" %%a in (%format_files_in_pattern%) do @echo %%~nxa) 2>nul | findstr /c:"!" > "%_bang_tmp%"
for /f "usebackq delims=" %%z in ("%_bang_tmp%") do echo BANG:%%z
del "%_bang_tmp%" 2>nul
endlocal
exit /b
CMDEOF
    win_src=$(cygpath -w "$workdir")
    win_drv=$(cygpath -w "$drv")
    res=$(cmd //c "$win_drv" "$win_src" 2>/dev/null | tr -d '\r')
    rm -f "$drv"; rm -rf "$workdir"

    assert_contains "bang!.mp4 помечен"    "BANG:bang!.mp4"   "$res"
    assert_contains "two!!.mp4 помечен"    "BANG:two!!.mp4"   "$res"
    assert_not_contains "plain.mp4 НЕ помечен"       "BANG:plain.mp4"       "$res"
    assert_not_contains "'with space.mp4' НЕ помечен" "BANG:with space.mp4"  "$res"
    assert_not_contains "pct%.mp4 НЕ помечен"        "BANG:pct%.mp4"        "$res"
    assert_not_contains "amp&.mp4 НЕ помечен"        "BANG:amp&.mp4"        "$res"
fi

summary
