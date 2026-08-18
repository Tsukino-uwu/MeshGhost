# MeshGhost - crop and upscale a region of the last screenshot so sprites are legible.
# A 240x160 GBA frame is too small to judge a sprite in; nearest-neighbour upscaling keeps the
# pixels honest (no smoothing inventing detail that is not there).
param([int]$X = 96, [int]$Y = 48, [int]$W = 96, [int]$H = 64, [int]$Scale = 4,
      [string]$Game = "emerald",
      [string]$In = "",
      [string]$Out = "")
# Screenshots live in dev-scripts/shots/<game>/ so a session on one adapter cannot bury another's.
if (-not $In)  { $In  = "C:\dev\MeshGhost\dev-scripts\shots\$Game\shot.png" }
if (-not $Out) { $Out = "C:\dev\MeshGhost\dev-scripts\shots\$Game\zoom.png" }
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile($In)
$crop = New-Object System.Drawing.Bitmap -ArgumentList $W, $H
$g = [System.Drawing.Graphics]::FromImage($crop)
$g.DrawImage($src, (New-Object System.Drawing.Rectangle 0,0,$W,$H), (New-Object System.Drawing.Rectangle $X,$Y,$W,$H), [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$ow = $W * $Scale; $oh = $H * $Scale
# NOTE: PowerShell variables are CASE-INSENSITIVE, so a bitmap named $out and the path
# parameter $Out are the same variable -- which silently made the bitmap a string.
$dest = New-Object System.Drawing.Bitmap -ArgumentList $ow, $oh
$g2 = [System.Drawing.Graphics]::FromImage($dest)
$g2.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$g2.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::Half
$g2.DrawImage($crop, 0, 0, $ow, $oh)
$g2.Dispose(); $dest.Save($Out); $src.Dispose(); $crop.Dispose(); $dest.Dispose()
