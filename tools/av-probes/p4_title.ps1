# ПРОБА 4 — строки заголовка окна, изменившиеся с v16 на v17.
# Проверяется маловероятное, но это единственное оставшееся отличие.
$itemNum = 1; $totalItems = 3; $pct = 42
$titles = @(
    "Video Downloader (yt-dlp) v17",
    "Video Downloader (yt-dlp) v17  [$itemNum/$totalItems]",
    "Video Downloader (yt-dlp) v17  [$itemNum/$totalItems]  $pct%",
    "Video Downloader (yt-dlp) v17 — Готово!"
)
Write-Host "ПРОБА 4: OK — строк заголовка: $($titles.Count)"
Read-Host "Enter для выхода"
