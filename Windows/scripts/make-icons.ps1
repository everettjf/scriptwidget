# Generates the Windows icon and the MSIX tile images from the shared app icon
# (Resource/AppIcon/ScriptWidget-AppIcon-2026.png). The output is checked in;
# run this again only when the app icon changes.
#
#   powershell -File Windows/scripts/make-icons.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repository = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$source = Join-Path $repository 'Resource\AppIcon\ScriptWidget-AppIcon-2026.png'
$assets = Join-Path $repository 'Windows\package\Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
$original = [System.Drawing.Image]::FromFile($source)

function New-Scaled([int] $width, [int] $height, [double] $iconFraction = 1.0, [bool] $rounded = $false) {
    $bitmap = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $side = [Math]::Round([Math]::Min($width, $height) * $iconFraction)
    $x = [Math]::Round(($width - $side) / 2)
    $y = [Math]::Round(($height - $side) / 2)
    if ($rounded) {
        # The source icon is a full square; Windows icons look right with rounded corners.
        $radius = $side * 0.22
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $d = $radius * 2
        $path.AddArc($x, $y, $d, $d, 180, 90)
        $path.AddArc($x + $side - $d, $y, $d, $d, 270, 90)
        $path.AddArc($x + $side - $d, $y + $side - $d, $d, $d, 0, 90)
        $path.AddArc($x, $y + $side - $d, $d, $d, 90, 90)
        $path.CloseFigure()
        $graphics.SetClip($path)
    }
    $graphics.DrawImage($original, $x, $y, $side, $side)
    $graphics.Dispose()
    return $bitmap
}

function Save-Png($bitmap, [string] $name) {
    $bitmap.Save((Join-Path $assets $name), [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

# MSIX tile images: the icon on a transparent tile.
foreach ($scale in 100, 200) {
    $f = $scale / 100
    Save-Png (New-Scaled (44 * $f) (44 * $f) 1.0 $true) "Square44x44Logo.scale-$scale.png"
    Save-Png (New-Scaled (150 * $f) (150 * $f) 0.6 $true) "Square150x150Logo.scale-$scale.png"
    Save-Png (New-Scaled (310 * $f) (150 * $f) 0.6 $true) "Wide310x150Logo.scale-$scale.png"
    Save-Png (New-Scaled (50 * $f) (50 * $f) 1.0 $true) "StoreLogo.scale-$scale.png"
}
foreach ($size in 16, 24, 32, 48, 256) {
    Save-Png (New-Scaled $size $size 1.0 $true) "Square44x44Logo.targetsize-$size.png"
    Save-Png (New-Scaled $size $size 1.0 $true) "Square44x44Logo.targetsize-${size}_altform-unplated.png"
}

# ScriptWidget.ico: PNG-compressed entries, which Windows Vista and later read.
$sizes = 16, 20, 24, 32, 40, 48, 64, 256
$images = foreach ($size in $sizes) {
    $bitmap = New-Scaled $size $size 1.0 $true
    $stream = New-Object System.IO.MemoryStream
    $bitmap.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    , $stream.ToArray()
}
$file = New-Object System.IO.MemoryStream
$writer = New-Object System.IO.BinaryWriter $file
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($index = 0; $index -lt $sizes.Count; $index++) {
    $size = $sizes[$index]
    $writer.Write([byte]($size -band 0xFF)); $writer.Write([byte]($size -band 0xFF))
    $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32)
    $writer.Write([uint32]$images[$index].Length); $writer.Write([uint32]$offset)
    $offset += $images[$index].Length
}
foreach ($image in $images) { $writer.Write($image) }
[System.IO.File]::WriteAllBytes((Join-Path $assets 'ScriptWidget.ico'), $file.ToArray())
$original.Dispose()
Write-Host "icons -> $assets"
