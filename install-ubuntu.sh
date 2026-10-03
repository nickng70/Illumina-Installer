#!/usr/bin/env bash
# ============================================================================
#  Illumina AVA PC Installer - Ubuntu Desktop 24.04/26.04 LTS
#  Hosted PUBLICLY in nickng70/Illumina-Installer (contains NO secrets).
#  Downloads the self-contained app from the PRIVATE nickng70/Illumina-Releases
#  repo using a read-only token entered at runtime.
#  Run with:  sudo bash install-ubuntu.sh
# ============================================================================
set -euo pipefail

# ----------------------------- CONFIG ---------------------------------------
GITHUB_OWNER="nickng70"
GITHUB_REPO="Illumina-Releases"      # PRIVATE repo holding release assets
ASSET_NAME="illumina-linux-x64.tar.gz"
APP_DIR="/var/www/illumina"
HUMAN_USER="avauser"                 # kiosk/operator account (auto-login)
SVC_USER="illumina"                  # app service account (owns Data)
HTTP_PORT="5152"
DOTNET_ROOT="/usr/share/dotnet"
TOKEN_FILE="/etc/illumina/github-token"
# ----------------------------------------------------------------------------

log()  { echo -e "\n\033[1;32m==>\033[0m $*"; }
die()  { echo -e "\n\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

echo "=================================================="
echo "   Illumina AVA PC Installer (Ubuntu)             "
echo "=================================================="

[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"

log "[1/10] Prerequisites..."
apt-get update -y >/dev/null
apt-get install -y curl jq tar >/dev/null

# ---------------- GitHub token (stored root-only for future updates) --------
mkdir -p /etc/illumina && chmod 700 /etc/illumina
if [[ -z "${GITHUB_TOKEN:-}" ]]; then
  if [[ -s "$TOKEN_FILE" ]]; then
    GITHUB_TOKEN="$(cat "$TOKEN_FILE")"
    log "Reusing stored GitHub token from $TOKEN_FILE"
  else
    read -rsp "Enter GitHub read-only token for $GITHUB_REPO: " GITHUB_TOKEN; echo
    [[ -n "$GITHUB_TOKEN" ]] || die "No token provided."
    printf '%s' "$GITHUB_TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
  fi
fi

# ---------------- Locate latest release asset -------------------------------
log "[2/10] Locating latest release in $GITHUB_OWNER/$GITHUB_REPO..."
API_JSON=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
             -H "Accept: application/vnd.github+json" \
             "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO/releases/latest") \
  || die "GitHub API call failed - check the token has Contents:Read on $GITHUB_REPO."
ASSET_URL=$(echo "$API_JSON" | jq -r --arg n "$ASSET_NAME" '.assets[] | select(.name==$n) | .url' | head -n1)
RELEASE_TAG=$(echo "$API_JSON" | jq -r '.tag_name')
[[ -n "$ASSET_URL" && "$ASSET_URL" != "null" ]] || die "Asset '$ASSET_NAME' not found in latest release ($RELEASE_TAG)."

log "Downloading $ASSET_NAME ($RELEASE_TAG)..."
curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
     -H "Accept: application/octet-stream" -o "/tmp/$ASSET_NAME" "$ASSET_URL"

# ---------------- Human kiosk account: avauser ------------------------------
log "[3/10] Configuring kiosk account '$HUMAN_USER'..."
if ! id -u "$HUMAN_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "AVA Kiosk" "$HUMAN_USER"
fi
usermod -aG sudo "$HUMAN_USER"
read -rsp "Set/refresh the SECRET admin password for $HUMAN_USER: " AVA_PASS; echo
[[ -n "$AVA_PASS" ]] || die "Password cannot be empty (sudo su depends on it)."
echo "$HUMAN_USER:$AVA_PASS" | chpasswd

# GDM automatic login (boots straight to desktop, no password prompt)
CONF=/etc/gdm3/custom.conf
mkdir -p /etc/gdm3; touch "$CONF"
set_daemon_key() {
  local key="$1" val="$2"
  if grep -qE "^[#[:space:]]*${key}=" "$CONF"; then
    sed -i -E "s|^[#[:space:]]*${key}=.*|${key}=${val}|" "$CONF"
  elif grep -qE "^\[daemon\]" "$CONF"; then
    sed -i -E "0,/^\[daemon\]/s//\[daemon\]\n${key}=${val}/" "$CONF"
  else
    printf '[daemon]\n%s=%s\n' "$key" "$val" >> "$CONF"
  fi
}
set_daemon_key AutomaticLoginEnable true
set_daemon_key AutomaticLogin "$HUMAN_USER"

# ---------------- App service account ---------------------------------------
log "[4/10] Creating service account '$SVC_USER'..."
id -u "$SVC_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER"

# ---------------- Install app files (preserve Data) -------------------------
log "[5/10] Installing app to $APP_DIR..."
mkdir -p "$APP_DIR"
DATA_BACKUP=""
if [[ -d "$APP_DIR/Data" ]]; then
  DATA_BACKUP="/tmp/.illumina-data.$$"
  mv "$APP_DIR/Data" "$DATA_BACKUP"
fi
tar -xzf "/tmp/$ASSET_NAME" -C "$APP_DIR"
rm -f "/tmp/$ASSET_NAME"
if [[ -n "$DATA_BACKUP" ]]; then
  rm -rf "$APP_DIR/Data"; mv "$DATA_BACKUP" "$APP_DIR/Data"
fi
mkdir -p "$APP_DIR/Data"

# Ownership lockdown:
#   app binaries/files -> root (readable/executable by all, writable by none)
#   Data folder        -> illumina ONLY (avauser gets Permission denied)
chown -R root:root "$APP_DIR"
chmod -R a+rX "$APP_DIR"
[[ -f "$APP_DIR/Illumina" ]] && chmod 755 "$APP_DIR/Illumina"
chown -R "$SVC_USER:$SVC_USER" "$APP_DIR/Data"
chmod 700 "$APP_DIR/Data"
find "$APP_DIR/Data" -type f -exec chmod 600 {} +
# Writable home spots the service (and dev-certs) need:
install -d -o "$SVC_USER" -g "$SVC_USER" -m 700 "$APP_DIR/.aspnet"

echo "$RELEASE_TAG" > /etc/illumina/current-version

# ---------------- .NET tooling + HTTPS dev certificate ----------------------
log "[6/10] Ensuring HTTPS developer certificate for the app..."
if [[ ! -x "$DOTNET_ROOT/dotnet" ]]; then
  curl -sSL https://dot.net/v1/dotnet-install.sh -o /tmp/dotnet-install.sh
  bash /tmp/dotnet-install.sh --channel 10.0 --install-dir "$DOTNET_ROOT" >/dev/null
  ln -sf "$DOTNET_ROOT/dotnet" /usr/local/bin/dotnet
fi
sudo -u "$SVC_USER" HOME="$APP_DIR" "$DOTNET_ROOT/dotnet" dev-certs https >/dev/null 2>&1 \
  || log "WARNING: dev-certs generation reported an issue - verify HTTPS endpoint at first run."

# ---------------- systemd service -------------------------------------------
log "[7/10] Creating systemd service..."
cat > /etc/systemd/system/illumina.service <<EOF
[Unit]
Description=Illumina Web App on Kestrel (.NET 10, self-contained)
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/Illumina
Environment=ASPNETCORE_ENVIRONMENT=Production
Environment=ASPNETCORE_URLS=http://0.0.0.0:$HTTP_PORT
Environment=HOME=$APP_DIR
User=$SVC_USER
Restart=always
RestartSec=10
KillSignal=SIGINT
SyslogIdentifier=illumina

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable illumina >/dev/null
systemctl restart illumina

# ---------------- Passwordless restart shortcut -----------------------------
log "[8/10] Creating restart shortcut (passwordless, narrowly scoped)..."
SYSTEMCTL_BIN="$(command -v systemctl)"
cat > /etc/sudoers.d/illumina-restart <<EOF
$HUMAN_USER ALL=(root) NOPASSWD: $SYSTEMCTL_BIN restart illumina
EOF
chmod 440 /etc/sudoers.d/illumina-restart
visudo -c -f /etc/sudoers.d/illumina-restart >/dev/null || die "sudoers file invalid!"

cat > /usr/local/bin/restart-illumina.sh <<'EOF'
#!/bin/bash
systemctl restart illumina
sleep 2
zenity --info --title="Illumina" --text="Illumina has been restarted!\nPlease wait a few seconds for the page to load." --width=320 &
sleep 3
firefox http://localhost:5152 &
EOF
chmod 755 /usr/local/bin/restart-illumina.sh

# ---------------- Desktop shortcuts + autostart for avauser -----------------
log "[9/10] Creating desktop shortcuts and autostart..."
USER_HOME=$(getent passwd "$HUMAN_USER" | cut -d: -f6)
DESKTOP=$(runuser -u "$HUMAN_USER" -- xdg-user-dir DESKTOP 2>/dev/null || true)
[[ -n "$DESKTOP" ]] || DESKTOP="$USER_HOME/Desktop"
mkdir -p "$DESKTOP" "$USER_HOME/.config/autostart"

cat > "$DESKTOP/Restart-Illumina.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Restart Illumina
Comment=Emergency restart for the Illumina portal
Exec=/usr/local/bin/restart-illumina.sh
Icon=system-restart
Terminal=false
EOF

cat > "$DESKTOP/Illumina-Portal.desktop" <<EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Illumina Portal
Comment=Open the Illumina operator portal
Exec=firefox http://localhost:$HTTP_PORT
Icon=firefox
Terminal=false
EOF

cat > "$USER_HOME/.config/autostart/illumina-portal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Illumina Portal
Exec=firefox http://localhost:$HTTP_PORT
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=8
EOF

chmod 755 "$DESKTOP"/*.desktop
chown -R "$HUMAN_USER:$HUMAN_USER" "$DESKTOP" "$USER_HOME/.config/autostart"
for f in "$DESKTOP"/*.desktop; do
  runuser -u "$HUMAN_USER" -- gio set "$f" metadata::trusted true 2>/dev/null || true
done

# No screen lock, no sleep - ever
runuser -u "$HUMAN_USER" -- dbus-launch gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
runuser -u "$HUMAN_USER" -- dbus-launch gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
runuser -u "$HUMAN_USER" -- dbus-launch gsettings set org.gnome.desktop.screensaver ubuntu-lock-on-suspend false 2>/dev/null || true
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1 || true

# ---------------- Firewall ---------------------------------------------------
log "[10/10] Configuring firewall..."
ufw allow OpenSSH >/dev/null
ufw allow "$HTTP_PORT/tcp" >/dev/null
ufw --force enable >/dev/null

echo
echo "=================================================="
echo "   ✅ Installation complete! ($RELEASE_TAG)"
echo "   Portal:   http://localhost:$HTTP_PORT"
echo "   Kiosk:    auto-logs in as $HUMAN_USER"
echo "   Admin:    sudo su  (secret password)"
echo "=================================================="
read -r -p "Reboot now to apply auto-login? [Y/n] " ans
case "$ans" in [nN]*) echo "Reboot later with: sudo reboot";; *) reboot;; esac