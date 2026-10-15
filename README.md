# LanXfer

**Zero-install** file transfer between two Windows PCs over an Ethernet cable (or the same local network).
Like [winutil](https://github.com/ChrisTitusTech/winutil), it starts with a single line in the terminal and runs entirely in memory — nothing is installed on disk.

## Usage

1. Connect the two PCs with an Ethernet cable. Any modern network card works with a regular straight cable, and no IP setup is needed — Windows assigns `169.254.x.x` addresses automatically.
2. On **both PCs**, open PowerShell (preferably *as Administrator*) and run:

```powershell
irm https://raw.githubusercontent.com/OgeaN/lanxfer/main/lanxfer.ps1 | iex
```

3. The UI opens in your browser. The other PC is discovered and connected automatically within a few seconds.
4. Drag and drop files or folders → they land in the other PC's `Downloads\LanXfer` folder.

### No internet on the other PC?

While LanXfer is running on one PC, run this on the other one (the IP is printed in the first PC's console):

```powershell
irm http://169.254.x.x:8765/s | iex
```

The script is then downloaded straight over the cable from the first PC.

## Settings

Optional environment variables, set before running:

| Variable | Default | Description |
|---|---|---|
| `LANXFER_PORT` | `8765` | HTTP port |
| `LANXFER_UDP` | `8766` | Auto-discovery (UDP broadcast) port |
| `LANXFER_DIR` | `%USERPROFILE%\Downloads\LanXfer` | Folder for received files |
| `LANXFER_NOBROWSER` | — | Set to `1` to not open the browser |

```powershell
$env:LANXFER_DIR = 'D:\Incoming'; irm https://raw.githubusercontent.com/OgeaN/lanxfer/main/lanxfer.ps1 | iex
```

## How it works

- `lanxfer.ps1` is plain PowerShell 5.1, which ships with Windows 10/11 — no dependencies.
- The script runs a small HTTP server (`TcpListener`). The UI (HTML/CSS/JS) is embedded in the script and rendered by your browser.
- Each connection is handled in its own runspace, and files stream to disk in 1 MB chunks, so large files don't fill up RAM.
- Peers find each other with UDP broadcast messages.
- When run as Administrator, it adds a temporary firewall rule and removes it on exit (`Ctrl+C`). Otherwise, allow access for **Public** networks when Windows asks — Windows classifies a direct cable link as an "Unidentified / Public" network.

## Security note

Anyone on the same network can send files to your inbox and download the files in it. LanXfer is meant for direct cable links — don't leave it running on shared networks (cafés, school, etc.).

## Running locally (from a clone)

Double-click `start.cmd`.
