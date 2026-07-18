#!/bin/bash
# ============================================================
# test_17_literal_paths.sh — F1: пути с wildcard-символами PowerShell.
#
# Симптом: имена вида "Season [1]" в дереве источника PowerShell трактовал как
# МАСКУ, а не как литерал. Позиционный -Path у Get-ChildItem глоббит, маска ни с
# чем не совпадает — обход возвращал 0 файлов, и батч завершался «успешно»,
# не сделав ничего. Test-Path/Remove-Item по тем же путям промахивались, а
# Remove-Item по маске в принципе способен снести не тот файл.
#
# Наивное лечение (просто дописать -LiteralPath к строке обхода) ЛОМАЕТ фильтр:
# при -LiteralPath параметр -Include молча игнорируется, и в перекодирование
# уходят .srt/.jpg/.txt. Поэтому фильтр по расширению вынесен в Where-Object.
# Тест закрывает обе половины: и обнаружение файлов, и то, что фильтр уцелел.
#
# Запускает НАСТОЯЩИЙ FFmpeg_Converter_script.ps1 (dot-source, как run_v16.ps1).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

SCRIPT_PS1="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"
if [ ! -f "$SCRIPT_PS1" ]; then
    suite "F1: литеральные пути"
    fail "production-скрипт на месте" "$SCRIPT_PS1" "файл не найден"
    summary
    exit 1
fi

# PS1 тесты — только Windows (Windows PowerShell semantics, cygpath-пути).
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*|*NT*) : ;; *) _ps_skip=1 ;; esac
if [ -n "${_ps_skip:-}" ] || { ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; }; then
    suite "F1: литеральные пути"
    skip "Все PS1 literal-path тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

WORK=$(mktemp -d /tmp/test_literal_XXXXXX)
# Имя каталога намеренно содержит [ ] — ровно тот класс, что ломал обход.
IN="$WORK/Season [1] (4K)"
DST="$WORK/out [enc]"
mkdir -p "$IN/nested [x]" "$DST"

# Полезная нагрузка: 2 видео в корне + 1 во вложенном каталоге со скобками.
: > "$IN/a.mp4"
: > "$IN/b.mkv"
: > "$IN/nested [x]/c.avi"
# Приманки: sidecar-субтитры и картинка НЕ должны попасть в перекодирование.
: > "$IN/a.srt"
: > "$IN/poster.jpg"
# Каталог с «расширением» видео: старый -Include пропускал его как FileInfo.
mkdir -p "$IN/decoy.mp4"

# Гоняет реальный воркер в dry_run и печатает его stdout.
# dry_run=yes: ffmpeg не вызывается для кодирования, но обход дерева и все
# Test-Path/New-Item на пути к нему исполняются по-настоящему — то, что нужно.
run_worker() {
    local extra="$1"
    local w_script w_in w_dst w_mock
    w_script=$(cygpath -w "$SCRIPT_PS1")
    w_in=$(cygpath -w "$IN"); w_dst=$(cygpath -w "$DST")
    w_mock=$(cygpath -w "$TESTS_DIR/mocks/ffmpeg.cmd")

    MOCK_FFMPEG_ENCODERS="" "$PS_CMD" -NoProfile -NonInteractive -Command "
\$ErrorActionPreference='Continue'
# cygpath -w отдаёт короткий 8.3-путь, а .NET DirectoryName — длинный: без
# нормализации strip-префикса в Encode-File не срабатывает (см. test_16).
\$folder_sources=(Get-Item -LiteralPath '$w_in').FullName + [IO.Path]::DirectorySeparatorChar
\$folder_destination=(Get-Item -LiteralPath '$w_dst').FullName + [IO.Path]::DirectorySeparatorChar
\$ffmpeg='$w_mock'; \$ffprobe='$w_mock'
\$audio_codec=':+:aac'; \$audio_number_channels=':-:2'; \$audio_bitrate=':-:128'
\$audio_sampling_rate=':-:44100'; \$audio_normalize=':-:loudnorm'
\$video_codec=':+:libx264'; \$video_resolution=':-:1280x720'; \$video_bitrate=':-:2000'
\$video_number_frames=':-:25'; \$video_rotation=':-:2'; \$video_subtitles=':-:burn'
\$video_quality=':+:23'; \$keep_aspect_ratio=':+:yes'; \$output_container=':+:mp4'
\$multithreads=':-:4'; \$parallel_files=':-:2'
\$hw_accel=':-:nvidia'; \$gpu_preset=':-:p5'; \$gpu_tune=':-:hq'; \$gpu_rc=':-:vbr'
\$playback_speed=':-:1.0'; \$start_coding=':-:01-00-00'; \$length_coding=':-:00-05-00'
\$split_by_silence='no'; \$silence_duration='2.0'; \$silence_threshold='-30dB'
\$save_old_extension='no'; \$format_files_in='mp4, mkv ,avi'
\$subtitles_style=''; \$dry_run='yes'; \$enable_log='no'; \$log_file=''
\$audio_only='no'; \$merge_files='no'; \$create_frame='no'
\$copy_codecs='no'; \$extract_audio_copy='no'; \$overwrite_existing='yes'
$extra
. '$w_script'
" 2>&1
}

# ══════════════════════════════════════════════════════════════
suite "F1: обход дерева с [ ] в именах"
# ══════════════════════════════════════════════════════════════

OUT=$(run_worker "")

# Суть находки: раньше здесь было ПУСТО и батч рапортовал успех.
assert_contains "файл в корне со скобками найден"        "a.mp4"  "$OUT"
assert_contains "второй файл в корне найден"             "b.mkv"  "$OUT"
assert_contains "файл во вложенном [x] найден"           "c.avi"  "$OUT"

# Вторая половина: -LiteralPath глушит -Include, фильтр обязан выжить отдельно.
assert_not_contains "sidecar .srt НЕ перекодируется"     "a.srt"     "$OUT"
assert_not_contains "картинка .jpg НЕ перекодируется"    "poster.jpg" "$OUT"
assert_not_contains "каталог decoy.mp4 НЕ взят как файл" "decoy.mp4" "$OUT"

# ══════════════════════════════════════════════════════════════
suite "F1: создание выходных каталогов по литеральному пути"
# ══════════════════════════════════════════════════════════════

# New-Item не имеет -LiteralPath ни в одной версии PowerShell, поэтому каталоги
# создаются через [IO.Directory]::CreateDirectory. Если бы осталось New-Item,
# подкаталог назначения для "nested [x]" не создался бы (или создался с
# буквальными скобками не там, где нужно).
if [ -d "$DST/nested [x]" ]; then
    pass "подкаталог назначения 'nested [x]' создан"
else
    fail "подкаталог назначения 'nested [x]' создан" "каталог существует" "не создан"
fi

# ══════════════════════════════════════════════════════════════
suite "F1: спецрежимы по путям со скобками"
# ══════════════════════════════════════════════════════════════

# Извлечение кадров бьёт по Test-Path/Remove-Item/New-Item сразу в четырёх местах.
OUT=$(run_worker "\$create_frame='yes'")
assert_contains "create_frame: файл со скобками в пути обработан" "a.mp4" "$OUT"
assert_not_contains "create_frame: ошибок пути нет" "не найден" "$OUT"

# extract_audio_copy — отдельная ветка с Test-Path/Remove-Item/Get-Item.
OUT=$(run_worker "\$extract_audio_copy='yes'")
assert_contains "extract_audio: файл со скобками в пути обработан" "a.mp4" "$OUT"
assert_not_contains "extract_audio: ошибок пути нет" "не найден" "$OUT"

# ══════════════════════════════════════════════════════════════
suite "F1: анти-регресс — позиционный -Path не вернулся"
# ══════════════════════════════════════════════════════════════
# Статическая проверка: пара «-LiteralPath + Where-Object» легко откатывается
# обратно к -Include при следующей правке, и поведенческий тест выше это поймает
# только на Windows. Здесь фиксируем сам контракт в исходнике.
src="$(cat "$SCRIPT_PS1")"
assert_contains "обход использует -LiteralPath"          'Get-ChildItem -LiteralPath $folder_sources' "$src"
assert_not_contains "-Include не вернулся (он молча игнорируется при -LiteralPath)" '-Recurse -Include' "$src"
assert_contains "фильтр расширений вынесен в Where-Object" '$_in_exts -contains $_.Extension' "$src"
assert_not_contains "New-Item по пользовательским путям убран" 'New-Item -ItemType Directory $frame_dir' "$src"

rm -rf "$WORK"
summary
