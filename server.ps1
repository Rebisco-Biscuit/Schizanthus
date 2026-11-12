param(
    [string]$PhotoDirectory = 'D:\Album\KK_SG',
    [int]$Port = 8765
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationCore

$photoRoot = (Resolve-Path -LiteralPath $PhotoDirectory).Path
$photoExtensions = @('.heic', '.heif', '.jpg', '.jpeg', '.png', '.webp', '.tif', '.tiff')
$photos = @(
    Get-ChildItem -LiteralPath $photoRoot -File |
        Where-Object { $photoExtensions -contains $_.Extension.ToLowerInvariant() } |
        Sort-Object LastWriteTime -Descending
)
$indexPath = Join-Path $PSScriptRoot 'index.html'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$Port/")

function Send-Response {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$ContentType,
        [byte[]]$Body
    )

    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $Body.Length
    $Context.Response.OutputStream.Write($Body, 0, $Body.Length)
    $Context.Response.Close()
}

function Send-Json {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        $Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 5 -Compress
    Send-Response $Context $StatusCode 'application/json; charset=utf-8' $utf8.GetBytes($json)
}

function Get-Photo {
    param([string]$Id)

    if ($Id -notmatch '\A\d+\z') {
        return $null
    }

    $index = [int]$Id
    if ($index -lt 0 -or $index -ge $photos.Count) {
        return $null
    }

    return $photos[$index]
}

function Get-MetadataValue {
    param(
        [System.Windows.Media.Imaging.BitmapMetadata]$Metadata,
        [string[]]$Queries
    )

    if ($null -eq $Metadata) {
        return $null
    }

    foreach ($query in $Queries) {
        if ($Metadata.ContainsQuery($query)) {
            $value = $Metadata.GetQuery($query)
            if ($value -is [UInt64] -or $value -is [Int64]) {
                $raw = [UInt64]$value
                $numerator = [UInt32]($raw -band [UInt64]4294967295)
                $denominator = [UInt32]($raw -shr 32)
                if ($denominator -ne 0) {
                    return "$numerator/$denominator"
                }
            }
            return [string]$value
        }
    }

    return $null
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
    $transform = New-Object System.Windows.Media.ScaleTransform
    $transform.ScaleX = $scale
    $transform.ScaleY = $scale
    $bitmap = New-Object System.Windows.Media.Imaging.TransformedBitmap
    $bitmap.BeginInit()
    $bitmap.Source = $frame
    $bitmap.Transform = $transform
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
    }
}

function New-Thumbnail {
    param([string]$Path)

    return Convert-ToJpeg -Path $Path -MaxDimension 480 -Quality 82
}

$listener.Start()
Write-Host "Photo viewer: http://127.0.0.1:$Port/"
Write-Host "Serving $($photos.Count) photos from $photoRoot"
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
                Send-Response $context 200 'text/html; charset=utf-8' $body
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
                        }
                    }
                )
                Send-Json $context 200 $items
                continue
            }

            if ($path -match '\A/api/photos/(\d+)\z') {
                $photo = Get-Photo $Matches[1]
                if ($null -eq $photo) {
                    Send-Json $context 404 @{ error = 'Photo not found.' }
                    continue
                }

                $decoder = [System.Windows.Media.Imaging.BitmapDecoder]::Create(
                    [Uri]::new($photo.FullName),
                    [System.Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,
                    [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                )
                $frame = $decoder.Frames[0]
                $metadata = $frame.Metadata
                $details = @{
                    width = $frame.PixelWidth
                    height = $frame.PixelHeight
                    dateTaken = Get-MetadataValue $metadata @('/ifd/exif/{ushort=36867}', '/ifd/{ushort=306}')
                    camera = Get-MetadataValue $metadata @('/ifd/{ushort=271}', '/ifd/{ushort=272}')
                    model = Get-MetadataValue $metadata @('/ifd/{ushort=272}')
                    iso = Get-MetadataValue $metadata @('/ifd/exif/{ushort=34855}')
                    aperture = Get-MetadataValue $metadata @('/ifd/exif/{ushort=33437}')
                    exposure = Get-MetadataValue $metadata @('/ifd/exif/{ushort=33434}')
                    focalLength = Get-MetadataValue $metadata @('/ifd/exif/{ushort=37386}')
                    focalLength35mm = Get-MetadataValue $metadata @('/ifd/exif/{ushort=41989}')
                }
                Send-Json $context 200 $details
                continue
            }

            if ($path -match '\A/(thumb|photo)/(\d+)\z') {
                $photo = Get-Photo $Matches[2]
                if ($null -eq $photo) {
                    Send-Json $context 404 @{ error = 'Photo not found.' }
                    continue
                }

                if ($Matches[1] -eq 'thumb') {
                    $body = New-Thumbnail $photo.FullName
                    Send-Response $context 200 'image/jpeg' $body
                }
                elseif ($photo.Extension.ToLowerInvariant() -in '.heic', '.heif', '.tif', '.tiff') {
                    $body = Convert-ToJpeg -Path $photo.FullName -MaxDimension 4096 -Quality 92
                    Send-Response $context 200 'image/jpeg' $body
                }
                else {
                    $contentType = switch ($photo.Extension.ToLowerInvariant()) {
                        { $_ -in '.jpg', '.jpeg' } { 'image/jpeg'; break }
                        '.png' { 'image/png'; break }
                        '.webp' { 'image/webp'; break }
                    }
                    $body = [System.IO.File]::ReadAllBytes($photo.FullName)
                    Send-Response $context 200 $contentType $body
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
                $context.Response.Close()
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
