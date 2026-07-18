# -*- coding: utf-8 -*-
# ============================================================================
# download-gui.ps1 — GUI загрузчик YouTube видео (Windows, PowerShell)
# Включает: cookies, прокси, AI-перевод, прогресс-бар, RichTextBox,
#           очередь URL, автоопределение платформы, версия yt-dlp
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$scriptDir = if ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}
# $env:YTDLP_CONFIG — override пути config.ini (используют тесты); иначе рядом со скриптом.
$configFile = if ($env:YTDLP_CONFIG) { $env:YTDLP_CONFIG } else { Join-Path $scriptDir "config.ini" }

# ── Чтение config.ini (один раз в хеш-таблицу) ──────────────────────────
$script:_configCache = @{}
if (Test-Path $configFile) {
    $curSection = ""
    foreach ($line in (Get-Content $configFile -Encoding UTF8)) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $curSection = $Matches[1]
            continue
        }
        if ($curSection -and $line -match '^([^=]+?)\s*=\s*(.*)') {
            $val = $Matches[2] -replace '\s+#.*', ''
            # Подстановка ${ENV_VAR} из окружения. Не задана → пустая строка + WARN.
            $val = [regex]::Replace($val, '\$\{(\w+)\}', {
                param($m)
                $ev = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
                if ($null -eq $ev) { Write-Host "WARN: переменная $($m.Groups[1].Value) не задана"; "" } else { $ev }
            })
            $script:_configCache["${curSection}::$($Matches[1].Trim())"] = $val
        }
    }
}
function Read-Config {
    param([string]$Key, [string]$Section, [string]$Default = "")
    $k = "${Section}::${Key}"
    if ($script:_configCache.ContainsKey($k)) { return $script:_configCache[$k] }
    return $Default
}

# ── Загрузка настроек ─────────────────────────────────────────────────────
$cfg_proxy_raw = Read-Config "url" "proxy" ""
$cfg_proxyType = "https"
$cfg_proxyHost = ""
$cfg_proxyPort = ""
$cfg_proxyUser = ""
$cfg_proxyPass = ""
if ($cfg_proxy_raw -match '^(https?|socks[45]?)://(?:([^:]+):([^@]+)@)?([^:/]+)(?::(\d+))?') {
    $cfg_proxyType = $Matches[1]
    $cfg_proxyUser = if ($Matches[2]) { $Matches[2] } else { "" }
    $cfg_proxyPass = if ($Matches[3]) { $Matches[3] } else { "" }
    $cfg_proxyHost = $Matches[4]
    $cfg_proxyPort = if ($Matches[5]) { $Matches[5] } else { "" }
}
# ── Сеть: профиль устойчивости + необязательный потолок скорости ──────────
# Значения раньше были зашиты литералами в строке сборки $command: подстроить их
# под медленный/нестабильный канал было нельзя. Дефолт normal воспроизводит
# прежний набор флагов ДОСЛОВНО, поэтому поведение по умолчанию не меняется.
# Паритет с build_net_args в .sh — таблица профилей обязана совпадать.
$cfg_speedProfile = Read-Config "speed_profile" "network" "normal"
$cfg_limitRate    = Read-Config "limit_rate"    "network" ""

function Build-NetArgs {
    switch ($cfg_speedProfile) {
        "careful" { $frags = 1; $retries = 20; $sock = 60; $sleepS = 5 }
        "fast"    { $frags = 8; $retries = 5;  $sock = 15; $sleepS = 0 }
        "normal"  { $frags = 4; $retries = 10; $sock = 30; $sleepS = 0 }
        default   {
            Write-Host "WARN: неизвестный speed_profile '$cfg_speedProfile', используется normal"
            $frags = 4; $retries = 10; $sock = 30; $sleepS = 0
        }
    }
    $a = @("--retries", "$retries", "--fragment-retries", "$retries",
           "--file-access-retries", "5", "--socket-timeout", "$sock",
           "--concurrent-fragments", "$frags")
    if ($sleepS -gt 0) { $a += @("--retry-sleep", "$sleepS") }
    if (-not [string]::IsNullOrWhiteSpace($cfg_limitRate)) { $a += @("--limit-rate", $cfg_limitRate) }
    return $a
}

$cfg_quality      = Read-Config "default_quality" "download" "720"
$cfg_baseDir      = Read-Config "base_dir"        "output"   "_video_"
$cfg_template     = Read-Config "template"         "output"   '%(uploader)s/%(upload_date)s - %(title).100U.%(ext)s'
$cfg_plTemplate   = Read-Config "playlist_template" "output"  '%(uploader)s/%(playlist)s/%(playlist_index)03d - %(title).100U.%(ext)s'
$cfg_cookieMethod  = Read-Config "method"          "cookies"  "none"
$cfg_cookieBrowser = Read-Config "browser"         "cookies"  "chrome"
$cfg_cookieFile    = Read-Config "file"            "cookies"  "youtube_cookies.txt"
$cfg_transEnabled  = Read-Config "enabled"         "translation" "false"
$cfg_transLang     = Read-Config "target_lang"     "translation" "ru"
$cfg_transVoice    = Read-Config "voice_style"     "translation" "live"
$cfg_transMode     = Read-Config "mode"            "translation" "mix"
# Паритет с .sh: архив загрузок и громкости/язык для AI-перевода — из config.
$cfg_continueOnErr = Read-Config "continue_on_error"  "download"    "true"
$cfg_useArchive    = Read-Config "use_archive"        "download"    "true"
$cfg_archiveFile   = Read-Config "archive_file"       "download"    "download_archive.txt"
$cfg_transOrigVol  = Read-Config "original_volume"    "translation" "0.3"
$cfg_transTransVol = Read-Config "translation_volume" "translation" "1.0"
$cfg_transOrigLang = Read-Config "original_lang"      "translation" "en"
# Trim: парсим "+/-VALUE" в (enabled, value)
function Parse-TrimFlag {
    param([string]$Raw, [string]$DefaultVal)
    if ($Raw -match '^\+(.*)$') { return @{ enabled = $true;  value = $Matches[1] } }
    if ($Raw -match '^-(.*)$')  { return @{ enabled = $false; value = $Matches[1] } }
    $val = if ($Raw) { $Raw } else { $DefaultVal }
    return @{ enabled = $false; value = $val }
}
$cfg_trim_start = Parse-TrimFlag (Read-Config "start" "trim" "-00:00:00") "00:00:00"
$cfg_trim_end   = Parse-TrimFlag (Read-Config "end"   "trim" "-00:01:00") "00:01:00"
$cfg_forceKf    = Read-Config "force_keyframes" "trim" "false"
# Аудио-формат / SponsorBlock / субтитры-с-видео — по умолчанию текущее поведение.
$cfg_audioFormat   = Read-Config "audio_format"        "download"  "best"
$cfg_sponsorblock  = Read-Config "sponsorblock"        "download"  "off"
$cfg_subsWithVideo = Read-Config "download_with_video" "subtitles" "off"
$cfg_subLang       = Read-Config "lang"                "subtitles" "ru"
# F31. Формат субтитров читаем из конфига (паритет с SH). Раньше был захардкожен vtt,
# то есть ключ [subtitles] format в GUI не работал вовсе.
$cfg_subFormat     = Read-Config "format"              "subtitles" "vtt"

$qualityMap = @{ "audio" = 0; "720" = 3; "360" = 1; "480" = 2; "1080" = 4; "1440" = 5; "2160" = 6 }
$defaultQualityIdx = if ($qualityMap.ContainsKey($cfg_quality)) { $qualityMap[$cfg_quality] } else { 3 }

$dlpLocal = Join-Path $scriptDir "yt-dlp.exe"
if (Test-Path $dlpLocal) { $dlp = $dlpLocal } else { $dlp = "yt-dlp" }

# ffmpeg для мержа AI-перевода: сначала рядом со скриптом (ffmpeg.exe), затем PATH —
# паритет с $dlp и с задекларированным binary auto-detection.
$ffmpegLocal = Join-Path $scriptDir "ffmpeg.exe"
if (Test-Path $ffmpegLocal) { $ffmpegBin = $ffmpegLocal } else { $ffmpegBin = "ffmpeg" }
$ffprobeLocal = Join-Path $scriptDir "ffprobe.exe"
if (Test-Path $ffprobeLocal) { $ffprobeBin = $ffprobeLocal } else { $ffprobeBin = "ffprobe" }

# ── Определение платформы по URL ──────────────────────────────────────────
function Get-Platform {
    param([string]$Url)
    # Домен якорим по границе (начало, '/', '.', '@'), иначе notyoutube.com и т.п.
    # ошибочно матчатся как подстрока.
    switch -Regex ($Url) {
        '(^|[./@])(youtube\.com|youtu\.be)([/:?#]|$)' { return 'YouTube' }
        '(^|[./@])rutube\.ru([/:?#]|$)'               { return 'RuTube' }
        '(^|[./@])vk\.com([/:?#]|$)'                  { return 'VK Video' }
        '(^|[./@])twitch\.tv([/:?#]|$)'               { return 'Twitch' }
        '(^|[./@])vimeo\.com([/:?#]|$)'               { return 'Vimeo' }
        '(^|[./@])dailymotion\.com([/:?#]|$)'         { return 'Dailymotion' }
        default                                        { return 'Video' }
    }
}

# ── Текущая версия yt-dlp (заполняется после показа формы) ────────────────
$currentVersion = ""

# ── Глобальная очередь URL ────────────────────────────────────────────────
$global:urlQueue = [System.Collections.Generic.List[hashtable]]::new()

# ── Windows argv-квотирование (CommandLineToArgvW) ────────────────────────
# Единый квотер для всех ProcessStartInfo.Arguments: yt-dlp и vot-cli-live.
# UseShellExecute=$false → строку Arguments разбирает CreateProcess/CommandLineToArgvW
# (не cmd.exe), поэтому &, <, >, ^, |, % — литералы; кавычить нужно только при пробеле/табе/".
# Экранирование бэкслешей перед " по алгоритму MS ("Everyone quotes… the wrong way").
function Quote-WinArg {
    param([string]$Arg)
    if ($Arg -eq "") { return '""' }
    if ($Arg -notmatch '[\s"]') { return $Arg }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')
    $bs = 0
    foreach ($ch in $Arg.ToCharArray()) {
        if ($ch -eq '\') {
            $bs++
        } elseif ($ch -eq '"') {
            [void]$sb.Append('\' * ($bs * 2 + 1)); [void]$sb.Append('"'); $bs = 0
        } else {
            if ($bs -gt 0) { [void]$sb.Append('\' * $bs); $bs = 0 }
            [void]$sb.Append($ch)
        }
    }
    if ($bs -gt 0) { [void]$sb.Append('\' * ($bs * 2)) }
    [void]$sb.Append('"')
    return $sb.ToString()
}
# Собирает строку Arguments из массива, квотируя каждый элемент.
function Join-WinArgs {
    param([string[]]$ArgList)
    return (($ArgList | ForEach-Object { Quote-WinArg $_ }) -join ' ')
}

# ── Таблицы форматов (script scope: читаются из Add_Click и из тестов) ─────
# Значения — сырые format-строки yt-dlp БЕЗ ручных кавычек: пробелов в них нет,
# поэтому Quote-WinArg их не квотирует, а argv-токен остаётся цельным.
$formatPresets = @{
    "avc1_best" = @(
        "bestaudio[ext!=webm]/bestaudio",
        "bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360]",
        "bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480]",
        "bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]",
        "bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080]",
        "bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440]",
        "bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160]"
    )
    "avc1_https" = @(
        "140", "140+134", "140+135/134", "140+136/135/134",
        "140+137/136/135/134",
        "140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]",
        "140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]"
    )
    "avc1_m3u8" = @(
        "234", "234+230", "234+231/230", "234+232/231/230",
        "270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]",
        "bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]",
        "bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]"
    )
    "avc1_https_60fps" = @(
        "140",
        "140+134/best[height<=360]",
        "140+135/best[height<=480]",
        "140+298/best[height<=720]",
        "140+299/298/best[height<=1080]",
        "bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=1440]",
        "bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/140+299/best[height<=2160]"
    )
    "avc1_m3u8_60fps" = @(
        "234",
        "234+309/bestvideo[height<=360][fps>=50]+bestaudio/best[height<=360]",
        "234+310/309/bestvideo[height<=480][fps>=50]+bestaudio/best[height<=480]",
        "234+311/310/309/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]",
        "234+312/311/310/309/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]",
        "234+313/312/311/310/309/bestvideo[height<=1440][fps>=50]+bestaudio/best[height<=1440]",
        "234+314/313/312/311/310/309/bestvideo[height<=2160][fps>=50]+bestaudio/best[height<=2160]"
    )
    "avc1_https_60fps_hdr" = @(
        "234",
        "234+696/bestvideo[height<=360][fps>=50]+bestaudio/best[height<=360]",
        "234+697/696/bestvideo[height<=480][fps>=50]+bestaudio/best[height<=480]",
        "234+698/697/696/bestvideo[height<=720][fps>=50]+bestaudio/best[height<=720]",
        "234+699/698/697/696/bestvideo[height<=1080][fps>=50]+bestaudio/best[height<=1080]",
        "234+700/699/698/697/696/bestvideo[height<=1440][fps>=50]+bestaudio/best[height<=1440]",
        "234+701/700/699/698/697/696/bestvideo[height<=2160][fps>=50]+bestaudio/best[height<=2160]"
    )
    "old_combo" = @(
        "140", "18", "59/22/18", "22/18",
        "37/22/18", "38/37/22/18", "38/37/22/18"
    )
}
# auto для не-YouTube: простой best[height<=N] (один поток).
$simpleBest = @(
    "bestaudio/best",
    "best[height<=360]/best",
    "best[height<=480]/best",
    "best[height<=720]/best",
    "best[height<=1080]/best",
    "best[height<=1440]/best",
    "best[height<=2160]/best"
)

# Тестовый хук: при дот-сорсинге с $env:YTDLP_TEST=1 выходим до построения GUI —
# тесты проверяют реальные Read-Config/Get-Platform/$qualityMap/$formatPresets/Quote-WinArg,
# а не устаревшие inline-копии. В обычном запуске (EXE) переменная не задана → GUI строится.
if ($env:YTDLP_TEST -eq '1') { return }

# ── Создание формы ────────────────────────────────────────────────────────
$form = [System.Windows.Forms.Form]::new()
$form.Text = "Video Downloader (yt-dlp) v15"
$form.Size = [System.Drawing.Size]::new(830, 807)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.Font = [System.Drawing.Font]::new("Microsoft Sans Serif", 10)
# DoubleBuffered (protected) — убирает мерцание при перерисовке / разблокировке
$form.GetType().GetProperty('DoubleBuffered',
    [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$form.SuspendLayout()
$_fc = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

$xPos0 = 20
$yPos  = 15

# ── 0. Версия yt-dlp + кнопка проверки обновлений ─────────────────────────
$xPos = $xPos0
$lblVersion = [System.Windows.Forms.Label]::new()
$lblVersion.Location = [System.Drawing.Point]::new($xPos, ($yPos + 3))
$lblVersion.Size     = [System.Drawing.Size]::new(400, 20)
$lblVersion.Text     = "yt-dlp: ..."
$lblVersion.ForeColor = [System.Drawing.Color]::DimGray
$_fc.Add($lblVersion)

$btnCheckUpdate = [System.Windows.Forms.Button]::new()
$btnCheckUpdate.Location = [System.Drawing.Point]::new(618, $yPos)
$btnCheckUpdate.Size     = [System.Drawing.Size]::new(182, 25)
$btnCheckUpdate.Text     = "Проверить обновления"
$btnCheckUpdate.Add_Click({
    $btnCheckUpdate.Enabled = $false
    $btnCheckUpdate.Text    = "Запрос..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $webArgs = @{
            Uri             = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"
            UseBasicParsing = $true
            TimeoutSec      = 15
            Headers         = @{ "User-Agent" = "yt-dlp-gui/1.0" }
        }
        # Прокси если задан
        if (([string]$comboProxyType.SelectedItem -ne "нет") -and -not [string]::IsNullOrWhiteSpace($textProxyHost.Text)) {
            $pType = $comboProxyType.SelectedItem
            $pHost = $textProxyHost.Text
            $pPort = $textProxyPort.Text
            # .NET Framework WebProxy не умеет SOCKS → проверка обновлений через SOCKS невозможна.
            if ($pType -match "^socks") {
                $lnkUpdateResult.Links.Clear()
                $lnkUpdateResult.Text = "проверка недоступна через SOCKS"
                $lnkUpdateResult.ForeColor = [System.Drawing.Color]::Gray
                return
            }
            # ServicePointManager не поддерживает https:// как схему прокси — используем http://
            $proxyScheme = if ($pType -match "^socks") { $pType } else { "http" }
            $proxyUri = "${proxyScheme}://${pHost}"
            if (-not [string]::IsNullOrWhiteSpace($pPort)) { $proxyUri += ":${pPort}" }
            $webArgs.Proxy = $proxyUri
            if (-not [string]::IsNullOrWhiteSpace($textProxyUser.Text)) {
                $webArgs.ProxyCredential = New-Object System.Management.Automation.PSCredential(
                    $textProxyUser.Text,
                    (ConvertTo-SecureString $textProxyPass.Text -AsPlainText -Force)
                )
            }
        }
        $response      = Invoke-RestMethod @webArgs
        $latestVersion = $response.tag_name
        $asset         = $response.assets | Where-Object { $_.name -eq "yt-dlp.exe" } | Select-Object -First 1
        $downloadUrl   = if ($asset) { $asset.browser_download_url } else { "https://github.com/yt-dlp/yt-dlp/releases/latest" }

        if ($currentVersion -eq $latestVersion) {
            $lnkUpdateResult.Links.Clear()
            $lnkUpdateResult.Text      = "обновлений нет"
            $lnkUpdateResult.ForeColor = [System.Drawing.Color]::Gray
            $script:updateUrl          = ""
        } else {
            $script:updateUrl          = $downloadUrl
            $linkText                  = "Скачать $latestVersion"
            $lnkUpdateResult.Text      = $linkText
            $lnkUpdateResult.Links.Clear()
            $lnkUpdateResult.Links.Add(0, $linkText.Length) | Out-Null
            $lnkUpdateResult.ForeColor = [System.Drawing.Color]::RoyalBlue
        }
    }
    catch {
        $lnkUpdateResult.Links.Clear()
        $lnkUpdateResult.Text      = "ошибка запроса"
        $lnkUpdateResult.ForeColor = [System.Drawing.Color]::Firebrick
        $script:updateUrl          = ""
    }
    finally {
        $btnCheckUpdate.Enabled = $true
        $btnCheckUpdate.Text    = "Проверить обновления"
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
$_fc.Add($btnCheckUpdate)

$script:updateUrl    = ""
$lnkUpdateResult     = [System.Windows.Forms.LinkLabel]::new()
$lnkUpdateResult.Location  = [System.Drawing.Point]::new(425, ($yPos + 5))
$lnkUpdateResult.Size      = [System.Drawing.Size]::new(190, 18)
$lnkUpdateResult.Text      = ""
$lnkUpdateResult.Font      = [System.Drawing.Font]::new("Microsoft Sans Serif", 9)
$lnkUpdateResult.Add_LinkClicked({
    if (-not [string]::IsNullOrEmpty($script:updateUrl)) {
        [System.Diagnostics.Process]::Start($script:updateUrl) | Out-Null
    }
})
$_fc.Add($lnkUpdateResult)

# ── 1. URL + кнопка добавления ────────────────────────────────────────────
$yPos += 35; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "URL видео:"
$lbl.Font     = [System.Drawing.Font]::new("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$_fc.Add($lbl)

$xPos += 110
$textBoxUrl = [System.Windows.Forms.TextBox]::new()
$textBoxUrl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textBoxUrl.Size     = [System.Drawing.Size]::new(556, 25)
$_fc.Add($textBoxUrl)

$xPos += 564
$btnAddUrl = [System.Windows.Forms.Button]::new()
$btnAddUrl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnAddUrl.Size     = [System.Drawing.Size]::new(106, 25)
$btnAddUrl.Text     = "Добавить  ↵"
$_fc.Add($btnAddUrl)

# Функция добавления URL в очередь (используется кнопкой и Enter)
$addUrlToQueue = {
    $url = $textBoxUrl.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) { return }
    # F30. Вход обязан быть http(s)-URL. Раньше произвольная строка уходила в argv
    # yt-dlp как есть: '--version' исполнялся как ОПЦИЯ (окно «скачало» версию),
    # а '-U' мог обновить/подменить сам бинарь. Поиска (ytsearch:) GUI не поддерживает,
    # поэтому всё, что не http(s)-URL, — ошибка ввода, а не задача загрузки.
    if ($url -notmatch '^https?://\S+$') {
        [System.Windows.Forms.MessageBox]::Show(
            "Ожидается ссылка вида https://... (получено: '$url').`n`nGUI принимает только адреса видео, не опции yt-dlp.",
            "Некорректная ссылка", "OK", "Warning") | Out-Null
        $textBoxUrl.SelectAll()
        return
    }
    $exists = $global:urlQueue | Where-Object { $_.Url -eq $url }
    if ($exists) { $textBoxUrl.SelectAll(); return }
    $platform    = Get-Platform $url
    $displayText = "[$platform]  $url"
    $global:urlQueue.Add(@{ Url = $url; Platform = $platform; Display = $displayText })
    $listBoxQueue.Items.Add($displayText) | Out-Null
    $textBoxUrl.Clear()
    $textBoxUrl.Focus()
}
$btnAddUrl.Add_Click($addUrlToQueue)

$textBoxUrl.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
        & $addUrlToQueue
        $e.SuppressKeyPress = $true
    }
})

# ── 2. Очередь URL (ListBox) ──────────────────────────────────────────────
$yPos += 35; $xPos = $xPos0
$listBoxQueue = [System.Windows.Forms.ListBox]::new()
$listBoxQueue.Location        = [System.Drawing.Point]::new($xPos, $yPos)
$listBoxQueue.Size            = [System.Drawing.Size]::new(666, 80)
$listBoxQueue.Font            = [System.Drawing.Font]::new("Consolas", 9)
$listBoxQueue.HorizontalScrollbar = $true
$_fc.Add($listBoxQueue)

$xPos += 674
$btnRemoveUrl = [System.Windows.Forms.Button]::new()
$btnRemoveUrl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnRemoveUrl.Size     = [System.Drawing.Size]::new(106, 36)
$btnRemoveUrl.Text     = "Удалить"
$btnRemoveUrl.Add_Click({
    $idx = $listBoxQueue.SelectedIndex
    if ($idx -ge 0) {
        $listBoxQueue.Items.RemoveAt($idx)
        $global:urlQueue.RemoveAt($idx)
    }
})
$_fc.Add($btnRemoveUrl)

$btnClearQueue = [System.Windows.Forms.Button]::new()
$btnClearQueue.Location = [System.Drawing.Point]::new($xPos, ($yPos + 42))
$btnClearQueue.Size     = [System.Drawing.Size]::new(106, 36)
$btnClearQueue.Text     = "Очистить"
$btnClearQueue.Add_Click({
    $listBoxQueue.Items.Clear()
    $global:urlQueue.Clear()
})
$_fc.Add($btnClearQueue)

# ── 3. Папка сохранения ───────────────────────────────────────────────────
$yPos += 90; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Папка:"
$_fc.Add($lbl)

$xPos += 110
$textBoxFolder = [System.Windows.Forms.TextBox]::new()
$textBoxFolder.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textBoxFolder.Size     = [System.Drawing.Size]::new(556, 25)
$textBoxFolder.Text     = [System.IO.Path]::Combine($scriptDir, $cfg_baseDir)
$_fc.Add($textBoxFolder)

$xPos += 564
$btnBrowse = [System.Windows.Forms.Button]::new()
$btnBrowse.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnBrowse.Size     = [System.Drawing.Size]::new(106, 25)
$btnBrowse.Text     = "Обзор..."
$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.SelectedPath = $textBoxFolder.Text
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBoxFolder.Text = $fb.SelectedPath
    }
})
$_fc.Add($btnBrowse)

# ── 4. Качество ───────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Качество:"
$_fc.Add($lbl)

$xPos += 110
$comboQuality = [System.Windows.Forms.ComboBox]::new()
$comboQuality.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboQuality.Size          = [System.Drawing.Size]::new(220, 25)
$comboQuality.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboQuality.Items.AddRange(@(
    "Только аудио", "360p", "480p", "720p", "1080p", "1440p", "2160p",
    "Субтитры (RU)", "Субтитры (EN)"
))
$comboQuality.SelectedIndex = $defaultQualityIdx
$_fc.Add($comboQuality)

$xPos += 230
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(65, 20)
$lbl.Text     = "Формат:"
$_fc.Add($lbl)

$xPos += 65
$comboFormat = [System.Windows.Forms.ComboBox]::new()
$comboFormat.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboFormat.Size          = [System.Drawing.Size]::new(235, 25)
$comboFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboFormat.Items.AddRange(@(
    "auto", "avc1_best", "avc1_https", "avc1_m3u8",
    "avc1_https_60fps", "avc1_m3u8_60fps",
    "avc1_https_60fps_hdr", "old_combo"
))
$cfg_format = Read-Config "format_preset" "download" "auto"
$fmtIdx = $comboFormat.Items.IndexOf($cfg_format)
$comboFormat.SelectedIndex = if ($fmtIdx -ge 0) { $fmtIdx } else { 0 }
$_fc.Add($comboFormat)

# ── 4b. Аудио-формат / SponsorBlock / субтитры с видео ────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Аудио:"
$_fc.Add($lbl)

$xPos += 110
$comboAudioFormat = [System.Windows.Forms.ComboBox]::new()
$comboAudioFormat.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboAudioFormat.Size          = [System.Drawing.Size]::new(90, 25)
$comboAudioFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboAudioFormat.Items.AddRange(@("best", "mp3", "m4a", "opus"))
$afIdx = $comboAudioFormat.Items.IndexOf($cfg_audioFormat)
$comboAudioFormat.SelectedIndex = if ($afIdx -ge 0) { $afIdx } else { 0 }
$_fc.Add($comboAudioFormat)

$xPos += 100
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(95, 20)
$lbl.Text     = "SponsorBlock:"
$_fc.Add($lbl)

$xPos += 95
$comboSponsorblock = [System.Windows.Forms.ComboBox]::new()
$comboSponsorblock.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboSponsorblock.Size          = [System.Drawing.Size]::new(90, 25)
$comboSponsorblock.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboSponsorblock.Items.AddRange(@("off", "mark", "remove"))
$sbIdx = $comboSponsorblock.Items.IndexOf($cfg_sponsorblock)
$comboSponsorblock.SelectedIndex = if ($sbIdx -ge 0) { $sbIdx } else { 0 }
$_fc.Add($comboSponsorblock)

$xPos += 100
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(70, 20)
$lbl.Text     = "Субтитры:"
$_fc.Add($lbl)

$xPos += 70
$comboSubsVideo = [System.Windows.Forms.ComboBox]::new()
$comboSubsVideo.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboSubsVideo.Size          = [System.Drawing.Size]::new(90, 25)
$comboSubsVideo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboSubsVideo.Items.AddRange(@("off", "sidecar", "embed"))
$svIdx = $comboSubsVideo.Items.IndexOf($cfg_subsWithVideo)
$comboSubsVideo.SelectedIndex = if ($svIdx -ge 0) { $svIdx } else { 0 }
$_fc.Add($comboSubsVideo)

# ── 5. Плейлист ───────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Плейлист с:"
$_fc.Add($lbl)

$xPos += 110
$textBoxStart = [System.Windows.Forms.TextBox]::new()
$textBoxStart.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textBoxStart.Size     = [System.Drawing.Size]::new(50, 25)
$_fc.Add($textBoxStart)

$xPos += 55
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(30, 20)
$lbl.Text     = "по:"
$_fc.Add($lbl)

$xPos += 30
$textBoxEnd = [System.Windows.Forms.TextBox]::new()
$textBoxEnd.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textBoxEnd.Size     = [System.Drawing.Size]::new(50, 25)
$_fc.Add($textBoxEnd)

# ── 5b. Фрагмент видео (Trim) ─────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Фрагмент с:"
$_fc.Add($lbl)

$xPos += 110
$chkTrimStart = [System.Windows.Forms.CheckBox]::new()
$chkTrimStart.Location = [System.Drawing.Point]::new($xPos, ($yPos + 4))
$chkTrimStart.Size     = [System.Drawing.Size]::new(18, 18)
$chkTrimStart.Checked  = $cfg_trim_start.enabled
$_fc.Add($chkTrimStart)

$xPos += 22
$textTrimStart = [System.Windows.Forms.TextBox]::new()
$textTrimStart.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textTrimStart.Size     = [System.Drawing.Size]::new(75, 25)
$textTrimStart.Text     = $cfg_trim_start.value
$_fc.Add($textTrimStart)

$xPos += 82
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(30, 20)
$lbl.Text     = "по:"
$_fc.Add($lbl)

$xPos += 30
$chkTrimEnd = [System.Windows.Forms.CheckBox]::new()
$chkTrimEnd.Location = [System.Drawing.Point]::new($xPos, ($yPos + 4))
$chkTrimEnd.Size     = [System.Drawing.Size]::new(18, 18)
$chkTrimEnd.Checked  = $cfg_trim_end.enabled
$_fc.Add($chkTrimEnd)

$xPos += 22
$textTrimEnd = [System.Windows.Forms.TextBox]::new()
$textTrimEnd.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textTrimEnd.Size     = [System.Drawing.Size]::new(75, 25)
$textTrimEnd.Text     = $cfg_trim_end.value
$_fc.Add($textTrimEnd)

$xPos += 90
$chkForceKf = [System.Windows.Forms.CheckBox]::new()
$chkForceKf.Location = [System.Drawing.Point]::new($xPos, ($yPos + 2))
$chkForceKf.Size     = [System.Drawing.Size]::new(335, 22)
$chkForceKf.Text     = "Точная обрезка (потребуется перекодирование)"
$chkForceKf.Checked  = ($cfg_forceKf -eq "true")
$tipKf = New-Object System.Windows.Forms.ToolTip
$tipKf.SetToolTip($chkForceKf,
    "Без этого фрагмент режется по ближайшему ключевому кадру:`r`n" +
    "  быстро (без перекодирования), но границы могут уехать на ±1-10 сек.`r`n" +
    "С галочкой: перекодируются только концы фрагмента — точно до секунды,`r`n" +
    "но медленнее и небольшая потеря качества на стыках.")
$_fc.Add($chkForceKf)

$tipTrim = New-Object System.Windows.Forms.ToolTip
$tipTrim.SetToolTip($textTrimStart,
    "Формат: ЧЧ:ММ:СС, М:СС или секунды. Галочкой можно выключить.`r`n" +
    "Если выкл — качать с начала ролика.")
$tipTrim.SetToolTip($textTrimEnd,
    "Формат: ЧЧ:ММ:СС, М:СС или секунды. Галочкой можно выключить.`r`n" +
    "Если выкл — качать до конца ролика.")

# ── 6. Прокси (5 полей) ───────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Прокси:"
$_fc.Add($lbl)

$xPos += 110
$comboProxyType = [System.Windows.Forms.ComboBox]::new()
$comboProxyType.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboProxyType.Size          = [System.Drawing.Size]::new(75, 25)
$comboProxyType.DropDownStyle = "DropDownList"
$comboProxyType.Items.AddRange(@("нет", "https", "http", "socks5", "socks4"))
if ([string]::IsNullOrWhiteSpace($cfg_proxy_raw) -or [string]::IsNullOrWhiteSpace($cfg_proxyHost)) {
    $comboProxyType.SelectedIndex = 0
} else {
    $comboProxyType.SelectedItem = $cfg_proxyType
    if ($comboProxyType.SelectedIndex -lt 0) { $comboProxyType.SelectedIndex = 1 }
}
$_fc.Add($comboProxyType)

$xPos += 80
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(18, 20)
$lbl.Text     = "://"
$_fc.Add($lbl)

$xPos += 18
$textProxyHost = [System.Windows.Forms.TextBox]::new()
$textProxyHost.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textProxyHost.Size     = [System.Drawing.Size]::new(210, 25)
$textProxyHost.Text     = $cfg_proxyHost
$_fc.Add($textProxyHost)

$xPos += 213
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(10, 20)
$lbl.Text     = ":"
$_fc.Add($lbl)

$xPos += 10
$textProxyPort = [System.Windows.Forms.TextBox]::new()
$textProxyPort.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textProxyPort.Size     = [System.Drawing.Size]::new(55, 25)
$textProxyPort.Text     = $cfg_proxyPort
$_fc.Add($textProxyPort)

$xPos += 65
$textProxyUser = [System.Windows.Forms.TextBox]::new()
$textProxyUser.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textProxyUser.Size     = [System.Drawing.Size]::new(130, 25)
$textProxyUser.Text     = $cfg_proxyUser
$_fc.Add($textProxyUser)

$xPos += 140
$textProxyPass = [System.Windows.Forms.TextBox]::new()
$textProxyPass.Location              = [System.Drawing.Point]::new($xPos, $yPos)
$textProxyPass.Size                  = [System.Drawing.Size]::new(144, 25)
$textProxyPass.Text                  = $cfg_proxyPass
$textProxyPass.UseSystemPasswordChar = $true
$_fc.Add($textProxyPass)

# Блокировка полей прокси при выборе "нет"
$updateProxyFieldsState = {
    $isNone = ([string]$comboProxyType.SelectedItem -eq "нет")
    $textProxyHost.Enabled = -not $isNone
    $textProxyPort.Enabled = -not $isNone
    $textProxyUser.Enabled = -not $isNone
    $textProxyPass.Enabled = -not $isNone
}
$comboProxyType.Add_SelectedIndexChanged($updateProxyFieldsState)
& $updateProxyFieldsState

# ── 7. Cookies ────────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(110, 20)
$lbl.Text     = "Cookies:"
$_fc.Add($lbl)

$xPos += 110
$comboCookies = [System.Windows.Forms.ComboBox]::new()
$comboCookies.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboCookies.Size          = [System.Drawing.Size]::new(150, 25)
$comboCookies.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboCookies.Items.AddRange(@("Без cookies", "Из браузера", "Из файла"))
$cookieIdx = switch ($cfg_cookieMethod) { "browser" { 1 } "file" { 2 } default { 0 } }
$comboCookies.SelectedIndex = $cookieIdx
$_fc.Add($comboCookies)

$xPos += 160
$comboCookieBrowser = [System.Windows.Forms.ComboBox]::new()
$comboCookieBrowser.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboCookieBrowser.Size          = [System.Drawing.Size]::new(120, 25)
$comboCookieBrowser.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboCookieBrowser.Items.AddRange(@("chrome", "firefox", "edge"))
$browserIdx = switch ($cfg_cookieBrowser) { "firefox" { 1 } "edge" { 2 } default { 0 } }
$comboCookieBrowser.SelectedIndex = $browserIdx
$comboCookieBrowser.Visible       = ($comboCookies.SelectedIndex -eq 1)
$_fc.Add($comboCookieBrowser)

$textBoxCookieFile = [System.Windows.Forms.TextBox]::new()
$textBoxCookieFile.Location = [System.Drawing.Point]::new($xPos, $yPos)
$textBoxCookieFile.Size     = [System.Drawing.Size]::new(400, 25)
$textBoxCookieFile.Text     = $cfg_cookieFile
$textBoxCookieFile.Visible  = ($comboCookies.SelectedIndex -eq 2)
$_fc.Add($textBoxCookieFile)

$xPosFileBrowse = $xPos + 410
$btnCookieBrowse = [System.Windows.Forms.Button]::new()
$btnCookieBrowse.Location = [System.Drawing.Point]::new($xPosFileBrowse, $yPos)
$btnCookieBrowse.Size     = [System.Drawing.Size]::new(90, 25)
$btnCookieBrowse.Text     = "Обзор..."
$btnCookieBrowse.Visible  = ($comboCookies.SelectedIndex -eq 2)
$btnCookieBrowse.Add_Click({
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Filter = "Cookies (*.txt)|*.txt|All (*.*)|*.*"
    if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBoxCookieFile.Text = $fd.FileName
    }
})
$_fc.Add($btnCookieBrowse)

$comboCookies.Add_SelectedIndexChanged({
    $comboCookieBrowser.Visible = ($comboCookies.SelectedIndex -eq 1)
    $textBoxCookieFile.Visible  = ($comboCookies.SelectedIndex -eq 2)
    $btnCookieBrowse.Visible    = ($comboCookies.SelectedIndex -eq 2)
})

# Проверка наличия ffmpeg (нужен для мержа AI-перевода). Зеркалит runtime-проверку
# в блоке перевода ниже — сначала локальный ffmpeg.exe рядом со скриптом, потом PATH.
function Test-FfmpegAvailable {
    if (Test-Path $ffmpegLocal) { return $true }
    return [bool](Get-Command "ffmpeg" -ErrorAction SilentlyContinue)
}

# ── 8. AI-перевод ─────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$chkTranslate = [System.Windows.Forms.CheckBox]::new()
$chkTranslate.Location = [System.Drawing.Point]::new($xPos, $yPos)
$chkTranslate.Size     = [System.Drawing.Size]::new(150, 20)
$chkTranslate.Text     = "AI-перевод аудио"
$chkTranslate.Checked  = ($cfg_transEnabled -eq "true")
$_fc.Add($chkTranslate)

$xPos += 170
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(50, 20)
$lbl.Text     = "Язык:"
$_fc.Add($lbl)

$xPos += 50
$comboTransLang = [System.Windows.Forms.ComboBox]::new()
$comboTransLang.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboTransLang.Size          = [System.Drawing.Size]::new(60, 25)
$comboTransLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransLang.Items.AddRange(@("ru", "en", "kk"))
$langIdx = switch ($cfg_transLang) { "en" { 1 } "kk" { 2 } default { 0 } }
$comboTransLang.SelectedIndex = $langIdx
$_fc.Add($comboTransLang)

$xPos += 80
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(55, 20)
$lbl.Text     = "Режим:"
$_fc.Add($lbl)

$xPos += 55
$comboTransMode = [System.Windows.Forms.ComboBox]::new()
$comboTransMode.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboTransMode.Size          = [System.Drawing.Size]::new(130, 25)
$comboTransMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransMode.Items.AddRange(@("2 дорожки", "Смешать", "Заменить"))
$modeIdx = switch ($cfg_transMode) { "mix" { 1 } "replace" { 2 } default { 0 } }
$comboTransMode.SelectedIndex = $modeIdx
$_fc.Add($comboTransMode)

$xPos += 150
$lbl = [System.Windows.Forms.Label]::new()
$lbl.Location = [System.Drawing.Point]::new($xPos, $yPos)
$lbl.Size     = [System.Drawing.Size]::new(55, 20)
$lbl.Text     = "Голос:"
$_fc.Add($lbl)

$xPos += 55
$comboTransVoice = [System.Windows.Forms.ComboBox]::new()
$comboTransVoice.Location      = [System.Drawing.Point]::new($xPos, $yPos)
$comboTransVoice.Size          = [System.Drawing.Size]::new(90, 25)
$comboTransVoice.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransVoice.Items.AddRange(@("live", "tts"))
$voiceIdx = if ($cfg_transVoice -eq "tts") { 1 } else { 0 }
$comboTransVoice.SelectedIndex = $voiceIdx
$_fc.Add($comboTransVoice)

# Предупреждение об отсутствии ffmpeg (аналог GPU-проверки в FFmpeg GUI)
$xPos += 95
$lblTransFfmpeg = [System.Windows.Forms.Label]::new()
$lblTransFfmpeg.Location  = [System.Drawing.Point]::new($xPos, $yPos)
$lblTransFfmpeg.AutoSize  = $true
$lblTransFfmpeg.ForeColor = [System.Drawing.Color]::Firebrick
$lblTransFfmpeg.Text      = ""
$_fc.Add($lblTransFfmpeg)

# При включении галочки проверяем ffmpeg и показываем уведомление, если его нет
$chkTranslate.Add_CheckedChanged({
    if ($chkTranslate.Checked -and -not (Test-FfmpegAvailable)) {
        $lblTransFfmpeg.Text = "ffmpeg не найден!"
    } else {
        $lblTransFfmpeg.Text = ""
    }
})
# Стартовая проверка, если перевод уже включён в config.ini
if ($chkTranslate.Checked -and -not (Test-FfmpegAvailable)) {
    $lblTransFfmpeg.Text = "ffmpeg не найден!"
}

# ── 9. Прогресс-бар ───────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$progressBar = [System.Windows.Forms.ProgressBar]::new()
$progressBar.Location = [System.Drawing.Point]::new($xPos, $yPos)
$progressBar.Size     = [System.Drawing.Size]::new(780, 20)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$_fc.Add($progressBar)

# ── 10. RichTextBox вывода ────────────────────────────────────────────────
$yPos += 25; $xPos = $xPos0
$richOutput = [System.Windows.Forms.RichTextBox]::new()
$richOutput.Location  = [System.Drawing.Point]::new($xPos, $yPos)
$richOutput.Size      = [System.Drawing.Size]::new(780, 220)
$richOutput.ReadOnly  = $true
$richOutput.Font      = [System.Drawing.Font]::new("Consolas", 9)
$richOutput.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$richOutput.ForeColor = [System.Drawing.Color]::White
$_fc.Add($richOutput)

# ── Функции вывода с цветом ───────────────────────────────────────────────
function Append-Output {
    param([string]$Text, [System.Drawing.Color]$Color = [System.Drawing.Color]::White)
    $richOutput.SelectionStart  = $richOutput.TextLength
    $richOutput.SelectionLength = 0
    $richOutput.SelectionColor  = $Color
    $richOutput.AppendText($Text + "`n")
    $richOutput.ScrollToCaret()
}

# ── 11. Статусная строка ──────────────────────────────────────────────────
$yPos += 225; $xPos = $xPos0
$lblStatus = [System.Windows.Forms.Label]::new()
$lblStatus.Location  = [System.Drawing.Point]::new($xPos, $yPos)
$lblStatus.Size      = [System.Drawing.Size]::new(780, 20)
$lblStatus.Text      = "Готов к загрузке"
$lblStatus.ForeColor = [System.Drawing.Color]::Gray
$_fc.Add($lblStatus)

# ── 11b. Команда (поле + кнопка копирования) ─────────────────────────────
$yPos += 22; $xPos = $xPos0
$labelCmd = [System.Windows.Forms.Label]::new()
$labelCmd.Location = [System.Drawing.Point]::new($xPos, $yPos + 2)
$labelCmd.Size     = [System.Drawing.Size]::new(60, 16)
$labelCmd.Text     = "Команда:"
$labelCmd.Font     = [System.Drawing.Font]::new($labelCmd.Font.FontFamily, 8)
$_fc.Add($labelCmd)

$textCommand = [System.Windows.Forms.TextBox]::new()
$textCommand.Location  = [System.Drawing.Point]::new($xPos + 62, $yPos)
$textCommand.Size      = [System.Drawing.Size]::new(718, 20)
$textCommand.ReadOnly  = $true
$textCommand.BackColor = [System.Drawing.Color]::White
$textCommand.Font      = [System.Drawing.Font]::new("Consolas", 8)
$textCommand.Text      = ""
$_fc.Add($textCommand)

# ── Глобальные переменные ─────────────────────────────────────────────────
$global:processRunning  = $false
$global:downloadProcess = $null
# Дочерний процесс AI-перевода (vot-cli-live). Ходит в сеть и раньше выполнялся
# синхронным ReadToEnd/WaitForExit на UI-потоке без таймаута — зависший сервис держал
# окно бессрочно, а Stop его не трогал. Теперь Stop убивает и его.
$global:translateProcess = $null

function Stop-Download {
    param([bool]$silent = $false)
    $global:processRunning = $false
    # НЕ обнуляем $global:downloadProcess и НЕ убиваем чужие yt-dlp — основной цикл
    # должен дождаться нашего процесса (WaitForExit) без NullReferenceException, а
    # массовый Stop-Process убивал бы параллельные загрузки других программ.
    if ($global:downloadProcess -ne $null -and -not $global:downloadProcess.HasExited) {
        try { $global:downloadProcess.Kill() } catch { }
    }
    # AI-перевод: убиваем vot-cli-live, иначе Stop не прерывал бы сетевой перевод.
    if ($global:translateProcess -ne $null -and -not $global:translateProcess.HasExited) {
        try { $global:translateProcess.Kill() } catch { }
    }
    if (-not $silent) {
        Append-Output "Загрузка остановлена" ([System.Drawing.Color]::Yellow)
    }
}

# ── 12. Кнопки ────────────────────────────────────────────────────────────
$yPos += 25; $xPos = $xPos0

$btnStart = [System.Windows.Forms.Button]::new()
$btnStart.Location  = [System.Drawing.Point]::new($xPos, $yPos)
$btnStart.Size      = [System.Drawing.Size]::new(185, 35)
$btnStart.Text      = "Начать загрузку"
$btnStart.BackColor = [System.Drawing.Color]::LightGreen
$btnStart.Font      = [System.Drawing.Font]::new("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$btnStart.Add_Click({
    if ($global:processRunning) { return }

    # Валидация очереди
    if ($global:urlQueue.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Добавьте хотя бы один URL в очередь",
            "Ошибка", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    # Валидация папки: пустое поле → Test-Path '' / New-Item '' падают с сырым .NET-исключением.
    if ([string]::IsNullOrWhiteSpace($textBoxFolder.Text)) {
        [System.Windows.Forms.MessageBox]::Show(
            "Укажите папку для сохранения",
            "Ошибка", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $btnStart.Enabled = $false
    $btnStop.Enabled  = $true
    # Очередь нельзя менять во время загрузки — иначе индексы съезжают.
    $btnRemoveUrl.Enabled = $false
    $btnClearQueue.Enabled = $false
    $global:processRunning = $true
    $richOutput.Clear()
    $progressBar.Value = 0
    $lblStatus.Text    = "Загрузка..."

    # Таблицы форматов ($formatPresets/$simpleBest) определены в script scope выше —
    # один источник истины для GUI и для тестов (Quote-WinArg квотирует при отправке).

    # Читаем очередь динамически — новые URL добавленные во время загрузки тоже будут обработаны
    $successCount  = 0
    $failCount     = 0
    # Паритет с COUNT_SKIP в .sh: архивные пропуски не должны выдаваться за загрузки.
    $skipCount     = 0

    try {
        $itemIdx = 0
        while ($itemIdx -lt $global:urlQueue.Count -and $global:processRunning) {
            $totalItems  = $global:urlQueue.Count

            $queueItem   = $global:urlQueue[$itemIdx]
            $currentUrl  = $queueItem.Url
            $platform    = $queueItem.Platform
            $itemNum     = $itemIdx + 1

            $progressBar.Value = 0
            $lblStatus.Text    = "Загрузка $itemNum/$totalItems  [$platform]"
            $form.Text         = "Video Downloader (yt-dlp) v15  [$itemNum/$totalItems]"
            Append-Output ""
            Append-Output "═══ [$itemNum/$totalItems] [$platform]  $currentUrl" ([System.Drawing.Color]::Cyan)

            $folder = $textBoxFolder.Text
            if (-not (Test-Path $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }

            # continue_on_error: true → -i (пропускать ошибки), false → --abort-on-error.
            $errFlag = if ($cfg_continueOnErr -eq "false") { "--abort-on-error" } else { "-i" }
            $command = @("-c", $errFlag, "-w", "--windows-filenames", "--compat-options", "filename-sanitization") + (Build-NetArgs)
            # F13. Точный handshake вместо поиска по mtime: yt-dlp сам сообщает финальный
            # путь каждого готового файла (after_move — уже после post-processor'ов и move).
            # --print-to-file пишет в наш per-process файл, не смешиваясь с прогрессом.
            # Без этого перевод искал «самый свежий файл в дереве» и мог утащить чужую загрузку.
            # Потребителей манифеста ДВА, как и в .sh:
            #   1) перевод — нужны пути готовых файлов;
            #   2) учёт archive-skip — пустой манифест при включённом архиве означает,
            #      что видео уже скачано и yt-dlp ничего не переместил.
            # Раньше манифест создавался ТОЛЬКО под перевод, поэтому (2) в GUI не
            # работал вовсе: URL, целиком лежащий в архиве, попадал в successCount и
            # печатался как «Готово» — сводка «N/M» завышала число реальных загрузок.
            $dlManifest = $null
            if ($chkTranslate.Checked -or ($cfg_useArchive -eq "true" -and $qi -lt 7)) {
                $dlManifest = Join-Path ([System.IO.Path]::GetTempPath()) ("ytdlp_manifest_{0}.txt" -f [System.Guid]::NewGuid().ToString('N'))
                Set-Content -LiteralPath $dlManifest -Value $null -Encoding UTF8
                $command += "--print-to-file", "after_move:filepath", $dlManifest
            }
            # Архив добавляется ниже — только для реальных загрузок (qi 0..6), НЕ для
            # режима «только субтитры» (qi 7/8): архив хранит ID видео, а не наличие
            # субтитров, иначе субтитры молча пропускаются (F3, паритет с CMD).
            $denoExe = Join-Path $scriptDir "deno.exe"
            if (Test-Path $denoExe) { $command += "--js-runtimes", "deno:$denoExe" }
            $tpl = if ($currentUrl -match '[?&]list=') { $cfg_plTemplate } else { $cfg_template }
            $tpl = $tpl -replace '/', '\'
            $command += "-o", "$folder\$tpl"

            # Прокси: используем переменные окружения вместо --proxy,
            # чтобы пароль не попадал в Get-Process | CommandLine.
            $proxyEnvVal = $null
            if (([string]$comboProxyType.SelectedItem -ne "нет") -and -not [string]::IsNullOrWhiteSpace($textProxyHost.Text)) {
                $pType = $comboProxyType.SelectedItem
                $pHost = $textProxyHost.Text
                $pPort = $textProxyPort.Text
                $pUser = $textProxyUser.Text
                $pPass = $textProxyPass.Text
                $proxyEnvVal = if (-not [string]::IsNullOrWhiteSpace($pUser) -and -not [string]::IsNullOrWhiteSpace($pPass)) {
                    "${pType}://${pUser}:${pPass}@${pHost}"
                } else {
                    "${pType}://${pHost}"
                }
                if (-not [string]::IsNullOrWhiteSpace($pPort)) { $proxyEnvVal += ":${pPort}" }
            }

            # Cookies
            switch ($comboCookies.SelectedIndex) {
                1 { $command += "--cookies-from-browser", $comboCookieBrowser.SelectedItem }
                2 {
                    if (-not [string]::IsNullOrWhiteSpace($textBoxCookieFile.Text)) {
                        $cookiePath = $textBoxCookieFile.Text
                        if (-not [System.IO.Path]::IsPathRooted($cookiePath)) { $cookiePath = Join-Path $scriptDir $cookiePath }
                        if (Test-Path $cookiePath) {
                            $command += "--cookies", $cookiePath
                        } else {
                            Append-Output "WARN: cookie-файл не найден: $cookiePath" ([System.Drawing.Color]::Yellow)
                        }
                    }
                }
            }

            # Формат
            $qi          = $comboQuality.SelectedIndex
            $selectedFmt = $comboFormat.SelectedItem
            # auto: для YouTube -> avc1_best, для остальных платформ -> простой best[height<=N]
            $effectiveFmt = $selectedFmt
            if ($selectedFmt -eq "auto") {
                if ($platform -eq "YouTube") {
                    $effectiveFmt = "avc1_best"
                } else {
                    # $simpleBest — в script scope выше (один источник истины).
                    if ($qi -ge 0 -and $qi -le 6) {
                        $command += "-f", $simpleBest[$qi]
                    }
                    $effectiveFmt = ""  # отметка: уже добавили
                }
            }
            switch ($qi) {
                { $_ -ge 0 -and $_ -le 6 } {
                    if ($effectiveFmt) {
                        $command += "-f", $formatPresets[$effectiveFmt][$qi]
                    }
                }
                # F31. --write-subs запрашивает авторские субтитры, --write-auto-subs
                # оставляет автоматические как fallback. Раньше слался только auto-флаг —
                # авторские (обычно точнее) молча пропадали, хотя пункт меню называется
                # «Только субтитры», а не «только автоматические». Язык — из пункта меню
                # (RU/EN — осознанный выбор пользователя), формат — из конфига.
                7 { $command += "--write-subs", "--write-auto-subs", "--sub-langs", "ru", "--sub-format", $cfg_subFormat, "--skip-download" }
                8 { $command += "--write-subs", "--write-auto-subs", "--sub-langs", "en", "--sub-format", $cfg_subFormat, "--skip-download" }
            }

            # Аудио-формат: только для «Только аудио» (qi=0) и явного mp3/m4a/opus.
            if ($qi -eq 0 -and @("mp3", "m4a", "opus") -contains $comboAudioFormat.SelectedItem) {
                $command += "--extract-audio", "--audio-format", $comboAudioFormat.SelectedItem, "--audio-quality", "0"
            }
            # SponsorBlock и субтитры-с-видео: только для реальных загрузок (qi 0..6),
            # НЕ для режима «только субтитры» (qi 7/8).
            if ($qi -ge 0 -and $qi -le 6) {
                # Архив загруженного (паритет с .sh/CMD): только для реальных загрузок.
                if ($cfg_useArchive -eq "true") { $command += "--download-archive", (Join-Path $folder $cfg_archiveFile) }
                # Метаданные и главы источника (архивная ценность; без глав — no-op).
                $command += "--embed-metadata", "--embed-chapters"
                switch ($comboSponsorblock.SelectedItem) {
                    "mark"   { $command += "--sponsorblock-mark", "all" }
                    "remove" { $command += "--sponsorblock-remove", "all" }
                }
                switch ($comboSubsVideo.SelectedItem) {
                    "sidecar" { $command += "--write-subs", "--write-auto-subs", "--sub-langs", $cfg_subLang }
                    "embed"   { $command += "--write-subs", "--write-auto-subs", "--sub-langs", $cfg_subLang, "--embed-subs" }
                }
            }

            # Плейлист (номера проверяем — нечисловой ввод иначе уронит yt-dlp)
            if ($currentUrl -match '[?&]list=') {
                if (-not [string]::IsNullOrWhiteSpace($textBoxStart.Text)) {
                    $v = $textBoxStart.Text.Trim()
                    if ($v -match '^\d+$') { $command += "--playlist-start", $v }
                    else { Append-Output "Некорректный номер начала плейлиста: '$v' (игнорирую)" ([System.Drawing.Color]::Firebrick) }
                }
                if (-not [string]::IsNullOrWhiteSpace($textBoxEnd.Text)) {
                    $v = $textBoxEnd.Text.Trim()
                    if ($v -match '^\d+$') { $command += "--playlist-end", $v }
                    else { Append-Output "Некорректный номер конца плейлиста: '$v' (игнорирую)" ([System.Drawing.Color]::Firebrick) }
                }
            }

            # Фрагмент: только start = с TIME до конца; только end = с начала до TIME;
            # оба = фрагмент TIME1..TIME2; ни один = весь ролик.
            if ($chkTrimStart.Checked -or $chkTrimEnd.Checked) {
                # Метки валидируем (паритет с CMD: ^[0-9:.]+$), невалидные — игнорируем.
                $tFrom = "0"; $tTo = "inf"
                if ($chkTrimStart.Checked -and -not [string]::IsNullOrWhiteSpace($textTrimStart.Text)) {
                    $v = $textTrimStart.Text.Trim()
                    if ($v -match '^[0-9:.]+$') { $tFrom = $v } else { Append-Output "Некорректная метка начала фрагмента: '$v' (игнорирую)" ([System.Drawing.Color]::Firebrick) }
                }
                if ($chkTrimEnd.Checked -and -not [string]::IsNullOrWhiteSpace($textTrimEnd.Text)) {
                    $v = $textTrimEnd.Text.Trim()
                    if ($v -match '^[0-9:.]+$') { $tTo = $v } else { Append-Output "Некорректная метка конца фрагмента: '$v' (игнорирую)" ([System.Drawing.Color]::Firebrick) }
                }
                $command += "--download-sections", "*${tFrom}-${tTo}"
                if ($chkForceKf.Checked) { $command += "--force-keyframes-at-cuts" }
            }

            # F30. '--' закрывает список опций: всё дальше yt-dlp обязан трактовать как
            # позиционный URL, даже если строка начинается с дефиса. Вместе с валидацией
            # ввода это второй барьер против исполнения опции вместо загрузки.
            $command += "--"
            # URL — сырой; Quote-WinArg сам решит, нужны ли кавычки (& ? = и пр. — литералы).
            $command += $currentUrl

            # Строку для показа и для Arguments собираем ЕДИНЫМ квотером (Join-WinArgs).
            $cmdLine = Join-WinArgs $command
            $textCommand.Text = "$dlp $cmdLine"
            Append-Output "Команда: $dlp $cmdLine" ([System.Drawing.Color]::DimGray)

            # Запуск процесса
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $dlp
            $psi.Arguments              = $cmdLine
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.WorkingDirectory       = $scriptDir
            if ($proxyEnvVal) {
                $psi.EnvironmentVariables["HTTP_PROXY"]  = $proxyEnvVal
                $psi.EnvironmentVariables["HTTPS_PROXY"] = $proxyEnvVal
                $psi.EnvironmentVariables["ALL_PROXY"]   = $proxyEnvVal
            }

            $global:downloadProcess = New-Object System.Diagnostics.Process
            $global:downloadProcess.StartInfo        = $psi
            $global:downloadProcess.EnableRaisingEvents = $true

            $stdoutQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
            $stderrQueue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

            $evtOut = Register-ObjectEvent -InputObject $global:downloadProcess -EventName OutputDataReceived -Action {
                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
                    $Event.MessageData.Enqueue($EventArgs.Data)
                }
            } -MessageData $stdoutQueue

            $evtErr = Register-ObjectEvent -InputObject $global:downloadProcess -EventName ErrorDataReceived -Action {
                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
                    $Event.MessageData.Enqueue($EventArgs.Data)
                }
            } -MessageData $stderrQueue

            $global:downloadProcess.Start() | Out-Null
            $global:downloadProcess.BeginOutputReadLine()
            $global:downloadProcess.BeginErrorReadLine()

            while (-not $global:downloadProcess.HasExited -and $global:processRunning) {
                [System.Windows.Forms.Application]::DoEvents()
                $line = $null
                while ($stdoutQueue.TryDequeue([ref]$line)) {
                    if ($line -match '\[download\]\s+(\d+\.?\d*)%') {
                        $pct = [int][math]::Floor([double]$Matches[1])
                        $progressBar.Value = [math]::Min($pct, 100)
                        $lblStatus.Text    = "Загрузка $itemNum/$totalItems  [$platform]  $pct%"
                        $form.Text         = "Video Downloader (yt-dlp) v15  [$itemNum/$totalItems]  $pct%"
                    } elseif ($line -match '\[download\] Destination:') {
                        Append-Output $line ([System.Drawing.Color]::LightGreen)
                    } elseif ($line -match '\[Merger\]|\[info\].*Merging') {
                        Append-Output $line ([System.Drawing.Color]::Cyan)
                    } elseif (-not [string]::IsNullOrWhiteSpace($line)) {
                        Append-Output $line
                    }
                }
                while ($stderrQueue.TryDequeue([ref]$line)) {
                    if ($line -match 'WARNING|ERROR') {
                        Append-Output $line ([System.Drawing.Color]::Yellow)
                    }
                }
                Start-Sleep -Milliseconds 100
            }

            # WaitForExit() гарантирует, что все OutputDataReceived события успели
            # отработать (иначе последние строки yt-dlp могут остаться в очереди).
            # Stop-Download мог убить процесс, но НЕ обнуляет ссылку — guard на всякий случай.
            $proc = $global:downloadProcess
            $exitCode = -1
            if ($proc) { $proc.WaitForExit(); $exitCode = $proc.ExitCode }
            $line = $null
            while ($stdoutQueue.TryDequeue([ref]$line)) {
                if (-not [string]::IsNullOrWhiteSpace($line)) {
                    Append-Output $line
                }
            }
            while ($stderrQueue.TryDequeue([ref]$line)) {
                if ($line -match 'WARNING|ERROR') {
                    Append-Output $line ([System.Drawing.Color]::Yellow)
                }
            }

            # Снимаем подписки OutputDataReceived/ErrorDataReceived (2 на URL) и Dispose,
            # иначе они накапливаются между загрузками (утечка). Зануляем ссылки: чтобы
            # finally не трогал уже снятые подписки, а уцелевшие (при исключении на след.
            # итерации до Register-ObjectEvent) не осиротели (F: event/handle-leak).
            if ($evtOut) { Unregister-Event -SourceIdentifier $evtOut.Name -ErrorAction SilentlyContinue; $evtOut | Remove-Job -Force -ErrorAction SilentlyContinue; $evtOut = $null }
            if ($evtErr) { Unregister-Event -SourceIdentifier $evtErr.Name -ErrorAction SilentlyContinue; $evtErr | Remove-Job -Force -ErrorAction SilentlyContinue; $evtErr = $null }
            # Process освобождаем — иначе Win32-хендлы текут по всей очереди. Ссылку НЕ
            # обнуляем (Stop-Download полагается на неё для WaitForExit без NullRef — F5).
            if ($global:downloadProcess) { $global:downloadProcess.Dispose() }

            if ($exitCode -eq 0) {
                $progressBar.Value = 100

                # Архив включён, yt-dlp отработал успешно, но не переместил ни одного
                # файла (пустой манифест) → видео уже было в архиве. Это ПРОПУСК, а не
                # загрузка. Контракт дословно как у .sh (там это `return 2`): на пропуске
                # перевод не запускается, потому что переводить нечего.
                $archiveSkipped = $false
                if ($dlManifest -and $cfg_useArchive -eq "true" -and $qi -lt 7 -and (Test-Path -LiteralPath $dlManifest)) {
                    $archiveSkipped = ((Get-Item -LiteralPath $dlManifest).Length -eq 0)
                }

                if ($archiveSkipped) {
                    $skipCount++
                    Append-Output "Пропущено (уже в архиве): [$platform]  $currentUrl" ([System.Drawing.Color]::Yellow)
                } else {
                $successCount++
                Append-Output "Готово: [$platform]  $currentUrl" ([System.Drawing.Color]::LightGreen)

                # F1/F2: явное сообщение, если перевод включён, но неприменим к режиму.
                # vot переводит по URL: audio нет видео для мержа; плейлист нет URL на
                # каждое видео; trim/SponsorBlock remove рассинхронизируют дорожку.
                if ($chkTranslate.Checked) {
                    $translateSkip = $null
                    if ($qi -eq 0) { $translateSkip = "не поддерживается для загрузки только аудио" }
                    elseif ($qi -ge 7) { $translateSkip = "неприменим к режиму «только субтитры»" }
                    elseif ($currentUrl -match '[?&]list=') { $translateSkip = "недоступен для плейлистов (vot переводит по одному URL)" }
                    elseif ($chkTrimStart.Checked -or $chkTrimEnd.Checked) { $translateSkip = "рассинхронизируется с обрезкой ролика (--download-sections)" }
                    elseif ($comboSponsorblock.SelectedItem -eq "remove") { $translateSkip = "рассинхронизируется со SponsorBlock remove" }
                    if ($translateSkip) { Append-Output "AI-перевод отключён: $translateSkip." ([System.Drawing.Color]::Yellow) }
                }

                # AI-перевод: только видео-качество (qi 1..6) и совместимый режим (см. выше).
                if ($chkTranslate.Checked -and $qi -ge 1 -and $qi -le 6 `
                        -and -not ($currentUrl -match '[?&]list=') `
                        -and -not $chkTrimStart.Checked -and -not $chkTrimEnd.Checked `
                        -and $comboSponsorblock.SelectedItem -ne "remove") {
                    $lblStatus.Text = "AI-перевод $itemNum/$totalItems..."
                    Append-Output "Получение AI-перевода..." ([System.Drawing.Color]::Cyan)

                    # F14 (паритет с .sh). Запрошенный перевод, применимый к режиму, обязан
                    # ЛИБО дать переведённый файл, ЛИБО быть засчитан как ошибка. Иначе провал
                    # перевода (нет зависимостей, vot без результата, ошибка мержа) тонет:
                    # загрузка ++successCount, а сводка рапортует чистый успех, ничего не переведя.
                    $translateOk = $false

                    $transLang      = $comboTransLang.SelectedItem
                    $transVoice     = $comboTransVoice.SelectedItem
                    $transModeNames = @("dual_track", "mix", "replace")
                    $transMode      = $transModeNames[$comboTransMode.SelectedIndex]

                    $hasDeps = $true
                    $votExe  = Join-Path $scriptDir "vot-cli-live.exe"
                    if (Test-Path $votExe) {
                        $votBin = $votExe
                    } elseif (Get-Command "vot-cli-live" -ErrorAction SilentlyContinue) {
                        $votBin = "vot-cli-live"
                    } else {
                        Append-Output "vot-cli-live не найден. Положите vot-cli-live.exe рядом со скриптом или: npm install -g vot-cli-live" ([System.Drawing.Color]::Red)
                        $hasDeps = $false
                    }
                    if (-not (Test-FfmpegAvailable)) {
                        Append-Output "ffmpeg не найден. Положите ffmpeg.exe рядом со скриптом или установите: https://ffmpeg.org" ([System.Drawing.Color]::Red)
                        $hasDeps = $false
                    }

                    if ($hasDeps) {
                        $tempDir = Join-Path $env:TEMP "yt-dlp-translate-$(Get-Random)"
                        New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

                        # NODE_TLS_REJECT_UNAUTHORIZED=0 нужен только vot-cli-live (внутренний
                        # node.js процесс ходит к translate-сервису с самоподписанным сертификатом).
                        # Передаём env только в дочерний процесс через ProcessStartInfo, чтобы
                        # переменная не висела на PowerShell-процессе и не влияла на параллельный
                        # код (Invoke-RestMethod при проверке обновлений, и т.п.).
                        $votPsi = New-Object System.Diagnostics.ProcessStartInfo
                        $votPsi.FileName               = $votBin
                        $votPsi.RedirectStandardOutput = $true
                        $votPsi.RedirectStandardError  = $true
                        $votPsi.UseShellExecute        = $false
                        $votPsi.CreateNoWindow         = $true
                        Append-Output "WARN: TLS-проверка отключена для AI-перевода (vot-cli-live) — риск MITM." ([System.Drawing.Color]::Yellow)
                        $votPsi.EnvironmentVariables["NODE_TLS_REJECT_UNAUTHORIZED"] = "0"
                        # Перевод тоже должен ходить через proxy (как и загрузка), иначе
                        # vot-cli-live стучится напрямую и падает там, где доступ только через прокси.
                        if ($proxyEnvVal) {
                            $votPsi.EnvironmentVariables["HTTP_PROXY"]  = $proxyEnvVal
                            $votPsi.EnvironmentVariables["HTTPS_PROXY"] = $proxyEnvVal
                            $votPsi.EnvironmentVariables["ALL_PROXY"]   = $proxyEnvVal
                        }
                        # Quoting: тот же единый квотер, что и для yt-dlp (--output/--reslang
                        # с пробелами в пути, URL со спецсимволами) — CommandLineToArgvW-корректно.
                        $votArgs = @("--output=$tempDir", "--voice-style=$transVoice", "--reslang=$transLang", $currentUrl)
                        $votPsi.Arguments = Join-WinArgs $votArgs
                        $votProc = [System.Diagnostics.Process]::Start($votPsi)
                        $global:translateProcess = $votProc
                        # Оба потока читаем асинхронно: последовательный ReadToEnd по одному
                        # пайпу блокирует до его закрытия (т.е. до выхода vot), а при сетевом
                        # висе — бессрочно; плюс deadlock, если переполнится второй буфер.
                        $outTask = $votProc.StandardOutput.ReadToEndAsync()
                        $errTask = $votProc.StandardError.ReadToEndAsync()
                        # Ждём с прокачкой message-loop (DoEvents), чтобы окно не висело и Stop
                        # оставался кликабельным. Отмена (processRunning=false) и потолок времени
                        # убивают vot — иначе зависший перевод держал бы GUI бессрочно.
                        $_votTimeoutMs = 900000
                        $_votSw = [System.Diagnostics.Stopwatch]::StartNew()
                        while (-not $votProc.HasExited) {
                            [System.Windows.Forms.Application]::DoEvents()
                            if (-not $global:processRunning) { try { $votProc.Kill() } catch {}; break }
                            if ($_votSw.ElapsedMilliseconds -gt $_votTimeoutMs) {
                                try { $votProc.Kill() } catch {}
                                Append-Output "AI-перевод: превышен таймаут vot-cli-live — прервано." ([System.Drawing.Color]::Red)
                                break
                            }
                            Start-Sleep -Milliseconds 150
                        }
                        $votProc.WaitForExit()
                        $null = $outTask.Result; $null = $errTask.Result
                        if ($votProc) { $votProc.Dispose() }
                        $global:translateProcess = $null

                        $transFile = Get-ChildItem -Path $tempDir -Filter "*.mp3" -File | Select-Object -First 1

                        if ($transFile) {
                            # F13. Источник пути — манифест самого yt-dlp, а не «самый свежий
                            # файл в дереве»: тот мог принадлежать параллельному процессу.
                            # Манифест может содержать и не-медиа результаты (sidecar-субтитры).
                            $latestVideo = $null
                            if ($dlManifest -and (Test-Path -LiteralPath $dlManifest)) {
                                $reported = @(Get-Content -LiteralPath $dlManifest -ErrorAction SilentlyContinue |
                                    Where-Object { $_ -and ([System.IO.Path]::GetExtension($_) -in @('.mp4','.mkv','.webm')) } |
                                    Select-Object -Unique)
                                foreach ($p in $reported) {
                                    if (Test-Path -LiteralPath $p) { $latestVideo = Get-Item -LiteralPath $p; break }
                                }
                            }
                            if ($latestVideo) {
                                # Сохраняем исходное расширение: -c:v copy VP9/AV1 в mp4 может упасть.
                                $outputFile = $latestVideo.FullName -replace ([regex]::Escape($latestVideo.Extension) + '$'), ('_translated' + $latestVideo.Extension)
                                Append-Output "Мерж аудиодорожек ($transMode)..." ([System.Drawing.Color]::Cyan)
                                # WebM-контейнер не принимает AAC → для .webm кодируем перевод в libopus.
                                $mergeACodec = if ($latestVideo.Extension -eq ".webm") { "libopus" } else { "aac" }
                                # `-map 0:a` переносит ВСЕ оригинальные дорожки, поэтому индекс
                                # перевода равен их числу, а не единице: при двух оригиналах
                                # metadata для a:1 села бы на второй оригинал, а сам перевод
                                # (a:2) остался бы без языка и названия.
                                $origACount = 1
                                try {
                                    $probe = @(& $ffprobeBin -v error -select_streams a `
                                        -show_entries stream=index -of csv=p=0 $latestVideo.FullName 2>$null |
                                        Where-Object { $_ -match '\S' })
                                    if ($probe.Count -ge 1) { $origACount = $probe.Count }
                                } catch { $origACount = 1 }
                                # F4: -map 0:s? -map 0:t? + -c:s copy сохраняют субтитры/вложения
                                # исходника — иначе встроенные субтитры исчезают после мержа перевода.
                                $ffArgs = switch ($transMode) {
                                    "dual_track" { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-map", "0:v", "-map", "0:a", "-map", "1:a", "-map", "0:s?", "-map", "0:t?",
                                                     "-c:v", "copy", "-c:a", "copy",
                                                     "-c:a:$origACount", $mergeACodec, "-b:a:$origACount", "192k", "-c:s", "copy",
                                                     "-metadata:s:a:0", "language=$cfg_transOrigLang",
                                                     "-metadata:s:a:0", "title=Original",
                                                     "-metadata:s:a:$origACount", "language=$transLang",
                                                     "-metadata:s:a:$origACount", "title=AI Translation",
                                                     "-disposition:a:0", "default", $outputFile) }
                                    "replace"    { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-map", "0:v", "-map", "1:a", "-map", "0:s?", "-map", "0:t?",
                                                     "-c:v", "copy", "-c:a", $mergeACodec, "-b:a", "192k", "-c:s", "copy",
                                                     "-metadata:s:a:0", "language=$transLang",
                                                     "-metadata:s:a:0", "title=AI Translation", $outputFile) }
                                    "mix"        { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-filter_complex", "[0:a]volume=$cfg_transOrigVol[a0];[1:a]volume=$cfg_transTransVol[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[aout]",
                                                     "-map", "0:v", "-map", "[aout]", "-map", "0:s?", "-map", "0:t?",
                                                     "-c:v", "copy", "-c:a", $mergeACodec, "-b:a", "192k", "-c:s", "copy", $outputFile) }
                                }
                                & $ffmpegBin @ffArgs 2>&1 | Out-Null
                                if ($LASTEXITCODE -eq 0 -and (Test-Path $outputFile)) {
                                    Move-Item -Path $outputFile -Destination $latestVideo.FullName -Force
                                    Append-Output "Перевод добавлен!" ([System.Drawing.Color]::LightGreen)
                                    $translateOk = $true
                                } else {
                                    Remove-Item -Path $outputFile -Force -ErrorAction SilentlyContinue
                                    Append-Output "Ошибка мержа аудиодорожек — оригинал сохранён" ([System.Drawing.Color]::Red)
                                }
                            } else {
                                # F14. Запрошенный перевод без результата — ошибка, а не заметка:
                                # иначе GUI отрапортует общий успех, ничего не переведя.
                                Append-Output "Ошибка: yt-dlp не сообщил ни одного медиафайла — переводить нечего" ([System.Drawing.Color]::Red)
                            }
                        } else {
                            Append-Output "Не удалось получить перевод" ([System.Drawing.Color]::Yellow)
                        }
                        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    # Перевод был запрошен и применим, но результата нет → это ошибка (nonzero-
                    # семантика .sh: COUNT_FAIL++). Загрузка уже засчитана в successCount, поэтому
                    # элемент отражается как «скачан, но перевод не выполнен».
                    if (-not $translateOk) {
                        $failCount++
                        Append-Output "AI-перевод не выполнен — засчитано как ошибка." ([System.Drawing.Color]::Red)
                    }
                }
                } # конец ветки «реальная загрузка» (не archive-skip)
                # Очистка манифеста — общая для обеих веток.
                if ($dlManifest) { Remove-Item -LiteralPath $dlManifest -Force -ErrorAction SilentlyContinue }
            } elseif ($global:processRunning) {
                $failCount++
                Append-Output "Ошибка: [$platform]  $currentUrl" ([System.Drawing.Color]::Red)
            }
            $itemIdx++
        } # конец while

        # Итоговая сводка
        Append-Output ""
        if ($global:processRunning) {
            $summary = "═══ Готово: $successCount/$totalItems"
            # Паритет с print_summary в .sh: пропуски показываются отдельной строкой,
            # иначе «Готово: 0/5» при полностью архивной очереди выглядит как провал.
            if ($skipCount -gt 0) { $summary += "  |  Пропущено (в архиве): $skipCount" }
            if ($failCount -gt 0) { $summary += "  |  Ошибки: $failCount" }
            Append-Output $summary ([System.Drawing.Color]::LightGreen)
            $lblStatus.Text = "Завершено: $successCount/$totalItems"
            $form.Text      = "Video Downloader (yt-dlp) v15 — Готово!"
        } else {
            Append-Output "═══ Остановлено  |  Загружено: $successCount" ([System.Drawing.Color]::Yellow)
            $lblStatus.Text = "Остановлено"
        }
    }
    catch {
        Append-Output "Ошибка: $_" ([System.Drawing.Color]::Red)
        [System.Windows.Forms.MessageBox]::Show($_.ToString(), "Ошибка",
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    finally {
        # Если исключение прервало итерацию между Register-ObjectEvent и штатной очисткой
        # (напр. Start() не нашёл yt-dlp.exe) — снимаем ещё живые подписки/PSEventJob
        # текущего URL, иначе они текут до закрытия GUI. Штатный путь уже занулил эти
        # ссылки, поэтому здесь очистка сработает только на пути исключения.
        if ($evtOut) { Unregister-Event -SourceIdentifier $evtOut.Name -ErrorAction SilentlyContinue; $evtOut | Remove-Job -Force -ErrorAction SilentlyContinue }
        if ($evtErr) { Unregister-Event -SourceIdentifier $evtErr.Name -ErrorAction SilentlyContinue; $evtErr | Remove-Job -Force -ErrorAction SilentlyContinue }
        $btnStart.Enabled      = $true
        $btnStop.Enabled       = $false
        $btnRemoveUrl.Enabled  = $true
        $btnClearQueue.Enabled = $true
        $global:processRunning = $false
    }
})
$_fc.Add($btnStart)

$xPos += 195
$btnStop = [System.Windows.Forms.Button]::new()
$btnStop.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnStop.Size     = [System.Drawing.Size]::new(185, 35)
$btnStop.Text     = "Остановить"
$btnStop.Enabled  = $false
$btnStop.Add_Click({ Stop-Download })
$_fc.Add($btnStop)

$xPos += 195
$btnClear = [System.Windows.Forms.Button]::new()
$btnClear.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnClear.Size     = [System.Drawing.Size]::new(185, 35)
$btnClear.Text     = "Очистить лог"
$btnClear.Add_Click({
    $richOutput.Clear()
    $progressBar.Value = 0
    $lblStatus.Text    = "Готов к загрузке"
    $form.Text         = "Video Downloader (yt-dlp) v15"
})
$_fc.Add($btnClear)

$xPos += 195
$btnExit = [System.Windows.Forms.Button]::new()
$btnExit.Location = [System.Drawing.Point]::new($xPos, $yPos)
$btnExit.Size     = [System.Drawing.Size]::new(185, 35)
$btnExit.Text     = "Выход"
$btnExit.Add_Click({
    if ($global:processRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Загрузка в процессе. Остановить и выйти?",
            "Подтверждение",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            Stop-Download -silent $true
            $form.Close()
        }
    } else { $form.Close() }
})
$_fc.Add($btnExit)

# ── Обработчик закрытия окна ──────────────────────────────────────────────
$form.Add_FormClosing({
    param($formSender, $e)
    if ($global:processRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Загрузка в процессе. Остановить и выйти?",
            "Подтверждение",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            Stop-Download -silent $true
        } else {
            $e.Cancel = $true
        }
    }
})

# Все контролы — в прокручиваемую панель: на маленьком разрешении нижние
# кнопки остаются доступны через вертикальную прокрутку.
$scrollPanel = [System.Windows.Forms.Panel]::new()
$scrollPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
$scrollPanel.AutoScroll = $true
$scrollPanel.Controls.AddRange($_fc.ToArray())
$form.Controls.Add($scrollPanel)
$form.ResumeLayout($true)

# Если форма выше/шире рабочей области экрана (маленькое разрешение) — ужимаем
# до рабочей области; внутренняя панель (AutoScroll) добавляет прокрутку,
# нижние кнопки остаются доступны.
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($form.Height -gt $wa.Height) {
    $form.Height = $wa.Height
    $form.Width  = [Math]::Min($form.Width + [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth, $wa.Width)
}
if ($form.Width -gt $wa.Width) { $form.Width = $wa.Width }

# ── Версия yt-dlp — после отрисовки формы (через отложенный вызов) ────
$script:dlpPath = "$dlp"
$form.Add_Shown({
    $t = [System.Windows.Forms.Timer]::new()
    $t.Interval = 50
    $t.Add_Tick({
        try {
            $this.Stop(); $this.Dispose()
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $script:dlpPath
            $psi.Arguments = '--version'
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.CreateNoWindow = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $ver = $p.StandardOutput.ReadToEnd().Trim()
            $p.WaitForExit()
            if ($ver) {
                $script:currentVersion = $ver
                $lblVersion.Text = "yt-dlp: $ver"
            } else {
                $lblVersion.Text = "yt-dlp: н/д"
            }
        } catch {
            $lblVersion.Text = "yt-dlp: н/д"
        }
    })
    $t.Start()
})

[void]$form.ShowDialog()
