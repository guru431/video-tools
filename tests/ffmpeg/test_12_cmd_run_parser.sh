#!/bin/bash
# ============================================================
# test_12_cmd_run_parser.sh — Парсер config.ini в FFmpeg_Converter_run_v19.cmd
# Прогоняет run_v19.cmd с тестовым config.ini через хук --print-config
# (печатает распарсенные переменные, не запуская script.cmd). Ловит баги:
#   (а) детект секций через echo|findstr (пробел + якорь $ на piped input)
#   (б) хвостовой пробел в ключе после "key = value" — ключи не матчатся
#   (в) исполнение `&` из значений при echo|findstr (subtitles_style, пути)
#   (г) :trim_val режет максимум 3 хвостовых пробела
#   (д) :to_flag при пустом значении даёт ":+:" вместо дефолта
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Проверяем доступность cmd (Git Bash на Windows)
if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD: парсер config.ini (run_v19)"
    skip "Все тесты парсера" "cmd.exe не доступен"
    summary
    exit 0
fi

# ══════════════════════════════════════════════════════════════
suite "CMD: парсер config.ini (run_v19, --print-config)"
# ══════════════════════════════════════════════════════════════

TMP_DIR=$(mktemp -d /tmp/test_cmd_run_parser_XXXXXX)
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.cmd" "$TMP_DIR/"

# Тестовый config.ini рядом с run-скриптом (run ищет его в каталоге скрипта).
# quality имеет 5 хвостовых пробелов (баг г), codec пустой (баг д),
# subtitles_style содержит &HFFFFFF& (баг в), source — абсолютный путь.
cat > "$TMP_DIR/config.ini" << 'INIEOF'
# Тестовый конфиг парсера
[folders]
source = C:\abs\src

[VIDEO]
Quality = +23     

[gpu]
hw_accel = +intel

[audio]
codec =

[other]
subtitles_style = FontSize=20,PrimaryColour=&HFFFFFF&
log_file = my#file.log

[remote]
enabled = yes
endpoint = https://svc.example.com/v1
api_key = s3cr3t-value
prefer = gpu
wait_timeout = 60
stall_timeout = 120
on_failure = local
INIEOF
# CRLF для cmd
sed -i 's/$/\r/' "$TMP_DIR/config.ini"

WIN_RUN=$(cygpath -w "$TMP_DIR/FFmpeg_Converter_run_v19.cmd")
WIN_TMP=$(cygpath -w "$TMP_DIR")

output=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1)
exit_code=$?

# Извлечь конкретные строки key=value (без \r), для точных сравнений
get_line() { printf '%s\n' "$output" | tr -d '\r' | grep "^$1=" | head -1; }

assert_eq "exit code 0" "0" "$exit_code"
assert_not_contains "нет исполнения & из значений ('is not recognized')" "is not recognized" "$output"
assert_not_contains "нет parse error 'was unexpected at this time'" "was unexpected at this time" "$output"

# (а)+(б) секции и ключи распознаны — значения из конфига, не дефолты
assert_eq "[gpu] hw_accel = +intel распарсен (не дефолт :-:intel)" \
    "hw_accel=:+:intel" "$(get_line hw_accel)"

# (г) 5 хвостовых пробелов значения полностью срезаны + регистр секции/ключа
# ([VIDEO]/Quality в верхнем регистре — /i делает совпадение регистронезависимым)
assert_eq "[VIDEO] Quality (капитал) + 5 trailing spaces -> video_quality=:+:23" \
    "video_quality=:+:23" "$(get_line video_quality)"

# Task 8: инлайн # без пробела слева — часть значения (my#file.log целиком).
# F28: относительный log_file резолвится от папки скрипта, поэтому значение приходит
# абсолютным — проверяем, что имя с '#' уцелело целиком в хвосте пути.
_lf=$(get_line log_file)
case "$_lf" in
    *my#file.log) pass "log_file=my#file.log сохранён целиком (# без пробела)" ;;
    *) fail "log_file=my#file.log сохранён целиком (# без пробела)" "путь заканчивается на my#file.log" "$_lf" ;;
esac

# (д) пустое значение codec= -> остался дефолт :+:aac, не ':+:'
assert_eq "[audio] codec= (пусто) -> остался дефолт audio_codec=:+:aac" \
    "audio_codec=:+:aac" "$(get_line audio_codec)"

# (в) значение с & дошло целиком
assert_eq "subtitles_style дошёл целиком с &HFFFFFF&" \
    "subtitles_style=FontSize=20,PrimaryColour=&HFFFFFF&" "$(get_line subtitles_style)"

# Резолвинг путей: абсолютный source не префиксуется, относительный destination — префиксуется каталогом скрипта
assert_eq "абсолютный source не префиксован" \
    "folder_sources=C:\\abs\\src" "$(get_line folder_sources)"
assert_contains "относительный destination префиксован папкой скрипта" \
    "$WIN_TMP" "$(get_line folder_destination)"

# ══════════════════════════════════════════════════════════════
suite "CMD: ключи [remote] действительно разбираются"
# ══════════════════════════════════════════════════════════════
# Раньше «ключи [remote] в .cmd читаются» подтверждалось только `grep -w` по
# исходнику: --print-config о них не знал, и опечатка в имени ключа прошла бы
# незамеченной. Теперь они печатаются, и значения из тестового конфига видны.
assert_eq "remote_enabled разобран"       "remote_enabled=yes"                          "$(get_line remote_enabled)"
assert_eq "remote_endpoint разобран"      "remote_endpoint=https://svc.example.com/v1"  "$(get_line remote_endpoint)"
assert_eq "remote_prefer разобран"        "remote_prefer=gpu"                           "$(get_line remote_prefer)"
assert_eq "remote_wait_timeout разобран"  "remote_wait_timeout=60"                      "$(get_line remote_wait_timeout)"
assert_eq "remote_stall_timeout разобран" "remote_stall_timeout=120"                    "$(get_line remote_stall_timeout)"
assert_eq "remote_on_failure разобран"    "remote_on_failure=local"                     "$(get_line remote_on_failure)"
# Ключ службы наружу не печатаем: вывод --print-config попадает в логи CI.
assert_eq "ключ службы под маской"        "remote_api_key=***"                          "$(get_line remote_api_key)"
assert_not_contains "значение ключа не печатается" "s3cr3t-value" "$output"

# ══════════════════════════════════════════════════════════════
suite "CMD: дубликат ключа — побеждает ПЕРВОЕ вхождение"
# ══════════════════════════════════════════════════════════════
# Контракт всех платформ. Раньше в .cmd каждое присваивание перезаписывало
# переменную, то есть побеждало ПОСЛЕДНЕЕ: один config.ini давал libx264 в
# SH/PS1 и libx265 в CMD — молча.
printf '[video]\r\ncodec = +libx264\r\ncodec = +libx265\r\n' > "$TMP_DIR/config.ini"
dup_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1)
dup_line=$(printf '%s\n' "$dup_out" | tr -d '\r' | grep '^video_codec=' | head -1)
assert_eq "дубликат: победило первое вхождение" "video_codec=:+:libx264" "$dup_line"

# ══════════════════════════════════════════════════════════════
suite "CMD: инлайн-комментарий с '=' в хвосте"
# ══════════════════════════════════════════════════════════════
# Хвост после " #" вычитался подстановкой !_val: #<хвост>=!, и первый '=' в
# хвосте завершал искомую подстроку: `mp4,mkv # x=y` давало `mp4,mkvy==y`.
# PS1 (\s+#.*) и SH такой проблемы не имеют — один config.ini значил разное.
printf '[other]\r\nformat_files_in = mp4,mkv # x=y\r\ndry_run = yes # default=no, 50%% off\r\nlog_file = my#file.log # a # b=c\r\n' > "$TMP_DIR/config.ini"
sic_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
assert_eq "хвост 'x=y' срезан целиком" "format_files_in=mp4,mkv" \
    "$(printf '%s\n' "$sic_out" | grep '^format_files_in=' | head -1)"
assert_eq "хвост с '=', ',' и '%' срезан целиком" "dry_run=yes" \
    "$(printf '%s\n' "$sic_out" | grep '^dry_run=' | head -1)"
case "$(printf '%s\n' "$sic_out" | grep '^log_file=' | head -1)" in
    *'\my#file.log') pass "режется по ПЕРВОЙ ' #', '#' без пробела остаётся в значении" ;;
    *) fail "режется по ПЕРВОЙ ' #', '#' без пробела остаётся в значении" "…\\my#file.log" \
        "$(printf '%s\n' "$sic_out" | grep '^log_file=')" ;;
esac

# ══════════════════════════════════════════════════════════════
suite "CMD: \${ENV} — имя обязано быть идентификатором"
# ══════════════════════════════════════════════════════════════
# CMD брал имя как любой текст до '}' и подставлял ${MY-VAR}, а SH и PS1
# оставляли литерал — один config.ini давал разное. Контракт трёх платформ:
# [A-Za-z_][A-Za-z0-9_]*, иначе WARN и значение как есть.
printf '[other]\r\nformat_files_in = ${MY-VAR}/x\r\nsubtitles_style = ${1ABC}/y\r\ndry_run = ${FF_T_ENV_OK}\r\n' > "$TMP_DIR/config.ini"
env_out=$(env 'MY-VAR=leaked' FF_T_ENV_OK=yes cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
assert_eq "\${MY-VAR} остаётся литералом (переменная при этом задана)" 'format_files_in=${MY-VAR}/x' \
    "$(printf '%s\n' "$env_out" | grep '^format_files_in=' | head -1)"
assert_eq "\${1ABC} остаётся литералом" 'subtitles_style=${1ABC}/y' \
    "$(printf '%s\n' "$env_out" | grep '^subtitles_style=' | head -1)"
assert_contains "недопустимое имя → WARN" "недопустимое имя переменной окружения" "$env_out"
assert_eq "допустимое имя по-прежнему подставляется" "dry_run=yes" \
    "$(printf '%s\n' "$env_out" | grep '^dry_run=' | head -1)"

# ══════════════════════════════════════════════════════════════
suite "CMD: ключи [asr] разбираются; enabled = yes — отказ без конвертации"
# ══════════════════════════════════════════════════════════════
# Распознавание речи в CMD недоступно. Молча конвертировать вместо расшифровки
# нельзя: пользователь получил бы видео там, где ждал текст, поэтому — код 1.
printf '[asr]\r\nenabled = no\r\nendpoint = https://asr.example:30010 http://asr2.example:30000\r\napi_key = asr-s3cr3t\r\npinned_pubkey = sha256//AAAA=\r\nlanguage = en\r\ndiarize = no\r\nnum_speakers = 4\r\n' > "$TMP_DIR/config.ini"
asr_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
get_asr() { printf '%s\n' "$asr_out" | grep "^$1=" | head -1; }
assert_eq "asr_enabled"       "asr_enabled=no"                                                    "$(get_asr asr_enabled)"
assert_eq "asr_endpoint"      "asr_endpoint=https://asr.example:30010 http://asr2.example:30000" "$(get_asr asr_endpoint)"
assert_eq "asr_pinned_pubkey" "asr_pinned_pubkey=sha256//AAAA="                                   "$(get_asr asr_pinned_pubkey)"
assert_eq "asr_language"      "asr_language=en"                                                   "$(get_asr asr_language)"
assert_eq "asr_diarize"       "asr_diarize=no"                                                    "$(get_asr asr_diarize)"
assert_eq "asr_num_speakers"  "asr_num_speakers=4"                                                "$(get_asr asr_num_speakers)"
assert_eq "ключ ASR под маской" "asr_api_key=***"                                                 "$(get_asr asr_api_key)"
assert_not_contains "значение ключа ASR не печатается" "asr-s3cr3t" "$asr_out"

printf '[asr]\r\nendpoint = ${FF_T_ASR_UNSET}\r\n' > "$TMP_DIR/config.ini"
asr_env_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
assert_not_contains "незаданная \${VAR} в [asr] не печатает WARN" "FF_T_ASR_UNSET" "$asr_env_out"

printf '[asr]\r\nenabled = yes\r\n' > "$TMP_DIR/config.ini"
asr_run_out=$(cmd //c "$WIN_RUN" < /dev/null 2>&1); asr_run_rc=$?
asr_run_out=$(printf '%s' "$asr_run_out" | tr -d '\r')
assert_eq "enabled = yes — код 1" "1" "$asr_run_rc"
assert_contains "отказ объяснён" "Распознавание речи" "$asr_run_out"
# В TMP_DIR нет script.cmd: дошёл бы до вызова — сказал бы «не найден».
assert_not_contains "конвертация не запускалась" "не найден FFmpeg_Converter_script.cmd" "$asr_run_out"

# ══════════════════════════════════════════════════════════════
suite "CMD: '!' в пути каталога скрипта не теряется"
# ══════════════════════════════════════════════════════════════
# %~dp0 под EnableDelayedExpansion терял '!': config.ini и ffmpeg.exe рядом со
# скриптом не находились молча, относительные пути уезжали в чужой каталог, а
# script.cmd объявлялся ненайденным. Путь снимается в SCRIPT_DIR до setlocal.
# Вместо script.cmd — заглушка: она печатает, что ей передал run (тот же контекст
# delayed expansion, что у настоящего script.cmd).
BANG_DIR="$TMP_DIR/dir"'!'"bang"
mkdir -p "$BANG_DIR"
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.cmd" "$BANG_DIR/"
: > "$BANG_DIR/ffmpeg.exe"
printf '[audio]\r\ncodec = +opus\r\n[folders]\r\ndestination = outdir\r\n' > "$BANG_DIR/config.ini"
printf '@echo off\r\necho STUB ffmpeg=!ffmpeg!\r\necho STUB dst=!folder_destination!\r\n' > "$BANG_DIR/FFmpeg_Converter_script.cmd"
WIN_BANG=$(cygpath -w "$BANG_DIR")
bang_out=$(cmd //c "$WIN_BANG\\FFmpeg_Converter_run_v19.cmd --print-config" < /dev/null 2>&1 | tr -d '\r')
assert_eq "config.ini рядом со скриптом прочитан" "audio_codec=:+:opus" \
    "$(printf '%s\n' "$bang_out" | grep '^audio_codec=' | head -1)"
assert_eq "относительный destination резолвится в каталог с '!'" "folder_destination=$WIN_BANG\\outdir" \
    "$(printf '%s\n' "$bang_out" | grep '^folder_destination=' | head -1)"
assert_eq "относительный log_file резолвится в каталог с '!'" "log_file=$WIN_BANG\\ffmpeg_convert.log" \
    "$(printf '%s\n' "$bang_out" | grep '^log_file=' | head -1)"
bang_run=$(cmd //c "$WIN_BANG\\FFmpeg_Converter_run_v19.cmd" < /dev/null 2>&1 | tr -d '\r')
assert_contains "ffmpeg.exe рядом со скриптом найден" "STUB ffmpeg=$WIN_BANG\\ffmpeg.exe" "$bang_run"
assert_contains "script.cmd рядом со скриптом вызван" "STUB dst=$WIN_BANG\\outdir" "$bang_run"

# ══════════════════════════════════════════════════════════════
suite "CMD: script.cmd не найден — причина, пауза, код 1"
# ══════════════════════════════════════════════════════════════
# Как у ранних отказов script.cmd: голый pause (при stdin из nul он возвращается
# сразу — здесь это и проверяется: прогон не зависает).
LONE_DIR="$TMP_DIR/lone"
mkdir -p "$LONE_DIR"
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.cmd" "$LONE_DIR/"
cmd //c "$(cygpath -w "$LONE_DIR")\\FFmpeg_Converter_run_v19.cmd" < /dev/null > "$TMP_DIR/lone.out" 2>&1
lone_rc=$?
lone_out=$(tr -d '\r' < "$TMP_DIR/lone.out")
assert_eq       "script.cmd не найден — код 1"   "1"                                   "$lone_rc"
assert_contains "script.cmd не найден — причина" "не найден FFmpeg_Converter_script.cmd" "$lone_out"
# Текст приглашения pause зависит от языка Windows — паузу ищем в исходнике.
lone_src=$(grep -A4 'не найден FFmpeg_Converter_script.cmd' "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.cmd" | tr -d '\r')
assert_contains "script.cmd не найден — пауза перед выходом" $'\tpause\n\texit /b 1' "$lone_src"

rm -rf "$TMP_DIR"

summary
