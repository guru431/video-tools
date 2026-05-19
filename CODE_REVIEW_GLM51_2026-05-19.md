# Code Review Findings — 2026-05-19 (GLM-5.1)

Автоматический code review через GLM-5.1 (OpenCode Go).
Логи: `_boss/cron/logs/multi-review_glm51_video_2026-05-19.log`

**Повторный прогон** после 2026-05-18 (`CODE_REVIEW_FINDINGS_2026-05-18.md`).

## Сводка

| Severity | Total | Valid | Partial | Halluc |
|---|---|---|---|---|
| P1 | 3 | 3 | 0 | 0 |
| P2 | 8 | (не валидировалось) | - | - |
| P3 | 2 | (не валидировалось) | - | - |

**Регрессии:** нет. Все 3 P1 текущего прогона — **новые** находки, не пересекаются с 5 P1 из 2026-05-18 (SSL bypass, eval в .sh, Invoke-Expression в .ps1, proxy password в command line, CMD nested quotes). Это означает либо прошлые P1 уже починены и GLM теперь видит другие, либо GLM варьирует фокус между прогонами.

## Valid P1

### 1. Парсинг битрейта без fallback в `video/ffmpeg/FFmpeg_Converter_script.cmd:130-132`
**Категория:** bug
**Что:** `find /i "bitrate:"` + `tokens=6` нестабильный, и при пустом результате `set_video_bitrate_final` остаётся пустой → ffmpeg запускается без `-b:v`, битрейт получается дефолтный или неограниченный.
**Fix:** Добавить проверку `if not defined set_video_bitrate_final set set_video_bitrate_final=-b:v !set_video_bitrate_orig!k`. Или регулярно проверять, что число действительно извлечено перед использованием.

### 2. Race condition при параллельной обработке в `video/ffmpeg/FFmpeg_Converter_script.sh:327-339`
**Категория:** bug
**Что:** При `parallel_files > 1` `encode_file` запускается в фоне, но переменные `vf_chain`, `af_chain`, `split_points`, `length_coding_value_silent${i}` — глобальные. Параллельные процессы перезаписывают друг друга → точки разреза перемешиваются между файлами. Финдинг частично перекрывается с P2 из 2026-05-18 (race на `r_$$_timestamp`), но указывает на более глубокую проблему — глобальное состояние, а не только имена файлов результатов.
**Fix:** Объявить переменные внутри `encode_file` как `local`. Использовать `local -A` ассоциативный массив вместо `eval`-генерированных имён. Альтернатива: убрать параллелизм для split_by_silence.

### 3. Прокси-пароль в `video/yt-dlp/config.ini:3` (committed)
**Категория:** security
**Что:** В репозиторий закоммичен URL прокси с паролем: `url = https://user:pass@host:port`. Пароль виден в git-истории и доступен всем, кто читает код. Проверено — файл существует, пароль реальный.
**Fix:** Удалить пароль из `config.ini`. Использовать переменные окружения (`HTTPS_PROXY`) или отдельный `config.local.ini` в `.gitignore`. Закоммитить `config.ini.example` без пароля. Опционально — пересоздать пароль на стороне прокси (так как он уже в истории).

## Partial P1
Нет.

## Halluc P1
Нет.

## P2 (backlog)

| # | file | category | description |
|---|---|---|---|
| 1 | `ffmpeg/FFmpeg_Converter_run_v13.cmd:14-15` | inconsistency | hw_accel default `:-:nvidia` в CMD vs `+intel` в config.ini |
| 2 | `ffmpeg/FFmpeg_Converter_script.cmd:197-199` | bug | Парсинг Duration через tokens=2,3,4 без проверки N/A → duration=0 |
| 3 | `ffmpeg/FFmpeg_Converter_script.cmd:219-224` | security | Неполное экранирование пути для subtitles= фильтра (] [ %) |
| 4 | `ffmpeg/FFmpeg_Converter_script.ps1:282-284` | bug | $out_file без кавычек в ffmpegArgs → пробелы в путях ломают Arguments |
| 5 | `ffmpeg/FFmpeg_Converter_script.sh:314-316` | bug | export -f encode_file экспортирует функцию, но переменные глобальные |
| 6 | `ffmpeg/FFmpeg_Converter_script.sh:233-234` | portability | `stat -c%s` не работает на macOS (там `-f%z`) |
| 7 | `ffmpeg/FFmpeg_Converter_script.sh:248-252` | bug | split_points без local → race condition при parallel |
| 8 | `yt-dlp/Downloading_from_YouTube_v13.ps1:527-530` | security | `NODE_TLS_REJECT_UNAUTHORIZED=0` через env-var, не per-process |

## P3 (backlog)

| # | file | category | description |
|---|---|---|---|
| 1 | `ffmpeg/FFmpeg_Converter_run_win_v13.ps1:680-685` | correctness | `comboVideoRotation.SelectedIndex + 1` — хрупко при изменении порядка |
| 2 | `ffmpeg/FFmpeg_Converter_script.ps1:345-347` | optimization | Get-ChildItem не кэшируется в цикле |
