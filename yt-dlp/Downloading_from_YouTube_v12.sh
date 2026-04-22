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
#   ./download.sh --help                        # справка
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.ini"
CHANNELS_FILE="${SCRIPT_DIR}/channels.txt"

# ── Цвета ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ── Счётчики для итоговой сводки ───────────────────────────────────────────
COUNT_OK=0
COUNT_SKIP=0
COUNT_FAIL=0
START_TIME=$(date +%s)

# ── Функции вывода ─────────────────────────────────────────────────────────
log_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_header(){ echo -e "\n${BOLD}═══ $* ═══${NC}\n"; }

# ── Чтение config.ini ─────────────────────────────────────────────────────
read_config() {
    local key="$1"
    local section="$2"
    local default="${3:-}"

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "$default"
        return
    fi

    local in_section=false
    local value=""
    while IFS= read -r line || [ -n "$line" ]; do
        # Убрать пробелы
        line=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        # Пропустить комментарии и пустые строки
        [[ -z "$line" || "$line" == \#* ]] && continue

        # Секция
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            if [ "${BASH_REMATCH[1]}" = "$section" ]; then
                in_section=true
            else
                in_section=false
            fi
            continue
        fi

        # Ключ=значение внутри нужной секции
        if $in_section && [[ "$line" =~ ^${key}[[:space:]]*=[[:space:]]*(.*) ]]; then
            value="${BASH_REMATCH[1]}"
            # Убрать inline-комментарии
            value=$(echo "$value" | sed 's/[[:space:]]*#.*//')
            echo "$value"
            return
        fi
    done < "$CONFIG_FILE"

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

check_base_deps() {
    check_dependency "yt-dlp" "Установите: https://github.com/yt-dlp/yt-dlp" || exit 1
}

check_translate_deps() {
    local missing=0
    check_dependency "ffmpeg" "Установите: https://ffmpeg.org/download.html" || missing=1
    # Ищем vot-cli-live рядом со скриптом, потом в PATH
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -x "$script_dir/vot-cli-live" ] || [ -f "$script_dir/vot-cli-live.exe" ]; then
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

# ── Формирование аргументов cookies ────────────────────────────────────────
build_cookie_args() {
    local method="$1"
    local cookie_file="$2"
    local cookie_browser="$3"

    case "$method" in
        file)
            if [ -f "$cookie_file" ]; then
                echo "--cookies \"$cookie_file\""
            else
                log_warn "Файл cookies не найден: $cookie_file"
            fi
            ;;
        browser)
            echo "--cookies-from-browser $cookie_browser"
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
    case "$url" in
        *youtube.com*|*youtu.be*) echo "youtube" ;;
        *vk.com*)                 echo "vk" ;;
        *rutube.ru*)              echo "rutube" ;;
        *twitch.tv*)              echo "twitch" ;;
        *vimeo.com*)              echo "vimeo" ;;
        *dailymotion.com*)        echo "dailymotion" ;;
        *)                        echo "other" ;;
    esac
}

# ── Формирование аргументов формата ────────────────────────────────────────
build_format_args() {
    local quality="$1"
    local preset="${2:-auto}"
    local platform="${3:-youtube}"

    # auto: для YouTube — avc1_best, для остальных — простой best[height<=N]
    if [ "$preset" = "auto" ]; then
        if [ "$platform" = "youtube" ]; then
            preset="avc1_best"
        else
            case "$quality" in
                audio) echo "-f \"bestaudio/best\"" ;;
                360)   echo "-f \"best[height<=360]/best\"" ;;
                480)   echo "-f \"best[height<=480]/best\"" ;;
                720)   echo "-f \"best[height<=720]/best\"" ;;
                1080)  echo "-f \"best[height<=1080]/best\"" ;;
                1440)  echo "-f \"best[height<=1440]/best\"" ;;
                2160)  echo "-f \"best[height<=2160]/best\"" ;;
                *)     echo "-f \"best[height<=720]/best\"" ;;
            esac
            return
        fi
    fi

    case "$preset" in
        avc1_best)
            case "$quality" in
                audio) echo "-f bestaudio[ext!=webm]" ;;
                360)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]\"" ;;
                480)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]\"" ;;
                720)   echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
                1080)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]\"" ;;
                1440)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]\"" ;;
                2160)  echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]\"" ;;
                *)     echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
            esac ;;
        avc1_https)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 140+134" ;;
                480)   echo "-f 140+135/134" ;;
                720)   echo "-f 140+136/135/134" ;;
                1080)  echo "-f 140+137/136/135/134" ;;
                1440)  echo "-f 140+138/137/136/135/134" ;;
                2160)  echo "-f 140+139/138/137/136/135/134" ;;
                *)     echo "-f 140+136/135/134" ;;
            esac ;;
        avc1_m3u8)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+230" ;;
                480)   echo "-f 234+231/230" ;;
                720)   echo "-f 234+232/231/230" ;;
                1080)  echo "-f 234+233/232/231/230" ;;
                1440)  echo "-f 234+234/233/232/231/230" ;;
                2160)  echo "-f 234+235/234/233/232/231/230" ;;
                *)     echo "-f 234+232/231/230" ;;
            esac ;;
        avc1_https_60fps)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+296" ;;
                480)   echo "-f 234+297/296" ;;
                720)   echo "-f 234+298/297/296" ;;
                1080)  echo "-f 234+299/298/297/296" ;;
                1440)  echo "-f 234+300/299/298/297/296" ;;
                2160)  echo "-f 234+301/300/299/298/297/296" ;;
                *)     echo "-f 234+298/297/296" ;;
            esac ;;
        avc1_m3u8_60fps)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+309" ;;
                480)   echo "-f 234+310/309" ;;
                720)   echo "-f 234+311/310/309" ;;
                1080)  echo "-f 234+312/311/310/309" ;;
                1440)  echo "-f 234+313/312/311/310/309" ;;
                2160)  echo "-f 234+314/313/312/311/310/309" ;;
                *)     echo "-f 234+311/310/309" ;;
            esac ;;
        avc1_https_60fps_hdr)
            case "$quality" in
                audio) echo "-f 234" ;;
                360)   echo "-f 234+696" ;;
                480)   echo "-f 234+697/696" ;;
                720)   echo "-f 234+698/697/696" ;;
                1080)  echo "-f 234+699/698/697/696" ;;
                1440)  echo "-f 234+700/699/698/697/696" ;;
                2160)  echo "-f 234+701/700/699/698/697/696" ;;
                *)     echo "-f 234+698/697/696" ;;
            esac ;;
        old_combo)
            case "$quality" in
                audio) echo "-f 140" ;;
                360)   echo "-f 18" ;;
                480)   echo "-f 20/18" ;;
                720)   echo "-f 22/20/18" ;;
                1080)  echo "-f 24/22/20/18" ;;
                1440)  echo "-f 26/24/22/20/18" ;;
                2160)  echo "-f 28/26/24/22/20/18" ;;
                *)     echo "-f 22/20/18" ;;
            esac ;;
        *)
            echo "-f \"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]\"" ;;
    esac
}

# ── Скачивание одного URL ──────────────────────────────────────────────────
download_url() {
    local url="$1"
    local output_template="$2"
    local quality="$3"
    local subs_only="$4"
    local proxy_url="$5"
    local cookie_args="$6"
    local archive_arg="$7"

    local cmd="yt-dlp -c -i -w --compat-options filename-sanitization"

    # Deno рядом со скриптом
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -x "$script_dir/deno" ] && cmd+=" --js-runtimes deno:$script_dir/deno"

    # Прокси
    [ -n "$proxy_url" ] && cmd+=" --proxy \"$proxy_url\""

    # Cookies
    [ -n "$cookie_args" ] && cmd+=" $cookie_args"

    # Архив скачанного
    [ -n "$archive_arg" ] && cmd+=" $archive_arg"

    # Шаблон вывода
    cmd+=" -o \"$output_template\""

    if [ "$subs_only" = "true" ]; then
        cmd+=" --sub-lang $SUB_LANG --write-auto-sub --sub-format $SUB_FORMAT --skip-download"
    else
        cmd+=" $(build_format_args "$quality" "$FORMAT_PRESET" "$(detect_platform "$url")")"
    fi

    cmd+=" \"$url\""

    log_info "Команда: $cmd"

    if eval $cmd; then
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

    log_info "Получение AI-перевода ($target_lang, $voice_style)..."

    local temp_dir
    temp_dir=$(mktemp -d)
    local vot_cmd="\"$VOT_BIN\" --output=\"$temp_dir\" --voice-style=$voice_style --reslang=$target_lang"
    vot_cmd+=" \"$url\""

    if ! NODE_TLS_REJECT_UNAUTHORIZED=0 eval $vot_cmd; then
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

    local output_file="${video_file%.mp4}_translated.mp4"

    log_info "Мерж аудиодорожек (режим: $mode)..."

    case "$mode" in
        dual_track)
            ffmpeg -y -i "$video_file" -i "$translation_file" \
                -map 0:v -map 0:a -map 1:a \
                -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 192k \
                -metadata:s:a:0 language="$orig_lang" -metadata:s:a:0 title="Original" \
                -metadata:s:a:1 language="$target_lang" -metadata:s:a:1 title="AI Translation" \
                -disposition:a:0 default \
                "$output_file" 2>/dev/null
            ;;
        replace)
            ffmpeg -y -i "$video_file" -i "$translation_file" \
                -map 0:v -map 1:a \
                -c:v copy -c:a aac -b:a 192k \
                -metadata:s:a:0 language="$target_lang" -metadata:s:a:0 title="AI Translation" \
                "$output_file" 2>/dev/null
            ;;
        mix)
            ffmpeg -y -i "$video_file" -i "$translation_file" \
                -filter_complex "[0:a]volume=${orig_vol}[a0];[1:a]volume=${trans_vol}[a1];[a0][a1]amix=inputs=2:duration=longest[aout]" \
                -map 0:v -map "[aout]" \
                -c:v copy -c:a aac -b:a 192k \
                "$output_file" 2>/dev/null
            ;;
    esac

    if [ $? -eq 0 ] && [ -f "$output_file" ]; then
        mv "$output_file" "$video_file"
        log_ok "Перевод добавлен: $video_file"
    else
        log_error "Ошибка мержа аудиодорожек"
        [ -f "$output_file" ] && rm -f "$output_file"
    fi

    rm -rf "$temp_dir"
}

# ── Batch-загрузка из channels.txt ─────────────────────────────────────────
download_batch() {
    local subs_only="$1"

    if [ ! -f "$CHANNELS_FILE" ]; then
        log_error "Файл каналов не найден: $CHANNELS_FILE"
        exit 1
    fi

    local total=0
    while IFS='|' read -r category handle mode || [ -n "$category" ]; do
        [[ -z "$category" || "$category" == \#* ]] && continue
        category=$(echo "$category" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        handle=$(echo "$handle" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        mode=$(echo "$mode" | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        [[ -z "$handle" ]] && continue

        total=$((total + 1))
        log_header "[$total] ${category}/${handle} (${mode})"

        local template
        if [ "$mode" = "playlists" ]; then
            template="${BASE_DIR}/${category}/${PLAYLIST_TEMPLATE}"
        else
            template="${BASE_DIR}/${category}/${OUTPUT_TEMPLATE}"
        fi

        local archive_arg=""
        if [ "$USE_ARCHIVE" = "true" ]; then
            archive_arg="--download-archive \"${BASE_DIR}/${ARCHIVE_FILE}\""
        fi

        local batch_args="-c -i -w --compat-options filename-sanitization"
        local sdir
        sdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        [ -x "$sdir/deno" ] && batch_args+=" --js-runtimes deno:$sdir/deno"
        [ -n "$PROXY_URL" ] && batch_args+=" --proxy \"$PROXY_URL\""
        [ -n "$COOKIE_ARGS" ] && batch_args+=" $COOKIE_ARGS"
        [ -n "$archive_arg" ] && batch_args+=" $archive_arg"
        batch_args+=" -o \"$template\""

        # Дата
        local date_range
        date_range=$(read_config "date_range" "batch" "now-6months")
        batch_args+=" --dateafter $date_range"

        # Задержки
        local sleep_req sleep_int max_sleep_int sleep_sub
        sleep_req=$(read_config "sleep_requests" "batch" "1.8")
        sleep_int=$(read_config "sleep_interval" "batch" "8")
        max_sleep_int=$(read_config "max_sleep_interval" "batch" "22")
        sleep_sub=$(read_config "sleep_subtitles" "batch" "4")
        batch_args+=" --sleep-requests $sleep_req"
        batch_args+=" --sleep-interval $sleep_int"
        batch_args+=" --max-sleep-interval $max_sleep_int"
        batch_args+=" --sleep-subtitles $sleep_sub"

        if [ "$subs_only" = "true" ]; then
            batch_args+=" --sub-lang $SUB_LANG --write-auto-sub --sub-format $SUB_FORMAT --skip-download"
        else
            batch_args+=" $(build_format_args "$QUALITY" "$FORMAT_PRESET" "youtube")"
        fi

        if [ "$mode" = "playlists" ]; then
            batch_args+=" --yes-playlist"
        else
            batch_args+=" --playlist-reverse"
        fi

        local url="https://www.youtube.com/@${handle}/${mode}"
        batch_args+=" \"$url\""

        local cmd="yt-dlp $batch_args"
        log_info "Команда: $cmd"

        if eval $cmd; then
            log_ok "Канал $handle завершён"
            COUNT_OK=$((COUNT_OK + 1))
        else
            log_error "Ошибка при загрузке канала $handle"
            COUNT_FAIL=$((COUNT_FAIL + 1))
        fi
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
  --proxy URL                  HTTP/HTTPS прокси

ПЕРЕВОД (требует vot-cli-live, ffmpeg, Node.js 18+):
  --translate LANG             Добавить AI-перевод аудио (ru, en, kk)
  --voice STYLE                Голос: live (по умолчанию) / tts
  --mix                        Смешать оригинал + перевод
  --replace                    Заменить оригинал переводом
  (по умолчанию — mix: смешать оригинал + перевод)

ПРОЧЕЕ:
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
    SUB_LANG=$(read_config "lang" "subtitles" "ru")
    SUB_FORMAT=$(read_config "format" "subtitles" "vtt")

    # Перевод
    TRANSLATE_ENABLED=$(read_config "enabled" "translation" "false")
    TRANSLATE_LANG=$(read_config "target_lang" "translation" "ru")
    TRANSLATE_VOICE=$(read_config "voice_style" "translation" "live")
    TRANSLATE_MODE=$(read_config "mode" "translation" "mix")
    TRANSLATE_ORIG_VOL=$(read_config "original_volume" "translation" "0.3")
    TRANSLATE_TRANS_VOL=$(read_config "translation_volume" "translation" "1.0")
    TRANSLATE_ORIG_LANG=$(read_config "original_lang" "translation" "en")

    # Относительный путь cookies к скрипту
    if [[ "$COOKIE_FILE_PATH" != /* ]]; then
        COOKIE_FILE_PATH="${SCRIPT_DIR}/${COOKIE_FILE_PATH}"
    fi

    # Относительный путь base_dir
    if [[ "$BASE_DIR" != /* ]]; then
        BASE_DIR="${SCRIPT_DIR}/${BASE_DIR}"
    fi
}

# ── Парсинг аргументов ─────────────────────────────────────────────────────
parse_args() {
    BATCH_MODE=false
    SUBS_ONLY=false
    TRANSLATE_CLI=""
    TRANSLATE_MODE_CLI=""
    TRANSLATE_VOICE_CLI=""
    URL=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --help|-h)
                show_help
                exit 0
                ;;
            --config)
                CONFIG_FILE="$2"; shift 2
                ;;
            --batch)
                BATCH_MODE=true; shift
                ;;
            --subs)
                SUBS_ONLY=true; shift
                ;;
            --quality)
                QUALITY="$2"; shift 2
                ;;
            --format)
                FORMAT_PRESET="$2"; shift 2
                ;;
            --proxy)
                PROXY_URL="$2"; shift 2
                ;;
            --cookies)
                COOKIE_METHOD="$2"; shift 2
                ;;
            --cookie-browser)
                COOKIE_BROWSER="$2"; shift 2
                ;;
            --cookie-file)
                COOKIE_FILE_PATH="$2"; shift 2
                ;;
            --translate)
                TRANSLATE_CLI="$2"; shift 2
                ;;
            --voice)
                TRANSLATE_VOICE_CLI="$2"; shift 2
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
            -*)
                log_error "Неизвестный флаг: $1"
                show_help
                exit 1
                ;;
            *)
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

    # Сформировать cookie args
    COOKIE_ARGS=$(build_cookie_args "$COOKIE_METHOD" "$COOKIE_FILE_PATH" "$COOKIE_BROWSER")
}

# ── MAIN ───────────────────────────────────────────────────────────────────
main() {
    load_config
    parse_args "$@"

    check_base_deps

    if [ "$TRANSLATE_ENABLED" = "true" ]; then
        check_translate_deps || exit 1
    fi

    log_header "YouTube Downloader"
    log_info "Качество: $QUALITY | Формат: $FORMAT_PRESET | Cookies: $COOKIE_METHOD | Прокси: ${PROXY_URL:-нет}"
    [ "$TRANSLATE_ENABLED" = "true" ] && log_info "Перевод: $TRANSLATE_LANG ($TRANSLATE_VOICE, $TRANSLATE_MODE)"

    if [ "$BATCH_MODE" = "true" ]; then
        download_batch "$SUBS_ONLY"
    elif [ -n "$URL" ]; then
        # Определить шаблон
        local template
        if echo "$URL" | grep -qi "playlist"; then
            template="${BASE_DIR}/${PLAYLIST_TEMPLATE}"
        else
            template="${BASE_DIR}/${OUTPUT_TEMPLATE}"
        fi

        local archive_arg=""
        if [ "$USE_ARCHIVE" = "true" ]; then
            archive_arg="--download-archive \"${BASE_DIR}/${ARCHIVE_FILE}\""
        fi

        download_url "$URL" "$template" "$QUALITY" "$SUBS_ONLY" "$PROXY_URL" "$COOKIE_ARGS" "$archive_arg"

        # AI-перевод если включён и не только субтитры
        if [ "$TRANSLATE_ENABLED" = "true" ] && [ "$SUBS_ONLY" != "true" ]; then
            # Найти последний скачанный файл
            local latest
            latest=$(find "$BASE_DIR" -name "*.mp4" -newer "$0" -type f 2>/dev/null | head -1)
            if [ -n "$latest" ]; then
                translate_audio "$latest" "$URL" "$TRANSLATE_LANG" "$TRANSLATE_VOICE" \
                    "$TRANSLATE_MODE" "$TRANSLATE_ORIG_LANG" \
                    "$TRANSLATE_ORIG_VOL" "$TRANSLATE_TRANS_VOL" "$PROXY_URL"
            fi
        fi
    else
        log_error "Укажите URL или используйте --batch"
        echo ""
        show_help
        exit 1
    fi

    print_summary
}

main "$@"
