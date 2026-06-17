#!/bin/bash
# ============================================================
# test_06_ps1.sh — Тест PS1 yt-dlp GUI: Read-Config, Get-Platform,
# qualityMap, formatPresets, cookie switch, proxy URL build.
# Использует inline PowerShell без запуска GUI.
# ============================================================

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"

source "$TESTS_DIR/lib/framework.sh"

if ! command -v powershell &>/dev/null && ! command -v pwsh &>/dev/null; then
    suite "PS1 yt-dlp тесты"
    skip "Все PS1 тесты" "PowerShell не найден"
    summary
    exit 0
fi

PS_CMD="powershell"
command -v pwsh &>/dev/null && PS_CMD="pwsh"

get_field() {
    local output="$1" field="$2"
    echo "$output" | grep "^${field}=" | sed "s/^${field}=//"
}

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: Read-Config (из GUI скрипта)"
# ══════════════════════════════════════════════════════════════

run_readconfig() {
    local key="$1" section="$2" default="$3" content="$4"
    local tmpfile
    tmpfile=$(mktemp /tmp/test_ytps1_XXXXXX.ini)
    printf '%s\n' "$content" > "$tmpfile"
    local win_path
    win_path=$(cygpath -w "$tmpfile" 2>/dev/null || echo "$tmpfile")

    $PS_CMD -NoProfile -NonInteractive -Command "
\$configFile = '$win_path'
function Read-Config {
    param([string]\$Key, [string]\$Section, [string]\$Default = '')
    if (-not (Test-Path \$configFile)) { return \$Default }
    \$inSection = \$false
    foreach (\$line in (Get-Content \$configFile -Encoding UTF8)) {
        \$line = \$line.Trim()
        if ([string]::IsNullOrEmpty(\$line) -or \$line.StartsWith('#')) { continue }
        if (\$line -match '^\[([^\]]+)\]\$') {
            \$inSection = (\$Matches[1] -eq \$Section)
            continue
        }
        if (\$inSection -and \$line -match \"^\${Key}\s*=\s*(.*)\") {
            \$val = \$Matches[1] -replace '\s*#.*', ''
            return \$val
        }
    }
    return \$Default
}
Write-Output (Read-Config '$key' '$section' '$default')
" 2>/dev/null
    rm -f "$tmpfile"
}

result=$(run_readconfig "url" "proxy" "" "[proxy]
url = https://proxy.example.com:8080")
assert_eq "Read-Config proxy url"  "https://proxy.example.com:8080"  "$result"

result=$(run_readconfig "method" "cookies" "none" "[cookies]
method = browser")
assert_eq "Read-Config cookies method"  "browser"  "$result"

result=$(run_readconfig "default_quality" "download" "720" "[download]
default_quality = 1080")
assert_eq "Read-Config quality=1080"  "1080"  "$result"

result=$(run_readconfig "nonexistent" "proxy" "my_default" "[proxy]
url = something")
assert_eq "Read-Config нет ключа → default"  "my_default"  "$result"

result=$(run_readconfig "enabled" "translation" "false" "[translation]
enabled = true
target_lang = ru")
assert_eq "Read-Config translation enabled"  "true"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: Get-Platform (определение платформы)"
# ══════════════════════════════════════════════════════════════

run_platform() {
    local url="$1"
    $PS_CMD -NoProfile -NonInteractive -Command "
function Get-Platform {
    param([string]\$Url)
    switch -Regex (\$Url) {
        'youtube\.com|youtu\.be' { return 'YouTube' }
        'rutube\.ru'             { return 'RuTube' }
        'vk\.com'               { return 'VK Video' }
        'twitch\.tv'            { return 'Twitch' }
        'vimeo\.com'            { return 'Vimeo' }
        'dailymotion\.com'      { return 'Dailymotion' }
        default                  { return 'Video' }
    }
}
Write-Output (Get-Platform '$url')
" 2>/dev/null
}

result=$(run_platform "https://www.youtube.com/watch?v=abc123")
assert_eq "YouTube URL → YouTube"   "YouTube"    "$result"

result=$(run_platform "https://youtu.be/abc123")
assert_eq "youtu.be → YouTube"      "YouTube"    "$result"

result=$(run_platform "https://rutube.ru/video/abc")
assert_eq "rutube.ru → RuTube"      "RuTube"     "$result"

result=$(run_platform "https://vk.com/video123")
assert_eq "vk.com → VK Video"       "VK Video"   "$result"

result=$(run_platform "https://twitch.tv/somestream")
assert_eq "twitch.tv → Twitch"      "Twitch"     "$result"

result=$(run_platform "https://vimeo.com/123456")
assert_eq "vimeo.com → Vimeo"       "Vimeo"      "$result"

result=$(run_platform "https://example.com/video.mp4")
assert_eq "unknown → Video"         "Video"      "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: qualityMap → defaultQualityIdx"
# ══════════════════════════════════════════════════════════════

run_qualitymap() {
    local cfg_quality="$1"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$qualityMap = @{ '720' = 3; '360' = 1; '480' = 2; '1080' = 4; '1440' = 5; '2160' = 6 }
\$cfg_quality = '$cfg_quality'
\$defaultQualityIdx = if (\$qualityMap.ContainsKey(\$cfg_quality)) { \$qualityMap[\$cfg_quality] } else { 3 }
Write-Output \$defaultQualityIdx
" 2>/dev/null
}

result=$(run_qualitymap "720")
assert_eq "quality=720 → idx 3"   "3"  "$result"

result=$(run_qualitymap "360")
assert_eq "quality=360 → idx 1"   "1"  "$result"

result=$(run_qualitymap "1080")
assert_eq "quality=1080 → idx 4"  "4"  "$result"

result=$(run_qualitymap "2160")
assert_eq "quality=2160 → idx 6"  "6"  "$result"

result=$(run_qualitymap "audio")
assert_eq "quality=audio (unknown) → idx 3 (default)"  "3"  "$result"

result=$(run_qualitymap "")
assert_eq "quality='' (empty) → idx 3 (default)"  "3"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: formatPresets таблица"
# ══════════════════════════════════════════════════════════════

run_format() {
    local preset="$1"
    local qi="$2"
    # Пишем PS1 код в temp-файл (избегаем bash-экранирования < и `" в строках)
    local tmpps1
    tmpps1=$(mktemp /tmp/test_ytps1_fmt_XXXXXX.ps1)
    local win_path
    win_path=$(cygpath -w "$tmpps1" 2>/dev/null || echo "$tmpps1")
    cat > "$tmpps1" << 'PS1EOF'
$formatPresets = @{
    'avc1_best' = @(
        'bestaudio[ext!=webm]/bestaudio',
        'bestaudio[ext!=webm]+bestvideo[height<=360][vcodec^=avc1]/bestaudio+bestvideo[height<=360]',
        'bestaudio[ext!=webm]+bestvideo[height<=480][vcodec^=avc1]/bestaudio+bestvideo[height<=480]',
        'bestaudio[ext!=webm]+bestvideo[height<=720][vcodec^=avc1]/bestaudio+bestvideo[height<=720]',
        'bestaudio[ext!=webm]+bestvideo[height<=1080][vcodec^=avc1]/bestaudio+bestvideo[height<=1080]',
        'bestaudio[ext!=webm]+bestvideo[height<=1440][vcodec^=avc1]/bestaudio+bestvideo[height<=1440]',
        'bestaudio[ext!=webm]+bestvideo[height<=2160][vcodec^=avc1]/bestaudio+bestvideo[height<=2160]'
    )
    'avc1_https' = @(
        '140', '140+134', '140+135/134', '140+136/135/134',
        '140+137/136/135/134',
        '140+264/bestvideo[height<=1440][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=1440]',
        '140+266/bestvideo[height<=2160][vcodec^=avc1]+bestaudio[ext=m4a]/best[height<=2160]'
    )
    'avc1_m3u8' = @(
        '234', '234+230', '234+231/230', '234+232/231/230',
        '270+234/bestvideo[protocol*=m3u8][height<=1080]+bestaudio[protocol*=m3u8]/best[height<=1080]',
        'bestvideo[protocol*=m3u8][height<=1440]+bestaudio[protocol*=m3u8]/best[height<=1440]',
        'bestvideo[protocol*=m3u8][height<=2160]+bestaudio[protocol*=m3u8]/best[height<=2160]'
    )
    'avc1_https_60fps' = @(
        '140', '140+134/best[height<=360]', '140+135/best[height<=480]', '234+298/297/296',
        '234+299/298/297/296',
        '140+299/bestvideo[height<=1440][fps>=50]+bestaudio[ext=m4a]/best[height<=1440]',
        '140+299/bestvideo[height<=2160][fps>=50]+bestaudio[ext=m4a]/best[height<=2160]'
    )
    'avc1_m3u8_60fps' = @(
        '234', '234+309', '234+310/309', '234+311/310/309',
        '234+312/311/310/309', '234+313/312/311/310/309', '234+314/313/312/311/310/309'
    )
    'avc1_https_60fps_hdr' = @(
        '234', '234+696', '234+697/696', '234+698/697/696',
        '234+699/698/697/696', '234+700/699/698/697/696', '234+701/700/699/698/697/696'
    )
    'old_combo' = @(
        '140', '18', '59/22/18', '22/18',
        '37/22/18', '38/37/22/18', '38/37/22/18'
    )
}
PS1EOF
    # Добавляем строку с нужным preset/qi (подставляем снаружи)
    printf 'Write-Output $formatPresets['"'"'%s'"'"'][%s]\n' "$preset" "$qi" >> "$tmpps1"
    local result
    result=$($PS_CMD -NoProfile -NonInteractive -File "$win_path" 2>/dev/null)
    rm -f "$tmpps1"
    echo "$result"
}

result=$(run_format "avc1_best" 0)
assert_contains "avc1_best audio → bestaudio"  "bestaudio[ext!=webm]"  "$result"

result=$(run_format "avc1_best" 3)
assert_contains "avc1_best 720p → height<=720"  "height<=720"  "$result"
assert_contains "avc1_best 720p → vcodec^=avc1"  "vcodec^=avc1"  "$result"

result=$(run_format "avc1_https" 0)
assert_eq "avc1_https audio → 140"       "140"              "$result"

result=$(run_format "avc1_https" 3)
assert_eq "avc1_https 720p → 140+136/…" "140+136/135/134"  "$result"

result=$(run_format "avc1_https" 6)
assert_contains "avc1_https 2160p → 140+266 (не битый 140+139)"  "140+266"  "$result"

result=$(run_format "avc1_m3u8" 3)
assert_eq "avc1_m3u8 720p"   "234+232/231/230"  "$result"

result=$(run_format "avc1_https_60fps" 3)
assert_eq "60fps 720p"       "234+298/297/296"  "$result"

result=$(run_format "avc1_m3u8_60fps" 4)
assert_eq "m3u8_60fps 1080p" "234+312/311/310/309"  "$result"

result=$(run_format "avc1_https_60fps_hdr" 3)
assert_eq "hdr 720p"         "234+698/697/696"  "$result"

result=$(run_format "old_combo" 0)
assert_eq "old_combo audio → 140"  "140"       "$result"

result=$(run_format "old_combo" 3)
assert_eq "old_combo 720p → 22/18"  "22/18"  "$result"

result=$(run_format "old_combo" 6)
assert_eq "old_combo 2160p → 38/37/22/18"  "38/37/22/18"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: cookie switch → command args"
# ══════════════════════════════════════════════════════════════

run_cookies() {
    local index="$1"
    local browser="${2:-chrome}"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$command = @()
\$comboCookiesIdx = $index
\$comboCookieBrowserItem = '$browser'
switch (\$comboCookiesIdx) {
    1 { \$command += '--cookies-from-browser', \$comboCookieBrowserItem }
    2 { \$command += '--cookies', '\`"C:\\path\\cookies.txt\`"' }
}
Write-Output (\$command -join ' ')
" 2>/dev/null
}

result=$(run_cookies 0)
assert_eq "cookies idx=0 → пустой"   ""  "$result"

result=$(run_cookies 1 "chrome")
assert_contains "cookies idx=1 → --cookies-from-browser chrome"  "--cookies-from-browser"  "$result"
assert_contains "cookies idx=1 → browser=chrome"                 "chrome"                   "$result"

result=$(run_cookies 1 "firefox")
assert_contains "cookies idx=1 → firefox"  "firefox"  "$result"

result=$(run_cookies 2)
assert_contains "cookies idx=2 → --cookies"  "--cookies"  "$result"

# ══════════════════════════════════════════════════════════════
suite "PS1 yt-dlp: proxy URL построение"
# ══════════════════════════════════════════════════════════════

run_proxy() {
    local ptype="$1" phost="$2" pport="$3" puser="$4" ppass="$5"
    $PS_CMD -NoProfile -NonInteractive -Command "
\$pType = '$ptype'
\$pHost = '$phost'
\$pPort = '$pport'
\$pUser = '$puser'
\$pPass = '$ppass'
\$proxyVal = if (-not [string]::IsNullOrWhiteSpace(\$pUser) -and -not [string]::IsNullOrWhiteSpace(\$pPass)) {
    \"\${pType}://\${pUser}:\${pPass}@\${pHost}\"
} else {
    \"\${pType}://\${pHost}\"
}
if (-not [string]::IsNullOrWhiteSpace(\$pPort)) { \$proxyVal += \":\${pPort}\" }
Write-Output \$proxyVal
" 2>/dev/null
}

result=$(run_proxy "https" "proxy.example.com" "8080" "" "")
assert_eq "proxy без auth"  "https://proxy.example.com:8080"  "$result"

result=$(run_proxy "https" "proxy.example.com" "" "" "")
assert_eq "proxy без порта"  "https://proxy.example.com"  "$result"

result=$(run_proxy "https" "proxy.example.com" "8080" "user" "pass")
assert_eq "proxy с auth"  "https://user:pass@proxy.example.com:8080"  "$result"

result=$(run_proxy "socks5" "socks.example.com" "1080" "" "")
assert_eq "socks5 proxy"  "socks5://socks.example.com:1080"  "$result"

# ══════════════════════════════════════════════════════════════
suite "Task 11: PS1 yt-dlp GUI фиксы (анализ исходника)"
# ══════════════════════════════════════════════════════════════
PROJECT_DIR="$(cd "$TESTS_DIR/.." && pwd)"
DLP_PS1="$PROJECT_DIR/yt-dlp/Downloading_from_YouTube_v15.ps1"
src="$(cat "$DLP_PS1")"

assert_not_contains "нет массового Stop-Process yt-dlp"  'Get-Process -Name "yt-dlp"'  "$src"
# Обнуление только при инициализации (1 раз), не в Stop-Download
null_cnt=$(grep -cF '$global:downloadProcess = $null' "$DLP_PS1")
assert_eq "downloadProcess обнуляется только в init (не в Stop-Download)"  "1"  "$null_cnt"
assert_contains "guard перед WaitForExit"  'if ($proc) { $proc.WaitForExit(); $exitCode = $proc.ExitCode }'  "$src"
assert_contains "merge: проверка LASTEXITCODE"  '$LASTEXITCODE -eq 0 -and (Test-Path $outputFile)'  "$src"
assert_contains "vot stderr ReadToEndAsync (нет deadlock)"  "ReadToEndAsync()"  "$src"
assert_contains "qualityMap audio=0"  '"audio" = 0'  "$src"
assert_contains "translate исключает audio (qi>=1)"  '$qi -ge 1 -and $qi -le 6'  "$src"
assert_contains "Read-Config inline # по \\s+"  "'\\s+#.*'"  "$src"
assert_not_contains "нет --no-check-certificate"  "--no-check-certificate"  "$src"
assert_contains "--download-archive из config"  "--download-archive"  "$src"
assert_contains "mix громкости из config"  'volume=$cfg_transOrigVol'  "$src"
assert_contains "Unregister-Event (утечка событий)"  "Unregister-Event"  "$src"
assert_contains "btnRemoveUrl дизейблится при загрузке"  '$btnRemoveUrl.Enabled = $false'  "$src"
assert_contains "base_dir от scriptDir"  'Combine($scriptDir, $cfg_baseDir)'  "$src"

summary
