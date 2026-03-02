# Video Tools — Описание проектов

Два независимых набора скриптов для работы с видео: загрузка и конвертация.

---

## 1. yt-dlp/ — Загрузчик видео с YouTube и других платформ

**Назначение:** Скачивание видео/аудио/субтитров с YouTube и 1000+ других сайтов (через yt-dlp).
Включает AI-перевод аудиодорожки через Яндекс (vot-cli-live).

### Скрипты

| Файл | Описание |
|------|----------|
| `Downloading_from_YouTube_v11.sh` | CLI-скрипт (Linux/macOS/Git Bash). Режимы: одиночная загрузка, batch (каналы из channels.txt), субтитры, AI-перевод |
| `Downloading_from_YouTube_v11.cmd` | Интерактивный CLI для Windows с меню выбора качества, cookies, перевода |
| `Downloading_from_YouTube_v11.ps1` | GUI для Windows (WinForms): очередь URL, прогресс-бар, RichTextBox-лог, все настройки |
| `config.ini` | Общий конфиг: прокси, cookies, качество, шаблоны путей, batch-настройки, AI-перевод |
| `build_exe.ps1` | Сборка PS1 -> VideoDownloader.exe через ps2exe |

### Возможности

- **Качество:** 360p-4K, пресеты (avc1_best, avc1_https, m3u8, 60fps, HDR, old_combo)
- **Cookies:** без / из браузера (Chrome, Firefox, Edge) / из файла
- **Прокси:** HTTPS с авторизацией
- **AI-перевод аудио:** 3 режима — 2 дорожки (dual_track), замена (replace), микс (mix)
- **Batch:** загрузка каналов из channels.txt с задержками и архивом скачанного
- **Вывод:** цветной лог, итоговая сводка (ok/fail/skip/время)

### Бинарные зависимости (в папке)

| Файл | Назначение |
|------|------------|
| `yt-dlp.exe` | Загрузчик видео |
| `deno.exe` | JS-runtime для плагинов yt-dlp |
| `vot-cli-live.exe` | AI-перевод аудио через Яндекс (портативный, без Node.js) |
| `VideoDownloader.exe` | Скомпилированный GUI |

### Статус

Все запланированные функции (секции A-G) реализованы. Остался Web GUI (секция H).
Подробности: [yt-dlp/PLAN.md](yt-dlp/PLAN.md)

---

## 2. ffmpeg/ — Конвертер видео/аудио

**Назначение:** Пакетная конвертация видео и аудио файлов через ffmpeg.
Поддержка GPU-ускорения (NVIDIA NVENC, Intel QSV), нарезки, субтитров, изменения скорости.

### Скрипты

| Файл | Описание |
|------|----------|
| `FFmpeg_Converter_run.sh` | Конфигурация (настройки) для Linux/macOS/Git Bash |
| `FFmpeg_Converter_script.sh` | Основной скрипт обработки (bash) |
| `FFmpeg_Converter_run.cmd` | Конфигурация для Windows (CMD) |
| `FFmpeg_Converter_script.cmd` | Основной скрипт обработки (CMD) |
| `FFmpeg_Converter_run.ps1` | Конфигурация для PowerShell CLI |
| `FFmpeg_Converter_script.ps1` | Основной скрипт обработки (PowerShell) |
| `FFmpeg_Converter_run_win.ps1` | GUI для Windows (WinForms): все настройки, прогресс, версии |
| `build_exe.ps1` | Сборка PS1 -> VideoConverter.exe через ps2exe |

### Архитектура: run + script

Настройки задаются в `run`-файле (формат `:+:value` = включено, `:-:value` = выключено).
`run` вызывает `script`, который выполняет обработку. GUI (`run_win.ps1`) заменяет оба файла.

### Возможности

- **Видеокодеки:** libx264, libx265, libsvtav1, h264_nvenc, hevc_nvenc, av1_nvenc, h264_qsv
- **GPU-ускорение:** NVIDIA NVENC (пресеты p1-p7, tune, rate control) и Intel QSV
- **Аудиокодеки:** aac, libmp3lame + нормализация (loudnorm, dynaudnorm)
- **Режимы:** только аудио, объединение файлов, извлечение кадров, копирование без перекодирования, извлечение аудио без перекодирования
- **Нарезка:** по времени, по тишине (silencedetect), с привязкой к ближайшей паузе
- **Фильтры:** масштабирование (с сохранением пропорций), поворот, субтитры (burn/meta), скорость воспроизведения
- **Постоянное качество:** CRF (программные кодеки), CQ (NVENC), global_quality (QSV)
- **Контейнеры:** mp4, mkv, webm, avi, ts
- **CLI-прогресс:** прогресс-бар через `-progress pipe:1` (bash, ps1)
- **Итоговая сводка:** ok/fail/skip, время, входной/выходной размер, процент сжатия
- **Dry-run:** просмотр команд без запуска
- **Логирование:** в файл с таймстампами

### Бинарные зависимости

| Файл | Назначение |
|------|------------|
| `VideoConverter.exe` | Скомпилированный GUI |

ffmpeg/ffprobe должны быть в PATH или указаны в настройках.

### Статус

Все запланированные функции (секции A-J) реализованы. Остался Web GUI (секция H).
Подробности: [ffmpeg/PLAN.md](ffmpeg/PLAN.md)

---

## Общее

### Общие паттерны обоих проектов

- **3 платформы:** .sh (Linux/macOS/Git Bash), .cmd (Windows), .ps1 (Windows GUI)
- **Формат настроек ffmpeg:** `:+:value` (включено) / `:-:value` (выключено)
- **GUI:** WinForms (PowerShell) + сборка в EXE через ps2exe
- **Кодировка:** UTF-8 + BOM для .ps1, UTF-8 без BOM для .sh, chcp 65001 для .cmd

### Общие оставшиеся задачи

| # | Проект | Задача | Описание |
|---|--------|--------|----------|
| 1 | yt-dlp | channels.txt | Пример файла списка каналов для batch-загрузки |
| 2 | yt-dlp | parse-vtt.py | Python-парсер VTT -> текст |
| 3 | yt-dlp | Web GUI | Node.js + Express + WebSocket (порт 3100) |
| 4 | ffmpeg | Web GUI | Node.js + Express + WebSocket (порт 3200) |

Web GUI для обоих проектов должен использовать единый дизайн (тёмная тема, GitHub-стиль).
