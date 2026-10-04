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
    # Ограничение по времени: зависший ffmpeg-probe не морозит UI-поток бесконечно.
    try {
        $psi = [System.Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $Bin
        $psi.Arguments = "-hide_banner -loglevel error -f lavfi -i color=size=64x64:duration=0.1:rate=1 -c:v $Encoder -f null -"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardOutput = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        # Оба перенаправленных потока обязательно ДРЕНИРУЕМ. Буфер пайпа — 4 КБ; probe
        # с непривычной сборкой ffmpeg легко переполняет его диагностикой, дочерний
        # процесс блокируется на записи, WaitForExit истекает — и доступный энкодер
        # объявлялся недоступным («переключено на CPU») без единого объяснения.
        # ReadToEndAsync стартуем ДО ожидания, иначе дедлок просто переезжает.
        $tErr = $p.StandardError.ReadToEndAsync()
        $tOut = $p.StandardOutput.ReadToEndAsync()
        if (-not $p.WaitForExit(5000)) { try { $p.Kill() } catch {}; return $false }
        try { $tErr.Wait(1000) | Out-Null; $tOut.Wait(1000) | Out-Null } catch {}
        return ($p.ExitCode -eq 0)
    } catch {
        return $false
    }
}

# --- Фallback для $PSScriptRoot при запуске из ps2exe-экзешника ---
$script:_appDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($script:_appDir)) {
    $script:_appDir = Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Кавычки вокруг значения — обычный результат «Копировать как путь» в проводнике
# Windows. Без снятия путь «"C:/video/in"» не находился ни на одной платформе, а
# PS1 вдобавок падал исключением IsPathRooted. Паритет с Remove-ConfigQuotes в CLI.
function Remove-ConfigQuotes {
    param([string]$Value)
    $v = $Value.Trim()
    if ($v.Length -ge 2) {
        if (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'")) {
            return $v.Substring(1, $v.Length - 2)
        }
    }
    return $v
}

# Подстановка ${ENV_VAR} — алгоритм read_config из .sh, :expand_env из .cmd и
# Expand-ConfigEnv из CLI-PS1: имя обязано быть идентификатором, иначе WARN и
# значение остаётся как есть; не более 32 подстановок. Предупреждения КОПЯТСЯ и
# показываются одним окном после открытия формы: в EXE (-noConsole) Write-Host
# превращается в MessageBox на КАЖДЫЙ вызов, ещё до появления окна.
$script:configWarnings = @()
function Expand-ConfigEnv {
    param([string]$Value, [bool]$Quiet)
    for ($i = 0; $i -lt 32; $i++) {
        $m = [regex]::Match($Value, '\$\{([^}]*)\}')
        if (-not $m.Success) { break }
        $vn = $m.Groups[1].Value
        if (-not [regex]::IsMatch($vn, '^[A-Za-z_][A-Za-z0-9_]*$')) {
            $script:configWarnings += "WARN: '`${$vn}' — недопустимое имя переменной окружения, оставлено как есть"
            break
        }
        $ev = [Environment]::GetEnvironmentVariable($vn)
        if ([string]::IsNullOrEmpty($ev)) {
            if (-not $Quiet) { $script:configWarnings += "WARN: переменная $vn не задана" }
            $ev = ''
        }
        $Value = $Value.Replace('${' + $vn + '}', $ev)
    }
    return $Value
}

# --- Чтение config.ini (один раз в хеш-таблицу) ---
$configFile = Join-Path $script:_appDir "config.ini"
$script:_configCache = @{}
if (Test-Path -LiteralPath $configFile) {
    $curSection = ""
    foreach ($line in (Get-Content -LiteralPath $configFile -Encoding UTF8)) {
        $line = $line.Trim()
        if ([string]::IsNullOrEmpty($line) -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $curSection = $Matches[1]
            continue
        }
        if ($curSection -and $line -match '^([^=]+?)\s*=\s*(.*)') {
            $val = $Matches[2] -replace '\s+#.*', ''
            # Подстановка ${ENV_VAR} из окружения (паритет с yt-dlp/CLI). Не задана → пусто + WARN.
            # Кроме секции [remote]: там TRANSCODE_URL/TRANSCODE_API_KEY не заданы у всех,
            # кто удалённым бэкендом не пользуется, и WARN сыпался бы при каждом старте GUI.
            $val = Expand-ConfigEnv $val ($curSection -eq 'remote' -or $curSection -eq 'asr')
            # ContainsKey-guard = ПЕРВОЕ вхождение ключа. Раньше здесь побеждало
            # ПОСЛЕДНЕЕ, а CLI-PS1 и .sh брали первое: один config.ini с дублем
            # `codec` давал libx264 из CLI и libx265 из GUI — молча.
            $_ck = "${curSection}::$($Matches[1].Trim())"
            if (-not $script:_configCache.ContainsKey($_ck)) {
                $script:_configCache[$_ck] = (Remove-ConfigQuotes $val)
            }
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

# Выбор пункта списка по значению config.ini. Значение пункта — первое слово его
# текста ("2 - Stereo" → "2"). Раньше всё, что не "1", молча становилось вторым
# пунктом: `channels = +6` давал в GUI стерео, а CLI с тем же config.ini — `-ac 6`.
# Допустимое для ffmpeg значение вне списка добавляется пунктом «из config.ini» и
# уходит в воркер как есть (паритет с CLI); недопустимое — откат на $Default.
# Оба случая попадают в $script:configWarnings: молча расходиться с CLI нельзя.
function Select-ConfigComboValue {
    param($Combo, [string]$Value, [string]$Key, [string]$ValidPattern, [string]$Default)
    $v = "$Value".Trim()
    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ((([string]$Combo.Items[$i]) -split ' ')[0] -eq $v) { $Combo.SelectedIndex = $i; return }
    }
    if ($v -match $ValidPattern) {
        $Combo.SelectedIndex = $Combo.Items.Add("$v - из config.ini")
        $script:configWarnings += "WARN: $Key = $v — такого пункта в списке нет, добавлен «$v - из config.ini»"
        return
    }
    for ($i = 0; $i -lt $Combo.Items.Count; $i++) {
        if ((([string]$Combo.Items[$i]) -split ' ')[0] -eq $Default) { $Combo.SelectedIndex = $i; break }
    }
    $script:configWarnings += "WARN: $Key = '$Value' — недопустимое значение, в форме выбрано $Default"
}

# То же для списка, где текст пункта не начинается со значения («NVIDIA (NVENC)»):
# пункт ищется по таблице «значение → индекс». Ключи @{} без учёта регистра — как
# switch воркера. Неизвестное значение — $Default и предупреждение, не молча.
function Select-ConfigComboMapped {
    param($Combo, [string]$Value, [string]$Key, [hashtable]$Map, [int]$Default)
    $v = "$Value".Trim()
    if ($Map.ContainsKey($v)) { $Combo.SelectedIndex = $Map[$v]; return }
    $Combo.SelectedIndex = $Default
    $script:configWarnings += "WARN: $Key = '$Value' — недопустимое значение, в форме выбрано «$($Combo.Items[$Default])»"
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
$_cfg_overwrite_existing = Read-Config "overwrite_existing" "options" "no"

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
# parallel_files — SH-only. GUI обязан прочитать ключ и предупредить: один и тот же
# config.ini не имеет права молча значить разное на разных платформах (то же делают
# CLI-PS1 и CMD). Контрола в форме нет намеренно — включать нечего.
# Умолчание обязано совпадать с остальными платформами («-2» в CLI-PS1, CMD и SH):
# значение уезжает в воркер и печатается в предупреждении, поэтому config.ini без
# ключа давал на GUI другой текст, чем на тех же исходных данных в CLI.
$_cfg_parallel = Parse-Flag (Read-Config "parallel_files" "performance" "-2")
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
# Адрес и ключ ЧИТАЮТСЯ, но не редактируются: GUI показывает лишь «задано/не задано».
# Менять их можно только переменными окружения TRANSCODE_URL/TRANSCODE_API_KEY.
$_cfg_remote_on    = Read-Config "enabled" "remote" "no"
$_cfg_remote_ep    = Read-Config "endpoint" "remote" ""
$_cfg_remote_key   = Read-Config "api_key" "remote" ""
$_cfg_remote_pref  = Read-Config "prefer" "remote" "auto"
$_cfg_remote_wait  = Read-Config "wait_timeout" "remote" "1800"
$_cfg_remote_stall = Read-Config "stall_timeout" "remote" "900"
# Своих полей у этих двух в форме нет: api_key_command может спрашивать пароль,
# а on_failure меняет политику отказов — обоим место в config.ini, а не в
# галочке, которую поставили один раз и забыли. Читаем и передаём как есть.
$_cfg_remote_keycmd = Read-Config "api_key_command" "remote" ""
$_cfg_remote_onfail = Read-Config "on_failure" "remote" "abort"
# Распознавание речи. Адрес и ключ — в полях формы (начальные значения отсюда);
# api_key_command и pinned_pubkey полей не имеют: команда может спрашивать пароль,
# а пин — свойство сервера, а не запуска. Читаем и передаём как есть.
$_cfg_asr_on      = Read-Config "enabled" "asr" "no"
$_cfg_asr_ep      = Read-Config "endpoint" "asr" ""
$_cfg_asr_key     = Read-Config "api_key" "asr" ""
$_cfg_asr_keycmd  = Read-Config "api_key_command" "asr" ""
$_cfg_asr_pin     = Read-Config "pinned_pubkey" "asr" ""
$_cfg_asr_lang    = Read-Config "language" "asr" "ru"
$_cfg_asr_diarize = Read-Config "diarize" "asr" "yes"
$_cfg_asr_spk     = Read-Config "num_speakers" "asr" ""
$_cfg_formats      = Read-Config "format_files_in"    "other" "3gp,avi,flv,mp4,mpg,mpeg,wmv,mov,asf,mkv,m4v,webm,mts,vob,m4b,mp3,wma,ogg,m4a,aac"
$_cfg_sub_style    = Read-Config "subtitles_style"    "other" "FontName=Arial,FontSize=24,PrimaryColour=&HFFFFFF&"
$_cfg_dry_run      = Read-Config "dry_run"            "other" "no"
$_cfg_log          = Read-Config "enable_log"         "other" "no"
$_cfg_log_file     = Read-Config "log_file"           "other" "ffmpeg_convert.log"
# F5. Относительный log_file резолвим от папки приложения — тем же правилом, что source/
# destination выше и не-GUI wrappers (run.ps1 F28). Иначе Add-Content в worker'е пишет
# относительно $PWD: при запуске EXE через ярлык лог уходит в неожиданный каталог,
# нарушая контракт относительных путей и паритет с CLI-обёртками.
if (-not [System.IO.Path]::IsPathRooted($_cfg_log_file)) { $_cfg_log_file = Join-Path $script:_appDir $_cfg_log_file }

# Main Form
$form = [System.Windows.Forms.Form]::new()
$form.Text = "Video Converter (ffmpeg) v19"
$form.Size = [System.Drawing.Size]::new(820, 1022)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
# Двойная буферизация формы не включается: соответствующее свойство у Control
# защищённое, добраться до него можно только рефлексией к непубличному члену, а такая
# конструкция подпадает под эвристики антивирусов. Подкласс через компиляцию C# на лету
# — то же самое. Разбор: wiki, incident-amsi-doublebuffered-reflection-2026-08-19.
# Плата — лёгкое мерцание при перерисовке; частично гасится SuspendLayout/ResumeLayout.
$form.SuspendLayout()
$_fc = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()
$_mc = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# Main container
$mainContainer = [System.Windows.Forms.Panel]::new()
$mainContainer.Location = [System.Drawing.Point]::new(10, 36)
$mainContainer.Size = [System.Drawing.Size]::new(790, 947)
$mainContainer.AutoScroll = $true
$mainContainer.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
$_fc.Add($mainContainer)

# ========== Version strip (directly on form, above mainContainer) ==========
$lblFfmpegVersion = [System.Windows.Forms.Label]::new()
$lblFfmpegVersion.Location  = [System.Drawing.Point]::new(20, 13)
$lblFfmpegVersion.Size      = [System.Drawing.Size]::new(390, 18)
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
$btnCheckFfmpeg.Location = [System.Drawing.Point]::new(550, 10)
$btnCheckFfmpeg.Size     = [System.Drawing.Size]::new(240, 22)
$btnCheckFfmpeg.Text     = "Проверить обновления"
$btnCheckFfmpeg.Font     = [System.Drawing.Font]::new("Segoe UI", 8)
$btnCheckFfmpeg.Add_Click({
    $btnCheckFfmpeg.Enabled = $false
    $btnCheckFfmpeg.Text    = "Запрос..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $resp = $null; $rdr = $null
    try {
        Ensure-SslBypass
        # WebClient без таймаута висит ~100 с на UI-потоке при сетевых проблемах.
        # Подкласса с Timeout здесь нет и не будет: компиляция C# на лету
        # (`Add-Type -TypeDefinition` / позиционная `Add-Type @"…"@`) запрещена
        # в этом репозитории наравне с рефлексией к непубличным членам — она
        # поднимает тот же heuristic score, из-за которого Касперский блокировал
        # v17 целиком (docs/knowledge-base.md, «kaspersky-workaround»).
        # HttpWebRequest даёт Timeout штатным свойством, без единой строки C#.
        $req = [System.Net.HttpWebRequest]::Create("https://www.gyan.dev/ffmpeg/builds/release-version")
        $req.Method    = "GET"
        $req.Timeout   = 8000
        $req.ReadWriteTimeout = 8000
        $req.UserAgent = "ffmpeg-gui/1.0"
        $req.Proxy     = [System.Net.WebRequest]::GetSystemWebProxy()
        $req.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        $req.UseDefaultCredentials = $true
        $resp = $req.GetResponse()
        $rdr  = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $latestVer = $rdr.ReadToEnd().Trim()
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
        if ($rdr)  { try { $rdr.Dispose() }  catch {}; $rdr  = $null }
        if ($resp) { try { $resp.Dispose() } catch {}; $resp = $null }
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

# overwrite_existing раньше не имел контрола: значение читалось из config.ini и молча
# уходило в runspace. Пользователь GUI не видел его состояния и не мог перекодировать
# файл с новыми настройками — готовый выход просто пропускался без объяснения причины.
$checkOverwrite = [System.Windows.Forms.CheckBox]::new()
$checkOverwrite.Location = [System.Drawing.Point]::new(568, 62)
$checkOverwrite.Size = [System.Drawing.Size]::new(197, 20)
$checkOverwrite.Text = "Перезаписывать существующие"
$checkOverwrite.Checked = ($_cfg_overwrite_existing -eq "yes")
$_go.Add($checkOverwrite)

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
# Опечатка (+nvida, +amd) раньше молча давала «Без ускорения»; воркер на ней
# хотя бы предупреждает. off — документированное значение config.ini.example.
if ($_cfg_hw_accel.enabled) {
    Select-ConfigComboMapped $comboHWAccel $_cfg_hw_accel.value "[gpu] hw_accel" @{ nvidia = 1; intel = 2; off = 0 } 0
} else {
    $comboHWAccel.SelectedIndex = 0
}
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
# Включённое в config.ini значение вне списка раньше молча становилось p5/medium/
# hq/vbr, а CLI отдаёт его ffmpeg как есть. Шаблоны — значения, которые принимает
# энкодер (NVENC знает и прежние имена пресетов, а tune uhq и rc *_hq в список не
# вынесены): такое добавляется пунктом «из config.ini», прочее — откат с WARN.
# Выключенное значение CLI не использует — его, как и раньше, берём без проверки.
if ($comboHWAccel.SelectedIndex -eq 2) {
    $comboGpuPreset.Items.Clear()
    $comboGpuPreset.Items.AddRange(@("veryfast", "faster", "fast", "medium", "slow", "slower", "veryslow"))
    if ($_cfg_gpu_preset.enabled) {
        Select-ConfigComboValue $comboGpuPreset $_cfg_gpu_preset.value "[gpu] preset" '^(veryfast|faster|fast|medium|slow|slower|veryslow)$' "medium"
    } else {
        $idx = $comboGpuPreset.Items.IndexOf($_cfg_gpu_preset.value)
        $comboGpuPreset.SelectedIndex = if ($idx -ge 0) { $idx } else { 3 }
    }
    $comboGpuPreset.Visible = $true
    $labelGpuPreset.Visible = $true
} elseif ($comboHWAccel.SelectedIndex -eq 1) {
    if ($_cfg_gpu_preset.enabled) {
        Select-ConfigComboValue $comboGpuPreset $_cfg_gpu_preset.value "[gpu] preset" '^(p[1-7]|default|slow|medium|fast|hp|hq|bd|ll|llhq|llhp|lossless|losslesshp)$' "p5"
    } else {
        $idx = $comboGpuPreset.Items.IndexOf($_cfg_gpu_preset.value)
        if ($idx -ge 0) { $comboGpuPreset.SelectedIndex = $idx }
    }
    $comboGpuPreset.Visible = $true
    $labelGpuPreset.Visible = $true
    $comboGpuTune.Visible = $true; $labelGpuTune.Visible = $true
    $comboGpuRC.Visible = $true; $labelGpuRC.Visible = $true
}
# Инициализация tune/rc из config
if ($_cfg_gpu_tune.enabled) {
    Select-ConfigComboValue $comboGpuTune $_cfg_gpu_tune.value "[gpu] tune" '^(hq|uhq|ll|ull|lossless)$' "hq"
} else {
    $idxTune = $comboGpuTune.Items.IndexOf($_cfg_gpu_tune.value)
    if ($idxTune -ge 0) { $comboGpuTune.SelectedIndex = $idxTune }
}
if ($_cfg_gpu_rc.enabled) {
    Select-ConfigComboValue $comboGpuRC $_cfg_gpu_rc.value "[gpu] rc" '^(constqp|vbr|cbr|cbr_ld_hq|cbr_hq|vbr_hq|vbr_minqp|ll_2pass_quality|ll_2pass_size|vbr_2pass)$' "vbr"
} else {
    $idxRC = $comboGpuRC.Items.IndexOf($_cfg_gpu_rc.value)
    if ($idxRC -ge 0) { $comboGpuRC.SelectedIndex = $idxRC }
}

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
# Значение берётся из ВЫБРАННОГО пункта, поэтому список обязан быть
# нередактируемым: набранный руками текст оставлял SelectedIndex = -1, и в
# конфиг уезжало `-ac 0` / `transpose=` — ffmpeg падал на каждом файле.
$comboAudioChannels.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboAudioChannels.Items.AddRange(@("1 - Mono", "2 - Stereo"))
# Каналы: любое целое >= 1 (ffmpeg -ac), ведущие нули не в счёт.
Select-ConfigComboValue $comboAudioChannels $_cfg_audio_channels.value "[audio] channels" '^0*[1-9]\d*$' "2"
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
# Значение берётся ПО ИНДЕКСУ выбранного пункта, поэтому список обязан быть
# нередактируемым: набранный руками текст оставлял SelectedIndex = -1, и в
# конфиг уезжало `-ac 0` / `transpose=` — ffmpeg падал на каждом файле.
$comboVideoRotation.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboVideoRotation.Items.AddRange(@("1 - По часовой", "2 - Против часовой"))
# Поворот: 0..3 — все значения фильтра transpose (0 и 3 — с отражением).
Select-ConfigComboValue $comboVideoRotation $_cfg_video_rotation.value "[video] rotation" '^[0-3]$' "2"
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
# Значение берётся ПО ИНДЕКСУ выбранного пункта, поэтому список обязан быть
# нередактируемым: набранный руками текст оставлял SelectedIndex = -1, и в
# конфиг уезжало `-ac 0` / `transpose=` — ffmpeg падал на каждом файле.
$comboSubtitlesMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$comboSubtitlesMode.Items.AddRange(@("burn - На видео", "meta - Дорожкой"))
# Воркер знает только burn и meta; иное значение он молча не применяет вовсе, а
# GUI раньше так же молча выбирал burn и прожигал титры. Теперь — откат с WARN.
Select-ConfigComboValue $comboSubtitlesMode $_cfg_video_subtitles.value "[video] subtitles" '^(burn|meta)$' "burn"
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
$labelSpeedInfo.Text = "1.0 = норм, 2.0 = ускорение x2, 0.5 = замедление x2 (диапазон: больше 0 и не больше 100)"
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
$labelSilenceThreshold.Size = [System.Drawing.Size]::new(86, 16)
$labelSilenceThreshold.Text = "Порог тишины:"
$_gspl.Add($labelSilenceThreshold)

$textSilenceThreshold = [System.Windows.Forms.TextBox]::new()
$textSilenceThreshold.Location = [System.Drawing.Point]::new(416, 42)
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

# ========== Сервер конвертации ==========
# Группа стоит в ОСНОВНЫХ настройках, а не в спойлере: адрес и ключ нужно видеть
# и проверять до запуска, а спрятанная за «нажмите, чтобы развернуть» галка
# «Считать на сервере» неотличима от выключенной. Всё, что ниже (кнопки,
# прогресс), сдвинуто на высоту этой группы — Y там заданы абсолютными числами.
$yPos = 530
# Адрес и ключ берутся из config.ini (он gitignored — та же схема, что у yt-dlp,
# поэтому приватное значение лежит там открытым текстом и в репозиторий не уедет).
# Правка в полях действует на текущий запуск: GUI конфиг не переписывает, как и
# GUI yt-dlp. Постоянное значение задаётся в самом config.ini.
$grpRemote = [System.Windows.Forms.GroupBox]::new()
$grpRemote.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$grpRemote.Size = [System.Drawing.Size]::new(770, 92)
$grpRemote.Text = "Сервер конвертации"

$chkRemote = [System.Windows.Forms.CheckBox]::new()
$chkRemote.Location = [System.Drawing.Point]::new(8, 18)
$chkRemote.Size = [System.Drawing.Size]::new(300, 18)
$chkRemote.Text = "Считать на сервере"
$chkRemote.Checked = ($_cfg_remote_on -eq "yes")

$lblRemotePrefer = [System.Windows.Forms.Label]::new()
$lblRemotePrefer.Location = [System.Drawing.Point]::new(320, 20)
$lblRemotePrefer.Size = [System.Drawing.Size]::new(60, 16)
$lblRemotePrefer.Text = "Считать:"

$cmbRemotePrefer = [System.Windows.Forms.ComboBox]::new()
$cmbRemotePrefer.Location = [System.Drawing.Point]::new(382, 17)
$cmbRemotePrefer.Size = [System.Drawing.Size]::new(90, 20)
$cmbRemotePrefer.DropDownStyle = 'DropDownList'
[void]$cmbRemotePrefer.Items.AddRange(@("auto", "gpu", "cpu"))
# Пустое значение воркер читает как auto, иное вне трёх — отказ preflight'а; GUI
# раньше молча подставлял auto и считал там, где CLI с тем же config.ini отказал бы.
if (-not $_cfg_remote_pref) { $_cfg_remote_pref = "auto" }
Select-ConfigComboValue $cmbRemotePrefer $_cfg_remote_pref "[remote] prefer" '^(auto|gpu|cpu)$' "auto"

$lblRemoteWait = [System.Windows.Forms.Label]::new()
$lblRemoteWait.Location = [System.Drawing.Point]::new(488, 20)
$lblRemoteWait.Size = [System.Drawing.Size]::new(126, 16)
$lblRemoteWait.Text = "Ждать карту, сек:"

$txtRemoteWait = [System.Windows.Forms.TextBox]::new()
$txtRemoteWait.Location = [System.Drawing.Point]::new(616, 17)
$txtRemoteWait.Size = [System.Drawing.Size]::new(70, 20)
$txtRemoteWait.Text = $_cfg_remote_wait

$lblRemoteEndpoint = [System.Windows.Forms.Label]::new()
$lblRemoteEndpoint.Location = [System.Drawing.Point]::new(8, 49)
$lblRemoteEndpoint.Size = [System.Drawing.Size]::new(52, 16)
$lblRemoteEndpoint.Text = "Адрес:"

$txtRemoteEndpoint = [System.Windows.Forms.TextBox]::new()
$txtRemoteEndpoint.Location = [System.Drawing.Point]::new(62, 46)
$txtRemoteEndpoint.Size = [System.Drawing.Size]::new(400, 20)
$txtRemoteEndpoint.Text = $_cfg_remote_ep

$lblRemoteApiKey = [System.Windows.Forms.Label]::new()
$lblRemoteApiKey.Location = [System.Drawing.Point]::new(470, 49)
$lblRemoteApiKey.Size = [System.Drawing.Size]::new(44, 16)
$lblRemoteApiKey.Text = "Ключ:"

$txtRemoteApiKey = [System.Windows.Forms.TextBox]::new()
$txtRemoteApiKey.Location = [System.Drawing.Point]::new(518, 46)
$txtRemoteApiKey.Size = [System.Drawing.Size]::new(200, 20)
# Ключ не должен читаться через плечо и попадать на скриншоты окна.
$txtRemoteApiKey.UseSystemPasswordChar = $true
$txtRemoteApiKey.Text = $_cfg_remote_key

$grpRemote.Controls.AddRange(@($chkRemote, $lblRemotePrefer, $cmbRemotePrefer, $lblRemoteWait, $txtRemoteWait,
	$lblRemoteEndpoint, $txtRemoteEndpoint, $lblRemoteApiKey, $txtRemoteApiKey))
$_regFont = $grpRemote.Font
$grpRemote.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $grpRemote.Controls) { $c.Font = $_regFont }
$_mc.Add($grpRemote)

# ========== Распознавание речи (ASR) ==========
# Отдельный режим: файлы источника не перекодируются, а расшифровываются на
# сервере распознавания. Как и группа сервера конвертации — в основных
# настройках: адрес и ключ видны до запуска. Правка полей действует на текущий
# запуск — config.ini GUI не переписывает. Всё ниже сдвинуто на высоту группы.
$yPos = 626
$grpAsr = [System.Windows.Forms.GroupBox]::new()
$grpAsr.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$grpAsr.Size = [System.Drawing.Size]::new(770, 72)
$grpAsr.Text = "Распознавание речи (ASR)"

$chkAsr = [System.Windows.Forms.CheckBox]::new()
$chkAsr.Location = [System.Drawing.Point]::new(8, 18)
$chkAsr.Size = [System.Drawing.Size]::new(262, 18)
$chkAsr.Text = "Расшифровать вместо конвертации"
$chkAsr.Checked = ($_cfg_asr_on -eq "yes")

$lblAsrLang = [System.Windows.Forms.Label]::new()
$lblAsrLang.Location = [System.Drawing.Point]::new(280, 20)
$lblAsrLang.Size = [System.Drawing.Size]::new(40, 16)
$lblAsrLang.Text = "Язык:"

$cmbAsrLang = [System.Windows.Forms.ComboBox]::new()
$cmbAsrLang.Location = [System.Drawing.Point]::new(322, 17)
$cmbAsrLang.Size = [System.Drawing.Size]::new(56, 20)
$cmbAsrLang.DropDownStyle = 'DropDownList'
[void]$cmbAsrLang.Items.AddRange(@("ru", "en"))
if ($_cfg_asr_lang -and -not $cmbAsrLang.Items.Contains($_cfg_asr_lang)) { [void]$cmbAsrLang.Items.Add($_cfg_asr_lang) }
$cmbAsrLang.SelectedItem = $_cfg_asr_lang
if ($null -eq $cmbAsrLang.SelectedItem) {
    $cmbAsrLang.SelectedIndex = 0
    # Сюда попадает только пустое значение (непустое добавлено пунктом выше); CLI
    # на нём отказывает «[asr] language пуст», поэтому подстановку ru не скрываем.
    $script:configWarnings += "WARN: [asr] language пуст — в форме выбрано $($cmbAsrLang.SelectedItem)"
}

$chkAsrDiarize = [System.Windows.Forms.CheckBox]::new()
$chkAsrDiarize.Location = [System.Drawing.Point]::new(392, 18)
$chkAsrDiarize.Size = [System.Drawing.Size]::new(150, 18)
$chkAsrDiarize.Text = "Размечать говорящих"
$chkAsrDiarize.Checked = ($_cfg_asr_diarize -ne "no")

$lblAsrSpeakers = [System.Windows.Forms.Label]::new()
$lblAsrSpeakers.Location = [System.Drawing.Point]::new(548, 20)
$lblAsrSpeakers.Size = [System.Drawing.Size]::new(114, 16)
$lblAsrSpeakers.Text = "Сколько говорящих:"

$txtAsrSpeakers = [System.Windows.Forms.TextBox]::new()
$txtAsrSpeakers.Location = [System.Drawing.Point]::new(664, 17)
$txtAsrSpeakers.Size = [System.Drawing.Size]::new(40, 20)
$txtAsrSpeakers.Text = $_cfg_asr_spk

$lblAsrEndpoint = [System.Windows.Forms.Label]::new()
$lblAsrEndpoint.Location = [System.Drawing.Point]::new(8, 47)
$lblAsrEndpoint.Size = [System.Drawing.Size]::new(52, 16)
$lblAsrEndpoint.Text = "Адрес:"

$txtAsrEndpoint = [System.Windows.Forms.TextBox]::new()
$txtAsrEndpoint.Location = [System.Drawing.Point]::new(62, 44)
$txtAsrEndpoint.Size = [System.Drawing.Size]::new(400, 20)
$txtAsrEndpoint.Text = $_cfg_asr_ep

$lblAsrApiKey = [System.Windows.Forms.Label]::new()
$lblAsrApiKey.Location = [System.Drawing.Point]::new(470, 47)
$lblAsrApiKey.Size = [System.Drawing.Size]::new(44, 16)
$lblAsrApiKey.Text = "Ключ:"

$txtAsrApiKey = [System.Windows.Forms.TextBox]::new()
$txtAsrApiKey.Location = [System.Drawing.Point]::new(518, 44)
$txtAsrApiKey.Size = [System.Drawing.Size]::new(200, 20)
# Ключ не должен читаться с экрана через плечо и на скриншотах.
$txtAsrApiKey.UseSystemPasswordChar = $true
$txtAsrApiKey.Text = $_cfg_asr_key

$grpAsr.Controls.AddRange(@($chkAsr, $lblAsrLang, $cmbAsrLang, $chkAsrDiarize, $lblAsrSpeakers, $txtAsrSpeakers,
	$lblAsrEndpoint, $txtAsrEndpoint, $lblAsrApiKey, $txtAsrApiKey))
$_regFont = $grpAsr.Font
$grpAsr.Font = [System.Drawing.Font]::new($_regFont, [System.Drawing.FontStyle]::Bold)
foreach ($c in $grpAsr.Controls) { $c.Font = $_regFont }
$_mc.Add($grpAsr)

# ========== Other Settings (collapsible) ==========
$yPos = 702
$groupOther = [System.Windows.Forms.GroupBox]::new()
$groupOther.Location = [System.Drawing.Point]::new($xPos0, $yPos)
$groupOther.Size = [System.Drawing.Size]::new(770, 18)
$groupOther.Text = "Дополнительные настройки (нажмите, чтобы развернуть)"
# Развернувшись, группа СДВИГАЕТ то, что под ней, а не накрывает собой. Раньше
# накрывала: Y кнопок и прогресса заданы абсолютными числами, а группа добавлена
# в контейнер раньше них и потому рисуется поверх — после разворачивания кнопка
# «Начать перекодирование» просто исчезала под панелью. Контейнер с AutoScroll
# сам добавит полосу прокрутки, если сдвинутое не влезло в окно.
$groupOther.Add_Click({
    $_collapsed = 18
    $_expanded  = 98
    $_expanding = ($groupOther.Height -eq $_collapsed)
    $_delta = if ($_expanding) { $_expanded - $_collapsed } else { $_collapsed - $_expanded }
    $groupOther.Height = $groupOther.Height + $_delta
    $groupOther.Text = if ($_expanding) { "Дополнительные настройки (нажмите, чтобы свернуть)" } else { "Дополнительные настройки (нажмите, чтобы развернуть)" }
    foreach ($c in @($buttonRun, $buttonStop, $buttonDoctor, $groupProgress)) {
        if ($c) { $c.Top = $c.Top + $_delta }
    }
    # Окно растёт вместе с группой, иначе у контейнера появлялись ОБЕ полосы прокрутки:
    # вертикальная отнимает 17 px, и группы шириной 770 перестают влезать по ширине.
    # Упёрлось в рабочую область — прокрутка остаётся, но окно расширяется на ширину
    # полосы, как при старте на маленьком экране. Свернули — вернули прежний размер.
    if ($_expanding) {
        $script:_formSizeCollapsed = $form.Size
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        $form.Height = [Math]::Min($form.Height + $_delta, $wa.Height)
        if ($form.Bottom -gt $wa.Bottom) { $form.Top = [Math]::Max($wa.Top, $wa.Bottom - $form.Height) }
        $form.PerformLayout()
        if ($mainContainer.HorizontalScroll.Visible) {
            $form.Width = [Math]::Min($form.Width + [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth, $wa.Width)
        }
    } elseif ($script:_formSizeCollapsed) {
        $form.Size = $script:_formSizeCollapsed
    }
    $form.Refresh()
})
$_goth = [System.Collections.Generic.List[System.Windows.Forms.Control]]::new()

# ffmpeg path (авто: ./ffmpeg.exe рядом со скриптом, иначе из PATH)
$_localFfmpeg = Join-Path $script:_appDir "ffmpeg.exe"
$textFFmpegPath = [PSCustomObject]@{ Text = if (Test-Path -LiteralPath $_localFfmpeg) { $_localFfmpeg } else { "ffmpeg" } }

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
$yPos = 724

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
    # Записываем файл-флаг отмены. -LiteralPath обязателен: '[' в пути TEMP иначе
    # трактуется как маска, файл не создаётся и Stop молча не работает.
    if ($global:_guiCancel) {
        try { Set-Content -LiteralPath $global:_guiCancel -Value "cancel" -Encoding UTF8 } catch {}
    }
})
$_mc.Add($buttonStop)

# Тот же отчёт, что у `--doctor` в CLI: какой инструмент найден, где, и что без
# него не работает. До него пользователь GUI узнавал об отсутствии ffmpeg или
# curl только по невнятному отказу воркера на первом же файле.
$buttonDoctor = [System.Windows.Forms.Button]::new()
$buttonDoctor.Location = [System.Drawing.Point]::new(630, $yPos)
$buttonDoctor.Size = [System.Drawing.Size]::new(150, 30)
$buttonDoctor.Text = "Проверить окружение"
$buttonDoctor.Font = [System.Drawing.Font]::new($buttonDoctor.Font.FontFamily, 8)
$buttonDoctor.Add_Click({
    $lines = @()
    $lines += "Каталог приложения: $script:_appDir"
    $lines += ""

    $ffPath = $textFFmpegPath.Text
    if (-not $ffPath) { $ffPath = "ffmpeg" }
    $ffFound = $null
    try { $ffFound = (Get-Command $ffPath -ErrorAction SilentlyContinue).Source } catch {}
    if (-not $ffFound -and (Test-Path -LiteralPath $ffPath)) { $ffFound = $ffPath }
    if ($ffFound) {
        $lines += "ffmpeg:  есть — $ffFound"
    } elseif ($chkRemote.Checked) {
        $lines += "ffmpeg:  НЕТ — тонкий клиент: считает служба. Локально недоступны проверка результата и определение длительности."
    } else {
        $lines += "ffmpeg:  НЕТ — конвертация невозможна. Положите ffmpeg.exe рядом с приложением или добавьте в PATH."
    }

    if ($chkRemote.Checked) {
        # Именно curl.exe, а не `curl`: в Windows PowerShell 5.1 это АЛИАС на
        # Invoke-WebRequest, и он резолвится раньше исполняемого файла. Отчёт
        # печатал «curl: есть» (Source — путь к модулю) на машине, где curl.exe нет
        # вовсе, то есть диагностика врала ровно в том случае, ради которого её
        # открывают. -CommandType Application отсекает алиасы и функции.
        $curl = $null
        try { $curl = (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } catch {}
        if ($curl) { $lines += "curl:    есть — $curl" }
        else       { $lines += "curl:    НЕТ — удалённый бэкенд не работает вовсе." }
        $ep = $txtRemoteEndpoint.Text.Trim()
        if (-not $ep) {
            $lines += "Адрес:   НЕ ЗАДАН — заполните поле адреса службы."
        } elseif ($ep -notmatch '/v\d+$') {
            $lines += "Адрес:   $ep — БЕЗ версии API (/v1). Вероятен HTTP 404 на /capabilities."
        } else {
            $lines += "Адрес:   $ep"
        }
        if ($txtRemoteApiKey.Text.Trim() -or $_cfg_remote_keycmd) { $lines += "Ключ:    задан (значение не показываем)" }
        else { $lines += "Ключ:    НЕ ЗАДАН — служба откажет на первом запросе." }
    }

    if ($chkAsr.Checked) {
        $curl = $null
        try { $curl = (Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source } catch {}
        if ($curl) { $lines += "curl:    есть — $curl" }
        else       { $lines += "curl:    НЕТ — распознавание речи не работает вовсе." }
        $aep = $txtAsrEndpoint.Text.Trim()
        if ($aep) { $lines += "ASR:     $aep" }
        else      { $lines += "ASR:     адрес НЕ ЗАДАН — заполните поле адреса сервера распознавания." }
        if ($txtAsrApiKey.Text.Trim() -or $_cfg_asr_keycmd) { $lines += "Ключ ASR: задан (значение не показываем)" }
        else { $lines += "Ключ ASR: НЕ ЗАДАН — сервер откажет на первом запросе." }
    }

    $lines += ""
    $src = $textInputFolder.Text
    $lines += "Источник:   $src$(if (-not (Test-Path -LiteralPath $src)) { '   ← каталога НЕТ' })"
    $lines += "Назначение: $($textOutputFolder.Text)"
    [System.Windows.Forms.MessageBox]::Show(($lines -join "`n"), "Проверка окружения",
        [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
})
$_mc.Add($buttonDoctor)

# ========== Progress Section ==========
$yPos = 758
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
    # parallel_files=$($_cfg_parallel.value) игнорируется — параллельная обработка есть
    # только в .sh. Значение из config.ini передаём как есть, чтобы воркер напечатал
    # то же предупреждение, что и CLI-PS1.
    $script:parallel_files      = if ($_cfg_parallel.enabled) { ":+:$($_cfg_parallel.value)" } else { ":-:$($_cfg_parallel.value)" }
    $script:dry_run             = if ($checkDryRun.Checked)      { "yes" } else { "no" }
    $script:enable_log          = if ($checkLog.Checked)         { "yes" } else { "no" }
    $script:log_file            = $_cfg_log_file
    $script:extract_audio_copy  = if ($checkExtractAudioCopy.Checked) { "yes" } else { "no" }
    # overwrite_existing — из чекбокса «Перезаписывать существующие» (начальное
    # значение он берёт из config.ini). Раньше контрола не было вовсе, и переключить
    # поведение можно было только правкой config.ini.
    $script:overwrite_existing  = if ($checkOverwrite.Checked)   { "yes" } else { "no" }

    # Audio settings
    $script:audio_codec          = if ($checkAudioCodec.Checked)      { ":+:$($comboAudioCodec.Text)" }    else { ":-:$($comboAudioCodec.Text)" }
    # Как и rotation — первое слово текста пункта, а не SelectedIndex+1: пункт
    # «6 - из config.ini» (Select-ConfigComboValue) обязан уехать в воркер как 6.
    $_chVal = ([string]$comboAudioChannels.SelectedItem -split ' ')[0]
    $script:audio_number_channels = if ($checkAudioChannels.Checked)  { ":+:$_chVal" } else { ":-:$_chVal" }
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

    $subtitlesMode = ([string]$comboSubtitlesMode.SelectedItem -split ' ')[0]
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
    # Первое слово пункта: «slow - из config.ini» (Select-ConfigComboValue) уходит как slow.
    $_gpuPresetVal = ([string]$comboGpuPreset.SelectedItem -split ' ')[0]
    $_gpuTuneVal   = ([string]$comboGpuTune.SelectedItem -split ' ')[0]
    $_gpuRcVal     = ([string]$comboGpuRC.SelectedItem -split ' ')[0]
    $script:gpu_preset = if ($isGpuOn) { ":+:$_gpuPresetVal" } else { ":-:$_gpuPresetVal" }
    $script:gpu_tune   = if ($isGpuOn -and $hwIndex -eq 1) { ":+:$_gpuTuneVal" } else { ":-:$_gpuTuneVal" }
    $script:gpu_rc     = if ($isGpuOn -and $hwIndex -eq 1) { ":+:$_gpuRcVal" }   else { ":-:$_gpuRcVal" }

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

    # ---- Валидация числовых полей (до запуска — иначе ошибка ffmpeg на каждом файле) ----
    $numErr = $null
    # Распознавание не конвертирует: поля конвертации ему не мешают (воркер их тоже не
    # проверяет), а «Сколько говорящих» — шаблоном: [int64] на двадцати цифрах бросал.
    if ($chkAsr.Checked) {
        if ($txtAsrSpeakers.Text.Trim() -and $txtAsrSpeakers.Text.Trim() -notmatch '^0*([1-9]|[1-4][0-9]|50)\z') { $numErr = "«Сколько говорящих» — целое число от 1 до 50 или пусто (сервер определит сам)" }
    }
    elseif ($checkAudioBitrate.Checked    -and $textAudioBitrate.Text    -notmatch '^\d+$')            { $numErr = "Аудио битрейт должен быть целым числом (кбит/с)" }
    elseif ($checkAudioSampleRate.Checked -and $textAudioSampleRate.Text -notmatch '^\d+$')            { $numErr = "Частота дискретизации должна быть целым числом (Гц)" }
    elseif ($checkFrameRate.Checked       -and $textFrameRate.Text       -notmatch '^\d+(\.\d+)?$')    { $numErr = "Кадры/с должны быть числом" }
    elseif ($checkVideoBitrate.Checked    -and $textVideoBitrate.Text    -notmatch '^\d+$')            { $numErr = "Видео битрейт должен быть целым числом (кбит/с)" }
    elseif ($checkVideoQuality.Checked    -and (($textVideoQuality.Text  -notmatch '^\d+$') -or ([int]$textVideoQuality.Text -gt 51))) { $numErr = "Качество (CRF/CQ) должно быть целым 0-51" }
    # Диапазон скорости — тот же, что у скрипта (0 < v <= 100, F15): каскад atempo
    # написан под произвольные значения, а 100 — предел одного звена. Прежние 0.25-4.0
    # были уже́е скриптовых: один и тот же config.ini CLI принимал, а GUI отвергал,
    # причём диапазон не был назван нигде, кроме текста самой ошибки.
    elseif ($checkSpeed.Checked           -and (($textSpeed.Text -notmatch '^\d+(\.\d+)?$') -or ([double]$textSpeed.Text -le 0) -or ([double]$textSpeed.Text -gt 100))) { $numErr = "Скорость должна быть больше 0 и не больше 100 (точка как разделитель)" }
    elseif ($checkSplitSilence.Checked    -and $textSilenceDuration.Text -notmatch '^\d+(\.\d+)?$')    { $numErr = "Мин. тишина должна быть числом (секунды)" }
    # Метки времени тоже обязаны проверяться здесь. Скрипт разбирает их как чч-мм-сс
    # ([int]$x*3600+...), и «1:00:00» или любой другой текст ронял воркер исключением
    # каста — весь батч обрывался невнятной ошибкой на первом же файле.
    elseif ($checkStartTime.Checked       -and $textStartTime.Text       -notmatch '^\d{1,2}-\d{1,2}-\d{1,2}$') { $numErr = "Начало должно быть в формате чч-мм-сс (например 00-01-30)" }
    elseif ($checkDuration.Checked        -and $textDuration.Text        -notmatch '^\d{1,2}-\d{1,2}-\d{1,2}$') { $numErr = "Длительность должна быть в формате чч-мм-сс (например 00-05-00)" }
    # Три поля жили вне каскада и обнаруживались уже воркером — каждое по-своему
    # неприятно. «Разрешение» комбо редактируемое: «1280 x 720» давало
    # `scale=1280 :720` и FAIL каждого файла. «Потоки» с текстом молча становились
    # 4. «Ждать карту, сек» уезжает в JSON БЕЗ кавычек: «30 мин» давало невалидное
    # тело `{"wait_timeout":30 мин}`, и выяснялось это ПОСЛЕ загрузки гигабайт.
    elseif ($checkVideoResolution.Checked -and $comboVideoResolution.Text -notmatch '^\d+x\d+$') { $numErr = "Разрешение задаётся как ШИРИНАxВЫСОТА без пробелов (например 1280x720)" }
    elseif ($checkMultithreads.Checked    -and $textThreads.Text          -notmatch '^\d+$')     { $numErr = "Потоки ffmpeg должны быть целым числом" }
    elseif ($chkRemote.Checked            -and $txtRemoteWait.Text        -notmatch '^\d+$')     { $numErr = "«Ждать карту, сек» должно быть целым числом секунд" }
    if ($numErr) {
        [System.Windows.Forms.MessageBox]::Show($numErr, "Проверка настроек", "OK", "Warning") | Out-Null
        return
    }

    # ---- Валидация ----
    if ([string]::IsNullOrWhiteSpace($script:folder_sources) -or !(Test-Path -LiteralPath $script:folder_sources)) {
        [System.Windows.Forms.MessageBox]::Show("Папка источника не найдена:`n$($script:folder_sources)", "Ошибка", "OK", "Error")
        return
    }

    # ---- F-modes (GUI). Взаимоисключающие режимы — сказать ДО запуска ----
    # Скрипт и так выберет эффективный режим по приоритету и напишет WARN в лог, но
    # пользователь GUI этот лог видит уже после старта. Здесь он узнаёт заранее и может
    # отменить, а не обнаружить постфактум, что половина галок молча проигнорирована.
    $_modes = @()
    if ($checkMergeFiles.Checked)       { $_modes += "объединение файлов" }
    if ($checkExtractAudioCopy.Checked) { $_modes += "извлечение аудио без перекодирования" }
    if ($checkCreateFrames.Checked)     { $_modes += "извлечение кадров" }
    if ($checkCopyCodecs.Checked)       { $_modes += "копирование кодеков" }
    if ($checkSaveAudio.Checked)        { $_modes += "только аудио" }
    if ($_modes.Count -gt 1 -and -not $chkAsr.Checked) {
        # Порядок $_modes уже соответствует приоритету merge>extract>frame>copy>audio.
        $_msg = "Включено несколько взаимоисключающих режимов:`n`n  - " + ($_modes -join "`n  - ") +
                "`n`nБудет применён только «$($_modes[0])», остальные проигнорированы.`n`nПродолжить?"
        $_ans = [System.Windows.Forms.MessageBox]::Show($_msg, "Конфликт режимов", "YesNo", "Warning")
        if ($_ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    # ---- F33 (GUI). Точный энкодер проверяем ДО запуска ----
    # Рантайм-защита в script.ps1 уже откатывается на CPU, но пользователь GUI узнавал
    # об этом только из лога после старта — то есть выбрав GPU, тихо получал софтверное
    # кодирование. Резолвинг кандидата обязан повторять логику script.ps1.
    if ($hwIndex -gt 0 -and -not $chkAsr.Checked) {
        $_hwSuffix = if ($hwIndex -eq 1) { "_nvenc" } else { "_qsv" }
        $_hwLabel  = if ($hwIndex -eq 1) { "NVENC" }  else { "QSV" }
        $_swCodec  = $comboVideoCodec.Text
        $_cand = switch -Regex ($_swCodec) {
            '^libx264$'   { "h264$_hwSuffix"; break }
            '^libx265$'   { "hevc$_hwSuffix"; break }
            '^libsvtav1$' { "av1$_hwSuffix";  break }
            ([regex]::Escape($_hwSuffix) + '$') { $_swCodec; break }
            default       { "" }
        }
        $_probeWarn = $null
        if (-not $_cand) {
            $_probeWarn = "У кодека $_swCodec нет $_hwLabel-варианта."
        } else {
            try {
                $_encList = & $script:ffmpeg -encoders 2>&1 | Out-String
                # Якорение по границам столбца — как в script.ps1: подстрочный match
                # поймал бы av1_nvenc в строке про av1_nvenc_hypothetical.
                if ($_encList -notmatch "(?m)^\s*[A-Z.]+\s+$([regex]::Escape($_cand))(\s|$)") {
                    $_probeWarn = "Энкодер $_cand отсутствует в этой сборке ffmpeg."
                }
            } catch {
                $_probeWarn = "Не удалось опросить ffmpeg -encoders: $($_.Exception.Message)"
            }
        }
        if ($_probeWarn) {
            $_ans = [System.Windows.Forms.MessageBox]::Show(
                "$_probeWarn`n`nБудет использовано программное (CPU) кодирование — заметно медленнее.`n`nПродолжить?",
                "Аппаратное ускорение недоступно", "YesNo", "Warning")
            if ($_ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }
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
    } elseif (Test-Path -LiteralPath $scriptPath) {
        $scriptContent = [System.IO.File]::ReadAllText($scriptPath, [System.Text.Encoding]::UTF8)
    } else {
        [System.Windows.Forms.MessageBox]::Show("Скрипт не найден:`n$scriptPath", "Ошибка", "OK", "Error") | Out-Null
        $buttonRun.Enabled = $true; $buttonStop.Enabled = $false
        return
    }

    # ---- Удалённый бэкенд ----
    # Адрес и ключ берутся из полей формы (их начальное значение — из config.ini,
    # где допустима и подстановка ${TRANSCODE_URL}, развёрнутая при чтении).
    # $script:, как и остальные значения формы: сбор в runspace идёт через
    # Get-Variable -Scope Script, и локальная переменная обработчика туда не попадёт.
    # Нормализация адреса — одна на платформу, в Format-RemoteEndpoint
    # (remote_client.ps1, вызов из Invoke-RemotePreflight). Здесь только Trim
    # поля формы: раньше GUI снимал все хвостовые слэши, CLI-PS1 тоже, а .sh —
    # ровно один, и один config.ini давал «…/v1//jobs» из CLI.
    $script:remote_enabled         = if ($chkRemote.Checked) { "yes" } else { "no" }
    $script:remote_endpoint        = $txtRemoteEndpoint.Text.Trim()
    $script:remote_api_key         = $txtRemoteApiKey.Text.Trim()
    $script:remote_api_key_command = $_cfg_remote_keycmd
    $script:remote_prefer          = [string]$cmbRemotePrefer.SelectedItem
    $script:remote_wait_timeout    = $txtRemoteWait.Text
    $script:remote_stall_timeout   = $_cfg_remote_stall
    $script:remote_on_failure      = $_cfg_remote_onfail

    # ---- Распознавание речи ----
    $script:asr_enabled         = if ($chkAsr.Checked) { "yes" } else { "no" }
    $script:asr_endpoint        = $txtAsrEndpoint.Text.Trim()
    $script:asr_api_key         = $txtAsrApiKey.Text.Trim()
    $script:asr_api_key_command = $_cfg_asr_keycmd
    $script:asr_pinned_pubkey   = $_cfg_asr_pin
    $script:asr_language        = [string]$cmbAsrLang.SelectedItem
    $script:asr_diarize         = if ($chkAsrDiarize.Checked) { "yes" } else { "no" }
    $script:asr_num_speakers    = $txtAsrSpeakers.Text.Trim()

    # Собираем все переменные для передачи в runspace
    $varsToPass = @{}
    foreach ($varName in @(
        'folder_sources','folder_destination','audio_only','merge_files','create_frame',
        'copy_codecs','multithreads','parallel_files','extract_audio_copy','overwrite_existing',
        'audio_codec','audio_number_channels','audio_bitrate','audio_sampling_rate','audio_normalize',
        'video_codec','video_resolution','video_bitrate','video_number_frames','video_rotation',
        'video_subtitles','video_quality','keep_aspect_ratio','output_container',
        'hw_accel','gpu_preset','gpu_tune','gpu_rc',
        'playback_speed',
        'start_coding','length_coding','split_by_silence','silence_duration','silence_threshold',
        'ffmpeg','save_old_extension','format_files_in','subtitles_style',
        'dry_run','enable_log','log_file',
        'remote_enabled','remote_endpoint','remote_api_key','remote_api_key_command',
        'remote_prefer','remote_wait_timeout','remote_stall_timeout','remote_on_failure',
        'asr_enabled','asr_endpoint','asr_api_key','asr_api_key_command','asr_pinned_pubkey','asr_language','asr_diarize','asr_num_speakers'
    )) {
        $v = Get-Variable -Name $varName -Scope Script -ErrorAction SilentlyContinue
        $varsToPass[$varName] = if ($v) { $v.Value } else { $null }
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    foreach ($kv in $varsToPass.GetEnumerator()) {
        $rs.SessionStateProxy.SetVariable($kv.Key, $kv.Value)
    }
    # PSScriptRoot задаём для совместимости, но полагаться на него нельзя: у скрипта,
    # поданного строкой в AddScript(), автоматическая $PSScriptRoot пуста и перекрывает
    # это значение. Каталог приложения воркер берёт из $guiAppDir.
    $rs.SessionStateProxy.SetVariable("PSScriptRoot", $script:_appDir)
    $rs.SessionStateProxy.SetVariable("guiAppDir", $script:_appDir)
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

            # F17. Исход собираем из ТРЁХ независимых источников: исключение из
            # EndInvoke, Error stream и финальный state воркера. Раньше исключение
            # глушилось пустым catch, а `exit 1` из воркера не создаёт ErrorRecord —
            # поэтому провальный батч показывался как «Готово».
            $errParts = @()
            try { $global:_guiPS.EndInvoke($global:_guiHandle) | Out-Null }
            catch { $errParts += "Сбой выполнения: $($_.Exception.Message)" }

            $rsErrors = $global:_guiPS.Streams.Error
            if ($rsErrors -and $rsErrors.Count -gt 0) {
                $errParts += ($rsErrors | ForEach-Object { $_.ToString() })
            }

            # Причины отказа воркер печатает через Write-Host — это Information-stream,
            # и GUI его не читал вовсе: preflight-отказ (`exit 1` до первой записи
            # прогресса) давал бессодержательное «завершился без отчёта о результате».
            # Собираем ОТДЕЛЬНО от $errParts: наличие [ПРЕДУПРЕЖДЕНИЕ] само по себе не
            # делает прогон неудачным, эти строки нужны только в ветке ошибки.
            $infoLines = @()
            try {
                $infoLines = @($global:_guiPS.Streams.Information |
                    ForEach-Object { [string]$_ } |
                    Where-Object { $_ -match '\[ОШИБКА\]|\[FAIL\]|\[ПРЕДУПРЕЖДЕНИЕ\]' } |
                    Select-Object -Last 10)
            } catch {}

            # Читаем финальное состояние
            $state = $null
            try {
                # ReadAllText, а не Get-Content -Raw: воркер пишет File.WriteAllText в
                # UTF-8 без BOM, и Get-Content без -Encoding на русской локали читает его
                # как ANSI — «Файлов с ошибками: 2» приходило в MessageBox мохибейком.
                $json = [System.IO.File]::ReadAllText($global:_guiProgress) | ConvertFrom-Json
                if ($json) {
                    $state = $json.state
                    $progressBarFile.Value  = 100
                    $progressBarTotal.Value = 100
                    $labelProgressTotal.Text = "Файлов: $($json.fileNum) / $($json.totalFiles)"
                    $labelProgressSummary.Text = "OK: $($json.ok)   Ошибки: $($json.fail)   Пропущено: $($json.skip)"
                    # message — причина ОТКАЗА, и только при отказе она ошибка: при
                    # state=success любое информационное сообщение воркера иначе
                    # превращало успешный батч в «Ошибку» с MessageBox. Fail-closed
                    # это не ослабляет — он держится на state, а не на message.
                    if ($json.message -and $state -ne "success") { $errParts += [string]$json.message }
                }
            } catch {}

            # Fail-closed: успех показываем ТОЛЬКО при явном state=success без ошибок.
            # Воркер, упавший на preflight (`exit 1` до первой записи прогресса),
            # не оставляет state — молчание не имеет права читаться как «Готово».
            if ($state -eq "cancelled") {
                $labelProgressFile.Text = "Отменено"
            } elseif ($state -eq "success" -and $errParts.Count -eq 0) {
                $labelProgressFile.Text = "Готово"
            } else {
                $labelProgressFile.Text = "Ошибка"
                if ($errParts.Count -eq 0) { $errParts += "Скрипт завершился без отчёта о результате (state='$state')" }
                if ($infoLines.Count -gt 0) { $errParts += $infoLines }
                [System.Windows.Forms.MessageBox]::Show(($errParts -join "`n"), "Ошибка скрипта", "OK", "Error") | Out-Null
            }

            # Очистка
            # -LiteralPath: TEMP с '[' или ']' в пути иначе трактуется как маска и файлы
            # остаются (а Stop через cancel-файл перестаёт работать).
            if ($global:_guiProgress) {
                try { Remove-Item -LiteralPath $global:_guiProgress -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -LiteralPath "$($global:_guiProgress).tmp" -Force -ErrorAction SilentlyContinue } catch {}
                try { Remove-Item -LiteralPath "$($global:_guiProgress).bak" -Force -ErrorAction SilentlyContinue } catch {}
            }
            if ($global:_guiCancel) { try { Remove-Item -LiteralPath $global:_guiCancel -Force -ErrorAction SilentlyContinue } catch {} }
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
            if ($global:_guiProgress -and (Test-Path -LiteralPath $global:_guiProgress)) {
                $json = [System.IO.File]::ReadAllText($global:_guiProgress) | ConvertFrom-Json
                $progressBarFile.Value  = [Math]::Min($json.filePercent,  100)
                $progressBarTotal.Value = [Math]::Min($json.totalPercent, 100)
                if ($json.currentFile) {
                    # Фаза удалённого пути (отправка / ожидание карты /
                    # кодирование / скачивание). Без неё минуты «ничего не
                    # происходит» неотличимы от зависания.
                    if ($json.phase) {
                        $labelProgressFile.Text = "$($json.currentFile) · $($json.phase)"
                    } else {
                        $labelProgressFile.Text = "$($json.currentFile)"
                    }
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
    # Глобальная ссылка — чтобы FormClosing мог детерминированно остановить таймер.
    $global:_guiTimer = $timer
  } catch {
    # Сообщение пользовательское: отладочный диалог «DEBUG: Click Error» с номером
    # строки уезжал в собранный EXE, и любой сбой подготовки запуска выглядел для
    # пользователя как след разработки, а не как внятная ошибка.
    [System.Windows.Forms.MessageBox]::Show("Ошибка подготовки запуска: $_", "Видеоконвертер", "OK", "Error") | Out-Null
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

# Предупреждения разбора config.ini (см. Expand-ConfigEnv) — одним окном и уже
# поверх открытой формы, а не россыпью MessageBox до её появления.
if ($script:configWarnings.Count -gt 0) {
    $form.Add_Shown({
        [System.Windows.Forms.MessageBox]::Show(($script:configWarnings -join "`n"), "config.ini", "OK", "Warning") | Out-Null
    })
}

# ========== Получить версию ffmpeg — после отрисовки формы (через отложенный вызов) ==========
$form.Add_Shown({
    $t = [System.Windows.Forms.Timer]::new()
    $t.Interval = 50
    $t.Add_Tick({
        try {
            $this.Stop(); $this.Dispose()
            $ffmpegBin = $textFFmpegPath.Text
            # Ограниченный по времени probe версии — зависший бинарь не морозит UI навсегда.
            $vpsi = [System.Diagnostics.ProcessStartInfo]::new()
            $vpsi.FileName = $ffmpegBin; $vpsi.Arguments = "-version"
            $vpsi.UseShellExecute = $false; $vpsi.CreateNoWindow = $true
            $vpsi.RedirectStandardOutput = $true; $vpsi.RedirectStandardError = $true
            $vp = [System.Diagnostics.Process]::Start($vpsi)
            $vOutTask = $vp.StandardOutput.ReadToEndAsync()
            $vErrTask = $vp.StandardError.ReadToEndAsync()
            if (-not $vp.WaitForExit(5000)) { try { $vp.Kill() } catch {} }
            $versionOut = ""; try { $versionOut = $vOutTask.Result } catch {}
            try { $null = $vErrTask.Result } catch {}
            $versionLine = (($versionOut -split "`n") | Select-Object -First 1)
            if ($versionLine) { $versionLine = $versionLine.Trim() } else { $versionLine = "" }
            if ($versionLine -match 'ffmpeg version (\S+)') {
                $script:ffmpegCurrentVersion = $Matches[1]
                $lblFfmpegVersion.Text      = "ffmpeg: $($Matches[1])"
                $lblFfmpegVersion.ForeColor = [System.Drawing.Color]::DarkGreen

                # Probe реально выбранного энкодера (семейство по выбранному кодеку),
                # а не всегда h264 — иначе для HEVC/AV1 проверка нерелевантна.
                $selIdx = $comboHWAccel.SelectedIndex
                $encBase = switch -Regex ($comboVideoCodec.Text) {
                    'x265|hevc' { 'hevc'; break }
                    'av1'       { 'av1';  break }
                    default     { 'h264' }
                }
                if ($selIdx -eq 1) {
                    if (-not (Test-GpuEncoder $ffmpegBin "${encBase}_nvenc")) {
                        $comboHWAccel.SelectedIndex = 0
                        $labelHWInfo.Text = "NVIDIA NVENC недоступен (нет GPU/драйвера) — переключено на CPU"
                        $labelHWInfo.ForeColor = [System.Drawing.Color]::Firebrick
                    }
                } elseif ($selIdx -eq 2) {
                    if (-not (Test-GpuEncoder $ffmpegBin "${encBase}_qsv")) {
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
    # Сначала детерминированно гасим UI-таймер — иначе отложенный Tick мог бы дёрнуть
    # уже освобождённый runspace или удалённые файлы прогресса после закрытия формы.
    if ($global:_guiTimer) { try { $global:_guiTimer.Stop(); $global:_guiTimer.Dispose() } catch {} }
    if ($global:_guiPS -and $global:_guiHandle -and -not $global:_guiHandle.IsCompleted) {
        try { Set-Content -LiteralPath $global:_guiCancel -Value "cancel" -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
        # Даём воркеру до ~3с увидеть cancel-файл и сам убить свой ffmpeg.exe; иначе Stop()
        # обрывает pipeline, а внешний ffmpeg.exe остаётся осиротевшим процессом.
        # Ждём с прокачкой очереди сообщений. Голый Start-Sleep в UI-потоке замораживает
        # окно: Windows рисует «Не отвечает», и пользователь успевает снять процесс через
        # диспетчер задач — ровно тот осиротевший ffmpeg.exe, ради которого мы и ждём.
        # Форму на время ожидания выключаем, чтобы DoEvents не втянул новые клики.
        $form.Enabled = $false
        $waited = 0
        while (-not $global:_guiHandle.IsCompleted -and $waited -lt 3000) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 10; $waited += 10
        }
        if (-not $global:_guiHandle.IsCompleted) { try { $global:_guiPS.Stop() } catch {} }
    }
    # ".tmp"/".bak" — служебные файлы атомарной записи прогресса (воркер пишет в tmp и
    # подменяет цель); остаются, только если воркер убит между записью и подменой.
    #
    # Список строим ТОЛЬКО от заданных путей: при закрытии окна без единого запуска
    # $global:_guiProgress не определена, и "$($global:_guiProgress).tmp" давало голое
    # ".tmp" — Remove-Item сносил файлы «.tmp»/«.bak» из текущего каталога.
    $_toClean = @()
    if ($global:_guiProgress) { $_toClean += @($global:_guiProgress, "$($global:_guiProgress).tmp", "$($global:_guiProgress).bak") }
    if ($global:_guiCancel)   { $_toClean += $global:_guiCancel }
    foreach ($f in $_toClean) {
        try { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } catch {}
    }
    if ($global:_guiPS)       { try { $global:_guiPS.Dispose() } catch {} }
    if ($global:_guiRunspace) { try { $global:_guiRunspace.Dispose() } catch {} }
})

# ========== Show Form ==========
$form.ShowDialog() | Out-Null
