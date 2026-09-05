# Video Tools

ffmpeg/yt-dlp скрипты для загрузки и конвертации видео. Каждый инструмент реализован на 3 платформах (.sh, .cmd, .ps1), включая GUI (WinForms) и сборку PS1 в EXE через ps2exe. Автоматические тесты на чистом Bash — актуальное число печатает раннер `bash tests/run_tests.sh` (на платформах без CMD/PowerShell часть suite'ов пропускается, поэтому итог зависит от платформы).

---

## Структура проекта

```
video/
├── ffmpeg/                              # Конвертер видео/аудио
│   ├── config.ini.example               # Шаблон настроек (скопировать в config.ini)
│   ├── FFmpeg_Converter_run_v18.sh      # Загрузчик конфига (Bash)
│   ├── FFmpeg_Converter_run_v18.cmd     # Загрузчик конфига (CMD)
│   ├── FFmpeg_Converter_run_v18.ps1     # Загрузчик конфига (PowerShell)
│   ├── FFmpeg_Converter_run_win_v18.ps1 # GUI (WinForms)
│   ├── FFmpeg_Converter_script.*        # Основная логика (.sh/.cmd/.ps1)
│   ├── build_exe.ps1                    # Сборка -> _VideoConverter_v18.exe
│   ├── ffmpeg.exe                       # Портативный ffmpeg (нужно скачать, см. ниже)
│   ├── remote_client.*                  # Клиент удалённого бэкенда (.sh/.ps1)
│   └── _VideoConverter_v18.exe          # Скомпилированный GUI
│
├── yt-dlp/                              # Загрузчик видео с YouTube и 1000+ сайтов
│   ├── config.ini.example               # Шаблон настроек (скопировать в config.ini)
│   ├── Downloading_from_YouTube_v18.sh  # CLI (Bash)
│   ├── Downloading_from_YouTube_v18.cmd # CLI (Windows)
│   ├── Downloading_from_YouTube_v18.ps1 # GUI (WinForms)
│   ├── build_exe.ps1                    # Сборка -> _VideoDownloader_v18.exe
│   ├── yt-dlp.exe                       # Загрузчик видео (нужно скачать, см. ниже)
│   ├── ffmpeg.exe / ffprobe.exe         # Нужны для мержа дорожек и AI-перевода
│   ├── deno.exe                         # JS-рантайм ДЛЯ yt-dlp (YouTube), не для vot
│   ├── vot-cli-live.exe                 # AI-перевод аудио через Яндекс (опционально)
│   └── _VideoDownloader_v18.exe         # Скомпилированный GUI
│
├── tests/                               # Автоматические тесты
│   ├── run_tests.sh                     # Точка входа
│   ├── lib/framework.sh                 # Assert-функции, форматированный вывод
│   ├── mocks/                           # ffmpeg, ffmpeg.cmd, ffprobe, yt-dlp, curl, vot-cli-live
│   ├── ffmpeg/test_01..24*.sh           # 24 тест-файла
│   ├── yt-dlp/test_01..15*.sh           # 15 тест-файлов
│   └── common/test_*.sh                 # 11 файлов: кодировки, паритет, guardrail'ы, ссылки в документации, pre-commit, privacy-scan, вырезание комментариев при сборке
│
└── README.md
```

### Бинарники (не входят в репо)

Каждая сторона ищет инструменты **рядом со своим скриптом**, затем в `PATH`. Поэтому
раскладка разная, и «положить всё в одну папку» не работает:

| Инструмент | Куда класть | Зачем он там | Что без него не работает |
|---|---|---|---|
| `ffmpeg.exe` | `ffmpeg/` | конвертация | ffmpeg-сторона не работает вовсе (кроме тонкого клиента с `[remote] enabled = yes`) |
| `ffmpeg.exe` | `yt-dlp/` | склейка `video+audio` и мерж дорожки перевода | все `+`-пресеты отдают немерженные потоки; AI-перевод невозможен |
| `ffprobe.exe` | `yt-dlp/` | подсчёт аудиодорожек | режим перевода «2 дорожки» (`dual_track`) |
| `yt-dlp.exe` | `yt-dlp/` | загрузка | загрузка невозможна |
| `deno.exe` | `yt-dlp/` | **JS-рантайм для самого yt-dlp** | YouTube с 2025.11 требует внешний JS-рантайм: загрузки деградируют или падают. Нужен всем, а не только тем, кто пользуется переводом |
| `vot-cli-live.exe` | `yt-dlp/` | AI-перевод | нет AI-перевода. Нужен именно `.exe`: npm-шим (`.cmd`) запустить напрямую нельзя |

В `ffmpeg/` **`ffprobe.exe` не нужен** — эта сторона его не вызывает.
Проверить раскладку одной командой:
`bash yt-dlp/Downloading_from_YouTube_v18.sh --doctor` и
`bash ffmpeg/FFmpeg_Converter_run_v18.sh --doctor`.

Ссылки:

- **ffmpeg / ffprobe** — https://www.gyan.dev/ffmpeg/builds/ (full build), из архива нужны `bin/ffmpeg.exe` и `bin/ffprobe.exe`
- **yt-dlp** — https://github.com/yt-dlp/yt-dlp/releases (последний `yt-dlp.exe`)
- **deno** — https://github.com/denoland/deno/releases (`deno-x86_64-pc-windows-msvc.zip`)
- **vot-cli-live** — собирается из https://github.com/FOSWLY/vot-cli

Перед первым запуском скопировать шаблоны конфигов и отредактировать под себя:

```bash
cp ffmpeg/config.ini.example ffmpeg/config.ini
cp yt-dlp/config.ini.example yt-dlp/config.ini
```

Оба `config.ini` в `.gitignore` — в них попадают приватные значения (прокси
с логином и паролем, адрес и ключ службы конвертации), а репозиторий публичный.

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

#### Удалённый счёт на сервере конвертации

При `[remote] enabled = yes` кодирование уезжает на HTTP-службу конвертации, а
обход папок, имена выходов и учёт готового остаются локальными. Адрес и ключ
пишутся в `[remote] endpoint` и `api_key` вашего `config.ini` — он не коммитится,
поэтому значения можно вписать как есть. Подстановка из окружения тоже работает
(`endpoint = ${TRANSCODE_URL}`), если ключ удобнее держать вне файла.

**Версия API входит в адрес.** Клиент запрашивает `<endpoint>/capabilities`,
`<endpoint>/uploads`, `<endpoint>/jobs`, а служба слушает `/v1/...` — поэтому
`endpoint` обязан оканчиваться на `/v1` (`https://transcode.example.com/v1`).
Адрес без версии даёт HTTP 404 на первом же запросе; клиент предупреждает об
этом до запроса и объясняет 404, если он всё же пришёл.

Ключ можно вовсе не хранить в файле: `[remote] api_key_command = pass show …`
берёт его со stdout команды один раз, в предпусковой проверке. Приоритет —
`api_key_command`, затем `api_key`.

`[remote] on_failure` задаёт поведение при недоступной службе: `abort`
(умолчание — файл получает ошибку) либо `local` (файл считается локальным
ffmpeg). Откат при `local` не молчаливый: печатается причина, в сводке
появляется строка «Посчитано локально: N», а код возврата становится ненулевым.

`--remote-selftest` прогоняет удалённый путь целиком на пробном ролике в
мегабайт (preflight → печать запрашиваемых URL → загрузка → холостой прогон →
боевая задача → скачивание → проверка) и печатает таблицу «шаг / итог / время».
Стоит запускать после смены адреса или ключа: иначе первый настоящий контакт со
службой происходит на пакете из двухсот файлов.

В GUI адрес и ключ — в группе «Сервер конвертации» внутри свёрнутого блока
«Дополнительные настройки»; ключ на экране замаскирован. Правка в полях действует
на текущий запуск, конфиг GUI не переписывает. `api_key_command` и `on_failure`
своих полей не имеют — читаются из `config.ini`.

Локальный `ffmpeg` на удалённом пути перестал быть обязательным: без него
скрипт продолжает работу и предупреждает, что отключены проверка скачанного
результата (остаётся проверка на непустой файл) и определение длительности.
`split_by_silence = yes` без локального ffmpeg отклоняется явно — границы тишины
читает `silencedetect`, и брать их у службы значило бы завести второй источник
правды.

Уезжает только то, где выигрывает карта: обычное перекодирование и отрезки.
Режимы `copy_codecs`, `merge_files`, `create_frame`, `audio_only` и
`extract_audio_copy` считаются локально — карта в них не участвует.

Доступно в `.sh`, `.ps1` и GUI. В `.cmd` режим не поддерживается: в cmd.exe нет
нарезки файла по смещениям, sha256 и разбора JSON — там печатается
предупреждение, и файлы считаются локально.

### YT-DLP Downloader

- **Качество:** 360p-4K, 7 пресетов формата: `avc1_best`, `avc1_https`, `avc1_m3u8`, `avc1_https_60fps`, `avc1_m3u8_60fps`, `avc1_https_60fps_hdr`, `old_combo` (актуальный список печатает `--help`)
- **Cookies:** без / из браузера (Chrome, Firefox, Edge) / из файла
- **Прокси:** `http`, `https`, `socks4`, `socks4a`, `socks5`, `socks5h`; с авторизацией и без. Формат: `[схема]://[user:pass@]host[:port]`
- **AI-перевод аудио:** 3 режима — dual_track, replace, mix
- **Плейлисты:** `[download] playlist = auto|single|full` либо флаги `--no-playlist` / `--yes-playlist`
- **Диагностика:** `--doctor` — какие инструменты найдены, где и что без каждого не работает
- **Batch:** загрузка каналов из channels.txt с задержками и архивом скачанного — **только SH** (`Downloading_from_YouTube_v18.sh`, флаг `--batch`); в CMD и GUI (PS1) batch-режима нет
- **Субтитры:** авторские и автоматические (`--write-subs --write-auto-subs`); формат из `[subtitles] format` — у YouTube нативно доступен `vtt`

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

**Исключение (по дизайну):** `yt-dlp/Downloading_from_YouTube_v18.cmd` — интерактивный CLI (спрашивает параметры в консоли) и **не читает `config.ini`**. Это санкционированное отклонение от config-driven паттерна: config-driven режим для yt-dlp даёт SH (`.sh`) и GUI (`.ps1`). Мета-тест `tests/common/test_config_keys.sh` учитывает это исключение (для yt-dlp ключ обязан читаться в `.sh` ИЛИ `.ps1`, CMD не требуется).

---

## Запуск

```bash
# FFmpeg Converter (из папки ffmpeg/)
bash FFmpeg_Converter_run_v18.sh

# YT-DLP Downloader (из папки yt-dlp/)
bash Downloading_from_YouTube_v18.sh

# GUI (Windows PowerShell)
powershell -File ffmpeg/FFmpeg_Converter_run_win_v18.ps1
powershell -File yt-dlp/Downloading_from_YouTube_v18.ps1

# Готовые EXE (собираются через build_exe.ps1)
ffmpeg/_VideoConverter_v18.exe
yt-dlp/_VideoDownloader_v18.exe
```

---

## Тестирование

Тесты на чистом Bash, без внешних зависимостей. Mock-бинарники для ffmpeg, ffprobe, yt-dlp. Единственный источник числа тестов — сам раннер: конкретные числа в документации не приводятся, потому что устаревают при каждом новом assert и зависят от платформы. На платформах без CMD/PowerShell соответствующие suite'ы пропускаются (в CI это ошибка на Windows-линии, ожидаемо на Linux).

```bash
bash tests/run_tests.sh           # все тесты
bash tests/run_tests.sh ffmpeg    # ffmpeg (24 файла)
bash tests/run_tests.sh yt-dlp    # yt-dlp (15 файлов)
bash tests/run_tests.sh common    # кросс-платформенные инварианты (11 файлов)
```

### Тест-модули FFmpeg (24 файла)

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
| `test_19_findings_paths` | Пути и выборка входов: хвостовой разделитель source, прямые слэши, каталог «season.mp4», dry-run без mkdir, `.ffconv-partial-*`, суффикс `(part.1)` в проверке in==out, диапазон скорости и overwrite в GUI |
| `test_20_remote_map` | Удалённый бэкенд: отображение config.ini на операции службы (.sh) |
| `test_21_remote_client` | Удалённый бэкенд: HTTP-слой, preflight, загрузка кусками, задача и отмена (мок curl) |
| `test_22_remote_ps1` | Удалённый бэкенд: PS1-модуль клиента, загрузка через подменённый HTTP-слой |
| `test_23_remote_parity` | Удалённый бэкенд: SH и PS1 собирают побайтово одинаковый JSON |
| `test_24_gui_worker_runspace` | Воркер запускается ТАК ЖЕ, как из GUI (AddScript-строка): `$PSScriptRoot` пуст, stderr не оседает в `Streams.Error` |

### Тест-модули YT-DLP (15 файлов)

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
| `test_12_findings_cli` | `$qi` до манифеста, preflight AI-перевода, URL-валидация и громкости mix в CMD |
| `test_13_path_limit` | Лимит длины пути (MAX_PATH): бюджет от базовой папки, одинаковый результат в SH/PS1/CMD |
| `test_14_stop_and_window` | «Остановить» снимает дерево процессов; свёрнутое окно не трогаем |
| `test_15_cmd_smoke` | Сквозной прогон интерактивного `.cmd` целиком: меню, argv дочерних процессов, коды возврата (моки — настоящие EXE) |

### Тест-модули Common (11 файлов)

| Файл | Что тестирует |
|------|---------------|
| `test_framework_selfcheck` | Сам фреймворк: ассерты честны при `pipefail` (без ложной зелёнки) |
| `test_encoding` | Кодировки: `.ps1`=BOM, `.sh`=без BOM, entry `.cmd`=chcp |
| `test_config_keys` | Паритет ключей config.ini по платформам |
| `test_config_contract` | Контракт `config-key-contract.yaml` ↔ реальность (CI-safe) |
| `test_guardrails` | Статические guardrail'ы против регресса опасных паттернов |
| `test_path_matrix` | Adversarial имена/пути: Quote-WinArg + CMD `!`-детект |
| `test_ytdlp_preset_parity` | Паритет таблиц форматов yt-dlp SH ↔ PS1 |
| `test_build_strip` | Комментарии не попадают в собранный EXE: сборка зовёт вырезание, вырезание не трогает код и строки |
| `test_pre_commit_hook` | pre-commit на реальном temp-репо: блок секрета, разрешение удаления утечки |
| `test_privacy_scan` | privacy-scan на реальном temp-репо: RFC1918 IP / e-mail, файлы с пробелами и кириллицей, `*.example` |
| `test_docs_links` | Ссылки и пути в документации ведут на существующие файлы; имена EXE в CI ↔ файлы на диске |

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
