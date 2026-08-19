# ПРОБА 1 — создание пустого файла в %TEMP% со случайным именем через .NET-API.
# Ровно так v17 готовил манифест yt-dlp; в v16 на этом месте был Set-Content.
$manifest = Join-Path ([System.IO.Path]::GetTempPath()) ("ytdlp_manifest_{0}.txt" -f [System.Guid]::NewGuid().ToString('N'))
[System.IO.File]::WriteAllText($manifest, "")
Write-Host "ПРОБА 1: OK — файл создан: $manifest"
Remove-Item -LiteralPath $manifest -Force -ErrorAction SilentlyContinue
Read-Host "Enter для выхода"
