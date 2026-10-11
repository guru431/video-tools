# make_icons.ps1 — рисует значки обоих EXE.
#
#   powershell -File tools\make_icons.ps1
#
# Пишет ffmpeg/converter.ico и yt-dlp/downloader.ico. Файлы коммитятся: их берут
# оба build_exe.ps1 (-iconFile), и без них падает smoke-сборка в CI. После запуска
# пересобираются оба EXE — значок числится в $exeDeps (tools/check_release.ps1).
#
# Значки нарисованы кодом, а не взяты готовыми: в публичном репозитории лежит
# исходник картинки, а не только бинарь, и чужих логотипов в ней нет (знаки YouTube
# и FFmpeg — товарные).
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $PSScriptRoot

# Кадры ICO. 256 хранится PNG, остальные — несжатым 32-битным DIB: так пишут значки
# сами Windows и Visual Studio. PNG-кадр меньше 256 читают не все загрузчики, а
# 256 в DIB — это четверть мегабайта на значок.
$frameSizes = 16, 24, 32, 48, 64, 256

function Pt([double]$X, [double]$Y) { return New-Object System.Drawing.PointF([single]$X, [single]$Y) }

function New-RoundRect([double]$X, [double]$Y, [double]$W, [double]$H, [double]$R) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($R -le 0) {
        $p.AddRectangle((New-Object System.Drawing.RectangleF([single]$X, [single]$Y, [single]$W, [single]$H)))
        return $p
    }
    $d = 2 * $R
    $p.AddArc([single]$X, [single]$Y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($X + $W - $d), [single]$Y, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($X + $W - $d), [single]($Y + $H - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$X, [single]($Y + $H - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

# Конвертер: кадр киноплёнки с перфорацией и треугольником «play» (вырезаны —
# сквозь них видна плашка). Все числа — в пикселях кадра.
#
# Мелкие кадры заданы таблицей, а не масштабом: перфорация мастера на 16 px — это
# 1.4 px отверстия с шагом 2.5 px, сглаживание превращает её в серую полосу. В
# таблице каждое отверстие и каждый зазор — целое число пикселей.
function Get-FilmGeometry([int]$Size) {
    switch ($Size) {
        16 { return @{ Frame = 2, 3, 12, 10; R = 1.5; HoleW = 1; HoleH = 1; HoleR = 0
                       HoleX = 3, 6, 9, 12; HoleY = 4, 11
                       Play = (Pt 6.5 6), (Pt 6.5 10), (Pt 10 8) } }
        24 { return @{ Frame = 4, 5, 16, 14; R = 2; HoleW = 2; HoleH = 2; HoleR = 0
                       HoleX = 5, 9, 13, 17; HoleY = 6, 16
                       Play = (Pt 10 9.5), (Pt 10 14.5), (Pt 14.5 12) } }
        32 { return @{ Frame = 5, 7, 22, 18; R = 3; HoleW = 3; HoleH = 2; HoleR = 0
                       HoleX = 7, 12, 17, 22; HoleY = 9, 21
                       Play = (Pt 13.5 12.5), (Pt 13.5 19.5), (Pt 19.5 16) } }
    }
    $s = $Size / 256.0
    return @{ Frame = (40 * $s), (60 * $s), (176 * $s), (136 * $s); R = 22 * $s
              HoleW = 22 * $s; HoleH = 17 * $s; HoleR = 5 * $s
              HoleX = (0..3 | ForEach-Object { (57.6 + 39.6 * $_) * $s }); HoleY = (73 * $s), (166 * $s)
              Play = (Pt (112 * $s) (104 * $s)), (Pt (112 * $s) (152 * $s)), (Pt (154 * $s) (128 * $s)) }
}

function Add-FilmGlyph($G, $Brush, [int]$Size) {
    $m = Get-FilmGeometry $Size
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.FillMode = 'Alternate'
    $f = $m.Frame
    $p.AddPath((New-RoundRect $f[0] $f[1] $f[2] $f[3] $m.R), $false)
    foreach ($y in $m.HoleY) {
        foreach ($x in $m.HoleX) { $p.AddPath((New-RoundRect $x $y $m.HoleW $m.HoleH $m.HoleR), $false) }
    }
    $p.AddPolygon([System.Drawing.PointF[]]$m.Play)
    $G.FillPath($Brush, $p)
}

# Загрузчик: стрелка вниз в кольце. Числа — в единицах мастера 256×256; у мелких
# кадров линии толще в долях кадра (иначе на 16 px это линия в один пиксель),
# а толщина стрелки подобрана так, чтобы ствол ложился на целые столбцы пикселей.
function Add-ArrowGlyph($G, $Brush, [int]$Size) {
    switch ($Size) {
        16      { $R = 80.0; $ringW = 32.0; $arrowW = 32.0; $A = 34.0 }
        24      { $R = 78.0; $ringW = 64.0 / 3; $arrowW = 64.0 / 3; $A = 36.0 }
        32      { $R = 76.0; $ringW = 20.0; $arrowW = 24.0; $A = 36.0 }
        default { $R = 76.0; $ringW = 17.0; $arrowW = 19.0; $A = 38.0 }
    }
    $s = $Size / 256.0
    $c = 128.0 * $s
    $ring = New-Object System.Drawing.Pen($Brush, [single]($ringW * $s))
    $G.DrawEllipse($ring, [single]($c - $R * $s), [single]($c - $R * $s), [single](2 * $R * $s), [single](2 * $R * $s))
    $pen = New-Object System.Drawing.Pen($Brush, [single]($arrowW * $s))
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'; $pen.LineJoin = 'Round'
    $tip = $c + $A * $s
    $wing = 0.8 * $A * $s
    $G.DrawLine($pen, (Pt $c ($c - $A * $s)), (Pt $c $tip))
    $G.DrawLines($pen, [System.Drawing.PointF[]]@((Pt ($c - $wing) ($tip - $wing)), (Pt $c $tip), (Pt ($c + $wing) ($tip - $wing))))
}

function New-IconFrame([string]$App, [int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    # Half: целая координата — граница пикселя, и край плашки по сетке остаётся резким.
    $g.PixelOffsetMode = 'Half'
    $g.Clear([System.Drawing.Color]::Transparent)

    # Поле вокруг плашки — целое число пикселей; на 16 px плашка занимает кадр целиком.
    $margin = switch ($Size) { 16 { 0 } 24 { 1 } 32 { 1 } 48 { 2 } 64 { 3 } default { [int][Math]::Round($Size * 12 / 256.0) } }
    $side = $Size - 2 * $margin
    $colors = if ($App -eq 'converter') { '#4C93FF', '#6B46F2' } else { '#34D391', '#0B9A8D' }
    $tile = New-Object System.Drawing.Drawing2D.LinearGradientBrush(
        (Pt 0 0), (Pt $Size $Size),
        [System.Drawing.ColorTranslator]::FromHtml($colors[0]),
        [System.Drawing.ColorTranslator]::FromHtml($colors[1]))
    $g.FillPath($tile, (New-RoundRect $margin $margin $side $side ($side * 0.22)))

    $white = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    if ($App -eq 'converter') { Add-FilmGlyph $g $white $Size } else { Add-ArrowGlyph $g $white $Size }
    $g.Dispose()
    return $bmp
}

# Кадр как DIB внутри ICO: BITMAPINFOHEADER с удвоенной высотой, строки BGRA снизу
# вверх, затем однобитная AND-маска (строка выровнена на 32 бита; бит взведён у
# полностью прозрачного пикселя — её читают те, кто не понимает альфа-канал).
function Get-DibBytes([System.Drawing.Bitmap]$Bmp) {
    $n = $Bmp.Width
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]40); $bw.Write([int]$n); $bw.Write([int](2 * $n))
    $bw.Write([int16]1); $bw.Write([int16]32); $bw.Write([int]0)
    $bw.Write([int]($n * $n * 4)); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0); $bw.Write([int]0)
    $maskRow = [int][Math]::Ceiling($n / 32.0) * 4
    $mask = New-Object byte[] ($maskRow * $n)
    for ($y = $n - 1; $y -ge 0; $y--) {
        for ($x = 0; $x -lt $n; $x++) {
            $c = $Bmp.GetPixel($x, $y)
            $bw.Write([byte]$c.B); $bw.Write([byte]$c.G); $bw.Write([byte]$c.R); $bw.Write([byte]$c.A)
            if ($c.A -eq 0) {
                $i = ($n - 1 - $y) * $maskRow + ($x -shr 3)
                $mask[$i] = $mask[$i] -bor (0x80 -shr ($x -band 7))
            }
        }
    }
    $bw.Write($mask)
    $bw.Flush()
    return , $ms.ToArray()
}

function Get-PngBytes([System.Drawing.Bitmap]$Bmp) {
    $ms = New-Object System.IO.MemoryStream
    $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    return , $ms.ToArray()
}

function Write-Ico([string]$Path, [string]$App) {
    $images = @()
    foreach ($size in $frameSizes) {
        $bmp = New-IconFrame $App $size
        $bytes = if ($size -ge 256) { Get-PngBytes $bmp } else { Get-DibBytes $bmp }
        $images += , @{ Size = $size; Bytes = $bytes }
        $bmp.Dispose()
    }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    # ICONDIR: reserved, тип 1 (значок), число кадров.
    $bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$images.Count)
    $offset = 6 + 16 * $images.Count
    foreach ($img in $images) {
        # ICONDIRENTRY: ширина и высота — по байту, 256 записывается нулём.
        $dim = [byte]($img.Size % 256)
        $bw.Write($dim); $bw.Write($dim); $bw.Write([byte]0); $bw.Write([byte]0)
        $bw.Write([uint16]1); $bw.Write([uint16]32)
        $bw.Write([uint32]$img.Bytes.Length); $bw.Write([uint32]$offset)
        $offset += $img.Bytes.Length
    }
    foreach ($img in $images) { $bw.Write([byte[]]$img.Bytes) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    Write-Host ("{0}: {1} кадров, {2} КБ" -f $Path, $images.Count, [Math]::Round($ms.Length / 1KB))
}

Write-Ico (Join-Path $root 'ffmpeg/converter.ico')  'converter'
Write-Ico (Join-Path $root 'yt-dlp/downloader.ico') 'downloader'
