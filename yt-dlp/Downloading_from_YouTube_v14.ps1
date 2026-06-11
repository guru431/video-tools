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
$configFile = Join-Path $scriptDir "config.ini"

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
            $val = $Matches[2] -replace '\s*#.*', ''
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

$qualityMap = @{ "720" = 3; "360" = 1; "480" = 2; "1080" = 4; "1440" = 5; "2160" = 6 }
$defaultQualityIdx = if ($qualityMap.ContainsKey($cfg_quality)) { $qualityMap[$cfg_quality] } else { 3 }

$dlpLocal = Join-Path $scriptDir "yt-dlp.exe"
if (Test-Path $dlpLocal) { $dlp = $dlpLocal } else { $dlp = "yt-dlp" }

# ── Определение платформы по URL ──────────────────────────────────────────
function Get-Platform {
    param([string]$Url)
    switch -Regex ($Url) {
        'youtube\.com|youtu\.be' { return 'YouTube' }
        'rutube\.ru'             { return 'RuTube' }
        'vk\.com'               { return 'VK Video' }
        'twitch\.tv'            { return 'Twitch' }
        'vimeo\.com'            { return 'Vimeo' }
        'dailymotion\.com'      { return 'Dailymotion' }
        default                  { return 'Video' }
    }
}

# ── Текущая версия yt-dlp (заполняется после показа формы) ────────────────
$currentVersion = ""

# ── Глобальная очередь URL ────────────────────────────────────────────────
$global:urlQueue = [System.Collections.Generic.List[hashtable]]::new()

# ── Создание формы ────────────────────────────────────────────────────────
$form = [System.Windows.Forms.Form]::new()
$form.Text = "Video Downloader (yt-dlp) v14"
$form.Size = [System.Drawing.Size]::new(830, 775)
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
$textBoxFolder.Text     = [System.IO.Path]::Combine($PWD.Path, $cfg_baseDir)
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
# в блоке перевода ниже — ищем ffmpeg в PATH через Get-Command.
function Test-FfmpegAvailable {
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

function Stop-Download {
    param([bool]$silent = $false)
    $global:processRunning = $false
    if ($global:downloadProcess -ne $null -and -not $global:downloadProcess.HasExited) {
        try { $global:downloadProcess.Kill() } catch { }
    }
    try { Get-Process -Name "yt-dlp" -ErrorAction SilentlyContinue | Stop-Process -Force } catch { }
    $global:downloadProcess = $null
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

    $btnStart.Enabled = $false
    $btnStop.Enabled  = $true
    $global:processRunning = $true
    $richOutput.Clear()
    $progressBar.Value = 0
    $lblStatus.Text    = "Загрузка..."

    # Таблица форматов
    $formatPresets = @{
        "avc1_best" = @(
            "bestaudio[ext!=webm]/bestaudio",
            "`"bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360]`"",
            "`"bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480]`"",
            "`"bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]`"",
            "`"bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080]`"",
            "`"bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440]`"",
            "`"bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160]`""
        )
        "avc1_https" = @(
            "140", "140+134", "140+135/134", "140+136/135/134",
            "140+137/136/135/134",
            "`"140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]`"",
            "`"140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]`""
        )
        "avc1_m3u8" = @(
            "234", "234+230", "234+231/230", "234+232/231/230",
            "`"270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]`"",
            "`"bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]`"",
            "`"bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]`""
        )
        "avc1_https_60fps" = @(
            "140",
            "`"140+134/best[height<=360]`"",
            "`"140+135/best[height<=480]`"",
            "234+298/297/296",
            "234+299/298/297/296",
            "`"140+299/bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/best[height<=1440]`"",
            "`"140+299/bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/best[height<=2160]`""
        )
        "avc1_m3u8_60fps" = @(
            "234", "234+309", "234+310/309", "234+311/310/309",
            "234+312/311/310/309", "234+313/312/311/310/309", "234+314/313/312/311/310/309"
        )
        "avc1_https_60fps_hdr" = @(
            "234", "234+696", "234+697/696", "234+698/697/696",
            "234+699/698/697/696", "234+700/699/698/697/696", "234+701/700/699/698/697/696"
        )
        "old_combo" = @(
            "140", "18", "59/22/18", "22/18",
            "37/22/18", "38/37/22/18", "38/37/22/18"
        )
    }

    # Читаем очередь динамически — новые URL добавленные во время загрузки тоже будут обработаны
    $successCount  = 0
    $failCount     = 0

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
            $form.Text         = "Video Downloader (yt-dlp) v14  [$itemNum/$totalItems]"
            Append-Output ""
            Append-Output "═══ [$itemNum/$totalItems] [$platform]  $currentUrl" ([System.Drawing.Color]::Cyan)

            $folder = $textBoxFolder.Text
            if (-not (Test-Path $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }

            $command = @("-c", "-i", "-w", "--no-check-certificate", "--windows-filenames", "--compat-options", "filename-sanitization")
            $denoExe = Join-Path $scriptDir "deno.exe"
            if (Test-Path $denoExe) { $command += "--js-runtimes", "`"deno:$denoExe`"" }
            $tpl = if ($currentUrl -match '[?&]list=') { $cfg_plTemplate } else { $cfg_template }
            $tpl = $tpl -replace '/', '\'
            $command += "-o", "`"$folder\$tpl`""

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
                        $command += "--cookies", "`"$($textBoxCookieFile.Text)`""
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
                    $simpleBest = @(
                        "bestaudio/best",
                        "`"best[height<=360]/best`"",
                        "`"best[height<=480]/best`"",
                        "`"best[height<=720]/best`"",
                        "`"best[height<=1080]/best`"",
                        "`"best[height<=1440]/best`"",
                        "`"best[height<=2160]/best`""
                    )
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
                7 { $command += "--sub-lang", "ru", "--write-auto-sub", "--sub-format", "vtt", "--skip-download" }
                8 { $command += "--sub-lang", "en", "--write-auto-sub", "--sub-format", "vtt", "--skip-download" }
            }

            # Плейлист
            if ($currentUrl -match '[?&]list=') {
                if (-not [string]::IsNullOrWhiteSpace($textBoxStart.Text)) {
                    $command += "--playlist-start", $textBoxStart.Text
                }
                if (-not [string]::IsNullOrWhiteSpace($textBoxEnd.Text)) {
                    $command += "--playlist-end", $textBoxEnd.Text
                }
            }

            # Фрагмент: только start = с TIME до конца; только end = с начала до TIME;
            # оба = фрагмент TIME1..TIME2; ни один = весь ролик.
            if ($chkTrimStart.Checked -or $chkTrimEnd.Checked) {
                $tFrom = if ($chkTrimStart.Checked -and -not [string]::IsNullOrWhiteSpace($textTrimStart.Text)) { $textTrimStart.Text.Trim() } else { "0" }
                $tTo   = if ($chkTrimEnd.Checked   -and -not [string]::IsNullOrWhiteSpace($textTrimEnd.Text))   { $textTrimEnd.Text.Trim()   } else { "inf" }
                $command += "--download-sections", "`"*${tFrom}-${tTo}`""
                if ($chkForceKf.Checked) { $command += "--force-keyframes-at-cuts" }
            }

            # URL квотируем — может содержать & ? = и пр.
            $command += "`"$currentUrl`""

            $textCommand.Text = "$dlp $($command -join ' ')"
            Append-Output "Команда: $dlp $($command -join ' ')" ([System.Drawing.Color]::DimGray)

            # Метка времени перед загрузкой — для AI-перевода выбираем mp4, появившийся
            # в ходе ИМЕННО этой загрузки, а не самый свежий во всей папке (очередь,
            # параллельные внешние загрузки могли бы подсунуть чужой файл).
            $dlStartTime = Get-Date

            # Запуск процесса
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $dlp
            $psi.Arguments              = $command -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.WorkingDirectory       = $PWD.Path
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

            Register-ObjectEvent -InputObject $global:downloadProcess -EventName OutputDataReceived -Action {
                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
                    $Event.MessageData.Enqueue($EventArgs.Data)
                }
            } -MessageData $stdoutQueue | Out-Null

            Register-ObjectEvent -InputObject $global:downloadProcess -EventName ErrorDataReceived -Action {
                if (-not [string]::IsNullOrEmpty($EventArgs.Data)) {
                    $Event.MessageData.Enqueue($EventArgs.Data)
                }
            } -MessageData $stderrQueue | Out-Null

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
                        $form.Text         = "Video Downloader (yt-dlp) v14  [$itemNum/$totalItems]  $pct%"
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
            $global:downloadProcess.WaitForExit()
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

            if ($global:downloadProcess.HasExited -and $global:downloadProcess.ExitCode -eq 0) {
                $progressBar.Value = 100
                $successCount++
                Append-Output "Готово: [$platform]  $currentUrl" ([System.Drawing.Color]::LightGreen)

                # AI-перевод если включён и не субтитры
                if ($chkTranslate.Checked -and $qi -le 6) {
                    $lblStatus.Text = "AI-перевод $itemNum/$totalItems..."
                    Append-Output "Получение AI-перевода..." ([System.Drawing.Color]::Cyan)

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
                    if (-not (Get-Command "ffmpeg" -ErrorAction SilentlyContinue)) {
                        Append-Output "ffmpeg не найден. Установите: https://ffmpeg.org" ([System.Drawing.Color]::Red)
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
                        $votPsi.EnvironmentVariables["NODE_TLS_REJECT_UNAUTHORIZED"] = "0"
                        # Перевод тоже должен ходить через proxy (как и загрузка), иначе
                        # vot-cli-live стучится напрямую и падает там, где доступ только через прокси.
                        if ($proxyEnvVal) {
                            $votPsi.EnvironmentVariables["HTTP_PROXY"]  = $proxyEnvVal
                            $votPsi.EnvironmentVariables["HTTPS_PROXY"] = $proxyEnvVal
                            $votPsi.EnvironmentVariables["ALL_PROXY"]   = $proxyEnvVal
                        }
                        # Quoting: vot-cli-live принимает --key=value, поэтому простое join работает,
                        # но URL может содержать пробелы/спецсимволы — экранируем как в основном вызове.
                        $votArgs = @("--output=$tempDir", "--voice-style=$transVoice", "--reslang=$transLang", $currentUrl)
                        $votPsi.Arguments = ($votArgs | ForEach-Object {
                            if ($_ -match '[ "\\]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ }
                        }) -join " "
                        $votProc = [System.Diagnostics.Process]::Start($votPsi)
                        # Сливаем stdout/stderr, чтобы пайпы не блокировали процесс на больших объёмах.
                        $null = $votProc.StandardOutput.ReadToEnd()
                        $null = $votProc.StandardError.ReadToEnd()
                        $votProc.WaitForExit()

                        $transFile = Get-ChildItem -Path $tempDir -Filter "*.mp3" -File | Select-Object -First 1

                        if ($transFile) {
                            $latestVideo = Get-ChildItem -Path $folder -Filter "*.mp4" -Recurse -File |
                                Where-Object { $_.LastWriteTime -ge $dlStartTime } |
                                Sort-Object LastWriteTime -Descending | Select-Object -First 1
                            if ($latestVideo) {
                                $outputFile = $latestVideo.FullName -replace '\.mp4$', '_translated.mp4'
                                Append-Output "Мерж аудиодорожек ($transMode)..." ([System.Drawing.Color]::Cyan)
                                $ffArgs = switch ($transMode) {
                                    "dual_track" { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-map", "0:v", "-map", "0:a", "-map", "1:a",
                                                     "-c:v", "copy", "-c:a:0", "copy", "-c:a:1", "aac", "-b:a:1", "192k",
                                                     "-metadata:s:a:0", "language=eng",
                                                     "-metadata:s:a:0", "title=Original",
                                                     "-metadata:s:a:1", "language=$transLang",
                                                     "-metadata:s:a:1", "title=AI Translation",
                                                     "-disposition:a:0", "default", $outputFile) }
                                    "replace"    { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-map", "0:v", "-map", "1:a",
                                                     "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", $outputFile) }
                                    "mix"        { @("-y", "-i", $latestVideo.FullName, "-i", $transFile.FullName,
                                                     "-filter_complex", "[0:a]volume=0.3[a0];[1:a]volume=1.0[a1];[a0][a1]amix=inputs=2:duration=longest[aout]",
                                                     "-map", "0:v", "-map", "[aout]",
                                                     "-c:v", "copy", "-c:a", "aac", "-b:a", "192k", $outputFile) }
                                }
                                & ffmpeg @ffArgs 2>&1 | Out-Null
                                if (Test-Path $outputFile) {
                                    Move-Item -Path $outputFile -Destination $latestVideo.FullName -Force
                                    Append-Output "Перевод добавлен!" ([System.Drawing.Color]::LightGreen)
                                } else {
                                    Append-Output "Ошибка мержа аудиодорожек" ([System.Drawing.Color]::Red)
                                }
                            }
                        } else {
                            Append-Output "Не удалось получить перевод" ([System.Drawing.Color]::Yellow)
                        }
                        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
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
            if ($failCount -gt 0) { $summary += "  |  Ошибки: $failCount" }
            Append-Output $summary ([System.Drawing.Color]::LightGreen)
            $lblStatus.Text = "Завершено: $successCount/$totalItems"
            $form.Text      = "Video Downloader (yt-dlp) v14 — Готово!"
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
        $btnStart.Enabled      = $true
        $btnStop.Enabled       = $false
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
    $form.Text         = "Video Downloader (yt-dlp) v14"
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
