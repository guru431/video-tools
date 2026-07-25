#!/bin/bash
# ============================================================
# test_19_findings_paths.sh — находки deep-analysis по путям/выборке входов:
#   P1 — хвостовой разделитель в [folders] source не уводит выход мимо destination;
#   P2 — прямые слэши в source нормализуются (форма пути из общего config.ini);
#   P3 — каталог с «расширением» в имени ("season.mp4") не берётся во вход;
#   P4 — dry_run не создаёт каталоги зеркала в destination;
#   P5 — недобитый temp (.ffconv-partial-*) не становится входом следующего прогона;
#   P6 — «выход == вход» учитывает гарантированный суффикс " (part.1)" ([split] start);
#   P7 — диапазон playback_speed в GUI совпадает со скриптовым (0 < v <= 100);
#   P8 — GUI имеет контрол overwrite_existing;
#   P9 — валидация CRF в GUI отсекает отрицательные значения (гард от регресса).
# SH проверяется поведенчески (source "$SCRIPT"); PS1/CMD — source-scan (нет
# кроссплатформенного раннера в Git Bash), как и в test_15/test_18.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS_DIR="$TESTS_DIR/mocks"
source "$TESTS_DIR/lib/framework.sh"

WORK=$(mktemp -d /tmp/test_ff_a19_XXXXXX)
IN="$WORK/in"; DST="$WORK/out"; FFMPEG_LOG="$WORK/mock.log"
mkdir -p "$IN" "$DST"

default_vars() {
    folder_sources="$IN"; folder_destination="$DST"
    ffmpeg="$MOCKS_DIR/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":-:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":+:23"; keep_aspect_ratio=":+:yes"; output_container=":+:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi,webm"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"
    copy_codecs="no"; extract_audio_copy="no"; overwrite_existing="no"
}

run_capture() {
    rm -f "$FFMPEG_LOG"
    OUT_TEXT=$(
        export PATH="$MOCKS_DIR:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        default_vars
        for ov in "$@"; do eval "$ov"; done
        source "$SCRIPT" 2>&1
    ) < /dev/null
    RC=$?
}
log_has() { [ -f "$FFMPEG_LOG" ] && grep -qF -- "$1" "$FFMPEG_LOG"; }

SH_SRC="$(cat "$SCRIPT")"
PS1_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1")"
CMD_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")"
GUI_SRC="$(cat "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v16.ps1")"
CFG_SRC="$(cat "$PROJECT_DIR/ffmpeg/config.ini")"

# ══════════════════════════════════════════════════════════════
suite "P1: хвостовой разделитель в source не уводит выход мимо destination"
# ══════════════════════════════════════════════════════════════
# Относительный путь подпапки считается вычитанием строки source из каталога файла.
# Лишний '/' съедал ведущий разделитель: dest + 'sub/' давало '.../outsub/'.
mkdir -p "$IN/sub"
touch "$IN/sub/movie.mp4"
run_capture 'folder_sources="$IN/"'
if [ -f "$DST/sub/movie.mp4" ]; then pass "source с '/' на конце: выход в out/sub/"; else fail "source с '/' на конце: выход в out/sub/" "есть out/sub/movie.mp4" "нет"; fi
if [ ! -e "${WORK}/outsub" ]; then pass "source с '/' на конце: нет каталога-соседа outsub"; else fail "нет каталога-соседа outsub" "не создан" "создан ${WORK}/outsub"; fi
# Файл в КОРНЕ source: раньше имя приклеивалось прямо к каталогу (.../outmovie.mp4).
touch "$IN/root.mp4"
run_capture 'folder_sources="$IN/"'
if [ -f "$DST/root.mp4" ]; then pass "source с '/' на конце: файл из корня в out/"; else fail "файл из корня в out/" "есть out/root.mp4" "нет"; fi
if [ ! -e "${WORK}/outroot.mp4" ]; then pass "нет склейки '.../outroot.mp4'"; else fail "нет склейки '.../outroot.mp4'" "не создан" "создан"; fi
rm -rf "$IN/sub" "$IN/root.mp4" "$DST/sub" "$DST/root.mp4" "$DST/.root.ffconv"

# Нормализация — в самом script.* (choke point: покрывает и CLI, и GUI).
assert_contains "SH: нормализация корневых путей есть"      'folder_sources="$(norm_folder "$folder_sources")"' "$SH_SRC"
assert_contains "SH: destination тоже нормализуется"        'folder_destination="$(norm_folder "$folder_destination")"' "$SH_SRC"
assert_contains "PS1: нормализация корневых путей есть"     '$folder_sources     = Normalize-FolderPath $folder_sources' "$PS1_SRC"
assert_contains "CMD: нормализация корневых путей есть"     'call :norm_folder folder_sources' "$CMD_SRC"
assert_contains "CMD: подпрограмма :norm_folder на месте"   ':norm_folder' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "P2: прямые слэши в source (общий config.ini на 3 платформы)"
# ══════════════════════════════════════════════════════════════
# `source = C:/video/in` работал в SH и ронял PS1: regex-вычитание сырой строки не
# совпадало с '\'-формой $file.DirectoryName, и путь выхода превращался в мусор.
assert_contains "PS1: '/' и '\\' приводятся к разделителю платформы" ".Replace('/', \$s).Replace('\\', \$s)" "$PS1_SRC"
assert_contains "PS1: относительный путь считается канонизированно" 'function Get-RelDir' "$PS1_SRC"
assert_not_contains "PS1: нет regex-вычитания сырой строки source"  '-replace [regex]::Escape($folder_sources)' "$PS1_SRC"
assert_contains "PS1: карта коллизий использует ту же формулу"      '$_dir = Get-RelDir $_f.DirectoryName' "$PS1_SRC"
assert_contains "CMD: '/' приводится к '\\'"                        'set "_nf=!_nf:/=\!"' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "P3: каталог с расширением в имени не берётся во вход"
# ══════════════════════════════════════════════════════════════
# Каталог "season.mp4" попадал в выборку: ffmpeg падал на нём лишним FAIL, а его
# «выход» — обычный файл — занимал имя каталога зеркала для файлов внутри.
mkdir -p "$IN/season.mp4"
touch "$IN/season.mp4/ep.mp4"
run_capture
assert_not_contains "каталог 'season.mp4' не дал FAIL" "[FAIL]" "$OUT_TEXT"
if [ -f "$DST/season.mp4/ep.mp4" ]; then pass "файл внутри 'season.mp4' сконвертирован"; else fail "файл внутри 'season.mp4' сконвертирован" "есть out/season.mp4/ep.mp4" "нет"; fi
if [ -d "$DST/season.mp4" ]; then pass "'season.mp4' в destination — каталог, а не файл"; else fail "'season.mp4' в destination — каталог" "каталог" "не каталог"; fi
rm -rf "$IN/season.mp4" "$DST/season.mp4"

assert_contains "SH: выборка входов через -type f"          'find "$folder_sources" -type f' "$SH_SRC"
assert_contains "SH: единая функция выборки find_inputs"    'find_inputs() {' "$SH_SRC"
assert_contains "PS1: Get-ChildItem -File"                  'Get-ChildItem -LiteralPath $folder_sources -Recurse -File' "$PS1_SRC"
assert_contains "CMD: каталог отсекается в :process_file"    'if exist "!full_path!\" exit /b' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "P4: dry_run не создаёт каталоги зеркала"
# ══════════════════════════════════════════════════════════════
# Контракт D7 («dry-run только печатает команду») нарушался для каталогов: дерево
# подпапок появлялось физически и маскировало ошибки в самом пути.
mkdir -p "$IN/deep"
touch "$IN/deep/d.mp4"
run_capture 'dry_run="yes"'
assert_contains "dry_run: команда напечатана" "[DRY-RUN]" "$OUT_TEXT"
if [ ! -e "$DST/deep" ]; then pass "dry_run: подпапка destination не создана"; else fail "dry_run: подпапка не создана" "нет out/deep" "создана"; fi
# Контроль: настоящий прогон каталог создаёт.
run_capture
if [ -d "$DST/deep" ]; then pass "обычный прогон: подпапка создана"; else fail "обычный прогон: подпапка создана" "есть out/deep" "нет"; fi
rm -rf "$IN/deep" "$DST/deep"

assert_contains "SH: mkdir под guard'ом dry_run"   'if [ "$dry_run" != "yes" ] && [ ! -d "$folder_destination$file_path" ]' "$SH_SRC"
assert_contains "PS1: New-DirLiteral под guard'ом" 'if ($dry_run -ne "yes") { New-DirLiteral "$folder_destination$file_path" }' "$PS1_SRC"
assert_contains "CMD: md под guard'ом dry_run"     'if not "%dry_run%"=="yes" if not exist "%folder_destination%!file_path!" md' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "P5: .ffconv-partial-* не становится входом следующего прогона"
# ══════════════════════════════════════════════════════════════
# Недобитый temp прерванного прогона подпадает под маску *.mp4; в in-place режиме
# (destination == source) он попадал во вход следующего запуска.
touch "$IN/.ffconv-partial-orphan.mp4"
touch "$IN/ok.mp4"
run_capture
if log_has ".ffconv-partial-orphan.mp4"; then fail "partial-файл не берётся во вход" "нет вызова ffmpeg на него" "вызван"; else pass "partial-файл не берётся во вход"; fi
if [ -f "$DST/ok.mp4" ]; then pass "обычный файл рядом с partial сконвертирован"; else fail "обычный файл сконвертирован" "есть out/ok.mp4" "нет"; fi
rm -f "$IN/.ffconv-partial-orphan.mp4" "$IN/ok.mp4" "$DST/ok.mp4" "$DST/.ok.ffconv"

assert_contains "SH: выборка исключает .ffconv-partial-*"  "! -name '.ffconv-partial-*'" "$SH_SRC"
assert_contains "PS1: выборка исключает .ffconv-partial-*" "-not \$_.Name.StartsWith('.ffconv-partial-')" "$PS1_SRC"
assert_contains "CMD: выборка исключает .ffconv-partial-*" 'if /i "!pf_nx:~0,16!"==".ffconv-partial-" exit /b' "$CMD_SRC"
# Дочерние процессы параллельной ветки чистят свой temp сами (у родителя свой trap).
assert_contains "SH: trap в дочернем bash -c"              'trap _cleanup_child_on_int INT TERM; encode_file' "$SH_SRC"
assert_contains "SH: дочерний cleanup удаляет свой temp"   '[ -n "${_current_out_tmp:-}" ] && rm -f "$_current_out_tmp"' "$SH_SRC"
assert_contains "SH: родительский cleanup тоже удаляет temp" '[ -n "$_current_out_tmp" ] && rm -f "$_current_out_tmp"' "$SH_SRC"

# ══════════════════════════════════════════════════════════════
suite "P6: «выход == вход» учитывает суффикс (part.1) при [split] start"
# ══════════════════════════════════════════════════════════════
# При start != 0 суффикс " (part.1)" добавляется всегда, значит имя выхода отличается
# от входа — но проверка сверяла базовое имя и при in-place отклоняла КАЖДЫЙ файл.
touch "$IN/ip.mp4"
run_capture 'folder_destination="$IN"' 'start_coding=":+:00-00-10"'
assert_not_contains "in-place + start: нет ложного 'выход совпадает с входом'" "выход совпадает с входом" "$OUT_TEXT"
if [ -f "$IN/ip (part.1).mp4" ]; then pass "in-place + start: часть создана"; else fail "in-place + start: часть создана" "есть 'ip (part.1).mp4'" "нет"; fi
rm -f "$IN/ip.mp4" "$IN/ip (part.1).mp4" "$IN/.ip.ffconv"
# Контроль: без split in-place по-прежнему отклоняется (иначе файл кодировался бы в себя).
touch "$IN/ip2.mp4"
run_capture 'folder_destination="$IN"'
assert_contains "in-place без split: по-прежнему FAIL" "выход совпадает с входом" "$OUT_TEXT"
rm -f "$IN/ip2.mp4"

assert_contains "SH: part_suffix_known вычисляется"        'part_suffix_known=" (part.1)"' "$SH_SRC"
assert_contains "SH: сравнение включает суффикс"           '${file_name}${part_suffix_known}.${current_format_out}' "$SH_SRC"
assert_contains "PS1: сравнение включает суффикс"          '$canon_out = Get-CanonPath "$out_base$part_suffix_known.$current_format_out"' "$PS1_SRC"
assert_contains "CMD: сравнение включает суффикс"          '!file_name!!part_suffix_known!.!current_format_out!' "$CMD_SRC"

# ══════════════════════════════════════════════════════════════
suite "P7-P9: GUI — диапазон скорости, overwrite, валидация CRF"
# ══════════════════════════════════════════════════════════════
# P7. Один и тот же config.ini CLI принимал, а GUI отвергал: скрипт допускает
# 0 < v <= 100 (предел одного звена atempo), GUI требовал 0.25-4.0.
assert_contains "GUI: верхняя граница скорости = 100"      '[double]$textSpeed.Text -gt 100' "$GUI_SRC"
assert_contains "GUI: нижняя граница скорости > 0"         '[double]$textSpeed.Text -le 0' "$GUI_SRC"
assert_not_contains "GUI: старого диапазона 0.25-4.0 нет"  '-lt 0.25' "$GUI_SRC"
assert_contains "config.ini: диапазон скорости назван"     'Допустимый диапазон: больше 0 и не больше 100' "$CFG_SRC"

# P8. overwrite_existing получил контрол: без него готовый выход молча пропускался,
# и переключить поведение можно было только правкой config.ini.
assert_contains "GUI: чекбокс overwrite существует"        '$checkOverwrite.Text = "Перезаписывать существующие"' "$GUI_SRC"
assert_contains "GUI: overwrite берётся из чекбокса"       'if ($checkOverwrite.Checked)   { "yes" } else { "no" }' "$GUI_SRC"
assert_contains "GUI: начальное значение из config.ini"    '$checkOverwrite.Checked = ($_cfg_overwrite_existing -eq "yes")' "$GUI_SRC"

# P9. Гард от регресса: валидация CRF обязана отсекать и отрицательные значения.
# `-notmatch '^\d+$'` уже даёт true на "-5" — тест закрепляет это поведение, чтобы
# «упрощение» условия до -match/[int]-сравнения не открыло дыру снова.
assert_contains "GUI: CRF валидируется regex-ом только из цифр" "\$textVideoQuality.Text  -notmatch '^\\d+\$'" "$GUI_SRC"

# ── Cleanup ───────────────────────────────────────────────────
rm -rf "$WORK"

summary
