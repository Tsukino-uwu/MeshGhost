# Crops and upscales a region of the last screenshot, so a sprite in a 240x160 GBA frame is legible.
# Nearest-neighbour, so no smoothing invents detail that is not there.
param([int]$X = 96, [int]$Y = 48, [int]$W = 96, [int]$H = 64, [int]$Scale = 4,
      [string]$Game = "emerald",
      [string]$In = "",
      [string]$Out = "")
# Per game, so a session on one adapter cannot bury another's; from the script's own folder, never an absolute path.
if (-not $In)  { $In  = Join-Path $PSScriptRoot "shots\$Game\shot.png" }
if (-not $Out) { $Out = Join-Path $PSScriptRoot "shots\$Game\zoom.png" }
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($In)
$crop = New-Object System.Drawing.Bitmap -ArgumentList $W, $H
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,$W,$H), (New-Object System.Drawing.Rectangle $X,$Y,$W,$H), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$ow = $W * $Scale; $oh = $H * $Scale
# Not $out: PowerShell variables are case-insensitive, so it would be the $Out path parameter.
$dest = New-Object System.Drawing.Bitmap -ArgumentList $ow, $oh
$g2 = [System.Drawing.Graphics]::FromImage($dest)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g2.DrawImage($crop, 0, 0, $ow, $oh)
$g2.Dispose(); $dest.Save($Out); $src.Dispose(); $crop.Dispose(); $dest.Dispose()
