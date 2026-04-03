# Video Tools

ffmpeg/yt-dlp скрипты для загрузки и конвертации видео. Каждый инструмент реализован на 3 платформах (.sh, .cmd, .ps1), включая GUI (WinForms) и сборку PS1 в EXE через ps2exe. 343 автоматических теста на чистом Bash.

---

## Структура проекта

```
video/
├── ffmpeg/                        # Конвертер видео/аудио
│   ├── config.ini                 # Настройки: кодеки, GPU, нарезка, фильтры
│   ├── FFmpeg_Converter_run.sh    # Загрузчик конфига (Bash)
│   ├── FFmpeg_Converter_run.cmd   # Загрузчик конфига (CMD)
│   ├── FFmpeg_Converter_run.ps1   # Загрузчик конфига (PowerShell)
│   ├── FFmpeg_Converter_run_win.ps1  # GUI (WinForms)
│   ├── FFmpeg_Converter_script.*  # Основная логика (.sh/.cmd/.ps1)
│   ├── build_exe.ps1              # Сборка -> VideoConverter.exe
│   ├── ffmpeg.exe                 # Портативный ffmpeg
│   └── VideoConverter.exe         # Скомпилированный GUI
│
├── yt-dlp/                        # Загрузчик видео с YouTube и 1000+ сайтов
│   ├── config.ini                 # Настройки: качество, cookies, прокси, AI-перевод
│   ├── Downloading_from_YouTube_v11.sh   # CLI (Bash)
│   ├── Downloading_from_YouTube_v11.cmd  # CLI (Windows)
│   ├── Downloading_from_YouTube_v11.ps1  # GUI (WinForms)
│   ├── build_exe.ps1              # Сборка -> VideoDownloader.exe
│   ├── yt-dlp.exe                 # Загрузчик видео
│   ├── deno.exe                   # JS-runtime для плагинов yt-dlp
│   ├── vot-cli-live.exe           # AI-перевод аудио через Яндекс
│   └── VideoDownloader.exe        # Скомпилированный GUI
│
├── tests/                         # Автоматические тесты (~343 шт.)
│   ├── run_tests.sh               # Точка входа
│   ├── lib/framework.sh           # Assert-функции, форматированный вывод
│   ├── mocks/{ffmpeg,ffprobe,yt-dlp}  # Mock-бинарники
│   ├── ffmpeg/test_01..10*.sh     # 10 тест-файлов (~207 тестов)
│   └── yt-dlp/test_01..06*.sh     # 6 тест-файлов (~136 тестов)
│
├── CLAUDE.md                      # Инструкции для Claude Code
├── PLAN.md                        # Оставшиеся задачи (фильтры, пресеты)
└── README.md
```

---

## Технологии

- **Bash** (.sh) — основной скриптовый язык, Linux/macOS/Git Bash
- **CMD** (.cmd) — Windows, `@chcp 65001` для UTF-8
- **PowerShell** (.ps1) — Windows GUI (WinForms), UTF-8 с BOM
- **ffmpeg/ffprobe** — конвертация, анализ медиафайлов
- **yt-dlp** — загрузка видео, 1000+ сайтов
- **vot-cli-live** — AI-перевод аудио через Яндекс
- **ps2exe** — компиляция PS1 в EXE

---

## Возможности

### FFmpeg Converter

- **Кодеки:** libx264, libx265, libsvtav1, h264_nvenc, hevc_nvenc, av1_nvenc, h264_qsv
- **GPU-ускорение:** NVIDIA NVENC (пресеты p1-p7, tune, rate control), Intel QSV
- **Аудио:** aac, libmp3lame, нормализация (loudnorm, dynaudnorm)
- **Фильтры:** масштабирование, поворот, субтитры, изменение скорости (каскад atempo)
- **Режимы:** только аудио, объединение файлов, извлечение кадров, copy без перекодирования
- **Нарезка:** по времени, по тишине (silencedetect)
- **Контейнеры:** mp4, mkv, webm, avi, ts
- **Прогресс-бар**, dry-run, логирование, итоговая сводка (ok/fail/skip)

### YT-DLP Downloader

- **Качество:** 360p-4K, 7 пресетов (avc1_best, avc1_https, m3u8, 60fps, HDR, old_combo)
- **Cookies:** без / из браузера (Chrome, Firefox, Edge) / из файла
- **Прокси:** HTTPS с авторизацией
- **AI-перевод аудио:** 3 режима — dual_track, replace, mix
- **Batch:** загрузка каналов из channels.txt с задержками и архивом скачанного
- **Субтитры:** автоматическое скачивание (VTT)

---

## Архитектура: config.ini -> run -> script

Оба проекта используют одинаковый паттерн:

1. **`config.ini`** — пользовательские настройки. Формат: `+value` = включено, `-value` = выключено
2. **`run`** — читает config.ini, конвертирует в внутренний формат (`:+:value` / `:-:value`), запускает script
3. **`script`** — строит и выполняет команды ffmpeg/yt-dlp
4. **GUI** (`*_run_win.ps1`) — WinForms, читает config.ini для начальных значений контролов

Бинарники (ffmpeg, yt-dlp) автоматически определяются рядом со скриптом, затем в PATH. Относительные пути в config.ini разрешаются от директории скрипта.

---

## Запуск

```bash
# FFmpeg Converter (из папки ffmpeg/)
bash FFmpeg_Converter_run.sh

# YT-DLP Downloader (из папки yt-dlp/)
bash Downloading_from_YouTube_v11.sh

# GUI (Windows PowerShell)
powershell -File ffmpeg/FFmpeg_Converter_run_win.ps1
powershell -File yt-dlp/Downloading_from_YouTube_v11.ps1
```

---

## Тестирование

343 теста на чистом Bash, без внешних зависимостей. Mock-бинарники для ffmpeg, ffprobe, yt-dlp.

```bash
bash tests/run_tests.sh           # все тесты (~343)
bash tests/run_tests.sh ffmpeg    # ffmpeg (~207 тестов, 10 файлов)
bash tests/run_tests.sh yt-dlp    # yt-dlp (~136 тестов, 6 файлов)
```

### Тест-модули FFmpeg (10 файлов)

| Файл | Что тестирует |
|------|---------------|
| `test_01_config_sh` | Парсинг config.ini (Bash) |
| `test_02_config_ps1` | Парсинг config.ini (PowerShell) |
| `test_03_audio_args` | Формирование аудио-аргументов |
| `test_04_video_args` | Формирование видео-аргументов |
| `test_05_filters` | Фильтры (scale, rotate, setpts, atempo) |
| `test_06_gpu` | GPU-ускорение (NVENC, QSV, fallback) |
| `test_07_integration` | Интеграционный: реальный MP4 + mock |
| `test_08_ps1_audio_video` | PS1: аудио/видео аргументы |
| `test_09_ps1_filters_gpu` | PS1: фильтры и GPU |
| `test_10_cmd` | CMD-скрипт |

### Тест-модули YT-DLP (6 файлов)

| Файл | Что тестирует |
|------|---------------|
| `test_01_read_config` | Парсинг config.ini |
| `test_02_format_args` | Пресеты форматов (7 пресетов x 8 качеств) |
| `test_03_cookie_args` | Cookies (none/browser/file) |
| `test_04_integration` | Интеграционный: скрипт + mock yt-dlp |
| `test_05_cmd` | CMD-скрипт |
| `test_06_ps1` | PS1-скрипт |

Подробное описание: [tests/TESTING.md](tests/TESTING.md)

---

## Оставшиеся задачи

- Видеофильтры: шумоподавление, стабилизация, deband
- Цветокоррекция (eq-фильтр): контраст, яркость, насыщенность, гамма
- Софтверный пресет, профиль/уровень H.264, pixel format
- Алгоритм масштабирования (lanczos/bicubic), регулировка громкости
- Готовые пресеты для типичных сценариев
- Web GUI для обоих проектов (Node.js + Express + WebSocket)

Подробности: [PLAN.md](PLAN.md)
