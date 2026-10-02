#!/usr/bin/env bash
# RemoteRDP installer: sets up xrdp on the Linux host for RDP over Tailscale.
# Usage: curl -fsSL https://github.com/kilomene/RemoteRDP/releases/latest/download/install.sh | sudo bash
set -euo pipefail

log()  { echo "== $*" >&2; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ensure_root() {
    [ "$(id -u)" = 0 ] || die "run as root (use sudo)"
}

# ---- main -----------------------------------------------------------------

ensure_root
log "RemoteRDP installer: xrdp over Tailscale"

# 1. Install xrdp
if ! dpkg -l xrdp 2>/dev/null | grep -q "^ii"; then
    log "installing xrdp..."
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xrdp
else
    log "xrdp already installed"
fi

# 2. Configure xrdp to listen on all interfaces (Tailscale provides security)
#    Default port 3389 is fine.
log "configuring xrdp..."
# Ensure xrdp listens on 0.0.0.0:3389 (default, but be explicit)
sed -i 's/^port=.*/port=3389/' /etc/xrdp/xrdp.ini 2>/dev/null || true

# 3. Set up the desktop session for xrdp
#    xrdp needs a window manager. Use a lightweight one if none exists.
SERVICE_USER="${SUDO_USER:-$(logname 2>/dev/null || echo box)}"
log "configuring desktop for user: $SERVICE_USER"

USER_HOME=$(getent passwd "$SERVICE_USER" | cut -d: -f6)
if [ -z "$USER_HOME" ] || [ ! -d "$USER_HOME" ]; then
    die "cannot find home for user $SERVICE_USER"
fi

# 3a. Ensure the user has a password (xrdp authenticates against it).
#     If locked or unset, generate a secure random one and display it.
RDP_PASSWORD=""
pw_status="$(passwd -S "$SERVICE_USER" 2>/dev/null | awk '{print $2}' || echo "?")"
if [ "$pw_status" = "L" ] || [ "$pw_status" = "NP" ] || [ -z "$pw_status" ] || [ "$pw_status" = "?" ]; then
    log "no password set for $SERVICE_USER — generating one for RDP..."
    # 16-char alphanumeric, no ambiguous chars
    RDP_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
    echo "$SERVICE_USER:$RDP_PASSWORD" | chpasswd \
        || die "failed to set password for $SERVICE_USER"
    log "password set for $SERVICE_USER"
else
    log "user $SERVICE_USER already has a password"
fi

# Create .xsession to start a desktop environment via xrdp
# Try common desktops in order of preference
XSESSION=""
for wm in "xfce4-session" "mate-session" "gnome-session" "startlxde" "openbox-session"; do
    if have "$wm"; then
        XSESSION="$wm"
        break
    fi
done

if [ -n "$XSESSION" ]; then
    log "using desktop: $XSESSION"
    echo "$XSESSION" > "$USER_HOME/.xsession"
    chown "$SERVICE_USER:$SERVICE_USER" "$USER_HOME/.xsession"
    chmod 644 "$USER_HOME/.xsession"
else
    warn "no desktop environment found; installing xfce4 (lightweight)..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xfce4 xfce4-terminal
    echo "xfce4-session" > "$USER_HOME/.xsession"
    chown "$SERVICE_USER:$SERVICE_USER" "$USER_HOME/.xsession"
    chmod 644 "$USER_HOME/.xsession"
fi

# 4. Add xrdp user to ssl-cert group (needed for the private key)
adduser xrdp ssl-cert 2>/dev/null || true

# 5. Restart xrdp
log "starting xrdp..."
systemctl restart xrdp 2>/dev/null || service xrdp restart 2>/dev/null || {
    # No systemd: start manually
    pkill -f "xrdp" 2>/dev/null || true
    sleep 1
    /usr/sbin/xrdp &
    /usr/sbin/xrdp-sesman &
    log "xrdp started manually (no systemd)"
}

sleep 2
if pgrep -f "xrdp" >/dev/null 2>&1; then
    log "xrdp running"
else
    die "xrdp failed to start"
fi

# 6. Tailscale IP
TS_IP=""
if have tailscale; then
    TS_IP=$(tailscale ip -4 2>/dev/null | head -1 || true)
fi

# ---- summary ----------------------------------------------------------------
if [ -n "$RDP_PASSWORD" ]; then
    cat >&2 <<EOF

================ RemoteRDP ready ================
RDP port:     3389
Tailscale IP: ${TS_IP:-unknown}
Username:     $SERVICE_USER
Password:     $RDP_PASSWORD   <-- SAVE THIS (change with: sudo passwd $SERVICE_USER)
================================================

Connect from any RDP client:
  - Microsoft Remote Desktop (Android/iOS/Windows/Mac)
  - Windows: mstsc
  - Address: ${TS_IP:-<tailscale-ip>}:3389

EOF
else
    cat >&2 <<EOF

================ RemoteRDP ready ================
RDP port:     3389
Tailscale IP: ${TS_IP:-unknown}
Username:     $SERVICE_USER (your existing Linux password)
================================================

Connect from any RDP client:
  - Microsoft Remote Desktop (Android/iOS/Windows/Mac)
  - Windows: mstsc
  - Address: ${TS_IP:-<tailscale-ip>}:3389

EOF
fi
