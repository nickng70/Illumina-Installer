#!/bin/bash
# ==============================================================================
# Illumina AVA PC Installer - Ubuntu 22.04/24.04 (v7.1 FINAL)
# - Friendly sudo check (reassures nothing was changed)
# - Installs dependencies (curl, unzip, jq, openssl) silently
# - Clean [1]/[2] menu for account selection
# - Native Linux permissions (no "hidden folder" tricks needed)
# - Auto sign-in via GDM3; conditional, warm reboot prompt
# - HTTPS via a private 100-year PFX certificate (required for .NET on Linux)
# ==============================================================================

set -e

# ----------------------------- [0/8] SUDO CHECK -----------------------------
if [ "$EUID" -ne 0 ]; then
  echo ""
  echo "  Illumina setup needs administrator (sudo) rights for this one run - it"
  echo "  installs program files to /opt, configures the firewall, and sets up"
  echo "  the kiosk environment."
  echo ""
  echo "  Please close this terminal, open a new one, and run:"
  echo "  sudo ./install-ubuntu.sh"
  echo ""
  echo "  Nothing on this PC has been changed yet."
  exit 1
fi

# Identify the actual human user (not 'root')
if [ -n "$SUDO_USER" ]; then
    INTERACTIVE_USER="$SUDO_USER"
else
    INTERACTIVE_USER=$(logname 2>/dev/null || echo "root")
fi

if [ "$INTERACTIVE_USER" = "root" ]; then
    echo "  Please run this script via 'sudo' while logged in as your normal user,"
    echo "  rather than switching to the root user directly, so we can place the"
    echo "  desktop shortcuts in the correct user profile."
    exit 1
fi

USER_HOME=$(eval echo "~$INTERACTIVE_USER")
INSTALL_DIR="/opt/illumina"
MACHINE_DIR="/var/lib/illumina"
HTTP_PORT="443"
PORTAL_URL="https://localhost"

echo "=================================================="
echo "   Illumina AVA PC Installer - Ubuntu (v7.1)      "
echo "   Guided setup for a safe, self-starting kiosk   "
echo "=================================================="
echo ""
echo "  Welcome! This installer prepares this PC to run Illumina around the"
echo "  clock: it fetches the latest release, configures secure local HTTPS,"
echo "  and tailors the displays to your hardware. Every question explains"
echo "  itself, and pressing ENTER always accepts the safe, recommended default."

# ----------------------------- [1/8] DEPENDENCIES ---------------------------
echo -e "\n==> [1/8] Checking essential tools..."
apt-get update -qq > /dev/null
apt-get install -y -qq curl unzip jq openssl > /dev/null
echo "  All required tools (curl, unzip, jq, openssl) are ready."

# ----------------------------- [2/8] GITHUB TOKEN ---------------------------
echo -e "\n==> [2/8] Release access token..."
mkdir -p "$MACHINE_DIR"
TOKEN_FILE="$MACHINE_DIR/github-token"

if [ -n "$GITHUB_TOKEN" ]; then
    TOKEN="$GITHUB_TOKEN"
    echo "  Using the token from this session's environment."
elif [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE")
    echo "  Reusing the token stored on this machine - nothing to type."
else
    echo "  Illumina's release packages live in a private repository, so we need"
    echo "  a read-only GitHub token once; it is then stored securely on this PC."
    read -p "  Paste your GitHub read-only token: " TOKEN
    if [ -z "$TOKEN" ]; then echo "  A token is required. Exiting."; exit 1; fi
    echo "$TOKEN" > "$TOKEN_FILE"
    chmod 600 "$TOKEN_FILE"
    chown root:root "$TOKEN_FILE"
    echo "  Token stored securely (root only)."
fi

# ----------------------------- [3/8] DOWNLOAD RELEASE -----------------------
echo -e "\n==> [3/8] Downloading the latest Illumina release..."
RELEASE_JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/nickng70/Illumina-Releases/releases/latest")
TAG_NAME=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name=="illumina-linux-x64.zip") | .url')

if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    echo "  Asset 'illumina-linux-x64.zip' not found in release $TAG_NAME."
    exit 1
fi

ZIP_FILE="/tmp/illumina-linux-x64.zip"
curl -s -L -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" -o "$ZIP_FILE" "$ASSET_URL"
echo "  Release $TAG_NAME downloaded."

# ----------------------------- [4/8] PAUSE PREVIOUS SESSION -----------------
echo -e "\n==> [4/8] Pausing any running Illumina session..."
pkill -f "Illumina" || true
# Only kill Chrome processes running under the IlluminaKiosk profile
pkill -f "IlluminaKiosk" || true
sleep 2
rm -rf /tmp/IlluminaKiosk || true
echo "  Previous session paused - your open browser tabs and files are untouched."

# ----------------------------- [5/8] KIOSK ACCOUNT & SIGN-IN ----------------
echo -e "\n==> [5/8] Choosing the kiosk account and sign-in behavior..."
echo ""
echo "  How will this PC be used?"
echo "  [1] Dedicated Church AVA PC (Recommended)"
echo "      Creates a clean, standard-user account named 'avauser' just for Illumina."
echo "      This keeps the desktop uncluttered and prevents accidental system changes."
echo "  [2] Personal Laptop or IT Testing"
echo "      Uses your current Linux account ($INTERACTIVE_USER)."
echo "      Ideal for development, testing, or initial setup by an administrator."

read -p "  Select setup type (press ENTER for 1): " MODE
USE_AVA_USER=false
if [ "$MODE" != "2" ]; then USE_AVA_USER=true; fi

if [ "$USE_AVA_USER" = true ]; then
    HUMAN_USER="avauser"
    if ! id "$HUMAN_USER" &>/dev/null; then
        echo "  Set the SECRET password for avauser (used for maintenance logins):"
        passwd_prompt="  "
        while true; do
            read -s -p "  Password: " p1; echo
            read -s -p "  Confirm : " p2; echo
            if [ "$p1" = "$p2" ] && [ -n "$p1" ]; then
                PLAIN_PASS="$p1"
                break
            fi
            echo "  Passwords did not match or were empty. Try again."
        done
        useradd -m -s /bin/bash "$HUMAN_USER"
        echo "$HUMAN_USER:$PLAIN_PASS" | chpasswd
        echo "  Created kiosk account 'avauser'."
    else
        echo "  Reusing existing 'avauser' account."
    fi
    AUTO_LOGIN_ON=true
else
    HUMAN_USER="$INTERACTIVE_USER"
    echo ""
    echo "  Auto sign-in lets the PC boot straight into Illumina after a power cut."
    echo "  On a personal laptop, you may prefer the normal logon screen instead."
    read -p "  Enable auto sign-in for $HUMAN_USER? [y/N] (ENTER = No): " WANT_AUTO
    if [[ "$WANT_AUTO" =~ ^[yY]$ ]]; then
        echo "  Enter the sudo/sudo password for $HUMAN_USER to store for auto sign-in:"
        read -s -p "  Password: " PLAIN_PASS; echo
        AUTO_LOGIN_ON=true
    else
        AUTO_LOGIN_ON=false
    fi
fi

# Configure GDM3 Auto-login
GDM_CONF="/etc/gdm3/custom.conf"
if [ "$AUTO_LOGIN_ON" = true ] && [ -f "$GDM_CONF" ]; then
    sed -i '/^\[daemon\]/,/^\[/ s/^#\?AutomaticLoginEnable\s*=\s*.*/AutomaticLoginEnable=true/' "$GDM_CONF"
    sed -i '/^\[daemon\]/,/^\[/ s/^#\?AutomaticLogin\s*=\s*.*/AutomaticLogin='"$HUMAN_USER"'/' "$GDM_CONF"
    
    if ! grep -q "AutomaticLoginEnable" "$GDM_CONF"; then
        sed -i '/\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin='"$HUMAN_USER" "$GDM_CONF"
    fi
    echo "  Auto sign-in configured for $HUMAN_USER - it activates at the next restart."
else
    echo "  Auto sign-in left OFF - the PC keeps its normal logon screen."
fi

# ----------------------------- [6/8] APP FILES & PERMISSIONS ----------------
echo -e "\n==> [6/8] Installing Illumina and preparing its content folders..."
if [ -d "$INSTALL_DIR/Data" ]; then
    mv "$INSTALL_DIR/Data" /tmp/illumina-data-backup
fi
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
unzip -q "$ZIP_FILE" -d "$INSTALL_DIR"
rm "$ZIP_FILE"

if [ -d "/tmp/illumina-data-backup" ]; then
    rm -rf "$INSTALL_DIR/Data"
    mv /tmp/illumina-data-backup "$INSTALL_DIR/Data"
fi
mkdir -p "$INSTALL_DIR/Data"

# Writable folders
for W_DIR in SlideContent MediaContent AppData Recordings; do
    mkdir -p "$INSTALL_DIR/$W_DIR"
    chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/$W_DIR"
    chmod 755 "$INSTALL_DIR/$W_DIR"
done

# Content folders: On Linux, we don't need "hidden attribute" tricks.
# Standard POSIX permissions (chmod 500) mean ONLY the kiosk user can read
# or even list the contents of this folder. Other standard users are 
# completely locked out by the kernel.
chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/Data"
chmod 500 "$INSTALL_DIR/Data"
echo "  Content folders prepared with native Linux permissions (locked to $HUMAN_USER)."
echo "$TAG_NAME" > "$MACHINE_DIR/current-version"

# ----------------------------- [7/8] SURVEY, CERTS, OVERRIDES ---------------
echo -e "\n==> [7/8] Site survey, HTTPS certificate, and machine settings..."
echo ""
echo "  Every church is wired differently, so we ask three quick questions."
echo "  ENTER accepts the safe default (No) for each."
read -p "  [1/3] Is a RIGHT Wall display connected? [y/N] (ENTER = No): " R_WALL
read -p "  [2/3] Is a STREAMING/BROADCAST output used? [y/N] (ENTER = No): " STREAM
read -p "  [3/3] Should Prayer/Announcement slides sync from Google Drive? [y/N] (ENTER = No): " SYNC

RIGHT_ON=false; [[ "$R_WALL" =~ ^[yY]$ ]] && RIGHT_ON=true
STREAM_ON=false; [[ "$STREAM" =~ ^[yY]$ ]] && STREAM_ON=true
SYNC_ON=false; [[ "$SYNC" =~ ^[yY]$ ]] && SYNC_ON=true

# Drive Sync
KEY_JSON="$MACHINE_DIR/key.json"
PRAYER_ID=""; ANN_ID=""
if [ "$SYNC_ON" = true ]; then
    if [ ! -f "$KEY_JSON" ]; then
        echo "  Fetching Drive key from repository..."
        curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/nickng70/Illumina-Releases/contents/secrets/drive-key.json" -o "$KEY_JSON"
    fi
    if [ -f "$KEY_JSON" ]; then
        chown "$HUMAN_USER:$HUMAN_USER" "$KEY_JSON"
        chmod 400 "$KEY_JSON"
        read -p "  Prayer slides folder ID (Google Drive): " PRAYER_ID
        read -p "  Announcements slides folder ID (Google Drive): " ANN_ID
        if [ -z "$PRAYER_ID" ] || [ -z "$ANN_ID" ]; then SYNC_ON=false; fi
    else
        SYNC_ON=false
    fi
fi

# HTTPS Certificate (Linux requires a PFX file path, unlike the Windows Store)
echo "  Generating private 100-year HTTPS certificate..."
PFX_PATH="$MACHINE_DIR/illumina.pfx"
PFX_PASS="IlluminaKioskCert"
openssl req -x509 -newkey rsa:4096 -keyout /tmp/illumina.key -out /tmp/illumina.crt -days 36500 -nodes -subj "/CN=localhost" > /dev/null 2>&1
openssl pkcs12 -export -out "$PFX_PATH" -inkey /tmp/illumina.key -in /tmp/illumina.crt -passout pass:"$PFX_PASS" > /dev/null 2>&1
rm /tmp/illumina.key /tmp/illumina.crt
chown "$HUMAN_USER:$HUMAN_USER" "$PFX_PATH"
chmod 400 "$PFX_PATH"

# Build Overrides JSON using jq
OVERRIDES="$INSTALL_DIR/AppData/AppSettingsOverrides.json"
mkdir -p "$INSTALL_DIR/AppData"

jq -n \
  --arg pfx "$PFX_PATH" \
  --arg pass "$PFX_PASS" \
  --arg right "$RIGHT_ON" \
  --arg stream "$STREAM_ON" \
  --arg sync "$SYNC_ON" \
  --arg key "$KEY_JSON" \
  --arg prayer "$PRAYER_ID" \
  --arg ann "$ANN_ID" \
  '{
    "Urls": "https://0.0.0.0:443;http://0.0.0.0:80",
    "Kestrel": {
      "Certificates": {
        "Default": {
          "Path": $pfx,
          "Password": $pass
        }
      }
    },
    "Kiosk": {
      "BaseUrl": "https://localhost",
      "Enabled": true,
      "RightWallEnabled": ($right == "true"),
      "CgEnabled": ($stream == "true"),
      "ProgramEnabled": ($stream == "true")
    },
    "SlideLibrary": {
      "GoogleDrive": {
        "ServiceAccountKeyPath": (if $sync == "true" then $key else "" end),
        "PrayerFolderId": (if $sync == "true" then $prayer else "" end),
        "AnnouncementsFolderId": (if $sync == "true" then $ann else "" end)
      }
    }
  }' > "$OVERRIDES"
chown "$HUMAN_USER:$HUMAN_USER" "$OVERRIDES"

# ----------------------------- [8/8] HELPERS, SHORTCUTS, FIREWALL -----------
echo -e "\n==> [8/8] Writing shortcuts, configuring firewall, and keeping the PC awake..."

# Helper Scripts
cat <<EOF > "$INSTALL_DIR/open-illumina.sh"
#!/bin/bash
APP="$INSTALL_DIR/Illumina"
if ! pgrep -f "Illumina" > /dev/null; then
    nohup "$APP" > /dev/null 2>&1 &
    sleep 6
fi
google-chrome --app=https://localhost --user-data-dir=/tmp/IlluminaPortal > /dev/null 2>&1 &
EOF

cat <<EOF > "$INSTALL_DIR/restart-illumina.sh"
#!/bin/bash
pkill -f "Illumina"
pkill -f "IlluminaKiosk"
sleep 2
rm -rf /tmp/IlluminaKiosk
APP="$INSTALL_DIR/Illumina"
nohup "$APP" > /dev/null 2>&1 &
sleep 6
google-chrome --app=https://localhost --user-data-dir=/tmp/IlluminaPortal > /dev/null 2>&1 &
EOF

chmod +x "$INSTALL_DIR/open-illumina.sh" "$INSTALL_DIR/restart-illumina.sh"

# Desktop Shortcuts & Autostart
DESKTOP_DIR="$USER_HOME/Desktop"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
sudo -u "$HUMAN_USER" mkdir -p "$DESKTOP_DIR" "$AUTOSTART_DIR"

create_desktop_file() {
    local FILE_PATH=$1
    local NAME=$2
    local EXEC=$3
    cat <<EOF > "$FILE_PATH"
[Desktop Entry]
Type=Application
Name=$NAME
Exec=$EXEC
Icon=utilities-terminal
Terminal=false
EOF
    chown "$HUMAN_USER:$HUMAN_USER" "$FILE_PATH"
    chmod +x "$FILE_PATH"
    # GNOME requires trusting the desktop file
    if command -v gio &> /dev/null; then
        sudo -u "$HUMAN_USER" gio set "$FILE_PATH" metadata::trusted true
    fi
}

create_desktop_file "$DESKTOP_DIR/illumina.desktop" "Illumina" "$INSTALL_DIR/open-illumina.sh"
create_desktop_file "$DESKTOP_DIR/restart-illumina.desktop" "Restart Illumina" "$INSTALL_DIR/restart-illumina.sh"

if [ "$AUTO_LOGIN_ON" = true ]; then
    create_desktop_file "$AUTOSTART_DIR/illumina.desktop" "Illumina" "$INSTALL_DIR/open-illumina.sh"
fi

# Firewall (UFW)
if command -v ufw &> /dev/null; then
    ufw allow 443/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
fi

# Disable Sleep
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1
sudo -u "$HUMAN_USER" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' > /dev/null 2>&1 || true

echo ""
echo "=================================================="
echo "   Setup complete - Illumina $TAG_NAME is ready!"
echo "=================================================="
echo "   Kiosk account : $HUMAN_USER"
echo "   Auto sign-in  : $([ "$AUTO_LOGIN_ON" = true ] && echo 'configured' || echo 'off - normal logon screen')"
echo "   Right Wall    : $RIGHT_ON   Streaming: $STREAM_ON   Drive sync: $SYNC_ON"
echo "   Portal        : $PORTAL_URL"
echo ""

if [ "$AUTO_LOGIN_ON" = true ]; then
    echo "   Auto sign-in takes effect the next time this PC restarts - for example"
    echo "   after a power cut or your next planned reboot. There is nothing you need"
    echo "   to do right now: the desktop icon 'Illumina' starts everything immediately"
    echo "   in this session, and from the next restart onward the PC will boot"
    echo "   straight into Illumina on its own."
    read -p "   Would you like to restart now to see auto sign-in in action? [y/N] (ENTER = No): " ANS
    if [[ "$ANS" =~ ^[yY]$ ]]; then reboot; fi
else
    echo "   No restart is needed - everything is live already. The desktop icon"
    echo "   'Illumina' starts the app and opens the portal any time."
fi
