# Распознавание речи (ASR) в конвертере — план реализации

> ⚠️ **АРХИВ после выполнения.** План — исторический документ: он предписывает
> действия на дату написания. Действующее поведение описывают `docs/constraints.md`
> (раздел «Распознавание речи») и `README.md`; где они расходятся с планом — правы они.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** режим `[asr] enabled = yes` в `ffmpeg/`: файлы из `source` расшифровываются на сервере WhisperX, в `destination` ложатся `<имя>.txt` (реплики с говорящими) и `<имя>.asr.json` (сырой ответ).

**Architecture:** два новых модуля-клиента — `ffmpeg/asr_client.sh` и `ffmpeg/asr_client.ps1` — по образцу `remote_client.*`: только функции, результаты в глобальных `ASR_*` / `$script:Asr*`. Оба ходят на сервер через curl (системный `curl.exe` в Windows) с закреплённым ключом сервера; звук извлекает локальный ffmpeg (FLAC, моно, 16 кГц); длинная запись режется на равные части по живым пределам сервера. Текст из JSON собирают `awk` (.sh) и `ConvertFrom-Json` (.ps1) — байт в байт одинаково, это сверяют общие фикстуры. Конвертерные скрипты получают ветку ASR охранными условиями в четырёх местах; GUI — группу «Распознавание речи (ASR)»; `.cmd` отказывается с кодом 1.

**Tech Stack:** bash 3.2+ (Git Bash, macOS, Linux), POSIX awk (gawk/mawk/BWK), Windows PowerShell 5.1 / pwsh, curl ≥ 7.58 (`--pinnedpubkey`), cmd.exe, WinForms, ps2exe.

**Spec:** [`docs/superpowers/specs/2026-10-02-ffmpeg-asr-design.md`](../specs/2026-10-02-ffmpeg-asr-design.md)

## Global Constraints

- Репозиторий публичный: адрес сервера, ключ и пин — только в некоммитимом `ffmpeg/config.ini`; в коде, тестах, фикстурах и документах — `<хост>` или `*.example`.
- Коммиты — без trailer'а `Co-Authored-By` (CLAUDE.md проекта); многострочное сообщение — через файл и `git commit -F`.
- `.ps1` — UTF-8 с BOM (после Write — BOM Python'ом); `.sh` — UTF-8 без BOM, LF; `.cmd` — CRLF; проверка — `bash tests/common/test_encoding.sh`.
- `.sh` совместим с bash 3.2 и BSD-утилитами: нет `${var,,}`, `EPOCHSECONDS`, `printf %(…)T` без запасного пути, `wait -n`, `mapfile`, ассоциативных массивов.
- Печатающая функция (транзитивно зовущая `log_msg`) не вызывается через `$( )` — guardrail в `test_guardrails.sh`.
- Новый тест-файл регистрируется сразу в `tests/run_tests.sh` (`FFMPEG_TESTS`) и в таблице `README.md`.
- Тесты не ходят в сеть: curl только мок через `CURL_BIN`, в `.ps1`-тестах подменяется `Invoke-AsrCurl`.
- Порог сомнительного сегмента — `0.6`; формат времени — `HH:MM:SS` от `floor`; `.txt` — UTF-8 без BOM, LF.
- Коэффициент плана: `cpu` → `job_timeout_sec × 10 / 6`, иначе `× 10`; `W = min(max_seconds, это)`; часть ≤ `W / 2`, части равные.
- Таймаут запроса: `--connect-timeout 10 --max-time (job_timeout_sec + 300)`; выбор адреса: `--connect-timeout 5 --max-time 15`.
- 503 — пауза `ASR_RETRY_WAIT` (60) и повтор, не больше `ASR_RETRIES` (5) раз.

## Review Focus

1. **Кириллица и пробелы в имени входа** («Встреча 1.mp4»): извлечение, имя `.txt`, публикация — тест в Task 5 (сценарий «файл целиком»).
2. **200 с не-JSON телом** (страница ошибки прокси): файл проваливается с причиной, а не даёт пустой `.txt` — тест в Task 3 («200 без segments»).
3. **Многомегабайтный ответ со словами**: разбор линейный, а не квадратичный — тест на 2000 сегментов в Task 4 (.sh) и Task 7 (паритет).
4. **destination = source**: `.txt` рядом с записью, повтор не пересчитывает — тест в Task 5.
5. **«Остановить» в GUI во время многоминутного запроса**: curl убит, временные файлы убраны — тест реального `Invoke-AsrCurl` с медленным поддельным curl в Task 6.

## Карта файлов

| Файл | Что меняется |
|---|---|
| `ffmpeg/asr_client.sh` | **новый**: клиент (.sh) — конфиг, адреса, пределы, план, curl, исходы, сборка текста (awk), файл и прогон |
| `ffmpeg/asr_client.ps1` | **новый**: двойник для PowerShell/GUI/EXE |
| `ffmpeg/FFmpeg_Converter_script.sh` | подключение модуля, ветка ASR, сводка, очистка |
| `ffmpeg/FFmpeg_Converter_script.ps1` | то же для PowerShell, отмена и прогресс GUI |
| `ffmpeg/FFmpeg_Converter_run_v19.{sh,ps1,cmd}` | чтение `[asr]`; `.cmd` — предупреждение и выход 1 |
| `ffmpeg/FFmpeg_Converter_run_win_v19.ps1` | группа «Распознавание речи (ASR)», передача в воркер, проверка окружения |
| `ffmpeg/config.ini.example` | секция `[asr]` (пустые адрес и ключ) |
| `ffmpeg/build_exe.ps1`, `tools/check_release.ps1` | модуль вклеивается в EXE и считается его исходником |
| `tests/mocks/curl`, `tests/mocks/ffmpeg` | `-F` → POST, `MOCK_CURL_EXIT`, `MOCK_CURL_FAIL_HOSTS`, `MOCK_CURL_CODE_SEQ_FILE`; `MOCK_FFMPEG_NO_AUDIO` |
| `tests/fixtures/asr/` | **новый**: ответы сервера и ожидаемые `.txt` — общие для .sh и .ps1 |
| `tests/ffmpeg/test_25…28_*.sh` | **новые**: клиент .sh, клиент .ps1, паритет, сквозной прогон |
| `tests/common/test_config_keys.sh`, `test_config_contract.sh`, `tests/config-key-contract.yaml` | ключи с учётом секции; контракт `[asr]` |
| `tests/ffmpeg/test_12/16/24`, `tests/common/test_build_strip.sh`, `test_guardrails.sh` | CMD, GUI, EXE, зависимости выпуска |
| `README.md`, `docs/constraints.md`, `tests/TESTING.md` | документация |

---

### Task 1: Ключи `[asr]` на трёх платформах, контракт и секционная проверка ключей

**Files:**
- Modify: `ffmpeg/config.ini.example` (конец файла)
- Modify: `ffmpeg/FFmpeg_Converter_run_v19.sh:95,190-197`
- Modify: `ffmpeg/FFmpeg_Converter_run_v19.ps1:82,164-171`
- Modify: `ffmpeg/FFmpeg_Converter_run_v19.cmd:53-60,198-201,282-291,345-349,352`
- Modify: `tests/common/test_config_keys.sh` (весь ffmpeg-блок и сверка шаблона)
- Modify: `tests/config-key-contract.yaml`, `tests/common/test_config_contract.sh:122-134`
- Modify: `tests/ffmpeg/test_12_cmd_run_parser.sh` (новый suite перед `rm -rf "$TMP_DIR"`)
- Modify (локально, НЕ коммитится): `ffmpeg/config.ini`

**Interfaces:**
- Produces: переменные `asr_enabled`, `asr_endpoint`, `asr_api_key`, `asr_api_key_command`, `asr_pinned_pubkey`, `asr_language`, `asr_diarize`, `asr_num_speakers` (строки) — во всех трёх run-файлах; умолчания `no`, ``, ``, ``, ``, `ru`, `yes`, ``.

- [ ] **Step 1: Тест — секционная проверка ключей (падает: `[asr]` нет)**

В `tests/common/test_config_keys.sh` заменить блок от `# ── ffmpeg: строгий трёхплатформенный паритет` до `done < <(keys_of "$FF/config.ini.example")` на:

```bash
# ── ffmpeg: строгий трёхплатформенный паритет ─────────────────────────────
# Ключи сверяются ВМЕСТЕ С СЕКЦИЕЙ. [asr] повторяет имена [remote] (enabled,
# endpoint, api_key, api_key_command), и сверка по одному имени зеленела бы при
# забытом чтении `[asr] enabled` — его «покрывало» чтение `[remote] enabled`.
# Пары «секция/ключ» собираются одним grep/awk на файл, как и раньше.
keys_sec_of() {
    awk '/^[[:space:]]*\[[^]]+\][[:space:]]*$/ { s = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", s); s = tolower(s); next }
         /^[[:space:]]*[a-z_]+[[:space:]]*=/ { k = $0; sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*=.*/, "", k); print s "/" k }' "$1"
}
_rs_files=(); _rs_lists=()
key_sec_is_read() {
    local file="$1" pair="$2" list="" i
    for i in "${!_rs_files[@]}"; do
        [ "${_rs_files[i]}" = "$file" ] && { list="${_rs_lists[i]}"; break; }
    done
    if [ -z "$list" ]; then
        case "$file" in
            *.sh)  list=$'\n'"$(grep -oE 'read_config[[:space:]]+"[a-z_]+"[[:space:]]+"[a-z_]+"' "$file" | awk -F'"' '{print $4 "/" $2}')"$'\n' ;;
            *.ps1) list=$'\n'"$(grep -oE 'Read-Config[[:space:]]+"[a-z_]+"[[:space:]]+"[a-z_]+"' "$file" | awk -F'"' '{print $4 "/" $2}')"$'\n' ;;
            *.cmd) list=$'\n'"$(awk 'match($0, /"!_section!"=="[a-z_]+"/) { s = substr($0, RSTART + 15, RLENGTH - 16) }
                                     match($0, /_key!"=="[a-z_]+"/) { print s "/" substr($0, RSTART + 9, RLENGTH - 10) }' "$file")"$'\n' ;;
        esac
        _rs_files+=("$file"); _rs_lists+=("$list")
    fi
    case "$list" in *$'\n'"$pair"$'\n'*) return 0 ;; esac
    return 1
}

suite "ffmpeg: каждый ключ config.ini читается в run.sh/run.cmd/run.ps1 (с секцией)"
FF="$PROJECT_DIR/ffmpeg"
assert_nonempty_keys "ffmpeg" "$FF/config.ini.example"
while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    for plat in FFmpeg_Converter_run_v19.sh FFmpeg_Converter_run_v19.cmd FFmpeg_Converter_run_v19.ps1; do
        if key_sec_is_read "$FF/$plat" "$pair"; then pass "ffmpeg '$pair' в $plat"
        else fail "ffmpeg '$pair' в $plat" "читается" "отсутствует"; fi
    done
done < <(keys_sec_of "$FF/config.ini.example")

# Негативная самопроверка: ключ, прочитанный в ДРУГОЙ секции, не засчитывается.
if key_sec_is_read "$FF/FFmpeg_Converter_run_v19.sh" "nosuch/enabled"; then
    fail "чтение [remote] enabled не засчитывается за [nosuch] enabled" "не засчитано" "засчитано"
else
    pass "чтение [remote] enabled не засчитывается за [nosuch] enabled"
fi
```

И в suite «config.ini.example совпадает по ключам с рабочим config.ini» заменить две строки `_only_live=…`/`_only_tmpl=…` на:

```bash
    _kf=keys_of; [ "$_pair" = "ffmpeg" ] && _kf=keys_sec_of
    _only_live="$(comm -23 <($_kf "$_live" | sort -u) <($_kf "$_tmpl" | sort -u) | tr '\n' ' ')"
    _only_tmpl="$(comm -13 <($_kf "$_live" | sort -u) <($_kf "$_tmpl" | sort -u) | tr '\n' ' ')"
```

В `tests/config-key-contract.yaml` после списка `sh_ps1_only_behavior` (после `      - on_failure`) добавить:

```yaml
    # Распознавание речи — только .sh/.ps1/GUI: в cmd.exe нет HTTP-клиента с
    # закреплённым ключом и разбора JSON. Ключи в .cmd читаются (их видно в
    # --print-config), а при enabled = yes .cmd предупреждает и выходит с кодом 1.
    asr_sh_ps1_only_behavior:
      - enabled
      - endpoint
      - api_key
      - api_key_command
      - pinned_pubkey
      - language
      - diarize
      - num_speakers
```

В `tests/common/test_config_contract.sh` перед финальным `summary` добавить:

```bash
# asr_sh_ps1_only_behavior: ключи [asr]. В .cmd они читаются в своей секции, а
# включённый режим даёт отказ с кодом 1 — молча конвертировать вместо расшифровки
# значило бы выдать пользователю не тот результат.
ff_asr_only=$(yaml_list_after '    asr_sh_ps1_only_behavior:')
assert_not_empty "контракт: список asr_sh_ps1_only_behavior (ffmpeg) не пуст" "$ff_asr_only"
while IFS= read -r k; do
    [ -z "$k" ] && continue
    assert_contains "asr-ключ '$k' читается в run_v19.cmd" "if /i \"!_key!\"==\"$k\" set \"asr_" "$_cmd_run_src"
done < <(printf '%s\n' "$ff_asr_only")
assert_contains "CMD отказывается при включённом распознавании" "Распознавание речи" "$_cmd_run_src"
```

В `tests/ffmpeg/test_12_cmd_run_parser.sh` перед `rm -rf "$TMP_DIR"` добавить:

```bash
# ══════════════════════════════════════════════════════════════
suite "CMD: ключи [asr] разбираются; enabled = yes — отказ без конвертации"
# ══════════════════════════════════════════════════════════════
# Распознавание речи в CMD недоступно. Молча конвертировать вместо расшифровки
# нельзя: пользователь получил бы видео там, где ждал текст, поэтому — код 1.
printf '[asr]\r\nenabled = no\r\nendpoint = https://asr.example:30010 http://asr2.example:30000\r\napi_key = asr-s3cr3t\r\npinned_pubkey = sha256//AAAA=\r\nlanguage = en\r\ndiarize = no\r\nnum_speakers = 4\r\n' > "$TMP_DIR/config.ini"
asr_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
get_asr() { printf '%s\n' "$asr_out" | grep "^$1=" | head -1; }
assert_eq "asr_enabled"       "asr_enabled=no"                                              "$(get_asr asr_enabled)"
assert_eq "asr_endpoint"      "asr_endpoint=https://asr.example:30010 http://asr2.example:30000" "$(get_asr asr_endpoint)"
assert_eq "asr_pinned_pubkey" "asr_pinned_pubkey=sha256//AAAA="                             "$(get_asr asr_pinned_pubkey)"
assert_eq "asr_language"      "asr_language=en"                                             "$(get_asr asr_language)"
assert_eq "asr_diarize"       "asr_diarize=no"                                              "$(get_asr asr_diarize)"
assert_eq "asr_num_speakers"  "asr_num_speakers=4"                                          "$(get_asr asr_num_speakers)"
assert_eq "ключ ASR под маской" "asr_api_key=***"                                           "$(get_asr asr_api_key)"
assert_not_contains "значение ключа ASR не печатается" "asr-s3cr3t" "$asr_out"

printf '[asr]\r\nendpoint = ${FF_T_ASR_UNSET}\r\n' > "$TMP_DIR/config.ini"
asr_env_out=$(cmd //c "$WIN_RUN --print-config" < /dev/null 2>&1 | tr -d '\r')
assert_not_contains "незаданная \${VAR} в [asr] не печатает WARN" "FF_T_ASR_UNSET" "$asr_env_out"

printf '[asr]\r\nenabled = yes\r\n' > "$TMP_DIR/config.ini"
asr_run_out=$(cmd //c "$WIN_RUN" < /dev/null 2>&1); asr_run_rc=$?
asr_run_out=$(printf '%s' "$asr_run_out" | tr -d '\r')
assert_eq "enabled = yes — код 1" "1" "$asr_run_rc"
assert_contains "отказ объяснён" "Распознавание речи" "$asr_run_out"
# В TMP_DIR нет script.cmd: дошёл бы до вызова — сказал бы «не найден».
assert_not_contains "конвертация не запускалась" "не найден FFmpeg_Converter_script.cmd" "$asr_run_out"
```

- [ ] **Step 2: Прогнать — падают**

Run: `bash tests/common/test_config_keys.sh; bash tests/common/test_config_contract.sh; bash tests/ffmpeg/test_12_cmd_run_parser.sh`
Expected: `test_config_keys` зелёный (ключей `[asr]` в шаблоне ещё нет) — это нормально; `test_config_contract` FAIL (`asr-ключ … читается`, «CMD отказывается»); `test_12` FAIL (`asr_enabled` пуст, код 0).

- [ ] **Step 3: Шаблон конфига**

В конец `ffmpeg/config.ini.example` добавить:

```ini

[asr]
# Распознавание речи вместо конвертации (yes/no): файлы из source НЕ перекодируются,
# а расшифровываются на сервере распознавания (WhisperX). В destination ложатся
# <имя>.txt — реплики с говорящими — и <имя>.asr.json — сырой ответ сервера.
# Работает в .sh, .ps1 и GUI; CMD-версия при yes предупреждает и выходит с кодом 1.
enabled = no
# Базовый адрес шлюза без пути: https://<хост>:<порт>. Несколько адресов — через
# пробел, берётся первый ответивший (у сервера разные адреса из разных сетей).
# Подстановка из окружения: endpoint = ${ASR_URL} (не задана -> пусто, без WARN)
endpoint =
# Bearer-ключ шлюза, или ${ASR_API_KEY}
api_key =
# Ключ со stdout команды; приоритет выше api_key. Пример: pass show asr/key
api_key_command =
# Закреплённый открытый ключ сервера: sha256//<base64>. Сертификат сервера
# самоподписанный, поэтому для https пин обязателен: проверка имени отключается
# (-k) ТОЛЬКО вместе с ним, а чужой сертификат обрывает соединение.
pinned_pubkey =
# Язык записи: ru или en (что принимает сервер). Автоопределения нет
language = ru
# Размечать говорящих (yes/no)
diarize = yes
# Число говорящих, если точно известно (1–50); пусто — сервер определит сам
num_speakers =
#
# Тонкая настройка переменными окружения: ASR_RETRY_WAIT (60) — пауза перед
# повтором при заполненной очереди сервера (HTTP 503), ASR_RETRIES (5) — сколько
# раз повторять.
```

- [ ] **Step 4: run_v19.sh**

В `read_config` строку
`[ -n "${!_vn:-}" ] || [ "$section" = "remote" ] || echo "WARN: переменная $_vn не задана" >&2`
заменить на
`[ -n "${!_vn:-}" ] || [ "$section" = "remote" ] || [ "$section" = "asr" ] || echo "WARN: переменная $_vn не задана" >&2`
и в комментарии над ней дописать: «То же для [asr]: ASR_URL/ASR_API_KEY — о пустом адресе говорит asr_preflight.»

После строки `remote_on_failure="$(read_config "on_failure" "remote" "abort")"` добавить:

```bash

# Распознавание речи. Адрес — списком через пробел; нормализация и проверка —
# в asr_client.sh (asr_split_endpoints / asr_validate_config), как у [remote].
asr_enabled="$(read_config "enabled" "asr" "no")"
asr_endpoint="$(read_config "endpoint" "asr" "")"
asr_api_key="$(read_config "api_key" "asr" "")"
asr_api_key_command="$(read_config "api_key_command" "asr" "")"
asr_pinned_pubkey="$(read_config "pinned_pubkey" "asr" "")"
asr_language="$(read_config "language" "asr" "ru")"
asr_diarize="$(read_config "diarize" "asr" "yes")"
asr_num_speakers="$(read_config "num_speakers" "asr" "")"
```

- [ ] **Step 5: run_v19.ps1**

Строку `$val = Expand-ConfigEnv $val ($curSection -eq 'remote')` заменить на
`$val = Expand-ConfigEnv $val ($curSection -eq 'remote' -or $curSection -eq 'asr')`
(в комментарии над ней дописать «и [asr]»). После `$remote_on_failure      = Read-Config "on_failure" "remote" "abort"` добавить:

```powershell

# Распознавание речи; нормализация адреса и проверка — в asr_client.ps1.
$asr_enabled         = Read-Config "enabled" "asr" "no"
$asr_endpoint        = Read-Config "endpoint" "asr" ""
$asr_api_key         = Read-Config "api_key" "asr" ""
$asr_api_key_command = Read-Config "api_key_command" "asr" ""
$asr_pinned_pubkey   = Read-Config "pinned_pubkey" "asr" ""
$asr_language        = Read-Config "language" "asr" "ru"
$asr_diarize         = Read-Config "diarize" "asr" "yes"
$asr_num_speakers    = Read-Config "num_speakers" "asr" ""
```

- [ ] **Step 6: run_v19.cmd (CRLF сохраняется — после правки `bash tests/common/test_encoding.sh`)**

После `set "remote_on_failure=abort"` добавить:

```
set "asr_enabled=no"
set "asr_endpoint="
set "asr_api_key="
set "asr_api_key_command="
set "asr_pinned_pubkey="
set "asr_language=ru"
set "asr_diarize=yes"
set "asr_num_speakers="
```

Строку `if /i not "!_section!"=="remote" if not defined !_ee_name! echo WARN: переменная !_ee_name! не задана 1>&2` заменить на
`if /i not "!_section!"=="remote" if /i not "!_section!"=="asr" if not defined !_ee_name! echo WARN: переменная !_ee_name! не задана 1>&2`
и в `::`-комментарии над ней дописать «То же для [asr].».

После блока `if /i "!_section!"=="remote" ( … )` в `:assign_var` добавить:

```
if /i "!_section!"=="asr" (
	if /i "!_key!"=="enabled" set "asr_enabled=!_val!"
	if /i "!_key!"=="endpoint" set "asr_endpoint=!_val!"
	if /i "!_key!"=="api_key" set "asr_api_key=!_val!"
	if /i "!_key!"=="api_key_command" set "asr_api_key_command=!_val!"
	if /i "!_key!"=="pinned_pubkey" set "asr_pinned_pubkey=!_val!"
	if /i "!_key!"=="language" set "asr_language=!_val!"
	if /i "!_key!"=="diarize" set "asr_diarize=!_val!"
	if /i "!_key!"=="num_speakers" set "asr_num_speakers=!_val!"
)
```

В `--print-config`: в список `for %%V in (… remote_on_failure)` дописать ` asr_enabled asr_endpoint asr_api_key_command asr_pinned_pubkey asr_language asr_diarize asr_num_speakers`, а после строки маски `remote_api_key` добавить
`	if defined asr_api_key (echo asr_api_key=***) else (echo asr_api_key=)`.

Перед строкой `:: start coding` добавить:

```
rem Распознавание речи есть только в .sh/.ps1/GUI. Молча конвертировать вместо
rem расшифровки нельзя: пользователь получил бы перекодированные файлы там, где
rem ждал текст. Поэтому отказ — явный и с ненулевым кодом, а не предупреждение.
if /i "%asr_enabled%"=="yes" (
	echo [ПРЕДУПРЕЖДЕНИЕ] Распознавание речи ^([asr] enabled^) в CMD-версии недоступно:
	echo [ПРЕДУПРЕЖДЕНИЕ] нет HTTP-клиента с закреплённым ключом сервера и разбора JSON.
	echo [ПРЕДУПРЕЖДЕНИЕ] Конвертация не запускается. Используйте .sh, .ps1 или GUI.
	exit /b 1
)
```

- [ ] **Step 7: Локальный `ffmpeg/config.ini` (gitignored, НЕ коммитить)**

Дописать ту же секцию `[asr]`, что в шаблоне, но со значениями из инструкции ASR, которую прислал владелец (файл вне репозитория): `endpoint` — оба адреса шлюза на порту HTTPS через пробел (сначала адрес второй сети, названный владельцем, затем адрес LAN, который отвечает с этой машины), `api_key` — ключ из инструкции, `pinned_pubkey` — `sha256//…` из инструкции; `enabled = no`. Проверить: `git status --short ffmpeg/config.ini` пуст (файл игнорируется).

- [ ] **Step 8: Прогнать — зелёные**

Run: `bash tests/common/test_config_keys.sh && bash tests/common/test_config_contract.sh && bash tests/ffmpeg/test_12_cmd_run_parser.sh && bash tests/ffmpeg/test_01_config_sh.sh && bash tests/ffmpeg/test_02_config_ps1.sh && bash tests/common/test_encoding.sh`
Expected: все `TESTS_RESULT … fail=0`.

- [ ] **Step 9: Commit**

```bash
git add ffmpeg/config.ini.example ffmpeg/FFmpeg_Converter_run_v19.sh ffmpeg/FFmpeg_Converter_run_v19.ps1 ffmpeg/FFmpeg_Converter_run_v19.cmd tests/common/test_config_keys.sh tests/common/test_config_contract.sh tests/config-key-contract.yaml tests/ffmpeg/test_12_cmd_run_parser.sh
git commit -F <файл с сообщением «asr: ключи [asr] на трёх платформах, CMD отказывается; ключи сверяются с секцией»>
```

---

### Task 2: Моки curl и ffmpeg для ASR

**Files:**
- Modify: `tests/mocks/curl`
- Modify: `tests/mocks/ffmpeg:55-72`

**Interfaces:**
- Produces: мок curl понимает `-F`/`--form` как POST (если нет `-X`), `MOCK_CURL_EXIT=<n>` (выйти с кодом), `MOCK_CURL_FAIL_HOSTS="h1 h2"` (exit 7 для этих хостов), `MOCK_CURL_CODE_SEQ_FILE=<файл>` (код ответа — первая строка файла, строка снимается); мок ffmpeg — `MOCK_FFMPEG_NO_AUDIO=1` (нет строки `Audio:`).

Эти изменения проверяются тестами Task 3 и Task 5 (первые их потребители); отдельного тест-файла у мока нет, как и у прежних его ручек.

- [ ] **Step 1: curl — шапка**

В шапку мока (после строки про `MOCK_CURL_ROUTES`) дописать:

```bash
#   MOCK_CURL_EXIT     — выйти с этим кодом (90 — чужой сертификат, 28 — таймаут)
#   MOCK_CURL_FAIL_HOSTS — хосты через пробел, для которых — exit 7 (выбор адреса)
#   MOCK_CURL_CODE_SEQ_FILE — файл с HTTP-кодами по строке: каждый вызов берёт
#                        первую строку как код ответа и снимает её (повторы при 503)
#   `-F`/`--form` без `-X` — это POST, как у настоящего curl.
```

- [ ] **Step 2: curl — метод по `-F`**

Перед циклом разбора аргументов добавить `METHOD_SET=0`; в `case "$PREV" in` заменить `-X) METHOD="$arg" ;;` на:

```bash
		-X) METHOD="$arg"; METHOD_SET=1 ;;
		-F|--form) [ "$METHOD_SET" = "1" ] || METHOD="POST" ;;
```

- [ ] **Step 3: curl — коды выхода, хосты, последовательность кодов**

Сразу после строки `[ "${MOCK_CURL_FAIL:-0}" = "1" ] && exit 7` добавить:

```bash
[ -n "${MOCK_CURL_EXIT:-}" ] && exit "$MOCK_CURL_EXIT"
_host="${URL#*://}"; _host="${_host%%[/:]*}"
case " ${MOCK_CURL_FAIL_HOSTS:-} " in
	*" $_host "*) [ -n "$_host" ] && exit 7 ;;
esac
SEQ_CODE=""
if [ -n "${MOCK_CURL_CODE_SEQ_FILE:-}" ] && [ -s "$MOCK_CURL_CODE_SEQ_FILE" ]; then
	_seq=()
	while IFS= read -r _l; do [ -n "$_l" ] && _seq+=("$_l"); done < "$MOCK_CURL_CODE_SEQ_FILE"
	SEQ_CODE="${_seq[0]:-}"
	if [ "${#_seq[@]}" -gt 1 ]; then
		printf '%s\n' "${_seq[@]:1}" > "$MOCK_CURL_CODE_SEQ_FILE"
	else
		: > "$MOCK_CURL_CODE_SEQ_FILE"
	fi
fi
```

И сразу перед блоком «Хвост собираем по формату -w» добавить:
`[ -n "$SEQ_CODE" ] && CODE="$SEQ_CODE"`

- [ ] **Step 4: ffmpeg — запись без звука**

В шапку: `#   MOCK_FFMPEG_NO_AUDIO=1     — в выводе -i нет строки Stream … Audio`. В блоке `-i` заменить последний аргумент `printf` (строку `"    Stream #0:1(und): Audio: …" >&2`) так:

```bash
    ASTREAM="    Stream #0:1(und): Audio: ${AUDIO_CODEC}, 48000 Hz, stereo, fltp, 192 kb/s"
    [ "${MOCK_FFMPEG_NO_AUDIO:-0}" = "1" ] && ASTREAM=""
    printf '%s\n' "ffmpeg version 6.0 (mock)" \
        "Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'input.mp4':" \
        "  Metadata:" \
        "    encoder         : Lavf58.76.100" \
        "  Duration: ${DURATION}, start: 0.000000, bitrate: ${BITRATE} kb/s" \
        "${VSTREAM}" ${ASTREAM:+"$ASTREAM"} >&2
```

- [ ] **Step 5: Регресс моков**

Run: `bash tests/ffmpeg/test_21_remote_client.sh && bash tests/ffmpeg/test_07_integration.sh`
Expected: `fail=0` (прежнее поведение моков не изменилось).

- [ ] **Step 6: Commit** — `tests/mocks/curl tests/mocks/ffmpeg`, сообщение «tests: моки curl и ffmpeg — POST по -F, коды выхода, хосты, последовательность кодов, запись без звука».

---

### Task 3: `asr_client.sh` — конфиг, адреса, пределы, план, curl, исходы

**Files:**
- Create: `ffmpeg/asr_client.sh`
- Create: `tests/fixtures/asr/limits.json`
- Create: `tests/ffmpeg/test_25_asr_client.sh`
- Modify: `tests/run_tests.sh` (`FFMPEG_TESTS`), `README.md` (таблица ffmpeg-тестов и счётчики файлов)

**Interfaces:**
- Consumes: `asr_*` из Task 1; моки Task 2.
- Produces (все результаты — глобальные переменные, функции не печатают в stdout):
  - `asr_escape_dq <s>` → `ASR_ESCAPED`
  - `asr_split_endpoints <строка>` → массив `ASR_ENDPOINTS`
  - `asr_tls_args <base>` → массив `ASR_TLS_ARGS`
  - `asr_json_field <json> <поле>` → `ASR_JSON_VAL`, rc 1 если нет
  - `asr_parse_limits <json>` → `ASR_LIM_MAX_SECONDS ASR_LIM_MAX_BYTES ASR_LIM_JOB_TIMEOUT ASR_LIM_DEVICE ASR_LIM_LANGUAGES ASR_LIM_DIARIZATION ASR_LIM_VER`, rc 1 если нет `max_seconds`/`job_timeout_sec`
  - `asr_plan_parts <D>` → `ASR_PLAN` («смещение:длина» через пробел), `ASR_PLAN_LEN`, `ASR_PLAN_WHOLE`
  - `asr_curl_args <base> <часть> <ответ>` → массив `ASR_CURL_ARGS`
  - `asr_extract_args <вход> <смещение> <длина> <частей> <выход>` → массив `ASR_FF_ARGS`
  - `asr_hms <сек>` → `ASR_HMS`; `asr_now` → `ASR_NOW` (`FFCONV_ASR_NOW` подменяет)
  - `asr_validate_config` → rc 0/1, сообщения в stderr
  - `asr_resolve_api_key` → rc; пишет `asr_api_key`
  - `asr_curl_run <каталог> <аргументы…>` → `ASR_CURL_RC ASR_HTTP_CODE ASR_CURL_ERR`
  - `asr_select_endpoint` → rc; `ASR_BASE` + пределы, иначе `ASR_STOP_REASON`
  - `asr_detail <файл>` → `ASR_DETAIL`
  - `asr_classify <rc> <code> <файл>` → `ASR_OUTCOME` (`ok|file|stop`), `ASR_REASON`
  - `asr_transcribe_part <часть> <ответ>` → `ASR_OUTCOME ASR_REASON` (файлы в `ASR_RUN_DIR`)
  - `asr_preflight` → rc; создаёт `ASR_RUN_DIR`, ставит `ASR_BASE`

- [ ] **Step 1: Фикстура пределов**

`tests/fixtures/asr/limits.json` (одна строка, без перевода строки в конце):

```json
{"max_seconds":3600.0,"max_bytes":524288000,"languages":["en","ru"],"models":["whisperx"],"asr_ver":"large-v3-turbo.cpu.int8.v1","device":"cpu","compute_type":"int8","diarization":true,"job_timeout_sec":1800.0,"max_queue":4,"cuda_broken":false,"reject_codes":{"413":"файл больше max_bytes","503":"очередь заполнена (4)"}}
```

- [ ] **Step 2: Тест — `tests/ffmpeg/test_25_asr_client.sh`**

```bash
#!/bin/bash
# Тест дот-сорсит настоящий модуль: переменные asr_*, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
# ============================================================
# test_25_asr_client.sh — клиент распознавания речи (.sh): ключи [asr] в
# run_v19.sh, адреса, пределы сервера, план частей, аргументы curl, исходы,
# выбор адреса и запрос через мок curl, сборка текста и JSON из общих фикстур
# tests/fixtures/asr (те же ожидаемые .txt сверяет test_26 для .ps1).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/asr_client.sh"

FIX="$TESTS_DIR/fixtures/asr"
MOCK_CURL="$TESTS_DIR/mocks/curl"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_XXXXXX")"
LIMITS="$(cat "$FIX/limits.json")"
TAB=$'\t'
_join() { local IFS='|'; JOINED="$*"; }

# ══════════════════════════════════════════════════════════════
suite "ключи [asr] читаются в run_v19.sh"
# ══════════════════════════════════════════════════════════════
cp "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.sh" "$WORK/run.sh"
printf '%s\n' '[asr]' 'enabled = yes' 'endpoint = ${FF_T_ASR_UNSET} https://b.example:30010/' \
    'api_key = k1' 'api_key_command = printf k2' 'pinned_pubkey = sha256//AAA=' \
    'language = en' 'diarize = no' 'num_speakers = 3' > "$WORK/config.ini"
_vals="$( unset FF_T_ASR_UNSET; source "$WORK/run.sh" 2>"$WORK/warn.txt"
    printf '%s|%s|%s|%s|%s|%s|%s|%s' "$asr_enabled" "$asr_endpoint" "$asr_api_key" \
        "$asr_api_key_command" "$asr_pinned_pubkey" "$asr_language" "$asr_diarize" "$asr_num_speakers" )"
assert_eq "все восемь ключей разобраны" \
    "yes| https://b.example:30010/|k1|printf k2|sha256//AAA=|en|no|3" "$_vals"
assert_not_contains "незаданная \${VAR} в [asr] не печатает WARN" "FF_T_ASR_UNSET" "$(cat "$WORK/warn.txt")"
printf '[asr]\n' > "$WORK/config.ini"
_vals="$( source "$WORK/run.sh" 2>/dev/null; printf '%s|%s|%s' "$asr_enabled" "$asr_language" "$asr_diarize" )"
assert_eq "умолчания" "no|ru|yes" "$_vals"

# ══════════════════════════════════════════════════════════════
suite "адреса: список через пробел, без хвостовых слэшей"
# ══════════════════════════════════════════════════════════════
asr_split_endpoints "  https://a.example:30010/  http://b.example:30000//  "
_join "${ASR_ENDPOINTS[@]}"
assert_eq "два адреса, слэши сняты" "https://a.example:30010|http://b.example:30000" "$JOINED"
asr_split_endpoints ""
assert_eq "пустая строка — ни одного адреса" "0" "${#ASR_ENDPOINTS[@]}"

# ══════════════════════════════════════════════════════════════
suite "пределы сервера из /speech/limits"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"; _rc=$?
assert_eq "разобраны" "0" "$_rc"
_join "$ASR_LIM_MAX_SECONDS" "$ASR_LIM_MAX_BYTES" "$ASR_LIM_JOB_TIMEOUT" "$ASR_LIM_DEVICE" "$ASR_LIM_DIARIZATION" "$ASR_LIM_VER"
assert_eq "числа — целой частью, строки без кавычек" \
    "3600|524288000|1800|cpu|true|large-v3-turbo.cpu.int8.v1" "$JOINED"
assert_eq "языки списком" "en ru" "$ASR_LIM_LANGUAGES"
asr_parse_limits '<html>502 Bad Gateway</html>'; _rc=$?
assert_eq "не пределы — отказ" "1" "$_rc"

# ══════════════════════════════════════════════════════════════
suite "план частей (спека §6)"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"
for _c in "2999:0:2999" "3000:0:3000" "3001:0:1001 1001:1001 2002:999" \
          "5400:0:1350 1350:1350 2700:1350 4050:1350"; do
    asr_plan_parts "${_c%%:*}"
    assert_eq "cpu, ${_c%%:*} с" "${_c#*:}" "$ASR_PLAN"
done
asr_plan_parts 3001
assert_eq "длина части при нарезке" "1001" "$ASR_PLAN_LEN"
assert_eq "предел «целиком» на cpu" "3000" "$ASR_PLAN_WHOLE"
ASR_LIM_DEVICE="cuda"; ASR_LIM_MAX_SECONDS=7200
asr_plan_parts 7200; assert_eq "cuda, 7200 с — целиком" "0:7200" "$ASR_PLAN"
asr_plan_parts 7201; assert_eq "cuda, 7201 с — три части" "0:2401 2401:2401 4802:2399" "$ASR_PLAN"

# ══════════════════════════════════════════════════════════════
suite "аргументы запроса распознавания"
# ══════════════════════════════════════════════════════════════
asr_parse_limits "$LIMITS"
asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""; asr_pinned_pubkey=""
asr_curl_args "https://h.example:30010" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_eq "https без пина — обычная проверка TLS" \
    "-sS|--connect-timeout|10|--max-time|2100|-F|file=@part_000.flac;type=audio/flac|-F|model=whisperx|-F|language=ru|-F|diarize=true|-o|resp_000.json|-w|%{http_code}|https://h.example:30010/speech/transcriptions" \
    "$JOINED"
asr_pinned_pubkey="sha256//AAA="
asr_curl_args "https://h.example:30010" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_contains "https с пином — -k только вместе с --pinnedpubkey" "--max-time|2100|-k|--pinnedpubkey|sha256//AAA=|-F" "$JOINED"
asr_curl_args "http://h.example:30000" "part_000.flac" "resp_000.json"
_join "${ASR_CURL_ARGS[@]}"
assert_not_contains "http — без -k" "|-k|" "$JOINED"
asr_diarize="no"; asr_num_speakers="4"
asr_curl_args "http://h.example:30000" "part_001.flac" "resp_001.json"
_join "${ASR_CURL_ARGS[@]}"
assert_contains "diarize = no → false" "-F|diarize=false" "$JOINED"
assert_contains "num_speakers — только когда задан" "-F|num_speakers=4|-o" "$JOINED"
asr_diarize="yes"; asr_num_speakers=""; asr_pinned_pubkey=""
asr_extract_args "/in/a b.mp4" 1001 999 3 "part_001.flac"
_join "${ASR_FF_ARGS[@]}"
assert_eq "извлечение части" "-nostdin|-v|error|-y|-ss|1001|-t|999|-i|/in/a b.mp4|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_001.flac" "$JOINED"
asr_extract_args "/in/a.mp4" 0 61 1 "part_000.flac"
_join "${ASR_FF_ARGS[@]}"
assert_not_contains "целиком — без -ss/-t" "-ss" "$JOINED"

# ══════════════════════════════════════════════════════════════
suite "исходы: файл провален или прогон остановлен"
# ══════════════════════════════════════════════════════════════
printf '{"detail":"язык вне languages"}' > "$WORK/detail.json"
_cl() { asr_classify "$@"; CL="$ASR_OUTCOME|$ASR_REASON"; }
ASR_CURL_ERR=""
_cl 0 200 "";                 assert_eq "200 — успех" "ok|" "$CL"
_cl 0 400 "$WORK/detail.json"; assert_eq "400 — файл, detail дословно" "file|HTTP 400: язык вне languages" "$CL"
_cl 0 413 "";                 assert_eq "413 — файл" "file|HTTP 413" "$CL"
_cl 0 422 "";                 assert_eq "422 — файл" "file|HTTP 422" "$CL"
_cl 0 401 "";                 assert_eq "401 — прогон" "stop|ключ не принят (HTTP 401)" "$CL"
_cl 0 403 "";                 assert_eq "403 — прогон" "stop|ключ не принят (HTTP 403)" "$CL"
_cl 0 500 "";                 assert_eq "500 — прогон" "stop|HTTP 500" "$CL"
_cl 0 504 "";                 assert_contains "504 — прогон, задача ещё идёт" "stop|сервер не уложился" "$CL"
_cl 90 000 "";                assert_eq "curl 90 — прогон" "stop|сертификат сервера не совпал с закреплённым ключом (curl 90)" "$CL"
_cl 28 000 "";                assert_contains "curl 28 — прогон" "stop|истёк таймаут" "$CL"
_cl 26 000 "";                assert_contains "curl 26 — файл" "file|curl не смог прочитать" "$CL"
ASR_CURL_ERR="Failed to connect"
_cl 7 000 "";                 assert_eq "прочие коды curl — прогон с причиной" "stop|сетевая ошибка (curl 7: Failed to connect)" "$CL"
ASR_CURL_ERR=""

# ══════════════════════════════════════════════════════════════
suite "выбор адреса: первый ответивший; ключ — только в конфиге curl"
# ══════════════════════════════════════════════════════════════
export CURL_BIN="$MOCK_CURL" MOCK_CURL_LOG="$WORK/curl.log"
ASR_RUN_DIR="$WORK/run"; mkdir -p "$ASR_RUN_DIR"
asr_api_key="sekret-key-1"; asr_pinned_pubkey=""
asr_endpoint="https://a.example:30010 https://b.example:30010"
export MOCK_CURL_ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}"
export MOCK_CURL_FAIL_HOSTS="a.example"
: > "$MOCK_CURL_LOG"
asr_select_endpoint; _rc=$?
assert_eq "выбор удался" "0" "$_rc"
assert_eq "недоступный первый пропущен" "https://b.example:30010" "$ASR_BASE"
assert_eq "пределы сохранены" "1800" "$ASR_LIM_JOB_TIMEOUT"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "ключ ушёл заголовком через конфиг" 'header = "Authorization: Bearer sekret-key-1"' "$_log"
assert_empty "ключа нет в argv" "$(grep -F -- '--config' "$MOCK_CURL_LOG" | grep -F 'sekret-key-1')"
assert_contains "первый адрес опрошен" "https://a.example:30010/speech/limits" "$_log"

export MOCK_CURL_FAIL_HOSTS="a.example b.example"
asr_select_endpoint; _rc=$?
assert_eq "никто не ответил — отказ" "1" "$_rc"
assert_contains "в причине каждый адрес" "https://a.example:30010 → curl 7" "$ASR_STOP_REASON"
assert_contains "и второй" "https://b.example:30010 → curl 7" "$ASR_STOP_REASON"
unset MOCK_CURL_FAIL_HOSTS

export MOCK_CURL_ROUTES="GET /speech/limits${TAB}401${TAB}{\"detail\":\"нет ключа\"}"
: > "$MOCK_CURL_LOG"
asr_select_endpoint; _rc=$?
assert_eq "401 — отказ сразу" "1" "$_rc"
assert_contains "причина названа" "ключ не принят (HTTP 401)" "$ASR_STOP_REASON"
assert_not_contains "второй адрес не опрашивался" "b.example" "$(cat "$MOCK_CURL_LOG")"

export MOCK_CURL_EXIT=90
asr_select_endpoint; _rc=$?
assert_eq "чужой сертификат — отказ сразу" "1" "$_rc"
assert_contains "причина — сертификат" "не совпал с закреплённым ключом" "$ASR_STOP_REASON"
unset MOCK_CURL_EXIT

# ══════════════════════════════════════════════════════════════
suite "запрос части: файл относительным именем, повтор при 503, тело без segments"
# ══════════════════════════════════════════════════════════════
asr_endpoint="https://b.example:30010"; asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""
export MOCK_CURL_ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}"
asr_select_endpoint
printf 'FLAC' > "$ASR_RUN_DIR/part_000.flac"
_basic="$(cat "$FIX/basic.json")"
export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}200${TAB}${_basic}"
: > "$MOCK_CURL_LOG"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "200 — успех" "ok" "$ASR_OUTCOME"
assert_eq "ответ сохранён как есть" "$_basic" "$(cat "$ASR_RUN_DIR/resp_000.json")"
_log="$(cat "$MOCK_CURL_LOG")"
assert_contains "часть — относительным именем (curl из Git Bash не открывает /tmp/…)" "file=@part_000.flac;type=audio/flac" "$_log"
assert_contains "модель" "model=whisperx" "$_log"
assert_contains "язык" "language=ru" "$_log"
assert_not_contains "num_speakers не задан — не отправлен" "num_speakers" "$_log"

printf '503\n503\n200\n' > "$WORK/seq"
export MOCK_CURL_CODE_SEQ_FILE="$WORK/seq" ASR_RETRY_WAIT=0
: > "$MOCK_CURL_LOG"
asr_transcribe_part "part_000.flac" "resp_000.json" 2>"$WORK/err.txt"
assert_eq "после двух 503 — успех" "ok" "$ASR_OUTCOME"
assert_eq "три попытки" "3" "$(grep -c 'speech/transcriptions' "$MOCK_CURL_LOG")"
assert_contains "о повторе сказано" "HTTP 503" "$(cat "$WORK/err.txt")"
printf '503\n503\n503\n503\n' > "$WORK/seq"
: > "$MOCK_CURL_LOG"
ASR_RETRIES=2 asr_transcribe_part "part_000.flac" "resp_000.json" 2>/dev/null
assert_eq "очередь полна и после повторов — прогон" "stop" "$ASR_OUTCOME"
assert_contains "причина — 503" "HTTP 503" "$ASR_REASON"
assert_eq "одна попытка и два повтора" "3" "$(grep -c 'speech/transcriptions' "$MOCK_CURL_LOG")"
unset MOCK_CURL_CODE_SEQ_FILE

export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}200${TAB}<html>gateway</html>"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "200 без segments — файл провален" "file|сервер ответил 200, но без поля segments" "$ASR_OUTCOME|$ASR_REASON"
export MOCK_CURL_ROUTES="POST /speech/transcriptions${TAB}400${TAB}{\"detail\":\"ffprobe не прочитал аудио\"}"
asr_transcribe_part "part_000.flac" "resp_000.json"
assert_eq "400 — файл, detail дословно" "file|HTTP 400: ffprobe не прочитал аудио" "$ASR_OUTCOME|$ASR_REASON"
unset MOCK_CURL_ROUTES

# ══════════════════════════════════════════════════════════════
suite "проверка [asr] до запуска"
# ══════════════════════════════════════════════════════════════
_vc() { asr_endpoint="$1"; asr_language="$2"; asr_diarize="$3"; asr_num_speakers="$4"
        asr_validate_config 2>"$WORK/vc.txt"; VC=$?; VC_ERR="$(cat "$WORK/vc.txt")"; }
_vc "https://a:1" ru yes "";   assert_eq "верная конфигурация" "0" "$VC"
_vc "" ru yes "";              assert_eq "пустой адрес" "1" "$VC"
assert_contains "подсказка про переменную" 'ASR_URL' "$VC_ERR"
_vc "ftp://a" ru yes "";       assert_eq "чужая схема" "1" "$VC"
_vc "https://a:1" "" yes "";   assert_eq "пустой язык" "1" "$VC"
_vc "https://a:1" ru maybe ""; assert_eq "diarize не yes/no" "1" "$VC"
for _n in 0 51 abc -1; do _vc "https://a:1" ru yes "$_n"; assert_eq "num_speakers=$_n отвергнут" "1" "$VC"; done
for _n in 1 50; do _vc "https://a:1" ru yes "$_n"; assert_eq "num_speakers=$_n принят" "0" "$VC"; done

# ══════════════════════════════════════════════════════════════
suite "ключ из api_key_command"
# ══════════════════════════════════════════════════════════════
ASR_API_KEY_RESOLVED="no"; asr_api_key=""; asr_api_key_command='printf "  cmd-key  \n"'
asr_resolve_api_key; _rc=$?
assert_eq "команда отработала" "0" "$_rc"
assert_eq "первая строка без пробелов" "cmd-key" "$asr_api_key"
ASR_API_KEY_RESOLVED="no"; asr_api_key_command='false'
asr_resolve_api_key 2>/dev/null; _rc=$?
assert_eq "упавшая команда — отказ" "1" "$_rc"
asr_api_key_command=""

rm -rf "$WORK"
summary
```

Регистрация: в `tests/run_tests.sh` после `"$TESTS_DIR/ffmpeg/test_24_gui_worker_runspace.sh"` добавить `"$TESTS_DIR/ffmpeg/test_25_asr_client.sh"`; в `README.md` — строку таблицы ffmpeg-тестов `| \`test_25_asr_client\` | Распознавание речи: клиент (.sh) — ключи, адреса, пределы, план частей, curl, исходы, сборка текста |` и счётчики файлов ffmpeg 24 → 25 (структура, раздел «Запуск тестов», заголовок таблицы).

Фикстура `basic.json` нужна уже здесь — создать её по Task 4 Step 1 (одна строка без перевода строки).

- [ ] **Step 3: Прогнать — падает**

Run: `bash tests/ffmpeg/test_25_asr_client.sh`
Expected: ошибка `source …/asr_client.sh: No such file or directory`, затем FAIL на первых ассертах.

- [ ] **Step 4: Реализация — `ffmpeg/asr_client.sh` (первая половина)**

```bash
#!/bin/bash
# Модуль подключается через `source` из converter-скрипта и работает на его
# переменных (asr_*, ffmpeg, folder_*, log_msg, put_result…): shellcheck их не
# видит и объявляет неопределёнными (SC2154) или неиспользуемыми (SC2034).
# shellcheck disable=SC2034,SC2154
# ============================================================
# Распознавание речи (ASR) — клиент сервера WhisperX (Bash)
#
# Подключается из FFmpeg_Converter_script.sh. Ничего не запускает сам: только
# функции, поэтому модуль дот-сорсится в тест без сети и без побочных эффектов.
# Результаты функций — в глобальных ASR_*, а не в stdout: функция внутри $( )
# выполнилась бы в подоболочке, и всё, что она выставила, потерялось бы (см.
# шапку remote_client.sh). Двойник — asr_client.ps1; равенство плана частей,
# аргументов curl, исходов и текста сверяет test_27_asr_parity.sh.
#
# Спека: docs/superpowers/specs/2026-10-02-ffmpeg-asr-design.md
# ============================================================

# --- Экранирование значения для curl-конфига ---
# Внутри кавычек curl-конфига экранируются ровно \ и " (curl.1, --config). Проход
# посимвольный по той же причине, что в remote_escape_dq: подстановка шаблоном
# ломается на bash 3.2. Своя копия, а не вызов из remote_client.sh: модуль
# подключается и проверяется без удалённого бэкенда.
asr_escape_dq() {
	local s="$1" out='' i c
	for (( i = 0; i < ${#s}; i++ )); do
		c=${s:i:1}
		case $c in
			'\') out="$out\\\\" ;;
			'"') out="$out\\\"" ;;
			*)   out="$out$c" ;;
		esac
	done
	ASR_ESCAPED="$out"
}

# --- Адреса: список через пробел, без хвостовых слэшей ---
# У сервера разные адреса из разных сетей; берётся первый ответивший. read -a,
# а не `for w in $1`: голое раскрытие глоббит `*` и `?` по файлам каталога.
asr_split_endpoints() {
	local -a words
	local u i
	ASR_ENDPOINTS=()
	read -r -a words <<< "$1"
	for (( i = 0; i < ${#words[@]}; i++ )); do
		u="${words[i]}"
		while [ -n "$u" ] && [ "${u: -1}" = "/" ]; do u="${u%/}"; done
		[ -n "$u" ] && ASR_ENDPOINTS+=("$u")
	done
	return 0
}

# --- TLS: -k только вместе с пином ---
# Сертификат сервера самоподписанный и выписан на другое имя: обычная проверка не
# пройдёт. Пин проверяет, что на том конце именно наш сервер; -k без пина не
# ставится никогда — это было бы «доверять кому угодно».
asr_tls_args() {
	ASR_TLS_ARGS=()
	case "$1" in
		https://*) [ -n "${asr_pinned_pubkey:-}" ] && ASR_TLS_ARGS=(-k --pinnedpubkey "$asr_pinned_pubkey") ;;
	esac
	return 0
}

# --- Поле плоского JSON (ответ /speech/limits) ---
# Ответ плоский, кроме reject_codes, а имена нужных полей в нём уникальны —
# поэтому регулярное выражение, а не разбор целиком. Кавычки строки снимаются.
asr_json_field() {
	local re='"'"$2"'"[[:space:]]*:[[:space:]]*("[^"]*"|\[[^]]*\]|[^,}[:space:]]+)'
	ASR_JSON_VAL=""
	[[ $1 =~ $re ]] || return 1
	ASR_JSON_VAL="${BASH_REMATCH[1]}"
	case "$ASR_JSON_VAL" in
		\"*\") ASR_JSON_VAL="${ASR_JSON_VAL#\"}"; ASR_JSON_VAL="${ASR_JSON_VAL%\"}" ;;
	esac
	return 0
}

# --- Пределы сервера ---
# Опираемся на живой ответ: при переключении сервера на карту max_seconds и
# скорость меняются, и зашитые числа завели бы план частей не туда.
asr_parse_limits() {
	local v
	ASR_LIM_MAX_SECONDS=""; ASR_LIM_MAX_BYTES=""; ASR_LIM_JOB_TIMEOUT=""
	ASR_LIM_DEVICE=""; ASR_LIM_LANGUAGES=""; ASR_LIM_DIARIZATION=""; ASR_LIM_VER=""
	asr_json_field "$1" max_seconds && ASR_LIM_MAX_SECONDS="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" max_bytes && ASR_LIM_MAX_BYTES="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" job_timeout_sec && ASR_LIM_JOB_TIMEOUT="${ASR_JSON_VAL%%.*}"
	asr_json_field "$1" device && ASR_LIM_DEVICE="$ASR_JSON_VAL"
	asr_json_field "$1" diarization && ASR_LIM_DIARIZATION="$ASR_JSON_VAL"
	asr_json_field "$1" asr_ver && ASR_LIM_VER="$ASR_JSON_VAL"
	if asr_json_field "$1" languages; then
		v="${ASR_JSON_VAL#[}"; v="${v%]}"; v="${v//\"/}"; v="${v//,/ }"
		read -r -a _asr_langs <<< "$v"
		ASR_LIM_LANGUAGES="${_asr_langs[*]}"
	fi
	case "$ASR_LIM_MAX_SECONDS" in ''|*[!0-9]*) return 1 ;; esac
	case "$ASR_LIM_JOB_TIMEOUT" in ''|*[!0-9]*) return 1 ;; esac
	return 0
}

# --- План частей (спека §6) ---
# $1 — длительность в целых секундах (уже с запасом вверх). Предел «целиком» W —
# что сервер успеет за свой job_timeout_sec: на процессоре ~0.5 с на секунду
# записи (берём 0.6 с запасом), на карте в разы быстрее (0.1). Коэффициенты — в
# целых: ×10/6 и ×10. Длиннее W — равные части не длиннее W/2: равные, чтобы не
# было трёхсекундного хвоста, который сервер распознаёт хуже всего.
asr_plan_parts() {
	local d="$1" w lim p n l i off len
	if [ "$ASR_LIM_DEVICE" = "cpu" ]; then lim=$(( ASR_LIM_JOB_TIMEOUT * 10 / 6 )); else lim=$(( ASR_LIM_JOB_TIMEOUT * 10 )); fi
	w="$ASR_LIM_MAX_SECONDS"
	[ "$lim" -lt "$w" ] && w="$lim"
	ASR_PLAN_WHOLE="$w"
	if [ "$d" -le "$w" ]; then
		ASR_PLAN="0:$d"; ASR_PLAN_LEN="$d"
		return 0
	fi
	p=$(( w / 2 )); n=$(( (d + p - 1) / p )); l=$(( (d + n - 1) / n ))
	ASR_PLAN=""; ASR_PLAN_LEN="$l"
	for (( i = 0; i < n; i++ )); do
		off=$(( i * l )); len=$(( d - off ))
		[ "$len" -gt "$l" ] && len="$l"
		[ "$len" -gt 0 ] || break
		ASR_PLAN="${ASR_PLAN:+$ASR_PLAN }$off:$len"
	done
	return 0
}

# --- Аргументы запроса распознавания ---
# Ключа здесь нет: он уходит конфигом на stdin (asr_curl_run). Часть и ответ —
# ОТНОСИТЕЛЬНЫМИ именами: curl запускается из ASR_RUN_DIR. curl из Git Bash —
# нативная программа, и путь `file=@/tmp/…` MSYS в Windows-путь не переводит —
# curl отвечает кодом 26 (проверено 2026-10-02). Порядок аргументов — контракт
# с Get-AsrCurlArgs в .ps1 (test_27).
asr_curl_args() {
	local base="$1" part="$2" out="$3" diar="false"
	[ "${asr_diarize:-yes}" = "yes" ] && diar="true"
	ASR_CURL_ARGS=(-sS --connect-timeout 10 --max-time "$(( ASR_LIM_JOB_TIMEOUT + 300 ))")
	asr_tls_args "$base"
	[ ${#ASR_TLS_ARGS[@]} -gt 0 ] && ASR_CURL_ARGS+=("${ASR_TLS_ARGS[@]}")
	ASR_CURL_ARGS+=(-F "file=@${part};type=audio/flac" -F "model=whisperx"
		-F "language=${asr_language}" -F "diarize=${diar}")
	[ -n "${asr_num_speakers:-}" ] && ASR_CURL_ARGS+=(-F "num_speakers=${asr_num_speakers}")
	ASR_CURL_ARGS+=(-o "$out" -w '%{http_code}' "${base}/speech/transcriptions")
	return 0
}

# --- Извлечение звука части ---
# Первая звуковая дорожка → FLAC, моно, 16 кГц: кодер встроен в любую сборку
# ffmpeg, без потерь, час ≈ 65 МБ при пределе сервера 500 МБ. -ss/-t — только при
# нескольких частях и на входной стороне: перекодирование, смещение точное.
asr_extract_args() {
	ASR_FF_ARGS=(-nostdin -v error -y)
	[ "$4" -gt 1 ] && ASR_FF_ARGS+=(-ss "$2" -t "$3")
	ASR_FF_ARGS+=(-i "$1" -map 0:a:0 -vn -ac 1 -ar 16000 -c:a flac "$5")
	return 0
}

asr_hms() {
	local s="${1%%.*}"
	printf -v ASR_HMS '%02d:%02d:%02d' $(( s / 3600 )) $(( s % 3600 / 60 )) $(( s % 60 ))
}

# Дата в шапке расшифровки. FFCONV_ASR_NOW подменяет её в тестах: реального
# времени тесты не читают. printf %(…)T — bash 4.2+, на 3.2 (macOS) — date.
asr_now() {
	ASR_NOW="${FFCONV_ASR_NOW:-}"
	[ -n "$ASR_NOW" ] && return 0
	printf -v ASR_NOW '%(%Y-%m-%d %H:%M)T' -1 2>/dev/null || ASR_NOW="$(date '+%Y-%m-%d %H:%M')"
}

# --- Проверка [asr] до первого файла ---
asr_validate_config() {
	local bad=0 i
	asr_split_endpoints "${asr_endpoint:-}"
	if [ ${#ASR_ENDPOINTS[@]} -eq 0 ]; then
		echo "[ОШИБКА] [asr] endpoint пуст: задайте адрес сервера распознавания (или \${ASR_URL})." >&2
		bad=1
	fi
	for (( i = 0; i < ${#ASR_ENDPOINTS[@]}; i++ )); do
		case "${ASR_ENDPOINTS[i]}" in
			http://?*|https://?*) ;;
			*) echo "[ОШИБКА] [asr] endpoint: '${ASR_ENDPOINTS[i]}' — адрес должен начинаться с http:// или https://." >&2
			   bad=1 ;;
		esac
	done
	if [ -z "${asr_language:-}" ]; then
		echo "[ОШИБКА] [asr] language пуст: укажите язык записи (ru, en)." >&2
		bad=1
	fi
	case "${asr_diarize:-yes}" in
		yes|no) ;;
		*) echo "[ОШИБКА] [asr] diarize = '$asr_diarize': ожидается yes или no." >&2; bad=1 ;;
	esac
	if [ -n "${asr_num_speakers:-}" ]; then
		local n_ok=0
		case "$asr_num_speakers" in
			*[!0-9]*) ;;
			*) [ "$(( 10#$asr_num_speakers ))" -ge 1 ] && [ "$(( 10#$asr_num_speakers ))" -le 50 ] && n_ok=1 ;;
		esac
		if [ "$n_ok" = "0" ]; then
			echo "[ОШИБКА] [asr] num_speakers = '$asr_num_speakers': целое от 1 до 50 или пусто." >&2
			bad=1
		fi
	fi
	return $bad
}

# --- Ключ из api_key_command (приоритет выше api_key) ---
# Выполняется один раз за прогон: менеджер паролей может спросить пароль.
ASR_API_KEY_RESOLVED="no"
asr_resolve_api_key() {
	[ -n "${asr_api_key_command:-}" ] || return 0
	[ "$ASR_API_KEY_RESOLVED" = "yes" ] && return 0
	local out
	out="$(eval "$asr_api_key_command" 2>/dev/null)" || {
		echo "[ОШИБКА] [asr] api_key_command завершилась с ошибкой — ключ не получен." >&2
		return 1
	}
	out="${out%%$'\n'*}"
	out="${out#"${out%%[![:space:]]*}"}"
	out="${out%"${out##*[![:space:]]}"}"
	if [ -z "$out" ]; then
		echo "[ОШИБКА] [asr] api_key_command ничего не напечатала — ключ не получен." >&2
		return 1
	fi
	asr_api_key="$out"
	ASR_API_KEY_RESOLVED="yes"
	return 0
}

# --- Вызов curl из каталога прогона ---
# Ключ — конфигом на stdin (`--config -`), а не аргументом: argv процесса читает
# любой локальный пользователь, а запрос живёт до получаса. Код ответа — из
# `-w %{http_code}` (тело уходит в файл через -o); "000" — ответа не было.
asr_curl_run() {
	local dir="$1" out
	shift
	asr_escape_dq "${asr_api_key:-}"
	out="$(cd "$dir" && printf 'header = "Authorization: Bearer %s"\n' "$ASR_ESCAPED" \
		| "${CURL_BIN:-curl}" --config - "$@" 2>curl.err)"
	ASR_CURL_RC=$?
	ASR_HTTP_CODE="$out"
	case "$ASR_HTTP_CODE" in ''|*[!0-9]*) ASR_HTTP_CODE="000" ;; esac
	ASR_CURL_ERR=""
	[ -s "$dir/curl.err" ] && IFS= read -r ASR_CURL_ERR < "$dir/curl.err"
	rm -f "$dir/curl.err"
	return 0
}

# --- Выбор адреса: первый, ответивший 200 на GET /speech/limits ---
# 401/403 и чужой сертификат (curl 90) — остановка сразу: ключ общий для всех
# адресов, а чужой сертификат — повод остановиться, а не искать дальше.
asr_select_endpoint() {
	local u tried="" i body hint
	ASR_BASE=""; ASR_STOP_REASON=""
	asr_split_endpoints "${asr_endpoint:-}"
	for (( i = 0; i < ${#ASR_ENDPOINTS[@]}; i++ )); do
		u="${ASR_ENDPOINTS[i]}"
		asr_tls_args "$u"
		rm -f "$ASR_RUN_DIR/limits.json"
		asr_curl_run "$ASR_RUN_DIR" -sS --connect-timeout 5 --max-time 15 \
			${ASR_TLS_ARGS[@]+"${ASR_TLS_ARGS[@]}"} -o limits.json -w '%{http_code}' "$u/speech/limits"
		if [ "$ASR_CURL_RC" = "90" ]; then
			ASR_STOP_REASON="сертификат $u не совпал с закреплённым ключом [asr] pinned_pubkey (curl 90) — соединение оборвано"
			return 1
		fi
		case "$ASR_HTTP_CODE" in
			200)
				body=""
				[ -f "$ASR_RUN_DIR/limits.json" ] && IFS= read -r -d '' body < "$ASR_RUN_DIR/limits.json"
				if asr_parse_limits "$body"; then
					ASR_BASE="$u"
					return 0
				fi
				tried="$tried; $u → 200, но ответ не похож на /speech/limits" ;;
			401|403)
				ASR_STOP_REASON="$u: ключ не принят (HTTP $ASR_HTTP_CODE) — проверьте [asr] api_key"
				return 1 ;;
			*)
				if [ "$ASR_CURL_RC" != "0" ]; then
					hint=""
					case "$ASR_CURL_RC" in
						35|60) [ -z "${asr_pinned_pubkey:-}" ] && hint=" — для самоподписанного сертификата задайте [asr] pinned_pubkey" ;;
					esac
					tried="$tried; $u → curl $ASR_CURL_RC${ASR_CURL_ERR:+ ($ASR_CURL_ERR)}$hint"
				else
					tried="$tried; $u → HTTP $ASR_HTTP_CODE"
				fi ;;
		esac
	done
	ASR_STOP_REASON="сервер распознавания недоступен: ${tried#; }"
	return 1
}

# --- Текст ошибки сервера: {"detail": "..."} — дословно ---
asr_detail() {
	local body="" re='"detail"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
	ASR_DETAIL=""
	[ -n "${1:-}" ] && [ -s "$1" ] || return 0
	IFS= read -r -d '' body < "$1"
	[[ $body =~ $re ]] && ASR_DETAIL="${BASH_REMATCH[1]}"
	return 0
}

# --- Исход запроса (спека §5.3) ---
# file — причина в самом файле (прогон продолжается); stop — причина общая для
# всех файлов: сервер, сеть, ключ, сертификат (прогон останавливается).
# Тексты причин — контракт с Get-AsrOutcome в .ps1 (test_27).
asr_classify() {
	local rc="$1" code="$2" f="${3:-}" d=""
	ASR_OUTCOME="stop"; ASR_REASON=""; ASR_DETAIL=""
	[ "$code" != "200" ] && asr_detail "$f"
	[ -n "$ASR_DETAIL" ] && d=": $ASR_DETAIL"
	if [ "$rc" != "0" ]; then
		case "$rc" in
			90) ASR_REASON="сертификат сервера не совпал с закреплённым ключом (curl 90)" ;;
			28) ASR_REASON="истёк таймаут ожидания ответа (curl 28); задача на сервере может ещё выполняться" ;;
			26) ASR_OUTCOME="file"; ASR_REASON="curl не смог прочитать извлечённый звук (curl 26)" ;;
			*)  ASR_REASON="сетевая ошибка (curl $rc${ASR_CURL_ERR:+: $ASR_CURL_ERR})" ;;
		esac
		return 0
	fi
	case "$code" in
		200) ASR_OUTCOME="ok" ;;
		400|413|422) ASR_OUTCOME="file"; ASR_REASON="HTTP $code$d" ;;
		401|403) ASR_REASON="ключ не принят (HTTP $code)$d" ;;
		503) ASR_REASON="очередь сервера заполнена (HTTP 503) и после повторов$d" ;;
		504) ASR_REASON="сервер не уложился в свой предел (HTTP 504); задача на сервере продолжает выполняться — повторите позже$d" ;;
		*) ASR_REASON="HTTP $code$d" ;;
	esac
	return 0
}

# --- Запрос одной части ---
# Запрос синхронный: соединение молчит до конца распознавания (до получаса) — это
# норма. 503 (очередь полна) — пауза и повтор; остальное классифицирует
# asr_classify. 200 без поля segments (страница ошибки прокси) — провал файла, а
# не пустая расшифровка.
asr_transcribe_part() {
	local part="$1" resp="$2" try=1 tries="${ASR_RETRIES:-5}" wait_s="${ASR_RETRY_WAIT:-60}"
	while :; do
		rm -f "$ASR_RUN_DIR/$resp"
		asr_curl_args "$ASR_BASE" "$part" "$resp"
		asr_curl_run "$ASR_RUN_DIR" "${ASR_CURL_ARGS[@]}"
		if [ "$ASR_CURL_RC" = "0" ] && [ "$ASR_HTTP_CODE" = "503" ] && [ "$try" -le "$tries" ]; then
			echo "[ПРЕДУПРЕЖДЕНИЕ] Очередь сервера заполнена (HTTP 503) — повтор через ${wait_s} с (попытка $try из $tries)." >&2
			sleep "$wait_s"
			try=$((try + 1))
			continue
		fi
		break
	done
	asr_classify "$ASR_CURL_RC" "$ASR_HTTP_CODE" "$ASR_RUN_DIR/$resp"
	if [ "$ASR_OUTCOME" = "ok" ] && ! grep -q '"segments"' "$ASR_RUN_DIR/$resp" 2>/dev/null; then
		ASR_OUTCOME="file"; ASR_REASON="сервер ответил 200, но без поля segments"
	fi
	return 0
}

# --- Предпусковая проверка: один раз, ДО первого файла ---
# Всё, что делает невозможным весь прогон, выясняется здесь: отказать на сотом
# файле дороже, чем на нулевом. Создаёт ASR_RUN_DIR (его убирает сводка скрипта и
# trap Ctrl+C) и выбирает адрес.
asr_preflight() {
	asr_validate_config || return 1
	if [ "${ffmpeg_available:-yes}" != "yes" ]; then
		echo "[ОШИБКА] Распознавание речи требует локального ffmpeg: им извлекается звук ($ffmpeg не найден)." >&2
		return 1
	fi
	if ! command -v "${CURL_BIN:-curl}" >/dev/null 2>&1; then
		echo "[ОШИБКА] curl не найден — распознавание речи невозможно." >&2
		return 1
	fi
	asr_resolve_api_key || return 1
	if [ -z "${asr_api_key:-}" ]; then
		echo "[ОШИБКА] [asr] ключ не задан: api_key, api_key_command или \${ASR_API_KEY}." >&2
		return 1
	fi
	ASR_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ffconv_asr.XXXXXXXX")" || {
		echo "[ОШИБКА] Не удалось создать временный каталог для распознавания." >&2
		ASR_RUN_DIR=""
		return 1
	}
	if ! asr_select_endpoint; then
		echo "[ОШИБКА] $ASR_STOP_REASON" >&2
		rm -rf "$ASR_RUN_DIR"; ASR_RUN_DIR=""
		return 1
	fi
	if [ -n "$ASR_LIM_LANGUAGES" ]; then
		case " $ASR_LIM_LANGUAGES " in
			*" $asr_language "*) ;;
			*)
				echo "[ОШИБКА] [asr] language = '$asr_language': сервер его не принимает (доступны: $ASR_LIM_LANGUAGES)." >&2
				rm -rf "$ASR_RUN_DIR"; ASR_RUN_DIR=""
				return 1 ;;
		esac
	fi
	case "$ASR_BASE" in
		http://*) echo "[ПРЕДУПРЕЖДЕНИЕ] $ASR_BASE — открытый http: ключ и звук идут по сети незашифрованными." ;;
	esac
	if [ "${asr_diarize:-yes}" = "yes" ] && [ "$ASR_LIM_DIARIZATION" = "false" ]; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] Сервер сообщает diarization = false: говорящих в расшифровке может не быть."
	fi
	ASR_STOP_REASON=""
	asr_plan_parts 0
	log_msg "INFO" "Распознавание речи: $ASR_BASE (${ASR_LIM_VER:-?}, ${ASR_LIM_DEVICE:-?}); целиком — до $ASR_PLAN_WHOLE с, длиннее — равными частями"
	return 0
}
```

- [ ] **Step 5: Прогнать — зелёный (кроме сборки текста — её suites ещё нет)**

Run: `bash tests/ffmpeg/test_25_asr_client.sh`
Expected: `TESTS_RESULT pass=… fail=0`. Если падает `asr_json_field` на bash 3.2-специфике — проверить шаблон отдельным скриптом-файлом (память: однострочник Bash-инструмента искажает `\`).

- [ ] **Step 6: Guardrail и shellcheck**

Run: `bash tests/common/test_guardrails.sh && bash tests/common/test_encoding.sh`
Expected: `fail=0` (печатающие функции модуля — `asr_preflight` — через `$( )` нигде не вызываются).

- [ ] **Step 7: Commit** — `ffmpeg/asr_client.sh tests/ffmpeg/test_25_asr_client.sh tests/fixtures/asr/limits.json tests/fixtures/asr/basic.json tests/run_tests.sh README.md`, «asr: клиент .sh — адреса, пределы, план частей, curl с пином, исходы».

---

### Task 4: `asr_client.sh` — сборка `.txt` и `.asr.json`

**Files:**
- Create: `tests/fixtures/asr/{basic,escapes,empty}.json`, `tests/fixtures/asr/{basic,escapes,chunks,empty}.txt`
- Modify: `ffmpeg/asr_client.sh` (дописать в конец)
- Modify: `tests/ffmpeg/test_25_asr_client.sh` (suites перед `rm -rf "$WORK"`)

**Interfaces:**
- Produces:
  - `asr_render <имя входа> <дата> <длина части> <выход .txt> <файл1> <смещение1> [<файл2> <смещение2> …]` → rc 0/1; `ASR_R_SPEAKERS` («2» или «2,1»), `ASR_R_LOW`, `ASR_R_BAD`
  - `asr_write_json <выход> <файл1> <смещение1> […]` → rc

- [ ] **Step 1: Фикстуры (JSON — одна строка без перевода строки в конце; .txt — с `\n` в конце)**

`tests/fixtures/asr/basic.json`:
```json
{"text":" Добрый день. Начинаем совещание. Да, слышу.","language":"ru","asr_ver":"large-v3-turbo.cpu.int8.v1","segments":[{"start":0.03,"end":4.71,"text":" Добрый день.","speaker":"SPEAKER_00","confidence":0.94,"avg_logprob":-0.06,"words":[{"word":"Добрый","start":0.03,"end":0.41,"score":0.81,"speaker":"SPEAKER_00"},{"word":"день.","start":0.45,"end":0.9,"score":0.7,"speaker":"SPEAKER_00"}]},{"start":5.0,"end":9.5,"text":" Начинаем совещание.","speaker":"SPEAKER_00","confidence":0.91,"words":[]},{"start":41.2,"end":43.0,"text":" Да, слышу.","speaker":"SPEAKER_01","confidence":0.55,"words":[]}],"stages":{"transcribe":{"status":"ok","seconds":76.0},"align":{"status":"ok","seconds":23.0},"diarize":{"status":"ok","seconds":117.0}},"warnings":[],"audio_seconds":480.0,"processing_seconds":215.0}
```

`tests/fixtures/asr/escapes.json` — экранирование, `\u`, суррогатная пара, нет `speaker`, `null`, пустой сегмент, ошибки этапов, нет `processing_seconds`:
```json
{"asr_ver":"large-v3-turbo.cpu.int8.v1","segments":[{"start":1.5,"end":2.0,"text":" Он сказал: \"привет\\пока\"\n\tи ушёл \u0434\u0430 \ud83d\ude00","confidence":0.8},{"start":2.5,"end":3.0,"text":"   ","speaker":"SPEAKER_00","confidence":0.1},{"start":3.25,"end":4.0,"text":" Второй.","speaker":null,"confidence":null},{"start":65.9,"end":70.0,"text":"Третий","speaker":"SPEAKER_02","confidence":0.2}],"stages":{"transcribe":{"status":"ok"},"align":{"status":"unavailable"},"diarize":{"status":"failed"}},"warnings":["разметка говорящих не выполнена","у 1 сегмента нет confidence"],"audio_seconds":75.5}
```

`tests/fixtures/asr/empty.json`:
```json
{"segments":[],"stages":{},"warnings":[]}
```

`tests/fixtures/asr/basic.txt`:
```
# Расшифровка: meeting.mp4
# Дата: 2026-10-02 12:00
# Модель: large-v3-turbo.cpu.int8.v1
# Длительность записи: 00:08:00, обработка: 00:03:35
# Говорящих: 2
# Сомнительных сегментов (confidence < 0.6): 1; первые: 00:00:41

[00:00:00] SPEAKER_00: Добрый день. Начинаем совещание.
[00:00:41] SPEAKER_01: Да, слышу.
```

`tests/fixtures/asr/escapes.txt` (между `"` и `и` — ДВА пробела: от `\n` и от `\t`):
```
# Расшифровка: escapes.mkv
# Дата: 2026-10-02 12:00
# Модель: large-v3-turbo.cpu.int8.v1
# Длительность записи: 00:01:15, обработка: ?
# Говорящих: 1
# Сомнительных сегментов (confidence < 0.6): 1; первые: 00:01:05
# Этапы с ошибкой: align=unavailable, diarize=failed
# Предупреждение: разметка говорящих не выполнена
# Предупреждение: у 1 сегмента нет confidence

[00:00:01] SPEAKER_?: Он сказал: "привет\пока"  и ушёл да 😀 Второй.
[00:01:05] SPEAKER_02: Третий
```

`tests/fixtures/asr/chunks.txt` (`basic.json` со смещением 0 + `escapes.json` со смещением 1001):
```
# Расшифровка: long.mp4
# Дата: 2026-10-02 12:00
# Модель: large-v3-turbo.cpu.int8.v1
# Длительность записи: 00:09:15, обработка: ?
# Говорящих по частям: 2, 1
# Частей: 2 по ≈00:16:41 — метки говорящих в разных частях независимы
# Сомнительных сегментов (confidence < 0.6): 2; первые: 00:00:41, 00:17:46
# Этапы с ошибкой: ч.2: align=unavailable, ч.2: diarize=failed
# Предупреждение: ч.2: разметка говорящих не выполнена
# Предупреждение: ч.2: у 1 сегмента нет confidence

[00:00:00] SPEAKER_00: Добрый день. Начинаем совещание.
[00:00:41] SPEAKER_01: Да, слышу.
[00:16:42] SPEAKER_?: Он сказал: "привет\пока"  и ушёл да 😀 Второй.
[00:17:46] SPEAKER_02: Третий
```

`tests/fixtures/asr/empty.txt` (заканчивается пустой строкой):
```
# Расшифровка: silence.wav
# Дата: 2026-10-02 12:00
# Модель: ?
# Длительность записи: ?, обработка: ?
# Говорящих: 0
# Сомнительных сегментов (confidence < 0.6): 0

```

После записи проверить байты: `od -c tests/fixtures/asr/empty.txt | tail -3` — конец `0 \n \n`; `tail -c 1 tests/fixtures/asr/basic.json | od -c` — последний байт `}`.

- [ ] **Step 2: Тест — дописать в `test_25_asr_client.sh` перед `rm -rf "$WORK"`**

```bash
# ══════════════════════════════════════════════════════════════
suite "сборка текста из ответов (общие фикстуры tests/fixtures/asr)"
# ══════════════════════════════════════════════════════════════
# $1 — ожидаемый .txt; дальше — аргументы asr_render (выход — четвёртый из них).
_render_check() {
    local want="$FIX/$1"; shift
    asr_render "$@"; local rc=$?
    if [ "$rc" -eq 0 ] && cmp -s "$want" "$4"; then pass "$(basename "$want"): байт в байт"
    else fail "$(basename "$want"): байт в байт" "$(cat "$want")" "$(cat "$4" 2>/dev/null)"; fi
}
_render_check basic.txt "meeting.mp4" "2026-10-02 12:00" 480 "$WORK/basic.txt" "$FIX/basic.json" 0
assert_eq "сводка: говорящие|сомнительные|этапы" "2|1|" "$ASR_R_SPEAKERS|$ASR_R_LOW|$ASR_R_BAD"
_render_check escapes.txt "escapes.mkv" "2026-10-02 12:00" 76 "$WORK/escapes.txt" "$FIX/escapes.json" 0
assert_eq "этапы с ошибкой в сводке" "align=unavailable, diarize=failed" "$ASR_R_BAD"
_render_check chunks.txt "long.mp4" "2026-10-02 12:00" 1001 "$WORK/chunks.txt" "$FIX/basic.json" 0 "$FIX/escapes.json" 1001
assert_eq "говорящие по частям" "2,1" "$ASR_R_SPEAKERS"
_render_check empty.txt "silence.wav" "2026-10-02 12:00" 10 "$WORK/empty.txt" "$FIX/empty.json" 0

# Многомегабайтный ответ со словами: разбор обязан быть линейным. В BWK awk
# (macOS) substr считает длину всей строки на каждом вызове, и посимвольный
# проход по документу целиком был бы квадратичным.
{
    printf '{"asr_ver":"x","segments":['
    for (( _i = 0; _i < 2000; _i++ )); do
        [ "$_i" -gt 0 ] && printf ','
        printf '{"start":%d.5,"end":%d.9,"text":" реплика %d \\"q\\"","speaker":"SPEAKER_0%d","confidence":0.9,"words":[{"word":"реплика","start":%d.5,"end":%d.7,"score":0.8}]}' \
            "$_i" "$_i" "$_i" $(( _i % 2 )) "$_i" "$_i"
    done
    printf '],"stages":{"transcribe":{"status":"ok"}},"warnings":[],"audio_seconds":2000.0,"processing_seconds":1000.0}'
} > "$WORK/big.json"
asr_render "big.mp4" "2026-10-02 12:00" 2000 "$WORK/big.txt" "$WORK/big.json" 0
assert_eq "2000 реплик" "2000" "$(grep -c '^\[' "$WORK/big.txt")"
assert_eq "последняя реплика цела" '[00:33:19] SPEAKER_01: реплика 1999 "q"' "$(tail -1 "$WORK/big.txt")"

# ══════════════════════════════════════════════════════════════
suite "JSON результата"
# ══════════════════════════════════════════════════════════════
asr_write_json "$WORK/one.json" "$FIX/basic.json" 0
assert_eq "одна часть — ответ без изменений" "$(cat "$FIX/basic.json")" "$(cat "$WORK/one.json")"
asr_write_json "$WORK/two.json" "$FIX/basic.json" 0 "$FIX/escapes.json" 1001
_two="$(cat "$WORK/two.json")"
assert_contains "обёртка, первая часть" '{"chunks":[{"offset_seconds":0,"response":{' "$_two"
assert_contains "вторая часть со смещением" '"offset_seconds":1001,"response":{"asr_ver"' "$_two"
```

- [ ] **Step 3: Прогнать — падает** (`asr_render: command not found`).

Run: `bash tests/ffmpeg/test_25_asr_client.sh`

- [ ] **Step 4: Реализация — дописать в `ffmpeg/asr_client.sh`**

```bash
# --- Сборка .txt из ответов сервера: один процесс awk на файл ---
# Ни jq, ни python в Git Bash/macOS не гарантированы. Разбор JSON — с RS = кавычка:
# документ режется на короткие записи «вне строки / внутри строки», и awk не
# ходит посимвольно по многомегабайтному тексту (в BWK awk substr считает длину
# всей строки на каждом вызове — посимвольный проход был бы квадратичным).
# Кавычка внутри строки экранирована, если перед ней НЕЧЁТНОЕ число обратных
# слэшей. Хранятся только нужные значения (слова и полный текст пропускаются),
# строки декодируются целиком: \" \\ \/ \b \f \n \r \t \uXXXX и суррогатные пары.
# LC_ALL=C: байты UTF-8 проходят насквозь, %c печатает байт. Правила шапки и
# реплик — спека §9.2; двойник — Write-AsrTranscript в .ps1 (байт в байт, test_27).
# В программе нет апострофов: она лежит в одинарных кавычках оболочки.
ASR_AWK_RENDER='
function hexval(h,   i, v, c) {
	if (length(h) != 4) return -1
	v = 0; h = tolower(h)
	for (i = 1; i <= 4; i++) {
		c = index("0123456789abcdef", substr(h, i, 1)) - 1
		if (c < 0) return -1
		v = v * 16 + c
	}
	return v
}
function utf8(cp) {
	if (cp < 128) return sprintf("%c", cp)
	if (cp < 2048) return sprintf("%c%c", 192 + int(cp / 64), 128 + cp % 64)
	if (cp < 65536) return sprintf("%c%c%c", 224 + int(cp / 4096), 128 + int(cp / 64) % 64, 128 + cp % 64)
	return sprintf("%c%c%c%c", 240 + int(cp / 262144), 128 + int(cp / 4096) % 64, 128 + int(cp / 64) % 64, 128 + cp % 64)
}
function decode(s,   out, i, c, cp, lo) {
	if (index(s, "\\") == 0) return s
	out = ""
	while ((i = index(s, "\\")) > 0) {
		out = out substr(s, 1, i - 1)
		c = substr(s, i + 1, 1)
		if (c == "u") {
			cp = hexval(substr(s, i + 2, 4)); s = substr(s, i + 6)
			if (cp >= 55296 && cp < 56320 && substr(s, 1, 2) == "\\u") {
				lo = hexval(substr(s, 3, 4))
				if (lo >= 56320 && lo < 57344) { cp = 65536 + (cp - 55296) * 1024 + (lo - 56320); s = substr(s, 7) }
			}
			if (cp > 0) out = out utf8(cp)
			continue
		}
		if (c == "n") out = out "\n"
		else if (c == "t") out = out "\t"
		else if (c == "r") out = out "\r"
		else if (c == "b") out = out "\b"
		else if (c == "f") out = out "\f"
		else out = out c
		s = substr(s, i + 2)
	}
	return out s
}
function clean(t) { gsub(/[\r\n\t]/, " ", t); sub(/^ +/, "", t); sub(/ +$/, "", t); return t }
function ts(x,   s) { s = int(x); return sprintf("%02d:%02d:%02d", int(s / 3600), int((s % 3600) / 60), s % 60) }
function want(path) {
	return path ~ /^p[0-9]+\.(asr_ver|audio_seconds|processing_seconds)$/ ||
	       path ~ /^p[0-9]+\.warnings\.[0-9]+$/ ||
	       path ~ /^p[0-9]+\.stages\.[^.]+\.status$/ ||
	       path ~ /^p[0-9]+\.segments\.[0-9]+\.(start|text|speaker|confidence)$/
}
function curpath() {
	if (d == 0) return "p" part
	return (TY[d] == "o") ? PP[d] "." KEY[d] : PP[d] "." IX[d]
}
function setval(raw, isstr,   path, a) {
	path = curpath()
	if (!want(path)) return
	if (!isstr && raw == "null") return
	V[path] = isstr ? decode(raw) : raw
	split(path, a, ".")
	if (a[2] == "segments" && a[3] + 1 > NSEG[part]) NSEG[part] = a[3] + 1
	if (a[2] == "warnings" && a[3] + 1 > NW[part]) NW[part] = a[3] + 1
}
function flushlit() { if (lit != "") { setval(lit, 0); lit = "" } }
function opencont(t,   path) {
	path = curpath()
	d++; TY[d] = t; PP[d] = path; KEY[d] = ""; IX[d] = 0
	expect = (t == "o") ? "k" : "v"
}
function outside(s,   i, n, c) {
	n = length(s)
	for (i = 1; i <= n; i++) {
		c = substr(s, i, 1)
		if (c == "{") opencont("o")
		else if (c == "[") opencont("a")
		else if (c == "}" || c == "]") { flushlit(); d--; expect = "n" }
		else if (c == ":") expect = "v"
		else if (c == ",") { flushlit(); if (TY[d] == "a") IX[d]++; expect = (TY[d] == "o") ? "k" : "v" }
		else if (c == " " || c == "\n" || c == "\r" || c == "\t") flushlit()
		else lit = lit c
	}
}
function onstring(raw) {
	if (expect == "k") {
		KEY[d] = raw
		if (PP[d] ~ /^p[0-9]+\.stages$/) SK[part, ++NSK[part]] = raw
		expect = "c"
	} else { setval(raw, 1); expect = "n" }
}
BEGIN {
	RS = "\""
	part = 0
	split(ENVIRON["ASR_R_OFFS"], OFF, " ")
	out = ENVIRON["ASR_R_OUT"]
	lowthr = 0.6
}
FNR == 1 { part++; d = 0; ins = 0; sbuf = ""; lit = ""; expect = "v"; NSEG[part] = 0; NW[part] = 0; NSK[part] = 0 }
{
	if (!ins) { outside($0); ins = 1; next }
	n = length($0); k = 0
	while (k < n && substr($0, n - k, 1) == "\\") k++
	if (k % 2 == 1) { sbuf = sbuf $0 "\""; next }
	onstring(sbuf $0); sbuf = ""; ins = 0
}
END {
	aud = 0; audok = 1; prc = 0; prcok = 1; ver = ""; bad = ""; nwarn = 0
	nrep = 0; low = 0; nlow = 0; lowlist = ""; spk = ""; spkh = ""
	for (p = 1; p <= part; p++) {
		pre = "p" p "."
		off = OFF[p] + 0
		tag = (part > 1) ? "ч." p ": " : ""
		if ((pre "audio_seconds") in V) aud += V[pre "audio_seconds"]; else audok = 0
		if ((pre "processing_seconds") in V) prc += V[pre "processing_seconds"]; else prcok = 0
		if (ver == "" && (pre "asr_ver") in V) ver = V[pre "asr_ver"]
		for (j = 1; j <= NSK[p]; j++) {
			sk = SK[p, j]
			sst = ((pre "stages." sk ".status") in V) ? V[pre "stages." sk ".status"] : "?"
			if (sst != "ok") bad = bad (bad == "" ? "" : ", ") tag sk "=" sst
		}
		for (j = 0; j < NW[p]; j++)
			if ((pre "warnings." j) in V) WARN[++nwarn] = tag clean(V[pre "warnings." j])
		ns = 0; cur = ""; rb = ""; t0 = 0
		for (i = 0; i < NSEG[p]; i++) {
			sb = pre "segments." i "."
			if (!((sb "text") in V)) continue
			t = clean(V[sb "text"])
			if (t == "") continue
			sp = ((sb "speaker") in V && V[sb "speaker"] != "") ? V[sb "speaker"] : "SPEAKER_?"
			if (sp != "SPEAKER_?" && !((p, sp) in SEEN)) { SEEN[p, sp] = 1; ns++ }
			st = (((sb "start") in V) ? V[sb "start"] + 0 : 0) + off
			if ((sb "confidence") in V && V[sb "confidence"] + 0 < lowthr) {
				low++
				if (nlow < 3) { lowlist = lowlist (nlow ? ", " : "") ts(st); nlow++ }
			}
			if (rb != "" && sp != cur) { REP[++nrep] = "[" ts(t0) "] " cur ": " rb; rb = "" }
			if (rb == "") { cur = sp; t0 = st; rb = t } else rb = rb " " t
		}
		if (rb != "") REP[++nrep] = "[" ts(t0) "] " cur ": " rb
		spk = spk (p > 1 ? "," : "") ns
		spkh = spkh (p > 1 ? ", " : "") ns
	}
	print "# Расшифровка: " ENVIRON["ASR_R_SRC"] > out
	print "# Дата: " ENVIRON["ASR_R_DATE"] > out
	print "# Модель: " (ver == "" ? "?" : ver) > out
	print "# Длительность записи: " (audok ? ts(aud) : "?") ", обработка: " (prcok ? ts(prc) : "?") > out
	if (part == 1) print "# Говорящих: " spkh > out
	else {
		print "# Говорящих по частям: " spkh > out
		print "# Частей: " part " по ≈" ts(ENVIRON["ASR_R_PLEN"] + 0) " — метки говорящих в разных частях независимы" > out
	}
	print "# Сомнительных сегментов (confidence < 0.6): " low (low > 0 ? "; первые: " lowlist : "") > out
	if (bad != "") print "# Этапы с ошибкой: " bad > out
	for (j = 1; j <= nwarn; j++) print "# Предупреждение: " WARN[j] > out
	print "" > out
	for (j = 1; j <= nrep; j++) print REP[j] > out
	close(out)
	print "speakers=" spk " low=" low " bad=" bad
}
'

# $1 — имя входа, $2 — дата, $3 — длина части (для шапки), $4 — выход;
# дальше пары «файл ответа, смещение». Сводка — в ASR_R_SPEAKERS/LOW/BAD.
# Значения уходят в awk через ENVIRON, а не -v: -v раскрывает в них \-escape'ы.
asr_render() {
	local src="$1" date="$2" plen="$3" out="$4" offs="" summary
	local -a files=()
	shift 4
	while [ $# -ge 2 ]; do files+=("$1"); offs="${offs:+$offs }$2"; shift 2; done
	rm -f "$out"
	summary="$(ASR_R_SRC="$src" ASR_R_DATE="$date" ASR_R_OUT="$out" ASR_R_OFFS="$offs" ASR_R_PLEN="$plen" \
		LC_ALL=C awk "$ASR_AWK_RENDER" "${files[@]}")" || return 1
	ASR_R_SPEAKERS="${summary#speakers=}"; ASR_R_SPEAKERS="${ASR_R_SPEAKERS%% low=*}"
	ASR_R_LOW="${summary#* low=}"; ASR_R_LOW="${ASR_R_LOW%% bad=*}"
	ASR_R_BAD="${summary#* bad=}"
	[ -s "$out" ]
}

# --- .asr.json: ответ как есть или обёртка частей без пересборки ---
# $1 — выход; дальше пары «файл ответа, смещение». Время внутри response — от
# начала своей части; смещение указано явно (спека §9.1).
asr_write_json() {
	local out="$1" first=1
	shift
	if [ $# -eq 2 ]; then cp -f "$1" "$out"; return $?; fi
	{
		printf '{"chunks":['
		while [ $# -ge 2 ]; do
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"offset_seconds":%s,"response":' "$2"
			cat "$1"
			printf '}'
			shift 2
		done
		printf ']}\n'
	} > "$out"
}
```

- [ ] **Step 5: Прогнать — зелёный**

Run: `bash tests/ffmpeg/test_25_asr_client.sh`
Expected: `fail=0`. При расхождении `escapes.txt` — `cmp -l` покажет байт; чаще всего виноват конец строки фикстуры или пробелы от `\n\t`.

- [ ] **Step 6: Commit** — `ffmpeg/asr_client.sh tests/ffmpeg/test_25_asr_client.sh tests/fixtures/asr/`, «asr: сборка .txt (awk, RS по кавычке) и .asr.json; общие фикстуры».

---

### Task 5: Ветка ASR в `FFmpeg_Converter_script.sh`

**Files:**
- Modify: `ffmpeg/asr_client.sh` (дописать `asr_file_cleanup`, `asr_file`, `asr_run`)
- Modify: `ffmpeg/FFmpeg_Converter_script.sh:141-145, 646-665, 1860-1873, 1891, 2017, 2173, 2190`
- Create: `tests/ffmpeg/test_28_asr_integration.sh`
- Modify: `tests/run_tests.sh`, `README.md`

**Interfaces:**
- Consumes: всё из Task 3–4; из script.sh — `path_dir`, `lower_ascii`, `canon_path`, `parse_media_info`, `partial_path`, `file_size`, `now_s`, `log_msg`, `put_result`, `find_inputs`, `sort_null`, `_src_prefix_len`, `dest_inside_source`, `canon_destination`.
- Produces: `asr_file <путь>` → rc 0 (учтён через `put_result`) или 2 (прогон остановлен, `ASR_STOP_REASON`); `asr_run` → `ASR_NOT_PROCESSED`; переменная `asr_active` в script.sh.

- [ ] **Step 1: Тест — `tests/ffmpeg/test_28_asr_integration.sh`**

```bash
#!/bin/bash
# Путь к дот-сорсимому скрипту вычисляется в рантайме (SC1090); переменные,
# которые здесь только присваиваются, читает production-скрипт (SC2034).
# shellcheck disable=SC1090,SC2034
# ============================================================
# test_28_asr_integration.sh — режим распознавания речи сквозь
# FFmpeg_Converter_script.sh: моки ffmpeg и curl, настоящие выборка входов,
# зеркало подпапок, пропуск готового, сводка и код возврата.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.sh"
MOCKS="$TESTS_DIR/mocks"
FIX="$TESTS_DIR/fixtures/asr"
source "$TESTS_DIR/lib/framework.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_int_XXXXXX")"
IN="$WORK/in"; OUT="$WORK/out"
LIMITS="$(cat "$FIX/limits.json")"
BASIC="$(cat "$FIX/basic.json")"
TAB=$'\t'

default_vars() {
    folder_sources="$IN"; folder_destination="$OUT"; ffmpeg="$MOCKS/ffmpeg"
    audio_codec=":+:aac"; audio_number_channels=":+:2"; audio_bitrate=":+:128"
    audio_sampling_rate=":+:44100"; audio_normalize=":-:loudnorm"
    video_codec=":+:libx264"; video_resolution=":-:1280x720"; video_bitrate=":-:2000"
    video_number_frames=":-:25"; video_rotation=":-:2"; video_subtitles=":-:burn"
    video_quality=":+:23"; keep_aspect_ratio=":+:yes"; output_container=":+:mp4"
    multithreads=":+:4"; parallel_files=":-:2"
    hw_accel=":-:nvidia"; gpu_preset=":-:p5"; gpu_tune=":-:hq"; gpu_rc=":-:vbr"
    playback_speed=":-:1.0"; start_coding=":-:01-00-00"; length_coding=":-:00-05-00"
    split_by_silence="no"; silence_duration="2.0"; silence_threshold="-30dB"
    save_old_extension="no"; format_files_in="mp4,mkv,avi"
    subtitles_style=""; dry_run="no"; enable_log="no"; log_file=""
    audio_only="no"; merge_files="no"; create_frame="no"; overwrite_existing="no"
    copy_codecs="no"; extract_audio_copy="no"
    remote_enabled="no"; remote_endpoint=""; remote_api_key=""
    remote_api_key_command=""; remote_on_failure="abort"; remote_prefer="auto"; remote_wait_timeout="1800"
    asr_enabled="yes"; asr_endpoint="https://asr.example:30010"; asr_api_key="int-secret-key"
    asr_api_key_command=""; asr_pinned_pubkey=""; asr_language="ru"; asr_diarize="yes"; asr_num_speakers=""
}

# RUN_OUT ← вывод скрипта, RUN_RC ← код возврата; маршруты мока curl — в $ROUTES.
run_asr() {
    RUN_OUT="$( (
        export PATH="$MOCKS:$PATH"
        export MOCK_FFMPEG_LOG="$WORK/ff.log" MOCK_CURL_LOG="$WORK/curl.log"
        export CURL_BIN="$MOCKS/curl" MOCK_CURL_ROUTES="$ROUTES"
        export FFCONV_ASR_NOW="2026-10-02 12:00" ASR_RETRY_WAIT=0
        default_vars
        for ov in "$@"; do eval "$ov"; done
        source "$SCRIPT" 2>&1
    ) < /dev/null )"
    RUN_RC=$?
}
reset_dirs() { rm -rf "$IN" "$OUT" "$WORK/ff.log" "$WORK/curl.log"; mkdir -p "$IN" "$OUT"; }
ok_routes() { ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}200${TAB}${BASIC}"; }
posts() { POSTS=0; [ -f "$WORK/curl.log" ] && POSTS="$(grep -c 'speech/transcriptions' "$WORK/curl.log")"; }

# ══════════════════════════════════════════════════════════════
suite "файл целиком: .txt и .asr.json в зеркале подпапки"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes
mkdir -p "$IN/sub"; : > "$IN/sub/Встреча 1.mp4"
run_asr
assert_eq "код возврата 0" "0" "$RUN_RC"
_txt="$OUT/sub/Встреча 1.txt"
assert_file_exists "расшифровка в зеркале подпапки" "$_txt"
assert_eq "шапка называет исходный файл" "# Расшифровка: Встреча 1.mp4" "$(head -1 "$_txt")"
assert_eq "остальное — как у фикстуры" "$(tail -n +2 "$FIX/basic.txt")" "$(tail -n +2 "$_txt")"
assert_eq "сырой ответ сохранён" "$BASIC" "$(cat "$OUT/sub/Встреча 1.asr.json")"
_ff="$(cat "$WORK/ff.log")"
assert_contains "звук — FLAC 16 кГц моно" "-map 0:a:0 -vn -ac 1 -ar 16000 -c:a flac" "$_ff"
assert_not_contains "целиком — без -ss" "-ss" "$_ff"
assert_contains "сводка" "Обработано:  1" "$RUN_OUT"
assert_not_contains "ключ не печатается" "int-secret-key" "$RUN_OUT"
assert_empty "временных файлов в назначении нет" "$(find "$OUT" -name '.ffconv-partial-*')"

# ══════════════════════════════════════════════════════════════
suite "длинная запись — равные части, смещения в JSON и шапке"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/long.mp4"
run_asr 'export MOCK_FFMPEG_DURATION=01:00:00.00'
assert_eq "код возврата 0" "0" "$RUN_RC"
_ff="$(cat "$WORK/ff.log")"
assert_contains "вторая часть" "-ss 1201 -t 1201" "$_ff"
assert_contains "третья часть — остаток" "-ss 2402 -t 1199" "$_ff"
posts; assert_eq "три запроса" "3" "$POSTS"
_j="$(cat "$OUT/long.asr.json")"
assert_contains "обёртка частей" '{"chunks":[{"offset_seconds":0,"response":' "$_j"
assert_contains "смещение третьей" '"offset_seconds":2402,"response":' "$_j"
assert_contains "шапка о частях" "# Частей: 3 по ≈00:20:01 — метки говорящих в разных частях независимы" "$(cat "$OUT/long.txt")"

# ══════════════════════════════════════════════════════════════
suite "готовое пропускается; overwrite_existing = yes — пересчёт"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr
rm -f "$WORK/curl.log"
run_asr
assert_eq "повтор — код 0" "0" "$RUN_RC"
assert_contains "пропуск назван" "расшифровка уже есть" "$RUN_OUT"
posts; assert_eq "повтор не отправляет запись" "0" "$POSTS"
rm -f "$WORK/curl.log"
run_asr 'overwrite_existing="yes"'
posts; assert_eq "overwrite — запрос снова" "1" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "файл без звука — провал без запроса"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/mute.mp4"
run_asr 'export MOCK_FFMPEG_NO_AUDIO=1'
assert_eq "код 1" "1" "$RUN_RC"
assert_contains "причина" "нет звуковой дорожки" "$RUN_OUT"
posts; assert_eq "запроса нет" "0" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "400 — провален файл, прогон продолжается"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}400${TAB}{\"detail\":\"ffprobe не прочитал аудио\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
posts; assert_eq "оба файла отправлены" "2" "$POSTS"
assert_contains "detail дословно" "HTTP 400: ffprobe не прочитал аудио" "$RUN_OUT"
assert_not_contains "прогон не останавливался" "Остановлено:" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "401 на запросе — прогон остановлен, остаток не тронут"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"; : > "$IN/b.mp4"
ROUTES="GET /speech/limits${TAB}200${TAB}${LIMITS}
POST /speech/transcriptions${TAB}401${TAB}{\"detail\":\"bad key\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
posts; assert_eq "только один запрос" "1" "$POSTS"
assert_contains "причина в сводке" "Остановлено: ключ не принят (HTTP 401)" "$RUN_OUT"
assert_contains "остаток посчитан" "Не обработано: 1" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "preflight: ключ не принят — ни один файл не тронут"
# ══════════════════════════════════════════════════════════════
reset_dirs; : > "$IN/a.mp4"
ROUTES="GET /speech/limits${TAB}401${TAB}{\"detail\":\"bad key\"}"
run_asr
assert_eq "код 1" "1" "$RUN_RC"
assert_contains "причина" "ключ не принят (HTTP 401)" "$RUN_OUT"
assert_not_contains "файлы не трогались" "Обработано:" "$RUN_OUT"
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'asr_language="de"'
assert_eq "чужой язык — код 1" "1" "$RUN_RC"
assert_contains "язык назван" "language = 'de'" "$RUN_OUT"

# ══════════════════════════════════════════════════════════════
suite "dry_run: план и команды без извлечения и отправки"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'dry_run="yes"' 'export MOCK_FFMPEG_DURATION=01:00:00.00'
assert_eq "код 0" "0" "$RUN_RC"
assert_contains "план" "[DRY-RUN] a.mp4: частей 3" "$RUN_OUT"
assert_contains "команда ffmpeg" "-c:a flac part_002.flac" "$RUN_OUT"
assert_contains "запрос" "speech/transcriptions" "$RUN_OUT"
assert_not_contains "ключа в выводе нет" "int-secret-key" "$RUN_OUT"
posts; assert_eq "отправки нет" "0" "$POSTS"
assert_empty "файлов нет" "$(ls -A "$OUT")"

# ══════════════════════════════════════════════════════════════
suite "два входа на один .txt; destination = source"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/x.mp4"; : > "$IN/x.mkv"
run_asr
assert_eq "коллизия — код 1" "1" "$RUN_RC"
assert_contains "конфликт назван" "конфликт выходов" "$RUN_OUT"
posts; assert_eq "отправлен только первый" "1" "$POSTS"
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'folder_destination="$IN"'
assert_file_exists "рядом с записью" "$IN/a.txt"
rm -f "$WORK/curl.log"
run_asr 'folder_destination="$IN"'
posts; assert_eq "повтор in-place не отправляет" "0" "$POSTS"

# ══════════════════════════════════════════════════════════════
suite "[remote] и parallel_files в режиме распознавания"
# ══════════════════════════════════════════════════════════════
reset_dirs; ok_routes; : > "$IN/a.mp4"
run_asr 'remote_enabled="yes"' 'remote_endpoint="http://svc.example/v1"' 'remote_api_key="r"' 'parallel_files=":+:3"'
assert_contains "[remote] не используется — сказано" "[remote] в режиме распознавания не используется" "$RUN_OUT"
assert_not_contains "служба конвертации не опрашивалась" "/capabilities" "$(cat "$WORK/curl.log")"
assert_contains "parallel_files назван" "parallel_files в режиме распознавания игнорируется" "$RUN_OUT"
assert_eq "код 0" "0" "$RUN_RC"

rm -rf "$WORK"
summary
```

Регистрация в `run_tests.sh` и README (`test_28_asr_integration` — «Распознавание речи: сквозной прогон script.sh с моками ffmpeg и curl»; счётчик +1).

- [ ] **Step 2: Прогнать — падает**

Run: `bash tests/ffmpeg/test_28_asr_integration.sh`
Expected: FAIL — script.sh не знает `asr_enabled` и конвертирует (в `ff.log` `-c:v libx264`).

- [ ] **Step 3: Дописать в `ffmpeg/asr_client.sh`**

```bash
# Части и ответы текущего файла — в ASR_RUN_DIR; сам каталог живёт весь прогон.
asr_file_cleanup() {
	[ -n "${ASR_RUN_DIR:-}" ] || return 0
	rm -f "$ASR_RUN_DIR"/part_*.flac "$ASR_RUN_DIR"/resp_*.json "$ASR_RUN_DIR/ffmpeg.err"
}

# --- Один файл (спека §5.2) ---
# rc 0 — файл учтён (ok/fail/skip через put_result); rc 2 — прогон остановлен,
# причина в ASR_STOP_REASON. Формулы имени и подпапки — те же, что у encode_file.
asr_file() {
	local full_path="$1" name="${1##*/}"
	if [ "$dest_inside_source" = "yes" ]; then
		canon_path "$full_path"
		case "$CANON_PATH" in
			"$canon_destination"/*)
				log_msg "SKIP" "внутри каталога назначения (собственный выход): $name"
				put_result "skip"
				return 0 ;;
		esac
	fi
	path_dir "$full_path"
	local rel="$PATH_DIR/"
	rel="${rel:$_src_prefix_len}"
	local stem="${name%.*}"
	[ "$save_old_extension" = "yes" ] && stem="$name"
	local out_dir="${folder_destination}${rel}"
	local out_txt="${out_dir}${stem}.txt" out_json="${out_dir}${stem}.asr.json"

	# Два входа одного прогона не делят один выход: movie.avi и movie.mp4 оба дают
	# movie.txt, и второй затёр бы первый (или «пропустил» бы его как готовый).
	lower_ascii "$out_txt"
	case "$ASR_CLAIMED" in
		*$'\n'"$LOWER_ASCII"$'\n'*)
			log_msg "FAIL" "$name: конфликт выходов — «${stem}.txt» уже занят другим входом (включите save_old_extension = yes либо разнесите файлы)"
			put_result "fail"
			return 0 ;;
	esac
	ASR_CLAIMED="$ASR_CLAIMED$LOWER_ASCII"$'\n'

	if [ "$overwrite_existing" != "yes" ] && [ -f "$out_txt" ]; then
		log_msg "SKIP" "$name: расшифровка уже есть (${stem}.txt)"
		put_result "skip"
		return 0
	fi

	# Длительность и звук — тот же разбор `ffmpeg -i`, что у конвертера.
	parse_media_info "$("$ffmpeg" -nostdin -i "$full_path" 2>&1)"
	if [ -z "$MI_ACODEC" ]; then
		log_msg "FAIL" "$name: нет звуковой дорожки"
		put_result "fail"
		return 0
	fi
	if [ -z "$MI_DUR" ]; then
		log_msg "FAIL" "$name: длительность не читается"
		put_result "fail"
		return 0
	fi
	local h m s
	IFS=: read -r h m s <<< "$MI_DUR"
	asr_plan_parts "$(( 10#$h * 3600 + 10#$m * 60 + 10#$s + 1 ))"
	local -a plan pairs=()
	read -r -a plan <<< "$ASR_PLAN"
	local n=${#plan[@]} i off len part resp t0 started

	if [ "$dry_run" = "yes" ]; then
		asr_hms "$ASR_PLAN_LEN"
		echo "[DRY-RUN] $name: частей $n (по ≈$ASR_HMS) → $out_txt"
		for (( i = 0; i < n; i++ )); do
			off="${plan[i]%%:*}"; len="${plan[i]#*:}"
			printf -v part 'part_%03d.flac' "$i"; printf -v resp 'resp_%03d.json' "$i"
			asr_extract_args "$full_path" "$off" "$len" "$n" "$part"
			echo "[DRY-RUN] $ffmpeg ${ASR_FF_ARGS[*]}"
			asr_curl_args "$ASR_BASE" "$part" "$resp"
			echo "[DRY-RUN] curl ${ASR_CURL_ARGS[*]}"
		done
		return 0
	fi

	[ -d "$out_dir" ] || mkdir -p "$out_dir"
	now_s; started=$NOW_S
	for (( i = 0; i < n; i++ )); do
		off="${plan[i]%%:*}"; len="${plan[i]#*:}"
		printf -v part 'part_%03d.flac' "$i"; printf -v resp 'resp_%03d.json' "$i"
		asr_extract_args "$full_path" "$off" "$len" "$n" "$ASR_RUN_DIR/$part"
		if ! "$ffmpeg" "${ASR_FF_ARGS[@]}" 2>"$ASR_RUN_DIR/ffmpeg.err" || [ ! -s "$ASR_RUN_DIR/$part" ]; then
			log_msg "FAIL" "$name: не удалось извлечь звук (часть $((i + 1))/$n)"
			asr_file_cleanup; put_result "fail"
			return 0
		fi
		if [ -n "$ASR_LIM_MAX_BYTES" ] && [ "$(file_size "$ASR_RUN_DIR/$part")" -gt "$ASR_LIM_MAX_BYTES" ]; then
			log_msg "FAIL" "$name: часть $((i + 1))/$n больше предела сервера ($ASR_LIM_MAX_BYTES байт)"
			asr_file_cleanup; put_result "fail"
			return 0
		fi
		asr_hms "$len"
		log_msg "INFO" "$name: распознавание, часть $((i + 1))/$n ($ASR_HMS записи) — ждём ответ сервера"
		now_s; t0=$NOW_S
		asr_transcribe_part "$part" "$resp"
		case "$ASR_OUTCOME" in
			ok) ;;
			file)
				log_msg "FAIL" "$name: $ASR_REASON"
				asr_file_cleanup; put_result "fail"
				return 0 ;;
			*)
				log_msg "FAIL" "$name: $ASR_REASON"
				ASR_STOP_REASON="$ASR_REASON"
				asr_file_cleanup; put_result "fail"
				return 2 ;;
		esac
		now_s; asr_hms $(( NOW_S - t0 ))
		log_msg "INFO" "$name: часть $((i + 1))/$n распознана за $ASR_HMS"
		rm -f "$ASR_RUN_DIR/$part"
		pairs+=("$ASR_RUN_DIR/$resp" "$off")
	done

	# Публикация: временные имена в каталоге назначения, затем rename; .txt —
	# последним: он маркер готовности, по нему работает пропуск.
	local tmp_json tmp_txt el extra=""
	tmp_json="$(partial_path "$out_json")"; tmp_txt="$(partial_path "$out_txt")"
	asr_now
	if ! asr_write_json "$tmp_json" "${pairs[@]}" \
		|| ! asr_render "$name" "$ASR_NOW" "$ASR_PLAN_LEN" "$tmp_txt" "${pairs[@]}"; then
		log_msg "FAIL" "$name: не удалось собрать расшифровку из ответа сервера"
		rm -f "$tmp_json" "$tmp_txt"; asr_file_cleanup; put_result "fail"
		return 0
	fi
	if mv -f "$tmp_json" "$out_json" 2>/dev/null && mv -f "$tmp_txt" "$out_txt" 2>/dev/null && [ -f "$out_txt" ]; then
		now_s; el=$(( NOW_S - started ))
		[ -n "$ASR_R_BAD" ] && extra=", этапы с ошибкой: $ASR_R_BAD"
		log_msg "OK" "$name -> ${stem}.txt (говорящих: $ASR_R_SPEAKERS, сомнительных сегментов: $ASR_R_LOW$extra) ($((el / 60))m $((el % 60))s)"
		put_result "ok:0:0"
	else
		log_msg "FAIL" "$name: не удалось опубликовать результат (rename)"
		rm -f "$tmp_json" "$tmp_txt"
		put_result "fail"
	fi
	asr_file_cleanup
	return 0
}

# --- Прогон: файлы строго по одному (у сервера один рабочий поток) ---
# Остановка (rc 2) — остальные файлы считаются «не обработано».
asr_run() {
	local full_path stopped="no" rc
	ASR_CLAIMED=$'\n'
	ASR_STOP_REASON=""
	ASR_NOT_PROCESSED=0
	while IFS= read -r -d '' full_path; do
		_any_input="yes"
		if [ "$stopped" = "yes" ]; then
			ASR_NOT_PROCESSED=$((ASR_NOT_PROCESSED + 1))
			continue
		fi
		asr_file "$full_path"; rc=$?
		[ "$rc" -eq 2 ] && stopped="yes"
	done < <(find_inputs | sort_null)
	return 0
}
```

- [ ] **Step 4: `FFmpeg_Converter_script.sh`**

1. После блока подключения `remote_client.sh` (строки 143–145):

```bash
# Распознавание речи — второй модуль того же устройства: только функции.
if [ -f "${_ffconv_script_dir}/asr_client.sh" ]; then
	source "${_ffconv_script_dir}/asr_client.sh"
fi
```

2. В `_cleanup_on_int` перед `exit 130`:
`	[ -n "${ASR_RUN_DIR:-}" ] && rm -rf "$ASR_RUN_DIR"`

3. Перед строкой `# F-modes. Спецрежимы (merge/extract/frame/copy/audio) взаимоисключающи по построению:`:

```bash
# --- Распознавание речи: отдельный режим вместо конвертации ---
# Ни один режим конвертера, ни [remote] здесь не участвуют: файлы не
# перекодируются. Всё, что делает невозможным весь прогон, выясняет
# asr_preflight — ДО первого файла.
asr_active="no"
if [ "${asr_enabled:-no}" = "yes" ]; then
	if ! type asr_preflight >/dev/null 2>&1; then
		echo "[ОШИБКА] [asr] enabled = yes, но рядом со скриптом нет asr_client.sh." >&2
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
	if [ "$parallel_count" -gt 1 ] 2>/dev/null; then
		echo "[ПРЕДУПРЕЖДЕНИЕ] parallel_files в режиме распознавания игнорируется: у сервера один рабочий поток, файлы идут по одному."
		parallel_count=1
	fi
	if [ "$remote_enabled" = "yes" ]; then
		log_msg "INFO" "[remote] в режиме распознавания не используется: конвертации нет"
		remote_enabled="no"
	fi
	if ! asr_preflight; then
		rm -rf "$results_dir"
		pause_prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	fi
	asr_active="yes"
fi

```

4. `if [ "$_n_modes" -gt 1 ]; then` → `if [ "$_n_modes" -gt 1 ] && [ "$asr_active" != "yes" ]; then`

5. `if [ "$merge_files" != "yes" ] && [ "$extract_audio_copy" != "yes" ] && [ "$create_frame" != "yes" ]; then` (карта коллизий) → дописать `&& [ "$asr_active" != "yes" ]` (у ASR своя проверка — `ASR_CLAIMED`).

6. `if [ "$merge_files" = "yes" ]; then` (начало «Основной логики») →

```bash
if [ "$asr_active" = "yes" ]; then
	asr_run
elif [ "$merge_files" = "yes" ]; then
```

7. После `rm -rf "$results_dir"` в сводке: `[ -n "${ASR_RUN_DIR:-}" ] && rm -rf "$ASR_RUN_DIR"`.

8. После строки `echo "  Ошибки:      ${total_fail}"`:

```bash
if [ -n "${ASR_STOP_REASON:-}" ]; then
	echo "  Остановлено: ${ASR_STOP_REASON}"
	echo "  Не обработано: ${ASR_NOT_PROCESSED:-0}"
fi
```

- [ ] **Step 5: Прогнать — зелёный, без регрессий конвертера**

Run: `bash tests/ffmpeg/test_28_asr_integration.sh && bash tests/ffmpeg/test_25_asr_client.sh && bash tests/ffmpeg/test_07_integration.sh && bash tests/ffmpeg/test_15_findings.sh && bash tests/common/test_guardrails.sh`
Expected: все `fail=0`.

- [ ] **Step 6: Commit** — «asr: ветка распознавания в FFmpeg_Converter_script.sh, сквозной тест».

---

### Task 6: `asr_client.ps1`

**Files:**
- Create: `ffmpeg/asr_client.ps1` (UTF-8 с BOM)
- Create: `tests/ffmpeg/test_26_asr_ps1.sh`
- Modify: `tests/run_tests.sh`, `README.md`

**Interfaces:**
- Consumes: переменные `$asr_*`, `$ffmpeg`, `$ffmpeg_available`; из script.ps1 — `Log-Msg`, `Write-GUIProgress`, `Get-RelDir`, `Get-CanonPath`, `Get-FileSize`, `Get-PartialPath`, `New-DirLiteral`, `$folder_destination`, `$save_old_extension`, `$overwrite_existing`, `$dry_run`, счётчики `$script:countOk/Fail/Skip`, `$script:fileNum`; `$script:AsrCancelCheck`, `$script:AsrTick`.
- Produces: `Format-AsrEndpoints`, `ConvertTo-AsrConfigString`, `Get-AsrTlsArgs`, `Get-AsrLimits` → объект `{MaxSeconds, MaxBytes, JobTimeout, Device, Languages, Diarization, Ver}`, `Get-AsrPlan <D> <MaxSeconds> <JobTimeout> <Device>` → `{Parts[], PartLen, Whole}`, `Get-AsrCurlArgs <Base> <Part> <Out>`, `Get-AsrFfArgs <In> <Offset> <Length> <Count> <Out>`, `Format-AsrTs`, `Get-AsrClean`, `Test-AsrConfigValues`, `Resolve-AsrApiKey`, `Get-AsrCurlExe`, `ConvertTo-AsrArgLine`, `Invoke-AsrCurl <Dir> <CurlArgs>` → `{Rc, Code, Err, Cancelled}` (точка подмены в тестах), `Select-AsrEndpoint`, `Get-AsrDetail`, `Get-AsrOutcome <Rc> <Code> <Detail> <CurlErr>` → `{Outcome, Reason}`, `Invoke-AsrTranscribePart <Part> <Resp>`, `Write-AsrJson <Out> <Parts>`, `Write-AsrTranscript <Src> <Date> <PartLen> <Out> <Parts>` → `{Speakers, Low, Bad}`, `Invoke-AsrPreflight` → bool, `Invoke-AsrFile <FileInfo>`, `Invoke-AsrRun <files>`; `$script:AsrBase`, `$script:AsrLimits`, `$script:AsrRunDir`, `$script:AsrStopReason`, `$script:AsrNotProcessed`, `$script:AsrPreflightError`. Части `Parts` — массив `[pscustomobject]@{File; Offset}`.

- [ ] **Step 1: Тест — `tests/ffmpeg/test_26_asr_ps1.sh`**

```bash
#!/bin/bash
# ============================================================
# test_26_asr_ps1.sh — PS1-модуль распознавания (дот-сорсинг настоящего
# asr_client.ps1): те же случаи, что test_25 для .sh, и те же ожидаемые .txt из
# tests/fixtures/asr; плюс настоящий запуск curl.exe и отмена (только Windows).
# Один запуск PowerShell на весь файл: процесс дорог.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "ASR PS1"
    skip "PS1-модуль распознавания" "PowerShell не найден"
    summary
    exit 0
fi

_w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
FIX="$TESTS_DIR/fixtures/asr"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_ps1_XXXXXX")"
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_ps1_" .ps1)"

# Harness ASCII-only: пишется без BOM, а PowerShell 5.1 читает такой файл в ANSI.
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Fix, [string]$Work)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Log-Msg { param([string]$Level, [string]$Msg) Write-Output "LOG=[$Level] $Msg" }
function Write-GUIProgress { param([int]$FilePercent = 0, [string]$CurrentFile = '', [string]$Phase = '') }
. $Module
function J { param([object[]]$A) return ($A -join '|') }

Write-Output ("EP=" + (J @(Format-AsrEndpoints '  https://a.example:30010/  http://b.example:30000//  ')))
Write-Output ("EP_EMPTY=" + @(Format-AsrEndpoints '').Count)

$l = Get-AsrLimits ([System.IO.File]::ReadAllText((Join-Path $Fix 'limits.json')))
Write-Output ("LIM=" + (J @($l.MaxSeconds, $l.MaxBytes, $l.JobTimeout, $l.Device, $l.Diarization, $l.Ver)))
Write-Output ("LANGS=" + $l.Languages)
Write-Output ("LIM_BAD=" + [string]($null -eq (Get-AsrLimits '<html>502</html>')))

foreach ($d in 2999, 3000, 3001, 5400) { Write-Output ("PLAN_cpu_$d=" + ((Get-AsrPlan $d 3600 1800 'cpu').Parts -join ' ')) }
$p = Get-AsrPlan 3001 3600 1800 'cpu'
Write-Output ("PLANLEN=" + $p.PartLen + '|' + $p.Whole)
foreach ($d in 7200, 7201) { Write-Output ("PLAN_cuda_$d=" + ((Get-AsrPlan $d 7200 1800 'cuda').Parts -join ' ')) }

$script:AsrLimits = $l
$asr_language = 'ru'; $asr_diarize = 'yes'; $asr_num_speakers = ''; $asr_pinned_pubkey = ''
Write-Output ("ARGS_NOPIN=" + (J @(Get-AsrCurlArgs 'https://h.example:30010' 'part_000.flac' 'resp_000.json')))
$asr_pinned_pubkey = 'sha256//AAA='
Write-Output ("ARGS_PIN=" + (J @(Get-AsrCurlArgs 'https://h.example:30010' 'part_000.flac' 'resp_000.json')))
Write-Output ("ARGS_HTTP=" + (J @(Get-AsrCurlArgs 'http://h.example:30000' 'part_000.flac' 'resp_000.json')))
$asr_diarize = 'no'; $asr_num_speakers = '4'
Write-Output ("ARGS_N=" + (J @(Get-AsrCurlArgs 'http://h.example:30000' 'part_001.flac' 'resp_001.json')))
Write-Output ("FF=" + (J @(Get-AsrFfArgs '/in/a b.mp4' 1001 999 3 'part_001.flac')))
$asr_diarize = 'yes'; $asr_num_speakers = ''; $asr_pinned_pubkey = ''

foreach ($c in '0|200|', '0|400|bad-lang', '0|413|', '0|401|', '0|500|', '0|504|', '90|000|', '28|000|', '26|000|', '7|000|') {
    $rc, $code, $det = $c.Split('|')
    $o = Get-AsrOutcome ([int]$rc) $code $det 'Failed to connect'
    Write-Output ("CL_${rc}_$code=" + $o.Outcome + '|' + $o.Reason)
}

$cases = @(
    @{ Want = 'basic.txt';   Src = 'meeting.mp4'; Len = 480;  Parts = @(@('basic.json', 0)) },
    @{ Want = 'escapes.txt'; Src = 'escapes.mkv'; Len = 76;   Parts = @(@('escapes.json', 0)) },
    @{ Want = 'chunks.txt';  Src = 'long.mp4';    Len = 1001; Parts = @(@('basic.json', 0), @('escapes.json', 1001)) },
    @{ Want = 'empty.txt';   Src = 'silence.wav'; Len = 10;   Parts = @(@('empty.json', 0)) }
)
foreach ($case in $cases) {
    $parts = @($case.Parts | ForEach-Object { [pscustomobject]@{ File = (Join-Path $Fix $_[0]); Offset = [int64]$_[1] } })
    $s = Write-AsrTranscript $case.Src '2026-10-02 12:00' $case.Len (Join-Path $Work ('ps_' + $case.Want)) $parts
    Write-Output ("SUM_" + $case.Want + "=" + $s.Speakers + '|' + $s.Low + '|' + $s.Bad)
}
$one = [pscustomobject]@{ File = (Join-Path $Fix 'basic.json'); Offset = 0 }
$two = [pscustomobject]@{ File = (Join-Path $Fix 'escapes.json'); Offset = 1001 }
Write-AsrJson (Join-Path $Work 'ps_one.json') @($one)
Write-AsrJson (Join-Path $Work 'ps_two.json') @($one, $two)
try {
    $tw = [System.IO.File]::ReadAllText((Join-Path $Work 'ps_two.json')) | ConvertFrom-Json
    Write-Output ("TWO=" + $tw.chunks.Count + '|' + $tw.chunks[1].offset_seconds)
} catch { Write-Output 'TWO=parse-error' }

$vc = @('https://a:1|ru|yes|', '|ru|yes|', 'ftp://a|ru|yes|', 'https://a:1||yes|', 'https://a:1|ru|maybe|',
        'https://a:1|ru|yes|0', 'https://a:1|ru|yes|51', 'https://a:1|ru|yes|abc', 'https://a:1|ru|yes|1', 'https://a:1|ru|yes|50')
for ($i = 0; $i -lt $vc.Count; $i++) {
    $asr_endpoint, $asr_language, $asr_diarize, $asr_num_speakers = $vc[$i].Split('|')
    $ok = Test-AsrConfigValues
    Write-Output ("VC_$i=" + [int](-not $ok))
}
$asr_endpoint = ''; $asr_language = 'ru'; $asr_diarize = 'yes'; $asr_num_speakers = ''

$script:AsrApiKeyResolved = $false; $asr_api_key = ''; $asr_api_key_command = 'Write-Output "  cmd-key  "'
$r = Resolve-AsrApiKey
Write-Output ("KEYCMD=" + $r + '|' + $asr_api_key)
$asr_api_key_command = ''

# Настоящий Invoke-AsrCurl: поддельный curl (.cmd) и отмена. Только Windows.
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
    $fake = Join-Path $Work 'fakecurl.cmd'
    [System.IO.File]::WriteAllText($fake, "@echo off`r`necho %* > `"%~dp0args.txt`"`r`nfindstr `"^`" > `"%~dp0stdin.txt`"`r`necho 200`r`nexit /b 0`r`n")
    $env:CURL_BIN = $fake
    $asr_api_key = 'k-123'
    $r = Invoke-AsrCurl $Work @('-sS', '-o', 'x.json', '-w', '%{http_code}', 'https://h.example/speech/limits')
    Write-Output ("REAL_RC=" + $r.Rc + '|' + $r.Code)
    Write-Output ("REAL_STDIN=" + ([System.IO.File]::ReadAllText((Join-Path $Work 'stdin.txt'))).Trim())
    Write-Output ("REAL_ARGS=" + ([System.IO.File]::ReadAllText((Join-Path $Work 'args.txt'))).Trim())
    $slow = Join-Path $Work 'slowcurl.cmd'
    [System.IO.File]::WriteAllText($slow, "@echo off`r`nping -n 8 127.0.0.1 >nul`r`necho 200`r`n")
    $env:CURL_BIN = $slow
    $script:AsrCancelCheck = { $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-AsrCurl $Work @('-sS', 'https://h.example/x')
    Write-Output ("CANCEL=" + $r.Cancelled + '|' + [int]($sw.Elapsed.TotalSeconds -lt 5))
    $script:AsrCancelCheck = $null
    Remove-Item Env:CURL_BIN
} else { Write-Output 'REAL=skip' }

# Подменённый Invoke-AsrCurl: выбор адреса и запрос части.
$script:AsrRunDir = $Work
$script:codes = @(); $script:calls = 0; $script:body = ''
function Invoke-AsrCurl {
    param([string]$Dir, [string[]]$CurlArgs)
    $script:calls++
    $url = $CurlArgs[-1]
    if ($url -like 'https://a.example*') { return [pscustomobject]@{ Rc = 7; Code = '000'; Err = 'Failed to connect'; Cancelled = $false } }
    $i = [array]::IndexOf($CurlArgs, '-o')
    $out = Join-Path $Dir $CurlArgs[$i + 1]
    if ($url -like '*/speech/limits') {
        [System.IO.File]::WriteAllText($out, [System.IO.File]::ReadAllText((Join-Path $Fix 'limits.json')))
        return [pscustomobject]@{ Rc = 0; Code = '200'; Err = ''; Cancelled = $false }
    }
    $code = '200'
    if ($script:codes.Count -gt 0) { $code = $script:codes[0]; $script:codes = @($script:codes | Select-Object -Skip 1) }
    [System.IO.File]::WriteAllText($out, $script:body)
    return [pscustomobject]@{ Rc = 0; Code = $code; Err = ''; Cancelled = $false }
}
$asr_endpoint = 'https://a.example:30010 https://b.example:30010'
$ok = Select-AsrEndpoint
Write-Output ("SEL=" + $ok + '|' + $script:AsrBase + '|' + $script:AsrLimits.JobTimeout)
$env:ASR_RETRY_WAIT = '0'
$script:body = [System.IO.File]::ReadAllText((Join-Path $Fix 'basic.json'))
$script:codes = @('503', '503', '200'); $script:calls = 0
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_RETRY=" + $o.Outcome + '|' + $script:calls)
$env:ASR_RETRIES = '2'; $script:codes = @('503', '503', '503', '503'); $script:calls = 0
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_FULL=" + $o.Outcome + '|' + $script:calls)
Remove-Item Env:ASR_RETRIES
$script:body = '<html>gateway</html>'; $script:codes = @('200')
$o = Invoke-AsrTranscribePart 'part_000.flac' 'resp_000.json'
Write-Output ("TP_HTML=" + $o.Outcome + '|' + $o.Reason)
PSEOF

out="$("$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
    -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Fix "$(_w "$FIX")" -Work "$(_w "$WORK")" 2>&1 | tr -d '\r')"
rm -f "$HARNESS"
get_field() { printf '%s\n' "$out" | grep "^${1}=" | head -1 | sed "s/^${1}=//"; }

suite "ASR PS1: адреса и пределы"
assert_eq "два адреса, слэши сняты" "https://a.example:30010|http://b.example:30000" "$(get_field EP)"
assert_eq "пустая строка — ни одного" "0" "$(get_field EP_EMPTY)"
assert_eq "пределы" "3600|524288000|1800|cpu|true|large-v3-turbo.cpu.int8.v1" "$(get_field LIM)"
assert_eq "языки" "en ru" "$(get_field LANGS)"
assert_eq "не пределы — null" "True" "$(get_field LIM_BAD)"

suite "ASR PS1: план частей — те же числа, что в .sh"
assert_eq "2999" "0:2999" "$(get_field PLAN_cpu_2999)"
assert_eq "3000" "0:3000" "$(get_field PLAN_cpu_3000)"
assert_eq "3001" "0:1001 1001:1001 2002:999" "$(get_field PLAN_cpu_3001)"
assert_eq "5400" "0:1350 1350:1350 2700:1350 4050:1350" "$(get_field PLAN_cpu_5400)"
assert_eq "длина и предел" "1001|3000" "$(get_field PLANLEN)"
assert_eq "cuda 7200" "0:7200" "$(get_field PLAN_cuda_7200)"
assert_eq "cuda 7201" "0:2401 2401:2401 4802:2399" "$(get_field PLAN_cuda_7201)"

suite "ASR PS1: аргументы curl и ffmpeg"
assert_eq "https без пина" \
    "-sS|--connect-timeout|10|--max-time|2100|-F|file=@part_000.flac;type=audio/flac|-F|model=whisperx|-F|language=ru|-F|diarize=true|-o|resp_000.json|-w|%{http_code}|https://h.example:30010/speech/transcriptions" \
    "$(get_field ARGS_NOPIN)"
assert_contains "https с пином" "--max-time|2100|-k|--pinnedpubkey|sha256//AAA=|-F" "$(get_field ARGS_PIN)"
assert_not_contains "http — без -k" "|-k|" "$(get_field ARGS_HTTP)"
assert_contains "diarize=false и num_speakers" "-F|diarize=false|-F|num_speakers=4|-o" "$(get_field ARGS_N)"
assert_eq "извлечение части" "-nostdin|-v|error|-y|-ss|1001|-t|999|-i|/in/a b.mp4|-map|0:a:0|-vn|-ac|1|-ar|16000|-c:a|flac|part_001.flac" "$(get_field FF)"

suite "ASR PS1: исходы"
assert_eq "200" "ok|" "$(get_field CL_0_200)"
assert_eq "400" "file|HTTP 400: bad-lang" "$(get_field CL_0_400)"
assert_eq "413" "file|HTTP 413" "$(get_field CL_0_413)"
assert_eq "401" "stop|ключ не принят (HTTP 401)" "$(get_field CL_0_401)"
assert_eq "500" "stop|HTTP 500" "$(get_field CL_0_500)"
assert_contains "504" "stop|сервер не уложился" "$(get_field CL_0_504)"
assert_eq "curl 90" "stop|сертификат сервера не совпал с закреплённым ключом (curl 90)" "$(get_field CL_90_000)"
assert_contains "curl 28" "stop|истёк таймаут" "$(get_field CL_28_000)"
assert_contains "curl 26" "file|curl не смог прочитать" "$(get_field CL_26_000)"
assert_eq "curl 7" "stop|сетевая ошибка (curl 7: Failed to connect)" "$(get_field CL_7_000)"

suite "ASR PS1: текст — те же ожидаемые .txt, что у .sh"
for _f in basic escapes chunks empty; do
    if cmp -s "$FIX/$_f.txt" "$WORK/ps_$_f.txt"; then pass "$_f.txt: байт в байт"
    else fail "$_f.txt: байт в байт" "$(cat "$FIX/$_f.txt")" "$(cat "$WORK/ps_$_f.txt" 2>/dev/null)"; fi
done
assert_eq "сводка basic" "2|1|" "$(get_field SUM_basic.txt)"
assert_eq "сводка chunks" "2,1|2|ч.2: align=unavailable, ч.2: diarize=failed" "$(get_field SUM_chunks.txt)"
assert_eq "одна часть — JSON без изменений" "$(cat "$FIX/basic.json")" "$(cat "$WORK/ps_one.json")"
assert_eq "две части — валидная обёртка" "2|1001" "$(get_field TWO)"

suite "ASR PS1: проверка конфига и ключ из команды"
_want=(0 1 1 1 1 1 1 1 0 0)
for _i in 0 1 2 3 4 5 6 7 8 9; do assert_eq "случай $_i" "${_want[_i]}" "$(get_field "VC_$_i")"; done
assert_eq "api_key_command" "True|cmd-key" "$(get_field KEYCMD)"

suite "ASR PS1: выбор адреса и запрос части (подменённый curl)"
assert_eq "недоступный первый пропущен" "True|https://b.example:30010|1800" "$(get_field SEL)"
assert_eq "два 503 и успех" "ok|3" "$(get_field TP_RETRY)"
assert_eq "503 и после повторов — прогон" "stop|3" "$(get_field TP_FULL)"
assert_eq "200 без segments" "file|сервер ответил 200, но без поля segments" "$(get_field TP_HTML)"

suite "ASR PS1: настоящий запуск curl и отмена"
if [ "$(get_field REAL)" = "skip" ]; then
    skip "запуск curl.exe и отмена" "нужен Windows (поддельный curl — .cmd)"
else
    assert_eq "код и HTTP-код" "0|200" "$(get_field REAL_RC)"
    assert_eq "ключ — заголовком в stdin" 'header = "Authorization: Bearer k-123"' "$(get_field REAL_STDIN)"
    assert_contains "конфиг со stdin" "--config - -sS" "$(get_field REAL_ARGS)"
    assert_not_contains "ключа нет в аргументах" "k-123" "$(get_field REAL_ARGS)"
    assert_eq "отмена убивает curl быстро" "True|1" "$(get_field CANCEL)"
fi

rm -rf "$WORK"
summary
```

Регистрация в `run_tests.sh`/README (`test_26_asr_ps1` — «Распознавание речи: PS1-модуль — те же случаи и фикстуры, запуск curl.exe и отмена»).

- [ ] **Step 2: Прогнать — падает** (`asr_client.ps1` не найден, все поля пусты).

- [ ] **Step 3: Реализация — `ffmpeg/asr_client.ps1`**

```powershell
# ============================================================
# Распознавание речи (ASR) — клиент сервера WhisperX (PowerShell)
#
# Подключается из FFmpeg_Converter_script.ps1; в EXE вклеен в ту же строку
# (build_exe.ps1). Только функции, никаких действий при загрузке: модуль
# дот-сорсится в тест без сети. Двойник asr_client.sh: равенство плана частей,
# аргументов curl, исходов и текста сверяет test_27_asr_parity.sh.
#
# curl.exe, а не HttpWebRequest, как в remote_client.ps1: у сервера
# самоподписанный сертификат, проверка TLS заменена закреплением открытого
# ключа. curl делает это флагом --pinnedpubkey (системный curl.exe 8.x на
# Schannel — тоже); в .NET Framework пришлось бы разбирать DER сертификата
# руками в callback'е проверки, который вдобавок вызывается вне runspace.
#
# Спека: docs/superpowers/specs/2026-10-02-ffmpeg-asr-design.md
# ============================================================

$script:AsrLowConfidence = 0.6
$script:AsrApiKeyResolved = $false
$script:AsrBase = ''
$script:AsrLimits = $null
$script:AsrRunDir = ''
$script:AsrStopReason = ''
$script:AsrPreflightError = ''
$script:AsrNotProcessed = 0
$script:AsrClaimed = @{}

function Format-AsrEndpoints {
	param([string]$Value)
	if (-not $Value) { return @() }
	return @($Value.Trim() -split '\s+' | ForEach-Object { $_.TrimEnd('/') } | Where-Object { $_ })
}

function ConvertTo-AsrConfigString {
	param([string]$Value)
	return $Value.Replace('\', '\\').Replace('"', '\"')
}

# -k только вместе с пином: см. asr_tls_args в .sh. -clike: регистр схемы — как в .sh.
function Get-AsrTlsArgs {
	param([string]$Base)
	if ($Base -clike 'https://*' -and $asr_pinned_pubkey) { return @('-k', '--pinnedpubkey', $asr_pinned_pubkey) }
	return @()
}

function Get-AsrLimits {
	param([string]$Body)
	try { $j = $Body | ConvertFrom-Json } catch { return $null }
	if ($null -eq $j -or $null -eq $j.max_seconds -or $null -eq $j.job_timeout_sec) { return $null }
	return [pscustomobject]@{
		MaxSeconds  = [int64][math]::Truncate([double]$j.max_seconds)
		MaxBytes    = if ($null -ne $j.max_bytes) { [int64][math]::Truncate([double]$j.max_bytes) } else { [int64]0 }
		JobTimeout  = [int64][math]::Truncate([double]$j.job_timeout_sec)
		Device      = [string]$j.device
		Languages   = (@($j.languages | Where-Object { $_ }) -join ' ')
		Diarization = if ($null -ne $j.diarization) { ([string]$j.diarization).ToLowerInvariant() } else { '' }
		Ver         = [string]$j.asr_ver
	}
}

# План частей — спека §6, та же целочисленная формула, что asr_plan_parts.
function Get-AsrPlan {
	param([int64]$Duration, [int64]$MaxSeconds, [int64]$JobTimeout, [string]$Device)
	$lim = if ($Device -eq 'cpu') { [int64][math]::Floor($JobTimeout * 10 / 6) } else { $JobTimeout * 10 }
	$w = [int64][math]::Min($MaxSeconds, $lim)
	if ($Duration -le $w) { return [pscustomobject]@{ Parts = @("0:$Duration"); PartLen = $Duration; Whole = $w } }
	$p = [int64][math]::Floor($w / 2)
	$n = [int64][math]::Ceiling($Duration / $p)
	$l = [int64][math]::Ceiling($Duration / $n)
	$parts = @()
	for ($i = 0; $i -lt $n; $i++) {
		$off = $i * $l
		$len = [int64][math]::Min($l, $Duration - $off)
		if ($len -le 0) { break }
		$parts += "${off}:${len}"
	}
	return [pscustomobject]@{ Parts = $parts; PartLen = $l; Whole = $w }
}

# Порядок — контракт с asr_curl_args (test_27). Часть и ответ — относительными
# именами: curl запускается из каталога прогона (WorkingDirectory).
function Get-AsrCurlArgs {
	param([string]$Base, [string]$Part, [string]$Out)
	$d = if ($asr_diarize) { $asr_diarize } else { 'yes' }
	$diar = if ($d -ceq 'yes') { 'true' } else { 'false' }
	$a = @('-sS', '--connect-timeout', '10', '--max-time', [string]($script:AsrLimits.JobTimeout + 300))
	$a += @(Get-AsrTlsArgs $Base)
	$a += @('-F', "file=@$Part;type=audio/flac", '-F', 'model=whisperx', '-F', "language=$asr_language", '-F', "diarize=$diar")
	if ($asr_num_speakers) { $a += @('-F', "num_speakers=$asr_num_speakers") }
	$a += @('-o', $Out, '-w', '%{http_code}', "$Base/speech/transcriptions")
	return $a
}

function Get-AsrFfArgs {
	param([string]$In, [int64]$Offset, [int64]$Length, [int]$Count, [string]$Out)
	$a = @('-nostdin', '-v', 'error', '-y')
	if ($Count -gt 1) { $a += @('-ss', [string]$Offset, '-t', [string]$Length) }
	$a += @('-i', $In, '-map', '0:a:0', '-vn', '-ac', '1', '-ar', '16000', '-c:a', 'flac', $Out)
	return $a
}

function Format-AsrTs {
	param([double]$Seconds)
	$s = [int64][math]::Truncate($Seconds)
	return ('{0:D2}:{1:D2}:{2:D2}' -f [int64][math]::Truncate($s / 3600), [int64][math]::Truncate(($s % 3600) / 60), [int64]($s % 60))
}

# Только \r \n \t → пробел и обрезка пробелов: .Trim() без аргументов режет и
# NBSP, и текст разошёлся бы с awk-версией.
function Get-AsrClean {
	param([string]$Text)
	if (-not $Text) { return '' }
	return $Text.Replace("`r", ' ').Replace("`n", ' ').Replace("`t", ' ').Trim(' ')
}

function Test-AsrConfigValues {
	$errors = @()
	$eps = @(Format-AsrEndpoints $asr_endpoint)
	if ($eps.Count -eq 0) { $errors += '[asr] endpoint пуст: задайте адрес сервера распознавания (или ${ASR_URL}).' }
	foreach ($e in $eps) { if ($e -cnotmatch '^https?://.') { $errors += "[asr] endpoint: '$e' — адрес должен начинаться с http:// или https://." } }
	if (-not $asr_language) { $errors += '[asr] language пуст: укажите язык записи (ru, en).' }
	$d = if ($asr_diarize) { $asr_diarize } else { 'yes' }
	if ($d -cne 'yes' -and $d -cne 'no') { $errors += "[asr] diarize = '$asr_diarize': ожидается yes или no." }
	if ($asr_num_speakers) {
		if ($asr_num_speakers -notmatch '^[0-9]+$' -or [int64]$asr_num_speakers -lt 1 -or [int64]$asr_num_speakers -gt 50) {
			$errors += "[asr] num_speakers = '$asr_num_speakers': целое от 1 до 50 или пусто."
		}
	}
	foreach ($m in $errors) { Write-Host "[ОШИБКА] $m" }
	if ($errors.Count -gt 0) { $script:AsrPreflightError = $errors[0]; return $false }
	return $true
}

function Resolve-AsrApiKey {
	if (-not $asr_api_key_command) { return $true }
	if ($script:AsrApiKeyResolved) { return $true }
	$global:LASTEXITCODE = 0
	try {
		$out = & ([scriptblock]::Create($asr_api_key_command)) 2>$null
	} catch {
		Write-Host '[ОШИБКА] [asr] api_key_command завершилась с ошибкой — ключ не получен.'
		$script:AsrPreflightError = '[asr] api_key_command завершилась с ошибкой'
		return $false
	}
	if ($LASTEXITCODE -ne 0) {
		Write-Host "[ОШИБКА] [asr] api_key_command завершилась с кодом $LASTEXITCODE — ключ не получен."
		$script:AsrPreflightError = "[asr] api_key_command завершилась с кодом $LASTEXITCODE"
		return $false
	}
	$val = (@($out) | Where-Object { $_ } | Select-Object -First 1)
	if ($val) { $val = ([string]$val).Trim() }
	if (-not $val) {
		Write-Host '[ОШИБКА] [asr] api_key_command ничего не напечатала — ключ не получен.'
		$script:AsrPreflightError = '[asr] api_key_command ничего не напечатала'
		return $false
	}
	$script:asr_api_key = $val
	$script:AsrApiKeyResolved = $true
	return $true
}

# Именно curl.exe: в Windows PowerShell 5.1 `curl` — алиас Invoke-WebRequest.
function Get-AsrCurlExe {
	if ($env:CURL_BIN) { return $env:CURL_BIN }
	foreach ($n in 'curl.exe', 'curl') {
		$c = Get-Command $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($c) { return $c.Source }
	}
	return ''
}

# Та же склейка, что у запуска ffmpeg в FFmpeg_Converter_script.ps1: обратные
# слэши перед кавычкой и в конце аргумента удваиваются.
function ConvertTo-AsrArgLine {
	param([string[]]$Items)
	return (($Items | ForEach-Object {
		if ($_ -eq '' -or $_ -match '[ \t"\\]') {
			$a = [regex]::Replace($_, '(\\*)"', '$1$1\"')
			$a = [regex]::Replace($a, '(\\+)$', '$1$1')
			'"' + $a + '"'
		} else { $_ }
	}) -join ' ')
}

# Единственная точка выхода в сеть — её подменяют тесты. Ключ уходит конфигом
# на stdin, а не аргументом. Запрос молчит до получаса: каждые 0.5 с проверяется
# отмена ($script:AsrCancelCheck — кнопка «Остановить» GUI), раз в 5 с —
# $script:AsrTick (строка прогресса). finally добивает curl при Ctrl+C в CLI:
# CTRL_C в его скрытую консоль не доставляется.
function Invoke-AsrCurl {
	param([string]$Dir, [string[]]$CurlArgs)
	$psi = New-Object System.Diagnostics.ProcessStartInfo
	$psi.FileName = Get-AsrCurlExe
	$psi.Arguments = ConvertTo-AsrArgLine (@('--config', '-') + $CurlArgs)
	$psi.WorkingDirectory = $Dir
	$psi.UseShellExecute = $false
	$psi.RedirectStandardInput = $true
	$psi.RedirectStandardOutput = $true
	$psi.RedirectStandardError = $true
	$psi.CreateNoWindow = $true
	$p = $null; $done = $false
	try {
		$p = [System.Diagnostics.Process]::Start($psi)
		$p.StandardInput.Write('header = "Authorization: Bearer ' + (ConvertTo-AsrConfigString ([string]$asr_api_key)) + '"' + "`n")
		$p.StandardInput.Close()
		$outTask = $p.StandardOutput.ReadToEndAsync()
		$errTask = $p.StandardError.ReadToEndAsync()
		$t0 = [DateTime]::UtcNow; $tick = 0
		while (-not $p.WaitForExit(500)) {
			if ($script:AsrCancelCheck -and (& $script:AsrCancelCheck)) {
				try { $p.Kill() } catch {}
				$done = $true
				return [pscustomobject]@{ Rc = -1; Code = '000'; Err = 'отменено'; Cancelled = $true }
			}
			$el = [int]([DateTime]::UtcNow - $t0).TotalSeconds
			if ($script:AsrTick -and $el -ge $tick + 5) { $tick = $el; & $script:AsrTick $el }
		}
		$p.WaitForExit()
		$done = $true
		$code = ([string]$outTask.Result).Trim()
		if ($code -notmatch '^[0-9]+$') { $code = '000' }
		$err = [string](([string]$errTask.Result -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1))
		return [pscustomobject]@{ Rc = $p.ExitCode; Code = $code; Err = $err; Cancelled = $false }
	} catch {
		$done = $true
		return [pscustomobject]@{ Rc = -2; Code = '000'; Err = $_.Exception.Message; Cancelled = $false }
	} finally {
		if (-not $done -and $p -and -not $p.HasExited) { try { $p.Kill() } catch {} }
	}
}

function Select-AsrEndpoint {
	$tried = @()
	$script:AsrBase = ''; $script:AsrStopReason = ''
	foreach ($u in @(Format-AsrEndpoints $asr_endpoint)) {
		$lim = Join-Path $script:AsrRunDir 'limits.json'
		Remove-Item -LiteralPath $lim -Force -ErrorAction SilentlyContinue
		$r = Invoke-AsrCurl $script:AsrRunDir (@('-sS', '--connect-timeout', '5', '--max-time', '15') + @(Get-AsrTlsArgs $u) + @('-o', 'limits.json', '-w', '%{http_code}', "$u/speech/limits"))
		if ($r.Rc -eq 90) {
			$script:AsrStopReason = "сертификат $u не совпал с закреплённым ключом [asr] pinned_pubkey (curl 90) — соединение оборвано"
			return $false
		}
		if ($r.Code -eq '200') {
			$l = $null
			if (Test-Path -LiteralPath $lim) { $l = Get-AsrLimits ([System.IO.File]::ReadAllText($lim, [System.Text.Encoding]::UTF8)) }
			if ($l) { $script:AsrBase = $u; $script:AsrLimits = $l; return $true }
			$tried += "$u → 200, но ответ не похож на /speech/limits"
		} elseif ($r.Code -eq '401' -or $r.Code -eq '403') {
			$script:AsrStopReason = "${u}: ключ не принят (HTTP $($r.Code)) — проверьте [asr] api_key"
			return $false
		} elseif ($r.Rc -ne 0) {
			$hint = if (($r.Rc -eq 35 -or $r.Rc -eq 60) -and -not $asr_pinned_pubkey) { ' — для самоподписанного сертификата задайте [asr] pinned_pubkey' } else { '' }
			$e = if ($r.Err) { " ($($r.Err))" } else { '' }
			$tried += "$u → curl $($r.Rc)$e$hint"
		} else {
			$tried += "$u → HTTP $($r.Code)"
		}
	}
	$script:AsrStopReason = 'сервер распознавания недоступен: ' + ($tried -join '; ')
	return $false
}

function Get-AsrDetail {
	param([string]$File)
	if (-not $File -or -not (Test-Path -LiteralPath $File)) { return '' }
	try { $j = [System.IO.File]::ReadAllText($File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } catch { return '' }
	if ($j -and $j.detail -is [string]) { return $j.detail }
	return ''
}

# Тексты причин — контракт с asr_classify (test_27).
function Get-AsrOutcome {
	param([int]$Rc, [string]$Code, [string]$Detail, [string]$CurlErr)
	$d = if ($Detail) { ": $Detail" } else { '' }
	if ($Rc -ne 0) {
		if ($Rc -eq 90) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'сертификат сервера не совпал с закреплённым ключом (curl 90)' } }
		if ($Rc -eq 28) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'истёк таймаут ожидания ответа (curl 28); задача на сервере может ещё выполняться' } }
		if ($Rc -eq 26) { return [pscustomobject]@{ Outcome = 'file'; Reason = 'curl не смог прочитать извлечённый звук (curl 26)' } }
		$e = if ($CurlErr) { ": $CurlErr" } else { '' }
		return [pscustomobject]@{ Outcome = 'stop'; Reason = "сетевая ошибка (curl $Rc$e)" }
	}
	switch ($Code) {
		'200' { return [pscustomobject]@{ Outcome = 'ok'; Reason = '' } }
		{ $_ -in '400', '413', '422' } { return [pscustomobject]@{ Outcome = 'file'; Reason = "HTTP $Code$d" } }
		{ $_ -in '401', '403' } { return [pscustomobject]@{ Outcome = 'stop'; Reason = "ключ не принят (HTTP $Code)$d" } }
		'503' { return [pscustomobject]@{ Outcome = 'stop'; Reason = "очередь сервера заполнена (HTTP 503) и после повторов$d" } }
		'504' { return [pscustomobject]@{ Outcome = 'stop'; Reason = "сервер не уложился в свой предел (HTTP 504); задача на сервере продолжает выполняться — повторите позже$d" } }
	}
	return [pscustomobject]@{ Outcome = 'stop'; Reason = "HTTP $Code$d" }
}

function Invoke-AsrTranscribePart {
	param([string]$Part, [string]$Resp)
	$tries = if ($env:ASR_RETRIES) { [int]$env:ASR_RETRIES } else { 5 }
	$wait = if ($env:ASR_RETRY_WAIT) { [int]$env:ASR_RETRY_WAIT } else { 60 }
	$respPath = Join-Path $script:AsrRunDir $Resp
	$try = 1
	while ($true) {
		Remove-Item -LiteralPath $respPath -Force -ErrorAction SilentlyContinue
		$r = Invoke-AsrCurl $script:AsrRunDir @(Get-AsrCurlArgs $script:AsrBase $Part $Resp)
		if ($r.Cancelled) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'отменено пользователем' } }
		if ($r.Rc -eq 0 -and $r.Code -eq '503' -and $try -le $tries) {
			Write-Host "[ПРЕДУПРЕЖДЕНИЕ] Очередь сервера заполнена (HTTP 503) — повтор через $wait с (попытка $try из $tries)."
			for ($s = 0; $s -lt $wait; $s++) {
				if ($script:AsrCancelCheck -and (& $script:AsrCancelCheck)) { return [pscustomobject]@{ Outcome = 'stop'; Reason = 'отменено пользователем' } }
				Start-Sleep -Seconds 1
			}
			$try++
			continue
		}
		break
	}
	$detail = if ($r.Code -ne '200') { Get-AsrDetail $respPath } else { '' }
	$o = Get-AsrOutcome $r.Rc $r.Code $detail $r.Err
	if ($o.Outcome -eq 'ok') {
		$txt = if (Test-Path -LiteralPath $respPath) { [System.IO.File]::ReadAllText($respPath, [System.Text.Encoding]::UTF8) } else { '' }
		if (-not $txt.Contains('"segments"')) { $o = [pscustomobject]@{ Outcome = 'file'; Reason = 'сервер ответил 200, но без поля segments' } }
	}
	return $o
}

function Write-AsrJson {
	param([string]$Out, [object[]]$Parts)
	$utf8 = New-Object System.Text.UTF8Encoding($false)
	if ($Parts.Count -eq 1) { Copy-Item -LiteralPath $Parts[0].File -Destination $Out -Force; return }
	$sb = New-Object System.Text.StringBuilder
	[void]$sb.Append('{"chunks":[')
	for ($i = 0; $i -lt $Parts.Count; $i++) {
		if ($i -gt 0) { [void]$sb.Append(',') }
		[void]$sb.Append('{"offset_seconds":' + $Parts[$i].Offset + ',"response":')
		[void]$sb.Append([System.IO.File]::ReadAllText($Parts[$i].File, $utf8))
		[void]$sb.Append('}')
	}
	[void]$sb.Append("]}`n")
	[System.IO.File]::WriteAllText($Out, $sb.ToString(), $utf8)
}

# Правила шапки и реплик — спека §9.2; обязаны совпадать с awk в asr_client.sh
# байт в байт (общие фикстуры tests/fixtures/asr, test_25/26/27).
function Write-AsrTranscript {
	param([string]$Src, [string]$Date, [int64]$PartLen, [string]$Out, [object[]]$Parts)
	$np = $Parts.Count
	$aud = 0.0; $audOk = $true; $prc = 0.0; $prcOk = $true; $ver = ''
	$bad = New-Object System.Collections.Generic.List[string]
	$warn = New-Object System.Collections.Generic.List[string]
	$reps = New-Object System.Collections.Generic.List[string]
	$spk = New-Object System.Collections.Generic.List[string]
	$low = 0
	$lowList = New-Object System.Collections.Generic.List[string]
	for ($pi = 0; $pi -lt $np; $pi++) {
		$r = [System.IO.File]::ReadAllText($Parts[$pi].File, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
		$off = [double]$Parts[$pi].Offset
		$tag = if ($np -gt 1) { "ч.$($pi + 1): " } else { '' }
		if ($null -ne $r.audio_seconds) { $aud += [double]$r.audio_seconds } else { $audOk = $false }
		if ($null -ne $r.processing_seconds) { $prc += [double]$r.processing_seconds } else { $prcOk = $false }
		if (-not $ver -and $r.asr_ver) { $ver = [string]$r.asr_ver }
		if ($null -ne $r.stages) {
			foreach ($pp in $r.stages.PSObject.Properties) {
				$st = if ($null -ne $pp.Value -and $null -ne $pp.Value.status) { [string]$pp.Value.status } else { '?' }
				if ($st -cne 'ok') { $bad.Add("$tag$($pp.Name)=$st") }
			}
		}
		foreach ($w in @($r.warnings)) { if ($null -ne $w) { $warn.Add($tag + (Get-AsrClean ([string]$w))) } }
		$seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
		$cur = ''; $buf = ''; $t0 = 0.0
		foreach ($seg in @($r.segments)) {
			if ($null -eq $seg) { continue }
			$t = Get-AsrClean ([string]$seg.text)
			if (-not $t) { continue }
			$sp = if ($null -ne $seg.speaker -and [string]$seg.speaker -ne '') { [string]$seg.speaker } else { 'SPEAKER_?' }
			if ($sp -cne 'SPEAKER_?') { [void]$seen.Add($sp) }
			$start = if ($null -ne $seg.start) { [double]$seg.start } else { 0.0 }
			$st = $start + $off
			if ($null -ne $seg.confidence -and [double]$seg.confidence -lt $script:AsrLowConfidence) {
				$low++
				if ($lowList.Count -lt 3) { $lowList.Add((Format-AsrTs $st)) }
			}
			if ($buf -ne '' -and $sp -cne $cur) { $reps.Add("[$(Format-AsrTs $t0)] ${cur}: $buf"); $buf = '' }
			if ($buf -eq '') { $cur = $sp; $t0 = $st; $buf = $t } else { $buf = "$buf $t" }
		}
		if ($buf -ne '') { $reps.Add("[$(Format-AsrTs $t0)] ${cur}: $buf") }
		$spk.Add([string]$seen.Count)
	}
	$lines = New-Object System.Collections.Generic.List[string]
	$lines.Add("# Расшифровка: $Src")
	$lines.Add("# Дата: $Date")
	$lines.Add('# Модель: ' + $(if ($ver) { $ver } else { '?' }))
	$audS = if ($audOk) { Format-AsrTs $aud } else { '?' }
	$prcS = if ($prcOk) { Format-AsrTs $prc } else { '?' }
	$lines.Add("# Длительность записи: $audS, обработка: $prcS")
	if ($np -eq 1) {
		$lines.Add("# Говорящих: $($spk[0])")
	} else {
		$lines.Add('# Говорящих по частям: ' + ($spk -join ', '))
		$lines.Add("# Частей: $np по ≈$(Format-AsrTs $PartLen) — метки говорящих в разных частях независимы")
	}
	$lowTail = if ($low -gt 0) { '; первые: ' + ($lowList -join ', ') } else { '' }
	$lines.Add("# Сомнительных сегментов (confidence < 0.6): $low$lowTail")
	if ($bad.Count -gt 0) { $lines.Add('# Этапы с ошибкой: ' + ($bad -join ', ')) }
	foreach ($w in $warn) { $lines.Add("# Предупреждение: $w") }
	$lines.Add('')
	foreach ($x in $reps) { $lines.Add($x) }
	[System.IO.File]::WriteAllText($Out, (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
	return [pscustomobject]@{ Speakers = ($spk -join ','); Low = $low; Bad = ($bad -join ', ') }
}

function Remove-AsrRunDir {
	if ($script:AsrRunDir -and (Test-Path -LiteralPath $script:AsrRunDir)) {
		Remove-Item -LiteralPath $script:AsrRunDir -Recurse -Force -ErrorAction SilentlyContinue
	}
	$script:AsrRunDir = ''
}

function Set-AsrPreflightError {
	param([string]$Message)
	Write-Host "[ОШИБКА] $Message"
	$script:AsrPreflightError = $Message
	return $false
}

function Invoke-AsrPreflight {
	$script:AsrPreflightError = ''
	if (-not (Test-AsrConfigValues)) { return $false }
	if (-not $ffmpeg_available) { return (Set-AsrPreflightError "Распознавание речи требует локального ffmpeg: им извлекается звук ($ffmpeg не найден).") }
	if (-not (Get-AsrCurlExe)) { return (Set-AsrPreflightError 'curl не найден — распознавание речи невозможно.') }
	if (-not (Resolve-AsrApiKey)) { return $false }
	if (-not $asr_api_key) { return (Set-AsrPreflightError '[asr] ключ не задан: api_key, api_key_command или ${ASR_API_KEY}.') }
	$script:AsrRunDir = Join-Path ([System.IO.Path]::GetTempPath()) ('ffconv_asr_' + [guid]::NewGuid().ToString('N'))
	New-Item -ItemType Directory -Path $script:AsrRunDir -Force | Out-Null
	if (-not (Select-AsrEndpoint)) { Remove-AsrRunDir; return (Set-AsrPreflightError $script:AsrStopReason) }
	$langs = $script:AsrLimits.Languages
	if ($langs -and (" $langs " -cnotlike "* $asr_language *")) {
		Remove-AsrRunDir
		return (Set-AsrPreflightError "[asr] language = '$asr_language': сервер его не принимает (доступны: $langs).")
	}
	if ($script:AsrBase -clike 'http://*') { Write-Host "[ПРЕДУПРЕЖДЕНИЕ] $($script:AsrBase) — открытый http: ключ и звук идут по сети незашифрованными." }
	if ($asr_diarize -ne 'no' -and $script:AsrLimits.Diarization -eq 'false') { Write-Host '[ПРЕДУПРЕЖДЕНИЕ] Сервер сообщает diarization = false: говорящих в расшифровке может не быть.' }
	$script:AsrStopReason = ''
	$l = $script:AsrLimits
	$whole = (Get-AsrPlan 0 $l.MaxSeconds $l.JobTimeout $l.Device).Whole
	$ver = if ($l.Ver) { $l.Ver } else { '?' }
	$dev = if ($l.Device) { $l.Device } else { '?' }
	Log-Msg 'INFO' "Распознавание речи: $($script:AsrBase) ($ver, $dev); целиком — до $whole с, длиннее — равными частями"
	return $true
}

function Clear-AsrFileTemp {
	if (-not $script:AsrRunDir) { return }
	Get-ChildItem -LiteralPath $script:AsrRunDir -File -ErrorAction SilentlyContinue |
		Where-Object { $_.Name -like 'part_*.flac' -or $_.Name -like 'resp_*.json' } |
		Remove-Item -Force -ErrorAction SilentlyContinue
}

function Write-AsrFileFail {
	param([string]$Name, [string]$Reason)
	Log-Msg 'FAIL' "${Name}: $Reason"
	$script:anyFail = $true
	$script:countFail++
	Write-GUIProgress -CurrentFile $Name
}

function Invoke-AsrFile {
	param([System.IO.FileInfo]$File)
	$name = $File.Name
	$script:fileNum++
	$stem = if ($save_old_extension -eq 'yes') { $File.Name } else { $File.BaseName }
	$outDir = "$folder_destination$(Get-RelDir $File.DirectoryName)"
	$outTxt = "$outDir$stem.txt"; $outJson = "$outDir$stem.asr.json"
	$claim = (Get-CanonPath $outTxt).ToLowerInvariant()
	if ($script:AsrClaimed.ContainsKey($claim)) {
		Write-AsrFileFail $name "конфликт выходов — «$stem.txt» уже занят другим входом (включите save_old_extension = yes либо разнесите файлы)"
		return
	}
	$script:AsrClaimed[$claim] = $true
	if ($overwrite_existing -ne 'yes' -and (Test-Path -LiteralPath $outTxt)) {
		Log-Msg 'SKIP' "${name}: расшифровка уже есть ($stem.txt)"
		$script:countSkip++
		Write-GUIProgress -CurrentFile $name
		return
	}
	$info = ((& $ffmpeg -nostdin -i $File.FullName 2>&1 | ForEach-Object { "$_" }) -join "`n")
	if ($info -notmatch 'Stream #.*Audio:') { Write-AsrFileFail $name 'нет звуковой дорожки'; return }
	$m = [regex]::Match($info, 'Duration:\s+(\d+):(\d+):(\d+)')
	if (-not $m.Success) { Write-AsrFileFail $name 'длительность не читается'; return }
	$dur = [int64]$m.Groups[1].Value * 3600 + [int64]$m.Groups[2].Value * 60 + [int64]$m.Groups[3].Value + 1
	$lim = $script:AsrLimits
	$plan = Get-AsrPlan $dur $lim.MaxSeconds $lim.JobTimeout $lim.Device
	$n = $plan.Parts.Count
	if ($dry_run -eq 'yes') {
		Write-Host "[DRY-RUN] ${name}: частей $n (по ≈$(Format-AsrTs $plan.PartLen)) → $outTxt"
		for ($i = 0; $i -lt $n; $i++) {
			$off, $len = $plan.Parts[$i].Split(':')
			$part = 'part_{0:D3}.flac' -f $i; $resp = 'resp_{0:D3}.json' -f $i
			Write-Host "[DRY-RUN] $ffmpeg $((Get-AsrFfArgs $File.FullName $off $len $n $part) -join ' ')"
			Write-Host "[DRY-RUN] curl $((Get-AsrCurlArgs $script:AsrBase $part $resp) -join ' ')"
		}
		return
	}
	New-DirLiteral $outDir
	$started = Get-Date
	$pairs = @()
	for ($i = 0; $i -lt $n; $i++) {
		$off, $len = $plan.Parts[$i].Split(':')
		$part = 'part_{0:D3}.flac' -f $i; $resp = 'resp_{0:D3}.json' -f $i
		$partPath = Join-Path $script:AsrRunDir $part
		$ffArgs = @(Get-AsrFfArgs $File.FullName $off $len $n $partPath)
		& $ffmpeg @ffArgs 2>&1 | Out-Null
		if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $partPath) -or (Get-FileSize $partPath) -le 0) {
			Clear-AsrFileTemp; Write-AsrFileFail $name "не удалось извлечь звук (часть $($i + 1)/$n)"; return
		}
		if ($lim.MaxBytes -gt 0 -and (Get-FileSize $partPath) -gt $lim.MaxBytes) {
			Clear-AsrFileTemp; Write-AsrFileFail $name "часть $($i + 1)/$n больше предела сервера ($($lim.MaxBytes) байт)"; return
		}
		Log-Msg 'INFO' "${name}: распознавание, часть $($i + 1)/$n ($(Format-AsrTs $len) записи) — ждём ответ сервера"
		$script:AsrTickFile = $name
		$script:AsrTickPercent = [int]($i * 100 / $n)
		$script:AsrTickPhase = "распознавание, часть $($i + 1)/$n"
		Write-GUIProgress -FilePercent $script:AsrTickPercent -CurrentFile $name -Phase $script:AsrTickPhase
		$t0 = Get-Date
		$o = Invoke-AsrTranscribePart $part $resp
		if ($o.Outcome -ne 'ok') {
			Clear-AsrFileTemp
			if ($o.Outcome -eq 'stop') { $script:AsrStopReason = $o.Reason }
			Write-AsrFileFail $name $o.Reason
			return
		}
		Log-Msg 'INFO' "${name}: часть $($i + 1)/$n распознана за $(Format-AsrTs ((Get-Date) - $t0).TotalSeconds)"
		Remove-Item -LiteralPath $partPath -Force -ErrorAction SilentlyContinue
		$pairs += [pscustomobject]@{ File = (Join-Path $script:AsrRunDir $resp); Offset = [int64]$off }
	}
	$tmpJson = Get-PartialPath $outJson; $tmpTxt = Get-PartialPath $outTxt
	$date = if ($env:FFCONV_ASR_NOW) { $env:FFCONV_ASR_NOW } else { Get-Date -Format 'yyyy-MM-dd HH:mm' }
	try {
		Write-AsrJson $tmpJson $pairs
		$sum = Write-AsrTranscript $name $date $plan.PartLen $tmpTxt $pairs
	} catch {
		Remove-Item -LiteralPath $tmpJson, $tmpTxt -Force -ErrorAction SilentlyContinue
		Clear-AsrFileTemp
		Write-AsrFileFail $name "не удалось собрать расшифровку из ответа сервера: $($_.Exception.Message)"
		return
	}
	try {
		Move-Item -LiteralPath $tmpJson -Destination $outJson -Force -ErrorAction Stop
		Move-Item -LiteralPath $tmpTxt -Destination $outTxt -Force -ErrorAction Stop
	} catch {
		Remove-Item -LiteralPath $tmpJson, $tmpTxt -Force -ErrorAction SilentlyContinue
		Clear-AsrFileTemp
		Write-AsrFileFail $name 'не удалось опубликовать результат (rename)'
		return
	}
	Clear-AsrFileTemp
	$el = (Get-Date) - $started
	$extra = if ($sum.Bad) { ", этапы с ошибкой: $($sum.Bad)" } else { '' }
	Log-Msg 'OK' ("{0} -> {1}.txt (говорящих: {2}, сомнительных сегментов: {3}{4}) ({5}m {6}s)" -f $name, $stem, $sum.Speakers, $sum.Low, $extra, [int][math]::Floor($el.TotalMinutes), $el.Seconds)
	$script:countOk++
	Write-GUIProgress -FilePercent 100 -CurrentFile $name
}

function Invoke-AsrRun {
	param([object[]]$Files)
	$script:AsrClaimed = @{}
	$script:AsrStopReason = ''
	$script:AsrNotProcessed = 0
	try {
		foreach ($f in @($Files | Sort-Object FullName)) {
			if (-not $script:AsrStopReason -and $script:AsrCancelCheck -and (& $script:AsrCancelCheck)) { $script:AsrStopReason = 'отменено пользователем' }
			if ($script:AsrStopReason) { $script:AsrNotProcessed++; continue }
			Invoke-AsrFile $f
		}
	} finally {
		Remove-AsrRunDir
	}
}
```

После записи — BOM: `"/c/Program Files/Python314/python" -c "f=r'c:/AI/projects/video/ffmpeg/asr_client.ps1';b=open(f,'rb').read();open(f,'wb').write(b'\xef\xbb\xbf'+b) if not b.startswith(b'\xef\xbb\xbf') else None"`.

- [ ] **Step 4: Прогнать — зелёный**

Run: `bash tests/ffmpeg/test_26_asr_ps1.sh && bash tests/common/test_encoding.sh`
Expected: `fail=0`. При расхождении `.txt` — сравнить `cmp -l` и `od -c` (чаще всего: `[int64]` с банковским округлением вместо `Truncate`, `.Trim()` без аргументов, регистр в `-eq`).

- [ ] **Step 5: Commit** — «asr: клиент .ps1 — curl.exe с пином, тот же текст, что у .sh; отмена из GUI».

---

### Task 7: Паритет .sh ↔ .ps1

**Files:**
- Create: `tests/ffmpeg/test_27_asr_parity.sh`
- Modify: `tests/run_tests.sh`, `README.md`

**Interfaces:**
- Consumes: функции Task 3–4 и Task 6 с теми же именами и смыслом.

- [ ] **Step 1: Тест — `tests/ffmpeg/test_27_asr_parity.sh`**

```bash
#!/bin/bash
# shellcheck disable=SC2034
# ============================================================
# test_27_asr_parity.sh — .sh и .ps1 считают одинаково: план частей на сетке
# длительностей и пределов, аргументы curl, исходы и текст расшифровки
# (включая синтетический ответ на 2000 сегментов). Обе стороны печатают строки
# KEY=VALUE в файлы, сравнение — одним diff.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"
source "$PROJECT_DIR/ffmpeg/asr_client.sh"

PS_BIN=""
for _c in powershell.exe powershell pwsh; do
    command -v "$_c" >/dev/null 2>&1 && PS_BIN="$_c" && break
done
if [ -z "$PS_BIN" ]; then
    suite "ASR: паритет .sh ↔ .ps1"
    skip "паритет" "PowerShell не найден"
    summary
    exit 0
fi

_w() { cygpath -w "$1" 2>/dev/null || echo "$1"; }
FIX="$TESTS_DIR/fixtures/asr"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test_asr_par_XXXXXX")"
DURS="1 59 2999 3000 3001 4500 5999 6000 6001 9000 10801 36001"
LIMS="3600,1800,cpu 7200,1800,cuda 3600,600,cpu 1000,1800,cpu"
CLS="0:200 0:400 0:413 0:422 0:401 0:403 0:500 0:502 0:503 0:504 90:000 28:000 26:000 7:000 6:000"

# Синтетический большой ответ — общий вход обеих сторон.
{
    printf '{"asr_ver":"x","segments":['
    for (( _i = 0; _i < 2000; _i++ )); do
        [ "$_i" -gt 0 ] && printf ','
        printf '{"start":%d.25,"end":%d.9,"text":" r%d \\u0434 \\"q\\"","speaker":"SPEAKER_0%d","confidence":0.%d,"words":[]}' \
            "$_i" "$_i" "$_i" $(( _i % 3 )) $(( _i % 10 ))
    done
    printf '],"stages":{"transcribe":{"status":"ok"},"diarize":{"status":"failed"}},"warnings":["w"],"audio_seconds":2000.5,"processing_seconds":999.9}'
} > "$WORK/big.json"

# ── .sh ──
{
    for _l in $LIMS; do
        IFS=, read -r ASR_LIM_MAX_SECONDS ASR_LIM_JOB_TIMEOUT ASR_LIM_DEVICE <<< "$_l"
        for _d in $DURS; do asr_plan_parts "$_d"; echo "PLAN_${_l}_${_d}=$ASR_PLAN|$ASR_PLAN_LEN|$ASR_PLAN_WHOLE"; done
    done
    ASR_LIM_JOB_TIMEOUT=1800
    for _combo in "https://h:1,,yes," "https://h:1,sha256//P=,yes," "http://h:2,sha256//P=,no,7"; do
        IFS=, read -r _b asr_pinned_pubkey asr_diarize asr_num_speakers <<< "$_combo"
        asr_language="ru"
        asr_curl_args "$_b" "part_000.flac" "resp_000.json"
        _IFS="$IFS"; IFS='|'; echo "ARGS_${_combo}=${ASR_CURL_ARGS[*]}"; IFS="$_IFS"
    done
    ASR_CURL_ERR="boom"
    for _c in $CLS; do asr_classify "${_c%%:*}" "${_c#*:}" ""; echo "CL_${_c}=$ASR_OUTCOME|$ASR_REASON"; done
    for _e in "  https://a:1/ http://b:2// " "https://only"; do
        asr_split_endpoints "$_e"; _IFS="$IFS"; IFS='|'; echo "EP_${_e}=${ASR_ENDPOINTS[*]}"; IFS="$_IFS"
    done
} > "$WORK/sh.txt"
asr_render "big.mp4" "2026-10-02 12:00" 1500 "$WORK/sh_big.txt" "$WORK/big.json" 0 "$WORK/big.json" 1500

# ── .ps1 ── (harness ASCII-only)
HARNESS="$(mktemp_suffix "${TMPDIR:-/tmp}/asr_par_" .ps1)"
cat > "$HARNESS" <<'PSEOF'
param([string]$Module, [string]$Work, [string]$Durs, [string]$Lims, [string]$Cls)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
function Log-Msg { param($L, $M) }
. $Module
$lines = New-Object System.Collections.Generic.List[string]
foreach ($l in $Lims.Split(' ')) {
    $ms, $jt, $dev = $l.Split(',')
    foreach ($d in $Durs.Split(' ')) {
        $p = Get-AsrPlan ([int64]$d) ([int64]$ms) ([int64]$jt) $dev
        $lines.Add("PLAN_${l}_${d}=" + ($p.Parts -join ' ') + '|' + $p.PartLen + '|' + $p.Whole)
    }
}
$script:AsrLimits = [pscustomobject]@{ JobTimeout = [int64]1800 }
foreach ($combo in 'https://h:1,,yes,', 'https://h:1,sha256//P=,yes,', 'http://h:2,sha256//P=,no,7') {
    $b, $asr_pinned_pubkey, $asr_diarize, $asr_num_speakers = $combo.Split(',')
    $asr_language = 'ru'
    $lines.Add("ARGS_${combo}=" + ((Get-AsrCurlArgs $b 'part_000.flac' 'resp_000.json') -join '|'))
}
foreach ($c in $Cls.Split(' ')) {
    $rc, $code = $c.Split(':')
    $o = Get-AsrOutcome ([int]$rc) $code '' 'boom'
    $lines.Add("CL_${c}=" + $o.Outcome + '|' + $o.Reason)
}
foreach ($e in '  https://a:1/ http://b:2// ', 'https://only') { $lines.Add("EP_${e}=" + (@(Format-AsrEndpoints $e) -join '|')) }
[System.IO.File]::WriteAllText((Join-Path $Work 'ps.txt'), (($lines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
$big = Join-Path $Work 'big.json'
$parts = @([pscustomobject]@{ File = $big; Offset = 0 }, [pscustomobject]@{ File = $big; Offset = 1500 })
$null = Write-AsrTranscript 'big.mp4' '2026-10-02 12:00' 1500 (Join-Path $Work 'ps_big.txt') $parts
PSEOF
"$PS_BIN" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$(_w "$HARNESS")" \
    -Module "$(_w "$PROJECT_DIR/ffmpeg/asr_client.ps1")" -Work "$(_w "$WORK")" \
    -Durs "$DURS" -Lims "$LIMS" -Cls "$CLS" >/dev/null 2>&1
rm -f "$HARNESS"

suite "ASR: паритет .sh ↔ .ps1"
assert_not_empty "PS1 отработал" "$(cat "$WORK/ps.txt" 2>/dev/null)"
assert_empty "план, аргументы curl, исходы, адреса совпадают" "$(diff "$WORK/sh.txt" "$WORK/ps.txt")"
if cmp -s "$WORK/sh_big.txt" "$WORK/ps_big.txt"; then pass "2000 сегментов × 2 части: текст байт в байт"
else fail "2000 сегментов × 2 части: текст байт в байт" "совпадение" "$(diff "$WORK/sh_big.txt" "$WORK/ps_big.txt" | head -5)"; fi

rm -rf "$WORK"
summary
```

Регистрация в `run_tests.sh`/README (`test_27_asr_parity` — «Распознавание речи: .sh и .ps1 дают одинаковые план частей, аргументы curl, исходы и текст»).

- [ ] **Step 2: Прогнать**

Run: `bash tests/ffmpeg/test_27_asr_parity.sh`
Expected: `fail=0`. Если расходится — смотреть `diff` из сообщения; правится та платформа, что отходит от спеки, а не тест.

- [ ] **Step 3: Commit** — «asr: паритет .sh ↔ .ps1 — план, curl, исходы, текст».

---

### Task 8: Ветка ASR в `FFmpeg_Converter_script.ps1` и GUI-путь воркера

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_script.ps1:599-603, 617, 846, 1691, 1695, 1753, 1855, 1878-1879`
- Modify: `tests/ffmpeg/test_24_gui_worker_runspace.sh`

**Interfaces:**
- Consumes: всё из Task 6.
- Produces: `$asr_active` в script.ps1; `$script:AsrCancelCheck`, `$script:AsrTick`.

- [ ] **Step 1: Тест — режим `asr` в `test_24`**

В статическом suite «GUI-путь: контракт в исходниках» добавить:
`assert_contains "модуль ASR подключается по отсутствию функции" 'Get-Command Invoke-AsrRun' "$worker_src"`.

В harness (`cat > "$HARNESS" <<'PSEOF'`): после блока `if ($EmbedRemote) { … }` добавить:

```powershell
if ($Mode -eq 'asr') {
    # EXE layout plus a fake network: the module and an Invoke-AsrCurl override are
    # glued in front of the worker, so the worker does not dot-source the module.
    $asr = [System.IO.File]::ReadAllText((Join-Path $AppDir 'asr_client.ps1'), [System.Text.Encoding]::UTF8)
    $override = @'
function Invoke-AsrCurl {
    param([string]$Dir, [string[]]$CurlArgs)
    $i = [array]::IndexOf($CurlArgs, '-o')
    $out = Join-Path $Dir $CurlArgs[$i + 1]
    if ($CurlArgs[-1] -like '*/speech/limits') {
        $body = '{"max_seconds":3600.0,"max_bytes":524288000,"languages":["en","ru"],"device":"cpu","job_timeout_sec":1800.0,"diarization":true,"asr_ver":"mock"}'
    } else {
        $body = '{"asr_ver":"mock","segments":[{"start":0.5,"end":1.0,"text":" test","speaker":"SPEAKER_00","confidence":0.9}],"stages":{"transcribe":{"status":"ok"}},"warnings":[],"audio_seconds":60.0,"processing_seconds":3.0}'
    }
    [System.IO.File]::WriteAllText($out, $body)
    return [pscustomobject]@{ Rc = 0; Code = '200'; Err = ''; Cancelled = $false }
}
'@
    $script = $asr + "`n" + $override + "`n" + $script
}
```

В `$vars` дописать: `asr_enabled = 'no'; asr_endpoint = ''; asr_api_key = ''; asr_api_key_command = ''; asr_pinned_pubkey = ''; asr_language = 'ru'; asr_diarize = 'yes'; asr_num_speakers = ''`; в `switch ($Mode)` — `'asr' { $vars.asr_enabled = 'yes'; $vars.asr_endpoint = 'https://asr.example:30010'; $vars.asr_api_key = 'k' }`. После строки `Write-Output ("STATE=" + $state)` добавить:

```powershell
$asrTxt = Join-Path $Work 'out\clip.txt'
if (Test-Path -LiteralPath $asrTxt) { Write-Output ("ASRLINE=" + ([System.IO.File]::ReadAllLines($asrTxt))[-1]) }
```

После suite «раскладка EXE» добавить:

```bash
# ══════════════════════════════════════════════════════════════
suite "GUI-путь: режим распознавания речи (модуль вклеен, сеть подменена)"
# ══════════════════════════════════════════════════════════════
out=$(run_mode "asr" "")
assert_eq "ASR: state=success"      "success" "$(get_field "$out" STATE)"
assert_eq "ASR: Streams.Error пуст" "0"       "$(get_field "$out" ERRCOUNT)"
assert_eq "ASR: расшифровка собрана" "[00:00:00] SPEAKER_00: test" "$(get_field "$out" ASRLINE)"
```

- [ ] **Step 2: Прогнать — падает** (`ASRLINE` пуст, воркер конвертирует).

Run: `bash tests/ffmpeg/test_24_gui_worker_runspace.sh`

- [ ] **Step 3: `FFmpeg_Converter_script.ps1`**

1. После блока подключения `remote_client.ps1` (строки 599–603):

```powershell
# Распознавание речи — второй модуль того же устройства и по тем же правилам:
# каталог из $guiAppDir, в EXE функции уже вклеены (проверка по объявленной функции).
if (-not (Get-Command Invoke-AsrRun -ErrorAction SilentlyContinue)) {
	$_appRoot = if ($guiAppDir) { $guiAppDir } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
	$_asrModule = Join-Path $_appRoot 'asr_client.ps1'
	if (Test-Path -LiteralPath $_asrModule) { . $_asrModule }
}
```

2. После `$script:RemoteCancelCheck = { … }`:

```powershell
# Распознавание: запрос молчит до получаса — модулю отдаём проверку отмены и
# «тик» для строки прогресса GUI (раз в 5 с: «ждём сервер мм:сс»).
$script:AsrCancelCheck = { [bool]($guiCancelFile -and (Test-Path -LiteralPath $guiCancelFile)) }
$script:AsrTick = {
	param([int]$Elapsed)
	if ($guiProgressFile) {
		Write-GUIProgress -FilePercent $script:AsrTickPercent -CurrentFile $script:AsrTickFile -Phase ("{0}, ждём сервер {1}" -f $script:AsrTickPhase, (Format-AsrTs $Elapsed))
	}
}
```

3. Карта коллизий: `if ($merge_files -ne "yes" -and $extract_audio_copy -ne "yes" -and $create_frame -ne "yes") {` → дописать `-and $asr_enabled -ne 'yes'`.

4. F-modes: `if ($_activeModes.Count -gt 1) {` → `if ($_activeModes.Count -gt 1 -and $asr_enabled -ne 'yes') {`.

5. Перед `# --- Удалённый бэкенд: включён ли он для ЭТОГО прогона ---`:

```powershell
# --- Распознавание речи: отдельный режим вместо конвертации ---
$asr_active = 'no'
if ($asr_enabled -eq 'yes') {
	if (-not (Get-Command Invoke-AsrPreflight -ErrorAction SilentlyContinue)) {
		Write-Host "[ОШИБКА] [asr] enabled = yes, но рядом со скриптом нет asr_client.ps1."
		Write-GUIProgress -FilePercent 100 -CurrentFile "Ошибка" -State "failed" -ExitCode 1 -Message "Нет модуля asr_client.ps1"
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	if ($remote_enabled -eq 'yes') {
		Log-Msg "INFO" "[remote] в режиме распознавания не используется: конвертации нет"
		$remote_enabled = 'no'
	}
	if (-not (Invoke-AsrPreflight)) {
		Write-GUIProgress -FilePercent 100 -CurrentFile "Ошибка" -State "failed" -ExitCode 1 -Message $script:AsrPreflightError
		Pause-Prompt "Нажмите [Enter], чтобы выйти..."
		exit 1
	}
	$asr_active = 'yes'
}

```

6. «Основная логика»: `if ($merge_files -eq "yes") {` → `if ($asr_active -eq 'yes') {` + `	Invoke-AsrRun $format_files_in_list` + `} elseif ($merge_files -eq "yes") {`.

7. Сводка CLI: после `Write-Host ("  Ошибки:      {0}" -f $script:countFail)`:

```powershell
	if ($script:AsrStopReason) {
		Write-Host ("  Остановлено: {0}" -f $script:AsrStopReason)
		Write-Host ("  Не обработано: {0}" -f $script:AsrNotProcessed)
	}
```

8. Сводка GUI: ветку `} elseif ($script:countFail -gt 0) {` заменить на:

```powershell
	} elseif ($script:countFail -gt 0) {
		$_failMsg = if ($script:AsrStopReason) { "Остановлено: $($script:AsrStopReason)" } else { "Файлов с ошибками: $($script:countFail)" }
		Write-GUIProgress -FilePercent 100 -CurrentFile "Ошибки" -State "failed" -ExitCode 1 -Message $_failMsg
```

После правки — BOM (Python-сниппет из Task 6).

- [ ] **Step 4: Прогнать — зелёный, без регрессий**

Run: `bash tests/ffmpeg/test_24_gui_worker_runspace.sh && bash tests/ffmpeg/test_16_gui_state.sh && bash tests/ffmpeg/test_08_ps1_audio_video.sh && bash tests/common/test_guardrails.sh && bash tests/common/test_encoding.sh`
Expected: `fail=0`.

- [ ] **Step 5: Commit** — «asr: ветка распознавания в FFmpeg_Converter_script.ps1; GUI-путь воркера».

---

### Task 9: GUI, сборка EXE и зависимости выпуска

**Files:**
- Modify: `ffmpeg/FFmpeg_Converter_run_win_v19.ps1:105, 187-197, 212, 229, 1214-1217, 1304, 1356-1376, 1388, 1563, 1585, 1597, 1678-1694`
- Modify: `ffmpeg/build_exe.ps1:20-25`, `tools/check_release.ps1:29-32`
- Modify: `tests/ffmpeg/test_16_gui_state.sh`, `tests/common/test_build_strip.sh:40-43,81-86,145-148`, `tests/common/test_guardrails.sh:626,725`

- [ ] **Step 1: Тесты (падают)**

`test_16_gui_state.sh` перед `summary`:

```bash
suite "GUI: группа «Распознавание речи (ASR)»"
assert_contains "галка режима"               'chkAsr'               "$gui_text"
assert_contains "группа — верхнего уровня"   '$_mc.Add($grpAsr)'    "$gui_text"
assert_contains "поле адреса"                'txtAsrEndpoint'       "$gui_text"
assert_contains "ключ на экране замаскирован" 'txtAsrApiKey.UseSystemPasswordChar = $true' "$gui_text"
assert_contains "незаданная \${VAR} в [asr] без WARN" "(\$curSection -eq 'remote' -or \$curSection -eq 'asr')" "$gui_text"
for _v in asr_enabled asr_endpoint asr_api_key asr_api_key_command asr_pinned_pubkey asr_language asr_diarize asr_num_speakers; do
    assert_contains "$_v уезжает в runspace" "'$_v'" "$gui_text"
done
```

`test_build_strip.sh`: `assert_eq "ffmpeg: вырезание применено к трём исходникам" "3"` → `"ffmpeg: вырезание применено к четырём исходникам" "4"`; добавить `assert_contains "ffmpeg: встраиваемый asr_client.ps1 без комментариев" 'Remove-PsComments ([System.IO.File]::ReadAllText($asrPs1' "$FF_BUILD"`; в `$files` harness'а — `'ffmpeg/asr_client.ps1',`; в цикл `for f in …` — `ffmpeg_asr_client_ps1 \`.

`test_guardrails.sh`: после «зависимость: клиент remote» — `assert_contains "зависимость: клиент asr" "ffmpeg/asr_client.ps1" "$chk"`; в цикле `$PSScriptRoot` (строка 725) — добавить `"$PROJECT_DIR/ffmpeg/asr_client.ps1"`.

Run: `bash tests/ffmpeg/test_16_gui_state.sh; bash tests/common/test_build_strip.sh; bash tests/common/test_guardrails.sh` — FAIL на новых ассертах.

- [ ] **Step 2: GUI — конфиг**

Строка 105: `$val = Expand-ConfigEnv $val ($curSection -eq 'remote')` → `$val = Expand-ConfigEnv $val ($curSection -eq 'remote' -or $curSection -eq 'asr')`. После `$_cfg_remote_onfail = …` добавить:

```powershell
# Распознавание речи. Адрес и ключ — в полях формы (начальные значения отсюда);
# api_key_command и pinned_pubkey полей не имеют: команда может спрашивать пароль,
# а пин — свойство сервера, а не запуска. Читаем и передаём как есть.
$_cfg_asr_on      = Read-Config "enabled" "asr" "no"
$_cfg_asr_ep      = Read-Config "endpoint" "asr" ""
$_cfg_asr_key     = Read-Config "api_key" "asr" ""
$_cfg_asr_keycmd  = Read-Config "api_key_command" "asr" ""
$_cfg_asr_pin     = Read-Config "pinned_pubkey" "asr" ""
$_cfg_asr_lang    = Read-Config "language" "asr" "ru"
$_cfg_asr_diarize = Read-Config "diarize" "asr" "yes"
$_cfg_asr_spk     = Read-Config "num_speakers" "asr" ""
```

- [ ] **Step 3: GUI — группа и сдвиг раскладки**

Размеры: `$form.Size … (820, 946)` → `(820, 1022)`; `$mainContainer.Size … (790, 871)` → `(790, 947)`. После `$_mc.Add($grpRemote)` вставить:

```powershell

# ========== Распознавание речи (ASR) ==========
# Отдельный режим: файлы источника не перекодируются, а расшифровываются на
# сервере распознавания. Как и группа сервера конвертации — в основных
# настройках: адрес и ключ видны до запуска. Правка полей действует на текущий
# запуск — config.ini GUI не переписывает. Всё ниже сдвинуто на высоту группы.
$yPos = 626
$grpAsr = [System.Windows.Forms.GroupBox]::new()
$grpAsr.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$grpAsr.Size = [System.Drawing.Size]::new(770, 72)
$grpAsr.Text = "Распознавание речи (ASR)"

$chkAsr = [System.Windows.Forms.CheckBox]::new()
$chkAsr.Location = [System.Drawing.Point]::new(8, 18)
$chkAsr.Size = [System.Drawing.Size]::new(262, 18)
$chkAsr.Text = "Расшифровать вместо конвертации"
$chkAsr.Checked = ($_cfg_asr_on -eq "yes")

$lblAsrLang = [System.Windows.Forms.Label]::new()
$lblAsrLang.Location = [System.Drawing.Point]::new(280, 20)
$lblAsrLang.Size = [System.Drawing.Size]::new(40, 16)
$lblAsrLang.Text = "Язык:"

$cmbAsrLang = [System.Windows.Forms.ComboBox]::new()
$cmbAsrLang.Location = [System.Drawing.Point]::new(322, 17)
$cmbAsrLang.Size = [System.Drawing.Size]::new(56, 20)
$cmbAsrLang.DropDownStyle = 'DropDownList'
[void]$cmbAsrLang.Items.AddRange(@("ru", "en"))
if ($_cfg_asr_lang -and -not $cmbAsrLang.Items.Contains($_cfg_asr_lang)) { [void]$cmbAsrLang.Items.Add($_cfg_asr_lang) }
$cmbAsrLang.SelectedItem = $_cfg_asr_lang
if ($null -eq $cmbAsrLang.SelectedItem) { $cmbAsrLang.SelectedIndex = 0 }

$chkAsrDiarize = [System.Windows.Forms.CheckBox]::new()
$chkAsrDiarize.Location = [System.Drawing.Point]::new(392, 18)
$chkAsrDiarize.Size = [System.Drawing.Size]::new(150, 18)
$chkAsrDiarize.Text = "Размечать говорящих"
$chkAsrDiarize.Checked = ($_cfg_asr_diarize -ne "no")

$lblAsrSpeakers = [System.Windows.Forms.Label]::new()
$lblAsrSpeakers.Location = [System.Drawing.Point]::new(548, 20)
$lblAsrSpeakers.Size = [System.Drawing.Size]::new(114, 16)
$lblAsrSpeakers.Text = "Сколько говорящих:"

$txtAsrSpeakers = [System.Windows.Forms.TextBox]::new()
$txtAsrSpeakers.Location = [System.Drawing.Point]::new(664, 17)
$txtAsrSpeakers.Size = [System.Drawing.Size]::new(40, 20)
$txtAsrSpeakers.Text = $_cfg_asr_spk

$lblAsrEndpoint = [System.Windows.Forms.Label]::new()
$lblAsrEndpoint.Location = [System.Drawing.Point]::new(8, 47)
$lblAsrEndpoint.Size = [System.Drawing.Size]::new(52, 16)
$lblAsrEndpoint.Text = "Адрес:"

$txtAsrEndpoint = [System.Windows.Forms.TextBox]::new()
$txtAsrEndpoint.Location = [System.Drawing.Point]::new(62, 44)
$txtAsrEndpoint.Size = [System.Drawing.Size]::new(400, 20)
$txtAsrEndpoint.Text = $_cfg_asr_ep

$lblAsrApiKey = [System.Windows.Forms.Label]::new()
$lblAsrApiKey.Location = [System.Drawing.Point]::new(470, 47)
$lblAsrApiKey.Size = [System.Drawing.Size]::new(44, 16)
$lblAsrApiKey.Text = "Ключ:"

$txtAsrApiKey = [System.Windows.Forms.TextBox]::new()
$txtAsrApiKey.Location = [System.Drawing.Point]::new(518, 44)
$txtAsrApiKey.Size = [System.Drawing.Size]::new(200, 20)
# Ключ не должен читаться с экрана через плечо и на скриншотах.
$txtAsrApiKey.UseSystemPasswordChar = $true
$txtAsrApiKey.Text = $_cfg_asr_key

$grpAsr.Controls.AddRange(@($chkAsr, $lblAsrLang, $cmbAsrLang, $chkAsrDiarize, $lblAsrSpeakers, $txtAsrSpeakers,
	$lblAsrEndpoint, $txtAsrEndpoint, $lblAsrApiKey, $txtAsrApiKey))
$_regFont = $grpAsr.Font
$grpAsr.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $grpAsr.Controls) { $c.Font = $_regFont }
$_mc.Add($grpAsr)
```

Сдвиг на 76: у «Other Settings» `$yPos = 626` → `$yPos = 702`; у «Buttons Row» `$yPos = 648` → `$yPos = 724`; у «Progress Section» `$yPos = 682` → `$yPos = 758`.

- [ ] **Step 4: GUI — проверка окружения, валидация, запуск**

В обработчике `$buttonDoctor` после блока `if ($chkRemote.Checked) { … }`:

```powershell
    if ($chkAsr.Checked) {
        $curl = $null
        try { $curl = (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } catch {}
        if ($curl) { $lines += "curl:    есть — $curl" }
        else       { $lines += "curl:    НЕТ — распознавание речи не работает вовсе." }
        $aep = $txtAsrEndpoint.Text.Trim()
        if ($aep) { $lines += "ASR:     $aep" }
        else      { $lines += "ASR:     адрес НЕ ЗАДАН — заполните поле адреса сервера распознавания." }
        if ($txtAsrApiKey.Text.Trim() -or $_cfg_asr_keycmd) { $lines += "Ключ ASR: задан (значение не показываем)" }
        else { $lines += "Ключ ASR: НЕ ЗАДАН — сервер откажет на первом запросе." }
    }
```

После строки валидации `elseif ($chkRemote.Checked -and $txtRemoteWait.Text -notmatch …)`:

```powershell
    elseif ($chkAsr.Checked -and $txtAsrSpeakers.Text.Trim() -and (($txtAsrSpeakers.Text.Trim() -notmatch '^[0-9]+$') -or ([int64]$txtAsrSpeakers.Text.Trim() -lt 1) -or ([int64]$txtAsrSpeakers.Text.Trim() -gt 50))) { $numErr = "«Сколько говорящих» — целое число от 1 до 50 или пусто (сервер определит сам)" }
```

`if ($_modes.Count -gt 1) {` → `if ($_modes.Count -gt 1 -and -not $chkAsr.Checked) {`; `if ($hwIndex -gt 0) {` → `if ($hwIndex -gt 0 -and -not $chkAsr.Checked) {` (в режиме ASR режимы конвертера и энкодер не участвуют).

После `$script:remote_on_failure      = $_cfg_remote_onfail`:

```powershell

    # ---- Распознавание речи ----
    $script:asr_enabled         = if ($chkAsr.Checked) { "yes" } else { "no" }
    $script:asr_endpoint        = $txtAsrEndpoint.Text.Trim()
    $script:asr_api_key         = $txtAsrApiKey.Text.Trim()
    $script:asr_api_key_command = $_cfg_asr_keycmd
    $script:asr_pinned_pubkey   = $_cfg_asr_pin
    $script:asr_language        = [string]$cmbAsrLang.SelectedItem
    $script:asr_diarize         = if ($chkAsrDiarize.Checked) { "yes" } else { "no" }
    $script:asr_num_speakers    = $txtAsrSpeakers.Text.Trim()
```

В `$varsToPass`: `'remote_prefer','remote_wait_timeout','remote_stall_timeout','remote_on_failure'` → дописать `,` и строку
`        'asr_enabled','asr_endpoint','asr_api_key','asr_api_key_command','asr_pinned_pubkey','asr_language','asr_diarize','asr_num_speakers'`.

После правки — BOM.

- [ ] **Step 5: Сборка и выпуск**

`build_exe.ps1` — после блока `remote_client.ps1`:

```powershell

# Модуль распознавания речи — по той же причине и тем же способом: script.ps1
# подключает его только при отсутствии функции Invoke-AsrRun.
$asrPs1 = Join-Path $PSScriptRoot 'asr_client.ps1'
if (Test-Path -LiteralPath $asrPs1) {
    Write-Host 'Embedding asr_client.ps1...'
    $asrContent = Remove-PsComments ([System.IO.File]::ReadAllText($asrPs1, [System.Text.Encoding]::UTF8))
    $scriptContent = $asrContent + "`n" + $scriptContent
}
```

и в комментарии «Комментарии снимаются со ВСЕХ трёх исходников» — «четырёх». `tools/check_release.ps1`: `'ffmpeg/remote_client.ps1')` → `'ffmpeg/remote_client.ps1',` + `        'ffmpeg/asr_client.ps1')`.

- [ ] **Step 6: Прогнать — зелёный**

Run: `bash tests/ffmpeg/test_16_gui_state.sh && bash tests/common/test_build_strip.sh && bash tests/common/test_guardrails.sh && bash tests/ffmpeg/test_24_gui_worker_runspace.sh && bash tests/common/test_encoding.sh`
Expected: `fail=0`. Ручная проверка: `powershell -File ffmpeg\FFmpeg_Converter_run_win_v19.ps1` — группа видна под «Сервером конвертации», кнопки не перекрыты, спойлер «Дополнительные настройки» сдвигает кнопки.

- [ ] **Step 7: Commit** — «asr: группа в GUI, модуль в EXE и в зависимостях выпуска».

---

### Task 10: Документация

**Files:**
- Modify: `README.md`, `docs/constraints.md`, `tests/TESTING.md`
- Modify (локально, не коммитится): `CLAUDE.md`, `AGENTS.md`

- [ ] **Step 1: README.md**

В «### FFmpeg Converter» в список возможностей — `- **Распознавание речи:** расшифровка на сервере WhisperX с разметкой говорящих (\`[asr]\`)`. После раздела «#### Удалённый счёт на сервере конвертации» — новый:

```markdown
#### Распознавание речи (ASR)

Отдельный режим: `[asr] enabled = yes` — файлы из `source` не перекодируются, а
расшифровываются на сервере распознавания речи (WhisperX: слова выравниваются по
времени, говорящие размечаются). В `destination`, с тем же зеркалом подпапок,
ложатся `<имя>.txt` — реплики вида `[00:00:03] SPEAKER_00: …` с шапкой (модель,
длительность, число говорящих, сомнительные сегменты, ошибки этапов) — и
`<имя>.asr.json` с сырым ответом сервера. Готовый `.txt` при
`overwrite_existing = no` пропускается.

Звук извлекает локальный ffmpeg (первая дорожка → FLAC, моно, 16 кГц): видео
целиком по сети не идёт. Запись длиннее, чем сервер успевает обработать за свой
предел времени, режется на равные части (на процессорном сервере — до 25 минут);
метки говорящих в разных частях независимы, о чём сказано в шапке.

Адрес, ключ и закреплённый открытый ключ сервера — только в некоммитимом
`ffmpeg/config.ini` (или `${ASR_URL}` / `${ASR_API_KEY}`, `api_key_command`). В
`endpoint` можно перечислить несколько адресов через пробел — берётся первый
ответивший. Для `https` с самоподписанным сертификатом обязателен
`pinned_pubkey = sha256//…`: проверка имени отключается только вместе с ним.

Режим есть в `.sh`, `.ps1` и GUI (группа «Распознавание речи (ASR)»). CMD-версия
при `[asr] enabled = yes` предупреждает и завершается с кодом 1, не конвертируя.
```

В дереве «Структура проекта» рядом с `remote_client.*` — строки `asr_client.sh` / `asr_client.ps1` («клиент сервера распознавания речи») и `tests/fixtures/asr/` («ответы сервера и ожидаемые расшифровки — общие для .sh и .ps1»). Счётчики ffmpeg-тестов — 28 (все три места: дерево, «Запуск тестов», заголовок таблицы). Проверить, что строки таблицы `test_25…28` на месте.

- [ ] **Step 2: docs/constraints.md — раздел перед «## Тесты»**

```markdown
## Распознавание речи (`[asr]`)

- **Отдельный режим, а не шаг конвертации** (решение владельца, 2026-10-02):
  при `enabled = yes` режимы конвертера и `[remote]` не участвуют, файлы идут
  строго по одному — у сервера один рабочий поток, `parallel_files` игнорируется
  с предупреждением.
- **curl на обеих платформах, ключ сервера закреплён.** Сертификат сервера
  самоподписанный и выписан на другое имя; проверка TLS заменена пином
  (`--pinnedpubkey`), `-k` ставится только вместе с ним. Системный `curl.exe` 8.x
  на Schannel пин поддерживает: чужой ключ — код 90 (проверено 2026-10-02). В .NET
  Framework то же потребовало бы ручного разбора DER в callback'е проверки,
  который вызывается вне runspace, — поэтому `.ps1` запускает `curl.exe`, а не
  `HttpWebRequest`, как `remote_client.ps1`.
- **Файлы для curl — относительными именами из каталога прогона.** curl из Git
  Bash — нативная программа: `-F "file=@/tmp/…"` MSYS в Windows-путь не переводит,
  curl отвечает кодом 26 (проверено 2026-10-02). Поэтому curl запускается из
  `ASR_RUN_DIR` (`cd` в `.sh`, `WorkingDirectory` в `.ps1`).
- **Ключ — через stdin** (`--config -`), как у удалённого бэкенда: argv процесса
  виден всем, а запрос живёт до получаса.
- **Звук — FLAC, моно, 16 кГц, извлекается локально.** Кодер встроен в любую
  сборку ffmpeg (libmp3lame/libopus — нет), сжатие без потерь, час ≈ 65 МБ при
  пределе сервера 500 МБ.
- **Длительность — из `ffmpeg -i`**, тем же разбором, что у конвертера (ffprobe он
  не использует); дробная часть заменяется запасом +1 с.
- **План частей — из живых пределов** (`GET /speech/limits`): `W = min(max_seconds,
  job_timeout_sec / k)`, `k = 0.6` на `cpu` и `0.1` иначе; длиннее `W` — равные
  части не длиннее `W / 2`. Зашитые числа завели бы план не туда при переключении
  сервера на карту.
- **Исходы: «файл» или «прогон».** Причина в файле (нет звука, 400, 413, 422, 200
  без `segments`) — файл провален, прогон идёт дальше. Причина общая (401, 403,
  500, 502, 504, 503 после повторов, сеть, чужой сертификат) — прогон
  останавливается, остаток — «не обработано». 504 не повторяется: задача на
  сервере продолжает выполняться и занимает очередь.
- **Разбор JSON в `.sh` — один `awk` с `RS` = кавычка.** jq и python не
  гарантированы; в BWK awk (macOS) `substr` считает длину всей строки на каждом
  вызове, и посимвольный проход по многомегабайтному ответу был бы квадратичным.
  Кавычка экранирована, если перед ней нечётное число обратных слэшей.
- **Текст `.sh` и `.ps1` совпадает байт в байт** (UTF-8 без BOM, LF; в `.ps1` —
  обрезка только пробелов после замены `\r\n\t`, без `.Trim()`). Ожидаемые `.txt`
  лежат в `tests/fixtures/asr` и общие для `test_25` и `test_26`; `test_27` сверяет
  стороны напрямую, в том числе на 2000 сегментах.
- **Два входа на один `.txt`** (`movie.avi` и `movie.mp4`) — второй проваливается
  с объяснением, а не затирает и не «пропускает» первый.
- **CMD отказывается с кодом 1**, а не конвертирует: молчаливая конвертация
  вместо расшифровки дала бы не тот результат.
- **Адрес, ключ и пин — только в некоммитимом `config.ini`**: репозиторий
  публичный.
```

- [ ] **Step 3: tests/TESTING.md**

В таблицу «Из чего состоит» — строку `| \`tests/fixtures/asr/\` | Ответы сервера распознавания и ожидаемые расшифровки — общие для .sh и .ps1 |`. В «Правила, которые легко нарушить» — пункт:

```markdown
- **Ожидаемые расшифровки — одни на обе платформы.** `tests/fixtures/asr/*.txt`
  сверяют и `test_25` (.sh), и `test_26` (.ps1): расхождение текста чинится в той
  платформе, что отошла от спеки, а не правкой фикстуры под неё. JSON-фикстуры —
  одной строкой без перевода строки в конце: их тело уходит в мок curl маршрутом.
```

- [ ] **Step 4: CLAUDE.md и AGENTS.md (локальные, не коммитятся)**

CLAUDE.md: в списке «Недоступны в CMD» — добавить `[asr]` (выход с кодом 1); строку «Удалённый бэкенд — только …» дополнить «Распознавание речи — тоже»; «четырёх исходников GUI» → «пяти» и добавить `asr_client.ps1`; в «Ключевые ограничения» — блок:

```markdown
**Распознавание речи (`[asr]`):**
- Отдельный режим вместо конвертации; `.sh`/`.ps1`/GUI, CMD — отказ с кодом 1.
- Адрес/ключ/пин — только в некоммитимом `config.ini`; `-k` — только вместе с `--pinnedpubkey`.
- curl — из каталога прогона, файлы относительными именами (`file=@/tmp/…` в Git Bash → curl 26).
- Текст `.sh` (awk) и `.ps1` — байт в байт: общие фикстуры `tests/fixtures/asr`, сверка `test_25/26/27`.
```

AGENTS.md: если в нём перечислены исходники GUI/EXE — добавить `asr_client.ps1` (иначе внешний агент не пересоберёт EXE после правки модуля).

- [ ] **Step 5: Прогнать документные проверки**

Run: `bash tests/common/test_docs_links.sh && bash tests/common/test_guardrails.sh`
Expected: `fail=0` (счётчики README, ссылки, регистрация файлов).

- [ ] **Step 6: Commit** — `README.md docs/constraints.md tests/TESTING.md`, «docs: распознавание речи — README, ограничения, тест-система».

---

### Task 11: Выпуск и живая проверка

**Files:**
- Modify: `ffmpeg/_VideoConverter_v19.exe`, `ffmpeg/_VideoConverter_v19.exe.sha256`, `yt-dlp/_VideoDownloader_v19.exe*`, `release-manifest.json`

- [ ] **Step 1: Быстрый уровень и замер новых файлов**

Run: `bash tests/run_tests.sh --fast`
Expected: `fail=0`, укладывается в 60 с. Затем `bash tests/run_tests.sh ffmpeg` — по `TESTS_DURATION` решить, входит ли `ffmpeg/test_25_asr_client.sh` в `FAST_LEVEL` (только Bash, без PowerShell; если файл ≤ ~5 с и уровень остаётся в бюджете — добавить в список по убыванию времени и записать замер в комментарий над списком).

- [ ] **Step 2: Полный уровень**

Run: `bash tests/run_tests.sh`
Expected: `fail=0`; пропуски — только ожидаемые (нет cmd/PowerShell вне Windows).

- [ ] **Step 3: Пересборка EXE и манифест**

Run: `powershell -File tools\check_release.ps1 -SkipTests`
Expected: оба EXE собраны, `.sha256` и `release-manifest.json` обновлены, `Get-StaleExeSources` пуст.

- [ ] **Step 4: Commit** — `git add ffmpeg/_VideoConverter_v19.exe ffmpeg/_VideoConverter_v19.exe.sha256 yt-dlp/_VideoDownloader_v19.exe yt-dlp/_VideoDownloader_v19.exe.sha256 release-manifest.json`, «v19: пересборка обоих EXE после добавления распознавания речи».

- [ ] **Step 5: Живая проверка против сервера (вручную, вне набора)**

1. Короткая речь: синтезировать WAV голосом Windows (`System.Speech`, русский голос, если установлен; иначе английский и `language = en`) во временный каталог-источник.
2. Прогнать `.sh` с локальным `config.ini` (`[asr] enabled = yes`, источник/назначение — временные каталоги): проверить выбор адреса (адрес второй сети с этой машины не отвечает — должен быть взят адрес LAN), `.txt`/`.asr.json`, шапку, сводку.
3. То же через `.ps1` и GUI (галка «Расшифровать вместо конвертации»), включая кнопку «Остановить» во время запроса.
4. Запись длиннее порога (склеить синтезированную речь до 51 мин или взять длинную собственную запись владельца по согласию) — части, смещения, шапка.
5. Вернуть `enabled = no` в локальном конфиге, если владелец не попросил иного.

- [ ] **Step 6: Сообщить владельцу**: собранный EXE нужно проверить на машине с Kaspersky (правка GUI и нового модуля — правило проекта); отдельный ключ шлюза для конвертера вместо ключа из инструкции — по желанию.
