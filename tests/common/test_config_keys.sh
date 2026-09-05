#!/bin/bash
# ============================================================
# test_config_keys.sh — Meta-тест паритета ключей config.ini.
# Ключ, читаемый на одной платформе и забытый на другой — классическая parity-протечка,
# которую fragment-тесты не ловят. Здесь ".ini = контракт" становится enforced-инвариантом.
#   ffmpeg: каждый ключ ОБЯЗАН читаться в run.sh И run.cmd И run.ps1 (полный паритет).
#   yt-dlp: каждый ключ должен читаться хотя бы в .sh ИЛИ .ps1 (нет мёртвых ключей;
#           CMD интерактивен и config.ini не читает — исключён по дизайну).
#
# Список ключей берётся из config.ini.example, а НЕ из рабочего config.ini: оба
# рабочих конфига gitignored, на свежем клоне и на CI их нет. Раньше yt-dlp-блок
# читал отсутствующий файл, keys_of отдавал пустоту, цикл не выполнялся ни разу —
# и весь набор молча зеленел, ничего не проверив.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Имена ключей из config.ini (строки "key = ..." вне комментариев/секций)
keys_of() { grep -oE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$1" | sed 's/[[:space:]=]//g'; }

# Пустой список ключей означал бы «всё в порядке» при полностью отсутствующем
# шаблоне — проверяем, что читать вообще есть что.
assert_nonempty_keys() {
    local label="$1" file="$2" n
    n="$(keys_of "$file" 2>/dev/null | grep -c .)"
    if [ "$n" -gt 0 ]; then pass "$label: шаблон читается ($n ключей)"
    else fail "$label: шаблон читается" "ключи найдены" "нет файла или ключей: $file"; fi
}

# «Ключ читается» — это ВЫЗОВ ридера с этим ключом, а не слово где-нибудь в файле.
# Прежний `grep -qw` совпадал и с комментарием, и с чужим идентификатором: ключи
# start, enabled, file, format, prefer встречаются в тексте на каждой странице, и
# для них проверка была вечнозелёной. Ищем формы, которыми ридеры реально
# обращаются к ключу на каждой платформе.
key_is_read() {
    local file="$1" key="$2"
    case "$file" in
        *.sh)  grep -qE "read_config[[:space:]]+\"$key\"" "$file" ;;
        *.ps1) grep -qE "Read-Config[[:space:]]+\"$key\"" "$file" ;;
        *.cmd) grep -qE "_key!\"==\"$key\"" "$file" ;;
        *)     grep -qw -- "$key" "$file" ;;
    esac
}

# ── ffmpeg: строгий трёхплатформенный паритет ─────────────────────────────
suite "ffmpeg: каждый ключ config.ini читается в run.sh/run.cmd/run.ps1"
FF="$PROJECT_DIR/ffmpeg"
assert_nonempty_keys "ffmpeg" "$FF/config.ini.example"
while IFS= read -r key; do
    [ -z "$key" ] && continue
    for plat in FFmpeg_Converter_run_v18.sh FFmpeg_Converter_run_v18.cmd FFmpeg_Converter_run_v18.ps1; do
        if key_is_read "$FF/$plat" "$key"; then pass "ffmpeg '$key' в $plat"
        else fail "ffmpeg '$key' в $plat" "читается" "отсутствует"; fi
    done
done < <(keys_of "$FF/config.ini.example")

# ── yt-dlp: минимум один читатель (нет мёртвых ключей) ────────────────────
suite "yt-dlp: каждый ключ config.ini читается хотя бы в .sh или .ps1"
YT="$PROJECT_DIR/yt-dlp"
assert_nonempty_keys "yt-dlp" "$YT/config.ini.example"
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if key_is_read "$YT/Downloading_from_YouTube_v18.sh" "$key" || key_is_read "$YT/Downloading_from_YouTube_v18.ps1" "$key"; then
        pass "yt-dlp '$key' (есть читатель)"
    else
        fail "yt-dlp '$key' (есть читатель)" "читается в .sh или .ps1" "нигде не читается (мёртвый ключ)"
    fi
done < <(keys_of "$YT/config.ini.example")

# ── Шаблон и рабочий конфиг не разошлись ──────────────────────────────────
suite "config.ini.example совпадает по ключам с рабочим config.ini"
# Источников истины стало два, и проверки выше смотрят только в шаблон: ключ,
# добавленный в личный config.ini и в скрипты, но забытый в .example, не поймает
# ничто — на свежем клоне он просто не появится, и настройка молча пропадёт.
# Рабочего конфига нет на CI (он gitignored) — там проверка честно пропускается.
for _pair in "ffmpeg" "yt-dlp"; do
    _live="$PROJECT_DIR/$_pair/config.ini"
    _tmpl="$PROJECT_DIR/$_pair/config.ini.example"
    if [ ! -f "$_live" ]; then
        skip "$_pair: ключи шаблона = ключам config.ini" "рабочего config.ini нет (CI/свежий клон)"
        continue
    fi
    _only_live="$(comm -23 <(keys_of "$_live" | sort -u) <(keys_of "$_tmpl" | sort -u) | tr '\n' ' ')"
    _only_tmpl="$(comm -13 <(keys_of "$_live" | sort -u) <(keys_of "$_tmpl" | sort -u) | tr '\n' ' ')"
    assert_empty "$_pair: нет ключей только в config.ini" "$_only_live"
    assert_empty "$_pair: нет ключей только в .example"   "$_only_tmpl"
done

summary
