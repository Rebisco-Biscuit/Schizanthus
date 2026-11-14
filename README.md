# <img width="26" height="26" alt="image" src="https://github.com/user-attachments/assets/5b94503c-0ade-4b0b-83e4-ddb7db673f39" /> Schizanthus

A small, local photo viewer for `D:\Album\KK_SG`.

## Run

On Windows, start PowerShell in this folder and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\server.ps1
```

Then open [http://127.0.0.1:8765](http://127.0.0.1:8765). To use another folder or port, pass `-PhotoDirectory` or `-Port` to the script. Stop the server with Ctrl+C.

The viewer runs on loopback only, reads photos without modifying them, and keeps photo data on this computer. It shows HEIC, HEIF, JPEG, PNG, WebP, and TIFF images, with available camera metadata, dimensions, file size, and dates.
