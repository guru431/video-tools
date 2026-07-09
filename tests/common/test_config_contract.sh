#!/bin/bash
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
YT_SH="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.sh"
YT_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
YT_CMD="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"
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
is_sh_only() { printf '%s\n' "$sh_only_keys" | grep -qx -- "$1"; }
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if is_sh_only "$key"; then
        # batch-ключи — только .sh; в .ps1 их нет (проверяем реальное чтение в .sh).
        if grep -qw -- "$key" "$YT_SH"; then pass "sh_only '$key' читается в .sh"
        else fail "sh_only '$key' читается в .sh" "читается" "отсутствует"; fi
    else
        if grep -qw -- "$key" "$YT_SH" || grep -qw -- "$key" "$YT_PS1"; then
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
    if printf '%s\n' "$example_keys" | grep -qx -- "$sk"; then pass "sh_only '$sk' есть в config.ini.example"
    else fail "sh_only '$sk' есть в config.ini.example" "присутствует" "нет такого ключа (опечатка в контракте)"; fi
done < <(printf '%s\n' "$sh_only_keys")

summary
