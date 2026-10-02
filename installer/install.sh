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
    # Repair broken Tailscale keyring if missing (breaks apt-get update).
    # Correct URL pattern: https://pkgs.tailscale.com/stable/debian/{codename}.noarmor.gpg
    if [ ! -s /usr/share/keyrings/tailscale-archive-keyring.gpg ]; then
        log "repairing missing Tailscale keyring..."
        . /etc/os-release 2>/dev/null || true
        CODENAME="${VERSION_CODENAME:-trixie}"
        mkdir -p /usr/share/keyrings
        if curl -fsSL "https://pkgs.tailscale.com/stable/debian/${CODENAME}.noarmor.gpg" \
                -o /usr/share/keyrings/tailscale-archive-keyring.gpg 2>/dev/null; then
            log "Tailscale keyring repaired"
            chmod 644 /usr/share/keyrings/tailscale-archive-keyring.gpg
        else
            warn "could not download Tailscale keyring; apt update may warn"
        fi
    fi
    apt-get update -qq 2>&1 | tail -5 >&2 || true
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xrdp \
        || die "failed to install xrdp (check apt sources)"
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
    # 16-char alphanumeric, no ambiguous chars.
    # NOTE: tr|head triggers SIGPIPE (exit 141); with set -e+pipefail that
    # would kill the installer silently. Disable pipefail for this line.
    set +o pipefail
    RDP_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"
    set -o pipefail
    [ -n "$RDP_PASSWORD" ] || die "failed to generate password"
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

# 6. Auto-restart keepalive (no systemd on this VM, so use cron).
#    Every minute: if xrdp or xrdp-sesman died, restart them.
log "setting up xrdp auto-restart keepalive..."
cat > /usr/local/bin/xrdp-keepalive <<'KEEPALIVE_EOF'
#!/usr/bin/env bash
# RemoteRDP keepalive: restart xrdp if it crashed. Runs from cron every minute.
LOG="/var/log/remote/xrdp-keepalive.log"
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
restarted=0
if ! pgrep -f "/usr/sbin/xrdp$" >/dev/null 2>&1; then
    echo "$(date -Is) xrdp down — restarting" >> "$LOG"
    /usr/sbin/xrdp >> "$LOG" 2>&1 &
    restarted=1
fi
if ! pgrep -f "xrdp-sesman" >/dev/null 2>&1; then
    echo "$(date -Is) xrdp-sesman down — restarting" >> "$LOG"
    /usr/sbin/xrdp-sesman >> "$LOG" 2>&1 &
    restarted=1
fi
if [ "$restarted" = 1 ]; then
    sleep 2
    if pgrep -f "/usr/sbin/xrdp$" >/dev/null 2>&1; then
        echo "$(date -Is) xrdp restored" >> "$LOG"
    else
        echo "$(date -Is) xrdp FAILED to restart" >> "$LOG"
    fi
fi
KEEPALIVE_EOF
chmod +x /usr/local/bin/xrdp-keepalive
# Install cron if missing (minimal containers often lack it)
if ! have crontab; then
    log "installing cron..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cron \
        || warn "could not install cron; keepalive disabled"
fi
if have crontab; then
    # Start cron daemon (no systemd on this VM)
    if ! pgrep -f "/usr/sbin/cron" >/dev/null 2>&1; then
        log "starting cron daemon..."
        /usr/sbin/cron 2>/dev/null || service cron start 2>/dev/null || true
        sleep 1
    fi
    # Install cron job (idempotent: remove old, add new)
    (crontab -l 2>/dev/null | grep -v "xrdp-keepalive"; echo "* * * * * /usr/local/bin/xrdp-keepalive") | crontab -
    log "keepalive installed (cron, every minute)"
else
    warn "crontab not available; xrdp auto-restart disabled"
fi

# 7. Tailscale IP
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
