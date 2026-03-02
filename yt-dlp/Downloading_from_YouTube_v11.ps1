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

# ── Чтение config.ini ─────────────────────────────────────────────────────
function Read-Config {
    param([string]$Key, [string]$Section, [string]$Default = "")
    if (-not (Test-Path $configFile)) { return $Default }
    $inSection = $false
    foreach ($line in (Get-Content $configFile -Encoding UTF8)) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $inSection = ($Matches[1] -eq $Section)
            continue
        }
        if ($inSection -and $line -match "^${Key}\s*=\s*(.*)") {
            $val = $Matches[1] -replace '\s*#.*', ''
            return $val
        }
    }
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
$cfg_cookieMethod  = Read-Config "method"          "cookies"  "none"
$cfg_cookieBrowser = Read-Config "browser"         "cookies"  "chrome"
$cfg_cookieFile    = Read-Config "file"            "cookies"  "youtube_cookies.txt"
$cfg_transEnabled  = Read-Config "enabled"         "translation" "false"
$cfg_transLang     = Read-Config "target_lang"     "translation" "ru"
$cfg_transVoice    = Read-Config "voice_style"     "translation" "live"
$cfg_transMode     = Read-Config "mode"            "translation" "dual_track"

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
$form = New-Object System.Windows.Forms.Form
$form.Text = "Video Downloader (yt-dlp) v11"
$form.Size = New-Object System.Drawing.Size(830, 720)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10)

$xPos0 = 20
$yPos  = 15

# ── 0. Версия yt-dlp + кнопка проверки обновлений ─────────────────────────
$xPos = $xPos0
$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Location = New-Object System.Drawing.Point($xPos, ($yPos + 3))
$lblVersion.Size     = New-Object System.Drawing.Size(400, 20)
$lblVersion.Text     = "yt-dlp: ..."
$lblVersion.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblVersion)

$btnCheckUpdate = New-Object System.Windows.Forms.Button
$btnCheckUpdate.Location = New-Object System.Drawing.Point(618, $yPos)
$btnCheckUpdate.Size     = New-Object System.Drawing.Size(182, 25)
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
        if (-not [string]::IsNullOrWhiteSpace($textProxyHost.Text)) {
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
$form.Controls.Add($btnCheckUpdate)

$script:updateUrl    = ""
$lnkUpdateResult     = New-Object System.Windows.Forms.LinkLabel
$lnkUpdateResult.Location  = New-Object System.Drawing.Point(425, ($yPos + 5))
$lnkUpdateResult.Size      = New-Object System.Drawing.Size(190, 18)
$lnkUpdateResult.Text      = ""
$lnkUpdateResult.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 9)
$lnkUpdateResult.Add_LinkClicked({
    if (-not [string]::IsNullOrEmpty($script:updateUrl)) {
        [System.Diagnostics.Process]::Start($script:updateUrl) | Out-Null
    }
})
$form.Controls.Add($lnkUpdateResult)

# ── 1. URL + кнопка добавления ────────────────────────────────────────────
$yPos += 35; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "URL видео:"
$lbl.Font     = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lbl)

$xPos += 110
$textBoxUrl = New-Object System.Windows.Forms.TextBox
$textBoxUrl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textBoxUrl.Size     = New-Object System.Drawing.Size(556, 25)
$form.Controls.Add($textBoxUrl)

$xPos += 564
$btnAddUrl = New-Object System.Windows.Forms.Button
$btnAddUrl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnAddUrl.Size     = New-Object System.Drawing.Size(106, 25)
$btnAddUrl.Text     = "Добавить  ↵"
$form.Controls.Add($btnAddUrl)

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
$listBoxQueue = New-Object System.Windows.Forms.ListBox
$listBoxQueue.Location        = New-Object System.Drawing.Point($xPos, $yPos)
$listBoxQueue.Size            = New-Object System.Drawing.Size(666, 80)
$listBoxQueue.Font            = New-Object System.Drawing.Font("Consolas", 9)
$listBoxQueue.HorizontalScrollbar = $true
$form.Controls.Add($listBoxQueue)

$xPos += 674
$btnRemoveUrl = New-Object System.Windows.Forms.Button
$btnRemoveUrl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnRemoveUrl.Size     = New-Object System.Drawing.Size(106, 36)
$btnRemoveUrl.Text     = "Удалить"
$btnRemoveUrl.Add_Click({
    $idx = $listBoxQueue.SelectedIndex
    if ($idx -ge 0) {
        $listBoxQueue.Items.RemoveAt($idx)
        $global:urlQueue.RemoveAt($idx)
    }
})
$form.Controls.Add($btnRemoveUrl)

$btnClearQueue = New-Object System.Windows.Forms.Button
$btnClearQueue.Location = New-Object System.Drawing.Point($xPos, ($yPos + 42))
$btnClearQueue.Size     = New-Object System.Drawing.Size(106, 36)
$btnClearQueue.Text     = "Очистить"
$btnClearQueue.Add_Click({
    $listBoxQueue.Items.Clear()
    $global:urlQueue.Clear()
})
$form.Controls.Add($btnClearQueue)

# ── 3. Папка сохранения ───────────────────────────────────────────────────
$yPos += 90; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "Папка:"
$form.Controls.Add($lbl)

$xPos += 110
$textBoxFolder = New-Object System.Windows.Forms.TextBox
$textBoxFolder.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textBoxFolder.Size     = New-Object System.Drawing.Size(556, 25)
$textBoxFolder.Text     = [System.IO.Path]::Combine($PWD.Path, $cfg_baseDir)
$form.Controls.Add($textBoxFolder)

$xPos += 564
$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnBrowse.Size     = New-Object System.Drawing.Size(106, 25)
$btnBrowse.Text     = "Обзор..."
$btnBrowse.Add_Click({
    $fb = New-Object System.Windows.Forms.FolderBrowserDialog
    $fb.SelectedPath = $textBoxFolder.Text
    if ($fb.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBoxFolder.Text = $fb.SelectedPath
    }
})
$form.Controls.Add($btnBrowse)

# ── 4. Качество ───────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "Качество:"
$form.Controls.Add($lbl)

$xPos += 110
$comboQuality = New-Object System.Windows.Forms.ComboBox
$comboQuality.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboQuality.Size          = New-Object System.Drawing.Size(220, 25)
$comboQuality.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboQuality.Items.AddRange(@(
    "Только аудио", "360p", "480p", "720p", "1080p", "1440p", "2160p",
    "Субтитры (RU)", "Субтитры (EN)"
))
$comboQuality.SelectedIndex = $defaultQualityIdx
$form.Controls.Add($comboQuality)

$xPos += 230
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(65, 20)
$lbl.Text     = "Формат:"
$form.Controls.Add($lbl)

$xPos += 65
$comboFormat = New-Object System.Windows.Forms.ComboBox
$comboFormat.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboFormat.Size          = New-Object System.Drawing.Size(235, 25)
$comboFormat.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboFormat.Items.AddRange(@(
    "avc1_best", "avc1_https", "avc1_m3u8",
    "avc1_https_60fps", "avc1_m3u8_60fps",
    "avc1_https_60fps_hdr", "old_combo"
))
$cfg_format = Read-Config "format_preset" "download" "avc1_best"
$fmtIdx = $comboFormat.Items.IndexOf($cfg_format)
$comboFormat.SelectedIndex = if ($fmtIdx -ge 0) { $fmtIdx } else { 0 }
$form.Controls.Add($comboFormat)

# ── 5. Плейлист ───────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "Плейлист с:"
$form.Controls.Add($lbl)

$xPos += 110
$textBoxStart = New-Object System.Windows.Forms.TextBox
$textBoxStart.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textBoxStart.Size     = New-Object System.Drawing.Size(50, 25)
$form.Controls.Add($textBoxStart)

$xPos += 55
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(30, 20)
$lbl.Text     = "по:"
$form.Controls.Add($lbl)

$xPos += 30
$textBoxEnd = New-Object System.Windows.Forms.TextBox
$textBoxEnd.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textBoxEnd.Size     = New-Object System.Drawing.Size(50, 25)
$form.Controls.Add($textBoxEnd)

# ── 6. Прокси (5 полей) ───────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "Прокси:"
$form.Controls.Add($lbl)

$xPos += 110
$comboProxyType = New-Object System.Windows.Forms.ComboBox
$comboProxyType.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboProxyType.Size          = New-Object System.Drawing.Size(75, 25)
$comboProxyType.DropDownStyle = "DropDownList"
$comboProxyType.Items.AddRange(@("https", "http", "socks5", "socks4"))
$comboProxyType.SelectedItem  = $cfg_proxyType
if ($comboProxyType.SelectedIndex -lt 0) { $comboProxyType.SelectedIndex = 0 }
$form.Controls.Add($comboProxyType)

$xPos += 80
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(18, 20)
$lbl.Text     = "://"
$form.Controls.Add($lbl)

$xPos += 18
$textProxyHost = New-Object System.Windows.Forms.TextBox
$textProxyHost.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textProxyHost.Size     = New-Object System.Drawing.Size(210, 25)
$textProxyHost.Text     = $cfg_proxyHost
$form.Controls.Add($textProxyHost)

$xPos += 213
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(10, 20)
$lbl.Text     = ":"
$form.Controls.Add($lbl)

$xPos += 10
$textProxyPort = New-Object System.Windows.Forms.TextBox
$textProxyPort.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textProxyPort.Size     = New-Object System.Drawing.Size(55, 25)
$textProxyPort.Text     = $cfg_proxyPort
$form.Controls.Add($textProxyPort)

$xPos += 65
$textProxyUser = New-Object System.Windows.Forms.TextBox
$textProxyUser.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textProxyUser.Size     = New-Object System.Drawing.Size(130, 25)
$textProxyUser.Text     = $cfg_proxyUser
$form.Controls.Add($textProxyUser)

$xPos += 140
$textProxyPass = New-Object System.Windows.Forms.TextBox
$textProxyPass.Location              = New-Object System.Drawing.Point($xPos, $yPos)
$textProxyPass.Size                  = New-Object System.Drawing.Size(144, 25)
$textProxyPass.Text                  = $cfg_proxyPass
$textProxyPass.UseSystemPasswordChar = $true
$form.Controls.Add($textProxyPass)

# ── 7. Cookies ────────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(110, 20)
$lbl.Text     = "Cookies:"
$form.Controls.Add($lbl)

$xPos += 110
$comboCookies = New-Object System.Windows.Forms.ComboBox
$comboCookies.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboCookies.Size          = New-Object System.Drawing.Size(150, 25)
$comboCookies.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboCookies.Items.AddRange(@("Без cookies", "Из браузера", "Из файла"))
$cookieIdx = switch ($cfg_cookieMethod) { "browser" { 1 } "file" { 2 } default { 0 } }
$comboCookies.SelectedIndex = $cookieIdx
$form.Controls.Add($comboCookies)

$xPos += 160
$comboCookieBrowser = New-Object System.Windows.Forms.ComboBox
$comboCookieBrowser.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboCookieBrowser.Size          = New-Object System.Drawing.Size(120, 25)
$comboCookieBrowser.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboCookieBrowser.Items.AddRange(@("chrome", "firefox", "edge"))
$browserIdx = switch ($cfg_cookieBrowser) { "firefox" { 1 } "edge" { 2 } default { 0 } }
$comboCookieBrowser.SelectedIndex = $browserIdx
$comboCookieBrowser.Visible       = ($comboCookies.SelectedIndex -eq 1)
$form.Controls.Add($comboCookieBrowser)

$textBoxCookieFile = New-Object System.Windows.Forms.TextBox
$textBoxCookieFile.Location = New-Object System.Drawing.Point($xPos, $yPos)
$textBoxCookieFile.Size     = New-Object System.Drawing.Size(400, 25)
$textBoxCookieFile.Text     = $cfg_cookieFile
$textBoxCookieFile.Visible  = ($comboCookies.SelectedIndex -eq 2)
$form.Controls.Add($textBoxCookieFile)

$xPosFileBrowse = $xPos + 410
$btnCookieBrowse = New-Object System.Windows.Forms.Button
$btnCookieBrowse.Location = New-Object System.Drawing.Point($xPosFileBrowse, $yPos)
$btnCookieBrowse.Size     = New-Object System.Drawing.Size(90, 25)
$btnCookieBrowse.Text     = "Обзор..."
$btnCookieBrowse.Visible  = ($comboCookies.SelectedIndex -eq 2)
$btnCookieBrowse.Add_Click({
    $fd = New-Object System.Windows.Forms.OpenFileDialog
    $fd.Filter = "Cookies (*.txt)|*.txt|All (*.*)|*.*"
    if ($fd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textBoxCookieFile.Text = $fd.FileName
    }
})
$form.Controls.Add($btnCookieBrowse)

$comboCookies.Add_SelectedIndexChanged({
    $comboCookieBrowser.Visible = ($comboCookies.SelectedIndex -eq 1)
    $textBoxCookieFile.Visible  = ($comboCookies.SelectedIndex -eq 2)
    $btnCookieBrowse.Visible    = ($comboCookies.SelectedIndex -eq 2)
})

# ── 8. AI-перевод ─────────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$chkTranslate = New-Object System.Windows.Forms.CheckBox
$chkTranslate.Location = New-Object System.Drawing.Point($xPos, $yPos)
$chkTranslate.Size     = New-Object System.Drawing.Size(150, 20)
$chkTranslate.Text     = "AI-перевод аудио"
$chkTranslate.Checked  = ($cfg_transEnabled -eq "true")
$form.Controls.Add($chkTranslate)

$xPos += 170
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(50, 20)
$lbl.Text     = "Язык:"
$form.Controls.Add($lbl)

$xPos += 50
$comboTransLang = New-Object System.Windows.Forms.ComboBox
$comboTransLang.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboTransLang.Size          = New-Object System.Drawing.Size(60, 25)
$comboTransLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransLang.Items.AddRange(@("ru", "en", "kk"))
$langIdx = switch ($cfg_transLang) { "en" { 1 } "kk" { 2 } default { 0 } }
$comboTransLang.SelectedIndex = $langIdx
$form.Controls.Add($comboTransLang)

$xPos += 80
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(55, 20)
$lbl.Text     = "Режим:"
$form.Controls.Add($lbl)

$xPos += 55
$comboTransMode = New-Object System.Windows.Forms.ComboBox
$comboTransMode.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboTransMode.Size          = New-Object System.Drawing.Size(130, 25)
$comboTransMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransMode.Items.AddRange(@("2 дорожки", "Смешать", "Заменить"))
$modeIdx = switch ($cfg_transMode) { "mix" { 1 } "replace" { 2 } default { 0 } }
$comboTransMode.SelectedIndex = $modeIdx
$form.Controls.Add($comboTransMode)

$xPos += 150
$lbl = New-Object System.Windows.Forms.Label
$lbl.Location = New-Object System.Drawing.Point($xPos, $yPos)
$lbl.Size     = New-Object System.Drawing.Size(55, 20)
$lbl.Text     = "Голос:"
$form.Controls.Add($lbl)

$xPos += 55
$comboTransVoice = New-Object System.Windows.Forms.ComboBox
$comboTransVoice.Location      = New-Object System.Drawing.Point($xPos, $yPos)
$comboTransVoice.Size          = New-Object System.Drawing.Size(90, 25)
$comboTransVoice.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboTransVoice.Items.AddRange(@("live", "tts"))
$voiceIdx = if ($cfg_transVoice -eq "tts") { 1 } else { 0 }
$comboTransVoice.SelectedIndex = $voiceIdx
$form.Controls.Add($comboTransVoice)

# ── 9. Прогресс-бар ───────────────────────────────────────────────────────
$yPos += 30; $xPos = $xPos0
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point($xPos, $yPos)
$progressBar.Size     = New-Object System.Drawing.Size(780, 20)
$progressBar.Minimum  = 0
$progressBar.Maximum  = 100
$progressBar.Value    = 0
$form.Controls.Add($progressBar)

# ── 10. RichTextBox вывода ────────────────────────────────────────────────
$yPos += 25; $xPos = $xPos0
$richOutput = New-Object System.Windows.Forms.RichTextBox
$richOutput.Location  = New-Object System.Drawing.Point($xPos, $yPos)
$richOutput.Size      = New-Object System.Drawing.Size(780, 220)
$richOutput.ReadOnly  = $true
$richOutput.Font      = New-Object System.Drawing.Font("Consolas", 9)
$richOutput.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$richOutput.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($richOutput)

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
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location  = New-Object System.Drawing.Point($xPos, $yPos)
$lblStatus.Size      = New-Object System.Drawing.Size(780, 20)
$lblStatus.Text      = "Готов к загрузке"
$lblStatus.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblStatus)

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

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Location  = New-Object System.Drawing.Point($xPos, $yPos)
$btnStart.Size      = New-Object System.Drawing.Size(185, 35)
$btnStart.Text      = "Начать загрузку"
$btnStart.BackColor = [System.Drawing.Color]::LightGreen
$btnStart.Font      = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
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
            "140+137/136/135/134", "140+138/137/136/135/134", "140+139/138/137/136/135/134"
        )
        "avc1_m3u8" = @(
            "234", "234+230", "234+231/230", "234+232/231/230",
            "234+233/232/231/230", "234+234/233/232/231/230", "234+235/234/233/232/231/230"
        )
        "avc1_https_60fps" = @(
            "234", "234+296", "234+297/296", "234+298/297/296",
            "234+299/298/297/296", "234+300/299/298/297/296", "234+301/300/299/298/297/296"
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
            "140", "18", "20/18", "22/20/18",
            "24/22/20/18", "26/24/22/20/18", "28/26/24/22/20/18"
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
            $form.Text         = "Video Downloader (yt-dlp) v11  [$itemNum/$totalItems]"
            Append-Output ""
            Append-Output "═══ [$itemNum/$totalItems] [$platform]  $currentUrl" ([System.Drawing.Color]::Cyan)

            $folder = $textBoxFolder.Text
            if (-not (Test-Path $folder)) {
                New-Item -ItemType Directory -Path $folder -Force | Out-Null
            }

            $command = @("-c", "-i", "-w", "--no-check-certificate", "--windows-filenames", "--compat-options", "filename-sanitization")
            $denoExe = Join-Path $scriptDir "deno.exe"
            if (Test-Path $denoExe) { $command += "--js-runtimes", "deno:$denoExe" }
            $command += "-o", "`"$folder\%(uploader)s\%(title)s.%(ext)s`""

            # Прокси
            if (-not [string]::IsNullOrWhiteSpace($textProxyHost.Text)) {
                $pType = $comboProxyType.SelectedItem
                $pHost = $textProxyHost.Text
                $pPort = $textProxyPort.Text
                $pUser = $textProxyUser.Text
                $pPass = $textProxyPass.Text
                $proxyVal = if (-not [string]::IsNullOrWhiteSpace($pUser) -and -not [string]::IsNullOrWhiteSpace($pPass)) {
                    "${pType}://${pUser}:${pPass}@${pHost}"
                } else {
                    "${pType}://${pHost}"
                }
                if (-not [string]::IsNullOrWhiteSpace($pPort)) { $proxyVal += ":${pPort}" }
                $command += "--proxy", "`"$proxyVal`""
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
            switch ($qi) {
                { $_ -ge 0 -and $_ -le 6 } {
                    $command += "-f", $formatPresets[$selectedFmt][$qi]
                }
                7 { $command += "--sub-lang", "ru", "--write-auto-sub", "--sub-format", "vtt", "--skip-download" }
                8 { $command += "--sub-lang", "en", "--write-auto-sub", "--sub-format", "vtt", "--skip-download" }
            }

            # Плейлист
            if ($currentUrl -match "playlist") {
                if (-not [string]::IsNullOrWhiteSpace($textBoxStart.Text)) {
                    $command += "--playlist-start", $textBoxStart.Text
                }
                if (-not [string]::IsNullOrWhiteSpace($textBoxEnd.Text)) {
                    $command += "--playlist-end", $textBoxEnd.Text
                }
            }

            $command += $currentUrl

            Append-Output "Команда: $dlp $($command -join ' ')" ([System.Drawing.Color]::DimGray)

            # Запуск процесса
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName               = $dlp
            $psi.Arguments              = $command -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true
            $psi.WorkingDirectory       = $PWD.Path

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
                        $form.Text         = "Video Downloader (yt-dlp) v11  [$itemNum/$totalItems]  $pct%"
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

                        $env:NODE_TLS_REJECT_UNAUTHORIZED = "0"
                        $votCmd = "& `"$votBin`" --output=`"$tempDir`" --voice-style=$transVoice --reslang=$transLang `"$currentUrl`""
                        Invoke-Expression $votCmd 2>&1 | Out-Null
                        $env:NODE_TLS_REJECT_UNAUTHORIZED = "1"

                        $transFile = Get-ChildItem -Path $tempDir -Filter "*.mp3" -File | Select-Object -First 1

                        if ($transFile) {
                            $latestVideo = Get-ChildItem -Path $folder -Filter "*.mp4" -Recurse -File |
                                Sort-Object LastWriteTime -Descending | Select-Object -First 1
                            if ($latestVideo) {
                                $outputFile = $latestVideo.FullName -replace '\.mp4$', '_translated.mp4'
                                Append-Output "Мерж аудиодорожек ($transMode)..." ([System.Drawing.Color]::Cyan)
                                $ffmpegCmd = switch ($transMode) {
                                    "dual_track" { "ffmpeg -y -i `"$($latestVideo.FullName)`" -i `"$($transFile.FullName)`" -map 0:v -map 0:a -map 1:a -c:v copy -c:a:0 copy -c:a:1 aac -b:a:1 192k -metadata:s:a:0 language=eng -metadata:s:a:0 title=`"Original`" -metadata:s:a:1 language=$transLang -metadata:s:a:1 title=`"AI Translation`" -disposition:a:0 default `"$outputFile`"" }
                                    "replace"    { "ffmpeg -y -i `"$($latestVideo.FullName)`" -i `"$($transFile.FullName)`" -map 0:v -map 1:a -c:v copy -c:a aac -b:a 192k `"$outputFile`"" }
                                    "mix"        { "ffmpeg -y -i `"$($latestVideo.FullName)`" -i `"$($transFile.FullName)`" -filter_complex `"[0:a]volume=0.3[a0];[1:a]volume=1.0[a1];[a0][a1]amix=inputs=2:duration=longest[aout]`" -map 0:v -map `"[aout]`" -c:v copy -c:a aac -b:a 192k `"$outputFile`"" }
                                }
                                Invoke-Expression $ffmpegCmd 2>&1 | Out-Null
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
            $form.Text      = "Video Downloader (yt-dlp) v11 — Готово!"
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
$form.Controls.Add($btnStart)

$xPos += 195
$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnStop.Size     = New-Object System.Drawing.Size(185, 35)
$btnStop.Text     = "Остановить"
$btnStop.Enabled  = $false
$btnStop.Add_Click({ Stop-Download })
$form.Controls.Add($btnStop)

$xPos += 195
$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnClear.Size     = New-Object System.Drawing.Size(185, 35)
$btnClear.Text     = "Очистить лог"
$btnClear.Add_Click({
    $richOutput.Clear()
    $progressBar.Value = 0
    $lblStatus.Text    = "Готов к загрузке"
    $form.Text         = "Video Downloader (yt-dlp) v11"
})
$form.Controls.Add($btnClear)

$xPos += 195
$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Location = New-Object System.Drawing.Point($xPos, $yPos)
$btnExit.Size     = New-Object System.Drawing.Size(185, 35)
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
$form.Controls.Add($btnExit)

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

# ── Версия yt-dlp — после показа формы, чтобы не задерживать открытие ────
$form.Add_Shown({
    try {
        $ver = (& $dlp --version 2>&1).ToString().Trim()
        $script:currentVersion = $ver
        $lblVersion.Text = "yt-dlp: $ver"
    } catch {
        $lblVersion.Text = "yt-dlp: н/д"
    }
})

[void]$form.ShowDialog()
