<#
.SYNOPSIS
    Builds the app: index.html, the pages/ folder of comic pictures, and the icons.

.DESCRIPTION
    Reads comic/comic.json and, for every page listed there, writes a phone-sized
    copy into pages/. Each file name ends with a fingerprint of its contents
    (e.g. s01e03-04-1a2b3c4d.jpg), so a picture that changes gets a new name and
    phones never keep showing an old version.

    The list of seasons, episodes and pages is embedded into src/reader.html,
    which is written out as index.html. GitHub Pages serves index.html, pages/
    and the rest as the website.

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
$pagesDir     = Join-Path $PSScriptRoot 'pages'
$templatePath = Join-Path $PSScriptRoot 'src/reader.html'
$placeholder  = '__COMIC_DATA__'

$extensions = @{ 'image/jpeg' = '.jpg'; 'image/png' = '.png'; 'image/webp' = '.webp' }
$mimeTypes  = @{ '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.png' = 'image/png'; '.webp' = 'image/webp' }

# Pages larger than this (on their longest side) are scaled down for the app.
# Phones gain nothing from more pixels, and the app loads faster. Originals are untouched.
$maxPageSide = 1600
$jpegQuality = 85

function Get-PageImage([string]$Path, [string]$MimeType) {
    # Returns the image bytes to publish plus their width and height
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

function Get-Fingerprint([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash($Bytes)[0..3] | ForEach-Object { $_.ToString('x2') })) }
    finally { $sha.Dispose() }
}

$manifest = Get-Content (Join-Path $comicDir 'comic.json') -Raw -Encoding UTF8 | ConvertFrom-Json

# Start pages/ fresh so pictures that are no longer used disappear.
if (Test-Path -LiteralPath $pagesDir) { Remove-Item -LiteralPath $pagesDir -Recurse -Force }
New-Item -ItemType Directory -Path $pagesDir | Out-Null

$pageCount = 0
$seasons = @(foreach ($season in $manifest.seasons) {
    $episodes = @(foreach ($episode in $season.episodes) {
        $pageNumber = 0
        $pages = @(foreach ($page in $episode.pages) {
            $pageNumber++
            $path = Join-Path $comicDir (Join-Path $season.folder (Join-Path $episode.folder $page.file))
            if (-not (Test-Path -LiteralPath $path)) {
                throw "Page image not found: $path (listed in comic/comic.json)"
            }
            $extension = [IO.Path]::GetExtension($path).ToLowerInvariant()
            if (-not $mimeTypes.ContainsKey($extension)) {
                throw "Unsupported image type '$extension' for $path. Use .jpg, .png or .webp."
            }

            $picture = Get-PageImage $path $mimeTypes[$extension]
            $name = 's{0:00}e{1:00}-{2:00}-{3}{4}' -f $season.number, $episode.number, $pageNumber,
                (Get-Fingerprint $picture.bytes), $extensions[$picture.mime]
            [IO.File]::WriteAllBytes((Join-Path $pagesDir $name), $picture.bytes)
            $pageCount++

            [ordered]@{
                src    = "pages/$name"
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
# "</" inside a <script> block could end it early; "<\/" means the same in JSON.
$json = $json.Replace('</', '<\/')

$template = [IO.File]::ReadAllText($templatePath)
if (-not $template.Contains($placeholder)) {
    throw "The placeholder $placeholder is missing from src/reader.html."
}
$html = $template.Replace($placeholder, $json)

# A fingerprint of this version, so a running app can tell when a newer one is online.
$buildId = Get-Fingerprint ([System.Text.Encoding]::UTF8.GetBytes($html))
$html = $html.Replace('__BUILD_ID__', $buildId)

[IO.File]::WriteAllText($OutFile, $html, [System.Text.UTF8Encoding]::new($false))

$appKb   = [math]::Round((Get-Item -LiteralPath $OutFile).Length / 1KB)
$pagesMb = [math]::Round(((Get-ChildItem -LiteralPath $pagesDir | Measure-Object Length -Sum).Sum) / 1MB, 2)
Write-Host "Built $OutFile ($appKb KB) and $pageCount pictures in pages/ ($pagesMb MB)"

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
