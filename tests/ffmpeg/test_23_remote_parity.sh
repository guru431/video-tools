#!/bin/bash
# ============================================================
# test_23_remote_parity.sh — SH и PS1 обязаны собирать ОДИН И ТОТ ЖЕ JSON.
#
# Не «похожий»: строки сравниваются целиком. Разойдись порядок полей или
# формат числа — один config.ini дал бы на двух платформах разные файлы,
# и это единственный тест, который такое видит.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "remote: паритет SH ↔ PS1"
    skip "паритет сборщиков" "PowerShell не найден"
    summary
    exit 0
fi
MODULE="$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/remote_client.ps1"

# Профили: имя, затем присваивания для SH и для PS1 (одни и те же значения).
# Каждый профиль соответствует реальному сценарию config.ini.
profiles=(
  "умолчания|quality"
  "битрейт вместо quality|bitrate"
  "поворот и скорость|rotate_speed"
  "прожиг субтитров со стилем|subs"
  # Единственное свободное текстовое поле, уезжающее на службу, — subtitles_style,
  # и оно единственное проходит через экранирование. Профиль выше подавал
  # «FontName=Arial,FontSize=24» — ни `\`, ни `"`, ни `/`, ни кириллицы, то есть
  # обходил стороной ровно ту функцию, которая эти строки преобразует. Значение
  # ниже пишет человек руками, и `\` в ASS/SSA законен.
  "стиль со спецсимволами|subs_escapes"
  "GPU-пресеты|gpu"
  "звук без перекодирования|audio_copy"
)

# Одно значение на обе платформы: `\` (законен в ASS/SSA), `"`, `/` и кириллица.
# Держим в переменной, чтобы SH и PS1 получили БУКВАЛЬНО одну и ту же строку —
# иначе тест сравнивал бы не экранирование, а два разных входа.
STYLE_ESCAPES='Font\Name="Шрифт",Path=C:\a/b\c'

sh_vars() {
  set_video_codec="libx264"
  video_quality_status="+";       video_quality_value="23"
  video_bitrate_status="-";       video_bitrate_value="3000"
  video_resolution_status="+";    video_resolution_value="1280x720"
  video_number_frames_status="+"; video_number_frames_value="30"
  video_rotation_status="-";      video_rotation_value="2"
  video_subtitles_status="-";     video_subtitles_value="burn"
  keep_aspect_ratio_value="yes";  output_container_value="mp4"
  audio_codec_status="+";           audio_codec_value="aac"
  audio_number_channels_status="+"; audio_number_channels_value="2"
  audio_bitrate_status="+";         audio_bitrate_value="128"
  audio_sampling_rate_status="+";   audio_sampling_rate_value="48000"
  audio_normalize_status="-";       audio_normalize_value="loudnorm"
  playback_speed_status="-";      playback_speed_value="1.0"
  gpu_preset_status="-"; gpu_preset_value="p5"
  gpu_tune_status="-";   gpu_tune_value="hq"
  gpu_rc_status="-";     gpu_rc_value="vbr"
  threads="4"; subtitles_style=""
  case "$1" in
    bitrate)      video_quality_status="-"; video_bitrate_status="+" ;;
    rotate_speed) video_rotation_status="+"; playback_speed_status="+"; playback_speed_value="1.75" ;;
    subs)         video_subtitles_status="+"; subtitles_style="FontName=Arial,FontSize=24" ;;
    subs_escapes) video_subtitles_status="+"; subtitles_style="$STYLE_ESCAPES" ;;
    gpu)          gpu_preset_status="+"; gpu_tune_status="+"; gpu_rc_status="+" ;;
    audio_copy)   audio_codec_status="-" ;;
  esac
}

ps_vars() {
  cat <<PSEOF
\$set_video_codec="libx264"
\$video_quality_status="+";       \$video_quality_value="23"
\$video_bitrate_status="-";       \$video_bitrate_value="3000"
\$video_resolution_status="+";    \$video_resolution_value="1280x720"
\$video_number_frames_status="+"; \$video_number_frames_value="30"
\$video_rotation_status="-";      \$video_rotation_value="2"
\$video_subtitles_status="-";     \$video_subtitles_value="burn"
\$keep_aspect_ratio_value="yes";  \$output_container_value="mp4"
\$audio_codec_status="+";           \$audio_codec_value="aac"
\$audio_number_channels_status="+"; \$audio_number_channels_value="2"
\$audio_bitrate_status="+";         \$audio_bitrate_value="128"
\$audio_sampling_rate_status="+";   \$audio_sampling_rate_value="48000"
\$audio_normalize_status="-";       \$audio_normalize_value="loudnorm"
\$playback_speed_status="-";      \$playback_speed_value="1.0"
\$gpu_preset_status="-"; \$gpu_preset_value="p5"
\$gpu_tune_status="-";   \$gpu_tune_value="hq"
\$gpu_rc_status="-";     \$gpu_rc_value="vbr"
\$threads=4; \$subtitles_style=""
PSEOF
  case "$1" in
    bitrate)      echo '$video_quality_status="-"; $video_bitrate_status="+"' ;;
    rotate_speed) echo '$video_rotation_status="+"; $playback_speed_status="+"; $playback_speed_value="1.75"' ;;
    subs)         echo '$video_subtitles_status="+"; $subtitles_style="FontName=Arial,FontSize=24"' ;;
    subs_escapes) echo '$video_subtitles_status="+"'
                  # Одинарные кавычки PS1 обязаны дойти до PowerShell, поэтому
                  # printf, а не echo: '' внутри bash-строки схлопывается.
                  printf '$subtitles_style = %s%s%s\n' "'" "$STYLE_ESCAPES" "'" ;;
    gpu)          echo '$gpu_preset_status="+"; $gpu_tune_status="+"; $gpu_rc_status="+"' ;;
    audio_copy)   echo '$audio_codec_status="-"' ;;
  esac
}

suite "remote: паритет SH ↔ PS1"
for entry in "${profiles[@]}"; do
  name="${entry%%|*}"; key="${entry##*|}"
  for pair in "0 0" "60 300"; do
    set -- $pair
    sh_vars "$key"
    sh_out="$(remote_op_for_config "$1" "$2")"
    sh_op="$(printf '%s' "$sh_out" | head -1)"
    sh_params="$(printf '%s' "$sh_out" | tail -1)"
    ps_script="$(ps_vars "$key")"
    # Консоль PowerShell по умолчанию отдаёт вывод в OEM-кодировке (866), и
    # кириллица в значении приходит в bash мусором: сравнение строк целиком
    # ловило бы кодировку вместо экранирования.
    ps_res="$("$PS_BIN" -NoProfile -NonInteractive -Command "
      [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
      . '$MODULE'
      $ps_script
      \$r = Get-RemoteOpForConfig $1 $2
      Write-Output \$r.Op
      Write-Output \$r.Params
    " 2>&1 | tr -d '\r')"
    ps_op="$(printf '%s' "$ps_res" | head -1)"
    ps_params="$(printf '%s' "$ps_res" | tail -1)"
    assert_eq "$name ($1/$2): операция" "$sh_op" "$ps_op"
    assert_eq "$name ($1/$2): параметры" "$sh_params" "$ps_params"
  done
done

# ══════════════════════════════════════════════════════════════
suite "remote: паритет нормализации адреса SH ↔ PS1"
# ══════════════════════════════════════════════════════════════
# Нормализация жила в run-файлах, а этот тест смотрел только на сборку JSON —
# и расхождение прошло мимо: `${x%/}` снимал ОДИН хвостовой слэш, TrimEnd — все,
# а Trim пробелов был только в GUI. Теперь функция одна на платформу, и её
# равенство сверяется здесь, а не подразумевается.
for _ep in "http://h/v1" "http://h/v1/" "http://h/v1//" "  http://h/v1  " " http://h/v1// " "http://h" ""; do
  sh_norm="$(remote_normalize_endpoint "$_ep")"
  ps_norm="$("$PS_BIN" -NoProfile -NonInteractive -Command "
    . '$MODULE'
    Write-Output ('[' + (Format-RemoteEndpoint '$_ep') + ']')
  " 2>&1 | tr -d '\r' | head -1)"
  ps_norm="${ps_norm#[}"; ps_norm="${ps_norm%]}"
  assert_eq "нормализация «$_ep»" "$sh_norm" "$ps_norm"
done

summary
