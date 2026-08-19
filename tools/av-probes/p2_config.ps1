# ПРОБА 2 — разбор ini в хеш-таблицу, «первое вхождение ключа выигрывает».
# В v16 на этом месте было простое присваивание, в v17 добавилась проверка ContainsKey.
$script:_configCache = @{}
$curSection = "download"
$val = "720"
foreach ($line in @("default_quality = 720", "default_quality = 360")) {
    if ($line -match '^([^=]+?)\s*=\s*(.*)') {
        $val = $Matches[2]
        $_k = "${curSection}::$($Matches[1].Trim())"
        if (-not $script:_configCache.ContainsKey($_k)) { $script:_configCache[$_k] = $val }
    }
}
Write-Host "ПРОБА 2: OK — значение: $($script:_configCache['download::default_quality']) (ожидалось 720)"
Read-Host "Enter для выхода"
