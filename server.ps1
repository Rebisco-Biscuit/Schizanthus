param(
    [string]$PhotoDirectory = 'D:\Album\KK_SG',
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore

$photoRoot = (Resolve-Path -LiteralPath $PhotoDirectory).Path
$indexPath = Join-Path $PSScriptRoot 'index.html'
$cacheRoot = Join-Path $PSScriptRoot '.photo-cache'
$thumbnailCache = Join-Path $cacheRoot 'thumbs'
$previewCache = Join-Path $cacheRoot 'previews'
$metadataCache = Join-Path $cacheRoot 'metadata'

foreach ($directory in @($cacheRoot, $thumbnailCache, $previewCache, $metadataCache)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$photoExtensions = @('.heic', '.heif', '.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff')
$photos = @(
    Get-ChildItem -LiteralPath $photoRoot -File |
        Where-Object { $photoExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object LastWriteTime -Descending
)

$utf8 = New-Object System.Text.UTF8Encoding($false)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

function Send-Response {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body,
        [string]$CacheControl = 'no-store'
    )

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Body.Length
    $Context.Response.Headers['Cache-Control'] = $CacheControl
    $Context.Response.Headers['X-Content-Type-Options'] = 'nosniff'
    if ($Body.Length -gt 0) {
        $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    }
    $Context.Response.Close()
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        $Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 8 -Compress
    Send-Response $Context $StatusCode 'application/json; charset=utf-8' $utf8.GetBytes($json)
}

function Get-Photo {
    param([string]$Id)

    if ($Id -notmatch '\A\d+\z') { return $null }
    $index = [int]$Id
    if ($index -lt 0 -or $index -ge $photos.Count) { return $null }
    return $photos[$index]
}

function Get-PhotoCacheKey {
    param([System.IO.FileInfo]$Photo)

    # Include both size and UTC write time so changed files get fresh cache entries.
    return '{0}-{1}' -f $Photo.Length, $Photo.LastWriteTimeUtc.Ticks
}

function Get-CachePath {
    param(
        [string]$Directory,
        [int]$Id,
        [System.IO.FileInfo]$Photo,
        [string]$Extension
    )

    $key = Get-PhotoCacheKey $Photo
    return Join-Path $Directory ("{0}-{1}{2}" -f $Id, $key, $Extension)
}

function Convert-Rational {
    param($Value)

    if ($null -eq $Value) { return $null }

    if ($Value -is [UInt64] -or $Value -is [Int64] -or $Value -is [UInt32] -or $Value -is [Int32]) {
        $raw = [UInt64]$Value
        $numerator = [UInt32]($raw -band [UInt64]4294967295)
        $denominator = [UInt32]($raw -shr 32)
        if ($denominator -ne 0) {
            return [double]$numerator / [double]$denominator
        }
    }

    $text = [string]$Value
    if ($text -match '^\s*(-?\d+)\s*/\s*(\d+)\s*$') {
        $denominator = [double]$Matches[2]
        if ($denominator -ne 0) { return [double]$Matches[1] / $denominator }
    }
    return $null
}

function Get-MetadataValue {
    param(
        [System.Windows.Media.Imaging.BitmapMetadata]$Metadata,
        [string[]]$Queries
    )

    if ($null -eq $Metadata) { return $null }

    foreach ($query in $Queries) {
        try {
            if ($Metadata.ContainsQuery($query)) {
                $value = $Metadata.GetQuery($query)
                if ($null -ne $value) {
                    if ($value -is [UInt64] -or $value -is [Int64]) {
                        $raw = [UInt64]$value
                        $numerator = [UInt32]($raw -band [UInt64]4294967295)
                        $denominator = [UInt32]($raw -shr 32)
                        if ($denominator -ne 0) { return "$numerator/$denominator" }
                    }
                    return [string]$value
                }
            }
        }
        catch { }
    }
    return $null
}

function Get-RationalParts {
    param($Value)

    $items = @()
    if ($null -eq $Value) { return $items }

    try {
        foreach ($item in $Value) {
            $number = Convert-Rational $item
            if ($null -ne $number) { $items += [double]$number }
        }
    }
    catch {
        $number = Convert-Rational $Value
        if ($null -ne $number) { $items += [double]$number }
    }
    return $items
}

function Convert-GpsCoordinate {
    param(
        $RawValue,
        [string]$Reference,
        [string]$PositiveReference,
        [string]$NegativeReference
    )

    $parts = @(Get-RationalParts $RawValue)
    if ($parts.Count -lt 3) { return $null }

    $decimal = [double]$parts[0] + ([double]$parts[1] / 60.0) + ([double]$parts[2] / 3600.0)
    if ($Reference -eq $NegativeReference) { $decimal = -$decimal }
    elseif ($Reference -ne $PositiveReference) { return $null }

    return [Math]::Round($decimal, 7)
}

function Get-PhotoMetadata {
    param(
        [System.IO.FileInfo]$Photo,
        [int]$Id
    )

    $cacheFile = Get-CachePath $metadataCache $Id $Photo '.json'
    if (Test-Path -LiteralPath $cacheFile -PathType Leaf) {
        try {
            return (Get-Content -LiteralPath $cacheFile -Raw -Encoding UTF8 | ConvertFrom-Json)
        }
        catch { }
    }

    $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
        [Uri]::new($Photo.FullName),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    )

    try {
        $frame = $decoder.Frames[0]
        $metadata = $frame.Metadata

        $dateTaken = Get-MetadataValue $metadata @(
            '/app1/ifd/exif/{ushort=36867}', '/ifd/exif/{ushort=36867}',
            '/app1/ifd/{ushort=306}', '/ifd/{ushort=306}'
        )
        $camera = Get-MetadataValue $metadata @(
            '/app1/ifd/{ushort=271}', '/ifd/{ushort=271}'
        )
        $model = Get-MetadataValue $metadata @(
            '/app1/ifd/{ushort=272}', '/ifd/{ushort=272}'
        )

        $latRef = Get-MetadataValue $metadata @('/app1/ifd/gps/{ushort=1}', '/ifd/gps/{ushort=1}')
        $lonRef = Get-MetadataValue $metadata @('/app1/ifd/gps/{ushort=3}', '/ifd/gps/{ushort=3}')
        $latRaw = $null
        $lonRaw = $null
        foreach ($query in @('/app1/ifd/gps/{ushort=2}', '/ifd/gps/{ushort=2}')) {
            try {
                if ($metadata -and $metadata.ContainsQuery($query)) {
                    $latRaw = $metadata.GetQuery($query)
                    if ($null -ne $latRaw) { break }
                }
            } catch { }
        }
        foreach ($query in @('/app1/ifd/gps/{ushort=4}', '/ifd/gps/{ushort=4}')) {
            try {
                if ($metadata -and $metadata.ContainsQuery($query)) {
                    $lonRaw = $metadata.GetQuery($query)
                    if ($null -ne $lonRaw) { break }
                }
            } catch { }
        }

        $latitude = Convert-GpsCoordinate $latRaw $latRef 'N' 'S'
        $longitude = Convert-GpsCoordinate $lonRaw $lonRef 'E' 'W'

        $details = [ordered]@{
            width = $frame.PixelWidth
            height = $frame.PixelHeight
            dateTaken = $dateTaken
            camera = $camera
            model = $model
            iso = Get-MetadataValue $metadata @('/app1/ifd/exif/{ushort=34855}', '/ifd/exif/{ushort=34855}')
            aperture = Get-MetadataValue $metadata @('/app1/ifd/exif/{ushort=33437}', '/ifd/exif/{ushort=33437}')
            exposure = Get-MetadataValue $metadata @('/app1/ifd/exif/{ushort=33434}', '/ifd/exif/{ushort=33434}')
            focalLength = Get-MetadataValue $metadata @('/app1/ifd/exif/{ushort=37386}', '/ifd/exif/{ushort=37386}')
            focalLength35mm = Get-MetadataValue $metadata @('/app1/ifd/exif/{ushort=41989}', '/ifd/exif/{ushort=41989}')
            latitude = $latitude
            longitude = $longitude
        }

        $json = ConvertTo-Json -InputObject $details -Depth 6 -Compress
        [System.IO.File]::WriteAllText($cacheFile, $json, $utf8)
        return [pscustomobject]$details
    }
    finally {
        if ($null -ne $decoder) { $decoder = $null }
    }
}

function Convert-ToJpeg {
    param(
        [string]$Path,
        [int]$MaxDimension,
        [int]$Quality
    )

    $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
        [Uri]::new($Path),
        [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
        [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    )
    $frame = $decoder.Frames[0]
    $scale = [Math]::Min(1.0, $MaxDimension / [Math]::Max($frame.PixelWidth, $frame.PixelHeight))

    $bitmap = New-Object System.Windows.Media.Imaging.TransformedBitmap
    $bitmap.BeginInit()
    $bitmap.Source = $frame
    $bitmap.Transform = New-Object System.Windows.Media.ScaleTransform($scale, $scale)
    $bitmap.EndInit()

    $encoder = New-Object System.Windows.Media.Imaging.JpegBitmapEncoder
    $encoder.QualityLevel = $Quality
    $encoder.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bitmap))

    $stream = New-Object System.IO.MemoryStream
    try {
        $encoder.Save($stream)
        return ,$stream.ToArray()
    }
    finally {
        $stream.Dispose()
        $bitmap = $null
        $frame = $null
        $decoder = $null
    }
}

function Get-ThumbnailBytes {
    param(
        [System.IO.FileInfo]$Photo,
        [int]$Id
    )

    $cacheFile = Get-CachePath $thumbnailCache $Id $Photo '.jpg'
    if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
        $bytes = Convert-ToJpeg -Path $Photo.FullName -MaxDimension 480 -Quality 82
        [System.IO.File]::WriteAllBytes($cacheFile, $bytes)
    }
    return [System.IO.File]::ReadAllBytes($cacheFile)
}

function Get-PreviewBytes {
    param(
        [System.IO.FileInfo]$Photo,
        [int]$Id
    )

    $extension = $Photo.Extension.ToLowerInvariant()
    if ($extension -in @('.heic', '.heif', '.tif', '.tiff')) {
        $cacheFile = Get-CachePath $previewCache $Id $Photo '.jpg'
        if (-not (Test-Path -LiteralPath $cacheFile -PathType Leaf)) {
            $bytes = Convert-ToJpeg -Path $Photo.FullName -MaxDimension 4096 -Quality 92
            [System.IO.File]::WriteAllBytes($cacheFile, $bytes)
        }
        return @{
            bytes = [System.IO.File]::ReadAllBytes($cacheFile)
            contentType = 'image/jpeg'
        }
    }

    $contentType = switch ($extension) {
        { $_ -in '.jpg', '.jpeg' } { 'image/jpeg'; break }
        '.png' { 'image/png'; break }
        '.webp' { 'image/webp'; break }
        default { 'application/octet-stream' }
    }

    return @{
        bytes = [System.IO.File]::ReadAllBytes($Photo.FullName)
        contentType = $contentType
    }
}

$listener.Start()
Write-Host "Photo viewer: http://127.0.0.1:$Port/"
Write-Host "Serving $($photos.Count) photos from $photoRoot"
Write-Host "Cache: $cacheRoot"
Write-Host 'Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $path = $context.Request.Url.AbsolutePath

            if ($context.Request.HttpMethod -ne 'GET') {
                Send-Json $context 405 @{ error = 'Only GET requests are supported.' }
                continue
            }

            if ($path -eq '/') {
                $body = [System.IO.File]::ReadAllBytes($indexPath)
                Send-Response $context 200 'text/html; charset=utf-8' $body 'no-cache'
                continue
            }

            if ($path -eq '/api/photos') {
                $items = @(
                    for ($index = 0; $index -lt $photos.Count; $index++) {
                        @{
                            id = $index
                            name = $photos[$index].Name
                            size = $photos[$index].Length
                            modified = $photos[$index].LastWriteTime.ToString('o')
                            version = '{0}-{1}' -f $photos[$index].Length, $photos[$index].LastWriteTimeUtc.Ticks
                        }
                    }
                )
                Send-Json $context 200 $items
                continue
            }

            if ($path -match '\A/api/photos/(\d+)\z') {
                $id = [int]$Matches[1]
                $photo = Get-Photo $Matches[1]
                if ($null -eq $photo) {
                    Send-Json $context 404 @{ error = 'Photo not found.' }
                    continue
                }

                $details = Get-PhotoMetadata -Photo $photo -Id $id
                Send-Json $context 200 $details
                continue
            }

            if ($path -match '\A/(thumb|photo)/(\d+)\z') {
                $kind = $Matches[1]
                $id = [int]$Matches[2]
                $photo = Get-Photo $Matches[2]
                if ($null -eq $photo) {
                    Send-Json $context 404 @{ error = 'Photo not found.' }
                    continue
                }

                if ($kind -eq 'thumb') {
                    $body = Get-ThumbnailBytes -Photo $photo -Id $id
                    Send-Response $context 200 'image/jpeg' $body 'public, max-age=31536000, immutable'
                }
                else {
                    $result = Get-PreviewBytes -Photo $photo -Id $id
                    Send-Response $context 200 $result.contentType $result.bytes 'public, max-age=31536000, immutable'
                }
                continue
            }

            Send-Json $context 404 @{ error = 'Not found.' }
        }
        catch {
            Write-Warning "Request $($context.Request.Url.AbsolutePath) failed: $($_.Exception.Message)"
            try {
                Send-Json $context 500 @{ error = 'Unable to read this photo.' }
            }
            catch {
                try { $context.Response.Close() } catch { }
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
