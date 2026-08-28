# Удалённый бэкенд ffmpeg — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Скрипты `ffmpeg/` получают второй бэкенд вычисления: при `[remote] enabled = yes` кодирование уезжает на HTTP-службу конвертации, а вся оркестрация файлов остаётся клиентской.

**Architecture:** Отдельные модули `ffmpeg/remote_client.sh` и `ffmpeg/remote_client.ps1` подключаются в `FFmpeg_Converter_script.sh`/`.ps1` и подменяют **ровно один участок** `encode_file` — запуск ffmpeg с прогресс-циклом. Загрузка → задача → скачивание в тот же `partial_path`, дальше существующая валидация `-f null -`, `mv`, `manifest`, сводка. `.cmd` читает ключи и печатает предупреждение.

**Tech Stack:** Bash 3.2+ (`curl`, `sha256sum`/`shasum`, `dd`), PowerShell 5.1 (`System.Net.HttpWebRequest`, `Get-FileHash`, `ConvertFrom-Json`), WinForms (GUI), тестовый фреймворк `tests/lib/framework.sh`.

**Spec:** [`docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md`](../specs/2026-08-28-ffmpeg-remote-backend-design.md)

## Global Constraints

Каждая задача обязана их соблюдать. Значения взяты из спеки и из `CLAUDE.md` дословно.

- **Репозиторий публичный.** Ни адрес службы, ни ключ не попадают ни в один коммитимый файл. В `config.ini` стоят только `${TRANSCODE_URL}` и `${TRANSCODE_API_KEY}`.
- **Кодировки:** `.ps1` — UTF-8 **с BOM**; `.sh` — UTF-8 **без BOM**; `.cmd` — `@chcp 65001` и **CRLF обязательны**.
- **Паритет ключей:** каждый ключ `ffmpeg/config.ini` обязан читаться в `run.sh` **И** `run.cmd` **И** `run.ps1` — этого требует `tests/common/test_config_keys.sh`.
- **Никакого `jq`.** В Git Bash его нет. JSON разбирается собственным экстрактором плоских полей.
- **Не `Invoke-WebRequest`** для тела ответа: PowerShell 5.1 буферизует его целиком в память, результат на 3 ГБ убьёт процесс. Только `System.Net.HttpWebRequest` с потоковым `FileStream`.
- **Тесты не ходят в сеть.** Бинарь `curl` инжектируется через `CURL_BIN`, HTTP-слой `.ps1` — через подменяемую функцию. Bare-вызов должен громко падать.
- **Коммиты без trailer'а `Co-Authored-By`** — правило репозитория.
- **Отказ громкий.** Автоматического отката на локальный ffmpeg нет ни в одной задаче.
- **Прогон тестов:** `bash tests/run_tests.sh ffmpeg` и `bash tests/run_tests.sh common`. Итоговые числа тестов в документацию не переносить — они устаревают.

---

### Task 1: Секция `[remote]` в конфиге и её чтение на трёх платформах

**Files:**
- Modify: `ffmpeg/config.ini` (добавить секцию в конец)
- Modify: `ffmpeg/FFmpeg_Converter_run_v17.sh:143-149` (рядом с блоком `[split]`/`[other]`)
- Modify: `ffmpeg/FFmpeg_Converter_run_v17.ps1`
- Modify: `ffmpeg/FFmpeg_Converter_run_v17.cmd:12-52` (умолчания) и `:190-197` (`:assign_var`)
- Modify: `tests/config-key-contract.yaml`
- Test: `tests/common/test_config_keys.sh` (существующий, должен остаться зелёным), `tests/common/test_config_contract.sh`

**Interfaces:**
- Produces: переменные `remote_enabled`, `remote_endpoint`, `remote_api_key`, `remote_prefer`, `remote_wait_timeout` во всех трёх `run`-файлах (в `.ps1` — те же имена с `$`). Все последующие задачи читают именно их.

- [ ] **Step 1: Дописать секцию в `ffmpeg/config.ini`**

```ini

[remote]
# Считать на сервере конвертации вместо локального ffmpeg (yes/no)
enabled = no
# Адрес API службы. Приватное значение — задаётся переменной окружения
endpoint = ${TRANSCODE_URL}
# Bearer-ключ службы — тоже переменной окружения
api_key = ${TRANSCODE_API_KEY}
# Где считать на сервере: auto (ждать карту, потом процессор), gpu, cpu
prefer = auto
# Сколько ждать окна на карте, секунды
wait_timeout = 1800
```

- [ ] **Step 2: Прогнать контракт-тест и убедиться, что он покраснел**

Run: `bash tests/common/test_config_keys.sh`
Expected: FAIL — пять новых ключей не читаются ни в одном `run`-файле (15 провалов: 5 ключей × 3 платформы).

- [ ] **Step 3: Читать ключи в `FFmpeg_Converter_run_v17.sh`**

После блока `[split]` (строка ~142), перед `save_old_extension`:

```bash
remote_enabled="$(read_config "enabled" "remote" "no")"
remote_endpoint="$(read_config "endpoint" "remote" "")"
remote_api_key="$(read_config "api_key" "remote" "")"
remote_prefer="$(read_config "prefer" "remote" "auto")"
remote_wait_timeout="$(read_config "wait_timeout" "remote" "1800")"
# Хвостовой слэш в адресе даёт "…/v1//jobs" — служба отвечает 404 на путь,
# который человеку выглядит верным. Снимаем здесь, в единственном месте чтения.
remote_endpoint="${remote_endpoint%/}"
```

- [ ] **Step 4: Читать ключи в `FFmpeg_Converter_run_v17.ps1`**

В том же месте относительно других секций:

```powershell
$remote_enabled      = Read-Config "enabled" "remote" "no"
$remote_endpoint     = (Read-Config "endpoint" "remote" "").TrimEnd('/')
$remote_api_key      = Read-Config "api_key" "remote" ""
$remote_prefer       = Read-Config "prefer" "remote" "auto"
$remote_wait_timeout = Read-Config "wait_timeout" "remote" "1800"
```

- [ ] **Step 5: Читать ключи в `FFmpeg_Converter_run_v17.cmd`**

В блок умолчаний (после строки `set "log_file=ffmpeg_convert.log"`):

```cmd
set "remote_enabled=no"
set "remote_endpoint="
set "remote_api_key="
set "remote_prefer=auto"
set "remote_wait_timeout=1800"
```

В `:assign_var`, после блока `if /i "!_section!"=="other"`:

```cmd
if /i "!_section!"=="remote" (
	if /i "!_key!"=="enabled" set "remote_enabled=!_val!"
	if /i "!_key!"=="endpoint" set "remote_endpoint=!_val!"
	if /i "!_key!"=="api_key" set "remote_api_key=!_val!"
	if /i "!_key!"=="prefer" set "remote_prefer=!_val!"
	if /i "!_key!"=="wait_timeout" set "remote_wait_timeout=!_val!"
)
```

Файл сохранить с **CRLF** — иначе cmd.exe склеит строки блока `( … )`.

- [ ] **Step 6: Предупреждение в `.cmd` при `enabled = yes`**

Сразу после метки `:start_coding` в `FFmpeg_Converter_run_v17.cmd`:

```cmd
if /i "%remote_enabled%"=="yes" (
	echo [ПРЕДУПРЕЖДЕНИЕ] Удалённый бэкенд ^([remote] enabled^) в CMD-версии не поддерживается:
	echo [ПРЕДУПРЕЖДЕНИЕ] нет нарезки файла по смещениям, sha256 и разбора JSON. Файлы считаются локально.
	echo [ПРЕДУПРЕЖДЕНИЕ] Для удалённого счёта используйте .sh, .ps1 или GUI.
)
```

- [ ] **Step 7: Записать исключение в `tests/config-key-contract.yaml`**

В блок `ffmpeg.exceptions`, рядом с `sh_only_behavior`:

```yaml
    # Удалённый бэкенд — только .sh/.ps1/GUI: в cmd.exe нет нарезки файла по
    # смещениям, sha256 и разбора JSON. Ключи в .cmd читаются и дают явное
    # предупреждение, поэтому в общем правиле трёхплатформенного паритета
    # остаются — здесь фиксируется именно расхождение ПОВЕДЕНИЯ.
    sh_ps1_only_behavior:
      - enabled
      - endpoint
      - api_key
      - prefer
      - wait_timeout
```

- [ ] **Step 8: Прогнать тесты**

Run: `bash tests/run_tests.sh common`
Expected: PASS, `fail=0`.

- [ ] **Step 9: Убедиться, что приватного не добавилось**

Run: `git diff --cached; git diff` и глазами проверить, что в диффе нет ни IP-адреса, ни ключа.
Expected: только `${TRANSCODE_URL}` и `${TRANSCODE_API_KEY}`.

- [ ] **Step 10: Коммит**

```bash
git add ffmpeg/config.ini ffmpeg/FFmpeg_Converter_run_v17.sh ffmpeg/FFmpeg_Converter_run_v17.ps1 ffmpeg/FFmpeg_Converter_run_v17.cmd tests/config-key-contract.yaml
git commit -m "remote: секция [remote] в config.ini и её чтение на трёх платформах"
```

---

### Task 2: Отображение `config.ini` на операцию службы (`.sh`)

Чистая функция без сети. Именно она определяет паритет с локальным путём, поэтому идёт первой и отдельно.

**Files:**
- Create: `ffmpeg/remote_client.sh`
- Test: `tests/ffmpeg/test_20_remote_map.sh`

**Interfaces:**
- Consumes: разобранные переменные `FFmpeg_Converter_script.sh`: `set_video_codec`, `video_quality_status`/`_value`, `video_bitrate_status`/`_value`, `video_resolution_status`/`_value`, `video_number_frames_status`/`_value`, `video_rotation_status`/`_value`, `video_subtitles_status`/`_value`, `keep_aspect_ratio_value`, `output_container_value`, `audio_*_status`/`_value`, `playback_speed_status`/`_value`, `gpu_preset_*`, `gpu_tune_*`, `gpu_rc_*`, `threads`, `subtitles_style`, `hw_accel_status`/`_value`.
- Produces:
  - `remote_json_escape <строка>` → экранированная строка без кавычек-обёрток
  - `remote_map_codec <энкодер>` → `h264`|`hevc`|`av1`, код 1 если кодек неизвестен
  - `remote_op_for_config <start_sec> <length_sec>` → две строки: операция, затем JSON параметров

- [ ] **Step 1: Написать падающий тест**

Создать `tests/ffmpeg/test_20_remote_map.sh`:

```bash
#!/bin/bash
# ============================================================
# test_20_remote_map.sh — отображение config.ini на операции службы.
# Чистые функции, сети нет вовсе.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

suite "remote: отображение кодеков"
assert_eq "libx264 → h264"    "h264" "$(remote_map_codec libx264)"
assert_eq "h264_nvenc → h264" "h264" "$(remote_map_codec h264_nvenc)"
assert_eq "h264_qsv → h264"   "h264" "$(remote_map_codec h264_qsv)"
assert_eq "libx265 → hevc"    "hevc" "$(remote_map_codec libx265)"
assert_eq "hevc_nvenc → hevc" "hevc" "$(remote_map_codec hevc_nvenc)"
assert_eq "libsvtav1 → av1"   "av1"  "$(remote_map_codec libsvtav1)"
assert_eq "av1_nvenc → av1"   "av1"  "$(remote_map_codec av1_nvenc)"
if remote_map_codec libvpx-vp9 >/dev/null 2>&1; then
    fail "неизвестный кодек отвергается" "код возврата 1" "код возврата 0"
else
    pass "неизвестный кодек отвергается"
fi

suite "remote: экранирование JSON"
assert_eq "кавычка"     'a\"b'   "$(remote_json_escape 'a"b')"
assert_eq "обратный слэш" 'a\\b' "$(remote_json_escape 'a\b')"

# Минимальный набор переменных, какой даёт FFmpeg_Converter_script.sh после парсинга.
_setup_cfg() {
    set_video_codec="libx264"
    video_quality_status="+";      video_quality_value="23"
    video_bitrate_status="-";      video_bitrate_value="3000"
    video_resolution_status="+";   video_resolution_value="1280x720"
    video_number_frames_status="+"; video_number_frames_value="30"
    video_rotation_status="-";     video_rotation_value="2"
    video_subtitles_status="-";    video_subtitles_value="burn"
    keep_aspect_ratio_value="yes"
    output_container_value="mp4"
    audio_codec_status="+";           audio_codec_value="aac"
    audio_number_channels_status="+"; audio_number_channels_value="2"
    audio_bitrate_status="+";         audio_bitrate_value="128"
    audio_sampling_rate_status="+";   audio_sampling_rate_value="48000"
    audio_normalize_status="-";       audio_normalize_value="loudnorm"
    playback_speed_status="-";     playback_speed_value="1.0"
    gpu_preset_status="-";  gpu_preset_value="p5"
    gpu_tune_status="-";    gpu_tune_value="hq"
    gpu_rc_status="-";      gpu_rc_value="vbr"
    hw_accel_status="-";    hw_accel_value="intel"
    threads="4"
    subtitles_style=""
}

suite "remote: операция и параметры"
_setup_cfg
out="$(remote_op_for_config 0 0)"
op="$(printf '%s' "$out" | head -1)"
params="$(printf '%s' "$out" | tail -1)"
assert_eq "без start/length → transcode" "transcode" "$op"
assert_contains "кодек"       '"codec":"h264"'    "$params"
assert_contains "качество"    '"quality":23'      "$params"
assert_contains "разрешение"  '"resolution":"1280x720"' "$params"
assert_contains "пропорции"   '"keep_aspect":true' "$params"
assert_contains "кадры"       '"fps":30'          "$params"
assert_contains "контейнер"   '"container":"mp4"' "$params"
assert_contains "потоки"      '"threads":4'       "$params"
assert_contains "звук"        '"audio":{'         "$params"
assert_contains "аудиокодек"  '"codec":"aac"'     "$params"
assert_not_contains "выключенный битрейт не уехал" '"bitrate":3000' "$params"
assert_not_contains "выключенный поворот не уехал" '"rotate"'       "$params"
assert_not_contains "скорость 1.0 не уехала"       '"speed"'        "$params"

suite "remote: start/length → cut"
_setup_cfg
out="$(remote_op_for_config 60 300)"
op="$(printf '%s' "$out" | head -1)"
params="$(printf '%s' "$out" | tail -1)"
assert_eq "со start/length → cut" "cut" "$op"
assert_contains "начало"    '"start":60'       "$params"
assert_contains "конец"     '"end":360'        "$params"
assert_contains "перекод"   '"reencode":true'  "$params"
assert_contains "кодек на месте" '"codec":"h264"' "$params"

suite "remote: включённые необязательные поля"
_setup_cfg
video_bitrate_status="+"
video_rotation_status="+"
playback_speed_status="+"; playback_speed_value="1.75"
audio_normalize_status="+"
gpu_preset_status="+"
video_quality_status="-"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains "битрейт в бит/с"    '"bitrate":3000000'          "$params"
assert_contains "потолок исходного"  '"bitrate_cap_source":true'  "$params"
assert_contains "поворот"            '"rotate":"2"'               "$params"
assert_contains "скорость"           '"speed":1.75'               "$params"
assert_contains "нормализация"       '"normalize":"loudnorm"'     "$params"
assert_contains "пресет"             '"preset":"p5"'              "$params"
assert_not_contains "quality и bitrate вместе — 400 у службы" '"quality"' "$params"

suite "remote: субтитры и стиль"
_setup_cfg
video_subtitles_status="+"; video_subtitles_value="burn"
subtitles_style="FontName=Arial,FontSize=24"
params="$(remote_op_for_config 0 0 | tail -1)"
assert_contains "режим субтитров" '"subtitles":"burn"' "$params"
assert_contains "стиль"           '"subtitle_style":"FontName=Arial,FontSize=24"' "$params"

summary
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `bash tests/ffmpeg/test_20_remote_map.sh`
Expected: FAIL — `ffmpeg/remote_client.sh: No such file or directory`.

- [ ] **Step 3: Написать `ffmpeg/remote_client.sh`**

Файл — **UTF-8 без BOM**.

```bash
#!/bin/bash
# ============================================================
# Удалённый бэкенд — клиент службы конвертации (Bash)
#
# Подключается из FFmpeg_Converter_script.sh. Ничего не запускает сам:
# только функции. Так модуль можно дот-сорсить в тест без сети и без
# побочных эффектов — тем же приёмом, что и run-файлы.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

# --- JSON: сборка ---
# Экранируем ровно два символа, которые ломают строковый литерал JSON.
# Управляющие символы в наших значениях (кодеки, разрешения, стиль ASS)
# не встречаются: их бы отверг белый список службы ещё раньше.
remote_json_escape() {
	local s="$1"
	s="${s//\\/\\\\}"
	s="${s//\"/\\\"}"
	printf '%s' "$s"
}

# --- Отображение энкодера на кодек службы ---
# Служба принимает СЕМЕЙСТВО (h264/hevc/av1) и сама выбирает nvenc или
# программный энкодер по тому, где считает. Поэтому и libx264, и h264_nvenc,
# и h264_qsv отображаются в одно значение: разницу между ними на удалённом
# пути определяет очередь службы, а не наш config.ini.
remote_map_codec() {
	case "$1" in
		libx264|h264_nvenc|h264_qsv)   printf 'h264' ;;
		libx265|hevc_nvenc|hevc_qsv)   printf 'hevc' ;;
		libsvtav1|av1_nvenc|av1_qsv)   printf 'av1'  ;;
		*) return 1 ;;
	esac
}

# --- Операция и параметры из уже разобранного config.ini ---
# Аргументы: <начало в секундах> <длительность в секундах>; 0 0 = файл целиком.
# Печатает две строки: операцию и JSON параметров.
#
# Незнакомое службе поле — отказ 400, а НЕ молчаливое игнорирование. Обратное
# тоже верно и опаснее: поле, которое мы не отправили, примет умолчание службы,
# и результат тихо разойдётся с локальным. Поэтому каждое включённое (+) поле
# config.ini обязано оказаться здесь.
remote_op_for_config() {
	local start_sec="${1:-0}" length_sec="${2:-0}"
	local op="transcode" p=""

	local codec
	codec="$(remote_map_codec "$set_video_codec")" || return 1
	p="\"codec\":\"$codec\""

	# quality и bitrate вместе служба отвергает 400. Локальный скрипт при
	# включённом quality игнорирует битрейт — повторяем это правило здесь.
	if [ "$video_quality_status" = "+" ]; then
		p="$p,\"quality\":$video_quality_value"
	elif [ "$video_bitrate_status" = "+" ]; then
		# config.ini задаёт кбит/с, служба принимает бит/с.
		p="$p,\"bitrate\":$((video_bitrate_value * 1000)),\"bitrate_cap_source\":true"
	fi

	[ "$video_resolution_status" = "+" ] && p="$p,\"resolution\":\"$video_resolution_value\""
	if [ "$keep_aspect_ratio_value" = "yes" ]; then
		p="$p,\"keep_aspect\":true"
	else
		p="$p,\"keep_aspect\":false"
	fi
	[ "$video_number_frames_status" = "+" ] && p="$p,\"fps\":$video_number_frames_value"
	[ "$video_rotation_status" = "+" ]      && p="$p,\"rotate\":\"$video_rotation_value\""
	# speed=1.0 не отправляем: это умолчание службы, и лишнее поле только
	# расширяет площадь расхождения при сверке холостых прогонов.
	if [ "$playback_speed_status" = "+" ] && [ "$playback_speed_value" != "1.0" ]; then
		p="$p,\"speed\":$playback_speed_value"
	fi

	if [ "$video_subtitles_status" = "+" ]; then
		p="$p,\"subtitles\":\"$video_subtitles_value\""
		[ -n "$subtitles_style" ] && \
			p="$p,\"subtitle_style\":\"$(remote_json_escape "$subtitles_style")\""
	fi

	p="$p,\"container\":\"$output_container_value\""
	p="$p,\"threads\":${threads:-4}"

	[ "$gpu_preset_status" = "+" ] && p="$p,\"preset\":\"$gpu_preset_value\""
	[ "$gpu_tune_status" = "+" ]   && p="$p,\"tune\":\"$gpu_tune_value\""
	[ "$gpu_rc_status" = "+" ]     && p="$p,\"rc\":\"$gpu_rc_value\""

	local a="\"codec\":\"${audio_codec_value}\""
	[ "$audio_codec_status" = "+" ] || a="\"codec\":\"copy\""
	[ "$audio_bitrate_status" = "+" ]         && a="$a,\"bitrate\":$audio_bitrate_value"
	[ "$audio_number_channels_status" = "+" ] && a="$a,\"channels\":$audio_number_channels_value"
	[ "$audio_sampling_rate_status" = "+" ]   && a="$a,\"rate\":$audio_sampling_rate_value"
	[ "$audio_normalize_status" = "+" ]       && a="$a,\"normalize\":\"$audio_normalize_value\""
	p="$p,\"audio\":{$a}"

	# Отрезок — это op: cut с перекодированием, а не op: split. Разрезание на
	# части остаётся клиентским циклом: имена part.N и manifest строит он, и
	# отдать их назначение серверу значило бы переписать обе вещи (раздел 3.1).
	if [ "$start_sec" -gt 0 ] 2>/dev/null || [ "$length_sec" -gt 0 ] 2>/dev/null; then
		op="cut"
		p="\"start\":$start_sec,\"reencode\":true,$p"
		[ "$length_sec" -gt 0 ] 2>/dev/null && \
			p="\"end\":$((start_sec + length_sec)),$p"
	fi

	printf '%s\n{%s}\n' "$op" "$p"
}
```

- [ ] **Step 4: Прогнать тест**

Run: `bash tests/ffmpeg/test_20_remote_map.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 5: Коммит**

```bash
git add ffmpeg/remote_client.sh tests/ffmpeg/test_20_remote_map.sh
git commit -m "remote: отображение config.ini на операции службы (.sh)"
```

---

### Task 3: HTTP-слой, `capabilities` и мок `curl` (`.sh`)

**Files:**
- Modify: `ffmpeg/remote_client.sh`
- Create: `tests/mocks/curl`
- Modify: `tests/lib/framework.sh` (добавить `curl` в сетевой guard)
- Test: `tests/ffmpeg/test_21_remote_client.sh`

**Interfaces:**
- Consumes: `remote_endpoint`, `remote_api_key` (Task 1).
- Produces:
  - `remote_http <метод> <путь> [тело] [доп-заголовок…]` → тело ответа на stdout, HTTP-код в `REMOTE_HTTP_CODE`
  - `remote_json_field <json> <ключ>` → значение плоского поля
  - `remote_preflight` → 0 или 1; при отказе печатает причину; заполняет `REMOTE_CAPS_ARGS_VERSION`

- [ ] **Step 1: Написать падающий тест**

Создать `tests/ffmpeg/test_21_remote_client.sh`:

```bash
#!/bin/bash
# ============================================================
# test_21_remote_client.sh — HTTP-слой клиента службы.
# Сети нет: curl подменяется моком через CURL_BIN.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

export CURL_BIN="$TESTS_DIR/mocks/curl"
export MOCK_CURL_LOG; MOCK_CURL_LOG="$(mktemp "${TMPDIR:-/tmp}/mock_curl_XXXXXX")"
remote_endpoint="http://mock.invalid/v1"
remote_api_key="test-key"

suite "remote: разбор плоского JSON"
_j='{"job_id":"abc123","state":"running","progress":42,"reused":false,"note":null}'
assert_eq "строка"       "abc123"  "$(remote_json_field "$_j" job_id)"
assert_eq "строка 2"     "running" "$(remote_json_field "$_j" state)"
assert_eq "число"        "42"      "$(remote_json_field "$_j" progress)"
assert_eq "false"        "false"   "$(remote_json_field "$_j" reused)"
assert_empty "нет поля"            "$(remote_json_field "$_j" missing)"
# Ключ-подстрока не должен матчиться вместо полного имени.
assert_empty "частичный ключ"      "$(remote_json_field "$_j" job)"

suite "remote: HTTP-слой"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_BODY='{"status":"ok"}'
export MOCK_CURL_CODE=200
body="$(remote_http GET /health)"
assert_eq "тело ответа" '{"status":"ok"}' "$body"
assert_eq "код ответа"  "200"             "$REMOTE_HTTP_CODE"
assert_contains "ключ в заголовке" "Authorization: Bearer test-key" "$(cat "$MOCK_CURL_LOG")"
assert_contains "адрес собран"     "http://mock.invalid/v1/health"  "$(cat "$MOCK_CURL_LOG")"

suite "remote: preflight"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"args_version":"3","encoders":["h264_nvenc","hevc_nvenc"],"chunk_size":1048576}'
set_video_codec="libx264"
if remote_preflight >/dev/null 2>&1; then pass "живая служба принята"
else fail "живая служба принята" "код 0" "код 1"; fi
assert_eq "версия сборщика запомнена" "3" "$REMOTE_CAPS_ARGS_VERSION"
assert_eq "размер куска запомнен" "1048576" "$REMOTE_CHUNK_SIZE"

export MOCK_CURL_CODE=401
export MOCK_CURL_BODY='{"error":"нужен Bearer-ключ"}'
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "401 отвергается" "1" "$rc"
assert_contains "причина названа" "401" "$out"

export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"args_version":"3","encoders":["hevc_nvenc"],"chunk_size":1048576}'
remote_endpoint=""
out="$(remote_preflight 2>&1)"; rc=$?
assert_eq "пустой адрес отвергается" "1" "$rc"
assert_contains "названа переменная" "TRANSCODE_URL" "$out"
remote_endpoint="http://mock.invalid/v1"

rm -f "$MOCK_CURL_LOG"
summary
```

- [ ] **Step 2: Прогнать тест и убедиться, что он падает**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: FAIL — `remote_json_field: command not found`.

- [ ] **Step 3: Написать мок `tests/mocks/curl`**

Файл — **без BOM**, исполняемый (`chmod +x`).

```bash
#!/bin/bash
# ============================================================
# Mock curl — отдаёт консервированный ответ и пишет вызов в лог.
#
# Переменные окружения:
#   MOCK_CURL_LOG      — файл лога вызовов (по умолчанию /tmp/mock_curl_calls.txt)
#   MOCK_CURL_BODY     — тело ответа
#   MOCK_CURL_CODE     — HTTP-код (по умолчанию 200)
#   MOCK_CURL_BODY_FILE — файл, содержимое которого отдать вместо MOCK_CURL_BODY
#   MOCK_CURL_FAIL=1   — имитировать сетевой отказ (exit 7, как настоящий curl
#                        при "Failed to connect")
#
# Клиент зовёт curl с `-w '\n%{http_code}'`: код идёт последней строкой тела.
# Мок обязан повторять именно этот контракт, иначе тест разрешит код, который
# на настоящем curl не работает.
# ============================================================

LOG_FILE="${MOCK_CURL_LOG:-/tmp/mock_curl_calls.txt}"
echo "$@" >> "$LOG_FILE"

[ "${MOCK_CURL_FAIL:-0}" = "1" ] && exit 7

# -o <файл>: тело пишется в файл, а на stdout уходит только код.
OUT_FILE=""
PREV=""
for arg in "$@"; do
	[ "$PREV" = "-o" ] && OUT_FILE="$arg" && break
	PREV="$arg"
done

if [ -n "${MOCK_CURL_BODY_FILE:-}" ] && [ -f "$MOCK_CURL_BODY_FILE" ]; then
	BODY="$(cat "$MOCK_CURL_BODY_FILE")"
else
	BODY="${MOCK_CURL_BODY:-}"
fi

if [ -n "$OUT_FILE" ]; then
	printf '%s' "$BODY" > "$OUT_FILE"
	printf '%s' "${MOCK_CURL_CODE:-200}"
else
	printf '%s\n%s' "$BODY" "${MOCK_CURL_CODE:-200}"
fi
exit 0
```

- [ ] **Step 4: Добавить `curl` в сетевой guard**

В `tests/lib/framework.sh`, строка 54, расширить список:

```bash
    for _bin in vot-cli-live vot-cli-live.exe curl; do
```

И поправить текст guard'а, чтобы он называл верную переменную:

```bash
echo "NETWORK GUARD: реальный '$(basename "$0")' вызван в тесте — сетевые вызовы запрещены. Передайте мок через VOT_BIN/CURL_BIN." >&2
```

- [ ] **Step 5: Дописать HTTP-слой в `ffmpeg/remote_client.sh`**

```bash
# --- JSON: разбор плоских полей ---
# Своего разборщика ровно столько, сколько нужно: ответы службы плоские, а
# зависимости от `jq` быть не должно — в Git Bash его нет, и на машине
# владельца это основная платформа.
#
# Ключ ищем с открывающей кавычкой и двоеточием, иначе "job" совпал бы с
# началом "job_id" и вернул чужое значение.
remote_json_field() {
	local json="$1" key="$2" v
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1)"
	if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
	v="$(printf '%s' "$json" | sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([-0-9.]\{1,\}\|true\|false\).*/\1/p" | head -1)"
	printf '%s' "$v"
}

# --- HTTP ---
# Бинарь берём из CURL_BIN, чтобы тест подменил его моком. Тот же приём, что
# у VOT_BIN/YTDLP_BIN в yt-dlp: без него тест ходил бы в настоящую сеть.
REMOTE_HTTP_CODE=""
remote_http() {
	local method="$1" path="$2" body="${3:-}"; shift 3 2>/dev/null || shift $#
	local curl_bin="${CURL_BIN:-curl}"
	local args=(-sS -X "$method" -H "Authorization: Bearer ${remote_api_key}" -w '\n%{http_code}')
	local h
	for h in "$@"; do args+=(-H "$h"); done
	if [ -n "$body" ]; then
		args+=(-H "Content-Type: application/json" --data-binary "$body")
	fi
	local out
	out="$("$curl_bin" "${args[@]}" "${remote_endpoint}${path}" 2>/dev/null)" || {
		REMOTE_HTTP_CODE="000"; return 1
	}
	REMOTE_HTTP_CODE="${out##*$'\n'}"
	printf '%s' "${out%$'\n'*}"
}

# --- Предпусковая проверка ---
# Один раз за прогон, ДО первого файла. Всё, что может сделать невозможным
# весь прогон, должно выясниться здесь: отказать на сотом файле из двухсот
# дороже, чем на нулевом.
REMOTE_CAPS_ARGS_VERSION=""
REMOTE_CHUNK_SIZE=""
remote_preflight() {
	if [ -z "$remote_endpoint" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте переменную окружения TRANSCODE_URL." >&2
		return 1
	fi
	if [ -z "$remote_api_key" ]; then
		echo "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте переменную окружения TRANSCODE_API_KEY." >&2
		return 1
	fi
	if ! command -v "${CURL_BIN:-curl}" >/dev/null 2>&1; then
		echo "[ОШИБКА] Для удалённого бэкенда нужен curl, но он не найден." >&2
		return 1
	fi
	local caps
	caps="$(remote_http GET /capabilities)"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба конвертации недоступна: HTTP $REMOTE_HTTP_CODE." >&2
		return 1
	fi
	REMOTE_CAPS_ARGS_VERSION="$(remote_json_field "$caps" args_version)"
	REMOTE_CHUNK_SIZE="$(remote_json_field "$caps" chunk_size)"
	[ -n "$REMOTE_CHUNK_SIZE" ] || REMOTE_CHUNK_SIZE=$((32 * 1024 * 1024))
	# Версия сборщика аргументов службы. Расхождение не запрещает работу, но
	# молча получить файл, собранный логикой, которой у нас нет, — хуже, чем шумно.
	if [ -n "${REMOTE_KNOWN_ARGS_VERSION:-}" ] && \
	   [ "$REMOTE_CAPS_ARGS_VERSION" != "$REMOTE_KNOWN_ARGS_VERSION" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Служба собирает аргументы версии $REMOTE_CAPS_ARGS_VERSION, клиент рассчитан на $REMOTE_KNOWN_ARGS_VERSION. Сверьте холостой прогон."
	fi
	return 0
}
```

- [ ] **Step 6: Прогнать тест**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 7: Прогнать весь набор — guard не должен сломать существующие тесты**

Run: `bash tests/run_tests.sh`
Expected: `fail=0` во всех наборах. Если какой-то тест звал настоящий `curl`, он теперь падает с кодом 97 — это находка, а не помеха: такой тест ходил в сеть.

- [ ] **Step 8: Коммит**

```bash
git add ffmpeg/remote_client.sh tests/mocks/curl tests/lib/framework.sh tests/ffmpeg/test_21_remote_client.sh
git commit -m "remote: HTTP-слой, preflight и мок curl (.sh)"
```

---

### Task 4: Возобновляемая загрузка (`.sh`)

**Files:**
- Modify: `ffmpeg/remote_client.sh`
- Modify: `tests/ffmpeg/test_21_remote_client.sh`

**Interfaces:**
- Consumes: `remote_http`, `remote_json_field`, `REMOTE_CHUNK_SIZE` (Task 3).
- Produces:
  - `remote_sha256 <файл>` → шестнадцатеричный хеш
  - `remote_upload <файл>` → `upload_id` на stdout, код 1 при отказе

- [ ] **Step 1: Дописать падающие проверки в `tests/ffmpeg/test_21_remote_client.sh`**

Перед `summary`:

```bash
suite "remote: sha256"
_f="$(mktemp "${TMPDIR:-/tmp}/remote_sha_XXXXXX")"
printf 'abc' > "$_f"
assert_eq "sha256 от abc" \
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" \
  "$(remote_sha256 "$_f")"
rm -f "$_f"

suite "remote: загрузка кусками"
_big="$(mktemp "${TMPDIR:-/tmp}/remote_up_XXXXXX")"
head -c 3000 /dev/zero | tr '\0' 'x' > "$_big"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"upload_id":"up-42","chunk_size":1024,"received":0}'
REMOTE_CHUNK_SIZE=1024
uid="$(remote_upload "$_big")"
assert_eq "идентификатор загрузки" "up-42" "$uid"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "создание загрузки" "/v1/uploads" "$_log"
assert_contains "первый кусок"  "Content-Range: bytes 0-1023/3000"    "$_log"
assert_contains "второй кусок"  "Content-Range: bytes 1024-2047/3000" "$_log"
assert_contains "третий кусок"  "Content-Range: bytes 2048-2999/3000" "$_log"
assert_contains "завершение"    "/v1/uploads/up-42/complete"          "$_log"
assert_contains "хеш отправлен" "sha256"                              "$_log"

suite "remote: докачка с известного смещения"
: > "$MOCK_CURL_LOG"
# Служба сообщает, что 2048 байт уже приняты — заново их лить нельзя.
export MOCK_CURL_BODY='{"upload_id":"up-43","received":2048}'
uid="$(remote_upload "$_big")"
_log="$(cat "$MOCK_CURL_LOG")"
assert_not_contains "принятое не перезаливается" "bytes 0-1023/3000" "$_log"
assert_contains "докачка с 2048" "Content-Range: bytes 2048-2999/3000" "$_log"

suite "remote: отказ загрузки виден"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=413
export MOCK_CURL_BODY='{"error":"объявлено больше предела"}'
if remote_upload "$_big" >/dev/null 2>&1; then
    fail "413 отвергается" "код 1" "код 0"
else
    pass "413 отвергается"
fi
export MOCK_CURL_CODE=200
rm -f "$_big"
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: FAIL — `remote_sha256: command not found`.

- [ ] **Step 3: Реализовать в `ffmpeg/remote_client.sh`**

```bash
# --- sha256 ---
# sha256sum есть в Linux и Git Bash, shasum — в macOS. Проверяем оба, потому
# что macOS заявлена в поддержке проекта.
remote_sha256() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | cut -d' ' -f1
	else
		echo "[ОШИБКА] Не найден ни sha256sum, ни shasum — подтвердить загрузку нечем." >&2
		return 1
	fi
}

# --- Загрузка кусками ---
# Возобновляемость — не удобство, а условие работоспособности: файлы от
# гигабайта, и одна POST-загрузка на 20 ГБ рвётся и начинается заново.
# Перед отправкой спрашиваем у службы, сколько байт она уже приняла, и льём
# только хвост.
remote_upload() {
	local file="$1" size offset=0 chunk uid answer
	size="$(file_size "$file")"

	answer="$(remote_http POST /uploads)"
	[ "$REMOTE_HTTP_CODE" = "200" ] || {
		echo "[ОШИБКА] Служба не приняла загрузку: HTTP $REMOTE_HTTP_CODE." >&2
		return 1
	}
	uid="$(remote_json_field "$answer" upload_id)"
	[ -n "$uid" ] || { echo "[ОШИБКА] Служба не вернула upload_id." >&2; return 1; }

	chunk="$(remote_json_field "$answer" chunk_size)"
	[ -n "$chunk" ] && [ "$chunk" -gt 0 ] 2>/dev/null && REMOTE_CHUNK_SIZE="$chunk"

	# Сколько уже принято. Пустой ответ — считаем, что ноль: лишний перезалив
	# дешевле, чем пропущенное начало файла.
	answer="$(remote_http GET "/uploads/$uid")"
	if [ "$REMOTE_HTTP_CODE" = "200" ]; then
		offset="$(remote_json_field "$answer" received)"
		[ -n "$offset" ] || offset=0
	fi

	local tmp_chunk
	tmp_chunk="$(mktemp "${TMPDIR:-/tmp}/ffconv_chunk_XXXXXX")"
	while [ "$offset" -lt "$size" ]; do
		local this=$((size - offset))
		[ "$this" -gt "$REMOTE_CHUNK_SIZE" ] && this="$REMOTE_CHUNK_SIZE"
		# dd со смещением в блоках самого куска: bs=1 на гигабайтах непригоден
		# по скорости, а skip в блоках даёт точное смещение только когда оно
		# кратно bs — что здесь всегда так, потому что кусок фиксированный.
		dd if="$file" of="$tmp_chunk" bs="$REMOTE_CHUNK_SIZE" \
		   skip=$((offset / REMOTE_CHUNK_SIZE)) count=1 2>/dev/null
		remote_upload_chunk "$uid" "$tmp_chunk" "$offset" \
			$((offset + this - 1)) "$size" || { rm -f "$tmp_chunk"; return 1; }
		remote_report_upload "$((offset + this))" "$size"
		offset=$((offset + this))
	done
	rm -f "$tmp_chunk"

	local sha; sha="$(remote_sha256 "$file")" || return 1
	remote_http POST "/uploads/$uid/complete" \
		"{\"size\":$size,\"sha256\":\"$sha\"}" >/dev/null
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба не подтвердила загрузку: HTTP $REMOTE_HTTP_CODE." >&2
		return 1
	fi
	printf '%s' "$uid"
}

# Отдельной функцией, потому что тело куска — двоичное и идёт из файла:
# --data-binary @file, а не строкой, иначе нули и переводы строк исказятся.
remote_upload_chunk() {
	local uid="$1" chunk_file="$2" from="$3" to="$4" total="$5"
	local curl_bin="${CURL_BIN:-curl}" out
	out="$("$curl_bin" -sS -X PATCH \
		-H "Authorization: Bearer ${remote_api_key}" \
		-H "Content-Range: bytes ${from}-${to}/${total}" \
		-H "Content-Type: application/octet-stream" \
		--data-binary "@$chunk_file" \
		-w '\n%{http_code}' \
		"${remote_endpoint}/uploads/${uid}" 2>/dev/null)" || {
		echo "[ОШИБКА] Обрыв связи при отправке куска ${from}-${to}." >&2
		return 1
	}
	REMOTE_HTTP_CODE="${out##*$'\n'}"
	[ "$REMOTE_HTTP_CODE" = "200" ] && return 0
	echo "[ОШИБКА] Служба отвергла кусок ${from}-${to}: HTTP $REMOTE_HTTP_CODE." >&2
	return 1
}

# Прогресс загрузки — отдельная фаза. На файле в 3 ГБ по сети это и есть
# долгая часть: без своего индикатора прогресс стоял бы на нуле минутами.
remote_report_upload() {
	local done_b="$1" total_b="$2" pct=0
	[ "$total_b" -gt 0 ] 2>/dev/null && pct=$((done_b * 100 / total_b))
	show_progress_bar "$pct" "отправка"
}
```

- [ ] **Step 4: Заглушка `show_progress_bar`/`file_size` для автономного теста**

Модуль зовёт `show_progress_bar` и `file_size` из `FFmpeg_Converter_script.sh`. В тесте их нет. Дописать в начало `tests/ffmpeg/test_21_remote_client.sh`, сразу после `source` модуля:

```bash
# Модуль подключается в script.sh, где эти функции уже есть. В автономном
# тесте подставляем их сами — проверяем клиент, а не прогресс-бар.
file_size() { stat -c%s "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo 0; }
show_progress_bar() { :; }
```

- [ ] **Step 5: Прогнать тест**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 6: Коммит**

```bash
git add ffmpeg/remote_client.sh tests/ffmpeg/test_21_remote_client.sh
git commit -m "remote: возобновляемая загрузка кусками (.sh)"
```

---

### Task 5: Задача, ожидание, результат и отмена (`.sh`)

**Files:**
- Modify: `ffmpeg/remote_client.sh`
- Modify: `tests/ffmpeg/test_21_remote_client.sh`

**Interfaces:**
- Consumes: `remote_http`, `remote_json_field`, `remote_op_for_config`.
- Produces:
  - `remote_submit <upload_id> <op> <params_json> [subtitle_upload_id]` → `job_id`
  - `remote_dry_run <upload_id> <op> <params_json>` → план на stdout
  - `remote_wait <job_id> <метка>` → 0 при `done`, 1 иначе
  - `remote_fetch <job_id> <файл-назначения>` → 0/1
  - `remote_cancel <job_id>` → всегда 0
  - `REMOTE_CURRENT_JOB` — идентификатор текущей задачи для обработчика прерывания

- [ ] **Step 1: Дописать падающие проверки**

Перед `summary` в `tests/ffmpeg/test_21_remote_client.sh`:

```bash
suite "remote: создание задачи"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='{"job_id":"job-7","state":"queued","reused":false}'
remote_prefer="auto"; remote_wait_timeout="1800"; overwrite_existing="no"
jid="$(remote_submit up-42 transcode '{"codec":"h264"}')"
assert_eq "идентификатор задачи" "job-7" "$jid"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "операция"     '"op":"transcode"'   "$_log"
assert_contains "загрузка"     '"upload_id":"up-42"' "$_log"
assert_contains "предпочтение" '"prefer":"auto"'    "$_log"
assert_contains "таймаут"      '"wait_timeout":1800' "$_log"
assert_not_contains "без overwrite нет no_reuse" '"no_reuse":true' "$_log"

: > "$MOCK_CURL_LOG"
overwrite_existing="yes"
remote_submit up-42 transcode '{"codec":"h264"}' >/dev/null
assert_contains "overwrite → no_reuse" '"no_reuse":true' "$(cat "$MOCK_CURL_LOG")"
overwrite_existing="no"

suite "remote: субтитры уезжают отдельной загрузкой"
: > "$MOCK_CURL_LOG"
remote_submit up-42 transcode '{"codec":"h264"}' up-sub >/dev/null
assert_contains "subtitle_upload_id" '"subtitle_upload_id":"up-sub"' "$(cat "$MOCK_CURL_LOG")"

suite "remote: холостой прогон"
: > "$MOCK_CURL_LOG"
export MOCK_CURL_BODY='{"dry_run":true,"segmented":false,"outputs_expected":1,"argv":["ffmpeg","-i","x"]}'
out="$(remote_dry_run up-42 transcode '{"codec":"h264"}')"
assert_contains "план напечатан" "ffmpeg" "$out"
assert_contains "флаг отправлен" '"dry_run":true' "$(cat "$MOCK_CURL_LOG")"

suite "remote: ожидание задачи"
export REMOTE_POLL_SECONDS=0
export MOCK_CURL_BODY='{"job_id":"job-7","state":"done","progress":100}'
if remote_wait job-7 "файл" >/dev/null 2>&1; then pass "done даёт успех"
else fail "done даёт успех" "код 0" "код 1"; fi

export MOCK_CURL_BODY='{"job_id":"job-7","state":"failed","error":"код возврата 1"}'
out="$(remote_wait job-7 "файл" 2>&1)"; rc=$?
assert_eq "failed даёт отказ" "1" "$rc"
assert_contains "причина показана" "код возврата 1" "$out"

export MOCK_CURL_BODY='{"job_id":"job-7","state":"waiting_gpu","waiting_seconds":42,"missing_mib":512}'
# Одна итерация: подменяем опрос так, чтобы вторым ответом пришёл done.
out="$( (export MOCK_CURL_BODY='{"state":"waiting_gpu","waiting_seconds":42,"missing_mib":512}'
         REMOTE_WAIT_MAX_POLLS=1 remote_wait job-7 "файл" 2>&1) )" || true
assert_contains "ожидание объяснено" "42" "$out"
assert_contains "нехватка памяти названа" "512" "$out"

suite "remote: скачивание результата"
_dst="$(mktemp "${TMPDIR:-/tmp}/remote_dl_XXXXXX")"; rm -f "$_dst"
export MOCK_CURL_CODE=200
export MOCK_CURL_BODY='RESULT-BYTES'
if remote_fetch job-7 "$_dst"; then pass "скачивание успешно"
else fail "скачивание успешно" "код 0" "код 1"; fi
assert_file_exists "файл создан" "$_dst"
assert_eq "содержимое" "RESULT-BYTES" "$(cat "$_dst")"
rm -f "$_dst"

suite "remote: отмена освобождает карту"
: > "$MOCK_CURL_LOG"
remote_cancel job-7
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "метод DELETE" "DELETE" "$_log"
assert_contains "адрес задачи" "/v1/jobs/job-7" "$_log"
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: FAIL — `remote_submit: command not found`.

- [ ] **Step 3: Реализовать в `ffmpeg/remote_client.sh`**

```bash
# --- Тело запроса на создание задачи ---
# Собирается в одном месте: боевой путь и холостой прогон обязаны отправлять
# одинаковое тело, иначе сверка планов проверяет не то, что поедет.
remote_job_body() {
	local uid="$1" op="$2" params="$3" sub_uid="${4:-}" extra="${5:-}"
	local p="$params"
	if [ -n "$sub_uid" ]; then
		p="${p%\}},\"subtitle_upload_id\":\"$sub_uid\"}"
	fi
	local body="{\"upload_id\":\"$uid\",\"op\":\"$op\",\"params\":$p"
	body="$body,\"prefer\":\"${remote_prefer:-auto}\""
	body="$body,\"wait_timeout\":${remote_wait_timeout:-1800}"
	# overwrite_existing = yes обязан отключить дедупликацию службы: иначе
	# «перезаписать заново» вернуло бы прежний результат с reused: true.
	[ "$overwrite_existing" = "yes" ] && body="$body,\"no_reuse\":true"
	[ -n "$extra" ] && body="$body,$extra"
	printf '%s}' "$body"
}

remote_submit() {
	local answer jid
	answer="$(remote_http POST /jobs "$(remote_job_body "$@")")"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Служба отвергла задачу: HTTP $REMOTE_HTTP_CODE — $(remote_json_field "$answer" error)" >&2
		return 1
	fi
	jid="$(remote_json_field "$answer" job_id)"
	[ -n "$jid" ] || { echo "[ОШИБКА] Служба не вернула job_id." >&2; return 1; }
	[ "$(remote_json_field "$answer" reused)" = "true" ] && \
		log_msg "INFO" "Служба вернула готовый результат прежней задачи (дедупликация)"
	printf '%s' "$jid"
}

remote_dry_run() {
	local answer
	answer="$(remote_http POST /jobs "$(remote_job_body "$1" "$2" "$3" "${4:-}" '"dry_run":true')")"
	if [ "$REMOTE_HTTP_CODE" != "200" ]; then
		echo "[ОШИБКА] Холостой прогон отвергнут: HTTP $REMOTE_HTTP_CODE — $(remote_json_field "$answer" error)" >&2
		return 1
	fi
	# Печатаем ПЛАН целиком, а не одну команду: длинный файл служба режет,
	# кодирует посегментно, склеивает и отдельным проходом обрабатывает звук —
	# одной строкой это не описывается.
	echo "[DRY-RUN][REMOTE] $answer"
}

# --- Ожидание ---
REMOTE_CURRENT_JOB=""
remote_wait() {
	local jid="$1" label="$2" polls=0 answer state
	REMOTE_CURRENT_JOB="$jid"
	while :; do
		answer="$(remote_http GET "/jobs/$jid")"
		if [ "$REMOTE_HTTP_CODE" != "200" ]; then
			echo "[ОШИБКА] Состояние задачи недоступно: HTTP $REMOTE_HTTP_CODE." >&2
			REMOTE_CURRENT_JOB=""; return 1
		fi
		state="$(remote_json_field "$answer" state)"
		case "$state" in
			done)
				show_progress_bar 100 "$label"; printf "\n"
				REMOTE_CURRENT_JOB=""; return 0 ;;
			failed|cancelled)
				printf "\n"
				echo "[ОШИБКА] Задача $state: $(remote_json_field "$answer" error)" >&2
				REMOTE_CURRENT_JOB=""; return 1 ;;
			waiting_gpu)
				# Ожидание без объяснения неотличимо от зависания, поэтому
				# показываем и сколько ждём, и сколько памяти не хватает.
				printf "\r  ожидание карты: %s с, не хватает %s МиБ            " \
					"$(remote_json_field "$answer" waiting_seconds)" \
					"$(remote_json_field "$answer" missing_mib)" ;;
			*)
				show_progress_bar "$(remote_json_field "$answer" progress)" "$label" ;;
		esac
		polls=$((polls + 1))
		if [ -n "${REMOTE_WAIT_MAX_POLLS:-}" ] && [ "$polls" -ge "$REMOTE_WAIT_MAX_POLLS" ]; then
			printf "\n"; REMOTE_CURRENT_JOB=""; return 1
		fi
		sleep "${REMOTE_POLL_SECONDS:-2}"
	done
}

# --- Результат ---
# Пишем сразу в целевой временный файл через curl -o: тело может быть в
# гигабайты, и держать его в переменной оболочки нельзя.
remote_fetch() {
	local jid="$1" dst="$2" curl_bin="${CURL_BIN:-curl}" code
	code="$("$curl_bin" -sS -X GET \
		-H "Authorization: Bearer ${remote_api_key}" \
		-o "$dst" -w '%{http_code}' \
		"${remote_endpoint}/jobs/${jid}/result" 2>/dev/null)" || {
		echo "[ОШИБКА] Обрыв связи при скачивании результата." >&2
		rm -f "$dst"; return 1
	}
	REMOTE_HTTP_CODE="$code"
	if [ "$code" != "200" ]; then
		echo "[ОШИБКА] Результат недоступен: HTTP $code." >&2
		rm -f "$dst"; return 1
	fi
	return 0
}

# --- Отмена ---
# Брошенная задача продолжит держать карту, ради вежливости к которой служба
# и построена. Поэтому DELETE шлём даже когда уходим по прерыванию.
remote_cancel() {
	[ -n "${1:-}" ] || return 0
	remote_http DELETE "/jobs/$1" >/dev/null 2>&1
	return 0
}
```

- [ ] **Step 4: Заглушка `log_msg` в тесте**

Рядом с заглушками из Task 4:

```bash
log_msg() { :; }
```

- [ ] **Step 5: Прогнать тест**

Run: `bash tests/ffmpeg/test_21_remote_client.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 6: Коммит**

```bash
git add ffmpeg/remote_client.sh tests/ffmpeg/test_21_remote_client.sh
git commit -m "remote: задача, ожидание, результат и отмена (.sh)"
```

---

### Task 6: Стыковка в `FFmpeg_Converter_script.sh`

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.sh` — подключение модуля (после блока `[ -f ... ]` в начале), `_cleanup_on_int:450`, режимный блок `F-modes:1111`, тело `encode_file:984-1085`
- Test: `tests/ffmpeg/test_07_integration.sh` (дописать набор)

**Interfaces:**
- Consumes: всё из Task 2–5.
- Produces: переменная `remote_active` (`yes`/`no`) — вычисляется один раз после разбора режимов; при `yes` `encode_file` идёт удалённым путём.

- [ ] **Step 1: Расширить `default_vars` и добавить сбор вывода**

`test_07_integration.sh` **не читает `config.ini`**: он задаёт переменные напрямую и делает `source` скрипта (`default_vars`/`run_script`, строки 36–73). Новый набор обязан идти тем же путём.

В `default_vars` дописать умолчания удалённого бэкенда:

```bash
    remote_enabled="no"; remote_endpoint=""; remote_api_key=""
    remote_prefer="auto"; remote_wait_timeout="1800"
```

Рядом с `run_script` добавить вариант, отдающий вывод (существующий глушит его в `/dev/null`):

```bash
# Как run_script, но возвращает вывод скрипта: проверки удалённого бэкенда
# смотрят именно на сообщения, а не на вызовы ffmpeg.
run_script_out() {
    local dump; dump=$(mktemp_suffix /tmp/test_dump_ .txt)
    rm -f "$FFMPEG_LOG"
    (
        export PATH="$MOCKS_DIR:$PATH"
        export MOCK_FFMPEG_ENCODERS=""
        export MOCK_FFMPEG_LOG="$FFMPEG_LOG"
        export CURL_BIN="$MOCKS_DIR/curl"
        default_vars
        for ov in "$@"; do eval "$ov"; done
        _dump() { echo "done" > "$1"; }
        trap "_dump '$dump'" EXIT
        source "$SCRIPT" 2>&1
    ) < /dev/null
    rm -f "$dump"
}
```

- [ ] **Step 2: Написать падающие проверки**

Дописать в конец `tests/ffmpeg/test_07_integration.sh`, перед `summary`:

```bash
suite "remote: локальные режимы остаются локальными"
CURL_LOG="/tmp/mock_curl_int_$$.txt"
for _m in copy_codecs merge_files create_frame audio_only extract_audio_copy; do
    rm -f "$CURL_LOG"
    _out="$(MOCK_CURL_LOG="$CURL_LOG" run_script_out \
        'remote_enabled="yes"' \
        'remote_endpoint="http://mock.invalid/v1"' \
        'remote_api_key="k"' \
        "${_m}=\"yes\"" \
        'dry_run="yes"')"
    assert_contains "$_m: сказано, что считается локально" "локально" "$_out"
    if [ -s "$CURL_LOG" ]; then
        fail "$_m: в сеть не ходим" "лог curl пуст" "$(cat "$CURL_LOG")"
    else
        pass "$_m: в сеть не ходим"
    fi
done
rm -f "$CURL_LOG"

suite "remote: preflight обрывает прогон до первого файла"
_out="$(run_script_out 'remote_enabled="yes"' 'remote_endpoint=""' 'remote_api_key=""')"
assert_contains "названа переменная адреса" "TRANSCODE_URL" "$_out"
assert_not_contains "ни один файл не тронут" "Кодирование:" "$_out"

suite "remote: обычное перекодирование уезжает"
rm -f "$CURL_LOG"
_out="$(MOCK_CURL_LOG="$CURL_LOG" MOCK_CURL_CODE=200 \
    MOCK_CURL_BODY='{"args_version":"1","chunk_size":1048576,"job_id":"j1","upload_id":"u1","state":"done","received":0}' \
    run_script_out \
        'remote_enabled="yes"' \
        'remote_endpoint="http://mock.invalid/v1"' \
        'remote_api_key="k"' \
        'dry_run="yes"')"
assert_contains "сказано о включении" "Удалённый бэкенд включён" "$_out"
assert_contains "preflight спросил возможности" "/v1/capabilities" "$(cat "$CURL_LOG")"
rm -f "$CURL_LOG"
```

- [ ] **Step 3: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_07_integration.sh`
Expected: FAIL — вывод не содержит ни «локально», ни `TRANSCODE_URL`.

- [ ] **Step 4: Подключить модуль**

В `ffmpeg/FFmpeg_Converter_script.sh`, сразу после блока проверки окружения (`# --- E1. Проверка окружения ---`, ~строка 52):

```bash
# Удалённый бэкенд — отдельный модуль. Подключаем всегда: он ничего не делает
# сам, только объявляет функции, а условие включения проверяется ниже.
if [ -f "${SCRIPT_DIR}/remote_client.sh" ]; then
	source "${SCRIPT_DIR}/remote_client.sh"
fi
```

- [ ] **Step 5: Вычислить `remote_active` и сделать preflight**

После блока `F-modes` (определение эффективного режима, ~строка 1111–1175), перед `# --- Основная логика ---`:

```bash
# --- Удалённый бэкенд: включён ли он для ЭТОГО прогона ---
# Уезжает только то, где выигрывает карта. remux, concat, frames, audio и
# extract_audio служба умеет, но карта в них не участвует: там ffmpeg либо
# переливает байты, либо считает на процессоре — гнать по сети гигабайты ради
# `-c copy` заведомо хуже локального прогона. Молчать об этом нельзя: режим,
# который тихо не уехал, неотличим от сломанного удалённого пути.
remote_active="no"
if [ "$remote_enabled" = "yes" ]; then
	if ! type remote_preflight >/dev/null 2>&1; then
		echo "[ОШИБКА] [remote] enabled = yes, но рядом со скриптом нет remote_client.sh." >&2
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
	if [ "$merge_files" = "yes" ] || [ "$extract_audio_copy" = "yes" ] || \
	   [ "$create_frame" = "yes" ] || [ "$copy_codecs" = "yes" ] || \
	   [ "$audio_only" = "yes" ]; then
		log_msg "INFO" "Удалённый бэкенд не используется в этом режиме (карта в нём не участвует) — считаем локально"
	elif [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] parallel_files на удалённом пути игнорируется: параллельность задаёт очередь службы."
		parallel_count=1
		remote_active="yes"
	else
		remote_active="yes"
	fi
	if [ "$remote_active" = "yes" ]; then
		# Всё, что делает невозможным весь прогон, выясняем ДО первого файла.
		if ! remote_preflight; then
			pause_prompt "Нажмите [Enter], чтобы выйти..."
			exit 1
		fi
		if [ "$hw_accel_status" = "+" ] && [ "$hw_accel_value" = "intel" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] hw_accel = intel: Intel-карты на сервере нет, служба посчитает на процессоре."
		fi
		log_msg "INFO" "Удалённый бэкенд включён: кодирование уходит на службу конвертации"
	fi
fi
```

- [ ] **Step 6: Отменять задачу при прерывании**

В `_cleanup_on_int` (строка 450) и `_cleanup_child_on_int` (строка 464) первой строкой тела:

```bash
	[ -n "${REMOTE_CURRENT_JOB:-}" ] && remote_cancel "$REMOTE_CURRENT_JOB"
```

- [ ] **Step 7: Удалённая ветка в `encode_file`**

Заменить блок `# D7. Dry-run` (строка 984) так, чтобы удалённый путь шёл первым, а локальный остался без изменений:

```bash
		# Удалённый бэкенд подменяет РОВНО этот участок: сборку argv и запуск
		# ffmpeg. Всё до (manifest, коллизии, имена частей) и всё после
		# (валидация -f null -, mv, сводка, manifest_write) остаётся общим —
		# именно поэтому один config.ini даёт один результат на обоих путях.
		if [ "$remote_active" = "yes" ]; then
			local r_len=0
			[[ "$current_set_length" == "-t "* ]] && r_len="${current_set_length#-t }"
			local r_op r_params r_out
			r_out="$(remote_op_for_config "${b:-0}" "$r_len")" || {
				log_msg "FAIL" "$(basename "$full_path"): кодек $set_video_codec служба не поддерживает"
				any_fail="yes"
				echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				((c+=1)); continue
			}
			r_op="$(printf '%s' "$r_out" | head -1)"
			r_params="$(printf '%s' "$r_out" | tail -1)"

			# Загрузка одна на файл, задач — по одной на часть. Второй раз те же
			# гигабайты не отправляются.
			if [ -z "${remote_upload_id:-}" ]; then
				log_msg "INFO" "Отправка на сервер: $(basename "$full_path")"
				remote_upload_id="$(remote_upload "$full_path")" || {
					log_msg "FAIL" "$(basename "$full_path"): загрузка не удалась"
					any_fail="yes"
					echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
					((c+=1)); continue
				}
				printf "\n"
				# Файл субтитров приходит той же дорогой, что видео: путей в
				# параметрах служба не принимает по построению.
				remote_sub_id=""
				if [ "$sub_found" = "1" ] && [ -n "${sub_file:-}" ]; then
					remote_sub_id="$(remote_upload "$sub_file")" || remote_sub_id=""
				fi
			fi

			if [ "$dry_run" = "yes" ]; then
				remote_dry_run "$remote_upload_id" "$r_op" "$r_params" "${remote_sub_id:-}"
			else
				local r_job
				r_job="$(remote_submit "$remote_upload_id" "$r_op" "$r_params" "${remote_sub_id:-}")" || {
					log_msg "FAIL" "$(basename "$full_path"): служба отвергла задачу"
					any_fail="yes"
					echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
					((c+=1)); continue
				}
				local out_tmp; out_tmp="$(partial_path "$out_file")"
				rm -f "$out_tmp"
				_current_out_tmp="$out_tmp"
				local encode_start=$(date +%s)
				if remote_wait "$r_job" "$full_path" && remote_fetch "$r_job" "$out_tmp"; then
					publish_result "$full_path" "$out_tmp" "$out_file" "$encode_start"
				else
					log_msg "FAIL" "$(basename "$full_path")"
					rm -f "$out_tmp"
					any_fail="yes"
					echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
				fi
				_current_out_tmp=""
			fi
		elif [ "$dry_run" = "yes" ]; then
			echo "[DRY-RUN] $ffmpeg -nostdin -hide_banner -strict -2 $hw_decode_args $in_seek -i \"$full_path\" ${subtitles_params[*]} $convert_settings $thread_args ${vf_args[*]} ${af_args[*]} $current_set_length $out_seek \"$out_file\""
		else
```

Строку `fi` в конце локального блока (после `rm -f "$err_file"`) оставить как есть — она закрывает уже трёхветочный `if`.

`remote_upload_id` и `remote_sub_id` объявить `local` в начале `encode_file` рядом с `produced`, чтобы загрузка не переиспользовалась между файлами.

- [ ] **Step 8: Вынести публикацию результата в общую функцию**

Рядом с `partial_path` (строка 477) добавить:

```bash
# Публикация результата — общая для локального и удалённого путей. Вынесена,
# чтобы валидация, переименование и учёт байтов существовали в ОДНОМ
# экземпляре: разойдись они, «успех» на одном пути значил бы не то же, что на
# другом, и сводка ok/fail перестала бы что-либо значить.
#
# Удалённый путь добавляет одну проверку, которой у локального не было:
# `-s` и `-f null -` применяются к СКАЧАННОМУ файлу. Локальный ffmpeg с rc=0
# нулевой файл не оставляет, а оборванная загрузка — запросто.
publish_result() {
	local src="$1" tmp="$2" dst="$3" started="$4"
	local elapsed=$(( $(date +%s) - started ))
	if [ -s "$tmp" ] && "$ffmpeg" -nostdin -v error -i "$tmp" -f null - 2>/dev/null \
	   && mv -f "$tmp" "$dst" 2>/dev/null && [ -f "$dst" ]; then
		log_msg "OK" "$(basename "$src") -> $(basename "$dst") ($((elapsed / 60))m $((elapsed % 60))s)"
		local out_sz in_sz=0
		out_sz=$(file_size "$dst")
		if [ "$in_reported" -eq 0 ]; then in_sz=$(file_size "$src"); in_reported=1; fi
		produced+=("$dst")
		echo "ok:${out_sz}:${in_sz}" > "$(mktemp "$results_dir/r_XXXXXXXX")"
		return 0
	fi
	log_msg "FAIL" "$(basename "$src"): результат не прошёл проверку"
	rm -f "$tmp"
	any_fail="yes"
	echo "fail" > "$(mktemp "$results_dir/r_XXXXXXXX")"
	return 1
}
```

- [ ] **Step 9: Заставить локальный путь звать ту же функцию**

Без этого шага логика публикации существует в двух экземплярах, и комментарий выше врёт. В `encode_file` заменить блок `elif mv -f "$out_tmp" …` (строки 1063–1083 исходного файла) целиком:

```bash
			# F-rename. Публикацию результата подтверждаем: успех mv И наличие
			# файла-цели. Молчаливый провал rename (цель заблокирована, нет
			# места) иначе выдал бы отсутствующий результат за успех — с
			# записью manifest поверх него.
			else
				publish_result "$full_path" "$out_tmp" "$out_file" "$encode_start"
			fi
```

Ветка `if [ $exit_code -ne 0 ]` (показ последних строк `err_file`, удаление `out_tmp`) остаётся как была: она про отказ самого ffmpeg, а не про публикацию.

- [ ] **Step 10: Прогнать тесты**

Run: `bash tests/ffmpeg/test_07_integration.sh` затем `bash tests/run_tests.sh ffmpeg`
Expected: PASS, `fail=0` в обоих. Локальный путь тронут — набор обязан подтвердить, что он не сломан.

- [ ] **Step 11: Коммит**

```bash
git add ffmpeg/FFmpeg_Converter_script.sh tests/ffmpeg/test_07_integration.sh
git commit -m "remote: удалённая ветка в encode_file (.sh)"
```

---

### Task 7: Модуль клиента для PowerShell

**Files:**
- Create: `ffmpeg/remote_client.ps1` (UTF-8 **с BOM**)
- Test: `tests/ffmpeg/test_22_remote_ps1.sh`

**Interfaces:**
- Produces: `Get-RemoteCodec`, `Get-RemoteOpForConfig`, `Invoke-RemoteHttp`, `Invoke-RemotePreflight`, `Send-RemoteUpload`, `Submit-RemoteJob`, `Wait-RemoteJob`, `Receive-RemoteResult`, `Stop-RemoteJob`.
- Контракт `Get-RemoteOpForConfig`: принимает `[int]$StartSec`, `[int]$LengthSec`; возвращает `[pscustomobject]@{ Op = '…'; Params = '…' }`, где `Params` — **строка JSON**, побайтово совпадающая с выводом `remote_op_for_config` из `.sh`. На этом строится Task 8.

- [ ] **Step 1: Написать падающий тест**

Создать `tests/ffmpeg/test_22_remote_ps1.sh`:

```bash
#!/bin/bash
# ============================================================
# test_22_remote_ps1.sh — реальный PS1-модуль клиента (дот-сорсинг).
# Нужен Windows PowerShell; иначе набор пропускается.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "remote PS1"
    skip "PS1-модуль клиента" "PowerShell не найден"
    summary
    exit 0
fi

MODULE="$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/remote_client.ps1"

run_ps() {
    "$PS_BIN" -NoProfile -NonInteractive -Command "
        . '$MODULE'
        $1
    " 2>&1 | tr -d '\r'
}

suite "remote PS1: отображение кодеков"
assert_eq "libx264 → h264"  "h264" "$(run_ps 'Get-RemoteCodec libx264')"
assert_eq "hevc_nvenc → hevc" "hevc" "$(run_ps 'Get-RemoteCodec hevc_nvenc')"
assert_eq "libsvtav1 → av1" "av1"  "$(run_ps 'Get-RemoteCodec libsvtav1')"
assert_empty "неизвестный кодек" "$(run_ps 'Get-RemoteCodec libvpx-vp9')"

suite "remote PS1: операция и параметры"
_setup='
$set_video_codec="libx264"
$video_quality_status="+";       $video_quality_value="23"
$video_bitrate_status="-";       $video_bitrate_value="3000"
$video_resolution_status="+";    $video_resolution_value="1280x720"
$video_number_frames_status="+"; $video_number_frames_value="30"
$video_rotation_status="-";      $video_rotation_value="2"
$video_subtitles_status="-";     $video_subtitles_value="burn"
$keep_aspect_ratio_value="yes";  $output_container_value="mp4"
$audio_codec_status="+";           $audio_codec_value="aac"
$audio_number_channels_status="+"; $audio_number_channels_value="2"
$audio_bitrate_status="+";         $audio_bitrate_value="128"
$audio_sampling_rate_status="+";   $audio_sampling_rate_value="48000"
$audio_normalize_status="-";       $audio_normalize_value="loudnorm"
$playback_speed_status="-";      $playback_speed_value="1.0"
$gpu_preset_status="-"; $gpu_preset_value="p5"
$gpu_tune_status="-";   $gpu_tune_value="hq"
$gpu_rc_status="-";     $gpu_rc_value="vbr"
$threads=4; $subtitles_style=""
'
out="$(run_ps "$_setup; (Get-RemoteOpForConfig 0 0).Op")"
assert_eq "без отрезка → transcode" "transcode" "$out"
params="$(run_ps "$_setup; (Get-RemoteOpForConfig 0 0).Params")"
assert_contains "кодек"      '"codec":"h264"'          "$params"
assert_contains "качество"   '"quality":23'            "$params"
assert_contains "контейнер"  '"container":"mp4"'       "$params"
assert_contains "звук"       '"audio":{"codec":"aac"'  "$params"

out="$(run_ps "$_setup; (Get-RemoteOpForConfig 60 300).Op")"
assert_eq "с отрезком → cut" "cut" "$out"
params="$(run_ps "$_setup; (Get-RemoteOpForConfig 60 300).Params")"
assert_contains "начало"  '"start":60'      "$params"
assert_contains "конец"   '"end":360'       "$params"
assert_contains "перекод" '"reencode":true' "$params"

# Invoke-RemoteHttp — единственная точка выхода в сеть, и ровно поэтому её
# подменяем: без этого набора нарезка на куски и докачка в .ps1 не проверены
# вовсе, хотя в .sh покрыты (test_21). Именно здесь ловится расхождение,
# которое на живом файле в 3 ГБ стоило бы часа.
suite "remote PS1: загрузка кусками через подменённый HTTP-слой"
_harness="$(mktemp_suffix "${TMPDIR:-/tmp}/remote_up_" .ps1)"
_payload="$(mktemp "${TMPDIR:-/tmp}/remote_payload_XXXXXX")"
head -c 3000 /dev/zero | tr '\0' 'x' > "$_payload"
_payload_win="$(cygpath -w "$_payload" 2>/dev/null || echo "$_payload")"

cat > "$_harness" <<PSEOF
. '$MODULE'
\$script:calls = New-Object System.Collections.ArrayList
# Подмена: сети нет, ответы консервированные, вызовы записываются.
function Invoke-RemoteHttp {
	param([string]\$Method, [string]\$Path, [string]\$Body = '',
	      [hashtable]\$Headers = @{}, [string]\$OutFile = '', [string]\$InFile = '')
	\$range = if (\$Headers.ContainsKey('Content-Range')) { \$Headers['Content-Range'] } else { '' }
	[void]\$script:calls.Add("\$Method \$Path \$range \$Body")
	if (\$Method -eq 'POST' -and \$Path -eq '/uploads') {
		return [pscustomobject]@{ Code = 200; Body = '{"upload_id":"up-99","chunk_size":1024}' }
	}
	if (\$Method -eq 'GET' -and \$Path -like '/uploads/*') {
		return [pscustomobject]@{ Code = 200; Body = '{"received":0}' }
	}
	return [pscustomobject]@{ Code = 200; Body = '{}' }
}
\$uid = Send-RemoteUpload '$_payload_win'
Write-Output "UID=\$uid"
\$script:calls | ForEach-Object { Write-Output \$_ }
PSEOF

_out="$("$PS_BIN" -NoProfile -NonInteractive -File "$_harness" 2>&1 | tr -d '\r')"
assert_contains "идентификатор загрузки" "UID=up-99" "$_out"
assert_contains "первый кусок"  "bytes 0-1023/3000"    "$_out"
assert_contains "второй кусок"  "bytes 1024-2047/3000" "$_out"
assert_contains "третий кусок"  "bytes 2048-2999/3000" "$_out"
assert_contains "завершение"    "/uploads/up-99/complete" "$_out"
assert_contains "хеш отправлен" '"sha256"' "$_out"
# Тот же вход, что в .sh-тесте: хеш обязан совпасть на обеих платформах.
assert_not_contains "хеш не пустой" '"sha256":""' "$_out"
rm -f "$_harness" "$_payload"

summary
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_22_remote_ps1.sh`
Expected: FAIL (или SKIP, если PowerShell недоступен — тогда выполнять задачу на машине с ним).

- [ ] **Step 3: Написать `ffmpeg/remote_client.ps1`**

Файл — **UTF-8 с BOM**. Порядок сборки JSON обязан совпадать с `.sh` посимвольно: этого требует тест паритета Task 8.

```powershell
# ============================================================
# Удалённый бэкенд — клиент службы конвертации (PowerShell)
#
# Подключается из FFmpeg_Converter_script.ps1 и из GUI. Только функции,
# никаких действий при загрузке: так модуль дот-сорсится в тест без сети.
#
# Спека: docs/superpowers/specs/2026-08-28-ffmpeg-remote-backend-design.md
# ============================================================

function Get-RemoteCodec {
	param([string]$Encoder)
	switch -Regex ($Encoder) {
		'^(libx264|h264_nvenc|h264_qsv)$'  { return 'h264' }
		'^(libx265|hevc_nvenc|hevc_qsv)$'  { return 'hevc' }
		'^(libsvtav1|av1_nvenc|av1_qsv)$'  { return 'av1'  }
	}
	return ''
}

function ConvertTo-RemoteJsonString {
	param([string]$Value)
	return $Value.Replace('\', '\\').Replace('"', '\"')
}

# Порядок полей здесь — контракт с .sh, а не вкус: тест паритета сравнивает
# строки целиком. Меняя одну платформу, поменяйте вторую.
function Get-RemoteOpForConfig {
	param([int]$StartSec = 0, [int]$LengthSec = 0)

	$codec = Get-RemoteCodec $set_video_codec
	if (-not $codec) { return $null }

	$op = 'transcode'
	$p = "`"codec`":`"$codec`""

	if ($video_quality_status -eq '+') {
		$p += ",`"quality`":$video_quality_value"
	} elseif ($video_bitrate_status -eq '+') {
		$p += ",`"bitrate`":$([int]$video_bitrate_value * 1000),`"bitrate_cap_source`":true"
	}

	if ($video_resolution_status -eq '+') { $p += ",`"resolution`":`"$video_resolution_value`"" }
	if ($keep_aspect_ratio_value -eq 'yes') { $p += ",`"keep_aspect`":true" } else { $p += ",`"keep_aspect`":false" }
	if ($video_number_frames_status -eq '+') { $p += ",`"fps`":$video_number_frames_value" }
	if ($video_rotation_status -eq '+') { $p += ",`"rotate`":`"$video_rotation_value`"" }
	if ($playback_speed_status -eq '+' -and $playback_speed_value -ne '1.0') {
		$p += ",`"speed`":$playback_speed_value"
	}

	if ($video_subtitles_status -eq '+') {
		$p += ",`"subtitles`":`"$video_subtitles_value`""
		if ($subtitles_style) {
			$p += ",`"subtitle_style`":`"$(ConvertTo-RemoteJsonString $subtitles_style)`""
		}
	}

	$p += ",`"container`":`"$output_container_value`""
	$t = if ($threads) { $threads } else { 4 }
	$p += ",`"threads`":$t"

	if ($gpu_preset_status -eq '+') { $p += ",`"preset`":`"$gpu_preset_value`"" }
	if ($gpu_tune_status -eq '+')   { $p += ",`"tune`":`"$gpu_tune_value`"" }
	if ($gpu_rc_status -eq '+')     { $p += ",`"rc`":`"$gpu_rc_value`"" }

	$a = if ($audio_codec_status -eq '+') { "`"codec`":`"$audio_codec_value`"" } else { "`"codec`":`"copy`"" }
	if ($audio_bitrate_status -eq '+')         { $a += ",`"bitrate`":$audio_bitrate_value" }
	if ($audio_number_channels_status -eq '+') { $a += ",`"channels`":$audio_number_channels_value" }
	if ($audio_sampling_rate_status -eq '+')   { $a += ",`"rate`":$audio_sampling_rate_value" }
	if ($audio_normalize_status -eq '+')       { $a += ",`"normalize`":`"$audio_normalize_value`"" }
	$p += ",`"audio`":{$a}"

	# Отрезок — op: cut, а не op: split: имена part.N и manifest строит клиент.
	if ($StartSec -gt 0 -or $LengthSec -gt 0) {
		$op = 'cut'
		$p = "`"start`":$StartSec,`"reencode`":true," + $p
		if ($LengthSec -gt 0) { $p = "`"end`":$($StartSec + $LengthSec)," + $p }
	}

	return [pscustomobject]@{ Op = $op; Params = "{$p}" }
}

# --- HTTP ---
# Единственная точка выхода в сеть. Тест подменяет ЭТУ функцию — поэтому все
# остальные обязаны ходить только через неё.
#
# Не Invoke-WebRequest: в PowerShell 5.1 он буферизует тело целиком в память,
# и результат на 3 ГБ убил бы процесс.
function Invoke-RemoteHttp {
	param(
		[string]$Method,
		[string]$Path,
		[string]$Body = '',
		[hashtable]$Headers = @{},
		[string]$OutFile = '',
		[string]$InFile = ''
	)
	$req = [System.Net.HttpWebRequest]::Create("$remote_endpoint$Path")
	$req.Method = $Method
	$req.Timeout = 60000
	$req.ReadWriteTimeout = 600000
	$req.Headers.Add('Authorization', "Bearer $remote_api_key")
	foreach ($k in $Headers.Keys) {
		if ($k -eq 'Content-Range') { $req.Headers.Add($k, $Headers[$k]) }
		else { $req.Headers.Add($k, $Headers[$k]) }
	}
	try {
		if ($InFile) {
			$req.ContentType = 'application/octet-stream'
			$bytes = [System.IO.File]::ReadAllBytes($InFile)
			$req.ContentLength = $bytes.Length
			$rs = $req.GetRequestStream()
			$rs.Write($bytes, 0, $bytes.Length); $rs.Close()
		} elseif ($Body) {
			$req.ContentType = 'application/json'
			$bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
			$req.ContentLength = $bytes.Length
			$rs = $req.GetRequestStream()
			$rs.Write($bytes, 0, $bytes.Length); $rs.Close()
		}
		$resp = $req.GetResponse()
		$code = [int]$resp.StatusCode
		if ($OutFile) {
			# Потоком в файл: тело может быть в гигабайты.
			$src = $resp.GetResponseStream()
			$dst = [System.IO.File]::Create($OutFile)
			try { $src.CopyTo($dst, 1048576) } finally { $dst.Dispose(); $src.Dispose() }
			$text = ''
		} else {
			$sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
			$text = $sr.ReadToEnd(); $sr.Dispose()
		}
		$resp.Close()
		return [pscustomobject]@{ Code = $code; Body = $text }
	} catch [System.Net.WebException] {
		$code = 0
		$text = ''
		if ($_.Exception.Response) {
			$code = [int]$_.Exception.Response.StatusCode
			try {
				$sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
				$text = $sr.ReadToEnd(); $sr.Dispose()
			} catch {}
		}
		return [pscustomobject]@{ Code = $code; Body = $text }
	}
}

function Invoke-RemotePreflight {
	if (-not $remote_endpoint) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но адрес службы пуст. Задайте переменную окружения TRANSCODE_URL."
		return $false
	}
	if (-not $remote_api_key) {
		Write-Host "[ОШИБКА] [remote] enabled = yes, но ключ службы пуст. Задайте переменную окружения TRANSCODE_API_KEY."
		return $false
	}
	$r = Invoke-RemoteHttp GET '/capabilities'
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Служба конвертации недоступна: HTTP $($r.Code)."
		return $false
	}
	$caps = $r.Body | ConvertFrom-Json
	$script:RemoteChunkSize = if ($caps.chunk_size) { [int]$caps.chunk_size } else { 33554432 }
	$script:RemoteArgsVersion = $caps.args_version
	return $true
}

function Send-RemoteUpload {
	param([string]$Path)
	$size = (Get-Item -LiteralPath $Path).Length
	$r = Invoke-RemoteHttp POST '/uploads'
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не приняла загрузку: HTTP $($r.Code)."; return $null }
	$u = $r.Body | ConvertFrom-Json
	$uid = $u.upload_id
	if ($u.chunk_size) { $script:RemoteChunkSize = [int]$u.chunk_size }
	$chunk = $script:RemoteChunkSize

	$offset = 0
	$r = Invoke-RemoteHttp GET "/uploads/$uid"
	if ($r.Code -eq 200) { $offset = [int64](($r.Body | ConvertFrom-Json).received) }

	$tmp = [System.IO.Path]::GetTempFileName()
	$fs = [System.IO.File]::OpenRead($Path)
	try {
		while ($offset -lt $size) {
			$this = [Math]::Min([int64]$chunk, $size - $offset)
			$buf = New-Object byte[] $this
			$fs.Seek($offset, 'Begin') | Out-Null
			$fs.Read($buf, 0, $this) | Out-Null
			[System.IO.File]::WriteAllBytes($tmp, $buf)
			$r = Invoke-RemoteHttp PATCH "/uploads/$uid" '' `
				@{ 'Content-Range' = "bytes $offset-$($offset + $this - 1)/$size" } '' $tmp
			if ($r.Code -ne 200) {
				Write-Host "[ОШИБКА] Служба отвергла кусок $offset : HTTP $($r.Code)."
				return $null
			}
			$offset += $this
			Write-RemoteUploadProgress $offset $size
		}
	} finally { $fs.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

	$sha = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
	$r = Invoke-RemoteHttp POST "/uploads/$uid/complete" "{`"size`":$size,`"sha256`":`"$sha`"}"
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба не подтвердила загрузку: HTTP $($r.Code)."; return $null }
	return $uid
}

function Get-RemoteJobBody {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '', [string]$Extra = '')
	$p = $Params
	if ($SubtitleId) { $p = $p.Substring(0, $p.Length - 1) + ",`"subtitle_upload_id`":`"$SubtitleId`"}" }
	$b = "{`"upload_id`":`"$UploadId`",`"op`":`"$Op`",`"params`":$p"
	$pref = if ($remote_prefer) { $remote_prefer } else { 'auto' }
	$wt   = if ($remote_wait_timeout) { $remote_wait_timeout } else { 1800 }
	$b += ",`"prefer`":`"$pref`",`"wait_timeout`":$wt"
	if ($overwrite_existing -eq 'yes') { $b += ",`"no_reuse`":true" }
	if ($Extra) { $b += ",$Extra" }
	return "$b}"
}

function Submit-RemoteJob {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '')
	$r = Invoke-RemoteHttp POST '/jobs' (Get-RemoteJobBody $UploadId $Op $Params $SubtitleId)
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Служба отвергла задачу: HTTP $($r.Code) — $($r.Body)"; return $null }
	return ($r.Body | ConvertFrom-Json).job_id
}

function Invoke-RemoteDryRun {
	param([string]$UploadId, [string]$Op, [string]$Params, [string]$SubtitleId = '')
	$r = Invoke-RemoteHttp POST '/jobs' (Get-RemoteJobBody $UploadId $Op $Params $SubtitleId '"dry_run":true')
	if ($r.Code -ne 200) { Write-Host "[ОШИБКА] Холостой прогон отвергнут: HTTP $($r.Code) — $($r.Body)"; return $false }
	Write-Host "[DRY-RUN][REMOTE] $($r.Body)"
	return $true
}

function Wait-RemoteJob {
	param([string]$JobId, [string]$Label, [scriptblock]$OnProgress = $null)
	$script:RemoteCurrentJob = $JobId
	while ($true) {
		$r = Invoke-RemoteHttp GET "/jobs/$JobId"
		if ($r.Code -ne 200) {
			Write-Host "[ОШИБКА] Состояние задачи недоступно: HTTP $($r.Code)."
			$script:RemoteCurrentJob = ''; return $false
		}
		$j = $r.Body | ConvertFrom-Json
		switch ($j.state) {
			'done'      { if ($OnProgress) { & $OnProgress 100 $Label }; $script:RemoteCurrentJob = ''; return $true }
			'failed'    { Write-Host "[ОШИБКА] Задача провалена: $($j.error)"; $script:RemoteCurrentJob = ''; return $false }
			'cancelled' { Write-Host "[ОШИБКА] Задача отменена."; $script:RemoteCurrentJob = ''; return $false }
			'waiting_gpu' {
				Write-Host ("  ожидание карты: {0} с, не хватает {1} МиБ" -f $j.waiting_seconds, $j.missing_mib)
			}
			default { if ($OnProgress) { & $OnProgress ([int]$j.progress) $Label } }
		}
		Start-Sleep -Seconds $(if ($env:REMOTE_POLL_SECONDS) { [int]$env:REMOTE_POLL_SECONDS } else { 2 })
	}
}

function Receive-RemoteResult {
	param([string]$JobId, [string]$Destination)
	$r = Invoke-RemoteHttp GET "/jobs/$JobId/result" '' @{} $Destination
	if ($r.Code -ne 200) {
		Write-Host "[ОШИБКА] Результат недоступен: HTTP $($r.Code)."
		Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
		return $false
	}
	return $true
}

function Stop-RemoteJob {
	param([string]$JobId)
	if (-not $JobId) { return }
	Invoke-RemoteHttp DELETE "/jobs/$JobId" | Out-Null
}

# Прогресс загрузки. В GUI переопределяется — см. FFmpeg_Converter_script.ps1.
if (-not (Get-Command Write-RemoteUploadProgress -ErrorAction SilentlyContinue)) {
	function Write-RemoteUploadProgress {
		param([int64]$Done, [int64]$Total)
		if ($Total -gt 0) {
			Write-Progress -Activity "Отправка на сервер" -PercentComplete ([int]($Done * 100 / $Total))
		}
	}
}
```

- [ ] **Step 4: Прогнать тест**

Run: `bash tests/ffmpeg/test_22_remote_ps1.sh`
Expected: PASS, `fail=0` (или SKIP без PowerShell).

- [ ] **Step 5: Проверить кодировку**

Run: `bash tests/common/test_encoding.sh`
Expected: PASS — `remote_client.ps1` с BOM, `remote_client.sh` без BOM. Если новый файл не покрыт набором, дописать его в список проверяемых.

- [ ] **Step 6: Коммит**

```bash
git add ffmpeg/remote_client.ps1 tests/ffmpeg/test_22_remote_ps1.sh
git commit -m "remote: модуль клиента для PowerShell"
```

---

### Task 8: Паритет SH ↔ PS1

Отдельной задачей, потому что это единственный тест, который ловит расхождение сборщиков — то самое, из-за чего один `config.ini` дал бы разные файлы на разных платформах.

**Files:**
- Create: `tests/ffmpeg/test_23_remote_parity.sh`

**Interfaces:**
- Consumes: `remote_op_for_config` (Task 2), `Get-RemoteOpForConfig` (Task 7).

- [ ] **Step 1: Написать тест**

```bash
#!/bin/bash
# ============================================================
# test_23_remote_parity.sh — SH и PS1 обязаны собирать ОДИН И ТОТ ЖЕ JSON.
#
# Не «похожий»: строки сравниваются целиком. Разойдись порядок полей или
# формат числа — один config.ini дал бы на двух платформах разные файлы,
# и это единственный тест, который такое видит.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/remote_client.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "remote: паритет SH ↔ PS1"
    skip "паритет сборщиков" "PowerShell не найден"
    summary
    exit 0
fi
MODULE="$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/remote_client.ps1"

# Профили: имя, затем присваивания для SH и для PS1 (одни и те же значения).
# Каждый профиль соответствует реальному сценарию config.ini.
profiles=(
  "умолчания|quality"
  "битрейт вместо quality|bitrate"
  "поворот и скорость|rotate_speed"
  "прожиг субтитров со стилем|subs"
  "GPU-пресеты|gpu"
  "звук без перекодирования|audio_copy"
)

sh_vars() {
  set_video_codec="libx264"
  video_quality_status="+";       video_quality_value="23"
  video_bitrate_status="-";       video_bitrate_value="3000"
  video_resolution_status="+";    video_resolution_value="1280x720"
  video_number_frames_status="+"; video_number_frames_value="30"
  video_rotation_status="-";      video_rotation_value="2"
  video_subtitles_status="-";     video_subtitles_value="burn"
  keep_aspect_ratio_value="yes";  output_container_value="mp4"
  audio_codec_status="+";           audio_codec_value="aac"
  audio_number_channels_status="+"; audio_number_channels_value="2"
  audio_bitrate_status="+";         audio_bitrate_value="128"
  audio_sampling_rate_status="+";   audio_sampling_rate_value="48000"
  audio_normalize_status="-";       audio_normalize_value="loudnorm"
  playback_speed_status="-";      playback_speed_value="1.0"
  gpu_preset_status="-"; gpu_preset_value="p5"
  gpu_tune_status="-";   gpu_tune_value="hq"
  gpu_rc_status="-";     gpu_rc_value="vbr"
  threads="4"; subtitles_style=""
  case "$1" in
    bitrate)      video_quality_status="-"; video_bitrate_status="+" ;;
    rotate_speed) video_rotation_status="+"; playback_speed_status="+"; playback_speed_value="1.75" ;;
    subs)         video_subtitles_status="+"; subtitles_style="FontName=Arial,FontSize=24" ;;
    gpu)          gpu_preset_status="+"; gpu_tune_status="+"; gpu_rc_status="+" ;;
    audio_copy)   audio_codec_status="-" ;;
  esac
}

ps_vars() {
  cat <<PSEOF
\$set_video_codec="libx264"
\$video_quality_status="+";       \$video_quality_value="23"
\$video_bitrate_status="-";       \$video_bitrate_value="3000"
\$video_resolution_status="+";    \$video_resolution_value="1280x720"
\$video_number_frames_status="+"; \$video_number_frames_value="30"
\$video_rotation_status="-";      \$video_rotation_value="2"
\$video_subtitles_status="-";     \$video_subtitles_value="burn"
\$keep_aspect_ratio_value="yes";  \$output_container_value="mp4"
\$audio_codec_status="+";           \$audio_codec_value="aac"
\$audio_number_channels_status="+"; \$audio_number_channels_value="2"
\$audio_bitrate_status="+";         \$audio_bitrate_value="128"
\$audio_sampling_rate_status="+";   \$audio_sampling_rate_value="48000"
\$audio_normalize_status="-";       \$audio_normalize_value="loudnorm"
\$playback_speed_status="-";      \$playback_speed_value="1.0"
\$gpu_preset_status="-"; \$gpu_preset_value="p5"
\$gpu_tune_status="-";   \$gpu_tune_value="hq"
\$gpu_rc_status="-";     \$gpu_rc_value="vbr"
\$threads=4; \$subtitles_style=""
PSEOF
  case "$1" in
    bitrate)      echo '$video_quality_status="-"; $video_bitrate_status="+"' ;;
    rotate_speed) echo '$video_rotation_status="+"; $playback_speed_status="+"; $playback_speed_value="1.75"' ;;
    subs)         echo '$video_subtitles_status="+"; $subtitles_style="FontName=Arial,FontSize=24"' ;;
    gpu)          echo '$gpu_preset_status="+"; $gpu_tune_status="+"; $gpu_rc_status="+"' ;;
    audio_copy)   echo '$audio_codec_status="-"' ;;
  esac
}

suite "remote: паритет SH ↔ PS1"
for entry in "${profiles[@]}"; do
  name="${entry%%|*}"; key="${entry##*|}"
  for pair in "0 0" "60 300"; do
    set -- $pair
    sh_vars "$key"
    sh_out="$(remote_op_for_config "$1" "$2")"
    sh_op="$(printf '%s' "$sh_out" | head -1)"
    sh_params="$(printf '%s' "$sh_out" | tail -1)"
    ps_script="$(ps_vars "$key")"
    ps_res="$("$PS_BIN" -NoProfile -NonInteractive -Command "
      . '$MODULE'
      $ps_script
      \$r = Get-RemoteOpForConfig $1 $2
      Write-Output \$r.Op
      Write-Output \$r.Params
    " 2>&1 | tr -d '\r')"
    ps_op="$(printf '%s' "$ps_res" | head -1)"
    ps_params="$(printf '%s' "$ps_res" | tail -1)"
    assert_eq "$name ($1/$2): операция" "$sh_op" "$ps_op"
    assert_eq "$name ($1/$2): параметры" "$sh_params" "$ps_params"
  done
done

summary
```

- [ ] **Step 2: Прогнать тест**

Run: `bash tests/ffmpeg/test_23_remote_parity.sh`
Expected: сначала возможны провалы — расхождения форматирования (например `1.75` против `1,75` в локали, или `[int]` без нуля). Каждое расхождение исправлять **в `.ps1`**, приводя к формату `.sh`, и прогонять снова.

- [ ] **Step 3: Прогнать до зелёного**

Run: `bash tests/ffmpeg/test_23_remote_parity.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 4: Коммит**

```bash
git add tests/ffmpeg/test_23_remote_parity.sh ffmpeg/remote_client.ps1
git commit -m "remote: тест паритета сборщиков SH и PS1"
```

---

### Task 9: Стыковка в `FFmpeg_Converter_script.ps1`

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.ps1` — подключение модуля, режимный блок, `Encode-File:1051-1179`
- Test: `tests/ffmpeg/test_16_gui_state.sh` (дописать) либо новый набор в `test_08_ps1_audio_video.sh`

**Interfaces:**
- Consumes: всё из Task 7.
- Produces: `$remote_active` — паритет с `remote_active` в `.sh`.

- [ ] **Step 1: Написать падающую проверку**

Дописать в `tests/ffmpeg/test_08_ps1_audio_video.sh` перед `summary`:

```bash
suite "remote PS1: локальные режимы и preflight"
_ps_check() {
    "$PS_BIN" -NoProfile -NonInteractive -Command "$1" 2>&1 | tr -d '\r'
}
_script="$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/FFmpeg_Converter_script.ps1"
out="$(_ps_check "
  \$remote_enabled='yes'; \$remote_endpoint=''; \$remote_api_key=''
  \$copy_codecs='yes'; \$merge_files='no'; \$create_frame='no'
  \$audio_only='no'; \$extract_audio_copy='no'
  . '$(cd "$PROJECT_DIR/ffmpeg" && pwd -W 2>/dev/null || echo "$PROJECT_DIR/ffmpeg")/remote_client.ps1'
  # Блок выбора режима вынесен в функцию — см. шаг реализации.
  Set-RemoteActive | Out-Null
  Write-Output \$script:remote_active
")"
assert_eq "copy_codecs не уезжает" "no" "$out"
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_08_ps1_audio_video.sh`
Expected: FAIL — `Set-RemoteActive` не определена.

- [ ] **Step 3: Подключить модуль и вычислить режим**

В `ffmpeg/FFmpeg_Converter_script.ps1`, рядом с определением `$ffmpeg`:

```powershell
# Удалённый бэкенд — отдельный модуль: только объявляет функции, ничего не делает сам.
$_remoteModule = Join-Path $PSScriptRoot 'remote_client.ps1'
if (Test-Path -LiteralPath $_remoteModule) { . $_remoteModule }
```

В `ffmpeg/remote_client.ps1` дописать функцию выбора режима — она общая для CLI и GUI, поэтому живёт в модуле:

```powershell
# Уезжает только то, где выигрывает карта. remux, concat, frames, audio и
# extract_audio служба умеет, но карта в них не участвует: гнать гигабайты по
# сети ради `-c copy` заведомо хуже локального прогона. Молчать нельзя —
# режим, который тихо не уехал, неотличим от сломанного удалённого пути.
function Set-RemoteActive {
	$script:remote_active = 'no'
	if ($remote_enabled -ne 'yes') { return $false }
	if ($merge_files -eq 'yes' -or $extract_audio_copy -eq 'yes' -or
	    $create_frame -eq 'yes' -or $copy_codecs -eq 'yes' -or $audio_only -eq 'yes') {
		Write-Host "[ИНФО] Удалённый бэкенд не используется в этом режиме (карта в нём не участвует) — считаем локально"
		return $false
	}
	if (-not (Invoke-RemotePreflight)) { return $false }
	if ($hw_accel_status -eq '+' -and $hw_accel_value -eq 'intel') {
		Write-Host "[ПРЕДУПРЕЖДЕНИЕ] hw_accel = intel: Intel-карты на сервере нет, служба посчитает на процессоре."
	}
	$script:remote_active = 'yes'
	return $true
}
```

`Set-RemoteActive` обязана отличать два разных «нет»: режим, который считается локально по замыслу, и отказ preflight, после которого работать нельзя вовсе. Иначе прогон с пустым ключом тихо ушёл бы на локальный процессор — тот самый молчаливый откат, которого в этом проекте нет. Поэтому функция выставляет `$script:remote_fatal`:

```powershell
	if (-not (Invoke-RemotePreflight)) { $script:remote_fatal = $true; return $false }
```

и объявляет `$script:remote_fatal = $false` первой строкой тела, рядом с `$script:remote_active = 'no'`.

В `FFmpeg_Converter_script.ps1` перед основным циклом:

```powershell
$remote_active = 'no'
if ($remote_enabled -eq 'yes') {
	Set-RemoteActive | Out-Null
	if ($script:remote_fatal) {
		# Preflight не прошёл — не трогаем ни одного файла. Отказать на сотом
		# файле из двухсот дороже, чем на нулевом.
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	$remote_active = $script:remote_active
	if ($remote_active -eq 'yes') {
		Log-Msg "INFO" "Удалённый бэкенд включён: кодирование уходит на службу конвертации"
	}
}
```

- [ ] **Step 4: Удалённая ветка в `Encode-File`**

В `ffmpeg/FFmpeg_Converter_script.ps1` заменить начало блока `# D7. Dry-run` (строка 1051):

```powershell
		# Удалённый бэкенд подменяет РОВНО этот участок: сборку argv и запуск
		# ffmpeg. Всё до и после остаётся общим — поэтому один config.ini даёт
		# один результат на обоих путях.
		if ($remote_active -eq 'yes') {
			$rLen = 0
			if ($current_set_length -match '^-t\s+(\d+)') { $rLen = [int]$Matches[1] }
			$rMap = Get-RemoteOpForConfig ([int]$b) $rLen
			if ($null -eq $rMap) {
				Log-Msg "FAIL" "$($file.Name): кодек $set_video_codec служба не поддерживает"
				$anyFail = $true; $script:countFail++
			} else {
				if (-not $script:remoteUploadId) {
					Log-Msg "INFO" "Отправка на сервер: $($file.Name)"
					$script:remoteUploadId = Send-RemoteUpload $full_path
					$script:remoteSubId = ''
					if ($script:remoteUploadId -and $sub_found -and $sub_file) {
						$script:remoteSubId = Send-RemoteUpload $sub_file
					}
				}
				if (-not $script:remoteUploadId) {
					Log-Msg "FAIL" "$($file.Name): загрузка не удалась"
					$anyFail = $true; $script:countFail++
				} elseif ($dry_run -eq 'yes') {
					Invoke-RemoteDryRun $script:remoteUploadId $rMap.Op $rMap.Params $script:remoteSubId | Out-Null
				} else {
					$jobId = Submit-RemoteJob $script:remoteUploadId $rMap.Op $rMap.Params $script:remoteSubId
					if (-not $jobId) {
						Log-Msg "FAIL" "$($file.Name): служба отвергла задачу"
						$anyFail = $true; $script:countFail++
					} else {
						$startTime = Get-Date
						$onProgress = {
							param($pct, $label)
							if ($guiProgressFile) { Write-GUIProgress -FilePercent $pct -CurrentFile $label }
							else { Write-Progress -Activity "Кодирование на сервере" -Status $label -PercentComplete $pct }
						}
						$ok = (Wait-RemoteJob $jobId $file.Name $onProgress) -and
						      (Receive-RemoteResult $jobId $out_tmp)
						if ($ok) {
							Publish-EncodedResult $file $out_tmp $out_file $startTime
						} else {
							Log-Msg "FAIL" "$($file.Name)"
							if (Test-Path -LiteralPath $out_tmp) { Remove-Item -LiteralPath $out_tmp -Force -ErrorAction SilentlyContinue }
							$anyFail = $true; $script:countFail++
						}
					}
				}
			}
		} elseif ($dry_run -eq "yes") {
```

`$script:remoteUploadId` и `$script:remoteSubId` сбрасывать в `''` в начале `Encode-File`, рядом с `$produced`.

- [ ] **Step 5: Вынести публикацию результата в общую функцию**

Рядом с `Get-PartialPath` (строка ~500) добавить — паритет с `publish_result` из Task 6:

```powershell
# Публикация результата — общая для локального и удалённого путей. Логика
# обязана существовать в одном экземпляре: разойдись она между путями,
# «успех» значил бы разное, и сводка ok/fail перестала бы что-либо значить.
#
# Удалённый путь добавляет проверку, которой у локального не было: размер и
# читаемость СКАЧАННОГО файла. Локальный ffmpeg с rc=0 нулевой файл не
# оставляет, а оборванная загрузка — запросто.
function Publish-EncodedResult {
	param($File, [string]$Tmp, [string]$Destination, $StartTime)
	$elapsed = (Get-Date) - $StartTime
	$elapsedStr = "{0}m {1}s" -f [int]$elapsed.TotalMinutes, $elapsed.Seconds

	$valid = $false
	if ((Test-Path -LiteralPath $Tmp) -and (Get-Item -LiteralPath $Tmp).Length -gt 0) {
		& $ffmpeg -nostdin -v error -i $Tmp -f null - 2>$null | Out-Null
		$valid = ($LASTEXITCODE -eq 0)
	}
	if (-not $valid) {
		Log-Msg "FAIL" "$($File.Name): результат не прошёл проверку"
		if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
		$script:anyFail = $true; $script:countFail++
		Write-GUIProgress -FilePercent 0 -CurrentFile $File.Name
		return $false
	}

	# F-rename. Публикацию подтверждаем: Move-Item -ErrorAction Stop И наличие
	# файла-цели. Без -ErrorAction Stop сбой rename нетерминирующий — результат
	# засчитался бы как OK, а manifest записался бы поверх отсутствующего файла.
	try {
		Move-Item -LiteralPath $Tmp -Destination $Destination -Force -ErrorAction Stop
	} catch {
		Log-Msg "FAIL" "$($File.Name): не удалось опубликовать результат (rename): $_"
		if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue }
		$script:anyFail = $true; $script:countFail++
		Write-GUIProgress -FilePercent 0 -CurrentFile $File.Name
		return $false
	}
	if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
		Log-Msg "FAIL" "$($File.Name): результат не появился по целевому пути"
		$script:anyFail = $true; $script:countFail++
		return $false
	}

	Log-Msg "OK" "$($File.Name) -> $(Split-Path $Destination -Leaf) ($elapsedStr)"
	$script:countOk++
	$script:produced += $Destination
	# F29. Вход — только с первой удавшейся части.
	try {
		if (-not $script:inReported) { $script:totalInBytes += $File.Length; $script:inReported = $true }
		$script:totalOutBytes += (Get-Item -LiteralPath $Destination).Length
	} catch {}
	Write-GUIProgress -FilePercent 100 -CurrentFile $File.Name
	return $true
}
```

Затем в `Encode-File` заменить блок `} else { … Move-Item … }` (строки 1151–1178 исходного файла) на:

```powershell
			} else {
				Publish-EncodedResult $file $out_tmp $out_file $startTime | Out-Null
			}
```

Ветка `if ($exitCode -ne 0)` (последние строки `errBuf`, ожидание освобождения файла после `Kill`, удаление `out_tmp`) остаётся как была: она про отказ самого ffmpeg, а не про публикацию.

Переменные `$produced`, `$anyFail`, `$inReported` в `Encode-File` объявлены локально — при переносе логики в функцию обращаться к ним через `$script:`, иначе счётчики будут теряться. Прогон `tests/run_tests.sh ffmpeg` это подтвердит: локальный путь покрыт существующими наборами.

- [ ] **Step 6: Отмена задачи по кнопке Stop**

В цикле ожидания в `Wait-RemoteJob` уже есть выход по состоянию; добавить в `FFmpeg_Converter_script.ps1` там, где проверяется `$guiCancelFile`, вызов:

```powershell
	if ($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) {
		Stop-RemoteJob $script:RemoteCurrentJob
	}
```

- [ ] **Step 7: Прогнать тесты**

Run: `bash tests/run_tests.sh ffmpeg`
Expected: PASS, `fail=0`.

- [ ] **Step 8: Коммит**

```bash
git add ffmpeg/FFmpeg_Converter_script.ps1 ffmpeg/remote_client.ps1 tests/ffmpeg/test_08_ps1_audio_video.sh
git commit -m "remote: удалённая ветка в Encode-File (.ps1)"
```

---

### Task 10: Группа «Сервер» в GUI

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_run_win_v17.ps1`
- Test: `tests/ffmpeg/test_16_gui_state.sh`

**Interfaces:**
- Consumes: `Read-Config` GUI, `Invoke-RemotePreflight`.
- Produces: контролы `$chkRemote`, `$cmbRemotePrefer`, `$txtRemoteWait`, метка `$lblRemoteCreds`.

- [ ] **Step 1: Написать падающую проверку**

Дописать в `tests/ffmpeg/test_16_gui_state.sh` перед `summary`:

```bash
suite "GUI: группа «Сервер»"
GUI="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_win_v17.ps1"
gui_text="$(cat "$GUI")"
assert_contains "галка удалённого счёта" 'chkRemote'        "$gui_text"
assert_contains "выбор prefer"           'cmbRemotePrefer'  "$gui_text"
assert_contains "поле таймаута"          'txtRemoteWait'    "$gui_text"
assert_contains "метка состояния ключа"  'lblRemoteCreds'   "$gui_text"
# Приватное из GUI не редактируется и, значит, не может попасть в config.ini.
assert_not_contains "нет поля ввода адреса" 'txtRemoteEndpoint' "$gui_text"
assert_not_contains "нет поля ввода ключа"  'txtRemoteApiKey'   "$gui_text"
```

- [ ] **Step 2: Прогнать и убедиться, что падает**

Run: `bash tests/ffmpeg/test_16_gui_state.sh`
Expected: FAIL — контролов нет.

- [ ] **Step 3: Добавить группу в GUI**

Рядом с существующими группами (следуя тому же стилю создания контролов, что уже в файле):

```powershell
# Группа «Сервер». Адрес и ключ здесь ТОЛЬКО показываются: GUI сохраняет свои
# значения в config.ini, а он лежит в публичном репозитории — дай мы их
# редактировать, приватное уехало бы в коммит. Менять их можно лишь через
# переменные окружения TRANSCODE_URL и TRANSCODE_API_KEY.
$grpRemote = New-Object System.Windows.Forms.GroupBox
$grpRemote.Text = "Сервер конвертации"

$chkRemote = New-Object System.Windows.Forms.CheckBox
$chkRemote.Text = "Считать на сервере"
$chkRemote.Checked = ((Read-Config "enabled" "remote" "no") -eq "yes")

$cmbRemotePrefer = New-Object System.Windows.Forms.ComboBox
$cmbRemotePrefer.DropDownStyle = 'DropDownList'
[void]$cmbRemotePrefer.Items.AddRange(@("auto", "gpu", "cpu"))
$cmbRemotePrefer.SelectedItem = (Read-Config "prefer" "remote" "auto")

$txtRemoteWait = New-Object System.Windows.Forms.TextBox
$txtRemoteWait.Text = (Read-Config "wait_timeout" "remote" "1800")

$lblRemoteCreds = New-Object System.Windows.Forms.Label
$_ep = Read-Config "endpoint" "remote" ""
$_ak = Read-Config "api_key" "remote" ""
$lblRemoteCreds.Text = if ($_ep -and $_ak) {
	"Адрес и ключ: заданы (переменные окружения)"
} else {
	"Адрес и ключ: НЕ заданы — задайте TRANSCODE_URL и TRANSCODE_API_KEY"
}
```

Разместить контролы и добавить группу на форму по образцу соседних групп файла.

- [ ] **Step 4: Записывать три ключа обратно в `config.ini`**

Там, где GUI собирает `config.ini` из контролов, дописать секцию — **только три поведенческих ключа**, `endpoint` и `api_key` переносить из прежнего файла как есть:

```powershell
"[remote]"
"enabled = " + $(if ($chkRemote.Checked) { "yes" } else { "no" })
"endpoint = " + $rawRemoteEndpoint   # строка из прежнего config.ini, НЕ развёрнутое значение
"api_key = " + $rawRemoteApiKey      # то же: сохраняем ${TRANSCODE_API_KEY}, а не ключ
"prefer = " + $cmbRemotePrefer.SelectedItem
"wait_timeout = " + $txtRemoteWait.Text
```

`$rawRemoteEndpoint`/`$rawRemoteApiKey` читать **до подстановки `${VAR}`** — сырыми строками из файла. Иначе GUI при первом же сохранении запишет в `config.ini` развёрнутое значение переменной, то есть настоящий адрес и ключ.

- [ ] **Step 5: Прогнать тесты**

Run: `bash tests/ffmpeg/test_16_gui_state.sh` затем `bash tests/run_tests.sh`
Expected: PASS, `fail=0`.

- [ ] **Step 6: Проверить руками, что GUI не пишет приватное**

Запустить GUI, поставить галку, сохранить, посмотреть `ffmpeg/config.ini`.
Expected: в файле стоят `${TRANSCODE_URL}` и `${TRANSCODE_API_KEY}`, а не их значения.

- [ ] **Step 7: Коммит**

```bash
git add ffmpeg/FFmpeg_Converter_run_win_v17.ps1 tests/ffmpeg/test_16_gui_state.sh
git commit -m "remote: группа «Сервер» в GUI"
```

---

### Task 11: Guardrail приватности, документация, EXE и приёмка

**Files:**
- Modify: `tests/common/test_guardrails.sh`
- Modify: `README.md`, `CLAUDE.md`
- Test: весь набор

- [ ] **Step 1: Написать guardrail приватности**

Дописать в `tests/common/test_guardrails.sh`:

```bash
suite "приватность: адрес и ключ службы не в репозитории"
# Литеральный адрес службы или ключ в коммитимом файле — это утечка, а
# репозиторий публичный. Ищем по форме, а не по конкретному значению:
# конкретные значения нельзя записать в тест по той же причине.
_priv_hits="$(git -C "$PROJECT_DIR" grep -nIE \
    'https?://(10|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+' \
    -- ':!tests/*' ':!docs/*' 2>/dev/null || true)"
assert_empty "нет приватных IP в URL" "$_priv_hits"

_key_hits="$(git -C "$PROJECT_DIR" grep -nIE \
    '^[[:space:]]*api_key[[:space:]]*=[[:space:]]*[^$[:space:]].*' \
    -- 'ffmpeg/config.ini' 'yt-dlp/config.ini*' 2>/dev/null || true)"
assert_empty "api_key задан только переменной" "$_key_hits"
```

- [ ] **Step 2: Прогнать guardrail**

Run: `bash tests/common/test_guardrails.sh`
Expected: PASS, `fail=0`. Если что-то нашлось — это находка, убрать значение до коммита.

- [ ] **Step 3: Дописать раздел в `README.md`**

```markdown
### Удалённый счёт на сервере конвертации

При `[remote] enabled = yes` кодирование уезжает на HTTP-службу конвертации, а
обход папок, имена выходов и учёт готового остаются локальными. Адрес и ключ
задаются переменными окружения `TRANSCODE_URL` и `TRANSCODE_API_KEY` — в
`config.ini` стоят только их имена.

Уезжает только то, где выигрывает карта: обычное перекодирование и отрезки.
Режимы `copy_codecs`, `merge_files`, `create_frame`, `audio_only` и
`extract_audio_copy` считаются локально — карта в них не участвует.

Доступно в `.sh`, `.ps1` и GUI. В `.cmd` режим не поддерживается: в cmd.exe нет
нарезки файла по смещениям, sha256 и разбора JSON — там печатается
предупреждение, и файлы считаются локально.
```

- [ ] **Step 4: Дописать ограничения в `CLAUDE.md`**

В раздел «Key Constraints»:

```markdown
- Удалённый бэкенд (`[remote] enabled`) есть только в `.sh`/`.ps1`/GUI; `.cmd` читает ключи и печатает `[ПРЕДУПРЕЖДЕНИЕ]` — в cmd.exe нет нарезки файла по смещениям, `sha256` и разбора JSON. Адрес и ключ живут **только** в переменных окружения `TRANSCODE_URL`/`TRANSCODE_API_KEY`: репозиторий публичный, и GUI поэтому показывает их как «задано/не задано», но не редактирует. JSON собирается **в одинаковом порядке полей** в `ffmpeg/remote_client.sh` и `ffmpeg/remote_client.ps1` — это контракт, его сверяет `tests/ffmpeg/test_23_remote_parity.sh` сравнением строк целиком. Разрезание на части остаётся клиентским циклом (`op: cut` на часть, не `op: split`): имена `part.N` и `manifest` строит клиент. Автоматического отката на локальный ffmpeg нет — на пакете в двести файлов молчаливый переход на процессор неотличим от зависания
```

- [ ] **Step 5: Прогнать весь набор**

Run: `bash tests/run_tests.sh`
Expected: `fail=0` во всех трёх наборах (`ffmpeg`, `yt-dlp`, `common`).

- [ ] **Step 6: Собрать EXE**

Run: `powershell -File ffmpeg/build_exe.ps1`
Expected: EXE собран без ошибок.

- [ ] **Step 7: Проверить запуск EXE на машине с антивирусом**

Это **обязательный** шаг, а не формальность: `.ps1` теперь скачивает файлы из сети и пишет их на диск — ровно тот класс поведения, за который Kaspersky заблокировал `yt-dlp` v17. Запустить собранный EXE на машине с антивирусом и убедиться, что он стартует.
Expected: окно GUI открывается. Если заблокирован — откатывать по одному изменению за раз, начиная с текста сообщений и комментариев, как делали в `tools/av-rollback`.

- [ ] **Step 8: Живая приёмка по спеке**

Пройти 12 пунктов раздела 14 спеки на настоящей службе. Пункты 1 (совпадение холостых прогонов) и 3 (имена `part.N`) выполнить **первыми**: они не требуют гонять гигабайты и показывают расхождение сборщиков раньше всего. Результат каждого пункта записать в `FINDINGS.md`, если что-то разошлось.

- [ ] **Step 9: Коммит**

```bash
git add tests/common/test_guardrails.sh README.md CLAUDE.md
git commit -m "remote: guardrail приватности, документация и ограничения"
```

---

## Порядок и зависимости

```
Task 1 (config)
  ├─→ Task 2 (маппинг .sh) ─→ Task 3 (HTTP .sh) ─→ Task 4 (загрузка) ─→ Task 5 (задача) ─→ Task 6 (стыковка .sh)
  └─→ Task 7 (модуль .ps1) ──────────────────────────────────────────────→ Task 9 (стыковка .ps1) ─→ Task 10 (GUI)
                    Task 8 (паритет) требует Task 2 и Task 7
                                                                              Task 11 — последняя
```

Task 2 и Task 7 независимы после Task 1 и могут идти параллельно. Task 8 — первая точка, где расхождение платформ становится видно; не откладывать её за Task 9.
