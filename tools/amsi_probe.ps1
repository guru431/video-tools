# amsi_probe.ps1 — находит место в скрипте, на которое антивирус выносит вердикт.
#
# Зачем. GUI поставляется как EXE (ps2exe), внутри которого лежит PowerShell-скрипт.
# Перед исполнением движок отдаёт ВЕСЬ его текст антивирусу через AMSI; если тот
# отвечает «вредоносный», PowerShell отказывается запускать и показывает
# «This script contains malicious content and has been blocked by your antivirus
# software» с указанием line:1 — то есть на начало скрипта, а не на место проблемы.
# Понять, какая именно конструкция не понравилась, из этого сообщения нельзя.
#
# Как. Скрипт скармливает антивирусу куски проверяемого файла и смотрит, какие из них
# получают вердикт. Проверяемый текст оборачивается в блочный комментарий `<# ... #>`:
# он всегда компилируется и НИКОГДА не исполняется, но до AMSI доходит дословно.
# Так что запуск этого инструмента не выполняет ни строчки из проверяемого файла.
#
# Использование (на машине, где антивирус ругается):
#   powershell -ExecutionPolicy Bypass -File tools\amsi_probe.ps1 yt-dlp\Downloading_from_YouTube_v17.ps1
#
# Результат — номер строки, начиная с которой появляется вердикт, плюс перечень всех
# независимо срабатывающих участков (их может быть несколько).

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    # Размер окна для независимого прохода. Меньше — точнее, но дольше.
    [int]$Window = 40
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "Файл не найден: $Path"; exit 1 }

$lines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Path))
Write-Host "Файл: $Path  ($($lines.Count) строк)"

# Внутри проверяемого текста не должно быть маркеров блочного комментария, иначе
# обёртка закроется раньше времени и часть текста уйдёт на исполнение.
if (($lines -match '<#') -or ($lines -match '#>')) {
    Write-Host "ОТКАЗ: файл содержит '<#' или '#>' — обёртка в комментарий небезопасна."
    exit 1
}

$script:LastMessage = ''

# $true — антивирус вынес вердикт на этот текст. Ошибки разбора сюда не попадают:
# текст закомментирован целиком, поэтому синтаксис всегда валиден.
function Test-Verdict {
    param([string[]]$Slice)
    if ($Slice.Count -eq 0) { return $false }
    $text = "<#`n" + ($Slice -join "`n") + "`n#>"
    try {
        [void][ScriptBlock]::Create($text)
        return $false
    } catch {
        $script:LastMessage = $_.Exception.Message
        return $true
    }
}

Write-Host "`n[1/3] Проверяю файл целиком..."
if (-not (Test-Verdict $lines)) {
    Write-Host "Вердикта нет: на ЭТОЙ машине антивирус файл не блокирует."
    Write-Host "Запускать нужно там, где воспроизводится ошибка."
    exit 0
}
Write-Host "Вердикт есть. Сообщение:"
Write-Host "  $script:LastMessage"

# Двоичный поиск по префиксу: наименьшее число строк, на котором вердикт уже появляется.
Write-Host "`n[2/3] Ищу первую строку, на которой появляется вердикт..."
$lo = 1
$hi = $lines.Count
while ($lo -lt $hi) {
    $mid = [int](($lo + $hi) / 2)
    if (Test-Verdict $lines[0..($mid - 1)]) { $hi = $mid } else { $lo = $mid + 1 }
}
Write-Host "Вердикт появляется при добавлении строки $lo`:"
$from = [Math]::Max(0, $lo - 8)
$to   = [Math]::Min($lines.Count - 1, $lo + 3)
for ($i = $from; $i -le $to; $i++) {
    $mark = if (($i + 1) -eq $lo) { '>>' } else { '  ' }
    Write-Host ("{0} {1,5}: {2}" -f $mark, ($i + 1), $lines[$i])
}

# Префиксный поиск находит ОДНО место. Срабатываний может быть несколько, поэтому
# дополнительно проходим по файлу независимыми окнами.
Write-Host "`n[3/3] Независимый проход окнами по $Window строк..."
$hits = @()
for ($start = 0; $start -lt $lines.Count; $start += $Window) {
    $end = [Math]::Min($start + $Window - 1, $lines.Count - 1)
    if (Test-Verdict $lines[$start..$end]) {
        $hits += [pscustomobject]@{ From = $start + 1; To = $end + 1 }
        Write-Host ("  строки {0}-{1}: ВЕРДИКТ" -f ($start + 1), ($end + 1))
    }
}
if ($hits.Count -eq 0) {
    Write-Host "  ни одно окно по отдельности вердикта не получает —"
    Write-Host "  значит, антивирус реагирует на СОЧЕТАНИЕ участков, а не на одну конструкцию."
} else {
    Write-Host "`nИтого подозрительных участков: $($hits.Count)"
}
Write-Host "`nГотово. Пришлите вывод целиком."
