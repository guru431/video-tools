#!/bin/bash
# ============================================================
# test_config_keys.sh — Meta-тест паритета ключей config.ini.
# Ключ, читаемый на одной платформе и забытый на другой — классическая parity-протечка,
# которую fragment-тесты не ловят. Здесь ".ini = контракт" становится enforced-инвариантом.
#   ffmpeg: каждый ключ ОБЯЗАН читаться в run.sh И run.cmd И run.ps1 (полный паритет).
#   yt-dlp: каждый ключ должен читаться хотя бы в .sh ИЛИ .ps1 (нет мёртвых ключей;
#           CMD интерактивен и config.ini не читает — исключён по дизайну).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Имена ключей из config.ini (строки "key = ..." вне комментариев/секций)
keys_of() { grep -oE '^[[:space:]]*[a-z_]+[[:space:]]*=' "$1" | sed 's/[[:space:]=]//g'; }

# ── ffmpeg: строгий трёхплатформенный паритет ─────────────────────────────
suite "ffmpeg: каждый ключ config.ini читается в run.sh/run.cmd/run.ps1"
FF="$PROJECT_DIR/ffmpeg"
while IFS= read -r key; do
    [ -z "$key" ] && continue
    for plat in FFmpeg_Converter_run_v15.sh FFmpeg_Converter_run_v15.cmd FFmpeg_Converter_run_v15.ps1; do
        if grep -qw -- "$key" "$FF/$plat"; then pass "ffmpeg '$key' в $plat"
        else fail "ffmpeg '$key' в $plat" "читается" "отсутствует"; fi
    done
done < <(keys_of "$FF/config.ini")

# ── yt-dlp: минимум один читатель (нет мёртвых ключей) ────────────────────
suite "yt-dlp: каждый ключ config.ini читается хотя бы в .sh или .ps1"
YT="$PROJECT_DIR/yt-dlp"
while IFS= read -r key; do
    [ -z "$key" ] && continue
    if grep -qw -- "$key" "$YT/Downloading_from_YouTube_v15.sh" || grep -qw -- "$key" "$YT/Downloading_from_YouTube_v15.ps1"; then
        pass "yt-dlp '$key' (есть читатель)"
    else
        fail "yt-dlp '$key' (есть читатель)" "читается в .sh или .ps1" "нигде не читается (мёртвый ключ)"
    fi
done < <(keys_of "$YT/config.ini")

summary
