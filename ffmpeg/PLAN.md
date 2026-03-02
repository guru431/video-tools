# FFmpeg Converter — План улучшений

> Все изменения реализуются на трёх платформах: **Bash** (.sh), **CMD** (.cmd), **PowerShell** (.ps1 + GUI)

## Текущее состояние (актуализировано 2026-03-03)

Секции A-G, I, J полностью реализованы. Осталась только секция H (Web GUI).

| Скрипт | Платформа | Назначение | Статус |
|--------|-----------|------------|--------|
| FFmpeg_Converter_run.sh | Linux/macOS/Git Bash | Конфигурация (настройки) | ГОТОВ |
| FFmpeg_Converter_script.sh | Linux/macOS/Git Bash | Основной скрипт обработки | ГОТОВ |
| FFmpeg_Converter_run.cmd | Windows | Конфигурация (настройки) | ГОТОВ |
| FFmpeg_Converter_script.cmd | Windows | Основной скрипт обработки | ГОТОВ |
| FFmpeg_Converter_run.ps1 | Windows | Конфигурация (PowerShell CLI) | ГОТОВ |
| FFmpeg_Converter_script.ps1 | Windows | Основной скрипт (PowerShell CLI) | ГОТОВ |
| FFmpeg_Converter_run_win.ps1 | Windows | GUI (WinForms) | ГОТОВ |
| build_exe.ps1 | Windows | Сборка PS1 -> EXE через ps2exe | ГОТОВ |
| VideoConverter.exe | Windows | Скомпилированный GUI | ГОТОВ |

---

## A-G, I, J. Реализованные секции

### A. Критические баги — ВЫПОЛНЕНО
- **A1.** `audio_only` режим: `video_settings` формируется внутри `else`-ветки, аудио-режим работает корректно
- **A2.** GUI: видеокодек берётся из правильного комбобокса (GUI полностью переписан)
- **A3.** Bash: пути используют прямые слэши (`/`)
- **A4.** Bash: арифметика с float через `awk` вместо `$(())`
- **A5.** PowerShell: аргументы собираются в массив `$ffmpegArgs`, вызов через `& $ffmpeg @ffmpegArgs`
- **A6.** CMD: `chcp 65001` в начале файла для UTF-8

### B. Неработающий функционал — ВЫПОЛНЕНО
- **B1a.** Многопоточность: `-threads $threads` передаётся в ffmpeg
- **B1b.** Параллельная обработка: `parallel_files` + `xargs -P` (bash) / `Start-Job` (PS)
- **B2.** Стиль субтитров: `force_style='$subtitles_style'` при `video_subtitles=burn`

### C. Аппаратное ускорение — ВЫПОЛНЕНО
- **C1.** Настройка `hw_accel`: поддержка `nvidia` (NVENC/CUVID) и `intel` (QSV)
- **C1a.** Аппаратное декодирование: `-hwaccel cuda -hwaccel_output_format cuda`
- **C1b.** Автоматический маппинг кодеков: libx264->h264_nvenc, libx265->hevc_nvenc, libsvtav1->av1_nvenc
- **C1c.** GPU-масштабирование: `scale_cuda`, `scale_qsv`
- **C1d.** `hwdownload` при использовании CPU-фильтров с GPU-декодированием
- **C2.** Настройки NVENC: preset (p1-p7), tune (hq/ll/ull/lossless), rc (constqp/vbr/cbr)
- **C3.** CQ (аналог CRF) для NVENC: `-cq`, `-global_quality` для QSV

### D. Расширение функционала — ВЫПОЛНЕНО
- **D1.** Современные кодеки: libx265, libsvtav1, h264_nvenc, hevc_nvenc, av1_nvenc, h264_qsv
- **D2.** Постоянное качество: `-crf` (программные), `-cq` (NVENC), `-global_quality` (QSV)
- **D3.** Выходной контейнер: mp4, mkv, webm, avi, ts
- **D4.** Сохранение пропорций: `force_original_aspect_ratio=decrease,pad`
- **D5.** Нормализация звука: `loudnorm` (EBU R128), `dynaudnorm`
- **D6.** Скорость воспроизведения: `setpts=PTS/$speed` + `atempo` (с каскадом для >2x/<0.5x)
- **D7.** Dry-run: `dry_run=yes` выводит команду без запуска
- **D8.** Логирование: `enable_log=yes` + `log_file` с таймстампами

### E. Улучшения стабильности — ВЫПОЛНЕНО
- **E1.** Проверка окружения: существование папок, доступность ffmpeg, проверка NVENC/QSV
- **E2.** Обработка ошибок: проверка exit code, удаление битых выходных файлов
- **E3.** Проверка валидности: `ffprobe` для проверки существующих файлов перед пропуском
- **E4.** ffprobe: получение битрейта и длительности через `ffprobe` вместо парсинга stderr
- **E5.** Сборка цепочки фильтров: единая переменная `vf_chain` и `af_chain`

### F. Обновления GUI (PowerShell WinForms) — ВЫПОЛНЕНО
- **F1.** Новые элементы управления: GPU-ускорение, пресеты, контейнер, CRF, скорость, нормализация, сохранение пропорций, dry-run, логирование, расширенный список кодеков
- **F2.** Прогресс-бар, версия ffmpeg в шапке, кнопка обновления

### I. Извлечение аудио без перекодирования — ВЫПОЛНЕНО
- **I1.** Настройка `extract_audio_copy=yes` во всех run-файлах
- **I2.** Автоопределение аудио-кодека через ffprobe, подбор расширения (m4a/mp3/opus/ogg/flac/wav/mka)
- **I3.** `ffmpeg -i "$input" -vn -c:a copy "$output"` — копирование без перекодирования
- **I4.** Взаимоисключение с `audio_only` и `copy_codecs`

### J. CLI-улучшения — ВЫПОЛНЕНО
- **J1.** Прогресс-бар в CLI (bash, ps1): `-progress pipe:1` + парсинг `out_time_ms` + `printf \r`
- **J2.** Итоговая сводка: ok/fail/skip, время, входной/выходной размер, процент сжатия (все 3 платформы)

---

## H. Современный Web GUI (HTML/CSS/JS + Node.js Express) — НЕ РЕАЛИЗОВАНО

> Заменяет WinForms-интерфейс (`FFmpeg_Converter_run_win.ps1`) на кроссплатформенный веб-интерфейс

### H1. Архитектура

- **Backend:** Node.js + Express (HTTP-сервер + REST API)
- **Реальное время:** WebSocket (npm `ws`) для стриминга вывода ffmpeg и прогресса
- **Запуск ffmpeg:** `child_process.spawn` с `-progress pipe:1`
- **Frontend:** ванильный HTML/CSS/JS (без фреймворков)
- **Порт:** `http://localhost:3200`

### H2. Структура файлов

```
ffmpeg/gui/
├── package.json          # express, ws, open
├── server.js             # Express + WebSocket + child_process
├── config-parser.js      # Чтение/запись :+:/:-: настроек из run-файлов
└── public/
    ├── index.html        # Единственная HTML-страница
    ├── style.css         # Тёмная тема, анимации
    └── app.js            # WebSocket-клиент, UI-логика, state
```

### H3. API endpoints (server.js)

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/` | Статические файлы (public/) |
| GET | `/api/config` | Текущие настройки (из state или run-файла) -> JSON |
| POST | `/api/config` | Сохранить настройки |
| GET | `/api/versions` | `{ ffmpeg, ffprobe, node }` |
| POST | `/api/convert` | Запустить конвертацию с параметрами из JSON |
| POST | `/api/stop` | Остановить текущий процесс ffmpeg |
| GET | `/api/state` | Читает gui_state.json |
| POST | `/api/state` | Сохраняет gui_state.json |
| POST | `/api/browse` | Диалог выбора папки (через PowerShell/zenity) |
| WebSocket | `/ws` | Стриминг stdout/stderr ffmpeg + прогресс -> клиенту |

### H4. Логика конвертации

1. Принимает JSON со всеми настройками (аналог переменных из run-файлов)
2. Сканирует папку-источник, фильтрует по `format_files_in`
3. Собирает аргументы ffmpeg (вся логика из FFmpeg_Converter_script)
4. Запускает ffmpeg с `-progress pipe:1` для отслеживания прогресса
5. Для каждого файла: spawn ffmpeg, стримить прогресс через WebSocket
6. Получает длительность через ffprobe -> вычисляет процент по `out_time_ms`
7. По завершении каждого файла — обновляет счётчик (3/15 файлов)
8. Итоговая сводка после обработки всех файлов

WebSocket-сообщения (JSON):
```json
{ "type": "progress", "file": "video.mp4", "percent": 67, "fileNum": 3, "totalFiles": 15 }
{ "type": "log", "level": "info", "message": "Кодирование: video.mp4" }
{ "type": "done", "file": "video.mp4", "duration": "1m 23s", "status": "ok" }
{ "type": "summary", "ok": 12, "fail": 1, "skip": 2, "inputSize": "8.2 GB", "outputSize": "2.1 GB", "time": "4m 23s" }
```

### H5. Интерфейс (public/index.html)

```
+-------------------------------------------------------------+
|  FFmpeg Converter                      v1.0 | ffmpeg 7.1    |
+-------------------------------------------------------------+
|                                                               |
|  Входная папка:  [/path/to/input___________] [...]           |
|  Выходная папка: [/path/to/output__________] [...]           |
|                                                               |
|  +- Опции ------------------------------------------------+  |
|  | [ ]Только аудио  [ ]Объединить   [ ]Кадры              |  |
|  | [ ]Без перекод.  [x]Потоки:[4]   [ ]Dry-run            |  |
|  | [ ]Лог           [x]Пропорции                          |  |
|  | [ ]Извлечь аудио (без перекодирования)                  |  |
|  |                                                         |  |
|  | GPU: [Без ускорения v]                                  |  |
|  |      Пресет:[p5 v] Tune:[hq v] RC:[vbr v]              |  |
|  +----------------------------------------------------------+ |
|                                                               |
|  +- Аудио ---------------+  +- Видео -------------------+   |
|  | [x]Кодек: [aac v]     |  | [x]Кодек: [libx264 v]    |   |
|  | [x]Каналы: [2 v]      |  | [x]Разрешение:[1280x720v]|   |
|  | [x]Битрейт: [128]     |  | [x]Битрейт: [2000]       |   |
|  | [x]Частота: [44100]    |  | [x]Кадры/с: [25]         |   |
|  | [ ]Норм: [loudnorm v] |  | [ ]CRF: [23]             |   |
|  +------------------------+  | [ ]Поворот: [Против v]   |   |
|                               | [ ]Субтитры: [burn v]    |   |
|                               | [ ]Контейнер: [mp4 v]    |   |
|                               +---------------------------+  |
|                                                               |
|  +- Скорость -+ +- Разрез ----------------------------+      |
|  |[ ] [1.0]   | |[ ]Начало:[01-00-00] [ ]Длит:[00-05-00]|    |
|  +-------------+ |[ ]По тишине  Мин:[2.0]  Порог:[-30dB]|    |
|                   +---------------------------------------+   |
|                                                               |
|  [> Начать]  [# Стоп]  [Очистить]                            |
|                                                               |
|  ================== video.mp4  3/15 файлов                    |
|                                                               |
|  +- Лог -------------------------------------------------+   |
|  | [OK]   input1.mp4 -> output1.mp4 (1m 23s)             |   |
|  | [INFO] Кодирование: input2.mp4                         |   |
|  | [FAIL] broken.avi (exit code 1)                        |   |
|  +--------------------------------------------------------+   |
|                                                               |
|  +========================================================+  |
|  | Обработано: 12 | Ошибки: 1 | Время: 4m 23s             |  |
|  | Вход: 8.2 GB -> Выход: 2.1 GB (сжатие 74%)             |  |
|  +=========================================================+ |
+---------------------------------------------------------------+
```

Чекбоксы `[x]`/`[ ]` управляют активностью параметра (аналог `:+:`/`:-:` в run-файлах).
GPU-настройки скрыты по умолчанию — появляются при выборе GPU-ускорения.

### H6. Прогресс-бар

1. Перед началом: получить длительность каждого файла через ffprobe
2. Во время кодирования: ffmpeg с `-progress pipe:1`, стримит `out_time_ms` через WebSocket
3. На клиенте: прогресс-бар с анимацией shimmer, текущий файл, счётчик файлов
4. Итоговая сводка: ok/fail/skip, размеры, время, процент сжатия

### H7. Сохранение состояния (gui_state.json)

При каждом изменении настроек -> `POST /api/state` -> сохранение в `gui/gui_state.json`:
```json
{
  "folderSources": "m:/ffmpeg/0",
  "folderDestination": "m:/ffmpeg/1",
  "audioOnly": false,
  "mergeFiles": false,
  "audioCodec": { "enabled": true, "value": "aac" },
  "videoCodec": { "enabled": true, "value": "libx264" },
  "hwAccel": "off",
  "...": "..."
}
```

### H8. Дизайн и тема

Единый стиль с yt-dlp GUI:
- **Фон:** `#0d1117` (основной), `#161b22` (карточки)
- **Бордеры:** `#30363d`
- **Акценты:** `#58a6ff` (ссылки), `#238636` (успех), `#da3633` (ошибки/стоп)
- **Углы:** `border-radius: 8-12px`, тени `0 2px 8px rgba(0,0,0,0.3)`
- **Шрифт:** `system-ui, -apple-system, sans-serif`
- **Лог:** `Consolas / JetBrains Mono`, фон `#0d1117`
- **Прогресс-бар:** CSS-анимация shimmer, градиент `#4ade80 -> #22d3ee`

### H9. config-parser.js

Парсер формата `:+:`/`:-:` из run-файлов:
- `readConfig(filePath)` -> объект с настройками, включая enabled-флаг
- Пример: `:+:aac` -> `{ enabled: true, value: "aac" }`, `:-:loudnorm` -> `{ enabled: false, value: "loudnorm" }`

### H10. Порядок реализации GUI

1. Инициализация: package.json, установка зависимостей
2. config-parser.js — чтение/запись `:+:`/`:-:` формата
3. server.js — Express + WebSocket + REST API
4. public/index.html — все настройки из текущего GUI (run_win.ps1)
5. public/style.css — тёмная тема, анимации
6. public/app.js — WebSocket-клиент, управление состоянием
7. Логика конвертации: сборка аргументов ffmpeg на сервере
8. Прогресс-бар: ffprobe duration + `-progress pipe:1` + WebSocket
9. Итоговая сводка после обработки
10. Версии + обновление
11. Сохранение/восстановление состояния
12. Тестирование: все режимы, GPU, split, merge, audio_only

---

## Источники

- [NVIDIA Video Codec SDK — FFmpeg с GPU-ускорением](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/ffmpeg-with-nvidia-gpu/index.html)
- [NVIDIA FFmpeg Transcoding Guide](https://developer.nvidia.com/blog/nvidia-ffmpeg-transcoding-guide/)
- [NVIDIA Video Codec SDK 10 Presets (P1-P7)](https://developer.nvidia.com/blog/introducing-video-codec-sdk-10-presets/)
- [RTX 50 Series — поддержка 4:2:2, AV1 Ultra Quality](https://videocardz.com/newz/nvidia-geforce-rtx-50-series-adds-support-for-422-color-format-video-decoding-and-encoding)
- [GeForce RTX 5060 Ti — спецификации](https://www.nvidia.com/en-us/geforce/graphics-cards/50-series/rtx-5060-family/)
