<#
.SYNOPSIS
    Builds index.html (the whole app in one file) and the home-screen icons.

.DESCRIPTION
    Reads comic/comic.json, embeds every page image listed there directly into
    src/reader.html (as base64 data URIs), and writes one self-contained HTML
    file that works offline with no other files next to it. GitHub Pages
    serves it as the website; it can also be downloaded and opened as is.

    Also crops the app icons (icon-180/192/512.png) from a comic page.

    Works in Windows PowerShell 5.1 and PowerShell 7+.

.EXAMPLE
    .\build.ps1
#>
[CmdletBinding()]
param(
    [string]$OutFile = (Join-Path $PSScriptRoot 'index.html')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$comicDir     = Join-Path $PSScriptRoot 'comic'
$templatePath = Join-Path $PSScriptRoot 'src/reader.html'
$placeholder  = '__COMIC_DATA__'

$mimeTypes = @{ '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.webp' = 'image/webp' }

# Pages larger than this (on their longest side) are scaled down in the built file.
# Phones gain nothing from more pixels, and the app loads faster. Originals are untouched.
$maxPageSide = 1600
$jpegQuality = 85

function Get-PageImage([string]$Path, [string]$MimeType) {
    # Returns the image bytes to embed plus their width and height
    # (the reader uses the size to reserve space before an image is drawn).
    $image = [System.Drawing.Image]::FromFile($Path)
    try {
        $scale = [math]::Min([double]1, [double]$maxPageSide / [math]::Max($image.Width, $image.Height))
        if ($scale -ge 1) {
            return @{ bytes = [IO.File]::ReadAllBytes($Path); mime = $MimeType; width = $image.Width; height = $image.Height }
        }

        $width  = [int][math]::Round($image.Width * $scale)
        $height = [int][math]::Round($image.Height * $scale)
        $resized = [System.Drawing.Bitmap]::new($width, $height)
        $graphics = [System.Drawing.Graphics]::FromImage($resized)
        $stream = [IO.MemoryStream]::new()
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($image, 0, 0, $width, $height)

            $encoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
            $options = [System.Drawing.Imaging.EncoderParameters]::new(1)
            $options.Param[0] = [System.Drawing.Imaging.EncoderParameter]::new([System.Drawing.Imaging.Encoder]::Quality, [long]$jpegQuality)
            $resized.Save($stream, $encoder, $options)
            return @{ bytes = $stream.ToArray(); mime = 'image/jpeg'; width = $width; height = $height }
        }
        finally {
            $stream.Dispose()
            $graphics.Dispose()
            $resized.Dispose()
        }
    }
    finally { $image.Dispose() }
}

$manifest = Get-Content (Join-Path $comicDir 'comic.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Image data is large, so it is not passed through ConvertTo-Json (Windows PowerShell
# limits its size). Each page gets a short token instead, swapped for the data afterwards.
$imageData = [System.Collections.Generic.List[string]]::new()

$seasons = @(foreach ($season in $manifest.seasons) {
    $episodes = @(foreach ($episode in $season.episodes) {
        $pages = @(foreach ($page in $episode.pages) {
            $path = Join-Path $comicDir (Join-Path $season.folder (Join-Path $episode.folder $page.file))
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Page image not found: $path (listed in comic/comic.json)"
            }
            $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
            if (-not $mimeTypes.ContainsKey($extension)) {
                throw "Unsupported image type '$extension' for $path. Use .jpg, .png or .webp."
            }

            $picture = Get-PageImage $path $mimeTypes[$extension]
            $imageData.Add("data:$($picture.mime);base64,$([Convert]::ToBase64String($picture.bytes))")

            [ordered]@{
                src    = "__IMAGE_$($imageData.Count - 1)__"
                text   = $page.text
                width  = $picture.width
                height = $picture.height
            }
        })

        $entry = [ordered]@{ number = $episode.number; pages = $pages }
        if ($episode.PSObject.Properties['title']) { $entry.title = $episode.title }
        $entry
    })

    [ordered]@{ number = $season.number; episodes = $episodes }
})

$json = ConvertTo-Json -InputObject ([ordered]@{ title = $manifest.title; seasons = $seasons }) -Depth 10 -Compress

# Base64 never contains quotes or backslashes, so it can go straight into the JSON.
$builder = [System.Text.StringBuilder]::new($json)
for ($i = 0; $i -lt $imageData.Count; $i++) {
    [void]$builder.Replace("__IMAGE_$($i)__", $imageData[$i])
}
# "</" inside a <script> block could end it early; "<\/" means the same in JSON.
$json = $builder.ToString().Replace('</', '<\/')

$template = [IO.File]::ReadAllText($templatePath)
if (-not $template.Contains($placeholder)) {
    throw "The placeholder $placeholder is missing from src/reader.html."
}
$html = $template.Replace($placeholder, $json)

[IO.File]::WriteAllText($OutFile, $html, [System.Text.UTF8Encoding]::new($false))

$sizeMb = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1MB, 2)
Write-Host "Built $OutFile ($($imageData.Count) pages, $sizeMb MB)"

# ---------- App icons ----------

# A square cut from the swirl of the Pit (Season 1, Episode 1, page 9), above its caption.
$iconSource = Join-Path $comicDir 'season-01/episode-01/09.jpg'
$iconCrop   = [System.Drawing.Rectangle]::new(73, 170, 580, 580)

$source = [System.Drawing.Image]::FromFile($iconSource)
try {
    foreach ($size in 180, 192, 512) {
        $icon = [System.Drawing.Bitmap]::new($size, $size)
        $graphics = [System.Drawing.Graphics]::FromImage($icon)
        try {
            $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $graphics.DrawImage($source, [System.Drawing.Rectangle]::new(0, 0, $size, $size), $iconCrop, [System.Drawing.GraphicsUnit]::Pixel)
            $icon.Save((Join-Path $PSScriptRoot "icon-$size.png"), [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally {
            $graphics.Dispose()
            $icon.Dispose()
        }
    }
}
finally {
    $source.Dispose()
}
Write-Host 'Built icon-180.png, icon-192.png, icon-512.png'
