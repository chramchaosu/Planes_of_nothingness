<#
.SYNOPSIS
    Cuts a full comic page into its separate panels.

.DESCRIPTION
    Finds every panel as a block of colour on the white page, sorts the panels
    in reading order (top to bottom, then left to right) and saves them as
    01.jpg, 02.jpg, ... in the output folder. Each panel keeps its frame plus a
    small white margin, and is scaled down to at most -MaxSide pixels.

    Check the result: a speech bubble that bridges the white gap between two
    panels makes them one block.

.EXAMPLE
    .\tools\split-page.ps1 -Page 'C:\path\page.jpg' -OutDir comic\season-01\episode-06
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Page,
    [Parameter(Mandatory)][string]$OutDir,
    [int]$MaxSide = 3000,
    [int]$Margin = 16
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$step = 8             # analyse a copy shrunk 8 times; plenty to find panels, and fast
$minBlockCells = 2000 # ignore specks such as a signature

$source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $Page))
try {
    # 1. A small copy of the page, and a map of which cells are "not white".
    $w = [int]($source.Width / $step)
    $h = [int]($source.Height / $step)
    $small = [System.Drawing.Bitmap]::new($w, $h)
    $graphics = [System.Drawing.Graphics]::FromImage($small)
    $graphics.DrawImage($source, 0, 0, $w, $h)
    $graphics.Dispose()

    $ink = New-Object 'bool[,]' $w, $h
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $small.GetPixel($x, $y)
            $ink[$x, $y] = -not ($c.R -gt 225 -and $c.G -gt 225 -and $c.B -gt 225)
        }
    }
    $small.Dispose()

    # 2. Group touching "not white" cells into blocks and keep each block's bounding box.
    $seen = New-Object 'bool[,]' $w, $h
    $panels = [System.Collections.Generic.List[object]]::new()
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            if (-not $ink[$x, $y] -or $seen[$x, $y]) { continue }
            $stack = [System.Collections.Generic.Stack[int[]]]::new()
            $stack.Push(@($x, $y)); $seen[$x, $y] = $true
            $x0 = $x1 = $x; $y0 = $y1 = $y; $cells = 0
            while ($stack.Count) {
                $p = $stack.Pop(); $cells++
                $x0 = [math]::Min($x0, $p[0]); $x1 = [math]::Max($x1, $p[0])
                $y0 = [math]::Min($y0, $p[1]); $y1 = [math]::Max($y1, $p[1])
                foreach ($d in @(@(1, 0), @(-1, 0), @(0, 1), @(0, -1))) {
                    $nx = $p[0] + $d[0]; $ny = $p[1] + $d[1]
                    if ($nx -ge 0 -and $ny -ge 0 -and $nx -lt $w -and $ny -lt $h -and $ink[$nx, $ny] -and -not $seen[$nx, $ny]) {
                        $seen[$nx, $ny] = $true; $stack.Push(@($nx, $ny))
                    }
                }
            }
            if ($cells -gt $minBlockCells) {
                $panels.Add([pscustomobject]@{
                    X = $x0 * $step; Y = $y0 * $step
                    Width = ($x1 - $x0 + 1) * $step; Height = ($y1 - $y0 + 1) * $step
                })
            }
        }
    }
    if ($panels.Count -eq 0) { throw "No panels found on $Page." }

    # 3. Reading order: panels whose tops are close together form one row, read left to right.
    $rowTolerance = $source.Height * 0.03
    $ordered = $panels | Sort-Object Y | ForEach-Object -Begin { $rowTop = -1e9; $row = -1 } -Process {
        if ($_.Y - $rowTop -gt $rowTolerance) { $row++; $rowTop = $_.Y }
        $_ | Add-Member -NotePropertyName Row -NotePropertyValue $row -PassThru
    } | Sort-Object Row, X

    # 4. Cut, scale and save each panel.
    $jpeg = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $quality = [System.Drawing.Imaging.EncoderParameters]::new(1)
    $quality.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]92)
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    $number = 0
    foreach ($panel in $ordered) {
        $number++
        $x = [math]::Max(0, $panel.X - $Margin)
        $y = [math]::Max(0, $panel.Y - $Margin)
        $cropW = [math]::Min($source.Width - $x, $panel.Width + 2 * $Margin)
        $cropH = [math]::Min($source.Height - $y, $panel.Height + 2 * $Margin)
        $scale = [math]::Min([double]1, [double]$MaxSide / [math]::Max($cropW, $cropH))
        $outW = [int][math]::Round($cropW * $scale)
        $outH = [int][math]::Round($cropH * $scale)

        $bitmap = [System.Drawing.Bitmap]::new($outW, $outH)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, $outW, $outH),
                [System.Drawing.Rectangle]::new($x, $y, $cropW, $cropH), [System.Drawing.GraphicsUnit]::Pixel)
            $file = Join-Path $OutDir ('{0:00}.jpg' -f $number)
            $bitmap.Save($file, $jpeg, $quality)
            Write-Host "Saved $file (${outW}x$outH)"
        }
        finally {
            $graphics.Dispose()
            $bitmap.Dispose()
        }
    }
}
finally {
    $source.Dispose()
}
