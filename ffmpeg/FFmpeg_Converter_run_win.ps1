Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Bypass SSL certificate validation (for PS 5.1 compatibility)
if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
    Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int prob) { return true; }
}
'@
}
[System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
[System.Net.ServicePointManager]::SecurityProtocol  = [Net.SecurityProtocolType]::Tls12

# --- Фallback для $PSScriptRoot при запуске из ps2exe-экзешника ---
if ([string]::IsNullOrEmpty($PSScriptRoot)) {
    $PSScriptRoot = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# --- Чтение config.ini ---
$configFile = Join-Path $PSScriptRoot "config.ini"
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
            return $val.Trim()
        }
    }
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
$_cfg_source      = Read-Config "source"      "folders" "m:\ffmpeg\0"
$_cfg_destination = Read-Config "destination"  "folders" "m:\ffmpeg\1"
if (-not [System.IO.Path]::IsPathRooted($_cfg_source))     { $_cfg_source     = Join-Path $PSScriptRoot $_cfg_source }
if (-not [System.IO.Path]::IsPathRooted($_cfg_destination)) { $_cfg_destination = Join-Path $PSScriptRoot $_cfg_destination }

$_cfg_audio_only         = Read-Config "audio_only"         "options" "no"
$_cfg_merge_files        = Read-Config "merge_files"        "options" "no"
$_cfg_create_frame       = Read-Config "create_frame"       "options" "no"
$_cfg_copy_codecs        = Read-Config "copy_codecs"        "options" "no"
$_cfg_extract_audio_copy = Read-Config "extract_audio_copy" "options" "no"

$_cfg_audio_codec    = Parse-Flag (Read-Config "codec"         "audio" "+aac")
$_cfg_audio_channels = Parse-Flag (Read-Config "channels"      "audio" "+2")
$_cfg_audio_bitrate  = Parse-Flag (Read-Config "bitrate"       "audio" "+128")
$_cfg_audio_sample   = Parse-Flag (Read-Config "sampling_rate" "audio" "+44100")
$_cfg_audio_norm     = Parse-Flag (Read-Config "normalize"     "audio" "-loudnorm")

$_cfg_video_codec      = Parse-Flag (Read-Config "codec"            "video" "+libx264")
$_cfg_video_resolution = Parse-Flag (Read-Config "resolution"       "video" "+1280x720")
$_cfg_video_bitrate    = Parse-Flag (Read-Config "bitrate"          "video" "+2000")
$_cfg_video_framerate  = Parse-Flag (Read-Config "framerate"        "video" "+25")
$_cfg_video_rotation   = Parse-Flag (Read-Config "rotation"         "video" "-2")
$_cfg_video_subtitles  = Parse-Flag (Read-Config "subtitles"        "video" "-burn")
$_cfg_video_quality    = Parse-Flag (Read-Config "quality"          "video" "-23")
$_cfg_keep_aspect      = Parse-Flag (Read-Config "keep_aspect_ratio" "video" "+yes")
$_cfg_container        = Parse-Flag (Read-Config "container"        "video" "-mp4")

$_cfg_threads  = Parse-Flag (Read-Config "threads"        "performance" "+4")
$_cfg_hw_accel = Parse-Flag (Read-Config "hw_accel"       "gpu"         "-nvidia")
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

# Main Form
$form = New-Object System.Windows.Forms.Form
$form.Text = "Video Converter (ffmpeg)"
$form.Size = New-Object System.Drawing.Size(820, 908)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)

# Main container
$mainContainer = New-Object System.Windows.Forms.Panel
$mainContainer.Location = New-Object System.Drawing.Point(10, 36)
$mainContainer.Size = New-Object System.Drawing.Size(790, 840)
$mainContainer.AutoScroll = $true
$form.Controls.Add($mainContainer)

# ========== Version strip (directly on form, above mainContainer) ==========
$lblFfmpegVersion = New-Object System.Windows.Forms.Label
$lblFfmpegVersion.Location  = New-Object System.Drawing.Point(10, 13)
$lblFfmpegVersion.Size      = New-Object System.Drawing.Size(400, 18)
$lblFfmpegVersion.Text      = "ffmpeg: определяется..."
$lblFfmpegVersion.ForeColor = [System.Drawing.Color]::DimGray
$lblFfmpegVersion.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($lblFfmpegVersion)

$script:ffmpegUpdateUrl      = ""
$script:ffmpegCurrentVersion = ""
$lnkFfmpegUpdate = New-Object System.Windows.Forms.LinkLabel
$lnkFfmpegUpdate.Location  = New-Object System.Drawing.Point(415, 13)
$lnkFfmpegUpdate.Size      = New-Object System.Drawing.Size(130, 18)
$lnkFfmpegUpdate.Text      = ""
$lnkFfmpegUpdate.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
$lnkFfmpegUpdate.Add_LinkClicked({
    if (-not [string]::IsNullOrEmpty($script:ffmpegUpdateUrl)) {
        Start-Process $script:ffmpegUpdateUrl
    }
})
$form.Controls.Add($lnkFfmpegUpdate)

$btnCheckFfmpeg = New-Object System.Windows.Forms.Button
$btnCheckFfmpeg.Location = New-Object System.Drawing.Point(552, 10)
$btnCheckFfmpeg.Size     = New-Object System.Drawing.Size(240, 22)
$btnCheckFfmpeg.Text     = "Проверить обновления"
$btnCheckFfmpeg.Font     = New-Object System.Drawing.Font("Segoe UI", 8)
$btnCheckFfmpeg.Add_Click({
    $btnCheckFfmpeg.Enabled = $false
    $btnCheckFfmpeg.Text    = "Запрос..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
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
$form.Controls.Add($btnCheckFfmpeg)

$xPos0 = 10

# ========== Input Folder ==========
$yPos = 8
$labelInputFolder = New-Object System.Windows.Forms.Label
$labelInputFolder.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$labelInputFolder.Size = New-Object System.Drawing.Size(600, 15)
$labelInputFolder.Text = "Выберите папку с файлами для перекодирования:"
$mainContainer.Controls.Add($labelInputFolder)

$yPos += 18
$textInputFolder = New-Object System.Windows.Forms.TextBox
$textInputFolder.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$textInputFolder.Size = New-Object System.Drawing.Size(690, 22)
$textInputFolder.Text = $_cfg_source
$mainContainer.Controls.Add($textInputFolder)

$buttonInputBrowse = New-Object System.Windows.Forms.Button
$buttonInputBrowse.Location = New-Object System.Drawing.Point(705, $yPos)
$buttonInputBrowse.Size = New-Object System.Drawing.Size(75, 23)
$buttonInputBrowse.Text = "Обзор"
$buttonInputBrowse.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select source folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textInputFolder.Text = $folderBrowser.SelectedPath
    }
})
$mainContainer.Controls.Add($buttonInputBrowse)

# ========== Output Folder ==========
$yPos += 30
$labelOutputFolder = New-Object System.Windows.Forms.Label
$labelOutputFolder.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$labelOutputFolder.Size = New-Object System.Drawing.Size(600, 15)
$labelOutputFolder.Text = "Выберите папку для сохранения готовых файлов:"
$mainContainer.Controls.Add($labelOutputFolder)

$yPos += 18
$textOutputFolder = New-Object System.Windows.Forms.TextBox
$textOutputFolder.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$textOutputFolder.Size = New-Object System.Drawing.Size(690, 22)
$textOutputFolder.Text = $_cfg_destination
$mainContainer.Controls.Add($textOutputFolder)

$buttonOutputBrowse = New-Object System.Windows.Forms.Button
$buttonOutputBrowse.Location = New-Object System.Drawing.Point(705, $yPos)
$buttonOutputBrowse.Size = New-Object System.Drawing.Size(75, 23)
$buttonOutputBrowse.Text = "Обзор"
$buttonOutputBrowse.Add_Click({
    $folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
    $folderBrowser.Description = "Select destination folder"
    if ($folderBrowser.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $textOutputFolder.Text = $folderBrowser.SelectedPath
    }
})
$mainContainer.Controls.Add($buttonOutputBrowse)

# ========== Options Section ==========
$yPos += 32
$groupOptions = New-Object System.Windows.Forms.GroupBox
$groupOptions.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupOptions.Size = New-Object System.Drawing.Size(770, 128)
$groupOptions.Text = "Опции"
$mainContainer.Controls.Add($groupOptions)

# Row 1: SaveAudio | MergeFiles | CreateFrames
$checkSaveAudio = New-Object System.Windows.Forms.CheckBox
$checkSaveAudio.Location = New-Object System.Drawing.Point(8, 18)
$checkSaveAudio.Size = New-Object System.Drawing.Size(185, 20)
$checkSaveAudio.Text = "Сохранить только аудио"
$checkSaveAudio.Checked = ($_cfg_audio_only -eq "yes")
$groupOptions.Controls.Add($checkSaveAudio)

$checkMergeFiles = New-Object System.Windows.Forms.CheckBox
$checkMergeFiles.Location = New-Object System.Drawing.Point(208, 18)
$checkMergeFiles.Size = New-Object System.Drawing.Size(160, 20)
$checkMergeFiles.Text = "Объединить файлы"
$checkMergeFiles.Checked = ($_cfg_merge_files -eq "yes")
$groupOptions.Controls.Add($checkMergeFiles)

$checkCreateFrames = New-Object System.Windows.Forms.CheckBox
$checkCreateFrames.Location = New-Object System.Drawing.Point(388, 18)
$checkCreateFrames.Size = New-Object System.Drawing.Size(185, 20)
$checkCreateFrames.Text = "Разбить видео на кадры"
$checkCreateFrames.Checked = ($_cfg_create_frame -eq "yes")
$groupOptions.Controls.Add($checkCreateFrames)

# Row 2: CopyCodecs | Multithreads + textThreads
$checkCopyCodecs = New-Object System.Windows.Forms.CheckBox
$checkCopyCodecs.Location = New-Object System.Drawing.Point(8, 40)
$checkCopyCodecs.Size = New-Object System.Drawing.Size(185, 20)
$checkCopyCodecs.Text = "Без перекодирования"
$checkCopyCodecs.Checked = ($_cfg_copy_codecs -eq "yes")
$groupOptions.Controls.Add($checkCopyCodecs)

$checkMultithreads = New-Object System.Windows.Forms.CheckBox
$checkMultithreads.Location = New-Object System.Drawing.Point(208, 40)
$checkMultithreads.Size = New-Object System.Drawing.Size(120, 20)
$checkMultithreads.Text = "Потоки ffmpeg:"
$checkMultithreads.Checked = $_cfg_threads.enabled
$groupOptions.Controls.Add($checkMultithreads)

$textThreads = New-Object System.Windows.Forms.TextBox
$textThreads.Location = New-Object System.Drawing.Point(333, 40)
$textThreads.Size = New-Object System.Drawing.Size(35, 20)
$textThreads.Text = $_cfg_threads.value
$groupOptions.Controls.Add($textThreads)

# Row 2 продолжение: ExtractAudioCopy (справа от Multithreads)
$checkExtractAudioCopy = New-Object System.Windows.Forms.CheckBox
$checkExtractAudioCopy.Location = New-Object System.Drawing.Point(388, 40)
$checkExtractAudioCopy.Size = New-Object System.Drawing.Size(270, 20)
$checkExtractAudioCopy.Text = "Извлечь аудио (без перекодирования)"
$checkExtractAudioCopy.Checked = ($_cfg_extract_audio_copy -eq "yes")
$groupOptions.Controls.Add($checkExtractAudioCopy)

# Row 3: DryRun | Log | KeepAspect
$checkDryRun = New-Object System.Windows.Forms.CheckBox
$checkDryRun.Location = New-Object System.Drawing.Point(8, 62)
$checkDryRun.Size = New-Object System.Drawing.Size(165, 20)
$checkDryRun.Text = "Предпросмотр команд"
$checkDryRun.Checked = ($_cfg_dry_run -eq "yes")
$groupOptions.Controls.Add($checkDryRun)

$checkLog = New-Object System.Windows.Forms.CheckBox
$checkLog.Location = New-Object System.Drawing.Point(208, 62)
$checkLog.Size = New-Object System.Drawing.Size(120, 20)
$checkLog.Text = "Логирование"
$checkLog.Checked = ($_cfg_log -eq "yes")
$groupOptions.Controls.Add($checkLog)

$checkKeepAspect = New-Object System.Windows.Forms.CheckBox
$checkKeepAspect.Location = New-Object System.Drawing.Point(388, 62)
$checkKeepAspect.Size = New-Object System.Drawing.Size(175, 20)
$checkKeepAspect.Text = "Сохранять пропорции"
$checkKeepAspect.Checked = ($_cfg_keep_aspect.enabled -and $_cfg_keep_aspect.value -eq "yes")
$groupOptions.Controls.Add($checkKeepAspect)

# Row 4: GPU Acceleration
$labelHWAccelOpt = New-Object System.Windows.Forms.Label
$labelHWAccelOpt.Location = New-Object System.Drawing.Point(8, 86)
$labelHWAccelOpt.Size = New-Object System.Drawing.Size(90, 16)
$labelHWAccelOpt.Text = "GPU ускорение:"
$groupOptions.Controls.Add($labelHWAccelOpt)

$comboHWAccel = New-Object System.Windows.Forms.ComboBox
$comboHWAccel.Location = New-Object System.Drawing.Point(100, 84)
$comboHWAccel.Size = New-Object System.Drawing.Size(140, 21)
$comboHWAccel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboHWAccel.Items.AddRange(@("Без ускорения", "NVIDIA (NVENC)", "Intel (QSV)"))
$comboHWAccel.SelectedIndex = if ($_cfg_hw_accel.enabled) { switch ($_cfg_hw_accel.value) { "nvidia" { 1 } "intel" { 2 } default { 0 } } } else { 0 }
$groupOptions.Controls.Add($comboHWAccel)

# GPU Preset (hidden by default)
$labelGpuPreset = New-Object System.Windows.Forms.Label
$labelGpuPreset.Location = New-Object System.Drawing.Point(250, 86)
$labelGpuPreset.Size = New-Object System.Drawing.Size(48, 16)
$labelGpuPreset.Text = "Пресет:"
$labelGpuPreset.Visible = $false
$groupOptions.Controls.Add($labelGpuPreset)

$comboGpuPreset = New-Object System.Windows.Forms.ComboBox
$comboGpuPreset.Location = New-Object System.Drawing.Point(300, 84)
$comboGpuPreset.Size = New-Object System.Drawing.Size(55, 21)
$comboGpuPreset.Items.AddRange(@("p1", "p2", "p3", "p4", "p5", "p6", "p7"))
$comboGpuPreset.SelectedIndex = 4
$comboGpuPreset.Visible = $false
$groupOptions.Controls.Add($comboGpuPreset)

# GPU Tune (NVIDIA only, hidden)
$labelGpuTune = New-Object System.Windows.Forms.Label
$labelGpuTune.Location = New-Object System.Drawing.Point(362, 86)
$labelGpuTune.Size = New-Object System.Drawing.Size(40, 16)
$labelGpuTune.Text = "Tune:"
$labelGpuTune.Visible = $false
$groupOptions.Controls.Add($labelGpuTune)

$comboGpuTune = New-Object System.Windows.Forms.ComboBox
$comboGpuTune.Location = New-Object System.Drawing.Point(404, 84)
$comboGpuTune.Size = New-Object System.Drawing.Size(70, 21)
$comboGpuTune.Items.AddRange(@("hq", "ll", "ull", "lossless"))
$comboGpuTune.SelectedIndex = 0
$comboGpuTune.Visible = $false
$groupOptions.Controls.Add($comboGpuTune)

# GPU RC (NVIDIA only, hidden)
$labelGpuRC = New-Object System.Windows.Forms.Label
$labelGpuRC.Location = New-Object System.Drawing.Point(480, 86)
$labelGpuRC.Size = New-Object System.Drawing.Size(28, 16)
$labelGpuRC.Text = "RC:"
$labelGpuRC.Visible = $false
$groupOptions.Controls.Add($labelGpuRC)

$comboGpuRC = New-Object System.Windows.Forms.ComboBox
$comboGpuRC.Location = New-Object System.Drawing.Point(510, 84)
$comboGpuRC.Size = New-Object System.Drawing.Size(70, 21)
$comboGpuRC.Items.AddRange(@("vbr", "cbr", "constqp"))
$comboGpuRC.SelectedIndex = 0
$comboGpuRC.Visible = $false
$groupOptions.Controls.Add($comboGpuRC)

# Row 6: HW info label
$labelHWInfo = New-Object System.Windows.Forms.Label
$labelHWInfo.Location = New-Object System.Drawing.Point(8, 108)
$labelHWInfo.Size = New-Object System.Drawing.Size(750, 14)
$labelHWInfo.Text = ""
$labelHWInfo.Font = New-Object System.Drawing.Font($labelHWInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$groupOptions.Controls.Add($labelHWInfo)

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

# ========== Encoding Section ==========
$yPos = 260
$groupEncoding = New-Object System.Windows.Forms.GroupBox
$groupEncoding.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupEncoding.Size = New-Object System.Drawing.Size(770, 205)
$groupEncoding.Text = "Настройки кодирования"
$mainContainer.Controls.Add($groupEncoding)

# --- Audio column (x=8) ---

# Audio Codec
$labelAudioCodec = New-Object System.Windows.Forms.Label
$labelAudioCodec.Location = New-Object System.Drawing.Point(8, 18)
$labelAudioCodec.Size = New-Object System.Drawing.Size(120, 16)
$labelAudioCodec.Text = "Аудио кодек:"
$groupEncoding.Controls.Add($labelAudioCodec)

$checkAudioCodec = New-Object System.Windows.Forms.CheckBox
$checkAudioCodec.Location = New-Object System.Drawing.Point(130, 18)
$checkAudioCodec.Size = New-Object System.Drawing.Size(18, 18)
$checkAudioCodec.Checked = $_cfg_audio_codec.enabled
$groupEncoding.Controls.Add($checkAudioCodec)

$comboAudioCodec = New-Object System.Windows.Forms.ComboBox
$comboAudioCodec.Location = New-Object System.Drawing.Point(150, 18)
$comboAudioCodec.Size = New-Object System.Drawing.Size(105, 21)
$comboAudioCodec.Items.AddRange(@("aac", "libmp3lame"))
$_acIdx = $comboAudioCodec.Items.IndexOf($_cfg_audio_codec.value)
$comboAudioCodec.SelectedIndex = if ($_acIdx -ge 0) { $_acIdx } else { 0 }
$groupEncoding.Controls.Add($comboAudioCodec)

# Audio Channels
$labelAudioChannels = New-Object System.Windows.Forms.Label
$labelAudioChannels.Location = New-Object System.Drawing.Point(8, 40)
$labelAudioChannels.Size = New-Object System.Drawing.Size(120, 16)
$labelAudioChannels.Text = "Каналы:"
$groupEncoding.Controls.Add($labelAudioChannels)

$checkAudioChannels = New-Object System.Windows.Forms.CheckBox
$checkAudioChannels.Location = New-Object System.Drawing.Point(130, 40)
$checkAudioChannels.Size = New-Object System.Drawing.Size(18, 18)
$checkAudioChannels.Checked = $_cfg_audio_channels.enabled
$groupEncoding.Controls.Add($checkAudioChannels)

$comboAudioChannels = New-Object System.Windows.Forms.ComboBox
$comboAudioChannels.Location = New-Object System.Drawing.Point(150, 40)
$comboAudioChannels.Size = New-Object System.Drawing.Size(105, 21)
$comboAudioChannels.Items.AddRange(@("1 - Mono", "2 - Stereo"))
$comboAudioChannels.SelectedIndex = if ($_cfg_audio_channels.value -eq "1") { 0 } else { 1 }
$groupEncoding.Controls.Add($comboAudioChannels)

# Audio Bitrate
$labelAudioBitrate = New-Object System.Windows.Forms.Label
$labelAudioBitrate.Location = New-Object System.Drawing.Point(8, 62)
$labelAudioBitrate.Size = New-Object System.Drawing.Size(120, 16)
$labelAudioBitrate.Text = "Аудио битрейт:"
$groupEncoding.Controls.Add($labelAudioBitrate)

$checkAudioBitrate = New-Object System.Windows.Forms.CheckBox
$checkAudioBitrate.Location = New-Object System.Drawing.Point(130, 62)
$checkAudioBitrate.Size = New-Object System.Drawing.Size(18, 18)
$checkAudioBitrate.Checked = $_cfg_audio_bitrate.enabled
$groupEncoding.Controls.Add($checkAudioBitrate)

$textAudioBitrate = New-Object System.Windows.Forms.TextBox
$textAudioBitrate.Location = New-Object System.Drawing.Point(150, 62)
$textAudioBitrate.Size = New-Object System.Drawing.Size(105, 20)
$textAudioBitrate.Text = $_cfg_audio_bitrate.value
$groupEncoding.Controls.Add($textAudioBitrate)

# Audio Sampling Rate
$labelAudioSampleRate = New-Object System.Windows.Forms.Label
$labelAudioSampleRate.Location = New-Object System.Drawing.Point(8, 84)
$labelAudioSampleRate.Size = New-Object System.Drawing.Size(120, 16)
$labelAudioSampleRate.Text = "Дискретизация:"
$groupEncoding.Controls.Add($labelAudioSampleRate)

$checkAudioSampleRate = New-Object System.Windows.Forms.CheckBox
$checkAudioSampleRate.Location = New-Object System.Drawing.Point(130, 84)
$checkAudioSampleRate.Size = New-Object System.Drawing.Size(18, 18)
$checkAudioSampleRate.Checked = $_cfg_audio_sample.enabled
$groupEncoding.Controls.Add($checkAudioSampleRate)

$textAudioSampleRate = New-Object System.Windows.Forms.TextBox
$textAudioSampleRate.Location = New-Object System.Drawing.Point(150, 84)
$textAudioSampleRate.Size = New-Object System.Drawing.Size(105, 20)
$textAudioSampleRate.Text = $_cfg_audio_sample.value
$groupEncoding.Controls.Add($textAudioSampleRate)

# Audio Normalize
$labelAudioNorm = New-Object System.Windows.Forms.Label
$labelAudioNorm.Location = New-Object System.Drawing.Point(8, 106)
$labelAudioNorm.Size = New-Object System.Drawing.Size(120, 16)
$labelAudioNorm.Text = "Нормализация:"
$groupEncoding.Controls.Add($labelAudioNorm)

$checkAudioNorm = New-Object System.Windows.Forms.CheckBox
$checkAudioNorm.Location = New-Object System.Drawing.Point(130, 106)
$checkAudioNorm.Size = New-Object System.Drawing.Size(18, 18)
$checkAudioNorm.Checked = $_cfg_audio_norm.enabled
$groupEncoding.Controls.Add($checkAudioNorm)

$comboAudioNorm = New-Object System.Windows.Forms.ComboBox
$comboAudioNorm.Location = New-Object System.Drawing.Point(150, 106)
$comboAudioNorm.Size = New-Object System.Drawing.Size(105, 21)
$comboAudioNorm.Items.AddRange(@("loudnorm", "dynaudnorm"))
$_anIdx = $comboAudioNorm.Items.IndexOf($_cfg_audio_norm.value)
$comboAudioNorm.SelectedIndex = if ($_anIdx -ge 0) { $_anIdx } else { 0 }
$groupEncoding.Controls.Add($comboAudioNorm)

# --- Video column (x=380) ---

# Video Codec
$labelVideoCodec = New-Object System.Windows.Forms.Label
$labelVideoCodec.Location = New-Object System.Drawing.Point(380, 18)
$labelVideoCodec.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoCodec.Text = "Видео кодек:"
$groupEncoding.Controls.Add($labelVideoCodec)

$checkVideoCodec = New-Object System.Windows.Forms.CheckBox
$checkVideoCodec.Location = New-Object System.Drawing.Point(492, 18)
$checkVideoCodec.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoCodec.Checked = $_cfg_video_codec.enabled
$groupEncoding.Controls.Add($checkVideoCodec)

$comboVideoCodec = New-Object System.Windows.Forms.ComboBox
$comboVideoCodec.Location = New-Object System.Drawing.Point(512, 18)
$comboVideoCodec.Size = New-Object System.Drawing.Size(130, 21)
$comboVideoCodec.Items.AddRange(@("libx264", "libx265", "libsvtav1", "h264_nvenc", "hevc_nvenc", "av1_nvenc", "h264_qsv"))
$_vcIdx = $comboVideoCodec.Items.IndexOf($_cfg_video_codec.value)
$comboVideoCodec.SelectedIndex = if ($_vcIdx -ge 0) { $_vcIdx } else { 0 }
$groupEncoding.Controls.Add($comboVideoCodec)

# Video Resolution
$labelVideoResolution = New-Object System.Windows.Forms.Label
$labelVideoResolution.Location = New-Object System.Drawing.Point(380, 40)
$labelVideoResolution.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoResolution.Text = "Разрешение:"
$groupEncoding.Controls.Add($labelVideoResolution)

$checkVideoResolution = New-Object System.Windows.Forms.CheckBox
$checkVideoResolution.Location = New-Object System.Drawing.Point(492, 40)
$checkVideoResolution.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoResolution.Checked = $_cfg_video_resolution.enabled
$groupEncoding.Controls.Add($checkVideoResolution)

$comboVideoResolution = New-Object System.Windows.Forms.ComboBox
$comboVideoResolution.Location = New-Object System.Drawing.Point(512, 40)
$comboVideoResolution.Size = New-Object System.Drawing.Size(130, 21)
$comboVideoResolution.Items.AddRange(@("1920x1080", "1280x720", "854x480", "640x360", "1440x1080", "960x720", "640x480", "480x360"))
$_vrIdx = $comboVideoResolution.Items.IndexOf($_cfg_video_resolution.value)
$comboVideoResolution.SelectedIndex = if ($_vrIdx -ge 0) { $_vrIdx } else { 1 }
$groupEncoding.Controls.Add($comboVideoResolution)

# Video Bitrate
$labelVideoBitrate = New-Object System.Windows.Forms.Label
$labelVideoBitrate.Location = New-Object System.Drawing.Point(380, 62)
$labelVideoBitrate.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoBitrate.Text = "Видео битрейт:"
$groupEncoding.Controls.Add($labelVideoBitrate)

$checkVideoBitrate = New-Object System.Windows.Forms.CheckBox
$checkVideoBitrate.Location = New-Object System.Drawing.Point(492, 62)
$checkVideoBitrate.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoBitrate.Checked = $_cfg_video_bitrate.enabled
$groupEncoding.Controls.Add($checkVideoBitrate)

$textVideoBitrate = New-Object System.Windows.Forms.TextBox
$textVideoBitrate.Location = New-Object System.Drawing.Point(512, 62)
$textVideoBitrate.Size = New-Object System.Drawing.Size(130, 20)
$textVideoBitrate.Text = $_cfg_video_bitrate.value
$groupEncoding.Controls.Add($textVideoBitrate)

# Frame Rate
$labelFrameRate = New-Object System.Windows.Forms.Label
$labelFrameRate.Location = New-Object System.Drawing.Point(380, 84)
$labelFrameRate.Size = New-Object System.Drawing.Size(110, 16)
$labelFrameRate.Text = "Кадры/с:"
$groupEncoding.Controls.Add($labelFrameRate)

$checkFrameRate = New-Object System.Windows.Forms.CheckBox
$checkFrameRate.Location = New-Object System.Drawing.Point(492, 84)
$checkFrameRate.Size = New-Object System.Drawing.Size(18, 18)
$checkFrameRate.Checked = $_cfg_video_framerate.enabled
$groupEncoding.Controls.Add($checkFrameRate)

$textFrameRate = New-Object System.Windows.Forms.TextBox
$textFrameRate.Location = New-Object System.Drawing.Point(512, 84)
$textFrameRate.Size = New-Object System.Drawing.Size(130, 20)
$textFrameRate.Text = $_cfg_video_framerate.value
$groupEncoding.Controls.Add($textFrameRate)

# Video Quality (CRF/CQ)
$labelVideoQuality = New-Object System.Windows.Forms.Label
$labelVideoQuality.Location = New-Object System.Drawing.Point(380, 106)
$labelVideoQuality.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoQuality.Text = "Качество (CRF):"
$groupEncoding.Controls.Add($labelVideoQuality)

$checkVideoQuality = New-Object System.Windows.Forms.CheckBox
$checkVideoQuality.Location = New-Object System.Drawing.Point(492, 106)
$checkVideoQuality.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoQuality.Checked = $_cfg_video_quality.enabled
$groupEncoding.Controls.Add($checkVideoQuality)

$textVideoQuality = New-Object System.Windows.Forms.TextBox
$textVideoQuality.Location = New-Object System.Drawing.Point(512, 106)
$textVideoQuality.Size = New-Object System.Drawing.Size(130, 20)
$textVideoQuality.Text = $_cfg_video_quality.value
$groupEncoding.Controls.Add($textVideoQuality)

# Video Rotation
$labelVideoRotation = New-Object System.Windows.Forms.Label
$labelVideoRotation.Location = New-Object System.Drawing.Point(380, 128)
$labelVideoRotation.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoRotation.Text = "Поворот:"
$groupEncoding.Controls.Add($labelVideoRotation)

$checkVideoRotation = New-Object System.Windows.Forms.CheckBox
$checkVideoRotation.Location = New-Object System.Drawing.Point(492, 128)
$checkVideoRotation.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoRotation.Checked = $_cfg_video_rotation.enabled
$groupEncoding.Controls.Add($checkVideoRotation)

$comboVideoRotation = New-Object System.Windows.Forms.ComboBox
$comboVideoRotation.Location = New-Object System.Drawing.Point(512, 128)
$comboVideoRotation.Size = New-Object System.Drawing.Size(160, 21)
$comboVideoRotation.Items.AddRange(@("1 - По часовой", "2 - Против часовой"))
$comboVideoRotation.SelectedIndex = if ($_cfg_video_rotation.value -eq "1") { 0 } else { 1 }
$groupEncoding.Controls.Add($comboVideoRotation)

# Video Subtitles
$labelVideoSubtitles = New-Object System.Windows.Forms.Label
$labelVideoSubtitles.Location = New-Object System.Drawing.Point(380, 150)
$labelVideoSubtitles.Size = New-Object System.Drawing.Size(110, 16)
$labelVideoSubtitles.Text = "Субтитры:"
$groupEncoding.Controls.Add($labelVideoSubtitles)

$checkVideoSubtitles = New-Object System.Windows.Forms.CheckBox
$checkVideoSubtitles.Location = New-Object System.Drawing.Point(492, 150)
$checkVideoSubtitles.Size = New-Object System.Drawing.Size(18, 18)
$checkVideoSubtitles.Checked = $_cfg_video_subtitles.enabled
$groupEncoding.Controls.Add($checkVideoSubtitles)

$comboSubtitlesMode = New-Object System.Windows.Forms.ComboBox
$comboSubtitlesMode.Location = New-Object System.Drawing.Point(512, 150)
$comboSubtitlesMode.Size = New-Object System.Drawing.Size(160, 21)
$comboSubtitlesMode.Items.AddRange(@("burn - На видео", "meta - Дорожкой"))
$comboSubtitlesMode.SelectedIndex = if ($_cfg_video_subtitles.value -eq "meta") { 1 } else { 0 }
$groupEncoding.Controls.Add($comboSubtitlesMode)

# Output Container
$labelContainer = New-Object System.Windows.Forms.Label
$labelContainer.Location = New-Object System.Drawing.Point(380, 172)
$labelContainer.Size = New-Object System.Drawing.Size(110, 16)
$labelContainer.Text = "Контейнер:"
$groupEncoding.Controls.Add($labelContainer)

$checkContainer = New-Object System.Windows.Forms.CheckBox
$checkContainer.Location = New-Object System.Drawing.Point(492, 172)
$checkContainer.Size = New-Object System.Drawing.Size(18, 18)
$checkContainer.Checked = $_cfg_container.enabled
$groupEncoding.Controls.Add($checkContainer)

$comboContainer = New-Object System.Windows.Forms.ComboBox
$comboContainer.Location = New-Object System.Drawing.Point(512, 172)
$comboContainer.Size = New-Object System.Drawing.Size(130, 21)
$comboContainer.Items.AddRange(@("mp4", "mkv", "webm", "avi", "ts"))
$_cntIdx = $comboContainer.Items.IndexOf($_cfg_container.value)
$comboContainer.SelectedIndex = if ($_cntIdx -ge 0) { $_cntIdx } else { 0 }
$groupEncoding.Controls.Add($comboContainer)

# ========== Playback Speed Section ==========
$yPos = 469
$groupSpeed = New-Object System.Windows.Forms.GroupBox
$groupSpeed.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupSpeed.Size = New-Object System.Drawing.Size(770, 42)
$groupSpeed.Text = "Скорость воспроизведения"
$mainContainer.Controls.Add($groupSpeed)

$checkSpeed = New-Object System.Windows.Forms.CheckBox
$checkSpeed.Location = New-Object System.Drawing.Point(8, 14)
$checkSpeed.Size = New-Object System.Drawing.Size(80, 18)
$checkSpeed.Text = "Скорость:"
$checkSpeed.Checked = $_cfg_speed.enabled
$groupSpeed.Controls.Add($checkSpeed)

$textSpeed = New-Object System.Windows.Forms.TextBox
$textSpeed.Location = New-Object System.Drawing.Point(92, 14)
$textSpeed.Size = New-Object System.Drawing.Size(55, 20)
$textSpeed.Text = $_cfg_speed.value
$groupSpeed.Controls.Add($textSpeed)

$labelSpeedInfo = New-Object System.Windows.Forms.Label
$labelSpeedInfo.Location = New-Object System.Drawing.Point(158, 16)
$labelSpeedInfo.Size = New-Object System.Drawing.Size(600, 16)
$labelSpeedInfo.Text = "1.0 = норм, 2.0 = ускорение x2, 0.5 = замедление x2 (диапазон: 0.25 - 4.0)"
$labelSpeedInfo.Font = New-Object System.Drawing.Font($labelSpeedInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$groupSpeed.Controls.Add($labelSpeedInfo)

# ========== Split Section ==========
$yPos = 515
$groupSplit = New-Object System.Windows.Forms.GroupBox
$groupSplit.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupSplit.Size = New-Object System.Drawing.Size(770, 106)
$groupSplit.Text = "Настройки разреза файлов"
$mainContainer.Controls.Add($groupSplit)

# Start Time
$labelStartTime = New-Object System.Windows.Forms.Label
$labelStartTime.Location = New-Object System.Drawing.Point(8, 18)
$labelStartTime.Size = New-Object System.Drawing.Size(130, 16)
$labelStartTime.Text = "Начало (чч-мм-сс):"
$groupSplit.Controls.Add($labelStartTime)

$checkStartTime = New-Object System.Windows.Forms.CheckBox
$checkStartTime.Location = New-Object System.Drawing.Point(140, 18)
$checkStartTime.Size = New-Object System.Drawing.Size(18, 18)
$checkStartTime.Checked = $_cfg_start.enabled
$groupSplit.Controls.Add($checkStartTime)

$textStartTime = New-Object System.Windows.Forms.TextBox
$textStartTime.Location = New-Object System.Drawing.Point(160, 18)
$textStartTime.Size = New-Object System.Drawing.Size(80, 20)
$textStartTime.Text = $_cfg_start.value
$groupSplit.Controls.Add($textStartTime)

# Duration
$labelDuration = New-Object System.Windows.Forms.Label
$labelDuration.Location = New-Object System.Drawing.Point(252, 18)
$labelDuration.Size = New-Object System.Drawing.Size(165, 16)
$labelDuration.Text = "Длительность (чч-мм-сс):"
$groupSplit.Controls.Add($labelDuration)

$checkDuration = New-Object System.Windows.Forms.CheckBox
$checkDuration.Location = New-Object System.Drawing.Point(420, 18)
$checkDuration.Size = New-Object System.Drawing.Size(18, 18)
$checkDuration.Checked = $_cfg_length.enabled
$groupSplit.Controls.Add($checkDuration)

$textDuration = New-Object System.Windows.Forms.TextBox
$textDuration.Location = New-Object System.Drawing.Point(440, 18)
$textDuration.Size = New-Object System.Drawing.Size(80, 20)
$textDuration.Text = $_cfg_length.value
$groupSplit.Controls.Add($textDuration)

# Split by Silence
$checkSplitSilence = New-Object System.Windows.Forms.CheckBox
$checkSplitSilence.Location = New-Object System.Drawing.Point(8, 42)
$checkSplitSilence.Size = New-Object System.Drawing.Size(145, 18)
$checkSplitSilence.Text = "Разрезать по тишине"
$checkSplitSilence.Checked = ($_cfg_split_silence -eq "yes")
$groupSplit.Controls.Add($checkSplitSilence)

# Silence Duration
$labelSilenceDuration = New-Object System.Windows.Forms.Label
$labelSilenceDuration.Location = New-Object System.Drawing.Point(160, 44)
$labelSilenceDuration.Size = New-Object System.Drawing.Size(115, 16)
$labelSilenceDuration.Text = "Мин. тишина (сек):"
$groupSplit.Controls.Add($labelSilenceDuration)

$textSilenceDuration = New-Object System.Windows.Forms.TextBox
$textSilenceDuration.Location = New-Object System.Drawing.Point(277, 42)
$textSilenceDuration.Size = New-Object System.Drawing.Size(45, 20)
$textSilenceDuration.Text = $_cfg_silence_duration
$groupSplit.Controls.Add($textSilenceDuration)

# Silence Threshold
$labelSilenceThreshold = New-Object System.Windows.Forms.Label
$labelSilenceThreshold.Location = New-Object System.Drawing.Point(330, 44)
$labelSilenceThreshold.Size = New-Object System.Drawing.Size(80, 16)
$labelSilenceThreshold.Text = "Порог тишины:"
$groupSplit.Controls.Add($labelSilenceThreshold)

$textSilenceThreshold = New-Object System.Windows.Forms.TextBox
$textSilenceThreshold.Location = New-Object System.Drawing.Point(413, 42)
$textSilenceThreshold.Size = New-Object System.Drawing.Size(55, 20)
$textSilenceThreshold.Text = $_cfg_silence_thresh
$groupSplit.Controls.Add($textSilenceThreshold)

# Split info
$labelSplitInfo = New-Object System.Windows.Forms.Label
$labelSplitInfo.Location = New-Object System.Drawing.Point(8, 66)
$labelSplitInfo.Size = New-Object System.Drawing.Size(750, 34)
$labelSplitInfo.Text = "Разрезать на части: включите длительность. Вырезать фрагмент: включите начало + длительность.`nОбрезать начало: включите только начало."
$labelSplitInfo.Font = New-Object System.Drawing.Font($labelSplitInfo.Font.FontFamily, 8, [System.Drawing.FontStyle]::Italic)
$groupSplit.Controls.Add($labelSplitInfo)

# ========== Other Settings (collapsible) ==========
$yPos = 625
$groupOther = New-Object System.Windows.Forms.GroupBox
$groupOther.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupOther.Size = New-Object System.Drawing.Size(770, 18)
$groupOther.Text = "Дополнительные настройки (нажмите, чтобы развернуть)"
$groupOther.Add_Click({
    if ($groupOther.Height -eq 18) {
        $groupOther.Height = 96
    } else {
        $groupOther.Height = 18
    }
    $form.Refresh()
})
$mainContainer.Controls.Add($groupOther)

# ffmpeg path (авто: ./ffmpeg.exe рядом со скриптом, иначе из PATH)
$_localFfmpeg = Join-Path $PSScriptRoot "ffmpeg.exe"
$textFFmpegPath = [PSCustomObject]@{ Text = if (Test-Path $_localFfmpeg) { $_localFfmpeg } else { "ffmpeg" } }

# Save Old Extension
$checkSaveExtension = New-Object System.Windows.Forms.CheckBox
$checkSaveExtension.Location = New-Object System.Drawing.Point(8, 18)
$checkSaveExtension.Size = New-Object System.Drawing.Size(400, 18)
$checkSaveExtension.Text = "Оставлять старое расширение файла в названии"
$checkSaveExtension.Checked = ($_cfg_save_ext -eq "yes")
$groupOther.Controls.Add($checkSaveExtension)

# Input Formats
$labelInputFormats = New-Object System.Windows.Forms.Label
$labelInputFormats.Location = New-Object System.Drawing.Point(8, 42)
$labelInputFormats.Size = New-Object System.Drawing.Size(100, 16)
$labelInputFormats.Text = "Формат файлов:"
$groupOther.Controls.Add($labelInputFormats)

$textInputFormats = New-Object System.Windows.Forms.TextBox
$textInputFormats.Location = New-Object System.Drawing.Point(110, 42)
$textInputFormats.Size = New-Object System.Drawing.Size(648, 20)
$textInputFormats.Text = $_cfg_formats
$groupOther.Controls.Add($textInputFormats)

# Subtitles Style
$labelSubtitlesStyle = New-Object System.Windows.Forms.Label
$labelSubtitlesStyle.Location = New-Object System.Drawing.Point(8, 66)
$labelSubtitlesStyle.Size = New-Object System.Drawing.Size(100, 16)
$labelSubtitlesStyle.Text = "Стиль субтитров:"
$groupOther.Controls.Add($labelSubtitlesStyle)

$textSubtitlesStyle = New-Object System.Windows.Forms.TextBox
$textSubtitlesStyle.Location = New-Object System.Drawing.Point(110, 66)
$textSubtitlesStyle.Size = New-Object System.Drawing.Size(648, 20)
$textSubtitlesStyle.Text = $_cfg_sub_style
$groupOther.Controls.Add($textSubtitlesStyle)

# ========== Buttons Row ==========
# Centered: Run(260) + gap(12) + Stop(170) = 442 total in 770px → left = (770-442)/2 = 164 → absolute x = xPos0+164 = 174
$yPos = 647

$buttonRun = New-Object System.Windows.Forms.Button
$buttonRun.Location = New-Object System.Drawing.Point(174, $yPos)
$buttonRun.Size = New-Object System.Drawing.Size(260, 30)
$buttonRun.Text = "Начать перекодирование"
$buttonRun.BackColor = [System.Drawing.Color]::LightGreen
$buttonRun.Font = New-Object System.Drawing.Font("Microsoft Sans Serif", 10, [System.Drawing.FontStyle]::Bold)
$mainContainer.Controls.Add($buttonRun)

$buttonStop = New-Object System.Windows.Forms.Button
$buttonStop.Location = New-Object System.Drawing.Point(446, $yPos)
$buttonStop.Size = New-Object System.Drawing.Size(170, 30)
$buttonStop.Text = "Остановить"
$buttonStop.Font = New-Object System.Drawing.Font($buttonStop.Font.FontFamily, 11, [System.Drawing.FontStyle]::Bold)
$buttonStop.ForeColor = [System.Drawing.Color]::DarkRed
$buttonStop.Enabled = $false
$buttonStop.Add_Click({
    # Записываем файл-флаг отмены
    try { "cancel" | Set-Content $env:FFMPEG_GUI_CANCEL_FILE -Encoding UTF8 } catch {}
})
$mainContainer.Controls.Add($buttonStop)

# ========== Progress Section ==========
$yPos = 681
$groupProgress = New-Object System.Windows.Forms.GroupBox
$groupProgress.Location = New-Object System.Drawing.Point($xPos0, $yPos)
$groupProgress.Size = New-Object System.Drawing.Size(770, 132)
$groupProgress.Text = "Прогресс"
$groupProgress.Font = New-Object System.Drawing.Font($groupProgress.Font, [System.Drawing.FontStyle]::Bold)
$mainContainer.Controls.Add($groupProgress)

# Current file label
$labelProgressFile = New-Object System.Windows.Forms.Label
$labelProgressFile.Location = New-Object System.Drawing.Point(8, 18)
$labelProgressFile.Size = New-Object System.Drawing.Size(750, 16)
$labelProgressFile.Text = ""
$labelProgressFile.Font = New-Object System.Drawing.Font($labelProgressFile.Font.FontFamily, 9, [System.Drawing.FontStyle]::Regular)
$groupProgress.Controls.Add($labelProgressFile)

# Progress bar — текущий файл
$progressBarFile = New-Object System.Windows.Forms.ProgressBar
$progressBarFile.Location = New-Object System.Drawing.Point(8, 38)
$progressBarFile.Size = New-Object System.Drawing.Size(750, 18)
$progressBarFile.Minimum = 0
$progressBarFile.Maximum = 100
$progressBarFile.Value = 0
$groupProgress.Controls.Add($progressBarFile)

# Progress label — всего файлов
$labelProgressTotal = New-Object System.Windows.Forms.Label
$labelProgressTotal.Location = New-Object System.Drawing.Point(8, 60)
$labelProgressTotal.Size = New-Object System.Drawing.Size(750, 16)
$labelProgressTotal.Text = ""
$labelProgressTotal.Font = New-Object System.Drawing.Font($labelProgressTotal.Font.FontFamily, 9, [System.Drawing.FontStyle]::Regular)
$groupProgress.Controls.Add($labelProgressTotal)

# Progress bar — всего файлов
$progressBarTotal = New-Object System.Windows.Forms.ProgressBar
$progressBarTotal.Location = New-Object System.Drawing.Point(8, 80)
$progressBarTotal.Size = New-Object System.Drawing.Size(750, 18)
$progressBarTotal.Minimum = 0
$progressBarTotal.Maximum = 100
$progressBarTotal.Value = 0
$groupProgress.Controls.Add($progressBarTotal)

# Summary label
$labelProgressSummary = New-Object System.Windows.Forms.Label
$labelProgressSummary.Location = New-Object System.Drawing.Point(8, 104)
$labelProgressSummary.Size = New-Object System.Drawing.Size(750, 16)
$labelProgressSummary.Text = ""
$labelProgressSummary.Font = New-Object System.Drawing.Font($labelProgressSummary.Font.FontFamily, 8, [System.Drawing.FontStyle]::Regular)
$groupProgress.Controls.Add($labelProgressSummary)

# ========== Run Button Click Handler ==========
$buttonRun.Add_Click({
    # ---- Собрать все настройки ----
    $script:folder_sources      = $textInputFolder.Text
    $script:folder_destination  = $textOutputFolder.Text

    # options
    $script:audio_only          = if ($checkSaveAudio.Checked)   { "yes" } else { "no" }
    $script:merge_files         = if ($checkMergeFiles.Checked)  { "yes" } else { "no" }
    $script:create_frame        = if ($checkCreateFrames.Checked) { "yes" } else { "no" }
    $script:copy_codecs         = if ($checkCopyCodecs.Checked)  { "yes" } else { "no" }
    $script:multithreads        = if ($checkMultithreads.Checked) { ":+:$($textThreads.Text)" } else { ":-:1" }
    $script:parallel_files      = ":-:1"
    $script:dry_run             = if ($checkDryRun.Checked)      { "yes" } else { "no" }
    $script:enable_log          = if ($checkLog.Checked)         { "yes" } else { "no" }
    $script:log_file            = "ffmpeg_convert.log"
    $script:extract_audio_copy  = if ($checkExtractAudioCopy.Checked) { "yes" } else { "no" }

    # Audio settings
    $script:audio_codec          = if ($checkAudioCodec.Checked)      { ":+:$($comboAudioCodec.SelectedItem)" }    else { ":-:$($comboAudioCodec.SelectedItem)" }
    $script:audio_number_channels = if ($checkAudioChannels.Checked)  { ":+:$($comboAudioChannels.SelectedIndex + 1)" } else { ":-:$($comboAudioChannels.SelectedIndex + 1)" }
    $script:audio_bitrate        = if ($checkAudioBitrate.Checked)    { ":+:$($textAudioBitrate.Text)" }           else { ":-:$($textAudioBitrate.Text)" }
    $script:audio_sampling_rate  = if ($checkAudioSampleRate.Checked)  { ":+:$($textAudioSampleRate.Text)" }        else { ":-:$($textAudioSampleRate.Text)" }
    $script:audio_normalize      = if ($checkAudioNorm.Checked)       { ":+:$($comboAudioNorm.SelectedItem)" }     else { ":-:$($comboAudioNorm.SelectedItem)" }

    # Video settings
    $script:video_codec          = if ($checkVideoCodec.Checked)      { ":+:$($comboVideoCodec.SelectedItem)" }    else { ":-:$($comboVideoCodec.SelectedItem)" }
    $script:video_resolution     = if ($checkVideoResolution.Checked) { ":+:$($comboVideoResolution.SelectedItem)" } else { ":-:$($comboVideoResolution.SelectedItem)" }
    $script:video_bitrate        = if ($checkVideoBitrate.Checked)    { ":+:$($textVideoBitrate.Text)" }           else { ":-:$($textVideoBitrate.Text)" }
    $script:video_number_frames  = if ($checkFrameRate.Checked)       { ":+:$($textFrameRate.Text)" }              else { ":-:$($textFrameRate.Text)" }
    $script:video_rotation       = if ($checkVideoRotation.Checked)   { ":+:$($comboVideoRotation.SelectedIndex + 1)" } else { ":-:$($comboVideoRotation.SelectedIndex + 1)" }
    $script:video_quality        = if ($checkVideoQuality.Checked)    { ":+:$($textVideoQuality.Text)" }           else { ":-:$($textVideoQuality.Text)" }
    $script:keep_aspect_ratio    = if ($checkKeepAspect.Checked)      { ":+:yes" }                                 else { ":-:no" }
    $script:output_container     = if ($checkContainer.Checked)       { ":+:$($comboContainer.SelectedItem)" }     else { ":-:$($comboContainer.SelectedItem)" }

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
    if (!(Test-Path $script:folder_sources)) {
        [System.Windows.Forms.MessageBox]::Show("Папка источника не найдена:`n$($script:folder_sources)", "Ошибка", "OK", "Error")
        return
    }

    # ---- Подготовка прогресса ----
    $progressFile = [System.IO.Path]::GetTempFileName()
    $cancelFile   = [System.IO.Path]::GetTempFileName()
    Remove-Item $cancelFile -Force -ErrorAction SilentlyContinue  # удаляем, пусть не существует

    $env:FFMPEG_GUI_PROGRESS_FILE = $progressFile
    $env:FFMPEG_GUI_CANCEL_FILE   = $cancelFile

    $buttonRun.Enabled  = $false
    $buttonStop.Enabled = $true
    $progressBarFile.Value  = 0
    $progressBarTotal.Value = 0
    $labelProgressFile.Text    = "Запуск..."
    $labelProgressTotal.Text   = ""
    $labelProgressSummary.Text = ""

    # ---- Запуск script.ps1 в фоновом Runspace ----
    $scriptPath = Join-Path $PSScriptRoot "FFmpeg_Converter_script.ps1"

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
    $rs.SessionStateProxy.SetVariable("PSScriptRoot", $PSScriptRoot)

    $ps = [System.Management.Automation.PowerShell]::Create()
    $ps.Runspace = $rs
    $ps.AddScript(". '$scriptPath'") | Out-Null
    $global:_guiHandle    = $ps.BeginInvoke()
    $global:_guiPS        = $ps
    $global:_guiRunspace  = $rs
    $global:_guiProgress  = $progressFile
    $global:_guiCancel    = $cancelFile

    # ---- Таймер для обновления UI ----
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 400
    $timer.Add_Tick({
        # Проверяем, завершился ли фоновый процесс
        if ($global:_guiHandle.IsCompleted) {
            $timer.Stop()

            # Читаем финальное состояние
            try {
                $json = Get-Content $global:_guiProgress -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                if ($json) {
                    $progressBarFile.Value  = 100
                    $progressBarTotal.Value = 100
                    $labelProgressFile.Text = "Готово"
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
            if (Test-Path $global:_guiProgress) {
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
            }
        } catch {}
    })
    $timer.Start()
})

# ========== Получить версию ffmpeg при открытии формы ==========
$form.Add_Shown({
    try {
        $ffmpegBin = $textFFmpegPath.Text
        $versionLine = & $ffmpegBin -version 2>&1 | Select-Object -First 1
        if ($versionLine -match 'ffmpeg version (\S+)') {
            $script:ffmpegCurrentVersion = $Matches[1]
            $lblFfmpegVersion.Text      = "ffmpeg: $($Matches[1])"
            $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::DarkGreen
        } else {
            $lblFfmpegVersion.Text      = "ffmpeg: не найден в PATH"
            $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::Firebrick
        }
    }
    catch {
        $lblFfmpegVersion.Text      = "ffmpeg: не найден в PATH"
        $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::Firebrick
    }
})

# ========== Show Form ==========
$form.ShowDialog() | Out-Null
