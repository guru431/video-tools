# Общие константы и хелперы сборки EXE.
# Dot-source из ffmpeg/build_exe.ps1 и yt-dlp/build_exe.ps1 — SHA-пин ps2exe и версия
# определены здесь один раз (иначе при обновлении ps2exe/бампе версии легко забыть один файл).

$script:Ps2ExeSha    = 'E180C1264C131CAEDDFA37130A2F0EB826A3FFCA701B808DA3337689721FF45A'  # PS2EXE @ MScholtes/PS2EXE d32d5ce + локальный патч (экранирование метаданных для C#-литералов: \ " CR LF TAB)
$script:Ps2ExeCommit = 'd32d5ce21c458696e860a7533943b1466d925be9'  # закреплённый commit ps2exe (провенанс)
$script:BuildVersion = '18.0.0.0'

# Проверяет наличие вендоренного ps2exe и совпадение SHA256 (supply-chain).
function Assert-Ps2Exe {
    param([string]$Ps2ExePath)
    if (-not (Test-Path -LiteralPath $Ps2ExePath)) {
        Write-Host "ERROR: vendored ps2exe not found: $Ps2ExePath"
        exit 1
    }
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $Ps2ExePath).Hash
    if ($actual -ne $script:Ps2ExeSha) {
        Write-Host "ERROR: ps2exe.ps1 SHA256 mismatch (expected $script:Ps2ExeSha, got $actual)"
        exit 1
    }
}

# Пишет sidecar-файл <exe>.sha256 (SHA256 + имя) — пользователь может сверить бинарь с источником.
function Write-ExeChecksum {
    param([string]$ExePath)
    if (Test-Path -LiteralPath $ExePath) {
        $h = (Get-FileHash -Algorithm SHA256 -LiteralPath $ExePath).Hash
        # Перевод строки — только LF. Set-Content на Windows дописал бы CRLF, и для
        # `sha256sum -c` на Linux CR становится частью имени файла: проверка падает с
        # «No such file or directory» на верной сумме.
        [System.IO.File]::WriteAllText(
            "$ExePath.sha256",
            ("{0}  {1}`n" -f $h, (Split-Path $ExePath -Leaf)),
            (New-Object System.Text.ASCIIEncoding))
        Write-Host "SHA256: $h"
    }
}

# Снимает комментарии с текста PowerShell-скрипта ПЕРЕД упаковкой в EXE.
#
# Зачем. Вердикт антивируса выносит облачная эвристика по СУММЕ признаков, а оба
# GUI стоят у порога сами по себе: запускают дочерние процессы со скрытым окном,
# перехватывают их вывод, убивают деревья через taskkill /T /F, ходят в сеть.
# В этом репозитории уже измерено, что текст комментариев входит в эту сумму:
# v17 загрузчика блокировался Kaspersky, v16 — нет, и откат по одному изменению
# за раз показал причиной ~1.6 КБ дописанных комментариев (docs/knowledge-base.md).
# Ревизия 2026-09-05 добавила в три исходника конвертера ~32 КБ комментариев, и
# Kaspersky снова начал ругаться — на конвертер, но не на загрузчик.
#
# Снятие при СБОРКЕ, а не в исходниках, — принципиально: домашний стиль проекта
# (длинные «почему»-врезки) остаётся в репозитории и в git-истории, где он и
# нужен, а в бинарь не попадает ни байта этого текста. Иначе пришлось бы выбирать
# между работающим EXE и объяснениями, без которых правила выглядят произволом.
#
# Режем ТОКЕНАЙЗЕРОМ, а не регулярным выражением: '#' внутри строки, внутри
# here-string и внутри пути (`C:\dir#1`) — обычный символ, и построчный фильтр
# испортил бы данные молча. `#requires` оставляем: это директива, а не комментарий.
function Remove-PsComments {
    param([string]$Text)

    $errs = $null
    $toks = [System.Management.Automation.PSParser]::Tokenize($Text, [ref]$errs)
    if ($errs -and $errs.Count -gt 0) {
        throw "Remove-PsComments: исходник не разбирается ($($errs[0].Message))"
    }

    # Слепок «кода без комментариев» ДО правки — с ним сверимся после. NewLine из
    # слепка исключён намеренно: вместе со строкой-комментарием уходит и её перевод
    # строки. Разделитель предыдущего оператора при этом остаётся на месте — мы
    # удаляем строку целиком только тогда, когда до комментария на ней ничего нет.
    $sep = [string][char]0x1F
    $before = @($toks | Where-Object { $_.Type -ne 'Comment' -and $_.Type -ne 'NewLine' } | ForEach-Object { $_.Type.ToString() + $sep + $_.Content })

    $sb = New-Object System.Text.StringBuilder $Text
    $comments = @($toks | Where-Object {
        $_.Type -eq 'Comment' -and $_.Content -notmatch '^\s*#requires'
    })
    # С конца: иначе каждое удаление сдвигало бы смещения последующих токенов.
    for ($i = $comments.Count - 1; $i -ge 0; $i--) {
        $t = $comments[$i]
        $start = $t.Start
        $len   = $t.Length

        # Если до комментария на строке только пробелы — убираем строку целиком
        # вместе с переводом строки, чтобы не плодить пустые строки в бинаре.
        $lineStart = $Text.LastIndexOf("`n", [Math]::Max($start - 1, 0)) + 1
        if ($start -eq 0) { $lineStart = 0 }
        $prefix = $Text.Substring($lineStart, $start - $lineStart)
        if ($prefix -match '^\s*$') {
            $len  += $start - $lineStart
            $start = $lineStart
            $eol = $start + $len
            if ($eol -lt $Text.Length -and $Text[$eol] -eq "`r") { $len++; $eol++ }
            if ($eol -lt $Text.Length -and $Text[$eol] -eq "`n") { $len++ }
        }
        [void]$sb.Remove($start, $len)
    }
    $out = $sb.ToString()

    # Проверка, а не надежда: поток токенов кода обязан совпасть один в один.
    # Ошибка здесь означает, что вырезано что-то кроме комментария, — и сборка
    # должна упасть, а не выдать EXE с испорченным скриптом внутри.
    $errs2 = $null
    $toks2 = [System.Management.Automation.PSParser]::Tokenize($out, [ref]$errs2)
    if ($errs2 -and $errs2.Count -gt 0) {
        throw "Remove-PsComments: результат не разбирается ($($errs2[0].Message))"
    }
    $after = @($toks2 | Where-Object { $_.Type -ne 'Comment' -and $_.Type -ne 'NewLine' } | ForEach-Object { $_.Type.ToString() + $sep + $_.Content })
    if ($before.Count -ne $after.Count) {
        throw "Remove-PsComments: число токенов кода изменилось ($($before.Count) -> $($after.Count))"
    }
    for ($i = 0; $i -lt $before.Count; $i++) {
        if ($before[$i] -ne $after[$i]) {
            throw "Remove-PsComments: токен #$i изменился ('$($before[$i])' -> '$($after[$i])')"
        }
    }
    return $out
}
