# RemoteRDP

RDP-based remote desktop over Tailscale.

## Architecture

- **Host (Linux)**: xrdp server, installed via `installer/install.sh`. Serves the Linux desktop over standard RDP (port 3389).
- **Android client**: FreeRDP-based RDP client (in `android/`).
- **Network**: Tailscale (secure P2P, no open ports to the internet).

## Connect from

Any standard RDP client works:
1. This repo's Android app (FreeRDP)
2. Microsoft Remote Desktop (Android/iOS/Windows/Mac)
3. Windows built-in Remote Desktop Connection (mstsc)
4. Any other RDP client

## Quick start

On the Linux VM:
```bash
curl -fsSL https://github.com/kilomene/RemoteRDP/releases/latest/download/install.sh | sudo bash
```

Then connect from any RDP client to `100.x.x.x:3389` (your Tailscale IP) with your Linux username/password.
