# Fix Analysis Findings + ENV-substitution Feature — Implementation Plan

> ⚠️ **АРХИВ (2026-06-10). План закрыт как рабочий чеклист.**
>
> Незакрытые `- [ ]` ниже НЕ означают «задача открыта»: часть из них выполнена
> позднее вне этого плана, часть переформулирована. Открытые находки живут только
> в `FINDINGS.md`, идеи — в `IDEAS.md`.
>
> Файл сохранён ради контекста решений (почему фикс сделан именно так), а не для
> исполнения. Не начинать работу по нему, не сверившись с `FINDINGS.md`.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Исправить все подтверждённые находки анализа 2026-06-09/10 (P1/P2/P3 в ffmpeg и yt-dlp, 3 платформы) и реализовать подстановку `${ENV_VAR}` в config.ini yt-dlp.

**Architecture:** Config-driven pipeline `config.ini → run → script` в 3 платформах (SH/CMD/PS1) + WinForms GUI. Все фиксы обязаны сохранять platform parity. Тесты — чистый Bash (`tests/lib/framework.sh`), mock-бинари в `tests/mocks/`. CMD-тесты через `cmd //c` (двойной слэш) в Git Bash.

**Tech Stack:** Bash, Windows CMD (delayed expansion), PowerShell 5.1 (UTF-8 BOM!), ffmpeg, yt-dlp.

**Правила для исполнителя:**
- После КАЖДОГО Write/Edit `.ps1` с кириллицей — добавить BOM (python-сниппет из CLAUDE.md).
- Коммиты: однострочные `git commit -m`, БЕЗ `Co-Authored-By` trailer (публичный репо).
- Тесты гонять через Git Bash: `bash tests/run_tests.sh [ffmpeg|yt-dlp]`. `test_04_integration.sh` (yt-dlp) НЕ запускать — ходит в сеть.
- `grep -qF --` в тестах (паттерны с `-` ломают grep).
- Не трогать `yt-dlp/config.ini` (локальный, gitignored, рабочие креды пользователя) — кроме случаев, явно указанных в Task 13.

**Принятые решения (wontfix / документировать, НЕ чинить):**
1. ffmpeg GUI не пишет настройки обратно в config.ini — это ДИЗАЙН (CLAUDE.md: «GUI reads config.ini for initial control values»). Не реализовывать Write-Config.
2. Имена файлов с `!` в CMD-скриптах — известное ограничение delayed expansion; добавить комментарий в шапку обоих script.cmd, не чинить.
3. atempo cascade в CMD — известное ограничение, не трогать.

---

## Task 1: Реанимация FFmpeg_Converter_script.cmd (P1: parse errors)

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.cmd`
- Test: `tests/ffmpeg/test_11_cmd_smoke.sh` (создать)

Скрипт сейчас умирает с `". was unexpected at this time."` (exit 255) до обработки первого файла. Две причины: `::`-комментарии внутри `(...)`-блоков и label `:continue_next_file` внутри тела `for /r`.

- [ ] **Step 1: Написать падающий smoke-тест** — `tests/ffmpeg/test_11_cmd_smoke.sh`:

```bash
#!/bin/bash
# End-to-end smoke: script.cmd должен парситься и выполнять dry_run без parse errors.
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(dirname "$TESTS_DIR")"
source "$TESTS_DIR/lib/framework.sh"

WORK=$(mktemp -d /tmp/cmd_smoke_XXXXXX)
mkdir -p "$WORK/src" "$WORK/bin"
printf 'fake' > "$WORK/src/sample.mp4"
# Мок ffmpeg/ffprobe для cmd.exe: .bat в PATH
cat > "$WORK/bin/ffmpeg.bat" <<'EOF'
@echo off
exit /b 0
EOF
cat > "$WORK/bin/ffprobe.bat" <<'EOF'
@echo off
echo 60
exit /b 0
EOF

WIN_WORK=$(cygpath -w "$WORK")
WIN_SCRIPT=$(cygpath -w "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd")

OUT=$(cd "$WORK" && PATH="$WORK/bin:$PATH" cmd //v:on //c "set \"PATH=$WIN_WORK\\bin;%PATH%\" && set \"folder_sources=$WIN_WORK\\src\" && set \"folder_destination=$WIN_WORK\\out\" && set \"dry_run=yes\" && set \"audio_only=no\" && set \"copy_codecs=no\" && call \"$WIN_SCRIPT\"" < /dev/null 2>&1)
RC=$?

assert_not_contains "$OUT" "was unexpected at this time" "no parse errors"
assert_eq "0" "$RC" "exit code 0"
assert_contains "$OUT" "DRY-RUN" "dry-run executed for sample file"

rm -rf "$WORK"
print_summary
```

Примечание исполнителю: точные имена переменных окружения, которые ожидает script.cmd, взять из `FFmpeg_Converter_run_v14.cmd` (блок дефолтов) — передать ВСЕ обязательные, по образцу test_10. Если script.cmd завершается `pause`/`read` — подать `< NUL` (`cmd //c "... <NUL"`).

- [ ] **Step 2: Запустить тест, убедиться что падает** — `bash tests/ffmpeg/test_11_cmd_smoke.sh`. Ожидание: FAIL (`was unexpected at this time`, exit 255).

- [ ] **Step 3: Заменить все `::`-комментарии на `rem`** во всём файле (единообразно, и вне блоков тоже — безвредно). В текстах комментариев внутри блоков УБРАТЬ символы `(` и `)` (перефразировать). Пример:

```
до:   :: в системную память (иначе ffmpeg: "filter not supported on hardware frames").
после: rem в системную память — иначе ffmpeg: "filter not supported on hardware frames".
```

Проверка полноты: `grep -n "^\s*::" ffmpeg/FFmpeg_Converter_script.cmd` → пусто; `grep -n "rem.*[()]" ffmpeg/FFmpeg_Converter_script.cmd` → просмотреть каждое вхождение, внутри блоков скобок остаться не должно.

- [ ] **Step 4: Вынести тело `for /r` в подпрограмму** — убирает label `:continue_next_file` (строка ~503) и `goto` из блока (строки ~286, 295 — сейчас обрывают перечисление):

```bat
for /r "%folder_sources%" %%a in (%file_masks%) do call :process_file "%%~fa"
goto :after_files

:process_file
set "full_path=%~1"
rem ... всё прежнее тело цикла без изменений логики ...
rem прежние `goto :continue_next_file` -> `exit /b`
exit /b

:after_files
rem ... итоговая сводка ...
```

Точную маску файлов и структуру взять из текущего кода (~строки 248-504). Переменные-счётчики (`count_ok` и т.п.) сохраняются — подпрограмма работает в том же окружении.

- [ ] **Step 5: Прогнать smoke-тест до зелёного** — `bash tests/ffmpeg/test_11_cmd_smoke.sh` → PASS. Если новые parse errors — чинить аналогично (Step 3/4) и повторять.

- [ ] **Step 6: Полный прогон ffmpeg-тестов** — `bash tests/run_tests.sh ffmpeg` → все PASS.

- [ ] **Step 7: Commit** — `git add -A ffmpeg/FFmpeg_Converter_script.cmd tests/ffmpeg/test_11_cmd_smoke.sh && git commit -m "Fix CMD script fatal parse errors: :: comments in blocks, label inside for /r"`

---

## Task 2: FFmpeg_Converter_run_v14.cmd — парсер config.ini (P1 + P2 `&`-инъекция + P3)

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_run_v14.cmd`
- Test: `tests/ffmpeg/test_12_cmd_run_parser.sh` (создать)

Сейчас config.ini игнорируется полностью: (а) `echo !_line! | findstr /r "^\[.*\]$"` — пробел перед `|` + якорь `$` на piped input (известный паттерн из memory) → секции не распознаются; (б) `_key` получает хвостовой пробел и не матчится; (в) `echo |` исполняет `&` из значений (стоковый `subtitles_style` с `&HFFFFFF&`); (г) `:trim_val` режет максимум 3 пробела; (д) `:to_flag` при пустом значении даёт `:+:`.

- [ ] **Step 1: Добавить тестовый хук `--print-config`** в run_v14.cmd: если первый аргумент `--print-config`, после парсинга config.ini напечатать `key=value` всех переменных и `exit /b 0` (НЕ запуская script). Вставить проверку прямо перед запуском script-файла:

```bat
if "%~1"=="--print-config" (
	echo hw_accel=!hw_accel!
	echo video_quality=!video_quality!
	echo folder_sources=!folder_sources!
	echo subtitles_style=!subtitles_style!
	echo audio_codec=!audio_codec!
	exit /b 0
)
```

(Список ключей — все, что выставляет парсер; взять из блока дефолтов.)

- [ ] **Step 2: Написать падающий тест** — `tests/ffmpeg/test_12_cmd_run_parser.sh`: создать временный config.ini:

```ini
[video]
hw_accel = +intel
quality = +23
[subtitles]
style = FontSize=20,PrimaryColour=&HFFFFFF&
[audio]
codec =
```

Запустить `cmd //c "...run_v14.cmd --print-config"` с подменённым config (скопировать run + config во временную папку, т.к. путь к config зашит относительно скрипта). Ассерты:
- `hw_accel=:+:intel` (не дефолт),
- `video_quality=:+:23`,
- вывод НЕ содержит `is not recognized` (нет исполнения `&`),
- `audio_codec=:+:aac` (пустое значение → дефолт),
- `subtitles_style` содержит `&HFFFFFF&` целиком.

- [ ] **Step 3: Запустить тест → FAIL** (дефолтные значения вместо конфиговых).

- [ ] **Step 4: Починить детект секции** (строка ~65) — без сабпроцесса и пайпа:

```bat
set "_is_section="
if "!_line:~0,1!"=="[" if "!_line:~-1!"=="]" set "_is_section=1"
if defined _is_section (
	set "_section=!_line:~1,-1!"
) else (
	rem ... парсинг key = value как раньше ...
)
```

- [ ] **Step 5: Трим хвостовых пробелов ключа** — после `set "_key=%%K"` добавить `call :trim_key`, подпрограмма в конец файла:

```bat
:trim_key
if "!_key:~-1!"==" " (set "_key=!_key:~0,-1!" & goto :trim_key)
exit /b
```

- [ ] **Step 6: `:trim_val` — полный цикл вместо 3 итераций** (строка ~92):

```bat
:trim_val
if "!_val:~-1!"==" " (set "_val=!_val:~0,-1!" & goto :trim_val)
exit /b
```

- [ ] **Step 7: Детект абсолютного пути без `echo | findstr`** (строки ~173, 175):

```bat
set "_abs="
if "!folder_sources:~1,2!"==":\" set "_abs=1"
if "!folder_sources:~0,2!"=="\\" set "_abs=1"
if not defined _abs set "folder_sources=%~dp0!folder_sources!"
```

(аналогично для folder_destination).

- [ ] **Step 8: Guard пустого значения в `:to_flag`** (строки ~158-168) — первой строкой: `if not defined _fv exit /b` (остаётся дефолт).

- [ ] **Step 9: Тест → PASS; полный прогон** `bash tests/run_tests.sh ffmpeg` → PASS.

- [ ] **Step 10: Commit** — `git commit -m "Fix run_v14.cmd config parser: section detect, key trim, & injection, empty values"`

---

## Task 3: FFmpeg_Converter_script.ps1 — P1 audio_only, -ss 0, muxer map, transpose

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.ps1`
- Test: `tests/ffmpeg/test_09_ps1_filters.sh` (дополнить)

- [ ] **Step 1: Тесты (добавить в test_09):** (а) `audio_only=yes` → построенный argv НЕ содержит одинокого `-vf` (паттерн `-vf` без значения за ним / `-vf -af`); (б) `start_coding` включён со значением `0-0-0` → argv НЕ содержит `-ss`; (в) `container=mkv` → argv содержит `-f matroska`, НЕ `-f mkv`; имя файла по-прежнему `.mkv`; (г) `hw_accel=nvidia + rotation=2` → vf-цепочка содержит `transpose=2` и `hwdownload`, НЕ `transpose_cuda`. Запустить → FAIL.

- [ ] **Step 2: Фикс инициализации `$vf_parts`** — строка 147 `$vf_parts = @()` переместить ВЫШЕ строки 134 (перед `if ($audio_only -eq "yes")`).

- [ ] **Step 3: Фикс `-ss 0`** — строка 551:

```powershell
if ($b -gt 0) { $ffmpegArgs += @("-ss", "$b") }
```

- [ ] **Step 4: Muxer map** — на месте подстановки `-f` (~строка 212): расширение для имени файла остаётся как есть, для `-f` маппинг:

```powershell
$muxer_out = switch ($format_files_out) { "mkv" { "matroska" } "ts" { "mpegts" } default { $format_files_out } }
```

и использовать `$muxer_out` в аргументе `-f`.

- [ ] **Step 5: transpose + унификация hwdownload.** Строка 152: nvidia-ветка `transpose_cuda=...` → обычный `transpose=$video_rotation_value` (фильтра transpose_cuda не существует). Чтобы не получить смешанную CPU+GPU цепочку: если rotation включён И use_hw_accel — использовать CPU-вариант scale (`scale=...,pad=...` / `scale=...`) вместо `scale_cuda/scale_qsv` для ВСЕЙ цепочки. Эвристика hwdownload (строки 182-187): оставить per-element, но `transpose_cuda` из паттерна удалить:

```powershell
$needs_download = $vf_parts | Where-Object { $_ -notmatch '^(scale_cuda|scale_qsv|setpts)' }
```

- [ ] **Step 6: Тесты → PASS; BOM-проверка; полный прогон ffmpeg-тестов → PASS.**

- [ ] **Step 7: Commit** — `git commit -m "PS1: fix audio_only orphan -vf, -ss 0 with start_coding, mkv/ts muxer names, nvidia rotation"`

---

## Task 4: FFmpeg_Converter_script.sh — -nostdin, read -r, muxer, transpose, subtitle escaping

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.sh`
- Test: `tests/ffmpeg/test_03..07` (дополнить соответствующий файл по месту)

- [ ] **Step 1: Тесты:** (а) `container=mkv` → `-f matroska`; (б) nvidia+rotation → `transpose=`, не `transpose_cuda`; (в) burn-субтитры с путём `C:/dir/file.srt` → в `-vf` путь в форме `subtitles='C\:/dir/file.srt'`. Запустить → FAIL.

- [ ] **Step 2: `-nostdin`** — добавить первым аргументом ко ВСЕМ вызовам ffmpeg (строки ~325, 344, 352, 416, 552): `"$FFMPEG" -nostdin ...`.

- [ ] **Step 3: Цикл чтения файлов** (строка ~655): `while IFS= read -r -d '' full_path; do` (вместо `read -d $'\0'` без `-r`).

- [ ] **Step 4: Muxer map** (строка ~206):

```bash
case "$format_files_out" in
	mkv) muxer_out="matroska" ;;
	ts)  muxer_out="mpegts" ;;
	*)   muxer_out="$format_files_out" ;;
esac
```

`-f $muxer_out` в команде; расширение файла без изменений.

- [ ] **Step 5: transpose + hwdownload** — строка ~145: nvidia → `transpose=$video_rotation_value`; при rotation+hw_accel вся цепочка CPU (scale вместо scale_cuda/scale_qsv); эвристику hwdownload (строки ~173-182) перевести на per-element семантику, идентичную PS1: цепочку разбить по запятой, hwdownload добавлять если есть элемент, НЕ начинающийся со `scale_cuda|scale_qsv|setpts`.

- [ ] **Step 6: Экранирование пути субтитров** (строка ~503) — привести к единой схеме (та же в Task 5 для CMD): `\` → `/`, `:` → `\:`, `'` → `\'`, обернуть в `'...'`:

```bash
sub_escaped="${sub_file//\\//}"
sub_escaped="${sub_escaped//:/\\:}"
sub_escaped="${sub_escaped//\'/\\\'}"
# использование: subtitles='$sub_escaped'
```

- [ ] **Step 7: Тесты → PASS; полный прогон ffmpeg → PASS.**

- [ ] **Step 8: Commit** — `git commit -m "SH: add -nostdin, fix file loop read flags, mkv/ts muxers, nvidia rotation, subtitle path escaping"`

---

## Task 5: FFmpeg_Converter_script.cmd — latent P2/P3 (после Task 1)

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.cmd`
- Test: `tests/ffmpeg/test_10_cmd.sh` (дополнить), smoke из Task 1

- [ ] **Step 1: Тесты в test_10 (по образцу существующих — логика во временный .cmd):** (а) `keep_aspect_ratio` со статусом `-` + resolution → vf_chain содержит `scale=WxH`; (б) одночастный файл: суффикс `(part.1)` НЕ добавляется; (в) muxer map mkv→matroska; (г) nvidia+rotation → `transpose=`, эвристика hwdownload per-element. Запустить → FAIL.

- [ ] **Step 2: keep_aspect_ratio else-binding** (строки ~150-162) — предвычислить флаг:

```bat
set "keep_ar=no"
if "!keep_aspect_ratio_status!"=="+" if "!keep_aspect_ratio_value!"=="yes" set "keep_ar=yes"
if "!keep_ar!"=="yes" (
	rem ... ветка с force_original_aspect_ratio ...
) else (
	rem ... обычный scale ...
)
```

- [ ] **Step 3: Ведущий пробел в num** (строка ~401):

```bat
if defined num (set "num=!num! !part_start!") else (set "num=!part_start!")
```

- [ ] **Step 4: split_by_silence — починить 4 дефекта** (строки ~367-424):
  1. Float-таймстампы → ms-арифметика (по образцу `:build_atempo` в этом же файле): `for /f "tokens=1,2 delims=." %%x in ("!silence_start!") do ...`, дополнить дробную часть до 3 цифр, `set /a` в миллисекундах;
  2. `set "split_points="` в начале обработки каждого файла;
  3. Guard: `if not defined diff_start` → пропустить сравнение;
  4. Guard `if defined lcv_silent!cc!` перед использованием (через `call set "_lcv=%%lcv_silent!cc!%%"` + `if defined _lcv`).
  Если ms-арифметика разрастается сверх ~40 строк — fallback-решение: при `split_by_silence=yes` в CMD печатать предупреждение «split_by_silence недоступен в CMD-версии, используйте SH/PS1» и продолжать без разбиения (как с atempo cascade); тогда тесты на (4 дефекта) заменить тестом на предупреждение.

- [ ] **Step 5: Validity-check существующего выхода (E3)** (строка ~298) — паритет с SH/PS1:

```bat
if exist "!out_file!" (
	"%ffmpeg%" -v error -i "!out_file!" -f null - >nul 2>&1
	if !errorlevel! equ 0 ( rem скип, файл валиден
		...
	) else (
		del /q "!out_file!"
	)
)
```

- [ ] **Step 6: Octal-ловушка времени** (строки ~224-227, 508-515) — приём «префикс 1, вычесть 100» (уже используется в строках 110-111 этого файла) для всех компонент `%time%`.

- [ ] **Step 7: extract_audio: первая строка Audio, а не последняя** (строка ~262):

```bat
if not defined audio_line set "audio_line=%%c"
```

- [ ] **Step 8: Muxer map + transpose + hwdownload per-element** — зеркально Task 3/4: mkv→matroska, ts→mpegts при `-f`; nvidia rotation → `transpose=`; в эвристике hwdownload (строка ~172) `findstr` по элементам (разбить `vf_chain` по запятой в цикле) либо минимально — убрать `transpose_cuda` из паттерна и при rotation+hw использовать CPU-scale для всей цепочки (идентично Task 3 Step 5).

- [ ] **Step 9: Экранирование субтитров** (строки ~439-445): `\` → `/`, `:` → `\:` (убрать ошибочное `\'\:`), `'` → `\'` — та же схема, что Task 4 Step 6.

- [ ] **Step 10: Комментарий-ограничение в шапку:** `rem Известное ограничение: имена файлов с ! повреждаются (delayed expansion).`

- [ ] **Step 11: Тесты → PASS (включая smoke из Task 1); полный прогон ffmpeg → PASS.**

- [ ] **Step 12: Commit** — `git commit -m "CMD script: fix keep_aspect_ratio, part suffix, split_by_silence, output validity check, time math, audio probe, muxers, rotation"`

---

## Task 6: ffmpeg — кросс-платформенные мелочи (copy_codecs skip, Duration N/A)

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.sh`, `.ps1`, `.cmd`

- [ ] **Step 1: Тест:** copy_codecs=yes + исходник `.avi` → existence-check ищет `.avi`-выход (не `.mp4`). Duration пустая/0 → файл всё равно обрабатывается одной частью (`num` содержит `0`).

- [ ] **Step 2: copy_codecs skip-extension** — во всех 3: вычислить `current_format_out` (с учётом copy_codecs → расширение исходника) ДО existence/validity-проверки (SH ~349-363 vs 385; PS1 ~377-392 vs 414; CMD ~298 vs 328) — перенести присвоение выше.

- [ ] **Step 3: Duration N/A fallback** — если duration не определена/0: SH `num=(0)`; PS1 `$num = @(0)`; CMD `set "num=0"` — обработать файл целиком, предупреждение «длительность неизвестна, разбиение пропущено».

- [ ] **Step 4: Тесты → PASS; прогон ffmpeg → PASS. Commit** — `git commit -m "ffmpeg: fix skip-check extension with copy_codecs, process files with unknown duration"`

---

## Task 7: ffmpeg GUI (run_win_v14.ps1) — FormClosing, дефолты, mutual exclusion

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_run_win_v14.ps1`

GUI-логика тестами не покрыта (WinForms) — проверка: syntax-check `powershell -NoProfile -Command "[void][System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw 'ffmpeg/FFmpeg_Converter_run_win_v14.ps1'), [ref]$null)"` + ручной запуск не требуется.

- [ ] **Step 1: FormClosing** — перед `[void]$form.ShowDialog()` добавить:

```powershell
$form.Add_FormClosing({
	if ($global:_guiPS -and $global:_guiHandle -and -not $global:_guiHandle.IsCompleted) {
		try { "cancel" | Set-Content $global:_guiCancel -ErrorAction SilentlyContinue } catch {}
		try { $global:_guiPS.Stop() } catch {}
	}
	foreach ($f in @($global:_guiProgress, $global:_guiCancel)) {
		if ($f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
	}
	if ($global:_guiPS) { try { $global:_guiPS.Dispose() } catch {} }
	if ($global:_guiRS) { try { $global:_guiRS.Dispose() } catch {} }
})
```

(Точные имена глобалов runspace/handle взять из обработчика Run, строки ~1297-1313; если runspace хранится в локальных переменных — вынести в `$global:`.) Важно: cancel-файл script.ps1 уже умеет читать — убедиться, что Write-GUIProgress-цикл скрипта реагирует на cancel и убивает ffmpeg-процесс; если нет — в обработчике дополнительно killить PID из прогресс-JSON (`pid` поле уже есть в Write-GUIProgress).

- [ ] **Step 2: Дефолт hw_accel** — строка 99: `"+intel"` → `"-intel"` (паритет с run-скриптами).

- [ ] **Step 3: CRF↔битрейт mutual exclusion** (строки ~843-852) — не дизейблить чекбокс противоположной опции, только её поле ввода; при загрузке config с обоими включёнными — приоритет quality (снять галку bitrate), как в script.

- [ ] **Step 4: Inline-комментарии** — regex `-replace '\s*#.*'` → `-replace '\s+#.*'` (строки ~45-47).

- [ ] **Step 5: BOM-проверка; syntax-check; прогон ffmpeg-тестов (test_01/02 читают run-файлы) → PASS. Commit** — `git commit -m "GUI: cleanup on close, hw_accel default parity, CRF/bitrate exclusion, inline comment parsing"`

---

## Task 8: ffmpeg run-скрипты — паритет парсинга + build_exe

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_run_v14.ps1`, `ffmpeg/FFmpeg_Converter_run_v14.sh`, `ffmpeg/FFmpeg_Converter_run_v14.cmd`, `ffmpeg/build_exe.ps1`, `yt-dlp/build_exe.ps1`

- [ ] **Step 1: Тесты (test_01/test_12):** значение `my#file.log` сохраняется целиком при `log_file = my#file.log` (без пробела перед `#`) на всех платформах; `Codec = +aac` (капитализация) даёт одинаковый результат на всех платформах.

- [ ] **Step 2: Inline-комментарии:** PS1 (строка ~23): `'\s*#.*'` → `'\s+#.*'`. CMD: `delims=#` режет по любому `#` — заменить разбор: после `:trim_val` искать ` #` (пробел+решётка) через подстроку:

```bat
rem отрезать инлайн-комментарий только по " #"
set "_val_nc=!_val: #=|CUT|!"
for /f "tokens=1 delims=|" %%C in ("!_val_nc!") do ... 
```

Если подстрочный приём хрупок — допустимая альтернатива: оставить CMD как есть и задокументировать в config.ini («не используйте # внутри значений»), но тогда SH/PS1 тоже привести к разбору по первому `#`… НЕТ — выбрать вариант: SH-семантика (` #`) во всех платформах; CMD реализовать через `|CUT|`-приём с тестом.

- [ ] **Step 3: Регистр ключей:** SH (строка ~40,48): сравнение ключей после lowercase (`key=$(echo "$key" | tr 'A-Z' 'a-z')` — или `${key,,}` bash4); CMD: добавить `/i` ко всем `if "!_key!"=="..."` в `:assign_var`.

- [ ] **Step 4: SH backslash-пути** (строки ~78-79): после чтения `folder_sources="${folder_sources//\\//}"` (то же destination); абсолютным считать и `^[A-Za-z]:` :

```bash
case "$folder_sources" in
	/*|[A-Za-z]:*) ;; # абсолютный
	*) folder_sources="$SCRIPT_DIR/$folder_sources" ;;
esac
```

- [ ] **Step 5: build_exe.ps1 (оба проекта):** перед `Invoke-ps2exe` — `Remove-Item $out -Force -ErrorAction SilentlyContinue`; обернуть вызов в `$ErrorActionPreference='Stop'; try { ... } catch { Write-Host "FAIL: $_"; exit 1 }`.

- [ ] **Step 6: Тесты → PASS; полный прогон ffmpeg → PASS. Commit** — `git commit -m "run scripts: unify inline-comment and key case parsing, SH path normalization, build_exe fail-fast"`

---

## Task 9: yt-dlp — itag-таблицы (все 3 платформы) + avc1_best fallback

**Files:**
- Modify: `yt-dlp/Downloading_from_YouTube_v14.sh:232-256`, `.cmd:198-220`, `.ps1` (formatPresets, ~776-784)
- Test: `tests/yt-dlp/test_02/05/06` (дополнить по платформам)

Сломанные комбинации (аудио+аудио, несуществующие itag): `avc1_https` 1440/2160 (`140+138`, `140+139`), `avc1_m3u8` 1080/1440/2160 (`234+233`, `234+234`, `234+235`), `avc1_https_60fps` 360/480/1440/2160 (296/297/300/301), `old_combo` 480/1080/1440/2160 (20/24/26/28).

- [ ] **Step 1: Тесты:** для каждой платформы: пресет `avc1_https` + 2160 → format-строка содержит `140+266` и НЕ содержит `140+139`; `avc1_m3u8` + 1080 → НЕ содержит `234+233`; `old_combo` + 480 → НЕ содержит `20/`. Запустить → FAIL.

- [ ] **Step 2: Новые таблицы** (одинаковые на всех 3 платформах; селекторные fallback'и гарантируют корректную высоту даже если itag недоступен):

```
avc1_https:
  1440: 140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]
  2160: 140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]
avc1_https_60fps:
  360:  140+134/best[height<=360]          (60fps avc1 ниже 720 не существует — честный fallback)
  480:  140+135/best[height<=480]
  1440: 140+299/bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/best[height<=1440]
  2160: 140+299/bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/best[height<=2160]
avc1_m3u8:
  1080: 270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]
  1440: bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]
  2160: bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]
old_combo:
  480:  59/22/18
  1080: 37/22/18
  1440: 38/37/22/18
  2160: 38/37/22/18
```

ВНИМАНИЕ CMD: `protocol*=m3u8` и `<=` внутри `set` безопасны, но `^` и `!` — нет; в CMD-таблице уже применяется замена `ext!=webm`→`ext=m4a` — селекторы выше символа `!` не содержат, `^=` в CMD-строках экранировать как `^^=` при необходимости (проверить существующие записи-образцы в файле).

- [ ] **Step 3: avc1_best fallback в SH** (строки ~215-225) — добавить ту же fallback-альтернативу, что в PS1/CMD:

```bash
"bestaudio[ext!=webm]+bestvideo[height<=${H}][vcodec^=avc1]/bestaudio+bestvideo[height<=${H}]"
```

(для аудио-пресета: `bestaudio[ext!=webm]/bestaudio`).

- [ ] **Step 4: Тесты → PASS; прогон yt-dlp-тестов (`bash tests/run_tests.sh yt-dlp`, кроме test_04) → PASS. Commit** — `git commit -m "yt-dlp: fix broken itag tables (audio-only merges, nonexistent itags), unify avc1_best fallback"`

---

## Task 10: yt-dlp CMD — delayed expansion URL, кавычки, errorlevel, merge

**Files:**
- Modify: `yt-dlp/Downloading_from_YouTube_v14.cmd`
- Test: `tests/yt-dlp/test_05` (дополнить)

- [ ] **Step 1: Тесты:** (а) URL с `!` (`...watch?v=a!b!c`) доходит до yt-dlp-вызова неискажённым (через YTDLP_BIN-мок, который логирует argv); (б) путь скрипта с пробелом → вызов yt-dlp в кавычках; (в) после неуспешного vot печатается предупреждение. Запустить → FAIL.

- [ ] **Step 2: `%url%` → `!url!`** на строках 139, 272, 289, 308, 352; `%cookie_arg%` → `!cookie_arg!` (289, 308); `echo "%url%"` → `echo "!url!"` (139, 272).

- [ ] **Step 3: Кавычки бинарей:** `%dlp%` → `"!dlp!"` (289, 308); deno (298): `set "deno_arg=--js-runtimes "deno:%~dp0deno.exe""` — проверить итоговый argv в логе мока.

- [ ] **Step 4: vot errorlevel** (строки ~352-355):

```bat
set "vot_rc=!errorlevel!"
set "NODE_TLS_REJECT_UNAUTHORIZED="
if !vot_rc! GEQ 1 (
	echo [WARN] Не удалось получить AI-перевод
)
```

- [ ] **Step 5: Merge: проверка exit-кода ffmpeg** (строки ~372-382):

```bat
set "ff_rc=!errorlevel!"
if "!ff_rc!"=="0" if exist "!output_file!" (
	move /y "!output_file!" "!video_file!" >nul
) else (
	if exist "!output_file!" del /q "!output_file!"
	echo [WARN] Ошибка мержа перевода — оригинал сохранён
)
```

(точная структура — по текущему коду; ключевое: `move` только при rc=0, битый выход удалять).

- [ ] **Step 6: Пути от папки скрипта:** `set "folder=%~dp0_video_"` (строка ~10) — и все использования `_video_` (308, 365) через `!folder!`.

- [ ] **Step 7: Убрать `--no-check-certificate`** (289, 308) — паритет с SH.

- [ ] **Step 8: Тесты → PASS; прогон yt-dlp → PASS. Commit** — `git commit -m "yt-dlp CMD: preserve ! in URLs, quote binary paths, vot/ffmpeg exit codes, script-relative output dir"`

---

## Task 11: yt-dlp PS1/GUI — стоп-крэш, merge, паритет с SH

**Files:**
- Modify: `yt-dlp/Downloading_from_YouTube_v14.ps1`
- Test: `tests/yt-dlp/test_06` (дополнить — для тестируемых функций: Read-Config, формат-строки, qualityMap)

- [ ] **Step 1: Тесты (что тестируемо без GUI):** (а) `default_quality = audio` → индекс 0; (б) Read-Config: `pa#ss` в значении сохраняется (`\s+#`); (в) формат-строки avc1_best идентичны SH (после Task 9). Запустить → FAIL.

- [ ] **Step 2: Stop-Download крэш** (строка ~740 → ~999): в `Stop-Download` убрать `$global:downloadProcess = $null` (только Kill + флаг); на ~999:

```powershell
$proc = $global:downloadProcess
if ($proc) { $proc.WaitForExit() ; $exitCode = $proc.ExitCode } else { $exitCode = -1 }
```

- [ ] **Step 3: Убрать массовый kill** (строка ~739): удалить `Get-Process -Name "yt-dlp" | Stop-Process -Force` (Kill дочернего уже сделан).

- [ ] **Step 4: Merge с проверкой `$LASTEXITCODE`** (строки ~1103-1105):

```powershell
& $ffmpeg @ffArgs 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0 -and (Test-Path $outputFile)) {
	Move-Item -Force $outputFile $videoFile
} else {
	Remove-Item $outputFile -Force -ErrorAction SilentlyContinue
	Append-Output "Ошибка мержа перевода — оригинал сохранён"
}
```

- [ ] **Step 5: Кнопки очереди при загрузке** — в начале загрузки `$btnRemoveUrl.Enabled = $false; $btnClearQueue.Enabled = $false` (рядом с дизейблом btnStart), вернуть в конце/в finally.

- [ ] **Step 6: vot deadlock** (строки ~1071-1075):

```powershell
$errTask = $votProc.StandardError.ReadToEndAsync()
$votOut = $votProc.StandardOutput.ReadToEnd()
$votErr = $errTask.Result
```

- [ ] **Step 7: Паритет с SH:** (а) убрать `--no-check-certificate` (строка ~836); (б) `use_archive`/`archive_file` читать из config, при true добавлять `--download-archive (Join-Path $folder $archiveFile)`; (в) громкости: читать `original_volume`/`translation_volume`, подставить в filter_complex (строка ~1099); (г) `original_lang` → `language=` метаданные dual_track (строка ~1090) + метаданные в replace-ветке (как sh:435); (д) пути: `base_dir` и cookie-файл резолвить от `$scriptDir`, не `$PWD` (строки ~299, 865, 942); для cookie добавить `if (-not (Test-Path $cookieFile)) { Append-Output "WARN: cookie-файл не найден"; }` и пропуск аргумента.

- [ ] **Step 8: Read-Config `#`** (строка ~30): `'\s*#.*'` → `'\s+#.*'`.

- [ ] **Step 9: qualityMap** — добавить `"audio" = 0`.

- [ ] **Step 10: AI-перевод:** исключить аудио-only из условия (строка ~1018: `$qi -ge 1 -and $qi -le 6`); else-ветка при `$latestVideo -eq $null`: `Append-Output "Видео .mp4 для мержа не найдено — перевод пропущен"`.

- [ ] **Step 11: Утечка событий** (строки ~956-966): сохранить результаты `Register-ObjectEvent` в переменные; после `WaitForExit` — `Unregister-Event -SourceIdentifier ...; $proc.Dispose()`.

- [ ] **Step 12: BOM; syntax-check PSParser; тесты → PASS; прогон yt-dlp → PASS. Commit** — `git commit -m "yt-dlp PS1: fix Stop crash and process kill scope, merge exit-code check, SH parity (archive, volumes, paths, lang), event leaks"`

---

## Task 12: yt-dlp SH — deno, bash<4.4, translate rc, --no-mtime, continue_on_error (3 платформы)

**Files:**
- Modify: `yt-dlp/Downloading_from_YouTube_v14.sh`, `.cmd`, `.ps1`
- Test: `tests/yt-dlp/test_01/02` (дополнить)

- [ ] **Step 1: Тесты:** (а) `deno.exe` рядом со скриптом → `--js-runtimes` добавлен (SH); (б) `continue_on_error=false` → в argv НЕТ `-i`, есть `--abort-on-error`; true → есть `-i` (все 3 платформы); (в) при включённом переводе argv содержит `--no-mtime`. Запустить → FAIL.

- [ ] **Step 2: deno detection SH** (строки ~319, 488): проверять `deno` И `deno.exe` (по образцу yt-dlp-детекта, sh:31-34).

- [ ] **Step 3: env_prefix bash<4.4** (строки ~365, 540): `${env_prefix[@]+"${env_prefix[@]}"}`.

- [ ] **Step 4: translate rc parity** (строки ~816-831): сохранить rc `download_url`; в translate-ветку входить только при rc=0 (паритет с CMD).

- [ ] **Step 5: `--no-mtime` при переводе** — SH/CMD/PS1: если AI-перевод включён, добавить `--no-mtime` в аргументы yt-dlp (механизм выбора файла опирается на mtime; старые yt-dlp ставили mtime в прошлое).

- [ ] **Step 6: continue_on_error** — реализовать на всех 3: значение уже читается (SH `CONTINUE_ON_ERROR`); при `true` → `-i`, при `false` → `--abort-on-error` (заменить захардкоженный `-i` в sh:314,485; cmd:289,308; ps1:836).

- [ ] **Step 7: Тесты → PASS; прогон yt-dlp → PASS. Commit** — `git commit -m "yt-dlp: deno.exe detect, bash<4.4 arrays, translate rc parity, --no-mtime with translation, wire continue_on_error"`

---

## Task 13: Фича — подстановка ${ENV_VAR} в config.ini (yt-dlp, 3 платформы)

**Files:**
- Modify: `yt-dlp/Downloading_from_YouTube_v14.sh` (load_config), `.cmd` (:assign_var/парсер), `.ps1` (Read-Config)
- Modify: `yt-dlp/config.example.ini` — если существует; иначе НЕ создавать
- Modify: `.sanitize-patterns` (локальный, gitignored)
- Test: `tests/yt-dlp/test_01` (SH), `test_05` (CMD), `test_06` (PS1)

Семантика: если значение содержит `${NAME}` — заменить на значение переменной окружения `NAME`; если переменная не задана — заменить на пустую строку и напечатать предупреждение `WARN: переменная NAME не задана`. Несколько вхождений поддерживаются. Литеральных `${` в легитимных значениях не бывает (yt-dlp-шаблоны используют `%(...)s`).

- [ ] **Step 1: Тесты:** для каждой платформы: config с `url = ${TEST_PROXY}` + `TEST_PROXY=https://x:y@h:1` в окружении → распарсенное значение равно env; без переменной → пустая строка + WARN. Запустить → FAIL.

- [ ] **Step 2: SH** — в load_config после получения `value`:

```bash
while [[ "$value" == *'${'*'}'* ]]; do
	local _vn="${value#*\$\{}"; _vn="${_vn%%\}*}"
	[ -n "${!_vn:-}" ] || echo "WARN: переменная $_vn не задана" >&2
	value="${value//\$\{$_vn\}/${!_vn:-}}"
done
```

- [ ] **Step 3: PS1** — в Read-Config после трима значения:

```powershell
$val = [regex]::Replace($val, '\$\{(\w+)\}', {
	param($m)
	$ev = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
	if ($null -eq $ev) { Write-Host "WARN: переменная $($m.Groups[1].Value) не задана" ; "" } else { $ev }
})
```

- [ ] **Step 4: CMD** — после получения `_val`:

```bat
:expand_env
if "!_val!"=="" exit /b
echo(!_val! | findstr /c:"${" >nul || exit /b
for /f "tokens=2 delims={}" %%N in ("!_val!") do (
	if defined %%N (
		call set "_val=%%_val:${%%N}=!%%N!%%"
	) else (
		echo WARN: переменная %%N не задана
		call set "_val=%%_val:${%%N}=%%"
	)
)
goto :expand_env
```

ВНИМАНИЕ: `echo(!_val! | findstr` — здесь пайп с `&`-риском (Task 2!); заменить на подстрочную проверку: `if "!_val!"=="!_val:${=!" exit /b`.

- [ ] **Step 5: Документация** — в комментарий секции `[proxy]` шаблонного конфига (`config.example.ini`, если есть; иначе в README, если есть секция про конфиг): `# Поддерживается подстановка из окружения: url = ${PROXY_URL}`.

- [ ] **Step 6: .sanitize-patterns** (локальный) — добавить строки-маски: имя пользователя прокси, пароль, хост из текущего `yt-dlp/config.ini:3` (точные значения взять из файла). НЕ коммитить (файл gitignored).

- [ ] **Step 7: Тесты → PASS; полный прогон yt-dlp → PASS. Commit** — `git commit -m "yt-dlp: support \${ENV_VAR} substitution in config.ini values (all platforms)"`

---

## Task 14: Финальная верификация, статусы, EXE

**Files:**
- Modify: `FINDINGS.md`, `IDEAS.md`
- Rebuild: `ffmpeg/build_exe.ps1`, `yt-dlp/build_exe.ps1`

- [ ] **Step 1: Полный прогон** — `bash tests/run_tests.sh` (все, кроме test_04_integration) → 100% PASS.

- [ ] **Step 2: FINDINGS.md** — обе записи [ANALYSIS-LOGIC] → `**Статус:** done` + `**Resolved:** 2026-06-10 — <что сделано>`. IDEAS.md — запись про env-переменные → `**Статус:** done`.

- [ ] **Step 3: Rebuild EXE** — `powershell -File ffmpeg/build_exe.ps1` и `powershell -File yt-dlp/build_exe.ps1` → оба SUCCESS (с новым fail-fast из Task 8 это честный SUCCESS).

- [ ] **Step 4: Pre-commit sanity** — `git config core.hooksPath` = `.githooks`; `git diff --staged` не содержит секретов/IP (hook проверит, но глазами тоже).

- [ ] **Step 5: Финальный commit** — `git add -A && git commit -m "Close analysis findings: statuses, rebuilt EXEs"`

---

## Self-Review (выполнен)

- Покрытие: все P1 (4) — Tasks 1, 2, 3, 9; все P2 — Tasks 1-12; P3 — Tasks 5-12; фича — Task 13; wontfix задокументированы в шапке.
- Двусмысленности сняты: itag-таблицы заданы конкретно; split_by_silence CMD имеет fallback-вариант; GUI write-back — wontfix по дизайну.
- Типы/имена: `$muxer_out`/`muxer_out` согласованы между Task 3/4/5; схема экранирования субтитров едина (Task 4 Step 6 ↔ Task 5 Step 9).
