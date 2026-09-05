#!/bin/bash
# ============================================================
# test_15_cmd_smoke.sh — сквозной прогон yt-dlp/Downloading_from_YouTube_v18.cmd
#
# Все прочие CMD-тесты этого проекта проверяют ВЫРЕЗКИ из скрипта: подпрограмму,
# блок построения формата, отдельный `if`. Целиком интерактивный CLI не запускался
# ни разу — а ровно там живут отказы, которых вырезка не видит: `set /p` на
# закрытом stdin, метка `::` внутри блока, `pause` в конце, `exit /b`, порядок
# вопросов и их количество. Один сдвиг в цепочке ответов ломает ВСЁ меню, и
# юнит-тест подпрограммы остаётся зелёным.
#
# Прогон настоящий: скрипт копируется в temp, рядом кладутся МОК-БИНАРНИКИ
# (.exe, не .cmd — см. ниже), ответы меню подаются в stdin, а проверяются argv
# дочерних процессов и код возврата.
#
# Почему моки — .exe, а не .cmd: `"!dlp!" args` вызывается БЕЗ `call`, и cmd.exe
# при переходе на другой батник управление обратно НЕ возвращает — скрипт молча
# обрывался бы на первой же строке загрузки, а тест бы это «прошёл». Настоящий
# .exe собирается на месте из C# через Add-Type (csc идёт с .NET Framework).
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

CMD_SCRIPT="$REPO_DIR/yt-dlp/Downloading_from_YouTube_v18.cmd"

if ! cmd //c "exit 0" &>/dev/null; then
    suite "CMD yt-dlp: сквозной прогон"
    skip "Сквозной прогон CMD" "cmd.exe не доступен"
    summary
    exit 0
fi
if ! command -v powershell >/dev/null 2>&1; then
    suite "CMD yt-dlp: сквозной прогон"
    skip "Сквозной прогон CMD" "powershell не доступен (нужен для сборки мок-EXE)"
    summary
    exit 0
fi

TMP_DIR=$(mktemp -d "/tmp/test_ytcmd_smoke_XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_WIN=$(cygpath -w "$TMP_DIR" 2>/dev/null || printf '%s' "$TMP_DIR")

# ── Мок-бинарник ──────────────────────────────────────────────────────────
# Один исходник на все четыре роли: ветвится по собственному имени файла. Так
# проверяется и то, что скрипт зовёт ИМЕННО тот бинарник, который нашёл рядом с
# собой (local-first), — имя роли попадает в общий лог вызовов.
cat > "$TMP_DIR/mock.cs" <<'CSEOF'
using System;
using System.IO;
using System.Text;

class MockBin {
    static string Role() {
        string n = AppDomain.CurrentDomain.FriendlyName;
        if (n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) n = n.Substring(0, n.Length - 4);
        return n;
    }

    static int Main(string[] a) {
        string role = Role();
        string log = Environment.GetEnvironmentVariable("MOCK_LOG");
        if (!String.IsNullOrEmpty(log))
            File.AppendAllText(log, role + " ARGS: " + String.Join(" | ", a) + "\n", new UTF8Encoding(false));

        if (role == "yt-dlp") return YtDlp(a);
        if (role == "vot-cli-live") return Vot(a);
        if (role == "ffprobe") return FFprobe();
        if (role == "ffmpeg") return FFmpeg(a);
        return 0;
    }

    static int YtDlp(string[] a) {
        if (Array.IndexOf(a, "--get-title") >= 0) { Console.WriteLine("Mock Video Title"); return 0; }
        if (Array.IndexOf(a, "--version") >= 0) { Console.WriteLine("2099.01.01"); return 0; }

        string outFile = Environment.GetEnvironmentVariable("MOCK_OUT_FILE");
        if (!String.IsNullOrEmpty(outFile)) {
            Directory.CreateDirectory(Path.GetDirectoryName(outFile));
            File.WriteAllText(outFile, "video-bytes");
        }
        // Манифест --print-to-file after_move:filepath <файл>: путь идёт ЧЕРЕЗ один
        // аргумент после ключа. Пустым он остаётся, если MOCK_MANIFEST_EMPTY=1 —
        // это сценарий «всё уже в архиве», отдельная ветка скрипта.
        int i = Array.IndexOf(a, "--print-to-file");
        if (i >= 0 && i + 2 < a.Length && !String.IsNullOrEmpty(outFile)
            && Environment.GetEnvironmentVariable("MOCK_MANIFEST_EMPTY") != "1") {
            File.WriteAllText(a[i + 2], outFile + Environment.NewLine, new UTF8Encoding(false));
        }
        Console.WriteLine("[download] 100% of 1.00MiB");
        string rc = Environment.GetEnvironmentVariable("MOCK_DLP_RC");
        return String.IsNullOrEmpty(rc) ? 0 : int.Parse(rc);
    }

    static int Vot(string[] a) {
        string rc = Environment.GetEnvironmentVariable("MOCK_VOT_RC");
        foreach (string s in a) {
            if (s.StartsWith("--output=")) {
                string dir = s.Substring("--output=".Length);
                Directory.CreateDirectory(dir);
                // Имя как у настоящего vot — из названия ролика, со спецсимволом:
                // скрипт обязан переименовать его в фиксированное translated.mp3.
                if (String.IsNullOrEmpty(rc) || rc == "0")
                    File.WriteAllText(Path.Combine(dir, "Mock Video Title!.mp3"), "mp3-bytes");
            }
        }
        return String.IsNullOrEmpty(rc) ? 0 : int.Parse(rc);
    }

    static int FFprobe() {
        int n = 1;
        string s = Environment.GetEnvironmentVariable("MOCK_ACOUNT");
        if (!String.IsNullOrEmpty(s)) n = int.Parse(s);
        for (int k = 0; k < n; k++) Console.WriteLine(k.ToString());
        return 0;
    }

    static int FFmpeg(string[] a) {
        string rc = Environment.GetEnvironmentVariable("MOCK_FF_RC");
        if (a.Length > 0 && (String.IsNullOrEmpty(rc) || rc == "0")) {
            string outp = a[a.Length - 1];
            try { File.WriteAllText(outp, "merged-bytes"); } catch {}
        }
        return String.IsNullOrEmpty(rc) ? 0 : int.Parse(rc);
    }
}
CSEOF

cat > "$TMP_DIR/build_mock.ps1" <<'PSEOF'
$ErrorActionPreference = 'Stop'
$dir = $PSScriptRoot
$src = Get-Content -LiteralPath (Join-Path $dir 'mock.cs') -Raw
Add-Type -TypeDefinition $src -OutputAssembly (Join-Path $dir 'yt-dlp.exe') -OutputType ConsoleApplication
foreach ($n in @('vot-cli-live.exe', 'ffmpeg.exe', 'ffprobe.exe')) {
    Copy-Item -LiteralPath (Join-Path $dir 'yt-dlp.exe') -Destination (Join-Path $dir $n) -Force
}
PSEOF

if ! powershell -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$TMP_DIR/build_mock.ps1" 2>/dev/null || printf '%s' "$TMP_DIR/build_mock.ps1")" >/dev/null 2>&1 \
   || [ ! -f "$TMP_DIR/yt-dlp.exe" ]; then
    suite "CMD yt-dlp: сквозной прогон"
    skip "Сквозной прогон CMD" "не удалось собрать мок-EXE (нет csc от .NET Framework)"
    summary
    exit 0
fi

# В КОПИИ для теста глушим `chcp 65001`. Это не косметика: при активной кодовой
# странице 65001 cmd.exe вообще не читает `set /p` из перенаправленного файла —
# проверено на UTF-8, UTF-8 с BOM, UTF-16LE и UTF-16LE с BOM, каждый раз пустая
# строка. Пайп не спасает: из него `set /p` забирает весь буфер за первое
# обращение, и второй вопрос уже пуст. Другого способа прогнать интерактивное
# меню не-интерактивно нет, а сама строка chcp к проверяемой логике отношения не
# имеет и отдельно закреплена в tests/common/test_encoding.sh.
#
# Копию собираем awk'ом, а НЕ `sed … > файл`: msys-sed в текстовом режиме срезает
# \r, и копия уезжает в LF-only — то самое, от чего .gitattributes и
# tests/common/test_encoding.sh защищают настоящие .cmd (cmd.exe склеивает строки
# многострочных блоков `( … )`). Здесь awk дописывает \r обратно на каждой строке.
awk '{
    sub(/\r$/, "")
    if ($0 == "chcp 65001 >nul 2>&1") $0 = "rem chcp 65001 (заглушено тестом, см. заголовок)"
    printf "%s\r\n", $0
}' "$CMD_SCRIPT" > "$TMP_DIR/dl.cmd"

# Обёртка с `chcp` здесь не поможет и намеренно не заведена: измерено, что ЛЮБОЙ
# вызов `chcp` (не только 65001, но и 437) в том же процессе делает последующий
# `set /p` из перенаправленного файла пустым. Ломает не кодовая страница, а сама
# смена — видимо, пересоздание входного дескриптора. Отсюда и форма заглушки выше:
# строку `chcp` в копии надо именно УБРАТЬ, а не подменить другой.
DL_WIN="$TMP_WIN\\dl.cmd"
# ── Хелпер: прогон меню ───────────────────────────────────────────────────
# Ответы подаём РЕДИРЕКТОМ ИЗ ФАЙЛА, а не пайпом: из пайпа `set /p` вычитывает
# весь буфер за первое же обращение — второй вопрос и все следующие получают
# пустоту. Из файла читается построчно, как из консоли. Ровно поэтому и сам
# скрипт обязан отдавать своим `for /f`-потомкам пустой stdin (`<nul`): иначе
# первый же из них съедает файл целиком, и меню отвечает умолчаниями на всё.
SMOKE_OUT=""
SMOKE_RC=0
SMOKE_LOG=""

# Ответы задаются ИМЕНАМИ полей, а не позицией в списке: цепочка из одиннадцати
# пустых строк неотличима от цепочки из десяти, и промах на одну строку сдвигает
# ВСЁ меню — тест при этом остаётся зелёным, проверяя не тот сценарий (именно так
# и вышло при первом прогоне). Порядок ниже повторяет порядок вопросов скрипта.
# Пустое значение = Enter, то есть умолчание.
run_menu() {
    local url="" quality="" cookie="" cookie_path="" proxy="" ts="" te="" kf="" \
          translate="" ov="" tv="" fmt="" audiofmt="" sb="" subsvid=""
    local kv
    for kv in "$@"; do
        case "$kv" in
            url=*)        url="${kv#url=}" ;;
            quality=*)    quality="${kv#quality=}" ;;
            cookie=*)     cookie="${kv#cookie=}" ;;
            cookiepath=*) cookie_path="${kv#cookiepath=}" ;;
            proxy=*)      proxy="${kv#proxy=}" ;;
            ts=*)         ts="${kv#ts=}" ;;
            te=*)         te="${kv#te=}" ;;
            kf=*)         kf="${kv#kf=}" ;;
            translate=*)  translate="${kv#translate=}" ;;
            ov=*)         ov="${kv#ov=}" ;;
            tv=*)         tv="${kv#tv=}" ;;
            fmt=*)        fmt="${kv#fmt=}" ;;
            audiofmt=*)   audiofmt="${kv#audiofmt=}" ;;
            sb=*)         sb="${kv#sb=}" ;;
            subsvid=*)    subsvid="${kv#subsvid=}" ;;
            *) fail "run_menu: неизвестное поле" "url/quality/cookie/…" "$kv" ;;
        esac
    done

    local lines=("$url" "$quality" "$cookie")
    # Путь к cookies спрашивают только при варианте «из файла».
    [ "$cookie" = "4" ] && lines+=("$cookie_path")
    lines+=("$proxy" "$ts" "$te")
    # Про точную обрезку спрашивают, только если задана хотя бы одна граница.
    { [ -n "$ts" ] || [ -n "$te" ]; } && lines+=("$kf")
    lines+=("$translate")
    # Баланс дорожек спрашивают только в режиме mix (вариант 2).
    [ "$translate" = "2" ] && lines+=("$ov" "$tv")
    lines+=("$fmt" "$audiofmt" "$sb" "$subsvid")

    rm -rf "$TMP_DIR/_video_" "$TMP_DIR/calls.log"
    : > "$TMP_DIR/calls.log"
    printf '%s\n' "${lines[@]}" | sed 's/$/\r/' > "$TMP_DIR/answers.txt"
    SMOKE_OUT=$(env \
        MOCK_LOG="$TMP_WIN\\calls.log" \
        MOCK_OUT_FILE="$TMP_WIN\\_video_\\Mock Video Title.mp4" \
        MOCK_ACOUNT="${MOCK_ACOUNT:-}" \
        MOCK_DLP_RC="${MOCK_DLP_RC:-}" \
        MOCK_VOT_RC="${MOCK_VOT_RC:-}" \
        MOCK_FF_RC="${MOCK_FF_RC:-}" \
        MOCK_MANIFEST_EMPTY="${MOCK_MANIFEST_EMPTY:-}" \
        cmd //c "$DL_WIN" < "$TMP_DIR/answers.txt" 2>&1)
    SMOKE_RC=$?
    SMOKE_LOG=$(cat "$TMP_DIR/calls.log" 2>/dev/null | tr -d '\r')
}

# Прогон с пустым/битым URL: скрипт отказывает до первого вопроса меню, и
# позиционная цепочка здесь не нужна вовсе.
run_url_only() {
    rm -rf "$TMP_DIR/_video_" "$TMP_DIR/calls.log"
    : > "$TMP_DIR/calls.log"
    printf '%s\n' "$1" | sed 's/$/\r/' > "$TMP_DIR/answers.txt"
    SMOKE_OUT=$(env \
        MOCK_LOG="$TMP_WIN\\calls.log" \
        MOCK_OUT_FILE="$TMP_WIN\\_video_\\Mock Video Title.mp4" \
        cmd //c "$DL_WIN" < "$TMP_DIR/answers.txt" 2>&1)
    SMOKE_RC=$?
    SMOKE_LOG=$(cat "$TMP_DIR/calls.log" 2>/dev/null | tr -d '\r')
}

YT_URL="https://www.youtube.com/watch?v=dQw4w9WgXcQ"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: сквозной прогон — обычная загрузка"
# ══════════════════════════════════════════════════════════════
run_menu url="$YT_URL" quality=3 cookie=0 translate=0 audiofmt=0 sb=0 subsvid=0

assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "скрипт дошёл до финального сообщения" "Загрузка завершена успешно!" "$SMOKE_OUT"
assert_contains "yt-dlp вызван за названием" "yt-dlp ARGS:" "$SMOKE_LOG"
assert_contains "название запрошено с --get-title" "--get-title" "$SMOKE_LOG"
assert_contains "плейлист не разворачивается ради названия" "--flat-playlist" "$SMOKE_LOG"
assert_contains "загрузка ушла с --windows-filenames" "--windows-filenames" "$SMOKE_LOG"
assert_contains "выход направлен в _video_" "_video_" "$SMOKE_LOG"
assert_contains "архив загрузок подключён" "--download-archive" "$SMOKE_LOG"
assert_contains "метаданные и главы вшиваются" "--embed-metadata" "$SMOKE_LOG"
# YouTube + auto → пресет avc1_best: без него молча уехали бы на «best» и получили VP9/AV1.
assert_contains "для YouTube выбран avc1-пресет" "avc1" "$SMOKE_LOG"
# Без перевода манифест не нужен — лишний файл в %TEMP% на каждую загрузку.
assert_not_contains "без перевода манифест не запрашивается" "--print-to-file" "$SMOKE_LOG"
assert_not_contains "vot без перевода не зовётся" "vot-cli-live ARGS:" "$SMOKE_LOG"
assert_file_exists "файл загрузки создан" "$TMP_DIR/_video_/Mock Video Title.mp4"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: сквозной прогон — AI-перевод (mix)"
# ══════════════════════════════════════════════════════════════
run_menu url="$YT_URL" quality=3 cookie=0 translate=2 ov=0.5 tv=0.9 audiofmt=0 sb=0 subsvid=0

assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "манифест запрошен у yt-dlp" "--print-to-file | after_move:filepath" "$SMOKE_LOG"
assert_contains "vot вызван" "vot-cli-live ARGS:" "$SMOKE_LOG"
assert_contains "vot получил язык перевода" "--reslang=ru" "$SMOKE_LOG"
assert_contains "vot получил каталог вывода" "--output=" "$SMOKE_LOG"
assert_contains "ffmpeg вызван на мерж" "ffmpeg ARGS:" "$SMOKE_LOG"
assert_contains "режим mix собран через amix" "amix=inputs=2" "$SMOKE_LOG"
# Введённые громкости обязаны доехать до фильтра: раньше они были захардкожены.
assert_contains "громкость оригинала из ввода" "volume=0.5" "$SMOKE_LOG"
assert_contains "громкость перевода из ввода" "volume=0.9" "$SMOKE_LOG"
assert_contains "перевод объявлен успешным" "Перевод добавлен успешно!" "$SMOKE_OUT"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: сквозной прогон — dual_track и число дорожек"
# ══════════════════════════════════════════════════════════════
# ffprobe отдаёт ДВЕ оригинальные дорожки → индекс перевода = 2, а не 1.
MOCK_ACOUNT=2 run_menu url="$YT_URL" quality=3 cookie=0 translate=1 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "ffprobe спрошен о дорожках" "ffprobe ARGS:" "$SMOKE_LOG"
assert_contains "перевод помечен трёхбуквенным кодом" "language=rus" "$SMOKE_LOG"
assert_contains "оригинал помечен как eng" "language=eng" "$SMOKE_LOG"
# mp4 не пишет per-stream title — имя дорожки доезжает только через handler_name.
assert_contains "имя дорожки пишется в handler_name" "handler_name" "$SMOKE_LOG"
# Две оригинальные дорожки → перевод садится на a:2, а не на a:1.
assert_contains "перевод сел на a:2 при двух оригиналах" "-c:a:2" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: перевод несовместим с режимом → отключается вслух"
# ══════════════════════════════════════════════════════════════
# Качество 0 (только аудио) + перевод 1: видеофайла для мержа не будет.
run_menu url="$YT_URL" quality=0 cookie=0 translate=1 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "перевод отключён с объяснением" "AI-перевод отключён" "$SMOKE_OUT"
assert_not_contains "vot не вызывался" "vot-cli-live ARGS:" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: плейлист — свой шаблон, перевод недоступен"
# ══════════════════════════════════════════════════════════════
run_menu url="https://www.youtube.com/playlist?list=PL0000000000" \
         quality=3 cookie=0 translate=1 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "перевод отключён для плейлиста" "недоступен для плейлистов" "$SMOKE_OUT"
assert_contains "использован playlist-шаблон" "playlist_index" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: пустой манифест = архив, перевод пропускается"
# ══════════════════════════════════════════════════════════════
# yt-dlp вернул 0, но НИЧЕГО не переместил (видео уже в архиве). Проверка должна
# отработать ДО сетевого вызова vot — иначе перевод качается впустую минуты.
MOCK_MANIFEST_EMPTY=1 run_menu url="$YT_URL" quality=3 cookie=0 translate=1 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 0 (архив — не ошибка)" "0" "$SMOKE_RC"
assert_contains "сказано, что видео уже в архиве" "видео уже было в архиве" "$SMOKE_OUT"
assert_not_contains "vot не вызывался" "vot-cli-live ARGS:" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: обрезка ролика и её валидация"
# ══════════════════════════════════════════════════════════════
run_menu url="$YT_URL" quality=3 cookie=0 ts=00:01:00 te=00:02:00 kf=y \
         translate=0 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 0" "0" "$SMOKE_RC"
assert_contains "фрагмент ушёл в --download-sections" "--download-sections" "$SMOKE_LOG"
assert_contains "границы фрагмента верны" "*00:01:00-00:02:00" "$SMOKE_LOG"
assert_contains "точная обрезка включена по ответу y" "--force-keyframes-at-cuts" "$SMOKE_LOG"

# Некорректное время отбрасывается с предупреждением, а не уезжает в argv.
run_menu url="$YT_URL" quality=3 cookie=0 ts=1min translate=0 audiofmt=0 sb=0 subsvid=0
assert_contains "некорректное время начала отбито" "Некорректное время начала" "$SMOKE_OUT"
assert_not_contains "мусорное время не попало в argv" "1min" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: провал загрузки → ненулевой код возврата"
# ══════════════════════════════════════════════════════════════
# Скрипт запускают из cron/CI, и «ошибка» обязана быть видна кодом, а не только
# цветом консоли.
MOCK_DLP_RC=1 run_menu url="$YT_URL" quality=3 cookie=0 translate=0 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 1" "1" "$SMOKE_RC"
assert_contains "сообщение об ошибке загрузки" "Ошибка при загрузке!" "$SMOKE_OUT"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: перевод запрошен, но не выполнен → код 1"
# ══════════════════════════════════════════════════════════════
# F14: загрузка успешна, перевода нет — это НЕ полный успех.
MOCK_VOT_RC=1 run_menu url="$YT_URL" quality=3 cookie=0 translate=1 audiofmt=0 sb=0 subsvid=0
assert_eq "код возврата 1" "1" "$SMOKE_RC"
assert_contains "итог отражает несделанный перевод" "AI-перевод не выполнен" "$SMOKE_OUT"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: пустой URL — отказ до всякой работы"
# ══════════════════════════════════════════════════════════════
run_url_only ""
assert_eq "код возврата 1" "1" "$SMOKE_RC"
assert_contains "сказано, что URL обязателен" "URL обязателен!" "$SMOKE_OUT"
assert_empty "ни один бинарник не вызван" "$SMOKE_LOG"

# ══════════════════════════════════════════════════════════════
suite "CMD yt-dlp: URL с чужой схемой отбивается"
# ══════════════════════════════════════════════════════════════
run_url_only "file:///C:/Windows/System32/calc.exe"
assert_eq "код возврата 1" "1" "$SMOKE_RC"
assert_contains "требование схемы http(s)" "http:// или https://" "$SMOKE_OUT"
assert_empty "ни один бинарник не вызван" "$SMOKE_LOG"

summary
