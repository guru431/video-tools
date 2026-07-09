#!/bin/bash
# ============================================================
# test_guardrails.sh — статические guardrail'ы (read-only grep по исходникам).
# Ловят повторное появление опасных паттернов ДО ревью: ручная сборка argv-строки,
# temp-dir на %RANDOM%, бинарь без резолвинга рядом со скриптом, отключение TLS и т.п.
# Чистый bash, без PowerShell/cmd — идёт на любой платформе.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
YT_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
FF_CMD="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"

ps1="$(cat "$YT_PS1")"
ycmd="$(cat "$YT_CMD")"
ysh="$(cat "$YT_SH")"
ffcmd="$(cat "$FF_CMD")"

# ── yt-dlp PS1: единый argv-квотер, не ручная сборка строки ────────────────
suite "guardrails: yt-dlp PS1 argv/квотирование"
assert_not_contains "нет ручного \$command -join (argv)"  '$command -join'  "$ps1"
assert_contains "Quote-WinArg присутствует"               "function Quote-WinArg"  "$ps1"
assert_contains "Join-WinArgs присутствует"               "function Join-WinArgs"  "$ps1"
# ffmpeg для мержа — через резолвер \$ffmpegBin, не bare `& ffmpeg`.
assert_not_contains "нет bare '& ffmpeg @ffArgs'"         '& ffmpeg @ffArgs'  "$ps1"
assert_contains "мерж через \$ffmpegBin"                  '& $ffmpegBin @ffArgs'  "$ps1"

# ── yt-dlp CMD: GUID temp-dir, резолвер ffmpeg ────────────────────────────
suite "guardrails: yt-dlp CMD temp-dir/ffmpeg"
assert_contains "temp-dir через GUID (не голый %RANDOM%)"  "[guid]::NewGuid"  "$ycmd"
assert_contains "ffmpeg-резолвер (рядом со скриптом)"     '%~dp0ffmpeg.exe'  "$ycmd"
assert_contains "мерж через !ff_cmd!"                     '"!ff_cmd!" -y'  "$ycmd"

# ── ffmpeg CMD: детект имён с '!' ─────────────────────────────────────────
suite "guardrails: ffmpeg CMD '!'-детект"
assert_contains "подпрограмма :warn_bang_names"           ":warn_bang_names"  "$ffcmd"
assert_contains "вызов детекта перед циклом"              "call :warn_bang_names"  "$ffcmd"

# ── Security-инварианты (все yt-dlp платформы) ────────────────────────────
suite "guardrails: security"
assert_not_contains "PS1: нет --no-check-certificate"     "--no-check-certificate"  "$ps1"
assert_not_contains "CMD: нет --no-check-certificate"     "--no-check-certificate"  "$ycmd"
assert_not_contains "SH: нет --no-check-certificate"      "--no-check-certificate"  "$ysh"
# TLS отключается только для vot-cli-live и ОБЯЗАТЕЛЬНО сбрасывается назад.
assert_contains "CMD: NODE_TLS сбрасывается"              'set "NODE_TLS_REJECT_UNAUTHORIZED="'  "$ycmd"

summary
