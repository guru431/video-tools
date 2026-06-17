Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Включаем только TLS 1.2 (PS 5.1 default = SSL3/TLS1.0). Проверку сертификата
# НЕ отключаем: gyan.dev имеет валидный cert, глобальный bypass отравит весь процесс.
$script:_sslReady = $false
function Ensure-SslBypass {
    if ($script:_sslReady) { return }
    [System.Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:_sslReady = $true
}

# Реальный probe доступности GPU-энкодера (а не просто наличие в списке): пробуем
# короткий тестовый encode 64×64. Ловит случай ВМ без GPU, отсутствия драйвера и др.
function Test-GpuEncoder {
    param([string]$Bin, [string]$Encoder)
    try {
        & $Bin -hide_banner -loglevel error `
            -f lavfi -i "color=size=64x64:duration=0.1:rate=1" `
            -c:v $Encoder -f null - 2>&1 | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# --- Фallback для $PSScriptRoot при запуске из ps2exe-экзешника ---
$script:_appDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:_appDir)) {
    $script:_appDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# --- Чтение config.ini (один раз в хеш-таблицу) ---
$configFile = Join-Path $script:_appDir "config.ini"
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
            $script:_configCache["${curSection}::$($Matches[1].Trim())"] = $val.Trim()
        }
    }
}
function Read-Config {
    param([string]$Key, [string]$Section, [string]$Default = "")
    $k = "${Section}::${Key}"
    if ($script:_configCache.ContainsKey($k)) { return $script:_configCache[$k] }
    return $Default
}
# Парсинг флага +val/-val: возвращает @{enabled=$true/$false; value="val"}
function Parse-Flag {
    param([string]$Raw)
    if (-not $Raw) { return @{ enabled = $false; value = "" } }
    $first = $Raw[0]
    $rest = $Raw.Substring(1)
    switch ($first) {
        '+' { return @{ enabled = $true;  value = $rest } }
        '-' { return @{ enabled = $false; value = $rest } }
        default { return @{ enabled = $true; value = $Raw } }
    }
}

# Загрузка дефолтов из config.ini
$_cfg_source      = Read-Config "source"      "folders" "_video_\0"
$_cfg_destination = Read-Config "destination"  "folders" "_video_\1"
if (-not [System.IO.Path]::IsPathRooted($_cfg_source))     { $_cfg_source     = Join-Path $script:_appDir $_cfg_source }
if (-not [System.IO.Path]::IsPathRooted($_cfg_destination)) { $_cfg_destination = Join-Path $script:_appDir $_cfg_destination }

$_cfg_audio_only         = Read-Config "audio_only"         "options" "no"
$_cfg_merge_files        = Read-Config "merge_files"        "options" "no"
$_cfg_create_frame       = Read-Config "create_frame"       "options" "no"
$_cfg_copy_codecs        = Read-Config "copy_codecs"        "options" "no"
$_cfg_extract_audio_copy = Read-Config "extract_audio_copy" "options" "no"

$_cfg_audio_codec    = Parse-Flag (Read-Config "codec"         "audio" "+aac")
$_cfg_audio_channels = Parse-Flag (Read-Config "channels"      "audio" "+2")
$_cfg_audio_bitrate  = Parse-Flag (Read-Config "bitrate"       "audio" "+128")
$_cfg_audio_sample   = Parse-Flag (Read-Config "sampling_rate" "audio" "+48000")
$_cfg_audio_norm     = Parse-Flag (Read-Config "normalize"     "audio" "-loudnorm")

$_cfg_video_codec      = Parse-Flag (Read-Config "codec"            "video" "+libx264")
$_cfg_video_resolution = Parse-Flag (Read-Config "resolution"       "video" "+1280x720")
$_cfg_video_bitrate    = Parse-Flag (Read-Config "bitrate"          "video" "-3000")
$_cfg_video_framerate  = Parse-Flag (Read-Config "framerate"        "video" "+30")
$_cfg_video_rotation   = Parse-Flag (Read-Config "rotation"         "video" "-2")
$_cfg_video_subtitles  = Parse-Flag (Read-Config "subtitles"        "video" "-burn")
$_cfg_video_quality    = Parse-Flag (Read-Config "quality"          "video" "-23")
$_cfg_keep_aspect      = Parse-Flag (Read-Config "keep_aspect_ratio" "video" "+yes")
$_cfg_container        = Parse-Flag (Read-Config "container"        "video" "+mp4")

$_cfg_threads  = Parse-Flag (Read-Config "threads"        "performance" "+4")
$_cfg_hw_accel  = Parse-Flag (Read-Config "hw_accel"       "gpu"         "-intel")
$_cfg_gpu_preset = Parse-Flag (Read-Config "preset"        "gpu"         "-p5")
$_cfg_gpu_tune   = Parse-Flag (Read-Config "tune"          "gpu"         "-hq")
$_cfg_gpu_rc     = Parse-Flag (Read-Config "rc"            "gpu"         "-vbr")
$_cfg_speed    = Parse-Flag (Read-Config "playback_speed" "speed"       "-1.0")

$_cfg_start    = Parse-Flag (Read-Config "start"  "split" "-01-00-00")
$_cfg_length   = Parse-Flag (Read-Config "length" "split" "-00-05-00")
$_cfg_split_silence    = Read-Config "split_by_silence"  "split" "no"
$_cfg_silence_duration = Read-Config "silence_duration"  "split" "2.0"
$_cfg_silence_thresh   = Read-Config "silence_threshold" "split" "-30dB"

$_cfg_save_ext     = Read-Config "save_old_extension" "other" "no"
$_cfg_formats      = Read-Config "format_files_in"    "other" "3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
$_cfg_sub_style    = Read-Config "subtitles_style"    "other" "FontName=Arial:FontSize=24:PrimaryColour=&HFFFFFF&"
$_cfg_dry_run      = Read-Config "dry_run"            "other" "no"
$_cfg_log          = Read-Config "enable_log"         "other" "no"
$_cfg_log_file     = Read-Config "log_file"           "other" "ffmpeg_convert.log"

# Main Form
$form = [System.Windows.Forms.Form]::new()
$form.Text = "Video Converter (ffmpeg) v15"
$form.Size = [System.Drawing.Size]::new(820, 850)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
# DoubleBuffered (protected) — убирает мерцание при перерисовке / разблокировке
$form.GetType().GetProperty('DoubleBuffered',
    [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($form, $true, $null)
$form.SuspendLayout()
$_fc = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()
$_mc = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# Main container
$mainContainer = [System.Windows.Forms.Panel]::new()
$mainContainer.Location = [System.Drawing.Point]::new(10, 36)
$mainContainer.Size = [System.Drawing.Size]::new(790, 780)
$mainContainer.AutoScroll = $true
$mainContainer.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
$_fc.Add($mainContainer)

# ========== Version strip (directly on form, above mainContainer) ==========
$lblFfmpegVersion = [System.Windows.Forms.Label]::new()
$lblFfmpegVersion.Location  = [System.Drawing.Point]::new(10, 13)
$lblFfmpegVersion.Size      = [System.Drawing.Size]::new(400, 18)
$lblFfmpegVersion.Text      = "ffmpeg: определяется..."
$lblFfmpegVersion.ForeColor = [System.Drawing.Color]::DimGray
$lblFfmpegVersion.Font      = [System.Drawing.Font]::new("Segoe UI", 9)
$_fc.Add($lblFfmpegVersion)

$script:ffmpegUpdateUrl      = ""
$script:ffmpegCurrentVersion = ""
$lnkFfmpegUpdate = [System.Windows.Forms.LinkLabel]::new()
$lnkFfmpegUpdate.Location  = [System.Drawing.Point]::new(415, 13)
$lnkFfmpegUpdate.Size      = [System.Drawing.Size]::new(130, 18)
$lnkFfmpegUpdate.Text      = ""
$lnkFfmpegUpdate.Font      = [System.Drawing.Font]::new("Segoe UI", 9)
$lnkFfmpegUpdate.Add_LinkClicked({
    if (-not [string]::IsNullOrEmpty($script:ffmpegUpdateUrl)) {
        Start-Process $script:ffmpegUpdateUrl
    }
})
$_fc.Add($lnkFfmpegUpdate)

$btnCheckFfmpeg = [System.Windows.Forms.Button]::new()
$btnCheckFfmpeg.Location = [System.Drawing.Point]::new(552, 10)
$btnCheckFfmpeg.Size     = [System.Drawing.Size]::new(240, 22)
$btnCheckFfmpeg.Text     = "Проверить обновления"
$btnCheckFfmpeg.Font     = [System.Drawing.Font]::new("Segoe UI", 8)
$btnCheckFfmpeg.Add_Click({
    $btnCheckFfmpeg.Enabled = $false
    $btnCheckFfmpeg.Text    = "Запрос..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        Ensure-SslBypass
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", "ffmpeg-gui/1.0")
        $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $wc.UseDefaultCredentials = $true
        $latestVer = $wc.DownloadString("https://www.gyan.dev/ffmpeg/builds/release-version").Trim()
        $dlUrl     = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip"
        $script:ffmpegUpdateUrl = $dlUrl

        $currentShort = if ($script:ffmpegCurrentVersion) { ($script:ffmpegCurrentVersion -split '-')[0] } else { "" }
        if ($currentShort -and $currentShort -eq $latestVer) {
            $lnkFfmpegUpdate.Links.Clear()
            $lnkFfmpegUpdate.Text      = "актуально ($latestVer)"
            $lnkFfmpegUpdate.ForeColor = [System.Drawing.Color]::Gray
            $script:ffmpegUpdateUrl    = ""
        } else {
            $linkText = "Скачать $latestVer"
            $lnkFfmpegUpdate.Text = $linkText
            $lnkFfmpegUpdate.Links.Clear()
            $lnkFfmpegUpdate.Links.Add(0, $linkText.Length) | Out-Null
            $lnkFfmpegUpdate.ForeColor = [System.Drawing.Color]::RoyalBlue
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        $lnkFfmpegUpdate.Links.Clear()
        $lnkFfmpegUpdate.Text      = "ошибка запроса"
        $lnkFfmpegUpdate.ForeColor = [System.Drawing.Color]::Firebrick
        $script:ffmpegUpdateUrl    = ""
        [System.Windows.Forms.MessageBox]::Show($errMsg, "Ошибка проверки обновлений", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    finally {
        $btnCheckFfmpeg.Enabled = $true
        $btnCheckFfmpeg.Text    = "Проверить обновления"
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
$_fc.Add($btnCheckFfmpeg)

$xPos0 = 10

# ========== Input Folder ==========
$yPos = 8
$labelInputFolder = [System.Windows.Forms.Label]::new()
$labelInputFolder.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$labelInputFolder.Size = [System.Drawing.Size]::new(600, 15)
$labelInputFolder.Text = "Выберите папку с файлами для перекодирования:"
$_mc.Add($labelInputFolder)

$yPos += 18
$textInputFolder = [System.Windows.Forms.TextBox]::new()
$textInputFolder.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$textInputFolder.Size = [System.Drawing.Size]::new(690, 22)
$textInputFolder.Text = $_cfg_source
$_mc.Add($textInputFolder)

$buttonInputBrowse = [System.Windows.Forms.Button]::new()
$buttonInputBrowse.Location = [System.Drawing.Point]::new(705, $yPos)
$buttonInputBrowse.Size = [System.Drawing.Size]::new(75, 23)
$buttonInputBrowse.Text = "Обзор"
$buttonInputBrowse.Add_Click({
    $folderBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderBrowser.Description = "Select source folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textInputFolder.Text = $folderBrowser.SelectedPath
    }
})
$_mc.Add($buttonInputBrowse)

# ========== Output Folder ==========
$yPos += 30
$labelOutputFolder = [System.Windows.Forms.Label]::new()
$labelOutputFolder.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$labelOutputFolder.Size = [System.Drawing.Size]::new(600, 15)
$labelOutputFolder.Text = "Выберите папку для сохранения готовых файлов:"
$_mc.Add($labelOutputFolder)

$yPos += 18
$textOutputFolder = [System.Windows.Forms.TextBox]::new()
$textOutputFolder.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$textOutputFolder.Size = [System.Drawing.Size]::new(690, 22)
$textOutputFolder.Text = $_cfg_destination
$_mc.Add($textOutputFolder)

$buttonOutputBrowse = [System.Windows.Forms.Button]::new()
$buttonOutputBrowse.Location = [System.Drawing.Point]::new(705, $yPos)
$buttonOutputBrowse.Size = [System.Drawing.Size]::new(75, 23)
$buttonOutputBrowse.Text = "Обзор"
$buttonOutputBrowse.Add_Click({
    $folderBrowser = [System.Windows.Forms.FolderBrowserDialog]::new()
    $folderBrowser.Description = "Select destination folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textOutputFolder.Text = $folderBrowser.SelectedPath
    }
})
$_mc.Add($buttonOutputBrowse)

# ========== Options Section ==========
$yPos += 32
$groupOptions = [System.Windows.Forms.GroupBox]::new()
$groupOptions.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupOptions.Size = [System.Drawing.Size]::new(770, 128)
$groupOptions.Text = "Опции"
$_go = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# Row 1: SaveAudio | MergeFiles | CreateFrames
$checkSaveAudio = [System.Windows.Forms.CheckBox]::new()
$checkSaveAudio.Location = [System.Drawing.Point]::new(8, 18)
$checkSaveAudio.Size = [System.Drawing.Size]::new(185, 20)
$checkSaveAudio.Text = "Сохранить только аудио"
$checkSaveAudio.Checked = ($_cfg_audio_only -eq "yes")
$_go.Add($checkSaveAudio)

$checkMergeFiles = [System.Windows.Forms.CheckBox]::new()
$checkMergeFiles.Location = [System.Drawing.Point]::new(208, 18)
$checkMergeFiles.Size = [System.Drawing.Size]::new(160, 20)
$checkMergeFiles.Text = "Объединить файлы"
$checkMergeFiles.Checked = ($_cfg_merge_files -eq "yes")
$_go.Add($checkMergeFiles)

$checkCreateFrames = [System.Windows.Forms.CheckBox]::new()
$checkCreateFrames.Location = [System.Drawing.Point]::new(388, 18)
$checkCreateFrames.Size = [System.Drawing.Size]::new(185, 20)
$checkCreateFrames.Text = "Разбить видео на кадры"
$checkCreateFrames.Checked = ($_cfg_create_frame -eq "yes")
$_go.Add($checkCreateFrames)

# Row 2: CopyCodecs | Multithreads + textThreads
$checkCopyCodecs = [System.Windows.Forms.CheckBox]::new()
$checkCopyCodecs.Location = [System.Drawing.Point]::new(8, 40)
$checkCopyCodecs.Size = [System.Drawing.Size]::new(185, 20)
$checkCopyCodecs.Text = "Без перекодирования"
$checkCopyCodecs.Checked = ($_cfg_copy_codecs -eq "yes")
$_go.Add($checkCopyCodecs)

$checkMultithreads = [System.Windows.Forms.CheckBox]::new()
$checkMultithreads.Location = [System.Drawing.Point]::new(208, 40)
$checkMultithreads.Size = [System.Drawing.Size]::new(120, 20)
$checkMultithreads.Text = "Потоки ffmpeg:"
$checkMultithreads.Checked = $_cfg_threads.enabled
$_go.Add($checkMultithreads)

$textThreads = [System.Windows.Forms.TextBox]::new()
$textThreads.Location = [System.Drawing.Point]::new(333, 40)
$textThreads.Size = [System.Drawing.Size]::new(35, 20)
$textThreads.Text = $_cfg_threads.value
$_go.Add($textThreads)

# Row 2 продолжение: ExtractAudioCopy (справа от Multithreads)
$checkExtractAudioCopy = [System.Windows.Forms.CheckBox]::new()
$checkExtractAudioCopy.Location = [System.Drawing.Point]::new(388, 40)
$checkExtractAudioCopy.Size = [System.Drawing.Size]::new(270, 20)
$checkExtractAudioCopy.Text = "Извлечь аудио (без перекодирования)"
$checkExtractAudioCopy.Checked = ($_cfg_extract_audio_copy -eq "yes")
$_go.Add($checkExtractAudioCopy)

# Row 3: DryRun | Log | KeepAspect
$checkDryRun = [System.Windows.Forms.CheckBox]::new()
$checkDryRun.Location = [System.Drawing.Point]::new(8, 62)
$checkDryRun.Size = [System.Drawing.Size]::new(165, 20)
$checkDryRun.Text = "Предпросмотр команд"
$checkDryRun.Checked = ($_cfg_dry_run -eq "yes")
$_go.Add($checkDryRun)

$checkLog = [System.Windows.Forms.CheckBox]::new()
$checkLog.Location = [System.Drawing.Point]::new(208, 62)
$checkLog.Size = [System.Drawing.Size]::new(120, 20)
$checkLog.Text = "Логирование"
$checkLog.Checked = ($_cfg_log -eq "yes")
$_go.Add($checkLog)

$checkKeepAspect = [System.Windows.Forms.CheckBox]::new()
$checkKeepAspect.Location = [System.Drawing.Point]::new(388, 62)
$checkKeepAspect.Size = [System.Drawing.Size]::new(175, 20)
$checkKeepAspect.Text = "Сохранять пропорции"
$checkKeepAspect.Checked = ($_cfg_keep_aspect.enabled -and $_cfg_keep_aspect.value -eq "yes")
$_go.Add($checkKeepAspect)

# Row 4: GPU Acceleration
$labelHWAccelOpt = [System.Windows.Forms.Label]::new()
$labelHWAccelOpt.Location = [System.Drawing.Point]::new(8, 86)
$labelHWAccelOpt.Size = [System.Drawing.Size]::new(90, 16)
$labelHWAccelOpt.Text = "GPU ускорение:"
$_go.Add($labelHWAccelOpt)

$comboHWAccel = [System.Windows.Forms.ComboBox]::new()
$comboHWAccel.Location = [System.Drawing.Point]::new(100, 84)
$comboHWAccel.Size = [System.Drawing.Size]::new(140, 21)
$comboHWAccel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboHWAccel.Items.AddRange(@("Без ускорения", "NVIDIA (NVENC)", "Intel (QSV)"))
$comboHWAccel.SelectedIndex = if ($_cfg_hw_accel.enabled) { switch ($_cfg_hw_accel.value) { "nvidia" { 1 } "intel" { 2 } default { 0 } } } else { 0 }
$_go.Add($comboHWAccel)

# GPU Preset (hidden by default)
$labelGpuPreset = [System.Windows.Forms.Label]::new()
$labelGpuPreset.Location = [System.Drawing.Point]::new(250, 86)
$labelGpuPreset.Size = [System.Drawing.Size]::new(48, 16)
$labelGpuPreset.Text = "Пресет:"
$labelGpuPreset.Visible = $false
$_go.Add($labelGpuPreset)

$comboGpuPreset = [System.Windows.Forms.ComboBox]::new()
$comboGpuPreset.Location = [System.Drawing.Point]::new(300, 84)
$comboGpuPreset.Size = [System.Drawing.Size]::new(90, 21)
$comboGpuPreset.Items.AddRange(@("p1", "p2", "p3", "p4", "p5", "p6", "p7"))
$comboGpuPreset.SelectedIndex = 4
$comboGpuPreset.Visible = $false
$_go.Add($comboGpuPreset)

# GPU Tune (NVIDIA only, hidden)
$labelGpuTune = [System.Windows.Forms.Label]::new()
$labelGpuTune.Location = [System.Drawing.Point]::new(397, 86)
$labelGpuTune.Size = [System.Drawing.Size]::new(40, 16)
$labelGpuTune.Text = "Tune:"
$labelGpuTune.Visible = $false
$_go.Add($labelGpuTune)

$comboGpuTune = [System.Windows.Forms.ComboBox]::new()
$comboGpuTune.Location = [System.Drawing.Point]::new(439, 84)
$comboGpuTune.Size = [System.Drawing.Size]::new(70, 21)
$comboGpuTune.Items.AddRange(@("hq", "ll", "ull", "lossless"))
$comboGpuTune.SelectedIndex = 0
$comboGpuTune.Visible = $false
$_go.Add($comboGpuTune)

# GPU RC (NVIDIA only, hidden)
$labelGpuRC = [System.Windows.Forms.Label]::new()
$labelGpuRC.Location = [System.Drawing.Point]::new(515, 86)
$labelGpuRC.Size = [System.Drawing.Size]::new(28, 16)
$labelGpuRC.Text = "RC:"
$labelGpuRC.Visible = $false
$_go.Add($labelGpuRC)

$comboGpuRC = [System.Windows.Forms.ComboBox]::new()
$comboGpuRC.Location = [System.Drawing.Point]::new(545, 84)
$comboGpuRC.Size = [System.Drawing.Size]::new(70, 21)
$comboGpuRC.Items.AddRange(@("vbr", "cbr", "constqp"))
$comboGpuRC.SelectedIndex = 0
$comboGpuRC.Visible = $false
$_go.Add($comboGpuRC)

# Row 6: HW info label
$labelHWInfo = [System.Windows.Forms.Label]::new()
$labelHWInfo.Location = [System.Drawing.Point]::new(8, 108)
$labelHWInfo.Size = [System.Drawing.Size]::new(750, 14)
$labelHWInfo.Text = ""
$labelHWInfo.Font = [System.Drawing.Font]::new($labelHWInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$_go.Add($labelHWInfo)

# Event: show/hide GPU controls based on selection
$comboHWAccel.Add_SelectedIndexChanged({
    $isNvidia = ($comboHWAccel.SelectedIndex -eq 1)
    $isIntel = ($comboHWAccel.SelectedIndex -eq 2)
    $isGpu = ($isNvidia -or $isIntel)
    $labelGpuPreset.Visible = $isGpu
    $comboGpuPreset.Visible = $isGpu
    $labelGpuTune.Visible = $isNvidia
    $comboGpuTune.Visible = $isNvidia
    $labelGpuRC.Visible = $isNvidia
    $comboGpuRC.Visible = $isNvidia
    if ($isNvidia) {
        $comboGpuPreset.Items.Clear()
        $comboGpuPreset.Items.AddRange(@("p1", "p2", "p3", "p4", "p5", "p6", "p7"))
        $comboGpuPreset.SelectedIndex = 4
        $labelHWInfo.Text = "Кодеки автоматически заменяются: libx264->h264_nvenc, libx265->hevc_nvenc, libsvtav1->av1_nvenc"
    } elseif ($isIntel) {
        $comboGpuPreset.Items.Clear()
        $comboGpuPreset.Items.AddRange(@("veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"))
        $comboGpuPreset.SelectedIndex = 3
        $labelHWInfo.Text = "Кодеки автоматически заменяются: libx264->h264_qsv, libx265->hevc_qsv, libsvtav1->av1_qsv"
    } else {
        $labelHWInfo.Text = ""
    }
})

# Инициализация пресетов GPU по выбранному ускорителю (SelectedIndexChanged не срабатывает при начальной установке)
if ($comboHWAccel.SelectedIndex -eq 2) {
    $comboGpuPreset.Items.Clear()
    $comboGpuPreset.Items.AddRange(@("veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"))
    $idx = $comboGpuPreset.Items.IndexOf($_cfg_gpu_preset.value)
    $comboGpuPreset.SelectedIndex = if ($idx -ge 0) { $idx } else { 3 }
    $comboGpuPreset.Visible = $true
    $labelGpuPreset.Visible = $true
} elseif ($comboHWAccel.SelectedIndex -eq 1) {
    $idx = $comboGpuPreset.Items.IndexOf($_cfg_gpu_preset.value)
    if ($idx -ge 0) { $comboGpuPreset.SelectedIndex = $idx }
    $comboGpuPreset.Visible = $true
    $labelGpuPreset.Visible = $true
    $comboGpuTune.Visible = $true; $labelGpuTune.Visible = $true
    $comboGpuRC.Visible = $true; $labelGpuRC.Visible = $true
}
# Инициализация tune/rc из config
$idxTune = $comboGpuTune.Items.IndexOf($_cfg_gpu_tune.value)
if ($idxTune -ge 0) { $comboGpuTune.SelectedIndex = $idxTune }
$idxRC = $comboGpuRC.Items.IndexOf($_cfg_gpu_rc.value)
if ($idxRC -ge 0) { $comboGpuRC.SelectedIndex = $idxRC }

$groupOptions.Controls.AddRange($_go.ToArray())
# Жирный заголовок, дочерние контролы — обычный шрифт
$_regFont = $groupOptions.Font
$groupOptions.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $groupOptions.Controls) { $c.Font = $_regFont }
$_mc.Add($groupOptions)

# ========== Encoding Section ==========
$yPos = 240
$groupEncoding = [System.Windows.Forms.GroupBox]::new()
$groupEncoding.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupEncoding.Size = [System.Drawing.Size]::new(770, 130)
$groupEncoding.Text = "Настройки кодирования"
$_ge = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# --- Audio column (x=8) ---
$_ax = 8; $_achk = 105; $_ainp = 125; $_aw = 120

# Audio Codec
$labelAudioCodec = [System.Windows.Forms.Label]::new()
$labelAudioCodec.Location = [System.Drawing.Point]::new($_ax, 18)
$labelAudioCodec.Size = [System.Drawing.Size]::new(95, 16)
$labelAudioCodec.Text = "Аудио кодек:"
$_ge.Add($labelAudioCodec)

$checkAudioCodec = [System.Windows.Forms.CheckBox]::new()
$checkAudioCodec.Location = [System.Drawing.Point]::new($_achk, 18)
$checkAudioCodec.Size = [System.Drawing.Size]::new(18, 18)
$checkAudioCodec.Checked = $_cfg_audio_codec.enabled
$_ge.Add($checkAudioCodec)

$comboAudioCodec = [System.Windows.Forms.ComboBox]::new()
$comboAudioCodec.Location = [System.Drawing.Point]::new($_ainp, 18)
$comboAudioCodec.Size = [System.Drawing.Size]::new($_aw, 21)
$comboAudioCodec.Items.AddRange(@("aac", "libmp3lame"))
$_acIdx = $comboAudioCodec.Items.IndexOf($_cfg_audio_codec.value)
if ($_acIdx -ge 0) { $comboAudioCodec.SelectedIndex = $_acIdx } else { $comboAudioCodec.Text = $_cfg_audio_codec.value }
$_ge.Add($comboAudioCodec)

# Audio Channels
$labelAudioChannels = [System.Windows.Forms.Label]::new()
$labelAudioChannels.Location = [System.Drawing.Point]::new($_ax, 40)
$labelAudioChannels.Size = [System.Drawing.Size]::new(95, 16)
$labelAudioChannels.Text = "Каналы:"
$_ge.Add($labelAudioChannels)

$checkAudioChannels = [System.Windows.Forms.CheckBox]::new()
$checkAudioChannels.Location = [System.Drawing.Point]::new($_achk, 40)
$checkAudioChannels.Size = [System.Drawing.Size]::new(18, 18)
$checkAudioChannels.Checked = $_cfg_audio_channels.enabled
$_ge.Add($checkAudioChannels)

$comboAudioChannels = [System.Windows.Forms.ComboBox]::new()
$comboAudioChannels.Location = [System.Drawing.Point]::new($_ainp, 40)
$comboAudioChannels.Size = [System.Drawing.Size]::new($_aw, 21)
$comboAudioChannels.Items.AddRange(@("1 - Mono", "2 - Stereo"))
$comboAudioChannels.SelectedIndex = if ($_cfg_audio_channels.value -eq "1") { 0 } else { 1 }
$_ge.Add($comboAudioChannels)

# Audio Bitrate
$labelAudioBitrate = [System.Windows.Forms.Label]::new()
$labelAudioBitrate.Location = [System.Drawing.Point]::new($_ax, 62)
$labelAudioBitrate.Size = [System.Drawing.Size]::new(95, 16)
$labelAudioBitrate.Text = "Аудио битрейт:"
$_ge.Add($labelAudioBitrate)

$checkAudioBitrate = [System.Windows.Forms.CheckBox]::new()
$checkAudioBitrate.Location = [System.Drawing.Point]::new($_achk, 62)
$checkAudioBitrate.Size = [System.Drawing.Size]::new(18, 18)
$checkAudioBitrate.Checked = $_cfg_audio_bitrate.enabled
$_ge.Add($checkAudioBitrate)

$textAudioBitrate = [System.Windows.Forms.TextBox]::new()
$textAudioBitrate.Location = [System.Drawing.Point]::new($_ainp, 62)
$textAudioBitrate.Size = [System.Drawing.Size]::new($_aw, 20)
$textAudioBitrate.Text = $_cfg_audio_bitrate.value
$_ge.Add($textAudioBitrate)

# Audio Sampling Rate
$labelAudioSampleRate = [System.Windows.Forms.Label]::new()
$labelAudioSampleRate.Location = [System.Drawing.Point]::new($_ax, 84)
$labelAudioSampleRate.Size = [System.Drawing.Size]::new(95, 16)
$labelAudioSampleRate.Text = "Дискретизация:"
$_ge.Add($labelAudioSampleRate)

$checkAudioSampleRate = [System.Windows.Forms.CheckBox]::new()
$checkAudioSampleRate.Location = [System.Drawing.Point]::new($_achk, 84)
$checkAudioSampleRate.Size = [System.Drawing.Size]::new(18, 18)
$checkAudioSampleRate.Checked = $_cfg_audio_sample.enabled
$_ge.Add($checkAudioSampleRate)

$textAudioSampleRate = [System.Windows.Forms.TextBox]::new()
$textAudioSampleRate.Location = [System.Drawing.Point]::new($_ainp, 84)
$textAudioSampleRate.Size = [System.Drawing.Size]::new($_aw, 20)
$textAudioSampleRate.Text = $_cfg_audio_sample.value
$_ge.Add($textAudioSampleRate)

# Audio Normalize
$labelAudioNorm = [System.Windows.Forms.Label]::new()
$labelAudioNorm.Location = [System.Drawing.Point]::new($_ax, 106)
$labelAudioNorm.Size = [System.Drawing.Size]::new(95, 16)
$labelAudioNorm.Text = "Нормализация:"
$_ge.Add($labelAudioNorm)

$checkAudioNorm = [System.Windows.Forms.CheckBox]::new()
$checkAudioNorm.Location = [System.Drawing.Point]::new($_achk, 106)
$checkAudioNorm.Size = [System.Drawing.Size]::new(18, 18)
$checkAudioNorm.Checked = $_cfg_audio_norm.enabled
$_ge.Add($checkAudioNorm)

$comboAudioNorm = [System.Windows.Forms.ComboBox]::new()
$comboAudioNorm.Location = [System.Drawing.Point]::new($_ainp, 106)
$comboAudioNorm.Size = [System.Drawing.Size]::new($_aw, 21)
$comboAudioNorm.Items.AddRange(@("loudnorm", "dynaudnorm"))
$_anIdx = $comboAudioNorm.Items.IndexOf($_cfg_audio_norm.value)
if ($_anIdx -ge 0) { $comboAudioNorm.SelectedIndex = $_anIdx } else { $comboAudioNorm.Text = $_cfg_audio_norm.value }
$_ge.Add($comboAudioNorm)

# --- Video column 1 (x=265) ---
$_vx = 265; $_vchk = 365; $_vinp = 385; $_vw = 120

# Video Codec
$labelVideoCodec = [System.Windows.Forms.Label]::new()
$labelVideoCodec.Location = [System.Drawing.Point]::new($_vx, 18)
$labelVideoCodec.Size = [System.Drawing.Size]::new(98, 16)
$labelVideoCodec.Text = "Видео кодек:"
$_ge.Add($labelVideoCodec)

$checkVideoCodec = [System.Windows.Forms.CheckBox]::new()
$checkVideoCodec.Location = [System.Drawing.Point]::new($_vchk, 18)
$checkVideoCodec.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoCodec.Checked = $_cfg_video_codec.enabled
$_ge.Add($checkVideoCodec)

$comboVideoCodec = [System.Windows.Forms.ComboBox]::new()
$comboVideoCodec.Location = [System.Drawing.Point]::new($_vinp, 18)
$comboVideoCodec.Size = [System.Drawing.Size]::new($_vw, 21)
$comboVideoCodec.Items.AddRange(@("libx264", "libx265", "libsvtav1", "h264_nvenc", "hevc_nvenc", "av1_nvenc", "h264_qsv"))
$_vcIdx = $comboVideoCodec.Items.IndexOf($_cfg_video_codec.value)
if ($_vcIdx -ge 0) { $comboVideoCodec.SelectedIndex = $_vcIdx } else { $comboVideoCodec.Text = $_cfg_video_codec.value }
$_ge.Add($comboVideoCodec)

# Video Resolution
$labelVideoResolution = [System.Windows.Forms.Label]::new()
$labelVideoResolution.Location = [System.Drawing.Point]::new($_vx, 40)
$labelVideoResolution.Size = [System.Drawing.Size]::new(98, 16)
$labelVideoResolution.Text = "Разрешение:"
$_ge.Add($labelVideoResolution)

$checkVideoResolution = [System.Windows.Forms.CheckBox]::new()
$checkVideoResolution.Location = [System.Drawing.Point]::new($_vchk, 40)
$checkVideoResolution.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoResolution.Checked = $_cfg_video_resolution.enabled
$_ge.Add($checkVideoResolution)

$comboVideoResolution = [System.Windows.Forms.ComboBox]::new()
$comboVideoResolution.Location = [System.Drawing.Point]::new($_vinp, 40)
$comboVideoResolution.Size = [System.Drawing.Size]::new($_vw, 21)
$comboVideoResolution.Items.AddRange(@("1920x1080", "1280x720", "854x480", "640x360", "1440x1080", "960x720", "640x480", "480x360"))
$_vrIdx = $comboVideoResolution.Items.IndexOf($_cfg_video_resolution.value)
if ($_vrIdx -ge 0) { $comboVideoResolution.SelectedIndex = $_vrIdx } else { $comboVideoResolution.Text = $_cfg_video_resolution.value }
$_ge.Add($comboVideoResolution)

# Video Bitrate
$labelVideoBitrate = [System.Windows.Forms.Label]::new()
$labelVideoBitrate.Location = [System.Drawing.Point]::new($_vx, 62)
$labelVideoBitrate.Size = [System.Drawing.Size]::new(98, 16)
$labelVideoBitrate.Text = "Видео битрейт:"
$_ge.Add($labelVideoBitrate)

$checkVideoBitrate = [System.Windows.Forms.CheckBox]::new()
$checkVideoBitrate.Location = [System.Drawing.Point]::new($_vchk, 62)
$checkVideoBitrate.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoBitrate.Checked = $_cfg_video_bitrate.enabled
$_ge.Add($checkVideoBitrate)

$textVideoBitrate = [System.Windows.Forms.TextBox]::new()
$textVideoBitrate.Location = [System.Drawing.Point]::new($_vinp, 62)
$textVideoBitrate.Size = [System.Drawing.Size]::new($_vw, 20)
$textVideoBitrate.Text = $_cfg_video_bitrate.value
$_ge.Add($textVideoBitrate)

# Frame Rate
$labelFrameRate = [System.Windows.Forms.Label]::new()
$labelFrameRate.Location = [System.Drawing.Point]::new($_vx, 84)
$labelFrameRate.Size = [System.Drawing.Size]::new(98, 16)
$labelFrameRate.Text = "Кадры/с:"
$_ge.Add($labelFrameRate)

$checkFrameRate = [System.Windows.Forms.CheckBox]::new()
$checkFrameRate.Location = [System.Drawing.Point]::new($_vchk, 84)
$checkFrameRate.Size = [System.Drawing.Size]::new(18, 18)
$checkFrameRate.Checked = $_cfg_video_framerate.enabled
$_ge.Add($checkFrameRate)

$textFrameRate = [System.Windows.Forms.TextBox]::new()
$textFrameRate.Location = [System.Drawing.Point]::new($_vinp, 84)
$textFrameRate.Size = [System.Drawing.Size]::new($_vw, 20)
$textFrameRate.Text = $_cfg_video_framerate.value
$_ge.Add($textFrameRate)

# Video Quality (CRF/CQ)
$labelVideoQuality = [System.Windows.Forms.Label]::new()
$labelVideoQuality.Location = [System.Drawing.Point]::new($_vx, 106)
$labelVideoQuality.Size = [System.Drawing.Size]::new(98, 16)
$labelVideoQuality.Text = "Качество (CRF):"
$_ge.Add($labelVideoQuality)

$checkVideoQuality = [System.Windows.Forms.CheckBox]::new()
$checkVideoQuality.Location = [System.Drawing.Point]::new($_vchk, 106)
$checkVideoQuality.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoQuality.Checked = $_cfg_video_quality.enabled
$_ge.Add($checkVideoQuality)

$textVideoQuality = [System.Windows.Forms.TextBox]::new()
$textVideoQuality.Location = [System.Drawing.Point]::new($_vinp, 106)
$textVideoQuality.Size = [System.Drawing.Size]::new($_vw, 20)
$textVideoQuality.Text = $_cfg_video_quality.value
$_ge.Add($textVideoQuality)

# --- Video column 2 (x=522) ---
$_v2x = 522; $_v2chk = 612; $_v2inp = 632; $_v2w = 130

# Video Rotation
$labelVideoRotation = [System.Windows.Forms.Label]::new()
$labelVideoRotation.Location = [System.Drawing.Point]::new($_v2x, 18)
$labelVideoRotation.Size = [System.Drawing.Size]::new(88, 16)
$labelVideoRotation.Text = "Поворот:"
$_ge.Add($labelVideoRotation)

$checkVideoRotation = [System.Windows.Forms.CheckBox]::new()
$checkVideoRotation.Location = [System.Drawing.Point]::new($_v2chk, 18)
$checkVideoRotation.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoRotation.Checked = $_cfg_video_rotation.enabled
$_ge.Add($checkVideoRotation)

$comboVideoRotation = [System.Windows.Forms.ComboBox]::new()
$comboVideoRotation.Location = [System.Drawing.Point]::new($_v2inp, 18)
$comboVideoRotation.Size = [System.Drawing.Size]::new($_v2w, 21)
$comboVideoRotation.Items.AddRange(@("1 - По часовой", "2 - Против часовой"))
$comboVideoRotation.SelectedIndex = if ($_cfg_video_rotation.value -eq "1") { 0 } else { 1 }
$_ge.Add($comboVideoRotation)

# Video Subtitles
$labelVideoSubtitles = [System.Windows.Forms.Label]::new()
$labelVideoSubtitles.Location = [System.Drawing.Point]::new($_v2x, 40)
$labelVideoSubtitles.Size = [System.Drawing.Size]::new(88, 16)
$labelVideoSubtitles.Text = "Субтитры:"
$_ge.Add($labelVideoSubtitles)

$checkVideoSubtitles = [System.Windows.Forms.CheckBox]::new()
$checkVideoSubtitles.Location = [System.Drawing.Point]::new($_v2chk, 40)
$checkVideoSubtitles.Size = [System.Drawing.Size]::new(18, 18)
$checkVideoSubtitles.Checked = $_cfg_video_subtitles.enabled
$_ge.Add($checkVideoSubtitles)

$comboSubtitlesMode = [System.Windows.Forms.ComboBox]::new()
$comboSubtitlesMode.Location = [System.Drawing.Point]::new($_v2inp, 40)
$comboSubtitlesMode.Size = [System.Drawing.Size]::new($_v2w, 21)
$comboSubtitlesMode.Items.AddRange(@("burn - На видео", "meta - Дорожкой"))
$comboSubtitlesMode.SelectedIndex = if ($_cfg_video_subtitles.value -eq "meta") { 1 } else { 0 }
$_ge.Add($comboSubtitlesMode)

# Output Container
$labelContainer = [System.Windows.Forms.Label]::new()
$labelContainer.Location = [System.Drawing.Point]::new($_v2x, 62)
$labelContainer.Size = [System.Drawing.Size]::new(88, 16)
$labelContainer.Text = "Контейнер:"
$_ge.Add($labelContainer)

$checkContainer = [System.Windows.Forms.CheckBox]::new()
$checkContainer.Location = [System.Drawing.Point]::new($_v2chk, 62)
$checkContainer.Size = [System.Drawing.Size]::new(18, 18)
$checkContainer.Checked = $_cfg_container.enabled
$_ge.Add($checkContainer)

$comboContainer = [System.Windows.Forms.ComboBox]::new()
$comboContainer.Location = [System.Drawing.Point]::new($_v2inp, 62)
$comboContainer.Size = [System.Drawing.Size]::new($_v2w, 21)
$comboContainer.Items.AddRange(@("mp4", "mkv", "webm", "avi", "ts"))
$_cntIdx = $comboContainer.Items.IndexOf($_cfg_container.value)
if ($_cntIdx -ge 0) { $comboContainer.SelectedIndex = $_cntIdx } else { $comboContainer.Text = $_cfg_container.value }
$_ge.Add($comboContainer)

$groupEncoding.Controls.AddRange($_ge.ToArray())
$_regFont = $groupEncoding.Font
$groupEncoding.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $groupEncoding.Controls) { $c.Font = $_regFont }
$_mc.Add($groupEncoding)

# ========== Взаимоисключающие опции ==========
# Цвет для заблокированных элементов
$script:_disabledColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$script:_enabledColor  = [System.Drawing.SystemColors]::WindowText

# Набор видео-контролов (label + checkbox + input)
$script:_videoControls = @(
    @($labelVideoCodec, $checkVideoCodec, $comboVideoCodec),
    @($labelVideoResolution, $checkVideoResolution, $comboVideoResolution),
    @($labelVideoBitrate, $checkVideoBitrate, $textVideoBitrate),
    @($labelFrameRate, $checkFrameRate, $textFrameRate),
    @($labelVideoQuality, $checkVideoQuality, $textVideoQuality),
    @($labelVideoRotation, $checkVideoRotation, $comboVideoRotation),
    @($labelVideoSubtitles, $checkVideoSubtitles, $comboSubtitlesMode),
    @($labelContainer, $checkContainer, $comboContainer)
)
$script:_audioControls = @(
    @($labelAudioCodec, $checkAudioCodec, $comboAudioCodec),
    @($labelAudioChannels, $checkAudioChannels, $comboAudioChannels),
    @($labelAudioBitrate, $checkAudioBitrate, $textAudioBitrate),
    @($labelAudioSampleRate, $checkAudioSampleRate, $textAudioSampleRate),
    @($labelAudioNorm, $checkAudioNorm, $comboAudioNorm)
)

function Set-ControlGroupEnabled {
    param([array]$Groups, [bool]$Enabled)
    foreach ($grp in $Groups) {
        $lbl = $grp[0]; $chk = $grp[1]; $inp = $grp[2]
        $chk.Enabled = $Enabled
        $inp.Enabled = $Enabled
        $lbl.ForeColor = if ($Enabled) { $script:_enabledColor } else { $script:_disabledColor }
    }
}

function Update-MutualExclusion {
    $isCopy    = $checkCopyCodecs.Checked
    $isAudioOnly = $checkSaveAudio.Checked
    $isExtract = $checkExtractAudioCopy.Checked

    # --- Режимы-переключатели (copy / audio_only / extract) ---
    # Без перекодирования → всё кодирование отключено
    if ($isCopy) {
        Set-ControlGroupEnabled $script:_videoControls $false
        Set-ControlGroupEnabled $script:_audioControls $false
        $checkSpeed.Enabled = $false
        $textSpeed.Enabled = $false
        $comboHWAccel.Enabled = $false
        $checkKeepAspect.Enabled = $false
        $groupEncoding.ForeColor = $script:_disabledColor
        $groupSpeed.ForeColor = $script:_disabledColor
        return
    }

    # Извлечь аудио (без перекодирования) → всё кодирование отключено
    if ($isExtract) {
        Set-ControlGroupEnabled $script:_videoControls $false
        Set-ControlGroupEnabled $script:_audioControls $false
        $checkSpeed.Enabled = $false
        $textSpeed.Enabled = $false
        $comboHWAccel.Enabled = $false
        $checkKeepAspect.Enabled = $false
        $groupEncoding.ForeColor = $script:_disabledColor
        $groupSpeed.ForeColor = $script:_disabledColor
        return
    }

    # Всё включено по умолчанию
    $groupEncoding.ForeColor = $script:_enabledColor
    $groupSpeed.ForeColor = $script:_enabledColor
    Set-ControlGroupEnabled $script:_audioControls $true
    $checkSpeed.Enabled = $true
    $textSpeed.Enabled = $true
    $comboHWAccel.Enabled = $true
    $checkKeepAspect.Enabled = $true

    # Сохранить только аудио → видео-контролы отключены
    if ($isAudioOnly) {
        Set-ControlGroupEnabled $script:_videoControls $false
    } else {
        Set-ControlGroupEnabled $script:_videoControls $true
        # CRF ↔ Видео битрейт: взаимоисключающие. При обоих включённых приоритет
        # quality — снимаем галку bitrate. Дизейблим только ПОЛЕ ВВОДА противоположной
        # опции, не сам чекбокс (иначе оба залипали бы отключёнными навсегда).
        if ($checkVideoQuality.Checked -and $checkVideoBitrate.Checked) {
            $checkVideoBitrate.Checked = $false
        }
        $textVideoBitrate.Enabled = -not $checkVideoQuality.Checked
        $labelVideoBitrate.ForeColor = if ($checkVideoQuality.Checked) { $script:_disabledColor } else { $script:_enabledColor }
        $textVideoQuality.Enabled = -not $checkVideoBitrate.Checked
        $labelVideoQuality.ForeColor = if ($checkVideoBitrate.Checked) { $script:_disabledColor } else { $script:_enabledColor }
    }
}

# Подписка на события: режимы-переключатели
$checkCopyCodecs.Add_CheckedChanged({
    if ($checkCopyCodecs.Checked) {
        $checkSaveAudio.Checked = $false
        $checkExtractAudioCopy.Checked = $false
    }
    Update-MutualExclusion
})
$checkSaveAudio.Add_CheckedChanged({
    if ($checkSaveAudio.Checked) {
        $checkCopyCodecs.Checked = $false
        $checkExtractAudioCopy.Checked = $false
    }
    Update-MutualExclusion
})
$checkExtractAudioCopy.Add_CheckedChanged({
    if ($checkExtractAudioCopy.Checked) {
        $checkCopyCodecs.Checked = $false
        $checkSaveAudio.Checked = $false
    }
    Update-MutualExclusion
})

# CRF ↔ Видео битрейт
$checkVideoQuality.Add_CheckedChanged({ Update-MutualExclusion })
$checkVideoBitrate.Add_CheckedChanged({ Update-MutualExclusion })

# ========== Playback Speed Section ==========
$yPos = 374
$groupSpeed = [System.Windows.Forms.GroupBox]::new()
$groupSpeed.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupSpeed.Size = [System.Drawing.Size]::new(770, 42)
$groupSpeed.Text = "Скорость воспроизведения"
$_gsp = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

$checkSpeed = [System.Windows.Forms.CheckBox]::new()
$checkSpeed.Location = [System.Drawing.Point]::new(8, 14)
$checkSpeed.Size = [System.Drawing.Size]::new(80, 18)
$checkSpeed.Text = "Скорость:"
$checkSpeed.Checked = $_cfg_speed.enabled
$_gsp.Add($checkSpeed)

$textSpeed = [System.Windows.Forms.TextBox]::new()
$textSpeed.Location = [System.Drawing.Point]::new(92, 14)
$textSpeed.Size = [System.Drawing.Size]::new(55, 20)
$textSpeed.Text = $_cfg_speed.value
$_gsp.Add($textSpeed)

$labelSpeedInfo = [System.Windows.Forms.Label]::new()
$labelSpeedInfo.Location = [System.Drawing.Point]::new(158, 16)
$labelSpeedInfo.Size = [System.Drawing.Size]::new(600, 16)
$labelSpeedInfo.Text = "1.0 = норм, 2.0 = ускорение x2, 0.5 = замедление x2 (диапазон: 0.25 - 4.0)"
$labelSpeedInfo.Font = [System.Drawing.Font]::new($labelSpeedInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$_gsp.Add($labelSpeedInfo)

$groupSpeed.Controls.AddRange($_gsp.ToArray())
$_regFont = $groupSpeed.Font
$groupSpeed.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $groupSpeed.Controls) { $c.Font = $_regFont }
$_mc.Add($groupSpeed)

# Начальная синхронизация взаимоисключающих опций (после создания всех контролов)
Update-MutualExclusion

# ========== Split Section ==========
$yPos = 420
$groupSplit = [System.Windows.Forms.GroupBox]::new()
$groupSplit.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupSplit.Size = [System.Drawing.Size]::new(770, 106)
$groupSplit.Text = "Настройки разреза файлов"
$_gspl = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# Start Time
$labelStartTime = [System.Windows.Forms.Label]::new()
$labelStartTime.Location = [System.Drawing.Point]::new(8, 18)
$labelStartTime.Size = [System.Drawing.Size]::new(130, 16)
$labelStartTime.Text = "Начало (чч-мм-сс):"
$_gspl.Add($labelStartTime)

$checkStartTime = [System.Windows.Forms.CheckBox]::new()
$checkStartTime.Location = [System.Drawing.Point]::new(140, 18)
$checkStartTime.Size = [System.Drawing.Size]::new(18, 18)
$checkStartTime.Checked = $_cfg_start.enabled
$_gspl.Add($checkStartTime)

$textStartTime = [System.Windows.Forms.TextBox]::new()
$textStartTime.Location = [System.Drawing.Point]::new(160, 18)
$textStartTime.Size = [System.Drawing.Size]::new(80, 20)
$textStartTime.Text = $_cfg_start.value
$_gspl.Add($textStartTime)

# Duration
$labelDuration = [System.Windows.Forms.Label]::new()
$labelDuration.Location = [System.Drawing.Point]::new(252, 18)
$labelDuration.Size = [System.Drawing.Size]::new(165, 16)
$labelDuration.Text = "Длительность (чч-мм-сс):"
$_gspl.Add($labelDuration)

$checkDuration = [System.Windows.Forms.CheckBox]::new()
$checkDuration.Location = [System.Drawing.Point]::new(420, 18)
$checkDuration.Size = [System.Drawing.Size]::new(18, 18)
$checkDuration.Checked = $_cfg_length.enabled
$_gspl.Add($checkDuration)

$textDuration = [System.Windows.Forms.TextBox]::new()
$textDuration.Location = [System.Drawing.Point]::new(440, 18)
$textDuration.Size = [System.Drawing.Size]::new(80, 20)
$textDuration.Text = $_cfg_length.value
$_gspl.Add($textDuration)

# Split by Silence
$checkSplitSilence = [System.Windows.Forms.CheckBox]::new()
$checkSplitSilence.Location = [System.Drawing.Point]::new(8, 42)
$checkSplitSilence.Size = [System.Drawing.Size]::new(145, 18)
$checkSplitSilence.Text = "Разрезать по тишине"
$checkSplitSilence.Checked = ($_cfg_split_silence -eq "yes")
$_gspl.Add($checkSplitSilence)

# Silence Duration
$labelSilenceDuration = [System.Windows.Forms.Label]::new()
$labelSilenceDuration.Location = [System.Drawing.Point]::new(160, 44)
$labelSilenceDuration.Size = [System.Drawing.Size]::new(115, 16)
$labelSilenceDuration.Text = "Мин. тишина (сек):"
$_gspl.Add($labelSilenceDuration)

$textSilenceDuration = [System.Windows.Forms.TextBox]::new()
$textSilenceDuration.Location = [System.Drawing.Point]::new(277, 42)
$textSilenceDuration.Size = [System.Drawing.Size]::new(45, 20)
$textSilenceDuration.Text = $_cfg_silence_duration
$_gspl.Add($textSilenceDuration)

# Silence Threshold
$labelSilenceThreshold = [System.Windows.Forms.Label]::new()
$labelSilenceThreshold.Location = [System.Drawing.Point]::new(330, 44)
$labelSilenceThreshold.Size = [System.Drawing.Size]::new(80, 16)
$labelSilenceThreshold.Text = "Порог тишины:"
$_gspl.Add($labelSilenceThreshold)

$textSilenceThreshold = [System.Windows.Forms.TextBox]::new()
$textSilenceThreshold.Location = [System.Drawing.Point]::new(413, 42)
$textSilenceThreshold.Size = [System.Drawing.Size]::new(55, 20)
$textSilenceThreshold.Text = $_cfg_silence_thresh
$_gspl.Add($textSilenceThreshold)

# Split info
$labelSplitInfo = [System.Windows.Forms.Label]::new()
$labelSplitInfo.Location = [System.Drawing.Point]::new(8, 66)
$labelSplitInfo.Size = [System.Drawing.Size]::new(750, 34)
$labelSplitInfo.Text = "Разрезать на части: включите длительность. Вырезать фрагмент: включите начало + длительность.`nОбрезать начало: включите только начало."
$labelSplitInfo.Font = [System.Drawing.Font]::new($labelSplitInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$_gspl.Add($labelSplitInfo)

$groupSplit.Controls.AddRange($_gspl.ToArray())
$_regFont = $groupSplit.Font
$groupSplit.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $groupSplit.Controls) { $c.Font = $_regFont }
$_mc.Add($groupSplit)

# ========== Other Settings (collapsible) ==========
$yPos = 530
$groupOther = [System.Windows.Forms.GroupBox]::new()
$groupOther.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupOther.Size = [System.Drawing.Size]::new(770, 18)
$groupOther.Text = "Дополнительные настройки (нажмите, чтобы развернуть)"
$groupOther.Add_Click({
    if ($groupOther.Height -eq 18) {
        $groupOther.Height = 96
    } else {
        $groupOther.Height = 18
    }
    $form.Refresh()
})
$_goth = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# ffmpeg path (авто: ./ffmpeg.exe рядом со скриптом, иначе из PATH)
$_localFfmpeg = Join-Path $script:_appDir "ffmpeg.exe"
$textFFmpegPath = [PSCustomObject]@{ Text = if (Test-Path $_localFfmpeg) { $_localFfmpeg } else { "ffmpeg" } }

# Save Old Extension
$checkSaveExtension = [System.Windows.Forms.CheckBox]::new()
$checkSaveExtension.Location = [System.Drawing.Point]::new(8, 18)
$checkSaveExtension.Size = [System.Drawing.Size]::new(400, 18)
$checkSaveExtension.Text = "Оставлять старое расширение файла в названии"
$checkSaveExtension.Checked = ($_cfg_save_ext -eq "yes")
$_goth.Add($checkSaveExtension)

# Input Formats
$labelInputFormats = [System.Windows.Forms.Label]::new()
$labelInputFormats.Location = [System.Drawing.Point]::new(8, 42)
$labelInputFormats.Size = [System.Drawing.Size]::new(100, 16)
$labelInputFormats.Text = "Формат файлов:"
$_goth.Add($labelInputFormats)

$textInputFormats = [System.Windows.Forms.TextBox]::new()
$textInputFormats.Location = [System.Drawing.Point]::new(110, 42)
$textInputFormats.Size = [System.Drawing.Size]::new(648, 20)
$textInputFormats.Text = $_cfg_formats
$_goth.Add($textInputFormats)

# Subtitles Style
$labelSubtitlesStyle = [System.Windows.Forms.Label]::new()
$labelSubtitlesStyle.Location = [System.Drawing.Point]::new(8, 66)
$labelSubtitlesStyle.Size = [System.Drawing.Size]::new(100, 16)
$labelSubtitlesStyle.Text = "Стиль субтитров:"
$_goth.Add($labelSubtitlesStyle)

$textSubtitlesStyle = [System.Windows.Forms.TextBox]::new()
$textSubtitlesStyle.Location = [System.Drawing.Point]::new(110, 66)
$textSubtitlesStyle.Size = [System.Drawing.Size]::new(648, 20)
$textSubtitlesStyle.Text = $_cfg_sub_style
$_goth.Add($textSubtitlesStyle)

$groupOther.Controls.AddRange($_goth.ToArray())
$_regFont = $groupOther.Font
$groupOther.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $groupOther.Controls) { $c.Font = $_regFont }
$_mc.Add($groupOther)

# ========== Buttons Row ==========
# Centered: Run(260) + gap(12) + Stop(170) = 442 total in 770px → left = (770-442)/2 = 164 → absolute x = xPos0+164 = 174
$yPos = 552

$buttonRun = [System.Windows.Forms.Button]::new()
$buttonRun.Location = [System.Drawing.Point]::new(174, $yPos)
$buttonRun.Size = [System.Drawing.Size]::new(260, 30)
$buttonRun.Text = "Начать перекодирование"
$buttonRun.BackColor = [System.Drawing.Color]::LightGreen
$buttonRun.Font = [System.Drawing.Font]::new("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$_mc.Add($buttonRun)

$buttonStop = [System.Windows.Forms.Button]::new()
$buttonStop.Location = [System.Drawing.Point]::new(446, $yPos)
$buttonStop.Size = [System.Drawing.Size]::new(170, 30)
$buttonStop.Text = "Остановить"
$buttonStop.Font = [System.Drawing.Font]::new($buttonStop.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
$buttonStop.ForeColor = [System.Drawing.Color]::DarkRed
$buttonStop.Enabled = $false
$buttonStop.Add_Click({
    # Записываем файл-флаг отмены
    try { "cancel" | Set-Content $global:_guiCancel -Encoding UTF8 } catch {}
})
$_mc.Add($buttonStop)

# ========== Progress Section ==========
$yPos = 586
$groupProgress = [System.Windows.Forms.GroupBox]::new()
$groupProgress.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupProgress.Size = [System.Drawing.Size]::new(770, 168)
$groupProgress.Text = "Прогресс"
$groupProgress.Font = [System.Drawing.Font]::new($groupProgress.Font, [System.Drawing.FontStyle]::Bold)
$_gpr = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# Current file label
$labelProgressFile = [System.Windows.Forms.Label]::new()
$labelProgressFile.Location = [System.Drawing.Point]::new(8, 18)
$labelProgressFile.Size = [System.Drawing.Size]::new(750, 16)
$labelProgressFile.Text = ""
$labelProgressFile.Font = [System.Drawing.Font]::new($labelProgressFile.Font.FontFamily, 9, [System.Drawing.FontStyle]::Regular)
$_gpr.Add($labelProgressFile)

# Progress bar — текущий файл
$progressBarFile = [System.Windows.Forms.ProgressBar]::new()
$progressBarFile.Location = [System.Drawing.Point]::new(8, 38)
$progressBarFile.Size = [System.Drawing.Size]::new(750, 18)
$progressBarFile.Minimum = 0
$progressBarFile.Maximum = 100
$progressBarFile.Value = 0
$_gpr.Add($progressBarFile)

# Progress label — всего файлов
$labelProgressTotal = [System.Windows.Forms.Label]::new()
$labelProgressTotal.Location = [System.Drawing.Point]::new(8, 60)
$labelProgressTotal.Size = [System.Drawing.Size]::new(750, 16)
$labelProgressTotal.Text = ""
$labelProgressTotal.Font = [System.Drawing.Font]::new($labelProgressTotal.Font.FontFamily, 9, [System.Drawing.FontStyle]::Regular)
$_gpr.Add($labelProgressTotal)

# Progress bar — всего файлов
$progressBarTotal = [System.Windows.Forms.ProgressBar]::new()
$progressBarTotal.Location = [System.Drawing.Point]::new(8, 80)
$progressBarTotal.Size = [System.Drawing.Size]::new(750, 18)
$progressBarTotal.Minimum = 0
$progressBarTotal.Maximum = 100
$progressBarTotal.Value = 0
$_gpr.Add($progressBarTotal)

# Summary label
$labelProgressSummary = [System.Windows.Forms.Label]::new()
$labelProgressSummary.Location = [System.Drawing.Point]::new(8, 104)
$labelProgressSummary.Size = [System.Drawing.Size]::new(750, 16)
$labelProgressSummary.Text = ""
$labelProgressSummary.Font = [System.Drawing.Font]::new($labelProgressSummary.Font.FontFamily, 8, [System.Drawing.FontStyle]::Regular)
$_gpr.Add($labelProgressSummary)

# Command line display
$labelCmd = [System.Windows.Forms.Label]::new()
$labelCmd.Location = [System.Drawing.Point]::new(8, 124)
$labelCmd.Size = [System.Drawing.Size]::new(60, 16)
$labelCmd.Text = "Команда:"
$labelCmd.Font = [System.Drawing.Font]::new($labelCmd.Font.FontFamily, 8, [System.Drawing.FontStyle]::Regular)
$_gpr.Add($labelCmd)

$textCommand = [System.Windows.Forms.TextBox]::new()
$textCommand.Location = [System.Drawing.Point]::new(68, 122)
$textCommand.Size = [System.Drawing.Size]::new(690, 20)
$textCommand.ReadOnly = $true
$textCommand.BackColor = [System.Drawing.Color]::White
$textCommand.Font = [System.Drawing.Font]::new("Consolas", 8, [System.Drawing.FontStyle]::Regular)
$textCommand.Text = ""
$_gpr.Add($textCommand)

$groupProgress.Controls.AddRange($_gpr.ToArray())
$_mc.Add($groupProgress)

# ========== Run Button Click Handler ==========
$buttonRun.Add_Click({
  try {
    # ---- Собрать все настройки ----
    $script:folder_sources      = $textInputFolder.Text
    $script:folder_destination  = $textOutputFolder.Text

    # options
    $script:audio_only          = if ($checkSaveAudio.Checked)   { "yes" } else { "no" }
    $script:merge_files         = if ($checkMergeFiles.Checked)  { "yes" } else { "no" }
    $script:create_frame        = if ($checkCreateFrames.Checked) { "yes" } else { "no" }
    $script:copy_codecs         = if ($checkCopyCodecs.Checked)  { "yes" } else { "no" }
    $_threadsVal = if ($textThreads.Text -match '^[0-9]+$') { $textThreads.Text } else { '4' }
    $script:multithreads        = if ($checkMultithreads.Checked) { ":+:$_threadsVal" } else { ":-:1" }
    $script:parallel_files      = ":-:1"
    $script:dry_run             = if ($checkDryRun.Checked)      { "yes" } else { "no" }
    $script:enable_log          = if ($checkLog.Checked)         { "yes" } else { "no" }
    $script:log_file            = $_cfg_log_file
    $script:extract_audio_copy  = if ($checkExtractAudioCopy.Checked) { "yes" } else { "no" }

    # Audio settings
    $script:audio_codec          = if ($checkAudioCodec.Checked)      { ":+:$($comboAudioCodec.Text)" }    else { ":-:$($comboAudioCodec.Text)" }
    $script:audio_number_channels = if ($checkAudioChannels.Checked)  { ":+:$($comboAudioChannels.SelectedIndex + 1)" } else { ":-:$($comboAudioChannels.SelectedIndex + 1)" }
    $script:audio_bitrate        = if ($checkAudioBitrate.Checked)    { ":+:$($textAudioBitrate.Text)" }           else { ":-:$($textAudioBitrate.Text)" }
    $script:audio_sampling_rate  = if ($checkAudioSampleRate.Checked)  { ":+:$($textAudioSampleRate.Text)" }        else { ":-:$($textAudioSampleRate.Text)" }
    $script:audio_normalize      = if ($checkAudioNorm.Checked)       { ":+:$($comboAudioNorm.Text)" }     else { ":-:$($comboAudioNorm.Text)" }

    # Video settings
    $script:video_codec          = if ($checkVideoCodec.Checked)      { ":+:$($comboVideoCodec.Text)" }    else { ":-:$($comboVideoCodec.Text)" }
    $script:video_resolution     = if ($checkVideoResolution.Checked) { ":+:$($comboVideoResolution.Text)" } else { ":-:$($comboVideoResolution.Text)" }
    $script:video_bitrate        = if ($checkVideoBitrate.Checked)    { ":+:$($textVideoBitrate.Text)" }           else { ":-:$($textVideoBitrate.Text)" }
    $script:video_number_frames  = if ($checkFrameRate.Checked)       { ":+:$($textFrameRate.Text)" }              else { ":-:$($textFrameRate.Text)" }
    # Значение rotation берём из первой цифры текста ("1 - По часовой" → "1"),
    # а не SelectedIndex+1: при перестановке/добавлении пунктов в список маппинг сломается.
    $_rotVal = ([string]$comboVideoRotation.SelectedItem -split ' ')[0]
    $script:video_rotation       = if ($checkVideoRotation.Checked)   { ":+:$_rotVal" } else { ":-:$_rotVal" }
    $script:video_quality        = if ($checkVideoQuality.Checked)    { ":+:$($textVideoQuality.Text)" }           else { ":-:$($textVideoQuality.Text)" }
    $script:keep_aspect_ratio    = if ($checkKeepAspect.Checked)      { ":+:yes" }                                 else { ":-:no" }
    $script:output_container     = if ($checkContainer.Checked)       { ":+:$($comboContainer.Text)" }     else { ":-:$($comboContainer.Text)" }

    $subtitlesMode = if ($comboSubtitlesMode.SelectedIndex -eq 0) { "burn" } else { "meta" }
    $script:video_subtitles = if ($checkVideoSubtitles.Checked) { ":+:$subtitlesMode" } else { ":-:$subtitlesMode" }

    # Hardware acceleration
    $hwIndex = $comboHWAccel.SelectedIndex
    if ($hwIndex -eq 1) {
        $script:hw_accel = ":+:nvidia"
    } elseif ($hwIndex -eq 2) {
        $script:hw_accel = ":+:intel"
    } else {
        $script:hw_accel = ":-:off"
    }
    $isGpuOn = ($hwIndex -gt 0)
    $script:gpu_preset = if ($isGpuOn) { ":+:$($comboGpuPreset.SelectedItem)" } else { ":-:$($comboGpuPreset.SelectedItem)" }
    $script:gpu_tune   = if ($isGpuOn -and $hwIndex -eq 1) { ":+:$($comboGpuTune.SelectedItem)" } else { ":-:$($comboGpuTune.SelectedItem)" }
    $script:gpu_rc     = if ($isGpuOn -and $hwIndex -eq 1) { ":+:$($comboGpuRC.SelectedItem)" }   else { ":-:$($comboGpuRC.SelectedItem)" }

    # Playback speed
    $script:playback_speed = if ($checkSpeed.Checked) { ":+:$($textSpeed.Text)" } else { ":-:$($textSpeed.Text)" }

    # Split settings
    $script:start_coding      = if ($checkStartTime.Checked)  { ":+:$($textStartTime.Text)" }  else { ":-:$($textStartTime.Text)" }
    $script:length_coding     = if ($checkDuration.Checked)   { ":+:$($textDuration.Text)" }   else { ":-:$($textDuration.Text)" }
    $script:split_by_silence  = if ($checkSplitSilence.Checked) { "yes" } else { "no" }
    $script:silence_duration  = $textSilenceDuration.Text
    $script:silence_threshold = $textSilenceThreshold.Text

    # Other settings
    $script:ffmpeg             = $textFFmpegPath.Text
    $script:save_old_extension = if ($checkSaveExtension.Checked) { "yes" } else { "no" }
    $script:format_files_in    = $textInputFormats.Text
    $script:subtitles_style    = $textSubtitlesStyle.Text

    # ---- Валидация ----
    if ([string]::IsNullOrWhiteSpace($script:folder_sources) -or !(Test-Path $script:folder_sources)) {
        [System.Windows.Forms.MessageBox]::Show("Папка источника не найдена:`n$($script:folder_sources)", "Ошибка", "OK", "Error")
        return
    }

    # ---- Подготовка прогресса ----
    # progressFile создаётся сразу (worker читает); cancelFile — только путь
    # (Guid: имя уникально без необходимости создавать-и-удалять).
    $progressFile = [System.IO.Path]::GetTempFileName()
    $cancelFile   = Join-Path ([System.IO.Path]::GetTempPath()) ("ffmpeg-cancel-" + [Guid]::NewGuid().ToString("N") + ".tmp")

    $env:FFMPEG_GUI_PROGRESS_FILE = $progressFile
    $env:FFMPEG_GUI_CANCEL_FILE   = $cancelFile

    $buttonRun.Enabled  = $false
    $buttonStop.Enabled = $true
    $progressBarFile.Value  = 0
    $progressBarTotal.Value = 0
    $labelProgressFile.Text    = "Запуск..."
    $labelProgressTotal.Text   = ""
    $labelProgressSummary.Text = ""
    $textCommand.Text          = ""

    # ---- Запуск script.ps1 в фоновом Runspace ----
    $scriptPath = Join-Path $script:_appDir "FFmpeg_Converter_script.ps1"
    # Загружаем скрипт: из встроенной переменной (EXE) или из файла (.ps1)
    if ($script:_embeddedScript) {
        $scriptContent = $script:_embeddedScript
    } elseif (Test-Path $scriptPath) {
        $scriptContent = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
    } else {
        [System.Windows.Forms.MessageBox]::Show("Скрипт не найден:`n$scriptPath", "Ошибка", "OK", "Error") | Out-Null
        $buttonRun.Enabled = $true; $buttonStop.Enabled = $false
        return
    }

    # Собираем все переменные для передачи в runspace
    $varsToPass = @{}
    foreach ($varName in @(
        'folder_sources','folder_destination','audio_only','merge_files','create_frame',
        'copy_codecs','multithreads','parallel_files','extract_audio_copy',
        'audio_codec','audio_number_channels','audio_bitrate','audio_sampling_rate','audio_normalize',
        'video_codec','video_resolution','video_bitrate','video_number_frames','video_rotation',
        'video_subtitles','video_quality','keep_aspect_ratio','output_container',
        'hw_accel','gpu_preset','gpu_tune','gpu_rc',
        'playback_speed',
        'start_coding','length_coding','split_by_silence','silence_duration','silence_threshold',
        'ffmpeg','save_old_extension','format_files_in','subtitles_style',
        'dry_run','enable_log','log_file'
    )) {
        $v = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
        $varsToPass[$varName] = if ($v) { $v.Value } else { $null }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    foreach ($kv in $varsToPass.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    $rs.SessionStateProxy.SetVariable("PSScriptRoot", $script:_appDir)
    $rs.SessionStateProxy.SetVariable("guiProgressFile", $progressFile)
    $rs.SessionStateProxy.SetVariable("guiCancelFile", $cancelFile)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript($scriptContent) | Out-Null
    $global:_guiHandle    = $ps.BeginInvoke()
    $global:_guiPS        = $ps
    $global:_guiRunspace  = $rs
    $global:_guiProgress  = $progressFile
    $global:_guiCancel    = $cancelFile

    # ---- Таймер для обновления UI ----
    $timer = [System.Windows.Forms.Timer]::new()
    $timer.Interval = 400
    $timer.Add_Tick({
      try {
        # Проверяем, завершился ли фоновый процесс
        if ($global:_guiHandle.IsCompleted) {
            $this.Stop()
            $this.Dispose()

            # Проверяем ошибки Runspace
            try { $global:_guiPS.EndInvoke($global:_guiHandle) | Out-Null } catch {}
            $rsErrors = $global:_guiPS.Streams.Error
            if ($rsErrors -and $rsErrors.Count -gt 0) {
                $errMsg = ($rsErrors | ForEach-Object { $_.ToString() }) -join "`n"
                [System.Windows.Forms.MessageBox]::Show($errMsg, "Ошибка скрипта", "OK", "Error") | Out-Null
                $labelProgressFile.Text = "Ошибка"
            }

            # Читаем финальное состояние
            try {
                $json = Get-Content $global:_guiProgress -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($json) {
                    $progressBarFile.Value  = 100
                    $progressBarTotal.Value = 100
                    if (-not $labelProgressFile.Text.StartsWith("Ошибка")) { $labelProgressFile.Text = "Готово" }
                    $labelProgressTotal.Text = "Файлов: $($json.fileNum) / $($json.totalFiles)"
                    $labelProgressSummary.Text = "OK: $($json.ok)   Ошибки: $($json.fail)   Пропущено: $($json.skip)"
                }
            } catch {}

            # Очистка
            try { Remove-Item $global:_guiProgress -Force -ErrorAction SilentlyContinue } catch {}
            try { Remove-Item $global:_guiCancel   -Force -ErrorAction SilentlyContinue } catch {}
            $env:FFMPEG_GUI_PROGRESS_FILE = $null
            $env:FFMPEG_GUI_CANCEL_FILE   = $null
            try { $global:_guiPS.Dispose() } catch {}
            try { $global:_guiRunspace.Close() } catch {}

            $buttonRun.Enabled  = $true
            $buttonStop.Enabled = $false
            return
        }

        # Читаем прогресс из JSON-файла
        try {
            if ($global:_guiProgress -and (Test-Path $global:_guiProgress)) {
                $json = [System.IO.File]::ReadAllText($global:_guiProgress) | ConvertFrom-Json
                $progressBarFile.Value  = [Math]::Min($json.filePercent,  100)
                $progressBarTotal.Value = [Math]::Min($json.totalPercent, 100)
                if ($json.currentFile) {
                    $labelProgressFile.Text = "$($json.currentFile)"
                }
                if ($json.totalFiles -gt 0) {
                    $labelProgressTotal.Text = "Файл $($json.fileNum) из $($json.totalFiles)"
                }
                $labelProgressSummary.Text = "OK: $($json.ok)   Ошибки: $($json.fail)   Пропущено: $($json.skip)"
                if ($json.command) { $textCommand.Text = $json.command }
            }
        } catch {}
      } catch {}
    })
    $timer.Start()
  } catch {
    [System.Windows.Forms.MessageBox]::Show("LINE $($_.InvocationInfo.ScriptLineNumber): $_", "DEBUG: Click Error", "OK", "Error") | Out-Null
    $buttonRun.Enabled = $true
    $buttonStop.Enabled = $false
  }
})

$mainContainer.Controls.AddRange($_mc.ToArray())
$form.Controls.AddRange($_fc.ToArray())
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

# ========== Получить версию ffmpeg — после отрисовки формы (через отложенный вызов) ==========
$form.Add_Shown({
    $t = [System.Windows.Forms.Timer]::new()
    $t.Interval = 50
    $t.Add_Tick({
        try {
            $this.Stop(); $this.Dispose()
            $ffmpegBin = $textFFmpegPath.Text
            $versionLine = (& $ffmpegBin -version 2>&1 | Select-Object -First 1).ToString().Trim()
            if ($versionLine -match 'ffmpeg version (\S+)') {
                $script:ffmpegCurrentVersion = $Matches[1]
                $lblFfmpegVersion.Text      = "ffmpeg: $($Matches[1])"
                $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::DarkGreen

                # Probe выбранного GPU-энкодера — на VM/без драйвера откатываемся на CPU
                $selIdx = $comboHWAccel.SelectedIndex
                if ($selIdx -eq 1) {
                    if (-not (Test-GpuEncoder $ffmpegBin "h264_nvenc")) {
                        $comboHWAccel.SelectedIndex = 0
                        $labelHWInfo.Text = "NVIDIA NVENC недоступен (нет GPU/драйвера) — переключено на CPU"
                        $labelHWInfo.ForeColor = [System.Drawing.Color]::Firebrick
                    }
                } elseif ($selIdx -eq 2) {
                    if (-not (Test-GpuEncoder $ffmpegBin "h264_qsv")) {
                        $comboHWAccel.SelectedIndex = 0
                        $labelHWInfo.Text = "Intel QSV недоступен (нет GPU/драйвера) — переключено на CPU"
                        $labelHWInfo.ForeColor = [System.Drawing.Color]::Firebrick
                    }
                }
            } else {
                $lblFfmpegVersion.Text      = "ffmpeg: не найден в PATH"
                $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::Firebrick
            }
        } catch {
            $lblFfmpegVersion.Text      = "ffmpeg: не найден в PATH"
            $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::Firebrick
        }
    })
    $t.Start()
})

# ========== Cleanup on Close ==========
# Закрытие окна во время конверсии: отменяем фоновую задачу (worker видит cancel-файл
# и убивает свой ffmpeg-процесс), освобождаем runspace, удаляем временные файлы —
# иначе остаётся осиротевший ffmpeg.exe и неудалённый мусор.
$form.Add_FormClosing({
    if ($global:_guiPS -and $global:_guiHandle -and -not $global:_guiHandle.IsCompleted) {
        try { "cancel" | Set-Content $global:_guiCancel -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
        try { $global:_guiPS.Stop() } catch {}
    }
    foreach ($f in @($global:_guiProgress, $global:_guiCancel)) {
        if ($f) { try { Remove-Item $f -Force -ErrorAction SilentlyContinue } catch {} }
    }
    if ($global:_guiPS)       { try { $global:_guiPS.Dispose() } catch {} }
    if ($global:_guiRunspace) { try { $global:_guiRunspace.Dispose() } catch {} }
})

# ========== Show Form ==========
$form.ShowDialog() | Out-Null
