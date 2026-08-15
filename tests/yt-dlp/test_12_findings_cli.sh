#!/bin/bash
# ============================================================
# test_12_findings_cli.sh — находки code-review/deep-analysis по yt-dlp:
#   Y1 — $qi присваивается ДО блока манифеста (иначе на первой итерации очереди он
#        $null, «$qi -lt 7» истинно, и манифест создаётся для режима «только субтитры»);
#   Y2 — preflight: AI-перевод, несовместимый с режимом, сообщается ДО старта очереди;
#   Y3 — CMD: валидация URL средствами самого CMD, без temp-файла и findstr;
#   Y4 — CMD: громкости mix спрашиваются интерактивно и валидируются.
# PS1/CMD проверяются source-scan'ом: интерактивный CLI и WinForms в headless-тесте
# не прогнать, как и в test_05/test_08.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v17.ps1"
YT_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v17.cmd"
PS1_SRC="$(cat "$YT_PS1")"
CMD_SRC="$(cat "$YT_CMD")"

# ══════════════════════════════════════════════════════════════
suite "Y1: \$qi присвоен до создания манифеста загрузок"
# ══════════════════════════════════════════════════════════════
# Манифест нужен двум потребителям: переводу и учёту archive-skip. Условие отсекает
# режим «только субтитры» (qi 7/8) — но $qi присваивался НИЖЕ, в блоке «Формат».
# На первой итерации он был $null, `$null -lt 7` истинно, и манифест создавался всегда.
qi_assign=$(grep -n '^\s*\$qi\s*=\s*\$comboQuality\.SelectedIndex' "$YT_PS1" | head -1 | cut -d: -f1)
qi_use=$(grep -n 'cfg_useArchive -eq "true" -and \$qi -lt 7)) {' "$YT_PS1" | head -1 | cut -d: -f1)
if [ -n "$qi_assign" ] && [ -n "$qi_use" ] && [ "$qi_assign" -lt "$qi_use" ]; then
    pass "\$qi присваивается выше условия манифеста"
else
    fail "\$qi присваивается выше условия манифеста" "assign < use" "assign=$qi_assign use=$qi_use"
fi
n_assign=$(printf '%s\n' "$PS1_SRC" | grep -cE '^\s*\$qi\s*=\s*\$comboQuality\.SelectedIndex')
assert_eq "присваивание \$qi осталось одно (нет дубля ниже)" "1" "$n_assign"

# ══════════════════════════════════════════════════════════════
suite "Y2: preflight несовместимости AI-перевода с режимом"
# ══════════════════════════════════════════════════════════════
# Раньше валидация была только post-factum в цикле обработки: пользователь ждал
# загрузку всего плейлиста и лишь потом видел, что перевод пропущен для каждого URL.
assert_contains "preflight проверяет режим субтитров"   'if ($_qiPre -ge 7)' "$PS1_SRC"
assert_contains "preflight проверяет режим только-аудио" 'elseif ($_qiPre -eq 0)' "$PS1_SRC"
assert_contains "preflight можно отменить"              'if ($_ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }' "$PS1_SRC"
# Проверка обязана стоять ДО отключения кнопки и старта очереди, иначе смысла нет.
pre_ln=$(grep -n 'AI-перевод несовместим с режимом' "$YT_PS1" | head -1 | cut -d: -f1)
run_ln=$(grep -n '$global:processRunning = $true' "$YT_PS1" | head -1 | cut -d: -f1)
if [ -n "$pre_ln" ] && [ -n "$run_ln" ] && [ "$pre_ln" -lt "$run_ln" ]; then
    pass "preflight стоит до старта очереди"
else
    fail "preflight стоит до старта очереди" "preflight < start" "preflight=$pre_ln start=$run_ln"
fi
# Post-factum сообщения в цикле остаются — preflight их не заменяет, а дополняет.
assert_contains "post-factum причина для qi>=7 сохранена" 'неприменим к режиму «только субтитры»' "$PS1_SRC"

# ══════════════════════════════════════════════════════════════
suite "Y3: CMD валидирует URL без temp-файла и внешнего процесса"
# ══════════════════════════════════════════════════════════════
# Прежняя версия писала URL в %temp% и звала findstr: лишний I/O, зависимость от
# findstr и мусор в temp при падении между записью и del.
assert_not_contains "нет temp-файла для проверки URL"  '_urlchk' "$CMD_SRC"
assert_not_contains "нет вызова findstr по схеме URL"  'findstr /r /i /c:"^http://"' "$CMD_SRC"
assert_contains "схема http:// сверяется срезом"       'if /i "!url:~0,7!"=="http://"' "$CMD_SRC"
assert_contains "схема https:// сверяется срезом"      'if /i "!url:~0,8!"=="https://"' "$CMD_SRC"
# Кавычка в URL по-прежнему отсекается (инъекция в if-сравнение).
assert_contains "кавычка в URL отсекается"             'set "_nq=!url:"=!"' "$CMD_SRC"

# Поведенческая проверка среза схемы: логика короткая, прогоняем её в реальном cmd.
if command -v cmd >/dev/null 2>&1; then
    T=$(mktemp -d /tmp/test_yt12_XXXXXX)
    cat > "$T/urlchk.cmd" <<'EOF'
@echo off
setlocal enabledelayedexpansion
call :t "https://youtu.be/x"
call :t "http://example.com/v"
call :t "httpss://evil.tld"
call :t "ftp://host/f"
call :t "HTTPS://YOUTU.BE/X"
goto :eof
:t
set "url=%~1"
set "_urlok="
if /i "!url:~0,7!"=="http://"  set "_urlok=1"
if /i "!url:~0,8!"=="https://" set "_urlok=1"
if defined _urlok (echo "%~1" OK) else (echo "%~1" REJECT)
exit /b
EOF
    # CRLF — как и для второго драйвера ниже: CMD не разбирает блоки с LF-концами.
    sed -i 's/\r$//; s/$/\r/' "$T/urlchk.cmd"
    out=$(cmd //c "$(cygpath -w "$T/urlchk.cmd" 2>/dev/null || echo "$T/urlchk.cmd")" 2>&1 | tr -d '\r')
    assert_contains "https:// принимается"        '"https://youtu.be/x" OK'     "$out"
    assert_contains "http:// принимается"         '"http://example.com/v" OK'   "$out"
    assert_contains "httpss:// отвергается"       '"httpss://evil.tld" REJECT'  "$out"
    assert_contains "ftp:// отвергается"          '"ftp://host/f" REJECT'       "$out"
    assert_contains "регистр схемы игнорируется"  '"HTTPS://YOUTU.BE/X" OK'     "$out"
    rm -rf "$T"
else
    skip "Поведенческая проверка среза схемы URL" "cmd недоступен"
fi

# ══════════════════════════════════════════════════════════════
suite "Y4: CMD спрашивает громкости mix и валидирует ввод"
# ══════════════════════════════════════════════════════════════
# Значения были захардкожены (0.3/1.0): настроить баланс дорожек из CLI было нельзя,
# в отличие от GUI. Ввод обязан валидироваться — иначе он уходит в -filter_complex
# как есть, и ffmpeg падает на каждом файле.
assert_contains "запрос громкости оригинала"      'set /p "_ov=Громкость оригинала [0.3]: "' "$CMD_SRC"
assert_contains "запрос громкости перевода"       'set /p "_tv=Громкость перевода [1.0]: "'  "$CMD_SRC"
assert_contains "запрос только в режиме mix"      'if "%translate_mode%"=="mix" (' "$CMD_SRC"
assert_contains "подпрограмма валидации :read_vol" ':read_vol' "$CMD_SRC"
assert_contains "дефолты сохранены"               'set "translate_orig_vol=0.3"' "$CMD_SRC"

if command -v cmd >/dev/null 2>&1; then
    T=$(mktemp -d /tmp/test_yt12b_XXXXXX)
    # :read_vol вырезаем из production-файла — инлайн-копия разошлась бы с оригиналом.
    # До конца файла: подпрограмма стоит последней и включает ветку :read_vol_bad
    # (диапазон до первого «exit /b 0» обрезал бы её, и goto не нашёл бы метку).
    sed -n '/^:read_vol$/,$p' "$YT_CMD" > "$T/body.txt"
    # Драйвер пишем heredoc'ом, а не printf: printf съедал экранирование `^>` (в
    # выводе оставался настоящий `>`, CMD делал редирект и падал на «'.5' is not
    # recognized»). Разделитель вывода — `--`, без символов, значащих для CMD.
    # Запятую/точку с запятой в набор `for` не положить — это delims для CMD.
    cat > "$T/vol.cmd" <<'CMDEOF'
@echo off
setlocal enabledelayedexpansion
for %%v in (0.3 1 05.5 abc 1.2.3 . -1) do (
  set "_dst=9.9"
  set "_raw=%%v"
  call :read_vol _dst _raw
  echo %%v -- !_dst!
)
goto :eof

CMDEOF
    cat "$T/body.txt" >> "$T/vol.cmd"
    # CRLF обязателен: CMD с LF-концами разваливает многострочный `for ... do ( )`
    # на отдельные команды («'.5' is not recognized», «'enabledelayedexpansion' is
    # not recognized»). Та же конвенция, что в test_10_cmd.sh / test_12_cmd_run_parser.sh.
    sed -i 's/\r$//; s/$/\r/' "$T/vol.cmd"
    out=$(cmd //c "$(cygpath -w "$T/vol.cmd" 2>/dev/null || echo "$T/vol.cmd")" 2>&1 | tr -d '\r')
    assert_contains "0.3 принимается"           '0.3 -- 0.3'   "$out"
    assert_contains "1 принимается"             '1 -- 1'       "$out"
    assert_contains "05.5 принимается"          '05.5 -- 05.5' "$out"
    assert_contains "abc отвергается"           'abc -- 9.9'   "$out"
    assert_contains "1.2.3 отвергается"         '1.2.3 -- 9.9' "$out"
    assert_contains "одна точка отвергается"    '. -- 9.9'     "$out"
    assert_contains "отрицательное отвергается" '-1 -- 9.9'    "$out"
    rm -rf "$T"
else
    skip "Поведенческая проверка :read_vol" "cmd недоступен"
fi

summary
