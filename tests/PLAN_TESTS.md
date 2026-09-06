# План системы тестирования

> ⚠️ **АРХИВ — исторический план, НЕ источник истины.**
>
> Это исходный замысел тест-системы: семь ffmpeg-файлов, два yt-dlp и заглушка
> вместо конвертера. Реальный набор давно больше и устроен иначе (ffmpeg, yt-dlp
> и `common`; production-скрипты дот-сорсятся, заглушек нет). Актуальный состав —
> только из раннера (`bash tests/run_tests.sh`) и таблиц `README.md`; как всё
> устроено сейчас — в [`TESTING.md`](TESTING.md) и `CLAUDE.md`.
>
> Файл оставлен как след того, с чего начиналась тест-система. Сверять по нему
> текущее состояние нельзя.

## Структура

```
tests/
├── run_tests.sh                        # Точка входа — запускает все суиты
├── lib/
│   └── framework.sh                   # assert_eq, assert_contains, pass/fail
├── mocks/
│   ├── ffmpeg                          # Перехватывает аргументы, имитирует прогресс
│   ├── ffprobe                         # Возвращает фиктивные данные о медиа
│   └── yt-dlp                          # Записывает аргументы в лог
├── ffmpeg/
│   ├── FFmpeg_Converter_script.sh     # ЗАГЛУШКА — пустой файл, блокирует source
│   ├── test_01_config_sh.sh           # read_config + to_flag (Bash)
│   ├── test_02_config_ps1.sh          # Read-Config + To-Flag (PowerShell)
│   ├── test_03_audio_args.sh          # Аудио: кодек/каналы/битрейт/нормализация
│   ├── test_04_video_args.sh          # Видео: кодек/качество/контейнер
│   ├── test_05_filters.sh             # Фильтры: scale/rotate/speed + atempo
│   ├── test_06_gpu.sh                 # GPU: NVIDIA nvenc / Intel QSV
│   └── test_07_integration.sh        # Полный пайплайн с mock-ffmpeg
└── yt-dlp/
    ├── test_01_read_config.sh         # read_config для yt-dlp config.ini
    ├── test_02_format_args.sh         # build_format_args (все пресеты × все качества)
    ├── test_03_cookie_args.sh         # build_cookie_args (none/file/browser)
    └── test_04_integration.sh        # Полный пайплайн с mock-yt-dlp
```

## Ключевой трюк: тестирование run.sh без изменений

`FFmpeg_Converter_run.sh` заканчивается `source "${SCRIPT_DIR}/FFmpeg_Converter_script.sh"`.
При `source run.sh` из тест-файла `$0` = тест-файл → `SCRIPT_DIR` = `tests/ffmpeg/`.
Там лежит наша заглушка `FFmpeg_Converter_script.sh` (exit 0).
Config.ini каждый тест пишет сам в `tests/ffmpeg/config.ini`.
→ Переменные (audio_codec, video_codec, ...) доступны после source.

## Что проверяет каждый тест

### test_01_config_sh.sh (Bash config parsing)
- `+libx264` → `:+:libx264` (to_flag enabled)
- `-libx264` → `:-:libx264` (to_flag disabled)
- `+value` без prefix → `:+:value` (bare value treated as enabled)
- Комментарии `# ...` игнорируются
- Пустые строки игнорируются
- Несуществующий ключ → default value
- Несуществующая секция → default value
- Несуществующий config.ini → default value
- Несколько секций — читает нужную

### test_02_config_ps1.sh (PowerShell config parsing)
- `Read-Config` возвращает те же значения что и bash `read_config`
- `To-Flag` возвращает те же значения что и bash `to_flag`
- 6 эталонных пар (key → expected) сравниваются между sh и ps1

### test_03_audio_args.sh
- `codec = +aac` → `set_audio_codec="-c:a aac"`
- `codec = -aac` → `set_audio_codec=""`
- `bitrate = +192` → `set_audio_bitrate="-b:a 192k"`
- `bitrate = -192` → `set_audio_bitrate=""`
- `channels = +1` → `set_audio_number_channels="-ac 1"`
- `sampling_rate = +48000` → `set_audio_sampling_rate="-ar 48000"`
- `normalize = +loudnorm` → `af_chain` содержит `loudnorm=I=-16`
- `normalize = +dynaudnorm` → `af_chain` содержит `dynaudnorm`
- `normalize = -loudnorm` → `af_chain` пустой

### test_04_video_args.sh
- `codec = +libx264` → `set_video_codec="libx264"` → `-c:v libx264`
- `codec = +libx265` → `-c:v libx265`
- `codec = -libx264` → нет `-c:v`
- `quality = +23` → `crf_args="-crf 23"`
- `quality = -23` → `crf_args=""`
- `container = +mkv` → `format_files_out="mkv"`
- `container = -mp4` → `format_files_out="mp4"` (default)
- `audio_only = yes` → `video_settings="-vn"`, `format_files_out="mp3"`
- `framerate = +30` → `-r 30`
- `framerate = -30` → нет `-r`

### test_05_filters.sh
- `rotation = +1` → `vf_chain` содержит `transpose=1`
- `rotation = +2` → `vf_chain` содержит `transpose=2`
- `rotation = -1` → нет `transpose`
- `resolution = +1280x720`, `keep_aspect_ratio = +yes` → `scale=1280:720:force_original_aspect_ratio=decrease`
- `resolution = +1280x720`, `keep_aspect_ratio = -yes` → `scale=1280:720`
- `resolution = -1280x720` → нет `scale`
- `playback_speed = +2.0` → `vf_chain` содержит `setpts=PTS/2.0`, `af_chain` содержит `atempo=2.0`
- `playback_speed = +4.0` → `af_chain` содержит `atempo=2.0,atempo=2.0` (каскад)
- `playback_speed = +0.3` → `af_chain` содержит `atempo=0.5,...` (каскад вниз)
- `playback_speed = +1.0` → нет `setpts`, нет `atempo`
- `playback_speed = -1.0` → нет `setpts`, нет `atempo`

### test_06_gpu.sh
- mock ffmpeg возвращает `nvenc` в `-encoders` → hw_accel_type="nvidia"
- `libx264` + nvidia → `set_video_codec="h264_nvenc"`
- `libx265` + nvidia → `set_video_codec="hevc_nvenc"`
- `libsvtav1` + nvidia → `set_video_codec="av1_nvenc"`
- mock ffmpeg возвращает `qsv` в `-encoders` → hw_accel_type="intel"
- `libx264` + intel → `set_video_codec="h264_qsv"`
- mock ffmpeg не возвращает nvenc → использует software (предупреждение в stdout)
- `quality = +28` + nvidia → `gpu_args` содержит `-cq 28`
- `quality = +28` + intel → `gpu_args` содержит `-global_quality 28`
- `quality = +23` + software → `crf_args="-crf 23"`
- `gpu_preset = +p5` + nvidia → `-preset p5`
- `gpu_tune = +hq` + nvidia → `-tune hq`
- `gpu_rc = +vbr` + nvidia → `-rc vbr`

### test_07_integration.sh (FFmpeg полный пайплайн)
- Создаём реальный tiny MP4 (1 сек, 64x64) через настоящий ffmpeg
- Запускаем run.sh с mock-ffmpeg в PATH
- Mock ffmpeg записывает все аргументы в /tmp/mock_ffmpeg_last_call.txt
- Проверяем что mock был вызван: аргументы содержат входной файл
- `dry_run = yes` → mock НЕ вызывается
- Проверяем exit code

### test_01_read_config.sh (yt-dlp)
- Та же логика что и ffmpeg test_01, но для yt-dlp скрипта
- Проверяем секции: proxy/cookies/output/download/subtitles/batch/translation

### test_02_format_args.sh (yt-dlp)
- `build_format_args audio avc1_best` → `-f bestaudio[ext!=webm]`
- `build_format_args 720 avc1_best` → содержит `height<=720` и `vcodec^=avc1`
- `build_format_args 1080 avc1_best` → содержит `height<=1080`
- `build_format_args 720 avc1_https` → `-f 140+136/135/134`
- `build_format_args 1080 avc1_https` → `-f 140+137/136/135/134`
- `build_format_args 720 avc1_m3u8` → `-f 234+232/231/230`
- `build_format_args 720 avc1_https_60fps` → `-f 234+298/297/296`
- `build_format_args 720 avc1_m3u8_60fps` → `-f 234+311/310/309`
- `build_format_args 720 avc1_https_60fps_hdr` → `-f 234+698/697/696`
- `build_format_args 720 old_combo` → `-f 22/20/18`
- `build_format_args audio old_combo` → `-f 140`
- `build_format_args 360 old_combo` → `-f 18`
- Неизвестный пресет → fallback на 720p avc1_best

### test_03_cookie_args.sh (yt-dlp)
- `build_cookie_args none "" ""` → пустой вывод
- `build_cookie_args "" "" ""` → пустой вывод
- `build_cookie_args browser "" chrome` → `--cookies-from-browser chrome`
- `build_cookie_args browser "" firefox` → `--cookies-from-browser firefox`
- `build_cookie_args file /tmp/exists.txt ""` → `--cookies "/tmp/exists.txt"`
- `build_cookie_args file /tmp/noexist.txt ""` → пустой вывод (файл не найден)

### test_04_integration.sh (yt-dlp полный пайплайн)
- Запускаем скрипт с реальным URL = `https://example.com/fake` и mock yt-dlp
- Mock записывает аргументы
- Проверяем что mock вызван
- `--quality 1080` → args содержат `height<=1080`
- `--cookies browser chrome` → args содержат `--cookies-from-browser chrome`

## Архитектура framework.sh

```bash
TESTS_PASS=0; TESTS_FAIL=0; TESTS_SKIP=0
suite()           — печатает заголовок группы
pass()            — +1 pass, зелёная галочка
fail()            — +1 fail, красный крест + expected/got
skip()            — +1 skip, жёлтый кружок
assert_eq()       — сравнивает строки
assert_contains() — ищет паттерн в строке
assert_not_contains() — паттерн отсутствует
assert_empty()    — строка пустая
assert_not_empty()— строка не пустая
summary()         — итог, exit 1 если есть failures
```

## Запуск

```bash
bash tests/run_tests.sh                  # Все тесты
bash tests/run_tests.sh ffmpeg           # Только ffmpeg
bash tests/run_tests.sh yt-dlp           # Только yt-dlp
bash tests/ffmpeg/test_01_config_sh.sh  # Один файл
```
