# Система тестирования Video Tools

Автоматизированная тест-система на чистом Bash без внешних зависимостей.
Покрывает оба проекта: **FFmpeg Converter** и **YT-DLP Downloader**.

---

## Быстрый старт

```bash
# Все тесты (из корня проекта)
bash tests/run_tests.sh

# Только ffmpeg
bash tests/run_tests.sh ffmpeg

# Только yt-dlp
bash tests/run_tests.sh yt-dlp
```

**Результат:** 194 теста, 193 проходит, 1 пропускается (интеграционный тест на реальном ffmpeg — пропускается если ffmpeg недоступен).

---

## Структура

```
tests/
├── run_tests.sh              # Точка входа: запуск всех suite-ов, итоговый отчёт
├── lib/
│   └── framework.sh          # Assert-функции, счётчики, форматированный вывод
├── mocks/
│   ├── ffmpeg                # Mock ffmpeg: лог вызовов, имитация прогресса
│   ├── ffprobe               # Mock ffprobe: фиктивные данные о медиафайле
│   └── yt-dlp                # Mock yt-dlp: лог вызовов, имитация загрузки
├── ffmpeg/
│   ├── test_01_config_sh.sh  # Парсинг config.ini (Bash)
│   ├── test_02_config_ps1.sh # Парсинг config.ini (PowerShell)
│   ├── test_03_audio_args.sh # Формирование аудио-аргументов
│   ├── test_04_video_args.sh # Формирование видео-аргументов
│   ├── test_05_filters.sh    # Цепочки фильтров (scale, rotate, setpts, atempo)
│   ├── test_06_gpu.sh        # GPU-ускорение (NVENC, QSV)
│   └── test_07_integration.sh# Интеграционный: реальный MP4 + mock ffmpeg
└── yt-dlp/
    ├── test_01_read_config.sh # Парсинг config.ini yt-dlp
    ├── test_02_format_args.sh # Пресеты форматов (7 пресетов × 8 качеств)
    ├── test_03_cookie_args.sh # Аргументы cookies (none/browser/file)
    └── test_04_integration.sh # Интеграционный: реальный скрипт + mock yt-dlp
```

---

## Тест-модули FFmpeg (7 файлов, ~125 тестов)

### test_01_config_sh — Парсинг config.ini (Bash) · 29 тестов

Тестирует функции `read_config()` и `to_flag()` из `FFmpeg_Converter_run.sh`.

**Ключевой приём:** функции копируются прямо в тест-файл (без fork), поэтому тест быстрый и изолированный.

| Suite | Что проверяет |
|-------|---------------|
| `to_flag: конвертация +/- префиксов` | `+value → :+:value`, `-value → :-:value`, голое значение, пустое + default |
| `read_config: секция [audio]` | codec, channels, bitrate, sampling_rate, normalize |
| `read_config: секция [video]` | codec, resolution, framerate, rotation, quality, container |
| `read_config: секции [gpu] [other] [speed]` | hw_accel, preset, dry_run, log_file, parallel_files |
| `read_config: edge cases` | несуществующий ключ, несуществующая секция, отсутствующий файл |
| `to_flag + read_config: полный цикл` | Как в `run.sh`: audio_codec, video_codec, parallel (-), hw_accel (+) |

### test_02_config_ps1 — Парсинг config.ini (PowerShell) · 11 тестов

Запускает PowerShell (`pwsh`) для тестирования функций `Read-Config` и `To-Flag` из `FFmpeg_Converter_run.ps1`.

**Особенность:** тест пропускается если `pwsh` недоступен (1 skip).

| Suite | Что проверяет |
|-------|---------------|
| `PS1 To-Flag: конвертация префиксов` | Паритет с Bash-версией: +/- → :+:/:-: |
| `PS1 Read-Config: базовый парсинг` | Секции audio, video, performance |
| `PS1 Read-Config: inline комментарии` | Значение не включает комментарий `# ...` |
| `PS1 vs Bash: паритет значений` | PS1 и Bash дают одинаковый результат |

### test_03_audio_args — Аудио-аргументы · 16 тестов

Запускает `FFmpeg_Converter_script.sh` через `run_script()`, извлекает переменные через `trap EXIT`.

| Suite | Что проверяет |
|-------|---------------|
| `Аудио: кодек` | `-c:a aac`, `-c:a libmp3lame` |
| `Аудио: каналы и битрейт` | `-ac 1`/`-ac 2`, `-b:a 128k`/`-b:a 192k` |
| `Аудио: частота дискретизации` | `-ar 44100`, `-ar 48000` |
| `Аудио: нормализация` | loudnorm включён/выключен в `af_chain` |
| `Режим audio_only` | `-vn`, формат `mp3`, кодек `libmp3lame` |

### test_04_video_args — Видео-аргументы · 14 тестов

| Suite | Что проверяет |
|-------|---------------|
| `Видео: кодек` | libx264, libx265, libsvtav1 |
| `Видео: качество (CRF)` | `-crf 23` включён/выключен при разных настройках |
| `Видео: контейнер` | mp4, mkv, webm — в format_files_out и ffmpeg-аргументах |
| `Видео: частота кадров` | `-r 25`, `-r 60` |

### test_05_filters — Фильтры · 23 теста

| Suite | Что проверяет |
|-------|---------------|
| `Фильтры: поворот (transpose)` | `transpose=1` / `transpose=2` в `vf_chain` |
| `Фильтры: масштабирование (scale)` | `scale=`, `pad=` с сохранением пропорций |
| `Фильтры: скорость воспроизведения` | `setpts=0.5*PTS`, `atempo=2.0` для 2x |
| `Фильтры: atempo каскад (> 2.0)` | Скорость 3x → `atempo=2.0,atempo=1.5` |
| `Фильтры: atempo каскад (< 0.5)` | Скорость 0.25x → `atempo=0.5,atempo=0.5` |
| `Фильтры: комбо rotate + scale` | Оба фильтра через запятую в `vf_chain` |

### test_06_gpu — GPU · 23 теста

Управляется через `MOCK_FFMPEG_ENCODERS=nvenc|qsv|""`.

| Suite | Что проверяет |
|-------|---------------|
| `GPU NVIDIA: замена кодека` | `h264_nvenc` вместо `libx264` при `hw_accel=+nvidia` |
| `GPU NVIDIA: параметры качества` | `-cq`, `-preset`, `-tune`, `-rc` |
| `GPU Intel QSV: замена кодека` | `h264_qsv` вместо `libx264` при `hw_accel=+intel` |
| `GPU Intel QSV: параметры качества` | `-global_quality`, `-preset` |
| `GPU: NVENC не поддерживается` | Fallback на `libx264` если в mock нет nvenc |
| `GPU: hw_accel отключён (-)` | Программный кодек при `hw_accel=-nvidia` |

### test_07_integration — Интеграционный · 13 тестов

Создаёт реальный MP4 (1 сек, 64x64) через системный ffmpeg, затем запускает `script.sh` с mock ffmpeg. Проверяет полный пайплайн вызова.

| Suite | Что проверяет |
|-------|---------------|
| `Интеграция: базовый запуск` | mock ffmpeg был вызван, `-c:v libx264`, `-c:a aac`, `-crf` |
| `Интеграция: audio_only` | `-vn`, `libmp3lame` |
| `Интеграция: copy_codecs` | `-c copy`, нет `-crf`/`-c:v libx264` |
| `Интеграция: dry_run` | ffmpeg НЕ вызывается (выводится только команда) |
| `Интеграция: FAIL ffmpeg` | Файл не создан, ошибка в сводке |

---

## Тест-модули YT-DLP (4 файла, ~73 теста)

### test_01_read_config — Парсинг config.ini · 16 тестов

Использует ту же `read_config()` что и ffmpeg (функции идентичны). Тестирует на yt-dlp-specific секциях.

| Suite | Что проверяет |
|-------|---------------|
| `proxy` | url — пустое значение и реальный URL |
| `cookies` | method (none/browser/file), browser, file |
| `output` | base_dir, template, playlist_template |
| `download` | default_quality, continue_on_error, archive |
| `translation` | enabled, target_lang, voice_style, mode |
| `defaults и edge cases` | отсутствующий ключ, пустой файл, default-значения |

### test_02_format_args — Пресеты форматов · 34 теста

Проверяет `build_format_args()` — 7 пресетов × 8 уровней качества (0-6 + субтитры 91/92).

| Suite | Что проверяет |
|-------|---------------|
| `avc1_best` | `bestaudio[ext=m4a]+bestvideo[height<=N][vcodec^=avc1]` |
| `avc1_https` | Числовые ID: 140+137, 140+136, ... |
| `avc1_m3u8` | HLS ID: 234+233, 234+232, ... |
| `avc1_https_60fps` | 60fps ID: 234+299, 234+298, ... |
| `avc1_m3u8_60fps` | M3U8 60fps ID |
| `avc1_https_60fps_hdr` | HDR ID |
| `old_combo` | Legacy: 18, 20/18, 22/20/18, ... |
| `Неизвестный пресет` | Fallback на `avc1_best` |

### test_03_cookie_args — Cookies · 10 тестов

| Suite | Что проверяет |
|-------|---------------|
| `none / пустой` | cookie_arg пустой |
| `browser` | `--cookies-from-browser chrome/firefox/edge` |
| `file (существует)` | `--cookies /path/to/file` |
| `file (не существует)` | Предупреждение, cookie_arg пустой |
| `неизвестный метод` | Graceful fallback |

### test_04_integration — Интеграционный · 13 тестов

Запускает `Downloading_from_YouTube_v11.sh` с mock yt-dlp через PATH подмену.

| Suite | Что проверяет |
|-------|---------------|
| `Базовый: quality 720p` | `bestaudio[ext=m4a]+bestvideo[height<=720]...` |
| `Только аудио (quality 0)` | `-f bestaudio[ext=m4a]/bestaudio` |
| `Cookies chrome` | `--cookies-from-browser chrome` |
| `Прокси` | `--proxy http://proxy:3128` |
| `Субтитры (quality 91/92)` | `--sub-lang ru/en --write-auto-sub --skip-download` |
| `Ошибка yt-dlp` | `MOCK_YTDLP_FAIL=1` — exit code != 0 |

---

## Framework (lib/framework.sh)

### Assert-функции

```bash
assert_eq   "название" "ожидается" "получено"      # Точное равенство
assert_contains     "название" "подстрока" "текст" # Текст содержит подстроку
assert_not_contains "название" "подстрока" "текст" # Текст НЕ содержит подстроку
assert_empty     "название" "$var"                 # Переменная пуста
assert_not_empty "название" "$var"                 # Переменная не пуста
assert_file_exists "название" "/path/to/file"      # Файл существует
```

### Вывод

```bash
suite "Название группы"    # Заголовок группы тестов
pass  "название теста"     # Принудительно пройден
fail  "название" "ожидалось" "получено"  # Принудительно провален
skip  "название" "причина"  # Пропущен
summary                    # Итоговая строка: всего/пройдено/провалено/пропущено
```

**Важно:** `grep -qF -- "$pattern"` (двойное тире) — не позволяет паттернам вида `-c:v` интерпретироваться как флаг grep.

---

## Mock-бинарники (mocks/)

### mocks/ffmpeg

Устанавливается в PATH через `export PATH="$TESTS_DIR/mocks:$PATH"`.

**Управляющие переменные:**

| Переменная | Значение | Эффект |
|------------|----------|--------|
| `MOCK_FFMPEG_ENCODERS` | `nvenc` | Добавляет `nvenc_example` в вывод `-encoders` |
| `MOCK_FFMPEG_ENCODERS` | `qsv` | Добавляет `qsv_example` |
| `MOCK_FFMPEG_ENCODERS` | `` (пусто) | Только libx264/libx265/libsvtav1 |
| `MOCK_FFMPEG_LOG` | `/tmp/log.txt` | Путь к файлу лога (все вызовы дописываются) |
| `MOCK_FFMPEG_FAIL` | `1` | Возвращает exit code 1 |

**Поведение:**
- Записывает все аргументы в `$MOCK_FFMPEG_LOG`
- При `-encoders` — возвращает список кодеков
- При `-version` — возвращает `ffmpeg version 6.0 (mock)`
- При `-progress file` — записывает mock-прогресс (frame, fps, out_time_ms, progress=end)
- Создаёт пустой выходной файл (последний аргумент не начинающийся с `-`)

### mocks/ffprobe

| Запрос | Ответ |
|--------|-------|
| `-show_entries format=... noprint_wrappers=1:nokey=1 bit_rate` | `2000000` |
| `-show_entries format=... noprint_wrappers=1:nokey=1 duration` | `60.000000` |
| Всё остальное | Текст в стиле ffprobe stderr с Duration 00:01:00, 1920x1080 h264 |

### mocks/yt-dlp

| Переменная | Эффект |
|------------|--------|
| `MOCK_YTDLP_LOG` | Путь к файлу лога всех вызовов |
| `MOCK_YTDLP_FAIL` | `1` → exit code 1 |

---

## Ключевые техники

### 1. Запуск script.sh через `source` + `trap EXIT`

**Проблема:** `FFmpeg_Converter_script.sh` заканчивается на `read -p "..."; exit`. При `source` внутри subshell — `exit` завершает subshell ДО того, как вернуть значения переменных через stdout.

**Решение:** Записываем переменные в временный файл через `trap _dump EXIT`:

```bash
run_script() {
    local dump
    dump=$(mktemp /tmp/test_dump_XXXXXX.txt)

    (
        export PATH="$TESTS_DIR/mocks:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        default_vars                          # установить переменные
        for ov in "$@"; do eval "$ov"; done   # переопределить нужные

        _dump() {
            {
                echo "audio_codec_arg=${set_audio_codec:-}"
                echo "video_codec_arg=${set_video_codec:-}"
                echo "af_chain=${af_chain:-}"
                # ...другие переменные...
            } > "$dump"
        }
        trap _dump EXIT

        source "$SCRIPT" > /dev/null 2>&1
    ) < /dev/null   # < /dev/null: read -p немедленно получает EOF, не блокирует

    # Парсим результат
    local result
    result=$(cat "$dump")
    rm -f "$dump"
    echo "$result"
}
```

Тест читает переменные:
```bash
out=$(run_script 'audio_codec=":+:libmp3lame"')
codec=$(echo "$out" | grep '^audio_codec_arg=' | cut -d= -f2-)
assert_contains "aac кодек" "-c:a libmp3lame" "$codec"
```

### 2. Bypassing run.sh (прямая установка переменных)

`run.sh` читает `config.ini` через `sed`-форки — **очень медленно** на Windows (3200+ `sed` процессов за запуск). Тесты обходят `run.sh`, устанавливая переменные напрямую во внутреннем формате `:+:value` / `:-:value`:

```bash
default_vars() {
    folder_sources="/tmp/input"
    folder_destination="/tmp/output"
    ffmpeg="$TESTS_DIR/mocks/ffmpeg"
    audio_codec=":+:aac"          # = codec = +aac из config.ini
    video_codec=":+:libx264"      # = codec = +libx264
    video_quality=":+:23"         # = quality = +23 (CRF включён)
    video_bitrate=":-:2000"       # = bitrate = -2000 (битрейт выключен)
    hw_accel=":-:nvidia"          # = hw_accel = -nvidia (GPU выключен)
    # ...все остальные переменные...
}
```

### 3. Захват лога ffmpeg-вызовов

```bash
FFMPEG_LOG="/tmp/mock_ffmpeg_$$.txt"

run_script 'video_codec=":+:libx265"'

call_args=$(cat "$FFMPEG_LOG")
assert_contains "кодек libx265" "-c:v libx265" "$call_args"
assert_not_contains "нет nvidia" "h265_nvenc" "$call_args"
```

### 4. Управление NVENC через mock

```bash
# Тест с NVENC
export MOCK_FFMPEG_ENCODERS="nvenc"
run_script 'hw_accel=":+:nvidia"'
assert_contains "NVENC кодек" "h264_nvenc" "$(cat "$FFMPEG_LOG")"

# Тест без NVENC (fallback)
export MOCK_FFMPEG_ENCODERS=""
run_script 'hw_accel=":+:nvidia"'
assert_contains "fallback libx264" "-c:v libx264" "$(cat "$FFMPEG_LOG")"
```

### 5. Тест PowerShell из Bash

```bash
if ! command -v pwsh &>/dev/null; then
    skip "PS1 парсинг" "pwsh не найден"; summary; exit 0
fi

ps1_result=$(pwsh -NonInteractive -Command "
    \$config = Get-Content '$config_file' | Out-String
    # ...
    Write-Output \$result
" 2>/dev/null)
assert_eq "PS1 codec" ":+:libx265" "$ps1_result"
```

---

## Реальное тестирование (Real Runs)

Помимо мок-тестов, проводились реальные запуски на системном ffmpeg 7.1.1.

### Тест-видео

```bash
ffmpeg -y -f lavfi -i "color=c=blue:s=640x480:d=5:r=25" \
       -f lavfi -i "sine=frequency=440:d=5" \
       -c:v libx264 -c:a aac -shortest /tmp/test.mp4
```

### Покрытые сценарии

| Сценарий | Результат |
|----------|-----------|
| Базовая конвертация (640x480 → 320x240, CRF 28) | ✓ OK, правильные потоки |
| `audio_only=yes` (mp3, libmp3lame) | ✓ OK |
| `dry_run=yes` | ✓ Команда выведена, файлы не созданы |
| `copy_codecs=yes` | ✓ OK (после исправления 2 багов) |

### Баги, найденные при реальном тестировании

| Баг | Файл | Исправление |
|-----|------|-------------|
| `grep -oP` не работает в Git Bash (locale error) | `script.sh` | `grep -o 'pat' \| sed 's/pat//'` |
| `.exe` файл определён, переменная без `.exe` | `run.sh`, `script.sh` | Отдельная ветка `elif` для `.exe` |
| `copy_codecs=yes` + фильтры несовместимы с `-c copy` | `script.sh` | Обнулять `vf_args`/`af_args` при copy |
| `-ss 0` на output-side с `-c copy` удаляет видеопоток | `script.sh` | Добавлять `-ss` только если `b > 0` |

---

## Добавление новых тестов

### Новый тест в существующий файл

```bash
suite "Моё новое поведение"

out=$(run_script 'my_var=":+:value"')
my_arg=$(echo "$out" | grep '^my_arg=' | cut -d= -f2-)
assert_contains "моя настройка" "-my-flag value" "$my_arg"
assert_not_contains "нет лишнего" "--unwanted" "$my_arg"
```

### Новый тест-файл

1. Создать `tests/ffmpeg/test_08_new.sh` (или `tests/yt-dlp/test_05_new.sh`)
2. Скопировать шапку с `TESTS_DIR`, `PROJECT_DIR`, `source framework.sh`
3. Скопировать `default_vars()` и `run_script()` из соседнего файла
4. Зарегистрировать в `tests/run_tests.sh` в массиве `FFMPEG_TESTS` или `YTDLP_TESTS`

### Тест нового мок-поведения ffmpeg

Добавить в `tests/mocks/ffmpeg`:
```bash
if [[ "$*" == *"-my-flag"* ]]; then
    echo "my mock response"
    exit 0
fi
```

Управлять через переменную окружения:
```bash
export MOCK_FFMPEG_MY_OPTION="value"
```
