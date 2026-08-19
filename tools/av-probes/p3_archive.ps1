# ПРОБА 3 — подсчёт непустых строк файла (проверка «манифест пуст»).
# В v16 пустота определялась по длине файла, в v17 — по содержимому.
$tmp = Join-Path $env:TEMP "probe3_sample.txt"
Set-Content -LiteralPath $tmp -Value "C:\video\clip.mp4" -Encoding UTF8
$archiveSkipped = (@(Get-Content -LiteralPath $tmp -ErrorAction SilentlyContinue |
                     Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)
Write-Host "ПРОБА 3: OK — пусто: $archiveSkipped (ожидалось False)"
Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
Read-Host "Enter для выхода"
