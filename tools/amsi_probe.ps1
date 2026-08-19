# amsi_probe.ps1 — находит место в скрипте, на которое антивирус выносит вердикт.
#
# Зачем. GUI поставляется как EXE (ps2exe), внутри которого лежит PowerShell-скрипт.
# Перед исполнением движок отдаёт его текст антивирусу через AMSI; при отказе показывается
# «This script contains malicious content and has been blocked by your antivirus software»
# с указанием line:1 — то есть на начало скрипта, а не на место проблемы. Какая именно
# конструкция не понравилась, из сообщения не видно.
#
# Как. Скрипт компилирует куски проверяемого файла и смотрит, какие получают вердикт.
# Компиляция ([ScriptBlock]::Create) разбирает код, но НЕ исполняет его: ни одна строка
# проверяемого файла не выполняется. Резать можно не где попало — кусок обязан оставаться
# синтаксически целым, иначе вместо вердикта получим ошибку разбора. Поэтому границы
# берутся по верхнеуровневым инструкциям из настоящего AST файла.
#
# Режимы:
#   Compile (по умолчанию) — куски компилируются как КОД. Ловит и сигнатуры в тексте,
#                            и правила, которые смотрят на структуру кода.
#   Comment                — куски оборачиваются в блочный комментарий <# ... #>. Текст
#                            доходит до антивируса дословно, но кодом не является. Ловит
#                            только сигнатуры по тексту; поведенческие правила — нет.
#
# Использование (на машине, где ошибка воспроизводится):
#   powershell -ExecutionPolicy Bypass -File tools\amsi_probe.ps1 yt-dlp\Downloading_from_YouTube_v17.ps1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    [ValidateSet('Compile', 'Comment')]
    [string]$Mode = 'Compile'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "Файл не найден: $Path"; exit 1 }

$full  = (Resolve-Path -LiteralPath $Path).Path
$text  = [System.IO.File]::ReadAllText($full)
$lines = [System.IO.File]::ReadAllLines($full)
Write-Host "Файл:   $Path  ($($lines.Count) строк)"
Write-Host "Режим:  $Mode"

if ($Mode -eq 'Comment' -and (($lines -match '<#') -or ($lines -match '#>'))) {
    Write-Host "ОТКАЗ: файл содержит '<#' или '#>' — обёртка в комментарий небезопасна."
    exit 1
}

$script:LastMessage = ''

# $true — антивирус вынес вердикт. Ошибки разбора отсекаются отдельно: при их появлении
# кусок считается непроверяемым, а не «чистым», иначе двоичный поиск ушёл бы не туда.
function Test-Verdict {
    param([string]$Fragment)
    if ([string]::IsNullOrWhiteSpace($Fragment)) { return $false }
    $payload = if ($Mode -eq 'Comment') { "<#`n$Fragment`n#>" } else { $Fragment }
    try {
        [void][ScriptBlock]::Create($payload)
        return $false
    } catch {
        $msg = $_.Exception.Message
        $script:LastMessage = $msg
        # Отличаем вердикт антивируса от синтаксической ошибки. Текст сообщения
        # локализован, поэтому смотрим и на английский, и на русский варианты.
        if ($msg -match 'malicious|вредонос') { return $true }
        Write-Host "  (пропуск: кусок не разобрался — $($msg.Split("`n")[0]))"
        return $false
    }
}

# Границы верхнеуровневых инструкций: только по ним можно резать, не ломая синтаксис.
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
if ($errors -and $errors.Count -gt 0) {
    Write-Host "ВНИМАНИЕ: файл сам по себе не разбирается ($($errors.Count) ошибок) — результат ненадёжен."
}
$stmts = @($ast.EndBlock.Statements)
$cuts  = @($stmts | ForEach-Object { $_.Extent.EndLineNumber } | Sort-Object -Unique)
Write-Host "Верхнеуровневых инструкций: $($stmts.Count), точек разреза: $($cuts.Count)"

function Get-Prefix { param([int]$UpToLine) return ($lines[0..($UpToLine - 1)] -join "`n") }

Write-Host "`n[1/3] Проверяю файл целиком..."
if (-not (Test-Verdict $text)) {
    Write-Host "Вердикта нет: этот путь запуска антивирус не блокирует."
    Write-Host "Если EXE при этом блокируется — дело не в тексте скрипта, а в способе запуска"
    Write-Host "(ps2exe исполняет скрипт из памяти через AddScript, а не из файла)."
    exit 0
}
Write-Host "Вердикт есть. Сообщение:"
Write-Host "  $script:LastMessage"

Write-Host "`n[2/3] Ищу первую инструкцию, на которой появляется вердикт..."
$lo = 0; $hi = $cuts.Count - 1
while ($lo -lt $hi) {
    $mid = [int](($lo + $hi) / 2)
    if (Test-Verdict (Get-Prefix $cuts[$mid])) { $hi = $mid } else { $lo = $mid + 1 }
}
$line = $cuts[$lo]
Write-Host "Вердикт появляется вместе с инструкцией, заканчивающейся на строке $line`:"
$prev = if ($lo -gt 0) { $cuts[$lo - 1] + 1 } else { 1 }
for ($i = $prev - 1; $i -lt $line; $i++) { Write-Host ("{0,5}: {1}" -f ($i + 1), $lines[$i]) }

Write-Host "`n[3/3] Независимый проход по инструкциям (какие срабатывают сами по себе)..."
$hits = 0
for ($k = 0; $k -lt $cuts.Count; $k++) {
    $from = if ($k -gt 0) { $cuts[$k - 1] + 1 } else { 1 }
    $to   = $cuts[$k]
    if ($to -lt $from) { continue }
    if (Test-Verdict (($lines[($from - 1)..($to - 1)]) -join "`n")) {
        $hits++
        Write-Host ("  строки {0}-{1}: ВЕРДИКТ" -f $from, $to)
    }
}
if ($hits -eq 0) {
    Write-Host "  ни одна инструкция по отдельности вердикта не получает —"
    Write-Host "  антивирус реагирует на СОЧЕТАНИЕ, а не на одну конструкцию."
} else {
    Write-Host "`nИтого срабатывающих инструкций: $hits"
}
Write-Host "`nГотово. Пришлите вывод целиком."
