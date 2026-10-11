#!/bin/bash
# Тест дот-сорсит настоящий production-скрипт: переменные, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
# ============================================================
# test_20_remote_map.sh — отображение config.ini на операции службы.
# Чистые функции, сети нет вовсе.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

suite "remote: отображение кодеков"
assert_eq "libx264 → h264"    "h264" "$(remote_map_codec libx264)"
assert_eq "h264_nvenc → h264" "h264" "$(remote_map_codec h264_nvenc)"
assert_eq "h264_qsv → h264"   "h264" "$(remote_map_codec h264_qsv)"
assert_eq "libx265 → hevc"    "hevc" "$(remote_map_codec libx265)"
assert_eq "hevc_nvenc → hevc" "hevc" "$(remote_map_codec hevc_nvenc)"
assert_eq "libsvtav1 → av1"   "av1"  "$(remote_map_codec libsvtav1)"
assert_eq "av1_nvenc → av1"   "av1"  "$(remote_map_codec av1_nvenc)"
if remote_map_codec libvpx-vp9 >/dev/null 2>&1; then
    fail "неизвестный кодек отвергается" "код возврата 1" "код возврата 0"
else
    pass "неизвестный кодек отвергается"
fi

suite "remote: экранирование JSON"
# Прежняя версия этого assert'а закрепляла ДЕФЕКТ: она ожидала, что обратный
# слэш останется одиночным. В JSON одиночный `\` перед буквой — невалидная
# escape-последовательность, и служба обязана отвергнуть тело. Подробный разбор
# и профили с `/`, кириллицей и путями Windows — в test_21.
assert_eq "кавычка"       'a\"b'  "$(remote_json_escape 'a"b')"
assert_eq "обратный слэш" 'a\\b'  "$(remote_json_escape 'a\b')"
assert_eq "слэш не теряется" 'a/\\b' "$(remote_json_escape 'a/\b')"

# Минимальный набор переменных, какой даёт FFmpeg_Converter_script.sh после парсинга.
_setup_cfg() {
    set_video_codec="libx264"
    video_quality_status="+";      video_quality_value="23"
    video_bitrate_status="-";      video_bitrate_value="3000"
    video_resolution_status="+";   video_resolution_value="1280x720"
    video_number_frames_status="+"; video_number_frames_value="30"
    video_rotation_status="-";     video_rotation_value="2"
    video_subtitles_status="-";    video_subtitles_value="burn"
    keep_aspect_ratio_status="+"; keep_aspect_ratio_value="yes"
    output_container_status="+";  output_container_value="mp4"
    audio_codec_status="+";           audio_codec_value="aac"
    audio_number_channels_status="+"; audio_number_channels_value="2"
    audio_bitrate_status="+";         audio_bitrate_value="128"
    audio_sampling_rate_status="+";   audio_sampling_rate_value="48000"
    audio_normalize_status="-";       audio_normalize_value="loudnorm"
    playback_speed_status="-";     playback_speed_value="1.0"
    gpu_preset_status="-";  gpu_preset_value="p5"
    gpu_tune_status="-";    gpu_tune_value="hq"
    gpu_rc_status="-";      gpu_rc_value="vbr"
    hw_accel_status="-";    hw_accel_value="intel"
    threads="4"
    subtitles_style=""
}

suite "remote: операция и параметры"
_setup_cfg
out="$(remote_op_for_config 0 0)"
op="$(printf '%s' "$out" | head -1)"
params="$(printf '%s' "$out" | tail -1)"
assert_eq "без start/length → transcode" "transcode" "$op"
assert_contains "кодек"       '"codec":"h264"'    "$params"
assert_contains "качество"    '"quality":23'      "$params"
assert_contains "разрешение"  '"resolution":"1280x720"' "$params"
assert_contains "пропорции"   '"keep_aspect":true' "$params"
assert_contains "кадры"       '"fps":30'          "$params"
assert_contains "контейнер"   '"container":"mp4"' "$params"
assert_contains "потоки"      '"threads":4'       "$params"
assert_contains "звук"        '"audio":{'         "$params"
assert_contains "аудиокодек"  '"codec":"aac"'     "$params"
assert_not_contains "выключенный битрейт не уехал" '"bitrate":3000' "$params"
assert_not_contains "выключенный поворот не уехал" '"rotate"'       "$params"
assert_not_contains "скорость 1.0 не уехала"       '"speed"'        "$params"

suite "remote: start/length → cut"
_setup_cfg
out="$(remote_op_for_config 60 300)"
op="$(printf '%s' "$out" | head -1)"
params="$(printf '%s' "$out" | tail -1)"
assert_eq "со start/length → cut" "cut" "$op"
assert_contains "начало"    '"start":60'       "$params"
assert_contains "конец"     '"end":360'        "$params"
assert_contains "перекод"   '"reencode":true'  "$params"
assert_contains "кодек на месте" '"codec":"h264"' "$params"

suite "remote: включённые необязательные поля"
_setup_cfg
video_bitrate_status="+"
video_rotation_status="+"
playback_speed_status="+"; playback_speed_value="1.75"
audio_normalize_status="+"
gpu_preset_status="+"
video_quality_status="-"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains "битрейт в бит/с"    '"bitrate":3000000'          "$params"
assert_contains "потолок исходного"  '"bitrate_cap_source":true'  "$params"
# Единицы разные НАМЕРЕННО: audio.bitrate служба принимает в кбит/с (8–640) и сама
# подставляет `-b:a Nk`, video.bitrate — в бит/с. Ревью уже принимало асимметрию за дефект.
assert_contains "аудиобитрейт в кбит/с" '"audio":{"codec":"aac","bitrate":128,' "$params"
assert_not_contains "аудиобитрейт не умножен на 1000" '"bitrate":128000' "$params"
# Число, а не строка: у службы допустимые значения — ("off", 1, 2), и "2" в
# кавычках в этот список не входит. Отказ приходил 400-м после полной загрузки.
assert_contains "поворот"            '"rotate":2'                 "$params"
assert_contains "скорость"           '"speed":1.75'               "$params"
assert_contains "нормализация"       '"normalize":"loudnorm"'     "$params"
assert_contains "пресет"             '"preset":"p5"'              "$params"
assert_not_contains "quality и bitrate вместе — 400 у службы" '"quality"' "$params"

suite "remote: субтитры и стиль"
_setup_cfg
video_subtitles_status="+"; video_subtitles_value="burn"
subtitles_style="FontName=Arial,FontSize=24"
# Третий аргумент — «sidecar найден». Без файла титров поле subtitles уезжать не
# имеет права: локально это означает «кодируем без титров», а служба получала
# "subtitles":"burn" без subtitle_upload_id и отвечала 400 ПОСЛЕ полной загрузки.
params="$(remote_op_for_config 0 0 1 | tail -1)"
assert_contains "режим субтитров" '"subtitles":"burn"' "$params"
assert_contains "стиль"           '"subtitle_style":"FontName=Arial,FontSize=24"' "$params"

params="$(remote_op_for_config 0 0 0 | tail -1)"
assert_not_contains "без sidecar поле subtitles не уезжает"     '"subtitles"'      "$params"
assert_not_contains "без sidecar стиль субтитров не уезжает"    '"subtitle_style"' "$params"

# ══════════════════════════════════════════════════════════════
suite "remote: статус ключа значим так же, как значение"
# ══════════════════════════════════════════════════════════════
# Один config.ini обязан давать один результат локально и удалённо. Три поля
# читались ТОЛЬКО по значению, игнорируя '-': `container = -mkv` локально давал
# movie.mp4, а службе уходило "container":"mkv" — публиковался mp4 с MKV внутри.
_setup_cfg
output_container_status="-"; output_container_value="mkv"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains     "выключенный container → mp4, как локально" '"container":"mp4"' "$params"
assert_not_contains "выключенное значение container не уехало"  '"container":"mkv"' "$params"

# Контейнер уезжает ПОСЛЕ того же отображения, что у локального пути (script.sh, D3):
# выход на обоих путях называется по отображённому имени, а службе уходило исходное —
# `container = +m4v` локально давал mp4, удалённо отказ «служба не умеет m4v».
_setup_cfg
output_container_status="+"; output_container_value="m4v"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains "container = +m4v уезжает как mp4" '"container":"mp4"' "$params"
# Таблица отображения записана дважды — в script.sh (блок D3) и в remote_container:
# модуль необязателен и подключается отдельно, общей функции у них нет. Чтобы правка
# одного места не разошлась с другим, сверяется НАСТОЯЩИЙ блок D3, вырезанный из
# script.sh, а не список ожиданий в тесте. Адрес — по отступу в два таба: в файле
# есть и другие `case "$format_files_out"` (muxer, кодек субтитров, совместимость).
_d3="$(sed -n $'/^\t\tcase "\\$format_files_out" in$/,/^\t\tesac$/p' "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh")"
assert_eq "вырезан ровно один блок" "1" "$(printf '%s\n' "$_d3" | grep -c 'case "\$format_files_out" in')"
assert_contains "блок D3 найден в script.sh" 'format_files_out="mpegts"' "$_d3"
for _c in m4v mpg wmv mts m2ts mkv mp4 webm avi mov ts flv; do
    format_files_out="$_c"; eval "$_d3" > /dev/null
    output_container_status="+"; output_container_value="$_c"; remote_container
    assert_eq "container = +$_c: службе — то же имя, что у локального выхода" "$format_files_out" "$REMOTE_CONTAINER"
done

_setup_cfg
keep_aspect_ratio_status="-"; keep_aspect_ratio_value="yes"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains "выключенный keep_aspect_ratio → false" '"keep_aspect":false' "$params"

_setup_cfg
audio_codec_status="-"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains     "выключенный аудиокодек → copy" '"audio":{"codec":"copy"}' "$params"
assert_not_contains "при copy битрейт не уезжает"   '"bitrate":128'  "$params"
assert_not_contains "при copy каналы не уезжают"    '"channels"'     "$params"
assert_not_contains "при copy частота не уезжает"   '"rate"'         "$params"

summary
