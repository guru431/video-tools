#!/bin/bash
# ============================================================
# test_docs_links.sh — ссылки и пути в документации ведут на существующие файлы.
#
# Имена файлов в этом репозитории несут номер версии, и при каждом её подъёме
# ссылки протухают МОЛЧА. Одновременно в дереве жили: ссылка на CMD-файл прошлой
# версии в CLAUDE.md и AGENTS.md, битая markdown-ссылка на GUI прошлой версии в
# спеке удалённого бэкенда, хардкод имён EXE в CI и release-manifest.json — и ни
# одна из них не давала сигнала.
#
# Проверяем три вещи:
#   1. markdown-ссылки [текст](относительный/путь) указывают на существующее;
#   2. inline-`код`, похожий на путь внутри репозитория, существует;
#   3. имена EXE в .github/workflows/ci.yml и release-manifest.json совпадают
#      с файлами на диске (там путь живёт вне markdown и потому мимо пунктов 1-2).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/framework.sh"

# Исключения — списком и с причиной. Без причины запись не добавляется: молчащее
# исключение ничем не лучше молчащей битой ссылки.
is_excluded() {
    case "$1" in
        # gitignored: рабочие файлы пользователя, на свежем клоне их нет
        ffmpeg/config.ini|yt-dlp/config.ini|yt-dlp/channels.txt) return 0 ;;
        .sanitize-patterns) return 0 ;;
        # временный конфиг, который тест пишет сам перед запуском
        tests/ffmpeg/config.ini) return 0 ;;
        # пути ВНУТРИ стороннего архива (инструкция по распаковке ffmpeg)
        bin/*) return 0 ;;
        # внешняя вики: живёт вне репозитория (см. docs/knowledge-base.md)
        wiki/*|cron/*|projects/index.md) return 0 ;;
        # плейсхолдеры в инструкциях («создайте test_NN_new.sh»)
        *_new.sh) return 0 ;;
        */\<*\>*|*path/to/*|*your/*) return 0 ;;
    esac
    return 1
}

# Документы — ДЕЙСТВУЮЩИЕ. Исторические (архивы находок, планы прошлых работ)
# сознательно не трогаем: они фиксируют состояние на свою дату, и «починить» в
# них ссылку на v14 значило бы подделать запись. Спеки при этом действующие —
# спека удалённого бэкенда остаётся единственным документом с контрактом HTTP.
docs=()
while IFS= read -r f; do docs+=("$f"); done < <(
    find "$PROJECT_DIR" -maxdepth 1 -name '*.md' -type f ! -name '*-archive.md'
    find "$PROJECT_DIR/docs" -name '*.md' -type f -not -path '*/plans/*' 2>/dev/null
    find "$PROJECT_DIR/tests" -maxdepth 1 -name '*.md' -type f 2>/dev/null
    # tools/**/*.md и .github/**/*.md — тоже действующие документы: они описывают
    # рабочие процедуры (сборка, пробы антивируса, CI), и ссылка в никуда там стоит
    # ровно столько же, сколько в README. Раньше они не сканировались вовсе.
    find "$PROJECT_DIR/tools" -name '*.md' -type f 2>/dev/null
    find "$PROJECT_DIR/.github" -name '*.md' -type f 2>/dev/null
)

# ══════════════════════════════════════════════════════════════
suite "markdown-ссылки ведут на существующие файлы"
# ══════════════════════════════════════════════════════════════
broken_links=""
for d in "${docs[@]}"; do
    [ -f "$d" ] || continue
    dir="$(dirname "$d")"
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        # Внешние ссылки и якоря внутри страницы не наше дело.
        case "$target" in http*|mailto:*|\#*|'') continue ;; esac
        # Якорь и параметры отрезаем: файл — это то, что до '#'.
        target="${target%%#*}"
        [ -n "$target" ] || continue
        is_excluded "$target" && continue
        if [ ! -e "$dir/$target" ]; then
            broken_links="$broken_links ${d#$PROJECT_DIR/}→$target"
        fi
    done < <(grep -oE '\]\([^)]+\)' "$d" | sed -e 's/^](//' -e 's/)$//')
done
assert_empty "нет markdown-ссылок в никуда" "$broken_links"

# ══════════════════════════════════════════════════════════════
suite "пути в inline-коде документации существуют"
# ══════════════════════════════════════════════════════════════
# Ловим только то, что ЯВНО выглядит путём внутри репозитория: `каталог/файл.ext`
# с известным расширением. Иначе в выборку попадут команды, ключи и regexp'ы.
broken_paths=""
for d in "${docs[@]}"; do
    [ -f "$d" ] || continue
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        is_excluded "$p" && continue
        if [ ! -e "$PROJECT_DIR/$p" ]; then
            broken_paths="$broken_paths ${d#$PROJECT_DIR/}→$p"
        fi
    done < <(grep -oE '`[a-z0-9_.-]+/[A-Za-z0-9_./-]+\.(sh|ps1|cmd|md|yaml|yml|json|ini|exe|py|txt)`' "$d" \
             | tr -d '`' | sort -u)
done
assert_empty "нет ссылок на несуществующие файлы в inline-коде" "$broken_paths"

# ══════════════════════════════════════════════════════════════
suite "имена EXE в CI и release-manifest совпадают с файлами"
# ══════════════════════════════════════════════════════════════
# Единственные пути, живущие вне markdown: их не поймает ни одна проверка выше,
# а расходятся они при том же событии — подъёме версии в имени файла.
CI="$PROJECT_DIR/.github/workflows/ci.yml"
MANIFEST="$PROJECT_DIR/release-manifest.json"

missing_exe=""
for _f in "$CI" "$MANIFEST"; do
    [ -f "$_f" ] || { fail "$(basename "$_f") на месте" "файл есть" "не найден"; continue; }
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        [ -e "$PROJECT_DIR/$p" ] || missing_exe="$missing_exe $(basename "$_f")→$p"
    done < <(grep -oE '(ffmpeg|yt-dlp)/[A-Za-z0-9_.-]+\.(exe|ps1)' "$_f" | sort -u)
done
assert_empty "все пути EXE/PS1 из CI и manifest существуют" "$missing_exe"

# Обратная сторона: собранный EXE обязан быть перечислен в манифесте. Иначе
# провенанс молча теряет артефакт при переименовании.
unlisted=""
while IFS= read -r exe; do
    rel="${exe#$PROJECT_DIR/}"
    grep -qF "$rel" "$MANIFEST" 2>/dev/null || unlisted="$unlisted $rel"
done < <(find "$PROJECT_DIR/ffmpeg" "$PROJECT_DIR/yt-dlp" -maxdepth 1 -name '_Video*.exe' 2>/dev/null)
assert_empty "каждый собранный EXE перечислен в release-manifest.json" "$unlisted"

summary
