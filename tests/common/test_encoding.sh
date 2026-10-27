#!/bin/bash
# ============================================================
# test_encoding.sh — Инвариант кодировок файлов (рецидивный класс поломок):
#   .ps1  — UTF-8 с BOM (PS 5.1 без BOM читает кириллицу как CP1251 → ломает парсинг)
#   .sh   — без BOM (BOM ломает shebang)
#   entry .cmd — chcp 65001 (UTF-8-консоль для кириллицы)
#   .cmd  — CRLF-концы строк (с LF cmd.exe неверно разбирает многострочные блоки)
#   .sha256 — LF при checkout (с CRLF `sha256sum -c` не находит файл)
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

# Первые три байта — встроенным `read` в C-локали (байт = символ), а не
# `head | od | tr`: четыре процесса на каждый из десятков файлов набора.
has_bom() {
    local LC_ALL=C b=""
    IFS= read -r -n 3 -d '' b < "$1" 2>/dev/null
    [ "$b" = $'\xef\xbb\xbf' ]
}
# REL ← путь $1 относительно корня проекта (без подоболочки на вызов).
rel() { REL="${1#"$PROJECT_DIR"/}"; }

# ── .ps1 — должны иметь BOM (кроме вендоренного ps2exe.ps1) ────────────────
suite ".ps1 — UTF-8 с BOM"
while IFS= read -r f; do
    rel "$f"
    if has_bom "$f"; then pass "BOM: $REL"; else fail "BOM: $REL" "есть BOM" "нет BOM"; fi
done < <(find "$PROJECT_DIR/ffmpeg" "$PROJECT_DIR/yt-dlp" "$PROJECT_DIR/tools" -name '*.ps1' ! -name 'ps2exe.ps1' 2>/dev/null)

# ── .sh — не должны иметь BOM (весь проект) ───────────────────────────────
suite ".sh — без BOM"
while IFS= read -r f; do
    rel "$f"
    if has_bom "$f"; then fail "no-BOM: $REL" "нет BOM" "есть BOM"; else pass "no-BOM: $REL"; fi
done < <(find "$PROJECT_DIR" -name '*.sh' 2>/dev/null)

# ── Entry-point .cmd — chcp 65001 (script.cmd наследует кодировку от run.cmd) ──
suite "entry .cmd — chcp 65001"
for f in "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v21.cmd" "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v21.cmd"; do
    rel "$f"
    if grep -qi 'chcp 65001' "$f"; then pass "chcp: $REL"; else fail "chcp: $REL" "chcp 65001" "нет chcp"; fi
done

# ── Все .cmd — CRLF-концы строк ───────────────────────────────────────────
# Находка 2026-07-25: `tests/mocks/ffmpeg.cmd` выкладывался с LF (glob
# `tests/mocks/*  text eol=lf` в .gitattributes написан для extension-less bash-моков,
# но захватывал и .cmd). С LF cmd.exe склеивает строки многострочных `( )`-блоков:
# ссылки %1 раскрываются один раз, `shift` перестаёт двигать аргументы, и goto-цикл
# `:find_out` уходил в бесконечный цикл на 100% CPU без дочерних процессов — полный
# прогон вставал на test_16/test_17 намертво (лечилось только kill извне).
# Проверяем ВСЕ .cmd: ни один не имеет права оказаться с LF-концами.
suite ".cmd — CRLF-концы строк"
while IFS= read -r f; do
    _crlf=$(grep -c $'\r$' "$f" 2>/dev/null || echo 0)
    _all=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    rel "$f"
    if [ "${_all:-0}" -gt 0 ] && [ "$_crlf" = "$_all" ]; then
        pass "CRLF: $REL"
    else
        fail "CRLF: $REL" "все $_all строк с CRLF" "с CRLF только $_crlf"
    fi
done < <(find "$PROJECT_DIR" -name '*.cmd' -not -path '*/.git/*' 2>/dev/null)

# ── .sha256 — из git выходят с LF при любом core.autocrlf ─────────────────
# Sidecar сверяют `sha256sum -c`, а для него CR в конце строки — часть имени файла:
# «No such file or directory» на верной сумме. Write-ExeChecksum пишет LF, но без
# атрибута core.autocrlf=true (умолчание Git for Windows) возвращал CRLF при первом же
# checkout — свежий Windows-клон не мог сверить EXE с его собственным sidecar. Рабочая
# копия этого не показывает (сразу после сборки в ней LF), поэтому спрашиваем у git
# действующий атрибут: один процесс на все файлы.
suite ".sha256 — LF при checkout"
_sidecars=()
while IFS= read -r f; do
    rel "$f"; _sidecars+=("$REL")
done < <(find "$PROJECT_DIR/ffmpeg" "$PROJECT_DIR/yt-dlp" -maxdepth 1 -name '*.sha256' 2>/dev/null)
if [ "${#_sidecars[@]}" -eq 0 ]; then
    fail "sidecar-файлы .sha256 на месте" "хотя бы один" "ни одного"
elif _attrs=$(git -C "$PROJECT_DIR" check-attr eol -- "${_sidecars[@]}" 2>/dev/null); then
    for f in "${_sidecars[@]}"; do
        assert_contains "eol=lf: $f" "$f: eol: lf" "$_attrs"
    done
else
    skip ".sha256: действующий атрибут eol" "git не ответил"
fi

summary
