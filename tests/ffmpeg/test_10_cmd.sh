#!/bin/bash
# ============================================================
# test_10_cmd.sh — Тест CMD: парсинг config.ini и исправления
# Тестирует: :to_flag, парсинг секций, Bug 3 (copy_codecs+filters),
# Bug 4 (seek_arg при b=0), Bug 6 (GPU encoder check).
# Использует cmd.exe через inline .cmd скрипты.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD тесты"
    skip "Все CMD тесты" "cmd.exe не доступен"
    summary
    exit 0
fi

# ── Хелпер: запустить inline CMD скрипт через temp файл ───────────────────
run_cmd() {
    local script_content="$1"
    local tmp_cmd
    tmp_cmd=$(mktemp /tmp/test_cmd_XXXXXX.cmd)
    printf '@echo off\r\nchcp 65001 >nul 2>&1\r\nsetlocal enabledelayedexpansion\r\n%s\r\n' \
        "$script_content" > "$tmp_cmd"
    local win_path
    win_path=$(cygpath -w "$tmp_cmd" 2>/dev/null || echo "$tmp_cmd" | sed 's|/c/|C:/|' | sed 's|/|\\|g')
    local result
    result=$(cmd //c "$win_path" 2>/dev/null)
    rm -f "$tmp_cmd"
    echo "$result"
}

# ══════════════════════════════════════════════════════════════
suite "CMD: :to_flag суброутин (+/- → :+:/:-:)"
# ══════════════════════════════════════════════════════════════
# Раньше здесь стоял inline-пересказ одной строкой. Он не только мог разойтись с
# production, но и молча терял ветку `if not defined _fv exit /b` — то есть
# контракт «пустое значение сохраняет дефолт» не проверялся вовсе.
# Теперь вырезаем НАСТОЯЩУЮ подпрограмму (как уже сделано для :resolve_hw и
# :kbps_from_line ниже) и вызываем её через call.
RUN_CMD_SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v16.cmd"
if [ ! -f "$RUN_CMD_SCRIPT" ]; then
    fail "CMD: production run-скрипт на месте" "$RUN_CMD_SCRIPT" "файл не найден"
fi
TO_FLAG_SRC=$(awk '/^:to_flag/{f=1} f&&/^:start_coding/{exit} f{print}' "$RUN_CMD_SCRIPT" | tr -d '\r')
if [ -z "$TO_FLAG_SRC" ]; then
    fail "CMD: подпрограмма :to_flag найдена в production-файле" "найдена" "не найдена"
fi

to_flag_cmd() {
    # $1 = значение из config.ini, $2 = предустановленный дефолт переменной
    local body
    body=$(printf '%s\n' \
        "set \"video_codec=$2\"" \
        "call :to_flag \"$1\" video_codec" \
        "echo R=[!video_codec!]" \
        "goto :done_to_flag" \
        "$TO_FLAG_SRC" \
        ":done_to_flag" | sed 's/$/\r/')
    run_cmd "$body"
}

result=$(to_flag_cmd "+libx264" "")
assert_contains "to_flag: +libx264 → :+:libx264"     "R=[:+:libx264]"  "$result"

result=$(to_flag_cmd "-libx264" "")
assert_contains "to_flag: -libx264 → :-:libx264"     "R=[:-:libx264]"  "$result"

result=$(to_flag_cmd "libx264" "")
assert_contains "to_flag: bare libx264 → :+:libx264" "R=[:+:libx264]"  "$result"

# Ветка, которой в inline-копии не было совсем.
result=$(to_flag_cmd "" ":+:default_codec")
assert_contains "to_flag: пустое значение сохраняет дефолт" "R=[:+:default_codec]" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD: парсинг :+:value / :-:value"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "audio_codec=:+:aac"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "audio_codec_status=%%a" & set "audio_codec_value=%%b")
echo status=!audio_codec_status!
echo value=!audio_codec_value!
')
assert_contains "парсинг :+:aac → status=+"  "status=+"  "$result"
assert_contains "парсинг :+:aac → value=aac" "value=aac" "$result"

result=$(run_cmd '
set "video_codec=:-:libx264"
for /f "tokens=1,2 delims=:" %%a in ("%video_codec%") do (set "video_codec_status=%%a" & set "video_codec_value=%%b")
echo status=!video_codec_status!
echo value=!video_codec_value!
')
assert_contains "парсинг :-:libx264 → status=-"       "status=-"    "$result"
assert_contains "парсинг :-:libx264 → value=libx264"  "value=libx264" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD: аудио/видео аргументы"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "audio_codec=:+:aac"
set "audio_bitrate=:+:128"
set "audio_number_channels=:+:2"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "ac_status=%%a" & set "ac_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_bitrate%") do (set "ab_status=%%a" & set "ab_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_number_channels%") do (set "ach_status=%%a" & set "ach_value=%%b")
if "!ac_status!"=="+" (set "set_audio_codec=-c:a !ac_value!") else (set "set_audio_codec=")
if "!ab_status!"=="+" (set "set_audio_bitrate=-b:a !ab_value!k") else (set "set_audio_bitrate=")
if "!ach_status!"=="+" (set "set_audio_channels=-ac !ach_value!") else (set "set_audio_channels=")
echo codec=!set_audio_codec!
echo bitrate=!set_audio_bitrate!
echo channels=!set_audio_channels!
')
assert_contains "audio codec +aac → -c:a aac"      "-c:a aac"   "$result"
assert_contains "audio bitrate +128 → -b:a 128k"   "-b:a 128k"  "$result"
assert_contains "audio channels +2 → -ac 2"         "-ac 2"      "$result"

result=$(run_cmd '
set "audio_codec=:-:aac"
set "audio_bitrate=:-:128"
for /f "tokens=1,2 delims=:" %%a in ("%audio_codec%") do (set "ac_status=%%a" & set "ac_value=%%b")
for /f "tokens=1,2 delims=:" %%a in ("%audio_bitrate%") do (set "ab_status=%%a" & set "ab_value=%%b")
if "!ac_status!"=="+" (set "set_audio_codec=-c:a !ac_value!") else (set "set_audio_codec=")
if "!ab_status!"=="+" (set "set_audio_bitrate=-b:a !ab_value!k") else (set "set_audio_bitrate=")
echo codec=[!set_audio_codec!]
echo bitrate=[!set_audio_bitrate!]
')
assert_contains "audio codec -aac → пустой"    "codec=[]"   "$result"
assert_contains "audio bitrate -128 → пустой"  "bitrate=[]" "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 3: copy_codecs=yes очищает vf_args/af_args"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "copy_codecs=yes"
set "current_vf=scale=1280:720"
set "current_af=loudnorm"
if defined current_vf (set "vf_args=-vf !current_vf!")
if defined current_af (set "af_args=-af !current_af!")
if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")
echo vf=[!vf_args!]
echo af=[!af_args!]
')
assert_contains "Bug3: copy_codecs=yes → vf_args пустой"  "vf=[]"  "$result"
assert_contains "Bug3: copy_codecs=yes → af_args пустой"  "af=[]"  "$result"

result=$(run_cmd '
set "copy_codecs=no"
set "current_vf=scale=1280:720"
set "current_af=loudnorm"
if defined current_vf (set "vf_args=-vf !current_vf!")
if defined current_af (set "af_args=-af !current_af!")
if "%copy_codecs%"=="yes" (set "vf_args=" & set "af_args=")
echo vf=[!vf_args!]
echo af=[!af_args!]
')
assert_contains "Bug3: copy_codecs=no → vf_args сохранён"  "vf=[-vf scale=1280:720]"  "$result"
assert_contains "Bug3: copy_codecs=no → af_args сохранён"  "af=[-af loudnorm]"         "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 4: seek_arg пустой когда b=0"
# ══════════════════════════════════════════════════════════════

result=$(run_cmd '
set "b=0"
if %b%==0 (set "seek_arg=") else (set "seek_arg=-ss %b%")
echo seek=[!seek_arg!]
')
assert_contains "Bug4: b=0 → seek_arg пустой"  "seek=[]"  "$result"

result=$(run_cmd '
set "b=3600"
if %b%==0 (set "seek_arg=") else (set "seek_arg=-ss %b%")
echo seek=[!seek_arg!]
')
assert_contains "Bug4: b=3600 → seek_arg=-ss 3600"  "seek=[-ss 3600]"  "$result"

# ══════════════════════════════════════════════════════════════
suite "CMD Bug 6: GPU encoder check логика"
# ══════════════════════════════════════════════════════════════

# Тест логики (без реального ffmpeg): симулируем encoder_check
result=$(run_cmd '
set "use_hw_accel=no"
set "set_video_codec=libx264"
set "encoder_check=V..... h264_nvenc   NVIDIA NVENC H.264"
if defined encoder_check (
    set "use_hw_accel=yes"
    if "!set_video_codec!"=="libx264" set "set_video_codec=h264_nvenc"
)
echo hw=!use_hw_accel!
echo codec=!set_video_codec!
')
assert_contains "Bug6: encoder found → use_hw_accel=yes"  "hw=yes"         "$result"
assert_contains "Bug6: encoder found → libx264→h264_nvenc" "codec=h264_nvenc" "$result"

result=$(run_cmd '
set "use_hw_accel=no"
set "set_video_codec=libx264"
set "encoder_check="
if defined encoder_check (
    set "use_hw_accel=yes"
    if "!set_video_codec!"=="libx264" set "set_video_codec=h264_nvenc"
)
echo hw=!use_hw_accel!
echo codec=!set_video_codec!
')
assert_contains "Bug6: encoder not found → use_hw_accel=no"  "hw=no"      "$result"
assert_contains "Bug6: encoder not found → codec unchanged"   "codec=libx264" "$result"

# Сьюит «CMD: config.ini парсинг» удалён: это была 45-строчная inline-переделка
# парсера из run_v16.cmd (:trim_val/:trim_key/:strip_inline_comment/:assign_var).
# Настоящий парсер уже прогоняется в test_12_cmd_run_parser.sh через штатный хук
# --print-config, причём строго шире: регистр секций, пустое значение → дефолт,
# значения с & и #, резолвинг относительных путей. Копия проверяла подмножество
# и при этом могла разойтись с production.

# ══════════════════════════════════════════════════════════════
suite "CMD: atempo каскад (milli-арифметика, без float)"
# ══════════════════════════════════════════════════════════════

# Вызывает НАСТОЯЩУЮ подпрограмму :build_atempo, вырезанную из production-файла.
# Раньше здесь лежала инлайн-копия: продакшн мог сломаться, а копия — продолжать
# проходить. Отсутствие подпрограммы в исходнике теперь тоже провал, а не тихий скип.
CMD_SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"
BUILD_ATEMPO_SRC=$(sed -n '/^:build_atempo/,/^exit \/b 0/p' "$CMD_SCRIPT" | tr -d '\r')
if [ -z "$BUILD_ATEMPO_SRC" ]; then
    fail "CMD: подпрограмма :build_atempo найдена в production-файле" "найдена" "не найдена"
fi

# CRLF обязателен: с LF-переносами CMD десинхронизирует парсер на кириллических
# rem-комментариях подпрограммы и `goto :_bt_hi` перестаёт быть меткой.
atempo_cmd() {
    local body
    body=$(printf '%s\n' \
        "call :build_atempo \"$1\"" \
        "if errorlevel 1 (echo af=REJECTED) else (echo af=!af_chain!)" \
        "goto :done_atempo" \
        "$BUILD_ATEMPO_SRC" \
        ":done_atempo" | sed 's/$/\r/')
    run_cmd "$body"
}

result=$(atempo_cmd "3.0")
assert_contains "atempo 3.0 → atempo=2.0"        "atempo=2.0"  "$result"
assert_contains "atempo 3.0 → остаток atempo=1.5" "atempo=1.5"  "$result"

result=$(atempo_cmd "4.0")
assert_contains "atempo 4.0 → каскад 2x2"  "atempo=2.0,atempo=2.0"  "$result"

result=$(atempo_cmd "0.25")
assert_contains "atempo 0.25 → каскад 0.5x0.5"  "atempo=0.5,atempo=0.5"  "$result"

result=$(atempo_cmd "1.5")
assert_contains "atempo 1.5 (in-range) → atempo=1.5"  "af=atempo=1.5"  "$result"

# F15: невалидная скорость отвергается (errorlevel 1), а не вешает :_bt_hi/:_bt_lo.
# Без валидации 0 делится в 0, а отрицательное расходится — цикл не сходится никогда.
for bad in 0 -1 abc 150; do
    result=$(atempo_cmd "$bad")
    assert_contains "atempo '$bad' → REJECTED (F15)" "af=REJECTED" "$result"
done

# ══════════════════════════════════════════════════════════════
suite "F25 CMD: потолок битрейта из видеопотока (:kbps_from_line)"
# ══════════════════════════════════════════════════════════════
# Вызывает НАСТОЯЩУЮ подпрограмму :kbps_from_line из production-файла (не инлайн-копию).
# Контракт: число перед " kb/s" из строки Video; отсутствие kb/s или resolution → пусто.
CMD_SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"
KBPS_SRC=$(sed -n '/^:kbps_from_line/,/^endlocal & exit \/b/p' "$CMD_SCRIPT" | tr -d '\r')
if [ -z "$KBPS_SRC" ]; then
    fail "CMD: подпрограмма :kbps_from_line найдена в production-файле" "найдена" "не найдена"
fi
kbps_cmd() {
    local body
    body=$(printf '%s\n' \
        "call :kbps_from_line \"$1\" R" \
        "echo R=[!R!]" \
        "goto :done_kbps" \
        "$KBPS_SRC" \
        ":done_kbps" | sed 's/$/\r/')
    run_cmd "$body"
}
result=$(kbps_cmd '    Stream #0:0(und): Video: h264 (High), yuv420p, 1920x1080, 1808 kb/s, 30 fps, 30 tbr')
assert_contains "видеопоток 1808 kb/s → 1808"  "R=[1808]"  "$result"
result=$(kbps_cmd '    Stream #0:0(und): Video: h264 (High), yuv420p, 1920x1080, 30 fps, 30 tbr')
assert_contains "видеопоток без kb/s → пусто (fallback на контейнер)"  "R=[]"  "$result"

# ══════════════════════════════════════════════════════════════
suite "F33 CMD: GPU-энкодер разрешается точной проверкой (:resolve_hw)"
# ══════════════════════════════════════════════════════════════
# Ни один прежний CMD-тест не исполнял ветку GPU (никто не выставлял hw_accel).
# При F33 :resolve_hw падала на дисбалансе кавычек, а smoke/test_10 были зелёными.
# Здесь вызывается НАСТОЯЩАЯ :resolve_hw из production с mock-ffmpeg, отдающим список
# энкодеров. Контракт как у SH test_15::F33: включаем hardware ТОЛЬКО при точном энкодере.
RESOLVE_HW_SRC=$(awk '/^:resolve_hw/{f=1} f&&/^:build_atempo/{exit} f{print}' "$CMD_SCRIPT" | tr -d '\r')
if [ -z "$RESOLVE_HW_SRC" ]; then
    fail "CMD: подпрограмма :resolve_hw найдена в production-файле" "найдена" "не найдена"
fi
# Mock ffmpeg.cmd: печатает список энкодеров (имя в конце строки — под якорь `$` findstr).
MOCK_FF=$(mktemp /tmp/test_ffmock_XXXXXX.cmd)
printf '@echo off\r\necho  V..... libx264\r\necho  V..... libx265\r\necho  V..... libsvtav1\r\nfor %%%%e in (%%MOCK_ENC%%) do echo  V....D %%%%e\r\nexit /b 0\r\n' > "$MOCK_FF"
MOCK_FF_WIN=$(cygpath -w "$MOCK_FF" 2>/dev/null || echo "$MOCK_FF" | sed 's|/c/|C:/|;s|/|\\|g')

resolve_hw_cmd() {
    # $1=set_video_codec  $2=hw_accel_value  $3=MOCK_ENC (список энкодеров)
    local body
    body=$(printf '%s\n' \
        "set \"MOCK_ENC=$3\"" \
        "set \"ffmpeg=$MOCK_FF_WIN\"" \
        "set \"set_video_codec=$1\"" \
        "set \"hw_accel_value=$2\"" \
        "set \"use_hw_accel=no\"" \
        "set \"hw_decode_args=\"" \
        "call :resolve_hw" \
        "echo codec=!set_video_codec!" \
        "echo hw=!use_hw_accel!" \
        "echo decode=!hw_decode_args!" \
        "goto :done_hw" \
        "$RESOLVE_HW_SRC" \
        ":done_hw" | sed 's/$/\r/')
    run_cmd "$body"
}

# 1) libx264 + nvidia + сборка с h264_nvenc → hardware включается точным энкодером.
result=$(resolve_hw_cmd "libx264" "nvidia" "h264_nvenc hevc_nvenc av1_nvenc")
assert_contains "libx264+nvidia → энкодер h264_nvenc"  "codec=h264_nvenc"  "$result"
assert_contains "libx264+nvidia → use_hw_accel=yes"    "hw=yes"            "$result"
assert_contains "libx264+nvidia → -hwaccel cuda в argv" "-hwaccel cuda"    "$result"

# 2) libsvtav1 + nvidia, но БЕЗ av1_nvenc в сборке → остаёмся на software (F33-суть).
result=$(resolve_hw_cmd "libsvtav1" "nvidia" "h264_nvenc hevc_nvenc")
assert_contains "libsvtav1 без av1_nvenc → кодек не подменён"  "codec=libsvtav1"  "$result"
assert_not_contains "libsvtav1 без av1_nvenc → hardware НЕ включён"  "hw=yes"  "$result"
assert_not_contains "libsvtav1 без av1_nvenc → без hwaccel-кадров"   "-hwaccel cuda"  "$result"

# 3) кодек без GPU-варианта (libvpx-vp9) → software, hardware-кадры не включаются.
result=$(resolve_hw_cmd "libvpx-vp9" "nvidia" "h264_nvenc hevc_nvenc av1_nvenc")
assert_contains "libvpx-vp9 → кодек software оставлен"  "codec=libvpx-vp9"  "$result"
assert_not_contains "libvpx-vp9 → hardware НЕ включён"  "hw=yes"  "$result"
rm -f "$MOCK_FF"

# ══════════════════════════════════════════════════════════════
suite "CMD: keep_aspect_ratio else-binding (Task 5)"
# ══════════════════════════════════════════════════════════════
# При keep_aspect_ratio со статусом "-" масштабирование НЕ должно отключаться целиком
result=$(run_cmd '
set "video_resolution_status=+" & set "res_w=1280" & set "res_h=720"
set "hw_accel_type=" & set "use_hw_accel=no"
set "keep_aspect_ratio_status=-" & set "keep_aspect_ratio_value=yes"
set "vf_chain="
set "scale_filter=scale"
set "keep_ar=no"
if "!keep_aspect_ratio_status!"=="+" if "!keep_aspect_ratio_value!"=="yes" set "keep_ar=yes"
if "!keep_ar!"=="yes" (
	if defined vf_chain (set "vf_chain=!vf_chain!,scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease") else (set "vf_chain=scale=!res_w!:!res_h!:force_original_aspect_ratio=decrease")
) else (
	if defined vf_chain (set "vf_chain=!vf_chain!,scale=!res_w!:!res_h!") else (set "vf_chain=scale=!res_w!:!res_h!")
)
echo vf=!vf_chain!
')
assert_contains "keep_ar=- → scale всё равно применён"  "scale=1280:720"  "$result"
assert_not_contains "keep_ar=- → без force_original_aspect_ratio"  "force_original_aspect_ratio"  "$result"

# ══════════════════════════════════════════════════════════════
suite "script.cmd: фиксы Task 5 (анализ исходника)"
# ══════════════════════════════════════════════════════════════
SCRIPT_CMD="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"
src_cmd="$(cat "$SCRIPT_CMD")"

# keep_ar предвычисляется (нет else-binding бага)
assert_contains "keep_ar предвычислен"  'set "keep_ar=no"'  "$src_cmd"
# part suffix: без ведущего пробела (if defined num)
assert_contains "num без ведущего пробела"  'if defined num (set "num=!num! !part_start!") else (set "num=!part_start!")'  "$src_cmd"
# transpose_cuda удалён
assert_not_contains "нет transpose_cuda"  "transpose_cuda"  "$src_cmd"
# muxer map
assert_contains "muxer map matroska"  "matroska"  "$src_cmd"
assert_contains "muxer map mpegts"  "mpegts"  "$src_cmd"
assert_contains "-f использует muxer_out"  '-f !muxer_out!'  "$src_cmd"
# split_by_silence fallback с предупреждением
assert_contains "split_by_silence fallback warn"  "split_by_silence недоступен"  "$src_cmd"
# validity-check существующего выхода
assert_contains "validity-check -f null"  '-f null - >nul 2>&1'  "$src_cmd"
# extract_audio: первая строка Audio (if not defined audio_line)
assert_contains "extract_audio первая строка"  'if not defined audio_line set "audio_line=%%c"'  "$src_cmd"
# субтитры: backslash → forward slash (нет ошибочного \'\:)
assert_not_contains "нет ошибочного экранирования \\'\\:"  ":=\\'\\:"  "$src_cmd"
# octal-защита %time% (replace space->0)
assert_contains "time: пробел→0 для октальной защиты"  'start_hh: =0'  "$src_cmd"
# header: комментарий об ограничении ! в именах
assert_contains "header: ограничение ! в именах"  "имена файлов с"  "$src_cmd"

# ══════════════════════════════════════════════════════════════
suite "script.cmd: фиксы Task 6 (copy_codecs ext, Duration N/A)"
# ══════════════════════════════════════════════════════════════
# copy_codecs: current_format_out из источника ДО validity-check существующего выхода.
# Якорь — ИМЕННО проверка готового выхода (-i "!_existing_out!"), а не «первый -f null
# в файле»: валидаций `-f null -` в скрипте несколько (ещё и merge, и она стоит выше),
# и привязка к первому вхождению ловила чужую строку вместо нужной.
cc_ln=$(grep -nF 'set "current_format_out=!pf_x!"' "$SCRIPT_CMD" | head -1 | cut -d: -f1)
chk_ln=$(grep -nF -- '-i "!_existing_out!" -f null -' "$SCRIPT_CMD" | head -1 | cut -d: -f1)
order="bad"; [ -n "$cc_ln" ] && [ -n "$chk_ln" ] && [ "$cc_ln" -lt "$chk_ln" ] && order="ok"
assert_eq "copy_codecs ext вычислен ДО validity-check"  "ok"  "$order"
# Duration N/A → num=0 fallback
assert_contains "Duration N/A → num fallback"  'if not defined num set "num=0"'  "$src_cmd"

# AMF: constant-quality через cqp + qp_i/qp_p/qp_b, а не несуществующий одиночный -qp.
assert_contains     "CMD AMF: режим cqp + qp_i/qp_p/qp_b"  '_amf" set "crf_args=-rc cqp -qp_i'  "$src_cmd"
assert_not_contains "CMD AMF: нет одиночного -qp mapping"  '_amf" set "crf_args=-qp '          "$src_cmd"

# F-modes/#7: конфликт спецрежимов → WARN; extract уважает overwrite_existing.
assert_contains "CMD: WARN о взаимоисключающих режимах" "взаимоисключающих режимов" "$src_cmd"
# F1: удаление под guard'ом dry_run — extract при overwrite перезаписывает, но dry_run
# только печатает команду и не трогает существующий выход.
assert_contains "CMD: extract уважает overwrite_existing" 'if exist "!out_audio!" if "%overwrite_existing%"=="yes" if not "%dry_run%"=="yes" del' "$src_cmd"
# F-collision (#6): skip файлов внутри каталога назначения
assert_contains "CMD: dest-inside-source флаг" 'set "dest_inside_source=1"' "$src_cmd"

summary
