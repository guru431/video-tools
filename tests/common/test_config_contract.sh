#!/bin/bash
# Тест дот-сорсит настоящий production-скрипт: переменные, которые здесь только
# присваиваются, читает он (SC2034).
# shellcheck disable=SC2034
# ============================================================
# test_config_contract.sh — валидация машиночитаемого контракта
# tests/config-key-contract.yaml против реального кода.
#
# Дополняет test_config_keys.sh (тот читает gitignored yt-dlp/config.ini — в CI его нет):
# здесь yt-dlp ключи берутся из ТРЕКАЕМОГО yt-dlp/config.ini.example, поэтому проверка
# работает и на свежем клоне/CI. Плюс — явные исключения контракта (CMD, batch sh_only).
# Чистый bash.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

YAML="$TESTS_DIR/config-key-contract.yaml"
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.sh"
YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.ps1"
YT_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v19.cmd"
YT_EXAMPLE="$PROJECT_DIR/yt-dlp/config.ini.example"

keys_of() { grep -oE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$1" | sed 's/[[:space:]=]//g'; }
# Извлекает элементы YAML-списка "- X" под строкой-маркером $1.
yaml_list_after() {
    awk -v m="$1" '
        $0 ~ m { grab=1; next }
        grab && /^[[:space:]]*-[[:space:]]/ { sub(/^[[:space:]]*-[[:space:]]*/,""); print; next }
        grab && /^[[:space:]]*[^[:space:]-]/ { grab=0 }
    ' "$YAML"
}

# ── Контракт существует и объявляет исключения ────────────────────────────
suite "contract: файл и исключения"
assert_file_exists "config-key-contract.yaml существует"  "$YAML"
yaml="$(cat "$YAML")"
assert_contains "объявлен ffmpeg-контракт (sh+cmd+ps1)"  "read in run.sh AND run.cmd AND run.ps1"  "$yaml"
assert_contains "объявлен yt-dlp CMD exception"          "does not read config.ini"  "$yaml"

# ── yt-dlp CMD реально НЕ читает config.ini (санкционированное исключение) ──
# Упоминание в комментарии ("без config.ini") допустимо; запрещено чтение файла.
suite "contract: yt-dlp CMD не парсит config.ini"
noncomment_cfg=$(grep -n 'config\.ini' "$YT_CMD" | grep -vE ':[[:space:]]*(rem|::)' || true)
if [ -z "$noncomment_cfg" ]; then
    pass "CMD упоминает config.ini только в комментариях (не читает)"
else
    fail "CMD не читает config.ini" "только в комментариях" "$noncomment_cfg"
fi

# ── Покрытие yt-dlp ключей (из tracked example, CI-safe) ──────────────────
suite "contract: yt-dlp ключи (config.ini.example) читаются в .sh или .ps1"
sh_only_keys=$(yaml_list_after '    sh_only:')
sh_src="$(cat "$YT_SH")"
ps1_src="$(cat "$YT_PS1")"
# Проверки — по уже прочитанному тексту, без процесса на каждый ключ.
# is_sh_only: ключ — целая строка списка (как `grep -qx`).
is_sh_only() { case $'\n'"$sh_only_keys"$'\n' in *$'\n'"$1"$'\n'*) return 0 ;; esac; return 1; }
# has_word: ключ — отдельное слово (как `grep -qw`): по краям начало/конец текста
# или не-словесный символ; перевод строки — тоже не-словесный, поэтому весь файл
# одной строкой проверяется так же, как построчно.
has_word() {
    local re="(^|[^[:alnum:]_])$1([^[:alnum:]_]|\$)"
    [[ $2 =~ $re ]]
}
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if is_sh_only "$key"; then
        # batch-ключи — только .sh; в .ps1 их нет (проверяем реальное чтение в .sh).
        if has_word "$key" "$sh_src"; then pass "sh_only '$key' читается в .sh"
        else fail "sh_only '$key' читается в .sh" "читается" "отсутствует"; fi
    else
        if has_word "$key" "$sh_src" || has_word "$key" "$ps1_src"; then
            pass "yt-dlp '$key' (есть читатель .sh/.ps1)"
        else
            fail "yt-dlp '$key'" "читается в .sh или .ps1" "нигде (мёртвый ключ или не в контракте)"
        fi
    fi
done < <(keys_of "$YT_EXAMPLE")

# ── Заявленные sh_only ключи существуют в шаблоне (нет опечаток в контракте) ─
suite "contract: sh_only ключи реальны"
example_keys="$(keys_of "$YT_EXAMPLE")"
while IFS= read -r sk; do
    [ -z "$sk" ] && continue
    if case $'\n'"$example_keys"$'\n' in *$'\n'"$sk"$'\n'*) true ;; *) false ;; esac; then pass "sh_only '$sk' есть в config.ini.example"
    else fail "sh_only '$sk' есть в config.ini.example" "присутствует" "нет такого ключа (опечатка в контракте)"; fi
done < <(printf '%s\n' "$sh_only_keys")

# ══════════════════════════════════════════════════════════════
suite "contract: ffmpeg-исключения читаются, а не декоративны"
# ══════════════════════════════════════════════════════════════
# Списки sh_only_behavior / sh_ps1_only_behavior в ffmpeg-секции контракта не
# парсил никто: они были комментарием в YAML-обёртке. Правило простое и
# проверяемое — ключ, у которого поведение расходится между платформами, обязан
# в «обделённой» платформе печатать [ПРЕДУПРЕЖДЕНИЕ] рядом с чтением. Иначе один
# config.ini молча значит разное, что правило паритета и запрещает.
FF_CMD_RUN="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v19.cmd"
FF_CMD_SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.cmd"
FF_PS1_SCRIPT="$PROJECT_DIR/ffmpeg/FFmpeg_Converter_script.ps1"

ff_sh_only=$(yaml_list_after '    sh_only_behavior:')
ff_sh_ps1_only=$(yaml_list_after '    sh_ps1_only_behavior:')

assert_not_empty "контракт: список sh_only_behavior (ffmpeg) не пуст"     "$ff_sh_only"
assert_not_empty "контракт: список sh_ps1_only_behavior (ffmpeg) не пуст" "$ff_sh_ps1_only"

# sh_only_behavior: ключ читается везде, но работает только в .sh — значит и PS1,
# и CMD обязаны предупреждать.
while IFS= read -r k; do
    [ -z "$k" ] && continue
    if grep -q "ПРЕДУПРЕЖДЕНИЕ.*$k" "$FF_PS1_SCRIPT"; then
        pass "sh_only '$k': PS1 предупреждает"
    else
        fail "sh_only '$k': PS1 предупреждает" "строка с [ПРЕДУПРЕЖДЕНИЕ] и именем ключа" "нет"
    fi
    if grep -q "ПРЕДУПРЕЖДЕНИЕ.*$k" "$FF_CMD_SCRIPT"; then
        pass "sh_only '$k': CMD предупреждает"
    else
        fail "sh_only '$k': CMD предупреждает" "строка с [ПРЕДУПРЕЖДЕНИЕ] и именем ключа" "нет"
    fi
done < <(printf '%s
' "$ff_sh_only")

# sh_ps1_only_behavior: ключи секции [remote]. В .cmd они ЧИТАЮТСЯ (иначе
# --print-config о них не знал бы) и сопровождаются одним общим предупреждением
# о недоступности удалённого бэкенда — по ключу на строку тут не требуется.
_cmd_run_src="$(cat "$FF_CMD_RUN")"
while IFS= read -r k; do
    [ -z "$k" ] && continue
    assert_contains "remote-ключ '$k' читается в run_v19.cmd" "\"$k\"" "$_cmd_run_src"
done < <(printf '%s
' "$ff_sh_ps1_only")
assert_contains "CMD предупреждает о недоступности удалённого бэкенда"     "Удалённый бэкенд" "$_cmd_run_src"

summary
