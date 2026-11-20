<#
.SYNOPSIS
  Makes promo images for an add-on: promo\banner.png (1280x720) and promo\logo.png (512x512).

.DESCRIPTION
  Same style as the other add-ons' promos: a vertical gradient, art on the left,
  an outlined title, a colored subtitle and up to five bullets.

  Art is either item textures (-Icons, drawn pixel-sharp) or a built-in drawing (-Art eyes|bubble).

    powershell -ExecutionPolicy Bypass -File promo.ps1 -Repo ..\bow-variants -Title "BOW VARIANTS" `
      -Subtitle "Two new bows" -Bullets "One|Two" -Top "#1b2440" -Bottom "#3b5ba0" -Accent "#9fd0ff" `
      -Icons "Bow Variants RP\textures\items\explosive_bow.png|Bow Variants RP\textures\items\levitation_bow.png"
#>
param(
  [Parameter(Mandatory)][string]$Repo,
  [Parameter(Mandatory)][string]$Title,
  [Parameter(Mandatory)][string]$Subtitle,
  [string[]]$Bullets = @(),
  [string]$Top = '#13252b',
  [string]$Bottom = '#2a7a80',
  [string]$Accent = '#9ff0ff',
  [string[]]$Icons = @(),
  [ValidateSet('', 'eyes', 'bubble')][string]$Art = '',
  [string]$LogoTitle
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$Repo = (Resolve-Path -LiteralPath $Repo).Path
$outDir = Join-Path $Repo 'promo'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
if (-not $LogoTitle) { $LogoTitle = $Title }
# powershell -File passes a list as one string, so lists can also be separated with |.
$Bullets = @($Bullets | ForEach-Object { $_ -split '\|' } | Where-Object { $_ })
$Icons = @($Icons | ForEach-Object { $_ -split '\|' } | Where-Object { $_ })

function Get-Color([string]$hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }

function New-Canvas([int]$w, [int]$h) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
  $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, (Get-Color $Top), (Get-Color $Bottom), 90
  $g.FillRectangle($brush, $rect)
  return $bmp, $g
}

# Outlined title text, like the other banners.
function Draw-Title($g, [string]$text, [single]$size, [single]$x, [single]$y, [string]$align = 'Near') {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = $align
  $family = New-Object System.Drawing.FontFamily 'Arial Black'
  $path.AddString($text, $family, 0, $size, (New-Object System.Drawing.PointF $x, $y), $fmt)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 15, 15, 20)), ($size / 7)
  $pen.LineJoin = 'Round'
  $g.DrawPath($pen, $path)
  $g.FillPath([System.Drawing.Brushes]::White, $path)
}

# Fits the title on one line by shrinking it.
function Get-TitleSize($g, [string]$text, [single]$start, [single]$maxWidth) {
  $size = $start
  $family = New-Object System.Drawing.FontFamily 'Arial Black'
  while ($size -gt 20) {
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddString($text, $family, 0, $size, (New-Object System.Drawing.PointF 0, 0), (New-Object System.Drawing.StringFormat))
    if ($path.GetBounds().Width + $size / 7 -le $maxWidth) { break }
    $size -= 2
  }
  return $size
}

function Draw-Art($g, [single]$cx, [single]$cy, [single]$size) {
  if ($Icons.Count) {
    $g.InterpolationMode = 'NearestNeighbor'; $g.PixelOffsetMode = 'Half'
    $n = $Icons.Count
    $each = if ($n -eq 1) { $size } else { $size * 0.72 }
    for ($i = 0; $i -lt $n; $i++) {
      $img = [System.Drawing.Image]::FromFile((Join-Path $Repo $Icons[$i]))
      $offset = if ($n -eq 1) { 0 } else { ($i / ($n - 1) - 0.5) * $size * 0.45 }
      $g.DrawImage($img, [single]($cx - $each / 2 + $offset), [single]($cy - $each / 2 + $offset), [single]$each, [single]$each)
    }
    $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'Default'
  }
  elseif ($Art -eq 'eyes') {
    foreach ($dx in @(-0.25, 0.25)) {
      $ex = $cx + $dx * $size; $w = $size * 0.36; $h = $size * 0.15
      # Soft glow: a radial gradient that fades to nothing.
      $gw = $w * 2.2; $gh = $h * 4
      $glow = New-Object System.Drawing.Drawing2D.GraphicsPath
      $glow.AddEllipse([single]($ex - $gw / 2), [single]($cy - $gh / 2), [single]$gw, [single]$gh)
      $pgb = New-Object System.Drawing.Drawing2D.PathGradientBrush $glow
      $pgb.CenterColor = [System.Drawing.Color]::FromArgb(110, 255, 235, 215)
      $pgb.SurroundColors = @([System.Drawing.Color]::FromArgb(0, 255, 235, 215))
      $g.FillPath($pgb, $glow)
      $g.FillEllipse((New-Object System.Drawing.SolidBrush (Get-Color '#f4efe6')), [single]($ex - $w / 2), [single]($cy - $h / 2), [single]$w, [single]$h)
      $p = $h * 0.55
      $g.FillEllipse((New-Object System.Drawing.SolidBrush (Get-Color '#7a0c0c')), [single]($ex - $p / 2), [single]($cy - $p / 2), [single]$p, [single]$p)
      $g.FillEllipse([System.Drawing.Brushes]::Black, [single]($ex - $p / 4), [single]($cy - $p / 4), [single]($p / 2), [single]($p / 2))
    }
  }
  elseif ($Art -eq 'bubble') {
    $w = $size; $h = $size * 0.68; $x = $cx - $w / 2; $y = $cy - $h / 2 - $size * 0.08; $r = $size * 0.16
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc([single]$x, [single]$y, [single]($r * 2), [single]($r * 2), 180, 90)
    $path.AddArc([single]($x + $w - $r * 2), [single]$y, [single]($r * 2), [single]($r * 2), 270, 90)
    $path.AddArc([single]($x + $w - $r * 2), [single]($y + $h - $r * 2), [single]($r * 2), [single]($r * 2), 0, 90)
    $path.AddLine([single]($x + $w * 0.38), [single]($y + $h), [single]($x + $w * 0.18), [single]($y + $h + $size * 0.2))
    $path.AddLine([single]($x + $w * 0.2), [single]($y + $h), [single]($x + $r), [single]($y + $h))
    $path.AddArc([single]$x, [single]($y + $h - $r * 2), [single]($r * 2), [single]($r * 2), 90, 90)
    $path.CloseFigure()
    $g.FillPath([System.Drawing.Brushes]::White, $path)
    $font = New-Object System.Drawing.Font 'Arial Black', ($size * 0.17), ([System.Drawing.GraphicsUnit]::Pixel)
    $fmt = New-Object System.Drawing.StringFormat; $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'
    $fmt.FormatFlags = 'NoWrap'
    $g.DrawString('#@$%!', $font, (New-Object System.Drawing.SolidBrush (Get-Color $Top)), (New-Object System.Drawing.RectangleF ([single]$x), ([single]$y), ([single]$w), ([single]$h)), $fmt)
  }
}

# Banner
$bmp, $g = New-Canvas 1280 720
Draw-Art $g 280 360 380
$titleSize = Get-TitleSize $g $Title 92 680
Draw-Title $g $Title $titleSize 570 ($(if ($Bullets.Count) { 130 } else { 250 }))
$subFont = New-Object System.Drawing.Font 'Segoe UI Semibold', 28, ([System.Drawing.GraphicsUnit]::Pixel)
$subY = $(if ($Bullets.Count) { 240 } else { 360 })
$g.DrawString($Subtitle, $subFont, (New-Object System.Drawing.SolidBrush (Get-Color $Accent)), 572, $subY)
$bulletFont = New-Object System.Drawing.Font 'Segoe UI', 27, ([System.Drawing.GraphicsUnit]::Pixel)
$y = 330
foreach ($b in $Bullets | Select-Object -First 5) {
  $g.FillEllipse((New-Object System.Drawing.SolidBrush (Get-Color $Accent)), 569, ($y + 13), 13, 13)
  $g.DrawString($b, $bulletFont, [System.Drawing.Brushes]::White, 596, $y)
  $y += 58
}
$bmp.Save((Join-Path $outDir 'banner.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

# Logo
$bmp, $g = New-Canvas 512 512
Draw-Art $g 256 205 270
$logoSize = Get-TitleSize $g $LogoTitle 64 440
Draw-Title $g $LogoTitle $logoSize 256 (410 - $logoSize / 2) 'Center'
$bmp.Save((Join-Path $outDir 'logo.png'), [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()

Write-Host "Wrote $outDir\banner.png and logo.png"
