# Video Tools

ffmpeg/yt-dlp скрипты для загрузки и конвертации видео. Каждый инструмент реализован на 3 платформах (.sh, .cmd, .ps1), включая GUI (WinForms) и сборку PS1 в EXE через ps2exe. 1479 автоматических тестов на чистом Bash (на платформах без CMD/PowerShell часть suite'ов пропускается).

---

## Структура проекта

```
video/
├── ffmpeg/                              # Конвертер видео/аудио
│   ├── config.ini                       # Настройки: кодеки, GPU, нарезка, фильтры
│   ├── FFmpeg_Converter_run_v16.sh      # Загрузчик конфига (Bash)
│   ├── FFmpeg_Converter_run_v16.cmd     # Загрузчик конфига (CMD)
│   ├── FFmpeg_Converter_run_v16.ps1     # Загрузчик конфига (PowerShell)
│   ├── FFmpeg_Converter_run_win_v16.ps1 # GUI (WinForms)
│   ├── FFmpeg_Converter_script.*        # Основная логика (.sh/.cmd/.ps1)
│   ├── build_exe.ps1                    # Сборка -> _VideoConverter_v16.exe
│   ├── ffmpeg.exe                       # Портативный ffmpeg (нужно скачать, см. ниже)
│   └── _VideoConverter_v16.exe          # Скомпилированный GUI
│
├── yt-dlp/                              # Загрузчик видео с YouTube и 1000+ сайтов
│   ├── config.ini.example               # Шаблон настроек (скопировать в config.ini)
│   ├── Downloading_from_YouTube_v16.sh  # CLI (Bash)
│   ├── Downloading_from_YouTube_v16.cmd # CLI (Windows)
│   ├── Downloading_from_YouTube_v16.ps1 # GUI (WinForms)
│   ├── build_exe.ps1                    # Сборка -> _VideoDownloader_v16.exe
│   ├── yt-dlp.exe                       # Загрузчик видео (нужно скачать, см. ниже)
│   ├── deno.exe                         # JS-runtime для vot-cli (опционально)
│   ├── vot-cli-live.exe                 # AI-перевод аудио через Яндекс (опционально)
│   └── _VideoDownloader_v16.exe         # Скомпилированный GUI
│
├── tests/                               # Автоматические тесты (1479 шт.)
│   ├── run_tests.sh                     # Точка входа
│   ├── lib/framework.sh                 # Assert-функции, форматированный вывод
│   ├── mocks/{ffmpeg,ffprobe,yt-dlp}    # Mock-бинарники
│   ├── ffmpeg/test_01..18*.sh           # 18 тест-файлов (617 тестов)
│   ├── yt-dlp/test_01..11*.sh           # 11 тест-файлов (454 тестов)
│   └── common/test_*.sh                 # 9 файлов (408 тестов): кодировки, паритет, guardrail'ы, pre-commit, privacy-scan
│
└── README.md
```

### Бинарники (не входят в репо)

Скачать и положить рядом со скриптами:

- **ffmpeg.exe / ffprobe.exe** — https://www.gyan.dev/ffmpeg/builds/ (full build), распаковать `bin/ffmpeg.exe` и `bin/ffprobe.exe` в `ffmpeg/`
- **yt-dlp.exe** — https://github.com/yt-dlp/yt-dlp/releases (последний `yt-dlp.exe`), положить в `yt-dlp/`
- **deno.exe** (опционально, для AI-перевода) — https://github.com/denoland/deno/releases (`deno-x86_64-pc-windows-msvc.zip`), положить в `yt-dlp/`
- **vot-cli-live.exe** (опционально, AI-перевод) — собирается из https://github.com/FOSWLY/vot-cli, положить в `yt-dlp/`

Перед первым запуском yt-dlp: `cp yt-dlp/config.ini.example yt-dlp/config.ini` и отредактировать под себя.

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
- **Batch:** загрузка каналов из channels.txt с задержками и архивом скачанного — **только SH** (`Downloading_from_YouTube_v16.sh`, флаг `--batch`); в CMD и GUI (PS1) batch-режима нет
- **Субтитры:** автоматическое скачивание (VTT)

**Формат channels.txt:** одна строка на канал, `category|handle|mode` (где `mode` = `videos` либо `playlists`, `handle` — без ведущего `@`). `category` задаёт подпапку для сохранения, строки с `#` игнорируются. Шаблон для копирования — [`yt-dlp/channels.txt.example`](yt-dlp/channels.txt.example) (скопировать в `yt-dlp/channels.txt`).

Дополнительные ключи в `config.ini` (yt-dlp):

| Секция | Ключ | Значения | Описание |
|--------|------|----------|----------|
| `[download]` | `audio_format` | `best` \| `mp3` \| `m4a` \| `opus` | Извлечение аудио в нужный формат при качестве «только аудио» |
| `[download]` | `sponsorblock` | `off` \| `mark` \| `remove` | SponsorBlock: вырезать/отметить рекламные и др. сегменты |
| `[subtitles]` | `download_with_video` | `off` \| `sidecar` \| `embed` | Скачивать субтитры вместе с видео — отдельным файлом или встроить |

---

## Архитектура: config.ini -> run -> script

Оба проекта используют одинаковый паттерн:

1. **`config.ini`** — пользовательские настройки. Формат: `+value` = включено, `-value` = выключено
2. **`run`** — читает config.ini, конвертирует в внутренний формат (`:+:value` / `:-:value`), запускает script
3. **`script`** — строит и выполняет команды ffmpeg/yt-dlp
4. **GUI** (`*_run_win.ps1`) — WinForms, читает config.ini для начальных значений контролов

Бинарники (ffmpeg, yt-dlp) автоматически определяются рядом со скриптом, затем в PATH. Относительные пути в config.ini разрешаются от директории скрипта.

**Исключение (по дизайну):** `yt-dlp/Downloading_from_YouTube_v16.cmd` — интерактивный CLI (спрашивает параметры в консоли) и **не читает `config.ini`**. Это санкционированное отклонение от config-driven паттерна: config-driven режим для yt-dlp даёт SH (`.sh`) и GUI (`.ps1`). Мета-тест `tests/common/test_config_keys.sh` учитывает это исключение (для yt-dlp ключ обязан читаться в `.sh` ИЛИ `.ps1`, CMD не требуется).

---

## Запуск

```bash
# FFmpeg Converter (из папки ffmpeg/)
bash FFmpeg_Converter_run_v16.sh

# YT-DLP Downloader (из папки yt-dlp/)
bash Downloading_from_YouTube_v16.sh

# GUI (Windows PowerShell)
powershell -File ffmpeg/FFmpeg_Converter_run_win_v16.ps1
powershell -File yt-dlp/Downloading_from_YouTube_v16.ps1

# Готовые EXE (собираются через build_exe.ps1)
ffmpeg/_VideoConverter_v16.exe
yt-dlp/_VideoDownloader_v16.exe
```

---

## Тестирование

1479 тестов на чистом Bash, без внешних зависимостей. Mock-бинарники для ffmpeg, ffprobe, yt-dlp. На платформах без CMD/PowerShell соответствующие suite'ы пропускаются (в CI это ошибка на Windows-линии, ожидаемо на Linux).

```bash
bash tests/run_tests.sh           # все тесты (1479)
bash tests/run_tests.sh ffmpeg    # ffmpeg (617 тестов, 18 файлов)
bash tests/run_tests.sh yt-dlp    # yt-dlp (454 тестов, 11 файлов)
bash tests/run_tests.sh common    # кросс-платформенные инварианты (408 тестов, 9 файлов)
```

### Тест-модули FFmpeg (18 файлов)

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
| `test_11_cmd_smoke` | CMD: smoke-тест |
| `test_12_cmd_run_parser` | CMD: парсер run-конфига |
| `test_13_parser_parity` | Кросс-парсерный паритет SH/PS1 read_config |
| `test_14_audio_only_codec` | audio_only: контейнер/кодек из `[audio] codec` |
| `test_15_findings` | Фиксы аудита: dry-run спецрежимов, маркер кадров, overwrite, коллизии |
| `test_16_gui_state` | GUI: воркер сообщает честный исход батча (success/failed/cancelled) |
| `test_17_literal_paths` | PS1: пути с `[ ]` в именах (литеральные, без wildcard-глоббинга) |
| `test_18_findings_audit` | Фиксы аудита: dry-run+overwrite не удаляет выход, merge in-place отклоняется, проверка финального rename, silence-настройки в signature |

### Тест-модули YT-DLP (11 файлов)

| Файл | Что тестирует |
|------|---------------|
| `test_01_read_config` | Парсинг config.ini |
| `test_02_format_args` | Пресеты форматов (7 пресетов x 8 качеств) |
| `test_03_cookie_args` | Cookies (none/browser/file) |
| `test_04_integration` | Интеграционный: скрипт + mock yt-dlp |
| `test_05_cmd` | CMD-скрипт |
| `test_06_ps1` | PS1-скрипт |
| `test_07_new_features` | audio_format / sponsorblock / субтитры с видео |
| `test_08_findings` | Фиксы аудита yt-dlp |
| `test_09_speed_profile` | `[network]`: профили скорости/устойчивости, паритет SH↔PS1 |
| `test_10_archive_skip_parity` | Archive-skip: batch (SH) и GUI (PS1) не выдают пропуск за загрузку |
| `test_11_findings_f4_f15` | Фиксы аудита F4/F6/F8/F9/F11/F13/F14/F15 (rename, dry-run+translate, vot exit code, ffprobe для dual_track, GUID-манифест, host-детект, схема URL, регистронезависимый config) |

### Тест-модули Common (9 файлов)

| Файл | Что тестирует |
|------|---------------|
| `test_framework_selfcheck` | Сам фреймворк: ассерты честны при `pipefail` (без ложной зелёнки) |
| `test_encoding` | Кодировки: `.ps1`=BOM, `.sh`=без BOM, entry `.cmd`=chcp |
| `test_config_keys` | Паритет ключей config.ini по платформам |
| `test_config_contract` | Контракт `config-key-contract.yaml` ↔ реальность (CI-safe) |
| `test_guardrails` | Статические guardrail'ы против регресса опасных паттернов |
| `test_path_matrix` | Adversarial имена/пути: Quote-WinArg + CMD `!`-детект |
| `test_ytdlp_preset_parity` | Паритет таблиц форматов yt-dlp SH ↔ PS1 |
| `test_pre_commit_hook` | pre-commit на реальном temp-репо: блок секрета, разрешение удаления утечки |
| `test_privacy_scan` | privacy-scan на реальном temp-репо: RFC1918 IP / e-mail, файлы с пробелами, `*.example` |

Подробное описание: [tests/TESTING.md](tests/TESTING.md)

---

## Публичный репозиторий: защита от утечек

Репозиторий публичный. Защита от коммита секретов/персональных данных — двухуровневая:

1. **Локальный pre-commit hook** [`.githooks/pre-commit`](.githooks/pre-commit): сканер форматов ключей/токенов, строк из локального denylist [`.sanitize-patterns`](.sanitize-patterns.example) (gitignored) и printable-строк внутри бинарных артефактов (EXE). После клона активировать одной командой:

   ```bash
   bash scripts/bootstrap-public-repo.sh     # Linux/macOS/Git Bash
   scripts\bootstrap-public-repo.cmd         # Windows
   ```

   Скрипт идемпотентен: включает `git config core.hooksPath .githooks` и заводит `.sanitize-patterns` из `.sanitize-patterns.example`.

2. **CI** [`.github/workflows/ci.yml`](.github/workflows/ci.yml): работает для web-commit, PR и форков, где локальный hook не запускается. Линии: Linux (Bash + инварианты), macOS (Bash 3.2/BSD — портируемость SH), secret-scan всей истории (gitleaks) + privacy-scan генерик-PII ([`tools/privacy-scan.sh`](tools/privacy-scan.sh): приватные IPv4 RFC1918 и e-mail — то, что раньше ловил лишь локальный denylist), Windows (полный SH/CMD/PS1 паритет с `STRICT_SKIP=1` — пропуск платформенного suite'а = ошибка; сборка EXE; сверка `.sha256` и треугольника manifest↔EXE↔sidecar).

   Конкретные внутренние значения (домены, хосты, ФИО) остаются в локальном denylist — они приватны и в публичный CI-конфиг не выносятся; generic-паттерны (форматы ключей, RFC1918, e-mail) теперь покрыты всегда-включёнными линиями CI.

## Сборка EXE (опционально)

Скрипты собираются в `.exe` через [ps2exe](https://github.com/MScholtes/PS2EXE):

```powershell
powershell -File ffmpeg/build_exe.ps1
powershell -File yt-dlp/build_exe.ps1
```

`ps2exe.ps1` вендорится в `tools/` (закреплённый коммит + проверка SHA256 перед dot-source, без скачивания на лету). См. [tools/README.md](tools/README.md).
