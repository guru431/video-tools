#!/bin/bash
# ============================================================
# test_encoding.sh — Инвариант кодировок файлов (рецидивный класс поломок):
#   .ps1  — UTF-8 с BOM (PS 5.1 без BOM читает кириллицу как CP1251 → ломает парсинг)
#   .sh   — без BOM (BOM ломает shebang)
#   entry .cmd — chcp 65001 (UTF-8-консоль для кириллицы)
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

has_bom() { [ "$(head -c3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; }
rel() { echo "${1#"$PROJECT_DIR"/}"; }

# ── .ps1 — должны иметь BOM (кроме вендоренного ps2exe.ps1) ────────────────
suite ".ps1 — UTF-8 с BOM"
while IFS= read -r f; do
    if has_bom "$f"; then pass "BOM: $(rel "$f")"; else fail "BOM: $(rel "$f")" "есть BOM" "нет BOM"; fi
done < <(find "$PROJECT_DIR/ffmpeg" "$PROJECT_DIR/yt-dlp" "$PROJECT_DIR/tools" -name '*.ps1' ! -name 'ps2exe.ps1' 2>/dev/null)

# ── .sh — не должны иметь BOM (весь проект) ───────────────────────────────
suite ".sh — без BOM"
while IFS= read -r f; do
    if has_bom "$f"; then fail "no-BOM: $(rel "$f")" "нет BOM" "есть BOM"; else pass "no-BOM: $(rel "$f")"; fi
done < <(find "$PROJECT_DIR" -name '*.sh' 2>/dev/null)

# ── Entry-point .cmd — chcp 65001 (script.cmd наследует кодировку от run.cmd) ──
suite "entry .cmd — chcp 65001"
for f in "$PROJECT_DIR/ffmpeg/FFmpeg_Converter_run_v15.cmd" "$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.cmd"; do
    if grep -qi 'chcp 65001' "$f"; then pass "chcp: $(rel "$f")"; else fail "chcp: $(rel "$f")" "chcp 65001" "нет chcp"; fi
done

summary
