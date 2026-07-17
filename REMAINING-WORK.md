# Remaining Work — фиксы находок анализа + фича ${ENV_VAR}

> ⚠️ **ИСТОРИЧЕСКИЙ ДОКУМЕНТ (снимок на 2026-06-10). НЕ источник истины.**
>
> Актуальный статус открытых находок — только в `FINDINGS.md`; идеи — в `IDEAS.md`.
> Числа тестов — только из раннера (`bash tests/run_tests.sh`).
>
> Этот файл и связанный план описывают состояние на июнь 2026. Часть перечисленных
> здесь задач с тех пор закрыта, часть переформулирована, часть вскрылась как более
> глубокая, чем описано. Сверять по нему текущее состояние проекта нельзя: он
> оставлен как след того, что и почему делалось, а не как чеклист.

Статус-документ для продолжения работы. Полный пошаговый план с кодом фиксов:
[docs/superpowers/plans/2026-06-10-fix-analysis-findings.md](docs/superpowers/plans/2026-06-10-fix-analysis-findings.md)
(14 задач; в нём конкретные сниппеты, тестовые шаги и команды коммитов для КАЖДОЙ задачи — этот файл только статус и навигация).

Источник находок: анализ проекта 2026-06-09/10 (4 параллельных ревью-агента + верификация,
~50 подтверждённых находок). Находки P1/P2 кратко перечислены ниже в задачах; статусы — в `FINDINGS.md`, фича — в `IDEAS.md`.

## Процесс (как выполнялось и как продолжать)

Метод: subagent-driven development — на каждую задачу свежий субагент-исполнитель
(TDD: сначала падающий тест), затем два ревью: spec compliance + code quality;
найденные ревью проблемы исправляются до перехода дальше.

Правила (обязательные):
- Платформенный паритет: фикс в одной платформе = проверить/повторить в SH+PS1+CMD.
- `.ps1` — UTF-8 **с BOM** (после правки кириллицы добавить BOM python-сниппетом из CLAUDE.md); `.sh` — без BOM; `.cmd` — chcp 65001, CRLF.
- Коммиты: однострочные, **без** `Co-Authored-By` (публичный репо).
- Тесты: `bash tests/run_tests.sh ffmpeg` / `yt-dlp` (Git Bash; `test_04_integration.sh` yt-dlp НЕ гонять — ходит в сеть).
- В тестах `grep -qF -- "..."`; cmd вызывать `cmd //c` (двойной слэш).
- Не чинить ничего сверх задачи; найденное постороннее — в `FINDINGS.md`.

## Сделано (коммиты в main)

| Задача | Статус | Коммиты | Тесты |
|---|---|---|---|
| Task 1: script.cmd реанимация (P1: `::` в блоках → rem; тело `for /r` → `:process_file`; `%`-пути через переменные) | ✅ done + оба ревью | `834c0c7` (часть auto-commit), `04113c2` | test_11 smoke 8/8 |
| Task 2: run_v14.cmd парсер config.ini (P1: секции/трим ключа; P2: `&`-инъекция; P3: trim_val, to_flag; хук `--print-config`) | ✅ done, spec-ревью ✅, **quality-ревью НЕ завершено** (оборвано лимитом) | `d3b72bd`, `ca09f7c` | test_12 9/9 |

Полный прогон ffmpeg: **232/232 PASS**. yt-dlp не трогали (ожидается 136 минус test_04).

## Первый шаг при возобновлении

1. `git log --oneline -8` и `bash tests/run_tests.sh ffmpeg` — убедиться, что база не уехала (ночной auto-commit мог добавить коммит).
2. **Дозавершить quality-ревью Task 2**: ревью диапазона `04113c2..ca09f7c` (run_v14.cmd + test_12). Фокус: CMD-ловушки (`echo %%V=!%%V!` в `--print-config` при значениях со скобками; if/else binding; `call :trim_key` из for-блока; значение из одних пробелов); не изменилось ли прод-поведение без `--print-config`. Найденное — исправить и закоммитить.
3. Дальше — задачи 3–14 по плану, по порядку.

## Осталось: Tasks 3–14 (детали и код — в плане, здесь суть)

### Task 3: ffmpeg/FFmpeg_Converter_script.ps1 (есть P1)
- **P1**: `audio_only=yes` → `$vf_parts` не инициализирован → осиротевший `-vf` ломает каждый файл. Фикс: `$vf_parts = @()` перенести выше ветки audio_only (сейчас строка ~147 в else).
- `-ss 0` при start_coding с нулевым значением (строка ~551): условие → `if ($b -gt 0)`. Уже описано в FINDINGS.md (запись со статусом open).
- `container=mkv/ts` → `-f matroska/mpegts` (маппинг только для `-f`, расширение файла не менять).
- nvidia+rotation: `transpose_cuda` не существует → `transpose=N`; при rotation+GPU вся цепочка CPU (plain scale) + hwdownload-эвристика per-element без transpose_cuda.
- Тесты добавлять в `tests/ffmpeg/test_09_ps1_filters_gpu.sh`. BOM!

### Task 4: ffmpeg/FFmpeg_Converter_script.sh
- `-nostdin` во ВСЕ вызовы ffmpeg (~строки 325, 344, 352, 416, 552) — иначе ffmpeg ест NUL-список из stdin цикла `while read` → файлы молча пропускаются.
- Строка ~655: `while IFS= read -r -d '' full_path`.
- Muxer map mkv→matroska/ts→mpegts; transpose/hwdownload как в Task 3 (идентичная семантика!).
- Экранирование пути burn-субтитров (~503): `\`→`/`, `:`→`\:`, `'`→`\'`, обёртка `'...'` — единая схема для всех платформ.

### Task 5: ffmpeg/FFmpeg_Converter_script.cmd — latent-баги (скрипт уже парсится после Task 1)
- `keep_aspect_ratio` со статусом `-` отключает масштабирование вовсе (else-binding, ~150-162) → предвычислить флаг keep_ar.
- Лишний суффикс ` (part.1)` у одночастных файлов (ведущий пробел в `num`, ~401, 416).
- `split_by_silence` сломан полностью (float в `set /a`; `split_points` не сбрасывается между файлами; неопределённый `diff_start` → runtime error; нет guard `lcv_silent`). В плане есть fallback-вариант: предупреждение «используйте SH/PS1» — если ms-арифметика разрастётся.
- Нет validity-check существующего выхода (E3, ~298) — паритет с SH/PS1 (`ffmpeg -v error -i out -f null -`, битый → del).
- Octal-ловушка `%time%` в подсчёте времени (~224-227, 508-515) — приём «префикс 1, минус 100» (уже есть в строках 110-111).
- extract_audio: кодек по ПОСЛЕДНЕЙ строке Audio вместо первой (~262) → `if not defined audio_line`.
- Muxer map + transpose + hwdownload — зеркально Task 3/4.
- Экранирование субтитров: убрать ошибочное `:`→`\'\:` (строка ~448), схема как Task 4.
- В шапку: rem-комментарий об ограничении имён с `!` (и `%`/`^` после call — см. ревью Task 1).
- Тесты → test_10 (паттерн: логика во временный .cmd) + smoke test_11 должен остаться зелёным.

### Task 6: все 3 script-платформы — мелочи
- copy_codecs=yes: existence/validity-check ищет `.mp4` вместо расширения исходника → вычислять current_format_out ДО проверки (sh ~349-363 vs 385; ps1 ~377-392 vs 414; cmd ~298 vs 328+, после Task 1 номера сместились — искать по контексту).
- Duration N/A/0 → файл молча не обрабатывается → fallback: обработать целиком (`num=(0)` / `@(0)` / `set "num=0"`).

### Task 7: ffmpeg/FFmpeg_Converter_run_win_v14.ps1 (GUI; тестов нет — PSParser syntax-check)
- Нет FormClosing → осиротевший ffmpeg.exe + неудалённые temp при закрытии окна во время конверсии (сниппет в плане; runspace-глобалы из обработчика Run ~1297-1313).
- Дефолт `hw_accel` = `"+intel"` (строка ~99) при отсутствии ключа — у CLI `-intel` → рассинхрон, заменить.
- CRF↔битрейт mutual exclusion: оба включены в config → оба чекбокса заблокированы навсегда (~843-852) → дизейблить только поле ввода, при обоих checked приоритет quality.
- Inline-комментарии: `-replace '\s*#.*'` → `'\s+#.*'` (~45-47).
- **Решение wontfix**: GUI НЕ пишет config.ini обратно — это дизайн (CLAUDE.md), Write-Config не делать.

### Task 8: run-скрипты + build_exe
- Inline-`#`: PS1 run (~23) `'\s+#.*'`; CMD — резать только по ` #` (приём `|CUT|` в плане) — сейчас `delims=#` режет по любому.
- Регистр ключей: SH lowercase обеих сторон, CMD `/i` — паритет с PS1/GUI (регистронезависимы).
- run_v14.sh: нормализация `\`→`/` в путях из config + распознавать `[A-Za-z]:` как абсолютный (стоковый config содержит `_video_\0`).
- build_exe.ps1 (оба проекта): `Remove-Item $out` перед Invoke-ps2exe + try/catch — сейчас ложный SUCCESS со старым EXE.

### Task 9: yt-dlp itag-таблицы (P1) — все 3 платформы
Сломанные пресеты качают АУДИО вместо видео или несуществующие itag:
`avc1_https` 1440/2160 (`140+138`/`140+139`), `avc1_m3u8` 1080/1440/2160 (`234+233`/`234+234`/`234+235`), `avc1_https_60fps` 360/480/1440/2160 (296/297/300/301), `old_combo` 480/1080/1440/2160 (20/24/26/28).
Новые таблицы — В ПЛАНЕ (Task 9 Step 2, с селекторными fallback). Файлы: sh ~232-256, cmd ~198-220, ps1 formatPresets ~776-784. Плюс: avc1_best в SH без fallback-альтернативы (есть в PS1/CMD) → добавить.
ВНИМАНИЕ CMD: `!` в строках нельзя (delayed expansion), `^=` может требовать `^^=`.

### Task 10: yt-dlp/Downloading_from_YouTube_v14.cmd
- `%url%` → `!url!` (строки ~139, 272, 289, 308, 352): URL с `!` сейчас молча искажается; `%cookie_arg%` → `!cookie_arg!`.
- `%dlp%` → `"!dlp!"` (пути с пробелами); deno_arg с внутренними кавычками (~298).
- vot-cli: `set "NODE_TLS_REJECT_UNAUTHORIZED="` сбрасывает errorlevel ДО проверки → сохранить `vot_rc` сразу после vot (~352-355).
- **Merge перевода затирает оригинал битым файлом**: после ffmpeg проверяется только `if exist` без exit-кода (~372-382) → `ff_rc` + del битого.
- Выходная папка от CWD → `%~dp0_video_` (~10, 308, 365).
- Убрать безусловный `--no-check-certificate` (паритет с SH).
- Тесты → test_05 (через YTDLP_BIN-мок, логирующий argv).

### Task 11: yt-dlp/Downloading_from_YouTube_v14.ps1 (GUI; самая большая задача)
- Кнопка «Остановить» → гарантированный NullReferenceException (Stop-Download обнуляет `$global:downloadProcess` ~740, затем WaitForExit на null ~999) → не обнулять, guard.
- Убрать `Get-Process yt-dlp | Stop-Process -Force` (~739) — убивает ЧУЖИЕ загрузки.
- Merge перевода: `$LASTEXITCODE` не проверяется (~1103-1105) → как SH: rc=0 && exists, иначе del + сообщение.
- «Удалить»/«Очистить» активны во время загрузки → сдвиг индексов очереди → дизейблить на время processRunning.
- vot: `ReadToEnd()` stdout→stderr = deadlock → `ReadToEndAsync()` для stderr.
- Паритет с SH: убрать `--no-check-certificate` (~836); `use_archive`/`archive_file` (дефолт true!) → `--download-archive`; громкости original/translation_volume из config вместо хардкода 0.3/1.0 (~1099); `original_lang` → метаданные (~1090); base_dir и cookie-файл от `$scriptDir`, не `$PWD` (~299, 865, 942) + Test-Path cookie с warn.
- Read-Config `#`: `'\s+#.*'` (~30); qualityMap + `"audio"=0`; AI-перевод: исключить аудио-only из условия (~1018) + сообщение, если mp4 не найден (~1080-1083).
- Утечка Register-ObjectEvent (2 на URL, ~956-966) → Unregister + Dispose.
- Тесты → test_06 (Read-Config, формат-строки, qualityMap). BOM!

### Task 12: yt-dlp SH + кросс-платформа
- deno detection: проверять и `deno.exe` (~319, 488).
- `${env_prefix[@]+...}` для bash<4.4 (~365, 540) — иначе macOS bash 3.2 падает.
- Translate-ветка игнорирует rc загрузки (~816-831) → входить только при rc=0 (паритет CMD).
- `--no-mtime` при включённом переводе (все 3 платформы) — выбор файла по mtime ломается со старым yt-dlp.
- `continue_on_error` — мёртвый ключ: реализовать на всех 3 (true → `-i`, false → `--abort-on-error`; sh ~314/485, cmd ~289/308, ps1 ~836).

### Task 13: фича ${ENV_VAR} в config.ini (yt-dlp, 3 платформы) — из IDEAS.md
Семантика: `url = ${PROXY_URL}` → значение из окружения; не задана → пустая строка + WARN; несколько вхождений поддерживаются. Сниппеты для SH (load_config), PS1 (Read-Config, regex+scriptblock), CMD (`:expand_env`, БЕЗ echo|findstr — подстрочная проверка `!_val:${=!`) — в плане, Task 13 Steps 2-4.
Плюс: маски прокси-кредов в `.sanitize-patterns` (локальный, gitignored, НЕ коммитить); упоминание синтаксиса в комментарии шаблонного конфига, если есть config.example.ini. Боевой `yt-dlp/config.ini` (gitignored) НЕ ломать.

### Task 14: финал
1. Полный прогон всех тестов (кроме test_04_integration).
2. FINDINGS.md: записи `[ANALYSIS-LOGIC]` → done + Resolved-строка; IDEAS.md: env-var → done.
3. Rebuild EXE: `powershell -File ffmpeg/build_exe.ps1` и `yt-dlp/build_exe.ps1` (после Task 8 — честный fail-fast).
4. `git config core.hooksPath` = `.githooks`; просмотр diff на секреты перед финальным коммитом.

## Известные грабли (выученные в Tasks 1-2)

- Ночной auto-commit (cron) подбирает незакоммиченную работу — не оставлять рабочее дерево грязным между задачами; коммитить каждую задачу сразу.
- `::`-комментарии и label'ы внутри `(...)`-блоков CMD ломают парсер; `rem` со скобками внутри блоков — тоже.
- `call :sub "%%~fa"` повторно раскрывает `%` → пути передавать через переменные (уже исправлено в Task 1).
- `echo X | findstr` в CMD: пробел перед `|` попадает в вывод; `$`-якорь не работает на piped input; `&` в значении исполняется. Не использовать echo|findstr вообще.
- Мок-бинари для CMD-тестов: .bat без `call` не работает (передача управления), смотри генерацию мок-exe в test_11_cmd_smoke.sh.
- PS1 5.1: `@() + $null` даёт массив из одного $null (Count=1) — источник P1 в Task 3.
