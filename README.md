# Local Photo Viewer

A local photo viewer for `D:\Album\KK_SG\`.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Windows Imaging Component (WIC) codecs for the formats you want to decode
- An HEIC/HEIF codec installed on Windows if you want HEIC/HEIF thumbnails and previews

## Run

Open PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\server.ps1
```

Then open <http://127.0.0.1:8765/>.

To use another folder or port:

```powershell
.\server.ps1 -PhotoDirectory 'D:\Photos' -Port 8765
```

Stop the server with Ctrl+C.

## Performance changes

- Thumbnails are generated once and stored in `.photo-cache\thumbs`.
- HEIC, HEIF and TIFF previews are converted once and stored in `.photo-cache\previews`.
- Extracted EXIF metadata is cached in `.photo-cache\metadata`.
- Cache names include file size and last-write timestamp, so changed source files get new cache entries.
- The browser caches photo details during the current session, aborts stale detail requests, and preloads adjacent previews.

The first visit to a photo may still take time because its thumbnail or metadata has to be generated. Later visits reuse the cache.

## GPS and maps

When a photo contains readable EXIF GPS latitude and longitude, the information panel displays the coordinates and an interactive map directly inside the viewer. Photos without embedded GPS data show a short notice instead.

The map uses Leaflet with OpenStreetMap map tiles. It does not require an API key or paid account. OpenStreetMap attribution is displayed below the map. The public OpenStreetMap tile service has a usage policy and is intended for reasonable interactive use, not bulk tile downloading or high-volume production traffic. No reverse-geocoding service is used, so the viewer does not guess a street address or place name.

## Privacy and file handling

- The server binds to `127.0.0.1` only.
- Original photos are read but never modified.
- Generated cache files are stored beside the script in `.photo-cache`.
- When a GPS map is displayed, the browser requests map tiles from the OpenStreetMap tile service. The photo itself is not uploaded by this viewer.

## Notes

- HEIC/HEIF support depends on the codecs installed on Windows.
- WIC metadata support varies by image format and codec. Some formats may not expose all EXIF fields.
- The server handles requests sequentially. Disk caching removes the repeated conversion cost, but this version does not yet use a multi-threaded request worker pool.
- The in-page map requires an internet connection to load Leaflet and OpenStreetMap tiles.
- If you replace or rename photos, restart the server so the in-memory photo index is refreshed.
