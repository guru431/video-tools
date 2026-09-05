#!/bin/bash
set -uo pipefail

# ============================================================================
# download.sh — Универсальный скрипт загрузки видео с YouTube
# Платформы: Linux, macOS, Windows (Git Bash)
#
# Использование:
#   ./download.sh URL                           # скачать видео (720p)
#   ./download.sh --quality 1080 URL            # указать качество
#   ./download.sh --subs URL                    # только субтитры
#   ./download.sh --batch                       # все каналы из channels.txt
#   ./download.sh --batch --subs                # субтитры для всех каналов
#   ./download.sh --cookies browser URL         # cookies из браузера
#   ./download.sh --cookies file URL            # cookies из файла
#   ./download.sh --translate ru URL            # + AI-перевод аудио
#   ./download.sh --translate ru --mix URL      # перевод поверх оригинала
#   ./download.sh --trim-start 00:10 URL        # с 00:10 до конца ролика
#   ./download.sh --trim-end 00:30 URL          # с начала до 00:30
#   ./download.sh --trim-start 1:00 --trim-end 2:00 URL  # фрагмент 1:00-2:00
#   ./download.sh --help                        # справка
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.ini"
CHANNELS_FILE="${SCRIPT_DIR}/channels.txt"

# Бинари: env-override (для тестов) → рядом со скриптом → из PATH.
# Раньше резолвер был только у yt-dlp, а перевод звал bare `ffmpeg` — portable
# ffmpeg.exe рядом со скриптом не находился вовсе.
# .exe проверяем ПЕРВЫМ: в Git Bash `test -x dir/ffmpeg` истинно и тогда, когда
# рядом лежит только ffmpeg.exe — иначе вернули бы путь без расширения, который
# понимает лишь сам Git Bash.
resolve_bin() {
    local override="$1" name="$2"
    if [ -n "$override" ]; then
        printf '%s' "$override"
    elif [ -f "$SCRIPT_DIR/$name.exe" ]; then
        printf '%s' "$SCRIPT_DIR/$name.exe"
    elif [ -x "$SCRIPT_DIR/$name" ] && [ ! -d "$SCRIPT_DIR/$name" ]; then
        printf '%s' "$SCRIPT_DIR/$name"
    else
        printf '%s' "$name"
    fi
}
YTDLP="$(resolve_bin "${YTDLP_BIN:-}" yt-dlp)"
FFMPEG="$(resolve_bin "${FFMPEG_BIN:-}" ffmpeg)"
FFPROBE="$(resolve_bin "${FFPROBE_BIN:-}" ffprobe)"

# Абсолютный путь: POSIX (/x), Windows-диск (C:/x, C:\x) или UNC (\\host\share).
# Без распознавания drive/UNC `C:/Downloads` считался относительным и превращался
# в $SCRIPT_DIR/C:/Downloads.
is_abs_path() {
    case "$1" in
        /*|//*|\\\\*|[A-Za-z]:/*|[A-Za-z]:\\*) return 0 ;;
        *) return 1 ;;
    esac
}

# '~' в значении config.ini НЕ раскрывается оболочкой: значение приходит из файла,
# а не из командной строки. Без явного раскрытия `base_dir = ~/Видео` уезжал в
# `$SCRIPT_DIR/~/Видео` — каталог с буквальной тильдой в имени.
expand_tilde() {
    local p="$1"
    case "$p" in
        "~")   printf '%s' "${HOME:-$p}" ;;
        "~/"*) printf '%s' "${HOME:-~}/${p#\~/}" ;;
        *)     printf '%s' "$p" ;;
    esac
}

# ── JS-рантайм для yt-dlp (deno рядом со скриптом) ─────────────────────────
# С yt-dlp ≥ 2025.11 полная поддержка YouTube требует внешнего JS-рантайма.
#
# Две ловушки Git Bash, и раньше скрипт попадал в обе:
#   1. `[ -x "$dir/deno" ]` истинно и тогда, когда рядом лежит ТОЛЬКО deno.exe —
#      уезжал путь без расширения, который понимает лишь сам Git Bash. Поэтому
#      .exe проверяется ПЕРВЫМ (то же правило, что в resolve_bin выше);
#   2. MSYS переписывает POSIX-пути в Windows-вид только у аргументов, начинающихся
#      с '/' или '--x=/…'. Аргумент `deno:/d/…/deno.exe` уходит нативному процессу
#      КАК ЕСТЬ, и yt-dlp такого пути не находит. Конвертируем сами, как уже
#      сделано для каталога vot ниже.
# Итог обеих ошибок одинаков и тих: рантайм лежит рядом, а загрузки деградируют.
# Одна функция на оба места вызова (download_url и download_batch) — раньше это были
# две копии, и правка одной оставляла вторую сломанной.
build_js_runtime_args() {
    JS_RUNTIME_ARGS_ARR=()
    local dir deno=""
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$dir/deno.exe" ]; then
        deno="$dir/deno.exe"
    elif [ -x "$dir/deno" ] && [ ! -d "$dir/deno" ]; then
        deno="$dir/deno"
    fi
    [ -n "$deno" ] || return 0
    if command -v cygpath &>/dev/null; then
        deno="$(cygpath -w "$deno" 2>/dev/null || printf '%s' "$deno")"
    fi
    JS_RUNTIME_ARGS_ARR=(--js-runtimes "deno:$deno")
}

# ── Языковой тег для контейнера ────────────────────────────────────────────
# mp4-мультиплексор упаковывает РОВНО три символа (ISO 639-2) и на двухбуквенный
# код возвращает ошибку — поле языка остаётся пустым. Проверено на ffmpeg 8.1.2:
# language=ru/en/kk тега не дают вовсе, language=rus/eng/kaz дают (rus)/(eng)/(kaz).
# В MKV двухбуквенный код сохраняется, но общий трёхбуквенный корректен и там.
# Все avc1-пресеты выводят mp4, то есть по умолчанию обе дорожки dual_track
# оставались и без языка, и без имени.
iso639_2() {
    case "$1" in
        ru) printf 'rus' ;; en) printf 'eng' ;; kk) printf 'kaz' ;;
        de) printf 'deu' ;; fr) printf 'fra' ;; es) printf 'spa' ;;
        it) printf 'ita' ;; pt) printf 'por' ;; pl) printf 'pol' ;;
        uk) printf 'ukr' ;; tr) printf 'tur' ;; ja) printf 'jpn' ;;
        ko) printf 'kor' ;; zh) printf 'zho' ;; ar) printf 'ara' ;;
        be) printf 'bel' ;; uz) printf 'uzb' ;; az) printf 'aze' ;;
        # Уже трёхбуквенный (или незнакомый) код отдаём как есть: своё правило
        # лучше чужого молчания, но выдумывать за пользователя нечего.
        *)  printf '%s' "$1" ;;
    esac
}

# ── Цвета ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Уборка при Ctrl+C / SIGTERM ────────────────────────────────────────────
# Прерывание оставляло за собой три вида мусора: временный каталог перевода
# (/tmp/tmp.X с mp3), файл-манифест yt-dlp в %TEMP% и наполовину смерженный
# <video>_translated.mp4 рядом с оригиналом. Регистрируем всё это по мере
# создания — trap чистит и выходит с 130, как принято в ffmpeg-части репозитория.
YTDLP_TMP_PATHS=()
_register_tmp_path() { [ -n "${1:-}" ] && YTDLP_TMP_PATHS+=("$1"); }
_cleanup_on_int() {
    local p
    for p in "${YTDLP_TMP_PATHS[@]}"; do
        [ -n "$p" ] && rm -rf "$p" 2>/dev/null
    done
    exit 130
}
trap _cleanup_on_int INT TERM

# ── Счётчики для итоговой сводки ───────────────────────────────────────────
COUNT_OK=0
COUNT_SKIP=0
COUNT_FAIL=0
START_TIME=$(date +%s)

# ── Функции вывода ─────────────────────────────────────────────────────────
# printf '%b…%s', а не `echo -e`: последний интерпретирует escape-последовательности
# и в САМИХ ДАННЫХ. Windows-путь `C:\video\temp` печатался как `C:` + вертикальная
# табуляция + `ideo` + табуляция + `emp` — сообщение об ошибке врало о пути, по
# которому эту ошибку и надо искать. Цвета остаются в формате (%b), данные — в %s.
log_info()  { printf '%b[INFO]%b %s\n'  "$CYAN"   "$NC" "$*"; }
log_ok()    { printf '%b[OK]%b %s\n'    "$GREEN"  "$NC" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n'  "$YELLOW" "$NC" "$*"; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED"    "$NC" "$*"; }
log_header(){ printf '\n%b═══ %s ═══%b\n\n' "$BOLD" "$*" "$NC"; }

# ── Нормализация булевых и перечислимых значений config.ini ────────────────
# Булевы ключи сравнивались буквально с "true"/"false", а ffmpeg-сторона того же
# репозитория пишет yes/no — путаница неизбежна и была молчаливой:
# `use_archive = yes` выключал архив, `continue_on_error = no` всё равно давал -i.
# Принимаем весь обычный набор написаний; всё непонятное — WARN и умолчание.
to_bool() {
    local raw="$1" def="$2" name="${3:-}"
    case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
        true|yes|on|1)   printf 'true'  ;;
        false|no|off|0)  printf 'false' ;;
        "")              printf '%s' "$def" ;;
        *)
            [ -n "$name" ] && log_warn "$name: непонятное значение '$raw' (ожидается yes/no) — использую '$def'." >&2
            printf '%s' "$def" ;;
    esac
}

# Перечислимые ключи из config.ini не проверялись вовсе, тогда как те же значения из
# CLI валидируются: `format_preset = AVC1_BEST` или `default_quality = 4k` молча
# давали другое поведение (720p без ограничения кодека) без единого слова.
# Имя намеренно НЕ validate_enum: так называется валидатор аргументов CLI ниже по
# файлу, и он ПЕРЕКРЫВАЛ эту функцию — для валидного значения возвращал код 0 и
# ничего не печатал, поэтому `X=$(validate_enum …)` присваивал пустую строку, и
# format_preset/audio_format/sponsorblock молча обнулялись. Для config.ini поведение
# другое и по существу: предупредить и взять умолчание, а не завершить прогон.
config_enum() {
    local name="$1" value="$2" def="$3"; shift 3
    local allowed=("$@") a
    for a in "${allowed[@]}"; do
        [ "$value" = "$a" ] && { printf '%s' "$value"; return; }
    done
    log_warn "$name: недопустимое значение '$value' (допустимо: ${allowed[*]}) — использую '$def'." >&2
    printf '%s' "$def"
}

# ── Чтение config.ini ─────────────────────────────────────────────────────
read_config() {
    local key="$1"
    local section="$2"
    local default="${3:-}"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$default"
        return
    fi

    # F15. Регистронезависимое сравнение ключей/секций — паритет с PS1 (хеш-таблица
    # PowerShell регистронезависима) и с ffmpeg run.sh. Раньше [DOWNLOAD] или
    # Default_Quality работали в GUI, но в SH молча давали default.
    local saved_ncm; saved_ncm=$(shopt -p nocasematch)
    shopt -s nocasematch
    local in_section=false
    local value=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Trim через bash parameter expansion. На Windows Git Bash sed-fork ~500ms/вызов
        # (cygwin overhead) × 2 на строку × 30 строк × 20 ключей ≈ 10+ минут.
        # Bash builtin — мгновенно.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        # \r из CRLF-файлов (config.ini на Windows может быть CRLF)
        line="${line%$'\r'}"
        # Пропустить комментарии и пустые строки
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Секция
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "$section" ]]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi

        # Ключ=значение внутри нужной секции
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            value="${BASH_REMATCH[1]}"
            # Inline-комментарий: режем по ПЕРВОМУ " # " (пробел+решётка) через parameter
            # expansion — как ffmpeg run.sh. Прежний regex с жадным .* резал по ПОСЛЕДНЕМУ
            # " #", утаскивая часть значения. `val#ue` без пробела не комментарий.
            if [[ "$value" == *' #'* ]]; then
                value="${value%% #*}"
                value="${value%"${value##*[![:space:]]}"}"
            fi
            # Подстановка ${ENV_VAR} из окружения. Не задана → пустая строка + WARN.
            # Несколько вхождений поддерживаются (цикл по первому ${...} за итерацию).
            #
            # Два ограничителя, и оба обязательны:
            #   • имя обязано быть валидным идентификатором. `${}` давало пустое имя,
            #     а `${A-B}` — имя с дефисом: `${!_vn}` бросал «invalid variable name»,
            #     значение терялось целиком, и WARN об этом не говорил ни слова;
            #   • счётчик итераций. Значение переменной, содержащее ссылку на саму себя
            #     (SELF='${SELF}' в окружении), давало бесконечный цикл — скрипт висел
            #     молча, не дойдя до первой загрузки.
            local _sub_guard=0
            while [[ "$value" == *'${'*'}'* ]] && [ "$_sub_guard" -lt 32 ]; do
                _sub_guard=$((_sub_guard + 1))
                local _vn="${value#*\$\{}"; _vn="${_vn%%\}*}"
                if [[ ! "$_vn" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    echo "WARN: '\${$_vn}' — недопустимое имя переменной окружения, оставлено как есть" >&2
                    break
                fi
                [ -n "${!_vn:-}" ] || echo "WARN: переменная $_vn не задана" >&2
                value="${value//\$\{$_vn\}/${!_vn:-}}"
            done
            eval "$saved_ncm"
            echo "$value"
            return
        fi
    done < "$CONFIG_FILE"

    eval "$saved_ncm"
    echo "$default"
}

# ── Проверка зависимостей ──────────────────────────────────────────────────
check_dependency() {
    if ! command -v "$1" &>/dev/null; then
        log_error "$1 не найден. $2"
        return 1
    fi
    return 0
}

# ── Диагностика окружения (--doctor) ───────────────────────────────────────
# Одна команда вместо пяти разных отказов на разных стадиях. До неё пользователь
# узнавал об отсутствии deno на первом же ролике с челленджем, об отсутствии
# ffprobe — на первом переводе в режиме dual_track, а о том, что npm-шим vot не
# запускается, — только из сырого исключения. Отчёт печатает, ЧТО именно
# перестаёт работать без каждого инструмента: это и есть недостающая половина.
doctor_row() {
    printf '  %-14s %-9s %s\n' "$1" "$2" "$3"
}

doctor_tool() {
    local name="$1" path="$2" why="$3" version=""
    if [ -z "$path" ]; then
        doctor_row "$name" "НЕТ" "$why"
        return 1
    fi
    # Версию спрашиваем best-effort: инструмент может её не поддерживать.
    version="$("$path" --version 2>/dev/null | head -1)"
    [ -n "$version" ] || version="$path"
    doctor_row "$name" "есть" "$version"
    return 0
}

# Возвращает путь к бинарю или пустую строку. Тот же порядок, что у resolve_bin:
# рядом со скриптом (сначала .exe), затем PATH.
doctor_which() {
    local name="$1" p
    p="$(resolve_bin "" "$name")"
    case "$p" in
        */*) [ -f "$p" ] && { printf '%s' "$p"; return 0; } ;;
    esac
    command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
    printf ''
    return 1
}

run_doctor() {
    log_header "Проверка окружения"
    echo "Каталог скрипта: $SCRIPT_DIR"
    echo "Конфиг:          $CONFIG_FILE$([ -f "$CONFIG_FILE" ] || printf ' (нет — используются умолчания)')"
    echo ""
    echo "  инструмент     статус   путь / версия · что без него не работает"
    echo "  -------------- -------- -------------------------------------------"

    local rc=0
    doctor_tool "yt-dlp"   "$(doctor_which yt-dlp)"        "ЗАГРУЗКА НЕВОЗМОЖНА — это основной инструмент" || rc=1
    doctor_tool "ffmpeg"   "$(doctor_which ffmpeg)"        "не будет мержа дорожек (AI-перевод) и склейки форматов +" || rc=1
    doctor_tool "ffprobe"  "$(doctor_which ffprobe)"       "не работает режим перевода dual_track (подсчёт дорожек)" || true
    doctor_tool "deno"     "$(doctor_which deno)"          "YouTube требует JS-рантайм: загрузки деградируют или падают" || true
    if [ -n "${VOT_BIN:-}" ]; then
        doctor_tool "vot-cli-live" "$VOT_BIN" "нет AI-перевода" || true
    else
        doctor_tool "vot-cli-live" "$(doctor_which vot-cli-live)" "нет AI-перевода" || true
    fi

    echo ""
    echo "Настройки, влияющие на сеть и раскладку файлов:"
    # Здесь без выравнивания по колонкам: printf считает БАЙТЫ, а кириллическая
    # подпись занимает по два на символ — колонки разъезжались бы тем сильнее,
    # чем длиннее слово.
    echo "  Прокси:   $(mask_proxy "$PROXY_URL")"
    echo "  База:     $BASE_DIR"
    echo "  Архив:    $([ "$USE_ARCHIVE" = "true" ] && printf '%s' "$ARCHIVE_FILE" || printf 'выключен')"
    echo "  Cookies:  $COOKIE_METHOD$([ "$COOKIE_METHOD" = "file" ] && printf ' → %s' "$COOKIE_FILE_PATH")"
    echo "  Плейлист: ${PLAYLIST_MODE:-auto}"
    echo ""
    if [ "$rc" -eq 0 ]; then
        log_ok "Обязательные инструменты на месте."
    else
        log_error "Не хватает обязательных инструментов — см. таблицу выше."
    fi
    return $rc
}

check_base_deps() {
    check_dependency "$YTDLP" "Установите: https://github.com/yt-dlp/yt-dlp" || exit 1
}

check_translate_deps() {
    local missing=0
    # Режим проверяем ЗДЕСЬ, до сети: невалидный mode доходил до case в
    # translate_audio, не совпадал ни с одной веткой, и перевод «не выполнялся»
    # уже ПОСЛЕ скачивания перевода — минуты и трафик впустую.
    case "$TRANSLATE_MODE" in
        dual_track|mix|replace) ;;
        *)
            log_error "[translation] mode = '$TRANSLATE_MODE' — допустимо dual_track, mix или replace."
            missing=1 ;;
    esac
    # dual_track считает число оригинальных дорожек через ffprobe. Без него индекс
    # молча стал бы 1, и на файле с 2+ дорожками перевод сел бы на чужой индекс.
    if [ "$TRANSLATE_MODE" = "dual_track" ]; then
        check_dependency "$FFPROBE" "ffprobe нужен режиму dual_track (подсчёт аудиодорожек); ставится вместе с ffmpeg" || missing=1
    fi
    check_dependency "$FFMPEG" "Установите: https://ffmpeg.org/download.html" || missing=1
    # Бинарь vot: env-override (для тестов) → рядом со скриптом → из PATH.
    # Паритет с резолвером YTDLP_BIN; без override тесты уходили в реальную сеть.
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -n "${VOT_BIN:-}" ]; then
        :
    elif [ -x "$script_dir/vot-cli-live" ] || [ -f "$script_dir/vot-cli-live.exe" ]; then
        VOT_BIN="$script_dir/vot-cli-live"
        [ -f "$script_dir/vot-cli-live.exe" ] && VOT_BIN="$script_dir/vot-cli-live.exe"
    elif command -v vot-cli-live &>/dev/null; then
        VOT_BIN="vot-cli-live"
    else
        log_error "vot-cli-live не найден. Положите vot-cli-live рядом со скриптом или установите: npm install -g vot-cli-live"
        missing=1
    fi
    return $missing
}

# ── Формирование аргументов cookies (записывает в global COOKIE_ARGS_ARR) ──
# Глобальный массив вместо строки — чтобы пути с пробелами/спецсимволами
# проходили в yt-dlp как отдельные argv-элементы (без eval, без injection).
COOKIE_ARGS_ARR=()
build_cookie_args() {
    local method="$1"
    local cookie_file="$2"
    local cookie_browser="$3"
    COOKIE_ARGS_ARR=()

    case "$method" in
        file)
            if [ -f "$cookie_file" ]; then
                COOKIE_ARGS_ARR=(--cookies "$cookie_file")
            else
                log_warn "Файл cookies не найден: $cookie_file"
            fi
            ;;
        browser)
            COOKIE_ARGS_ARR=(--cookies-from-browser "$cookie_browser")
            ;;
        none|"")
            ;;
        *)
            log_warn "Неизвестный метод cookies: $method"
            ;;
    esac
}

# ── Определение платформы по URL ───────────────────────────────────────────
detect_platform() {
    local url="$1"
    # Регистр хоста не значим (RFC 3986), поэтому HTTPS://YOUTUBE.COM/... — тот же
    # youtube. Приводим к нижнему регистру только host: путь/query регистрозависимы,
    # а `tr` вместо ${url,,} — Bash 3.2 на macOS не знает ,,-раскрытия.
    local host="${url#*://}"
    host="${host%%/*}"; host="${host%%\?*}"; host="${host%%#*}"
    host="$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')"
    # Домен якорим по границе (начало строки, '.', '@'), иначе notyoutube.com
    # ошибочно распознаётся как youtube (подстрочный матч).
    # youtube-nocookie.com — домен embed-плеера YouTube. Раньше он попадал в "other"
    # и получал пресет `best[height<=N]/best`: один комбинированный поток ≤720p вместо
    # раздельных дорожек, то есть заметно худшее качество без единого слова об этом.
    if   [[ "$host" =~ (^|[.@])youtube\.com(:|$) ]] || [[ "$host" =~ (^|[.@])youtu\.be(:|$) ]] \
      || [[ "$host" =~ (^|[.@])youtube-nocookie\.com(:|$) ]]; then echo "youtube"
    elif [[ "$host" =~ (^|[.@])vk\.com(:|$) ]];         then echo "vk"
    elif [[ "$host" =~ (^|[.@])rutube\.ru(:|$) ]];      then echo "rutube"
    elif [[ "$host" =~ (^|[.@])twitch\.tv(:|$) ]];      then echo "twitch"
    elif [[ "$host" =~ (^|[.@])vimeo\.com(:|$) ]];      then echo "vimeo"
    elif [[ "$host" =~ (^|[.@])dailymotion\.com(:|$) ]];then echo "dailymotion"
    else echo "other"
    fi
}

# ── Формирование аргументов формата (записывает в global FMT_ARGS_ARR) ─────
# Один спецификатор (даже с `<=`, `^=`, `[]`) — единый argv-токен; bash array
# гарантирует это без shell-injection через eval.
FMT_ARGS_ARR=()
build_format_args() {
    local quality="$1"
    local preset="${2:-auto}"
    local platform="${3:-youtube}"
    local fmt=""

    # auto: для YouTube — avc1_best, для остальных — простой best[height<=N]
    if [ "$preset" = "auto" ]; then
        if [ "$platform" = "youtube" ]; then
            preset="avc1_best"
        else
            case "$quality" in
                audio) fmt="bestaudio/best" ;;
                360)   fmt="best[height<=360]/best" ;;
                480)   fmt="best[height<=480]/best" ;;
                720)   fmt="best[height<=720]/best" ;;
                1080)  fmt="best[height<=1080]/best" ;;
                1440)  fmt="best[height<=1440]/best" ;;
                2160)  fmt="best[height<=2160]/best" ;;
                *)     fmt="best[height<=720]/best" ;;
            esac
            FMT_ARGS_ARR=(-f "$fmt")
            return
        fi
    fi

    case "$preset" in
        avc1_best)
            case "$quality" in
                audio) fmt="bestaudio[ext!=webm]/bestaudio" ;;
                360)   fmt="bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360]" ;;
                480)   fmt="bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480]" ;;
                720)   fmt="bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]" ;;
                1080)  fmt="bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080]" ;;
                1440)  fmt="bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440]" ;;
                2160)  fmt="bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160]" ;;
                *)     fmt="bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]" ;;
            esac ;;
        avc1_https)
            case "$quality" in
                audio) fmt="140" ;;
                360)   fmt="140+134" ;;
                480)   fmt="140+135/140+134" ;;
                720)   fmt="140+136/140+135/140+134" ;;
                1080)  fmt="140+137/140+136/140+135/140+134" ;;
                1440)  fmt="140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]" ;;
                2160)  fmt="140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]" ;;
                *)     fmt="140+136/140+135/140+134" ;;
            esac ;;
        avc1_m3u8)
            case "$quality" in
                audio) fmt="234" ;;
                360)   fmt="234+230" ;;
                480)   fmt="234+231/234+230" ;;
                720)   fmt="234+232/234+231/234+230" ;;
                1080)  fmt="270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]" ;;
                1440)  fmt="bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]" ;;
                2160)  fmt="bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]" ;;
                *)     fmt="234+232/234+231/234+230" ;;
            esac ;;
        avc1_https_60fps)
            case "$quality" in
                audio) fmt="140" ;;
                360)   fmt="140+134/best[height<=360]" ;;
                480)   fmt="140+135/best[height<=480]" ;;
                720)   fmt="140+298/best[height<=720]" ;;
                1080)  fmt="140+299/140+298/best[height<=1080]" ;;
                1440)  fmt="bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=1440]" ;;
                2160)  fmt="bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=2160]" ;;
                *)     fmt="140+298/best[height<=720]" ;;
            esac ;;
        avc1_m3u8_60fps)
            case "$quality" in
                audio) fmt="234" ;;
                360)   fmt="234+309/bestvideo[height<=360][fps>=50]+bestaudio/best[height<=360]" ;;
                480)   fmt="234+310/234+309/bestvideo[height<=480][fps>=50]+bestaudio/best[height<=480]" ;;
                720)   fmt="234+311/234+310/234+309/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]" ;;
                1080)  fmt="234+312/234+311/234+310/234+309/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]" ;;
                1440)  fmt="234+313/234+312/234+311/234+310/234+309/bestvideo[height<=1440][fps>=50]+bestaudio/best[height<=1440]" ;;
                2160)  fmt="234+314/234+313/234+312/234+311/234+310/234+309/bestvideo[height<=2160][fps>=50]+bestaudio/best[height<=2160]" ;;
                *)     fmt="234+311/234+310/234+309/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]" ;;
            esac ;;
        avc1_https_60fps_hdr)
            case "$quality" in
                audio) fmt="234" ;;
                360)   fmt="234+696/bestvideo[height<=360][fps>=50]+bestaudio/best[height<=360]" ;;
                480)   fmt="234+697/234+696/bestvideo[height<=480][fps>=50]+bestaudio/best[height<=480]" ;;
                720)   fmt="234+698/234+697/234+696/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]" ;;
                1080)  fmt="234+699/234+698/234+697/234+696/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]" ;;
                1440)  fmt="234+700/234+699/234+698/234+697/234+696/bestvideo[height<=1440][fps>=50]+bestaudio/best[height<=1440]" ;;
                2160)  fmt="234+701/234+700/234+699/234+698/234+697/234+696/bestvideo[height<=2160][fps>=50]+bestaudio/best[height<=2160]" ;;
                *)     fmt="234+698/234+697/234+696/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]" ;;
            esac ;;
        old_combo)
            case "$quality" in
                audio) fmt="140" ;;
                360)   fmt="18" ;;
                480)   fmt="59/22/18" ;;
                720)   fmt="22/18" ;;
                1080)  fmt="37/22/18" ;;
                1440)  fmt="38/37/22/18" ;;
                2160)  fmt="38/37/22/18" ;;
                *)     fmt="22/18" ;;
            esac ;;
        *)
            fmt="bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]" ;;
    esac
    FMT_ARGS_ARR=(-f "$fmt")
}

# ── Лимит длины пути ───────────────────────────────────────────────────────
# Windows обрывается на MAX_PATH = 260 символов вместе с NUL, то есть 259 на путь.
# Папку yt-dlp создаёт успешно (она короче), а открыть файл уже не может: Win32
# отдаёт ERROR_PATH_NOT_FOUND, Python переводит это в ENOENT, и сообщение врёт —
# «unable to open for writing: [Errno 2] No such file or directory». Переполняют
# путь именно промежуточные файлы: к финальному имени добавляются .fNNN, .m4a,
# .part и -FragNNN, поэтому финальное имя может влезать, а закачка всё равно падать.
#
# Лимиты проставляются ЗДЕСЬ, а не в config.ini: защита обязана работать и без ini,
# и с ini, где шаблон записан без лимитов. Длина полей %(title)s/%(playlist)s заранее
# неизвестна, поэтому единственный способ удержать бюджет — задать им лимит принудительно.
LIMIT_MAX_PATH=259
LIMIT_RESERVE=32          # .fNNN + .m4a + .part + -FragNNN

# Третий аргумент (предел длины пути) — необязательный: production его не передаёт и
# получает платформенное значение, тест передаёт явно. Без него ожидания теста зависели
# бы от ОС раннера — на Linux/macOS ветка ниже даёт другой бюджет, и CI падал.
limit_output_template() {
    local base="$1" tpl="$2" max_path="${3:-}"
    local def_title=100 def_playlist=45 def_uploader=30
    local min_title=25   min_playlist=15 min_uploader=10

    # posix_component=yes означает «ограничение на ОДИН компонент, а не на весь путь».
    # Прежняя формула max_path = len(base)+1+127 давала на POSIX тот же общий бюджет,
    # что и на Windows: шаблон из нескольких компонентов
    # («%(uploader)s/%(playlist)s/%(title)s.%(ext)s») делил 127 символов на всех, и
    # название ролика резалось до ~47 символов там, где каждый компонент может быть
    # 255 БАЙТ. Считаем бюджет по САМОМУ ДЛИННОМУ компоненту шаблона.
    local posix_component="no"
    if [ -z "$max_path" ]; then
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) max_path=$LIMIT_MAX_PATH ;;
            *) posix_component="yes" ;;
        esac
    fi
    local budget
    if [ "$posix_component" = "yes" ]; then
        # 255 байт на компонент; кириллица в UTF-8 — два байта на символ, поэтому
        # считаем консервативно в «символах по два байта»: 127.
        budget=$(( 127 - LIMIT_RESERVE ))
        # Литералы и прочие поля считаются ниже по ВСЕМУ шаблону, что для
        # покомпонентного бюджета — верхняя оценка (то есть в безопасную сторону).
    else
        budget=$(( max_path - ${#base} - 1 - LIMIT_RESERVE ))
    fi

    # Литеральная часть шаблона: разделители, дефисы, точки — всё, кроме полей.
    local literals
    literals=$(printf '%s' "$tpl" | sed 's/%([^)]*)[^a-zA-Z%]*[a-zA-Z]//g')
    local used=${#literals}

    # Прочие поля — консервативные оценки; неизвестное поле считаем длинным.
    local field name lim
    while read -r field; do
        [ -z "$field" ] && continue
        name=${field%%)*}; name=${name#%(}
        case "$name" in
            title|playlist|uploader|channel) continue ;;   # считаются отдельно ниже
        esac
        lim=$(printf '%s' "$field" | sed -n 's/.*)\.\([0-9][0-9]*\).*/\1/p')
        if [ -n "$lim" ]; then used=$(( used + lim )); continue; fi
        case "$name" in
            ext)                       used=$(( used + 5 ))  ;;
            playlist_index|autonumber) used=$(( used + 4 ))  ;;
            upload_date|release_date)  used=$(( used + 8 ))  ;;
            id)                        used=$(( used + 12 )) ;;
            *)                         used=$(( used + 30 )) ;;
        esac
    done <<< "$(printf '%s' "$tpl" | grep -o '%([^)]*)[^a-zA-Z%]*[a-zA-Z]')"

    # Присутствие длинных полей и уже заданные пользователем лимиты. Пользовательский
    # лимит уважаем, но только в сторону уменьшения — иначе ini снова вернёт нас в MAX_PATH.
    # Поле распознаётся и в форме альтернатив: yt-dlp допускает %(title|Без имени)s
    # и %(uploader,channel)s. Прежний точный поиск '%(title)' их не видел вовсе —
    # лимит не ставился, и как раз на таких шаблонах путь и переполнялся.
    # Граница после имени: ')' (обычная форма), '|' (значение по умолчанию),
    # ',' (список альтернатив), '.' (уже заданный лимит).
    local t=0 p=0 u=0 user user_ch
    if printf '%s' "$tpl" | grep -qE '%\(title[|,).]'; then
        t=$def_title
        user=$(printf '%s' "$tpl" | sed -n 's/.*%(title)\.\([0-9][0-9]*\).*/\1/p')
        [ -n "$user" ] && [ "$user" -lt "$t" ] && t=$user
    fi
    if printf '%s' "$tpl" | grep -qE '%\(playlist[|,).]'; then
        p=$def_playlist
        user=$(printf '%s' "$tpl" | sed -n 's/.*%(playlist)\.\([0-9][0-9]*\).*/\1/p')
        [ -n "$user" ] && [ "$user" -lt "$p" ] && p=$user
    fi
    if printf '%s' "$tpl" | grep -qE '%\((uploader|channel)[|,).]'; then
        u=$def_uploader
        # Пользовательский лимит читаем у ОБОИХ полей и берём меньший: раньше
        # смотрели только на uploader, поэтому «%(channel).10s» переписывался
        # в «.30s» — лимит УВЕЛИЧИВАЛСЯ вопреки правилу «только в сторону
        # уменьшения», прямо противоположно тому, что обещает комментарий выше.
        user=$(printf '%s' "$tpl" | sed -n 's/.*%(uploader)\.\([0-9][0-9]*\).*/\1/p')
        user_ch=$(printf '%s' "$tpl" | sed -n 's/.*%(channel)\.\([0-9][0-9]*\).*/\1/p')
        if [ -n "$user_ch" ]; then
            if [ -z "$user" ] || [ "$user_ch" -lt "$user" ]; then user="$user_ch"; fi
        fi
        [ -n "$user" ] && [ "$user" -lt "$u" ] && u=$user
    fi

    # Ужимаем по приоритету: сперва название ролика, потом плейлист, потом автор —
    # обрезанное имя файла терпимо, потерянная структура папок хуже.
    local deficit=$(( used + t + p + u - budget ))
    local cut
    if [ "$deficit" -gt 0 ] && [ "$t" -gt 0 ]; then
        cut=$(( t - min_title )); [ "$cut" -gt "$deficit" ] && cut=$deficit
        [ "$cut" -gt 0 ] && { t=$(( t - cut )); deficit=$(( deficit - cut )); }
    fi
    if [ "$deficit" -gt 0 ] && [ "$p" -gt 0 ]; then
        cut=$(( p - min_playlist )); [ "$cut" -gt "$deficit" ] && cut=$deficit
        [ "$cut" -gt 0 ] && { p=$(( p - cut )); deficit=$(( deficit - cut )); }
    fi
    if [ "$deficit" -gt 0 ] && [ "$u" -gt 0 ]; then
        cut=$(( u - min_uploader )); [ "$cut" -gt "$deficit" ] && cut=$deficit
        [ "$cut" -gt 0 ] && { u=$(( u - cut )); deficit=$(( deficit - cut )); }
    fi
    if [ "$deficit" -gt 0 ]; then
        log_warn "Папка назначения слишком длинная (${#base} симв.) — путь может превысить лимит Windows даже с минимальными именами. Выберите папку короче." >&2
    fi

    # Подставляем лимиты, сохраняя тип конверсии (s/U/B) — он задан пользователем.
    [ "$t" -gt 0 ] && tpl=$(printf '%s' "$tpl" | sed "s/%(title)\(\.[0-9][0-9]*\)\{0,1\}\([a-zA-Z]\)/%(title).${t}\2/g")
    [ "$p" -gt 0 ] && tpl=$(printf '%s' "$tpl" | sed "s/%(playlist)\(\.[0-9][0-9]*\)\{0,1\}\([a-zA-Z]\)/%(playlist).${p}\2/g")
    if [ "$u" -gt 0 ]; then
        tpl=$(printf '%s' "$tpl" | sed "s/%(uploader)\(\.[0-9][0-9]*\)\{0,1\}\([a-zA-Z]\)/%(uploader).${u}\2/g")
        tpl=$(printf '%s' "$tpl" | sed "s/%(channel)\(\.[0-9][0-9]*\)\{0,1\}\([a-zA-Z]\)/%(channel).${u}\2/g")
    fi
    printf '%s' "$tpl"
}

# ── Скачивание одного URL ──────────────────────────────────────────────────
# Прокси-URL передаётся через global PROXY_URL (не в argv) — пароль не утекает
# в `ps aux`. Cookies и формат — через global *_ARR массивы, заполненные
# build_*-функциями. Команда выполняется напрямую через "${cmd[@]}", без eval.
download_url() {
    local url="$1"
    local output_template="$2"
    local quality="$3"
    local subs_only="$4"
    local archive_path="${5:-}"
    local trim_start_on="${6:-false}"
    local trim_start_val="${7:-}"
    local trim_end_on="${8:-false}"
    local trim_end_val="${9:-}"
    local force_kf="${10:-false}"

    # continue_on_error: true → -i (пропускать ошибки), false → --abort-on-error.
    local _err_flag="-i"; [ "${CONTINUE_ON_ERROR:-true}" = "false" ] && _err_flag="--abort-on-error"
    build_net_args
    local -a cmd=("$YTDLP" -c "$_err_flag" -w --windows-filenames --compat-options filename-sanitization
                  "${NET_ARGS_ARR[@]}")

    # Deno рядом со скриптом (см. build_js_runtime_args — там же обе ловушки Git Bash).
    build_js_runtime_args
    [ ${#JS_RUNTIME_ARGS_ARR[@]} -gt 0 ] && cmd+=("${JS_RUNTIME_ARGS_ARR[@]}")

    # F13. Точный handshake вместо поиска по mtime: yt-dlp сам сообщает финальный путь
    # каждого готового файла (after_move — уже после всех post-processor'ов и move).
    # --print-to-file пишет в наш per-process файл, не смешиваясь с прогрессом в stdout.
    # Без этого перевод искал «самый свежий файл в дереве» и мог утащить чужую загрузку.
    [ -n "${DL_MANIFEST:-}" ] && cmd+=(--print-to-file "after_move:filepath" "$DL_MANIFEST")

    # Прокси через переменную окружения — пароль не виден в ps aux
    local -a env_prefix=()
    if [ -n "${PROXY_URL:-}" ]; then
        env_prefix=(env "HTTP_PROXY=$PROXY_URL" "HTTPS_PROXY=$PROXY_URL" "ALL_PROXY=$PROXY_URL")
    fi

    # Cookies (массив, заполнен build_cookie_args)
    [ "${#COOKIE_ARGS_ARR[@]}" -gt 0 ] && cmd+=("${COOKIE_ARGS_ARR[@]}")

    # Архив скачанного. НЕ для режима «только субтитры»: архив хранит ID видео, а не
    # факт наличия субтитров; иначе субтитры после обычной загрузки молча пропускаются
    # (F3, паритет с CMD, который уже исключает архив для субтитров).
    [ -n "$archive_path" ] && [ "$subs_only" != "true" ] && cmd+=(--download-archive "$archive_path")

    # Шаблон вывода
    cmd+=(-o "$output_template")

    if [ "$subs_only" = "true" ]; then
        # F31. Ручные субтитры не теряем: --write-subs запрашивает авторские, --write-auto-subs
        # оставляет автоматические как fallback. Раньше слался только auto-флаг, хотя ни UI,
        # ни документация не обещают «только автоматические» — авторские (обычно точнее)
        # молча пропадали. Режим «субтитры вместе с видео» уже делал ровно так.
        # --sub-langs/--sub-format — актуальные имена (--sub-lang — legacy-алиас).
        cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG" --sub-format "$SUB_FORMAT" --skip-download)
    else
        build_format_args "$quality" "$FORMAT_PRESET" "$(detect_platform "$url")"
        cmd+=("${FMT_ARGS_ARR[@]}")

        # Плейлист: single → только указанное видео, full → весь плейлист,
        # auto → решает yt-dlp (прежнее поведение).
        case "${PLAYLIST_MODE:-auto}" in
            single) cmd+=(--no-playlist) ;;
            full)   cmd+=(--yes-playlist) ;;
        esac

        # Метаданные и главы источника (архивная ценность; для видео без глав — no-op).
        cmd+=(--embed-metadata --embed-chapters)

        # Перекодирование в аудиоформат (только при quality=audio и заданном формате)
        if [ "$quality" = "audio" ]; then
            # --extract-audio ставится ВСЕГДА, а формат — только когда он задан явно.
            # Раньше при audio_format = best (умолчание!) не ставилось ничего: на
            # площадках без чисто аудиопотока (VK, RuTube) селектор bestaudio/best
            # брал полноценное ВИДЕО и отдавал его как «только аудио» — гигабайты
            # вместо мегабайт, молча.
            cmd+=(--extract-audio --audio-quality 0)
            case "$AUDIO_FORMAT" in
                mp3|m4a|opus|flac|wav) cmd+=(--audio-format "$AUDIO_FORMAT") ;;
            esac
        fi

        # SponsorBlock (только для реальных загрузок)
        case "$SPONSORBLOCK" in
            remove) cmd+=(--sponsorblock-remove all) ;;
            mark)   cmd+=(--sponsorblock-mark all) ;;
        esac

        # Субтитры вместе с видео (sidecar/embed; opt-in, по умолчанию off)
        case "$SUBS_WITH_VIDEO" in
            sidecar) cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG") ;;
            embed)   cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG" --embed-subs) ;;
        esac
    fi

    # Фрагмент: только start = с TIME до конца; только end = с начала до TIME;
    # оба = фрагмент TIME1..TIME2; ни один = весь ролик.
    if [ "$trim_start_on" = "true" ] || [ "$trim_end_on" = "true" ]; then
        local from="0"
        local to="inf"
        [ "$trim_start_on" = "true" ] && [ -n "$trim_start_val" ] && from="$trim_start_val"
        [ "$trim_end_on"   = "true" ] && [ -n "$trim_end_val"   ] && to="$trim_end_val"
        cmd+=(--download-sections "*${from}-${to}")
        [ "$force_kf" = "true" ] && cmd+=(--force-keyframes-at-cuts)
    fi

    # F30. '--' закрывает список опций: всё дальше yt-dlp обязан трактовать как
    # позиционный URL, даже если строка начинается с дефиса. Иначе значение вроде
    # '--version' исполнилось бы как ОПЦИЯ вместо загрузки, а '-U' подменил бы бинарь.
    cmd+=(--)
    cmd+=("$url")

    if [ "$DRY_RUN" = "true" ]; then
        local proxy_note=""
        [ -n "${PROXY_URL:-}" ] && proxy_note="env HTTP_PROXY/HTTPS_PROXY/ALL_PROXY=$(mask_proxy "$PROXY_URL") "
        echo "[DRY-RUN] ${proxy_note}${cmd[*]}"
        return 0
    fi

    log_info "Команда: ${cmd[*]}"

    if "${env_prefix[@]+"${env_prefix[@]}"}" "${cmd[@]}"; then
        # Архив включён, но yt-dlp ничего не переместил (after_move не сработал → пустой
        # manifest) — значит, видео уже было в архиве и реально не скачивалось. Это ПРОПУСК,
        # а не загрузка: иначе COUNT_SKIP навсегда оставался бы 0, а архивные пропуски
        # выдавались бы за успешные скачивания. return 2 — отдельный код: перевод (потребитель
        # dl_rc==0) на пропуске не запускается, потому что переводить нечего.
        if [ -n "$archive_path" ] && [ "$subs_only" != "true" ] && [ -n "${DL_MANIFEST:-}" ] && [ ! -s "$DL_MANIFEST" ]; then
            log_info "Пропущено (уже в архиве): $url"
            COUNT_SKIP=$((COUNT_SKIP + 1))
            return 2
        fi
        log_ok "Загрузка завершена: $url"
        COUNT_OK=$((COUNT_OK + 1))
        return 0
    else
        local exit_code=$?
        log_error "Ошибка загрузки (код $exit_code): $url"
        COUNT_FAIL=$((COUNT_FAIL + 1))
        return 1
    fi
}

# ── AI-перевод аудиодорожки ────────────────────────────────────────────────
translate_audio() {
    local video_file="$1"
    local url="$2"
    local target_lang="$3"
    local voice_style="$4"
    local mode="$5"
    local orig_lang="$6"
    local orig_vol="$7"
    local trans_vol="$8"
    local proxy_url="$9"

    # Громкости уезжают прямо в filter_complex. `0,3` (запятая вместо точки) —
    # обычная опечатка, и она рвала граф: пользователь видел «Ошибка мержа
    # аудиодорожек» и ничего больше, потому что stderr ffmpeg уходил в /dev/null.
    local v
    for v in "$orig_vol" "$trans_vol"; do
        if [[ ! "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
            log_error "[translation] громкость '$v' — ожидается неотрицательное число с ТОЧКОЙ (например 0.3)."
            return 1
        fi
    done

    log_info "Получение AI-перевода ($target_lang, $voice_style)..."

    local temp_dir
    temp_dir=$(mktemp -d)
    _register_tmp_path "$temp_dir"
    # vot-cli-live на Windows — native-бинарь: POSIX-путь `/tmp/tmp.X` он понимает как
    # свой и пишет в C:\Users\...\Temp\tmp.X, после чего find в $temp_dir не находит
    # ничего и перевод в Git Bash не работает вовсе. Отдаём ему windows-представление
    # того же каталога — читаем результат по-прежнему по POSIX-пути.
    local vot_out="$temp_dir"
    if command -v cygpath &>/dev/null; then
        vot_out="$(cygpath -w "$temp_dir")" || vot_out="$temp_dir"
    fi
    local -a vot_cmd=("$VOT_BIN" "--output=$vot_out" "--voice-style=$voice_style" "--reslang=$target_lang" "$url")

    # Перевод тоже должен ходить через proxy (как и сама загрузка), иначе
    # vot-cli-live стучится напрямую и падает в сетях, где доступ только через прокси.
    # NODE_TLS_REJECT_UNAUTHORIZED=0 отключает проверку сертификата для дочернего
    # vot-процесса — требование vot-cli-live. Явно предупреждаем: в враждебной сети
    # (Wi-Fi/proxy/DNS) возможен MITM аудиодорожки перевода.
    log_warn "TLS-проверка отключена для AI-перевода (vot-cli-live) — риск MITM во враждебной сети."
    local -a vot_env=("NODE_TLS_REJECT_UNAUTHORIZED=0")
    if [ -n "$proxy_url" ]; then
        vot_env+=("HTTP_PROXY=$proxy_url" "HTTPS_PROXY=$proxy_url" "ALL_PROXY=$proxy_url")
    fi

    # Потолок времени. Без него зависший vot держал прогон БЕССРОЧНО: у PS1-GUI такой
    # предел есть (_votTimeoutMs), а .sh не имел ничего — batch-прогон на сотне URL
    # вставал намертво, и отличить это от медленного перевода было нечем.
    # `timeout(1)` не используем: на macOS его нет в базовой системе. Запускаем в фоне
    # и убиваем по своему таймеру — работает и на bash 3.2.
    local vot_timeout="${TRANSLATE_TIMEOUT_SEC:-900}"
    case "$vot_timeout" in ''|*[!0-9]*) vot_timeout=900 ;; esac
    local vot_rc=0
    if [ "$vot_timeout" -gt 0 ]; then
        env "${vot_env[@]}" "${vot_cmd[@]}" &
        local vot_pid=$!
        local waited=0
        while kill -0 "$vot_pid" 2>/dev/null; do
            if [ "$waited" -ge "$vot_timeout" ]; then
                log_error "AI-перевод: превышен таймаут ${vot_timeout} с — процесс остановлен."
                kill -TERM "$vot_pid" 2>/dev/null
                sleep 2
                kill -KILL "$vot_pid" 2>/dev/null
                vot_rc=124
                break
            fi
            sleep 1
            waited=$((waited + 1))
        done
        if [ "$vot_rc" -eq 0 ]; then wait "$vot_pid"; vot_rc=$?; fi
    else
        env "${vot_env[@]}" "${vot_cmd[@]}"; vot_rc=$?
    fi
    if [ "$vot_rc" -ne 0 ]; then
        log_error "Не удалось получить перевод для: $url"
        rm -rf "$temp_dir"
        return 1
    fi

    # Найти скачанный mp3
    local translation_file
    translation_file=$(find "$temp_dir" -name "*.mp3" -type f | head -1)
    if [ -z "$translation_file" ]; then
        log_error "Файл перевода не найден в $temp_dir"
        rm -rf "$temp_dir"
        return 1
    fi

    # Сохраняем исходное расширение (.mp4/.mkv/.webm): -c:v copy VP9/AV1 в mp4 может
    # упасть, а mv ниже целит в оригинальное имя видеофайла.
    local ext="${video_file##*.}"
    local output_file="${video_file%.*}_translated.${ext}"
    # WebM-контейнер не принимает AAC → для .webm-источника кодируем перевод в libopus.
    # `tr` вместо ${ext,,}: Bash 3.2 на macOS падает на ,,-раскрытии (bad substitution).
    local a_codec="aac"
    [ "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" = "webm" ] && a_codec="libopus"

    # `-map 0:a` переносит ВСЕ оригинальные дорожки, поэтому индекс перевода равен их
    # числу, а не единице: при двух оригиналах metadata для a:1 села бы на второй
    # оригинал, а перевод (a:2) остался бы безымянным.
    # F9: индекс дорожки перевода в dual_track определяется числом оригинальных
    # аудиодорожек (ffprobe). Без рабочего ffprobe он молча стал бы 1 — на файле с
    # 2+ дорожками перевод сел бы на неверный индекс/кодек. Для dual_track ffprobe
    # обязателен: если его нет, честно завершаем перевод ошибкой, а не угадываем.
    if [ "$mode" = "dual_track" ] && ! "$FFPROBE" -version >/dev/null 2>&1; then
        log_error "Режим dual_track требует ffprobe для подсчёта аудиодорожек, но он недоступен: $FFPROBE"
        rm -rf "$temp_dir"
        return 1
    fi

    local orig_a_count
    orig_a_count=$("$FFPROBE" -v error -select_streams a -show_entries stream=index \
        -of csv=p=0 "$video_file" 2>/dev/null | grep -c .)
    [ "${orig_a_count:-0}" -ge 1 ] 2>/dev/null || orig_a_count=1

    log_info "Мерж аудиодорожек (режим: $mode)..."

    # F4: сохраняем субтитры (0:s?) и вложения/шрифты (0:t?) исходника — иначе
    # встроенные субтитры (download_with_video=embed) исчезают после мержа перевода.
    # ? делает map необязательным: если потоков нет, ffmpeg не падает.
    #
    # -nostdin обязателен во ВСЕХ трёх ветках: translate_audio вызывается из цикла
    # `while read -r media … done < <(sort -u "$dl_manifest")`, то есть stdin цикла —
    # это сам список медиафайлов. ffmpeg без -nostdin входит в transcode-режим и
    # вычитывает stdin: остаток манифеста съедался, и второй/третий файл молча
    # оставался без перевода (при обещании «перевод на КАЖДЫЙ созданный файл»).
    # stderr мержа сохраняем в файл: /dev/null оставлял пользователя без причины отказа.
    local merge_err; merge_err="$(mktemp "${TMPDIR:-/tmp}/ytdlp_merge_err_XXXXXX")"
    _register_tmp_path "$merge_err"
    # Трёхбуквенные коды и handler_name: в mp4 per-stream `title` не пишется вовсе,
    # а имя дорожки плееры (VLC, mpv) берут из handler_name. Без него обе дорожки
    # dual_track оставались безымянными в контейнере по умолчанию.
    local orig_lang3 target_lang3
    orig_lang3="$(iso639_2 "$orig_lang")"
    target_lang3="$(iso639_2 "$target_lang")"
    case "$mode" in
        dual_track)
            "$FFMPEG" -nostdin -y -i "$video_file" -i "$translation_file" \
                -map 0:v -map 0:a -map 1:a -map 0:s? -map 0:t? \
                -c:v copy -c:a copy -c:a:$orig_a_count "$a_codec" -b:a:$orig_a_count 192k -c:s copy \
                -metadata:s:a:0 language="$orig_lang3" -metadata:s:a:0 title="Original" \
                -metadata:s:a:0 handler_name="Original" \
                -metadata:s:a:$orig_a_count language="$target_lang3" \
                -metadata:s:a:$orig_a_count title="AI Translation" \
                -metadata:s:a:$orig_a_count handler_name="AI Translation" \
                -disposition:a:0 default \
                "$output_file" 2>"$merge_err"
            ;;
        replace)
            "$FFMPEG" -nostdin -y -i "$video_file" -i "$translation_file" \
                -map 0:v -map 1:a -map 0:s? -map 0:t? \
                -c:v copy -c:a "$a_codec" -b:a 192k -c:s copy \
                -metadata:s:a:0 language="$target_lang3" -metadata:s:a:0 title="AI Translation" \
                -metadata:s:a:0 handler_name="AI Translation" \
                "$output_file" 2>"$merge_err"
            ;;
        mix)
            "$FFMPEG" -nostdin -y -i "$video_file" -i "$translation_file" \
                -filter_complex "[0:a]volume=${orig_vol}[a0];[1:a]volume=${trans_vol}[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[aout]" \
                -map 0:v -map "[aout]" -map 0:s? -map 0:t? \
                -c:v copy -c:a "$a_codec" -b:a 192k -c:s copy \
                "$output_file" 2>"$merge_err"
            ;;
    esac
    local ff_rc=$?

    local ret=1
    if [ "$ff_rc" -eq 0 ] && [ -f "$output_file" ]; then
        # F4: rename не считаем успехом вслепую — проверяем exit code mv. При отказе
        # (заблокированный файл, нет прав на каталог) оригинал остаётся нетронутым, а
        # перевод не выдаётся за успешный.
        if mv "$output_file" "$video_file"; then
            log_ok "Перевод добавлен: $video_file"
            ret=0
        else
            log_error "Не удалось заменить оригинал переведённым файлом: $video_file"
            [ -f "$output_file" ] && rm -f "$output_file"
        fi
    else
        log_error "Ошибка мержа аудиодорожек (ffmpeg код $ff_rc)"
        # Последние строки stderr ffmpeg: без них сообщение не даёт НИ ОДНОЙ зацепки,
        # а причина почти всегда конкретна (несовместимый кодек, битый filter_complex).
        if [ -s "$merge_err" ]; then
            log_error "ffmpeg: $(tail -3 "$merge_err" | tr '\n' ' ')"
        fi
        [ -f "$output_file" ] && rm -f "$output_file"
    fi
    rm -f "$merge_err"

    rm -rf "$temp_dir"
    return $ret
}

# ── Batch-загрузка из channels.txt ─────────────────────────────────────────
download_batch() {
    local subs_only="$1"

    if [ ! -f "$CHANNELS_FILE" ]; then
        log_error "Файл каналов не найден: $CHANNELS_FILE"
        exit 1
    fi

    local total=0
    # Разбор строки channels.txt. Четыре прежние ловушки, все молчаливые:
    #   • комментарий с отступом («  # tech|x|videos») не отбрасывался — «# tech»
    #     становилось категорией, а yt-dlp получал несуществующий канал;
    #   • хвостовой комментарий («tech|x|videos  # заметка») уезжал в mode;
    #   • лишнее поле («a|b|c|d») попадало в mode вместе с разделителем;
    #   • handle с ведущим '@' давал '@@handle' в URL — канал не находился.
    # Trim делаем parameter expansion'ом: sed-fork на строку в Git Bash дорог.
    local raw_line
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        raw_line="${raw_line%$'\r'}"
        raw_line="${raw_line#"${raw_line%%[![:space:]]*}"}"
        raw_line="${raw_line%"${raw_line##*[![:space:]]}"}"
        [[ -z "$raw_line" || "$raw_line" == \#* ]] && continue
        # Хвостовой комментарий — только после пробела, как в config.ini.
        if [[ "$raw_line" == *' #'* ]]; then
            raw_line="${raw_line%% #*}"
            raw_line="${raw_line%"${raw_line##*[![:space:]]}"}"
        fi
        local category handle mode _extra
        IFS='|' read -r category handle mode _extra <<< "$raw_line"
        category="${category#"${category%%[![:space:]]*}"}"; category="${category%"${category##*[![:space:]]}"}"
        handle="${handle#"${handle%%[![:space:]]*}"}";       handle="${handle%"${handle##*[![:space:]]}"}"
        mode="${mode#"${mode%%[![:space:]]*}"}";             mode="${mode%"${mode##*[![:space:]]}"}"
        if [ -n "${_extra:-}" ]; then
            log_warn "channels.txt: в строке «${raw_line}» больше трёх полей — лишнее проигнорировано."
        fi
        [[ -z "$handle" ]] && continue
        # '@' добавляем сами ниже — ведущий в значении дал бы '@@handle'.
        handle="${handle#@}"
        [ -z "$mode" ] && mode="videos"

        total=$((total + 1))
        log_header "[$total] ${category}/${handle} (${mode})"

        local template
        if [ "$mode" = "playlists" ]; then
            template="${BASE_DIR}/${category}/$(limit_output_template "${BASE_DIR}/${category}" "$PLAYLIST_TEMPLATE")"
        else
            template="${BASE_DIR}/${category}/$(limit_output_template "${BASE_DIR}/${category}" "$OUTPUT_TEMPLATE")"
        fi

        local _err_flag="-i"; [ "${CONTINUE_ON_ERROR:-true}" = "false" ] && _err_flag="--abort-on-error"
        build_net_args
        local -a cmd=("$YTDLP" -c "$_err_flag" -w --windows-filenames --compat-options filename-sanitization
                  "${NET_ARGS_ARR[@]}")
        build_js_runtime_args
        [ ${#JS_RUNTIME_ARGS_ARR[@]} -gt 0 ] && cmd+=("${JS_RUNTIME_ARGS_ARR[@]}")

        local -a env_prefix=()
        if [ -n "${PROXY_URL:-}" ]; then
            env_prefix=(env "HTTP_PROXY=$PROXY_URL" "HTTPS_PROXY=$PROXY_URL" "ALL_PROXY=$PROXY_URL")
        fi

        [ "${#COOKIE_ARGS_ARR[@]}" -gt 0 ] && cmd+=("${COOKIE_ARGS_ARR[@]}")
        # F3: архив не для «только субтитры» (хранит ID видео, а не наличие субтитров).
        [ "$USE_ARCHIVE" = "true" ] && [ "$subs_only" != "true" ] && cmd+=(--download-archive "$ARCHIVE_FILE")
        cmd+=(-o "$template")

        # Паритет с download_url: batch-ветка тоже получает манифест. Без него
        # COUNT_SKIP в batch навсегда оставался 0, и канал, где все видео уже в
        # архиве, засчитывался как успешно скачанный — сводка врала. Манифест
        # per-канал (не per-запуск): пустой после успешного прохода = новых видео
        # не было. Перевод в batch отключён guardrail'ом, поэтому единственный
        # потребитель здесь — учёт пропусков.
        local ch_manifest=""
        if [ "$USE_ARCHIVE" = "true" ] && [ "$subs_only" != "true" ]; then
            ch_manifest=$(mktemp 2>/dev/null) || ch_manifest="/tmp/ytdlp_batch_manifest_$$"
            _register_tmp_path "$ch_manifest"
            : > "$ch_manifest"
            cmd+=(--print-to-file "after_move:filepath" "$ch_manifest")
        fi

        # Дата
        local date_range
        date_range=$(read_config "date_range" "batch" "now-6months")
        cmd+=(--dateafter "$date_range")

        # Задержки
        local sleep_req sleep_int max_sleep_int sleep_sub
        sleep_req=$(read_config "sleep_requests" "batch" "1.8")
        sleep_int=$(read_config "sleep_interval" "batch" "8")
        max_sleep_int=$(read_config "max_sleep_interval" "batch" "22")
        sleep_sub=$(read_config "sleep_subtitles" "batch" "4")
        cmd+=(--sleep-requests "$sleep_req")
        cmd+=(--sleep-interval "$sleep_int")
        cmd+=(--max-sleep-interval "$max_sleep_int")
        cmd+=(--sleep-subtitles "$sleep_sub")

        if [ "$subs_only" = "true" ]; then
            # F31. Ручные субтитры не теряем: --write-subs запрашивает авторские, --write-auto-subs
        # оставляет автоматические как fallback. Раньше слался только auto-флаг, хотя ни UI,
        # ни документация не обещают «только автоматические» — авторские (обычно точнее)
        # молча пропадали. Режим «субтитры вместе с видео» уже делал ровно так.
        # --sub-langs/--sub-format — актуальные имена (--sub-lang — legacy-алиас).
        cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG" --sub-format "$SUB_FORMAT" --skip-download)
        else
            build_format_args "$QUALITY" "$FORMAT_PRESET" "youtube"
            cmd+=("${FMT_ARGS_ARR[@]}")

            # Метаданные и главы источника (архивная ценность; для видео без глав — no-op).
            cmd+=(--embed-metadata --embed-chapters)

            # Перекодирование в аудиоформат (только при quality=audio и заданном формате)
            if [ "$QUALITY" = "audio" ]; then
                cmd+=(--extract-audio --audio-quality 0)
                case "$AUDIO_FORMAT" in
                    mp3|m4a|opus|flac|wav) cmd+=(--audio-format "$AUDIO_FORMAT") ;;
                esac
            fi

            # SponsorBlock (только для реальных загрузок)
            case "$SPONSORBLOCK" in
                remove) cmd+=(--sponsorblock-remove all) ;;
                mark)   cmd+=(--sponsorblock-mark all) ;;
            esac

            # Субтитры вместе с видео (sidecar/embed; opt-in, по умолчанию off)
            case "$SUBS_WITH_VIDEO" in
                sidecar) cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG") ;;
                embed)   cmd+=(--write-subs --write-auto-subs --sub-langs "$SUB_LANG" --embed-subs) ;;
            esac
        fi

        if [ "$mode" = "playlists" ]; then
            cmd+=(--yes-playlist)
        else
            # --lazy-playlist + --break-on-reject вместо --playlist-reverse.
            #
            # Прежняя пара «идти с конца + --dateafter» заставляла yt-dlp получить
            # метаданные КАЖДОГО ролика канала (× --sleep-requests 1.8 с) и только
            # потом отбросить старые: на канале в тысячу видео это часы на каждый
            # прогон, причём почти целиком впустую. Ленивый режим отдаёт элементы по
            # мере получения, а --break-on-reject останавливает обход на ПЕРВОМ
            # ролике старше date_range — новые идут первыми, и дальше границы
            # yt-dlp просто не идёт.
            #
            # Цена — порядок загрузки «новые первыми» вместо «старые первыми».
            # Для инкрементального добора канала это и есть желаемый порядок.
            cmd+=(--lazy-playlist --break-on-reject)
        fi

        local url="https://www.youtube.com/@${handle}/${mode}"
        # F30. '--' закрывает список опций (паритет с download_url выше).
        cmd+=(--)
        cmd+=("$url")

        if [ "$DRY_RUN" = "true" ]; then
            local proxy_note=""
            [ -n "${PROXY_URL:-}" ] && proxy_note="env HTTP_PROXY/HTTPS_PROXY/ALL_PROXY=$(mask_proxy "$PROXY_URL") "
            echo "[DRY-RUN] ${proxy_note}${cmd[*]}"
            [ -n "$ch_manifest" ] && rm -f "$ch_manifest"
            continue
        fi

        log_info "Команда: ${cmd[*]}"

        if "${env_prefix[@]+"${env_prefix[@]}"}" "${cmd[@]}"; then
            # Контракт тот же, что в download_url: архив включён, yt-dlp отработал
            # успешно, но не переместил ни одного файла → все видео канала уже были
            # в архиве. Это ПРОПУСК, а не загрузка.
            if [ -n "$ch_manifest" ] && [ ! -s "$ch_manifest" ]; then
                log_info "Пропущено (нет новых видео): $handle"
                COUNT_SKIP=$((COUNT_SKIP + 1))
            else
                log_ok "Канал $handle завершён"
                COUNT_OK=$((COUNT_OK + 1))
            fi
        else
            log_error "Ошибка при загрузке канала $handle"
            COUNT_FAIL=$((COUNT_FAIL + 1))
        fi
        [ -n "$ch_manifest" ] && rm -f "$ch_manifest"
    done < "$CHANNELS_FILE"
}

# ── Итоговая сводка ───────────────────────────────────────────────────────
print_summary() {
    local end_time
    end_time=$(date +%s)
    local elapsed=$((end_time - START_TIME))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))

    echo ""
    echo -e "${BOLD}╔══════════════════════════════╗${NC}"
    echo -e "${BOLD}║         ИТОГО                ║${NC}"
    echo -e "${BOLD}╠══════════════════════════════╣${NC}"
    [ $COUNT_OK -gt 0 ]   && echo -e "${BOLD}║${NC}  ${GREEN}Успешно:${NC}    $COUNT_OK"
    [ $COUNT_SKIP -gt 0 ] && echo -e "${BOLD}║${NC}  ${YELLOW}Пропущено:${NC}  $COUNT_SKIP"
    [ $COUNT_FAIL -gt 0 ] && echo -e "${BOLD}║${NC}  ${RED}Ошибки:${NC}     $COUNT_FAIL"
    echo -e "${BOLD}║${NC}  Время:      ${minutes} мин ${seconds} сек"
    echo -e "${BOLD}╚══════════════════════════════╝${NC}"
}

# ── Справка ────────────────────────────────────────────────────────────────
show_help() {
    cat << 'EOF'
Использование: download.sh [ОПЦИИ] [URL]

РЕЖИМЫ:
  URL                          Скачать одно видео или плейлист
  --batch                      Скачать все каналы из channels.txt
  --subs                       Только субтитры (работает с URL и --batch)

КАЧЕСТВО:
  --quality NUM                360, 480, 720 (по умолчанию), 1080, 1440, 2160, audio
  --format PRESET              auto (по умолчанию; для YouTube = avc1_best,
                               для VK/RuTube/др. = простой best[height<=N]),
                               avc1_best, avc1_https, avc1_m3u8,
                               avc1_https_60fps, avc1_m3u8_60fps,
                               avc1_https_60fps_hdr, old_combo

COOKIES:
  --cookies browser            Извлечь cookies из браузера (Chrome по умолчанию)
  --cookies file               Использовать cookies из файла
  --cookies none               Без cookies (по умолчанию)
  --cookie-browser NAME        Браузер: chrome, firefox, edge
  --cookie-file PATH           Путь к файлу cookies

ПРОКСИ:
  --speed-profile P            Профиль сети: careful|normal|fast (по умолч. normal)
  --limit-rate RATE            Потолок скорости, напр. 2M, 500K (пусто = без лимита)
  --proxy URL                  HTTP/HTTPS прокси

ПЕРЕВОД (требует vot-cli-live, ffmpeg, Node.js 18+):
  --translate LANG             Добавить AI-перевод аудио (ru, en, kk)
  --voice STYLE                Голос: live (по умолчанию) / tts
  --mix                        Смешать оригинал + перевод
  --replace                    Заменить оригинал переводом
  (по умолчанию — mix: смешать оригинал + перевод)

ФРАГМЕНТ (только для одиночных URL):
  --trim-start TIME            Начало фрагмента (ЧЧ:ММ:СС, М:СС или секунды).
  --trim-end TIME              Конец фрагмента. Комбинации:
                                 только --trim-start  = с TIME до конца ролика
                                 только --trim-end    = с начала до TIME
                                 оба                  = фрагмент TIME1..TIME2
  --force-keyframes            Точная обрезка по границам (требует перекодирования концов).

ПРОЧЕЕ:
  --no-playlist                Скачать только указанное видео (игнорировать &list=)
  --yes-playlist               Всегда скачивать весь плейлист
  --doctor                     Отчёт об окружении: какие инструменты найдены,
                               где и что без каждого из них не работает
  --dry-run                    Показать итоговую команду yt-dlp без запуска
  --config PATH                Путь к config.ini
  --help                       Показать эту справку
EOF
}

# ── Загрузка конфигурации ──────────────────────────────────────────────────
load_config() {
    PROXY_URL=$(read_config "url" "proxy" "")
    COOKIE_METHOD=$(read_config "method" "cookies" "none")
    COOKIE_FILE_PATH=$(read_config "file" "cookies" "youtube_cookies.txt")
    COOKIE_BROWSER=$(read_config "browser" "cookies" "chrome")
    BASE_DIR=$(read_config "base_dir" "output" "_video_")
    OUTPUT_TEMPLATE=$(read_config "template" "output" '%(uploader)s/%(upload_date)s - %(title).100U.%(ext)s')
    PLAYLIST_TEMPLATE=$(read_config "playlist_template" "output" '%(uploader)s/%(playlist)s/%(playlist_index)03d - %(title).100U.%(ext)s')
    QUALITY=$(read_config "default_quality" "download" "720")
    FORMAT_PRESET=$(read_config "format_preset" "download" "auto")
    CONTINUE_ON_ERROR=$(read_config "continue_on_error" "download" "true")
    USE_ARCHIVE=$(read_config "use_archive" "download" "true")
    ARCHIVE_FILE=$(read_config "archive_file" "download" "download_archive.txt")
    AUDIO_FORMAT=$(read_config "audio_format" "download" "best")
    SPONSORBLOCK=$(read_config "sponsorblock" "download" "off")
    # Что делать со ссылкой, у которой есть &list=…:
    #   auto   — как раньше: ссылка с list= считается плейлистом (yt-dlp по умолчанию);
    #   single — скачать ТОЛЬКО указанное видео (--no-playlist);
    #   full   — всегда весь плейлист (--yes-playlist).
    # Практический повод для single: у ссылок вида watch?v=X&list=RD… (авто-микс
    # YouTube) плейлист бесконечный, и «скачать это видео» превращалось в закачку
    # микса целиком — по playlist-шаблону, то есть ещё и не туда, куда ожидалось.
    PLAYLIST_MODE=$(read_config "playlist" "download" "auto")

    # Нормализация: булевы ключи принимают yes/no/on/off/1/0, перечислимые —
    # проверяются теми же списками, что и одноимённые флаги CLI.
    CONTINUE_ON_ERROR=$(to_bool "$CONTINUE_ON_ERROR" "true"  "[download] continue_on_error")
    USE_ARCHIVE=$(to_bool      "$USE_ARCHIVE"        "true"  "[download] use_archive")
    QUALITY=$(config_enum "[download] default_quality" "$QUALITY" "720" \
        audio 360 480 720 1080 1440 2160)
    FORMAT_PRESET=$(config_enum "[download] format_preset" "$FORMAT_PRESET" "auto" \
        auto avc1_best avc1_https avc1_m3u8 avc1_https_60fps avc1_m3u8_60fps avc1_https_60fps_hdr old_combo)
    AUDIO_FORMAT=$(config_enum "[download] audio_format" "$AUDIO_FORMAT" "best" \
        best mp3 m4a opus flac wav)
    SPONSORBLOCK=$(config_enum "[download] sponsorblock" "$SPONSORBLOCK" "off" \
        off mark remove)

    # Trim: парсим +/-VALUE из [trim]
    local raw
    raw=$(read_config "start" "trim" "-00:00:00")
    TRIM_START_RAW="$raw"
    if [[ "$raw" == +* ]]; then TRIM_START_ON="true"; TRIM_START_VAL="${raw:1}"
    elif [[ "$raw" == -* ]]; then TRIM_START_ON="false"; TRIM_START_VAL="${raw:1}"
    else TRIM_START_ON="false"; TRIM_START_VAL="$raw"; fi
    raw=$(read_config "end" "trim" "-00:01:00")
    TRIM_END_RAW="$raw"
    if [[ "$raw" == +* ]]; then TRIM_END_ON="true"; TRIM_END_VAL="${raw:1}"
    elif [[ "$raw" == -* ]]; then TRIM_END_ON="false"; TRIM_END_VAL="${raw:1}"
    else TRIM_END_ON="false"; TRIM_END_VAL="$raw"; fi
    FORCE_KEYFRAMES=$(to_bool "$(read_config "force_keyframes" "trim" "false")" "false" "[trim] force_keyframes")
    # Сеть: профиль устойчивости + необязательный потолок скорости.
    # Дефолт normal воспроизводит прежние зашитые значения дословно.
    SPEED_PROFILE=$(read_config "speed_profile" "network" "normal")
    LIMIT_RATE=$(read_config "limit_rate" "network" "")

    SUB_LANG=$(read_config "lang" "subtitles" "ru")
    SUB_FORMAT=$(read_config "format" "subtitles" "vtt")
    SUBS_WITH_VIDEO=$(read_config "download_with_video" "subtitles" "off")
    SUBS_WITH_VIDEO=$(config_enum "[subtitles] download_with_video" "$SUBS_WITH_VIDEO" "off" \
        off sidecar embed)
    PLAYLIST_MODE=$(config_enum "[download] playlist" "$PLAYLIST_MODE" "auto" auto single full)
    # CLI перекрывает config.ini — как и все прочие флаги.
    [ -n "${PLAYLIST_MODE_CLI:-}" ] && PLAYLIST_MODE="$PLAYLIST_MODE_CLI"

    # Перевод
    TRANSLATE_ENABLED=$(to_bool "$(read_config "enabled" "translation" "false")" "false" "[translation] enabled")
    TRANSLATE_LANG=$(read_config "target_lang" "translation" "ru")
    TRANSLATE_VOICE=$(read_config "voice_style" "translation" "live")
    TRANSLATE_MODE=$(config_enum "[translation] mode" "$(read_config "mode" "translation" "mix")" "mix" \
        dual_track mix replace)
    TRANSLATE_ORIG_VOL=$(read_config "original_volume" "translation" "0.3")
    TRANSLATE_TRANS_VOL=$(read_config "translation_volume" "translation" "1.0")
    TRANSLATE_ORIG_LANG=$(read_config "original_lang" "translation" "en")
    # Потолок времени на один вызов vot-cli-live. 0 = без ограничения.
    TRANSLATE_TIMEOUT_SEC=$(read_config "timeout_sec" "translation" "900")
    case "$TRANSLATE_TIMEOUT_SEC" in
        ''|*[!0-9]*)
            log_warn "[translation] timeout_sec = '$TRANSLATE_TIMEOUT_SEC' — ожидается целое число секунд, использую 900."
            TRANSLATE_TIMEOUT_SEC=900 ;;
    esac

    # Относительные пути резолвятся от каталога скрипта; drive/UNC — уже абсолютные.
    COOKIE_FILE_PATH="$(expand_tilde "$COOKIE_FILE_PATH")"
    BASE_DIR="$(expand_tilde "$BASE_DIR")"
    ARCHIVE_FILE="$(expand_tilde "$ARCHIVE_FILE")"
    is_abs_path "$COOKIE_FILE_PATH" || COOKIE_FILE_PATH="${SCRIPT_DIR}/${COOKIE_FILE_PATH}"
    is_abs_path "$BASE_DIR"         || BASE_DIR="${SCRIPT_DIR}/${BASE_DIR}"
    # archive_file тоже путь, и абсолютный он или нет — решает та же функция.
    # Раньше он безусловно склеивался с BASE_DIR ниже, и `archive_file = D:\arch.txt`
    # превращался в `<BASE_DIR>/D:\arch.txt` — архив писался не туда, где его ищут.
    is_abs_path "$ARCHIVE_FILE" || ARCHIVE_FILE="${BASE_DIR}/${ARCHIVE_FILE}"

    # `[trim] start = 00:10` без знака — обычная ошибка: формат «+значение / -значение»
    # неочевиден, а молчаливое «выключено» неотличимо от «обрезка не сработала».
    if [ -n "${TRIM_START_RAW:-}" ] && [ "$TRIM_START_ON" = "false" ] \
       && [ "${TRIM_START_RAW:0:1}" != "-" ] && [ "${TRIM_START_RAW:0:1}" != "+" ]; then
        log_warn "[trim] start = '$TRIM_START_RAW' без знака — обрезка ВЫКЛЮЧЕНА. Включает только '+' в начале значения."
    fi
    if [ -n "${TRIM_END_RAW:-}" ] && [ "$TRIM_END_ON" = "false" ] \
       && [ "${TRIM_END_RAW:0:1}" != "-" ] && [ "${TRIM_END_RAW:0:1}" != "+" ]; then
        log_warn "[trim] end = '$TRIM_END_RAW' без знака — обрезка ВЫКЛЮЧЕНА. Включает только '+' в начале значения."
    fi

    # Значения [trim] из config.ini проходят ту же проверку, что и --trim-start/--trim-end.
    # Без неё битое значение уходило прямо в --download-sections, и пользователь видел
    # сырую ошибку yt-dlp вместо внятного сообщения о формате.
    [ "$TRIM_START_ON" = "true" ] && validate_time "[trim] start" "$TRIM_START_VAL"
    [ "$TRIM_END_ON"   = "true" ] && validate_time "[trim] end"   "$TRIM_END_VAL"
    return 0
}

# ── Валидация значений опций ───────────────────────────────────────────────
# Без этого `--quality --dry-run URL` съедал safety-флаг и начинал РЕАЛЬНУЮ загрузку,
# а `--quality` последним аргументом ронял скрипт raw-ошибкой set -u.
require_value() {
    local opt="$1" argc="$2" val="${3:-}"
    if [ "$argc" -lt 2 ]; then
        log_error "Опция $opt требует значения"
        exit 1
    fi
    case "$val" in
        -*) log_error "Опция $opt требует значения, а получен флаг: $val"; exit 1 ;;
    esac
}

validate_enum() {
    local opt="$1" val="$2"; shift 2
    local allowed
    for allowed in "$@"; do
        [ "$val" = "$allowed" ] && return 0
    done
    log_error "Недопустимое значение $opt: '$val'. Допустимо: $*"
    exit 1
}

# ЧЧ:ММ:СС, М:СС или секунды (в т.ч. дробные) — тот же контракт, что в справке.
validate_time() {
    local opt="$1" val="$2"
    case "$val" in
        ""|*[!0-9:.]*) log_error "Опция $opt: ожидается ЧЧ:ММ:СС, М:СС или секунды, получено: '$val'"; exit 1 ;;
    esac
}

# ── Парсинг аргументов ─────────────────────────────────────────────────────
parse_args() {
    BATCH_MODE=false
    SUBS_ONLY=false
    DRY_RUN=false
    TRANSLATE_CLI=""
    TRANSLATE_MODE_CLI=""
    TRANSLATE_VOICE_CLI=""
    SPEED_PROFILE_CLI=""
    LIMIT_RATE_CLI=""
    URL=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --config)
                require_value "$1" "$#" "${2:-}"
                CONFIG_FILE="$2"; shift 2
                ;;
            --batch)
                BATCH_MODE=true; shift
                ;;
            --subs)
                SUBS_ONLY=true; shift
                ;;
            --quality)
                require_value "$1" "$#" "${2:-}"
                validate_enum "$1" "$2" 360 480 720 1080 1440 2160 audio
                QUALITY="$2"; shift 2
                ;;
            --format)
                require_value "$1" "$#" "${2:-}"
                validate_enum "$1" "$2" auto avc1_best avc1_https avc1_m3u8 \
                    avc1_https_60fps avc1_m3u8_60fps avc1_https_60fps_hdr old_combo
                FORMAT_PRESET="$2"; shift 2
                ;;
            --proxy)
                require_value "$1" "$#" "${2:-}"
                PROXY_URL="$2"; shift 2
                ;;
            --cookies)
                require_value "$1" "$#" "${2:-}"
                validate_enum "$1" "$2" browser file none
                COOKIE_METHOD="$2"; shift 2
                ;;
            --cookie-browser)
                require_value "$1" "$#" "${2:-}"
                COOKIE_BROWSER="$2"; shift 2
                ;;
            --cookie-file)
                require_value "$1" "$#" "${2:-}"
                COOKIE_FILE_PATH="$2"; shift 2
                ;;
            --translate)
                require_value "$1" "$#" "${2:-}"
                TRANSLATE_CLI="$2"; shift 2
                ;;
            --voice)
                require_value "$1" "$#" "${2:-}"
                validate_enum "$1" "$2" live tts
                TRANSLATE_VOICE_CLI="$2"; shift 2
                ;;
            --speed-profile)
                require_value "$1" "$#" "${2:-}"
                validate_enum "$1" "$2" careful normal fast
                SPEED_PROFILE_CLI="$2"; shift 2
                ;;
            --limit-rate)
                require_value "$1" "$#" "${2:-}"
                LIMIT_RATE_CLI="$2"; shift 2
                ;;
            --mix)
                TRANSLATE_MODE_CLI="mix"; shift
                ;;
            --replace)
                TRANSLATE_MODE_CLI="replace"; shift
                ;;
            --dual-track)
                TRANSLATE_MODE_CLI="dual_track"; shift
                ;;
            --trim-start)
                require_value "$1" "$#" "${2:-}"
                validate_time "$1" "$2"
                TRIM_START_ON="true"; TRIM_START_VAL="$2"; shift 2
                ;;
            --trim-end)
                require_value "$1" "$#" "${2:-}"
                validate_time "$1" "$2"
                TRIM_END_ON="true"; TRIM_END_VAL="$2"; shift 2
                ;;
            --force-keyframes)
                FORCE_KEYFRAMES="true"; shift
                ;;
            --no-playlist)
                PLAYLIST_MODE_CLI="single"; shift
                ;;
            --yes-playlist)
                PLAYLIST_MODE_CLI="full"; shift
                ;;
            --doctor)
                DOCTOR_MODE=true; shift
                ;;
            --dry-run)
                DRY_RUN=true; shift
                ;;
            -*)
                log_error "Неизвестный флаг: $1"
                show_help
                exit 1
                ;;
            *)
                # Второй позиционный аргумент раньше просто ЗАТИРАЛ первый: команда
                # `script URL1 URL2` качала только URL2 и отчитывалась «Успешно: 1»
                # с кодом 0 — пользователь узнавал о потере, только не найдя файл.
                if [ -n "${URL:-}" ]; then
                    log_error "Указано несколько URL ('$URL' и '$1'). За один запуск обрабатывается один URL; для списка используйте --batch."
                    exit 1
                fi
                URL="$1"; shift
                ;;
        esac
    done

    # Применить CLI-параметры перевода
    if [ -n "$TRANSLATE_CLI" ]; then
        TRANSLATE_ENABLED="true"
        TRANSLATE_LANG="$TRANSLATE_CLI"
    fi
    [ -n "$TRANSLATE_MODE_CLI" ] && TRANSLATE_MODE="$TRANSLATE_MODE_CLI"
    [ -n "$TRANSLATE_VOICE_CLI" ] && TRANSLATE_VOICE="$TRANSLATE_VOICE_CLI"
    [ -n "$SPEED_PROFILE_CLI" ] && SPEED_PROFILE="$SPEED_PROFILE_CLI"
    [ -n "$LIMIT_RATE_CLI" ] && LIMIT_RATE="$LIMIT_RATE_CLI"

    # Сформировать cookie args (заполняет global COOKIE_ARGS_ARR)
    build_cookie_args "$COOKIE_METHOD" "$COOKIE_FILE_PATH" "$COOKIE_BROWSER"
}

# Собирает сетевые флаги yt-dlp по профилю SPEED_PROFILE в массив NET_ARGS_ARR.
#
# Раньше значения были зашиты литералами прямо в двух местах (download_url и
# download_batch). Их нельзя было подстроить под медленный/нестабильный канал,
# и две копии могли разойтись при правке. Профиль задаётся одним ключом:
#   careful — щадящий: 1 фрагмент за раз, больше попыток, длинный таймаут
#   normal  — прежнее поведение ДОСЛОВНО (дефолт, ничего не меняется)
#   fast    — агрессивный: 8 фрагментов, меньше попыток, короткий таймаут
# LIMIT_RATE ортогонален профилю: пустой = без ограничения.
build_net_args() {
    NET_ARGS_ARR=()
    local frags retries sock sleep_s
    case "${SPEED_PROFILE:-normal}" in
        careful) frags=1; retries=20; sock=60; sleep_s=5 ;;
        fast)    frags=8; retries=5;  sock=15; sleep_s=0 ;;
        normal)  frags=4; retries=10; sock=30; sleep_s=0 ;;
        *)
            echo "WARN: неизвестный speed_profile '${SPEED_PROFILE}', используется normal" >&2
            frags=4; retries=10; sock=30; sleep_s=0
            ;;
    esac
    NET_ARGS_ARR=(--retries "$retries" --fragment-retries "$retries"
                  --file-access-retries 5 --socket-timeout "$sock"
                  --concurrent-fragments "$frags")
    # Именно if, а не `[ ... ] && ...`: у идиомы со списком статус последней строки
    # становится статусом функции, и при пустом LIMIT_RATE (обычный случай)
    # build_net_args возвращала бы 1 — под `set -e` это уронило бы запуск.
    if [ "$sleep_s" -gt 0 ]; then
        NET_ARGS_ARR+=(--retry-sleep "$sleep_s")
    fi
    if [ -n "${LIMIT_RATE:-}" ]; then
        NET_ARGS_ARR+=(--limit-rate "$LIMIT_RATE")
    fi
    return 0
}

# Маскирует credentials в proxy URL для вывода в лог:
# scheme://user:pass@host:port -> scheme://***@host:port
# Маскирует пароль в URL прокси. Две дыры прежнего шаблона, обе печатали пароль
# открытым текстом в заголовок прогона и в строку [DRY-RUN]:
#   1) схема была ОБЯЗАТЕЛЬНОЙ, а config.ini.example объявляет её необязательной —
#      адрес без схемы не совпадал вовсе и уходил в лог как есть;
#   2) класс `[^@/]+` не пропускает '@', поэтому пароль, в котором сам есть '@',
#      обрезался по ПЕРВОМУ '@': маска накрывала только начало, а хвост пароля
#      вместе с хостом оставался в выводе открытым текстом.
# Примеров с '@' здесь намеренно нет: барьер приватности видит в такой строке
# форму «логин:пароль@хост» и блокирует коммит — см. .githooks/pre-commit.
# Теперь схема необязательна, а user:pass берётся жадно до ПОСЛЕДНЕГО '@' перед
# путём — ровно так же, как это делает разбор authority в RFC 3986.
mask_proxy() {
    local p="$1"
    [ -z "$p" ] && { echo "нет"; return; }
    echo "$p" | sed -E 's#^(([A-Za-z][A-Za-z0-9+.-]*://)?)[^/]*@#\1***@#'
}

# ── MAIN ───────────────────────────────────────────────────────────────────
main() {
    # Путь конфига должен быть известен ДО load_config, иначе настройки читаются
    # из дефолтного config.ini и CLI-флаг --config фактически игнорируется.
    local _args=("$@") _i
    for ((_i = 0; _i < ${#_args[@]}; _i++)); do
        if [ "${_args[$_i]}" = "--config" ] && [ $((_i + 1)) -lt ${#_args[@]} ]; then
            CONFIG_FILE="${_args[$((_i + 1))]}"
            break
        fi
    done

    load_config
    parse_args "$@"

    # --doctor печатает отчёт и выходит: он про окружение, а не про загрузку.
    if [ "${DOCTOR_MODE:-false}" = "true" ]; then
        run_doctor
        return $?
    fi

    check_base_deps

    # F1/F2: перевод несовместим с рядом режимов — отключаем ДО загрузки с ЯВНЫМ
    # сообщением, а не выполняем молча/неверно. vot переводит по URL, поэтому:
    #  batch/playlist — нет URL на каждое видео; audio — нет видеофайла для мержа;
    #  trim/SponsorBlock remove — дорожка перевода полного ролика рассинхронизируется.
    if [ "$TRANSLATE_ENABLED" = "true" ]; then
        if [ "$BATCH_MODE" = "true" ]; then
            log_warn "AI-перевод не применяется в режиме --batch (нужен отдельный URL на видео) — перевод отключён."
            TRANSLATE_ENABLED="false"
        elif [ "$SUBS_ONLY" = "true" ]; then
            log_warn "AI-перевод неприменим к режиму «только субтитры» — перевод отключён."
            TRANSLATE_ENABLED="false"
        elif [ "$QUALITY" = "audio" ]; then
            log_warn "AI-перевод не поддерживается для загрузки только аудио (quality=audio) — перевод отключён."
            TRANSLATE_ENABLED="false"
        elif echo "$URL" | grep -qi '[?&]list='; then
            log_warn "AI-перевод недоступен для плейлистов (vot переводит по одному URL) — скачивайте видео по одному. Перевод отключён."
            TRANSLATE_ENABLED="false"
        elif [ "$TRIM_START_ON" = "true" ] || [ "$TRIM_END_ON" = "true" ] || [ "$SPONSORBLOCK" = "remove" ]; then
            log_warn "AI-перевод несовместим с обрезкой (--trim-*) и SponsorBlock remove: дорожка перевода полного ролика рассинхронизируется с обрезанным видео. Перевод отключён."
            TRANSLATE_ENABLED="false"
        fi
    fi

    if [ "$TRANSLATE_ENABLED" = "true" ]; then
        check_translate_deps || exit 1
    fi

    log_header "YouTube Downloader"
    log_info "Качество: $QUALITY | Формат: $FORMAT_PRESET | Cookies: $COOKIE_METHOD | Прокси: $(mask_proxy "$PROXY_URL")"
    [ "$TRANSLATE_ENABLED" = "true" ] && log_info "Перевод: $TRANSLATE_LANG ($TRANSLATE_VOICE, $TRANSLATE_MODE)"

    if [ "$BATCH_MODE" = "true" ]; then
        download_batch "$SUBS_ONLY"
    elif [ -n "$URL" ]; then
        # Определить шаблон
        # Шаблон обязан соответствовать РЕЖИМУ, а не только виду ссылки: при
        # playlist = single качается одно видео, и playlist-шаблон разложил бы его
        # по несуществующей структуре плейлиста.
        local template
        if [ "${PLAYLIST_MODE:-auto}" != "single" ] && echo "$URL" | grep -qi '[?&]list='; then
            template="${BASE_DIR}/$(limit_output_template "$BASE_DIR" "$PLAYLIST_TEMPLATE")"
        else
            template="${BASE_DIR}/$(limit_output_template "$BASE_DIR" "$OUTPUT_TEMPLATE")"
        fi

        local archive_path=""
        if [ "$USE_ARCHIVE" = "true" ]; then
            archive_path="$ARCHIVE_FILE"
        fi

        # F13. Манифест точных путей от самого yt-dlp (--print-to-file after_move:filepath).
        # Потребители — перевод (нужны пути готовых файлов) и учёт archive-skip (пустой
        # manifest при включённом архиве = видео уже скачано). Per-process файл, поэтому
        # параллельный запуск не может подсунуть сюда свой результат.
        local dl_manifest=""
        if [ "$SUBS_ONLY" != "true" ] && { [ "$TRANSLATE_ENABLED" = "true" ] || [ "$USE_ARCHIVE" = "true" ]; }; then
            dl_manifest=$(mktemp 2>/dev/null) || dl_manifest="/tmp/ytdlp_manifest_$$"
            _register_tmp_path "$dl_manifest"
            : > "$dl_manifest"
        fi

        DL_MANIFEST="$dl_manifest" download_url "$URL" "$template" "$QUALITY" "$SUBS_ONLY" "$archive_path" \
            "$TRIM_START_ON" "$TRIM_START_VAL" "$TRIM_END_ON" "$TRIM_END_VAL" "$FORCE_KEYFRAMES"
        local dl_rc=$?

        # AI-перевод — отдельная задача на КАЖДЫЙ созданный медиафайл, а не только на
        # самый свежий; исход учитывается в COUNT_FAIL (F2). Плейлисты/batch/audio уже
        # отсеяны guardrail'ом выше, так что здесь обычно ровно один файл.
        # F13. Источник путей — манифест самого yt-dlp, а не «свежие файлы в дереве».
        if [ "$dl_rc" -eq 0 ] && [ "$TRANSLATE_ENABLED" = "true" ] && [ "$SUBS_ONLY" != "true" ] && [ "$DRY_RUN" = "true" ]; then
            # F6: dry-run — это проверка аргументов, а не реальный прогон. Манифест пуст
            # (yt-dlp не запускался), медиафайлов для перевода нет по определению —
            # печатаем план перевода и НЕ трактуем отсутствие файла как провал.
            echo "[DRY-RUN] AI-перевод ($TRANSLATE_LANG, $TRANSLATE_VOICE, режим $TRANSLATE_MODE): vot-cli-live --reslang=$TRANSLATE_LANG -- \"$URL\", затем ffmpeg-мерж в скачанный файл"
        elif [ "$dl_rc" -eq 0 ] && [ "$TRANSLATE_ENABLED" = "true" ] && [ "$SUBS_ONLY" != "true" ]; then
            local _tr_found=0
            while IFS= read -r media; do
                [ -z "$media" ] && continue
                # Манифест может содержать промежуточные не-медиа результаты (например
                # sidecar-субтитры) — переводим только видеоконтейнеры.
                case "${media##*.}" in
                    mp4|mkv|webm) ;;
                    *) continue ;;
                esac
                if [ ! -f "$media" ]; then
                    log_warn "AI-перевод: yt-dlp сообщил путь, которого нет: $media"
                    continue
                fi
                _tr_found=1
                if ! translate_audio "$media" "$URL" "$TRANSLATE_LANG" "$TRANSLATE_VOICE" \
                        "$TRANSLATE_MODE" "$TRANSLATE_ORIG_LANG" \
                        "$TRANSLATE_ORIG_VOL" "$TRANSLATE_TRANS_VOL" "$PROXY_URL"; then
                    COUNT_FAIL=$((COUNT_FAIL + 1))
                fi
            done < <(sort -u "$dl_manifest" 2>/dev/null)
            if [ "$_tr_found" -eq 0 ]; then
                # F14. Запрошенный перевод без результата — это провал, а не предупреждение:
                # иначе скрипт рапортует общий успех, не переведя ничего.
                log_error "AI-перевод: yt-dlp не сообщил ни одного медиафайла — переводить нечего."
                COUNT_FAIL=$((COUNT_FAIL + 1))
            fi
        fi
        [ -n "$dl_manifest" ] && rm -f "$dl_manifest" 2>/dev/null
    else
        log_error "Укажите URL или используйте --batch"
        echo ""
        show_help
        exit 1
    fi

    print_summary
    # Exit code отражает наличие ошибок — cron/CI могут детектировать провал.
    [ "$COUNT_FAIL" -gt 0 ] && exit 1
    exit 0
}

# Guard: main() запускается только при прямом вызове, не при dot-source (тесты
# подключают build_format_args/read_config напрямую — паритет с реальным кодом).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
