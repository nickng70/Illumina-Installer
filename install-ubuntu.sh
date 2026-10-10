#!/bin/bash
# ==============================================================================
# Illumina AVA PC Installer - Ubuntu 22.04/24.04 LTS (v8.0 FINAL)
# - Friendly sudo check; nothing changes before it passes
# - Provisions media engines via apt: LibreOffice, FFmpeg, wmctrl, zenity, 
#   and Google Chrome (official .deb) if missing
# - Five-question survey (Right Display / Streaming / Drive sync / device
#   automation / Novastar brightness); ENTER = No everywhere
# - Device automation: detect Home Assistant first, then address, then offer
#   a real Docker install here (Ubuntu is officially supported territory)
# - Patches the INSTALLED appsettings.json with the PFX Kestrel block when
#   the release zip predates it - PARSE-FREE awk text insert
# - Grants the AVA PC account read access to the GitHub token for in-app updates
# - Binding contract per AGENTS.md: HTTPS localhost-only + HTTP on all
#   interfaces; congregation QR BaseUrl auto-stamped from the LAN address
# - Resolved dependency paths + integration settings stamped into the
#   per-machine overrides layer (merge, never clobber)
# - Clean [1]/[2] AVA PC account menu; GDM3 auto sign-in; ufw; sleep masked
# - Simplified, bulletproof desktop shortcuts (Native Chrome portal +
#   Backend manager with friendly zenity UI prompts)
# - Human-facing labels use "Display" and "Sabbath"; internal config keys
#   keep their legacy names for backwards compatibility
# ==============================================================================
set -e

# ----------------------------- [0/9] SUDO CHECK -----------------------------
if [ "$EUID" -ne 0 ]; then
  echo ""
  echo "  Illumina setup needs administrator (sudo) rights for this one run - it"
  echo "  installs program files to /opt, configures the firewall, and sets up"
  echo "  the AVA PC environment."
  echo ""
  echo "  Please close this terminal, open a new one, and run:"
  echo "  sudo ./install-ubuntu.sh"
  echo ""
  echo "  Nothing on this PC has been changed yet."
  exit 1
fi

if [ -n "$SUDO_USER" ]; then INTERACTIVE_USER="$SUDO_USER"; else INTERACTIVE_USER=$(logname 2>/dev/null || echo "root"); fi
if [ "$INTERACTIVE_USER" = "root" ]; then
    echo "  Please run this script via 'sudo' while logged in as your normal user,"
    echo "  rather than switching to root directly, so shortcuts land in the right profile."
    exit 1
fi
USER_HOME=$(eval echo "~$INTERACTIVE_USER")
INSTALL_DIR="/opt/illumina"
MACHINE_DIR="/var/lib/illumina"
HTTP_PORT="443"
PORTAL_URL="https://localhost"

echo "=================================================="
echo "   Illumina AVA PC Installer - Ubuntu (v8.0)      "
echo "   Guided setup for a safe, self-starting AVA PC  "
echo "=================================================="
echo ""
echo "  Welcome! This installer prepares this PC to run Illumina."
echo "  1. Fetches the latest release and the media engines it needs,"
echo "  2. Configures secure local HTTPS with local SSL certificate and"
echo "  3. Integrations with your hardware."
echo "  Note: To change or customize advanced options,"
echo "        navigate to Menu->Settings."

# ----------------------------- [1/9] DEPENDENCIES ---------------------------
echo -e "\n==> [1/9] Accessing GitHub Illumina repository..."
apt-get update -qq > /dev/null
# Added zenity for the native Linux pop-up message box
apt-get install -y -qq curl unzip jq openssl wmctrl zenity > /dev/null
echo "  Core tools (curl, unzip, jq, openssl, wmctrl, zenity) are ready."

# ----------------------------- [2/9] GITHUB TOKEN ---------------------------
mkdir -p "$MACHINE_DIR"
TOKEN_FILE="$MACHINE_DIR/github-token"
if [ -n "$GITHUB_TOKEN" ]; then
    TOKEN="$GITHUB_TOKEN"; echo "  Using the token from this session's environment."
elif [ -f "$TOKEN_FILE" ]; then
    TOKEN=$(cat "$TOKEN_FILE"); echo "  Reusing the token stored on this machine."
else
    echo "  Illumina's release packages live in a private repository, so we need"
    echo "  a read-only GitHub token once; it is then stored securely on this PC."
    read -p "  Paste your GitHub read-only token: " TOKEN
    if [ -z "$TOKEN" ]; then echo "  A token is required. Exiting."; exit 1; fi
    echo "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    echo "  Token stored securely (root only)."
fi

# ----------------------------- [3/9] DOWNLOAD RELEASE -----------------------
echo -e "\n==> [2/9] Downloading the latest Illumina release..."
RELEASE_JSON=$(curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/nickng70/Illumina-Releases/releases/latest")
TAG_NAME=$(echo "$RELEASE_JSON" | jq -r '.tag_name')
ASSET_URL=$(echo "$RELEASE_JSON" | jq -r '.assets[] | select(.name=="illumina-linux-x64.zip") | .url')
if [ -z "$ASSET_URL" ] || [ "$ASSET_URL" = "null" ]; then
    echo "  Asset 'illumina-linux-x64.zip' not found in release $TAG_NAME."; exit 1
fi
ZIP_FILE="/tmp/illumina-linux-x64.zip"
curl -s -L -H "Authorization: Bearer $TOKEN" -H "Accept: application/octet-stream" -o "$ZIP_FILE" "$ASSET_URL"
echo "  Release $TAG_NAME downloaded."

# ----------------------------- [4/9] MEDIA ENGINES & BROWSER ----------------
echo -e "\n==> [3/9] Provisioning media engines and the display browser..."
echo "  Illumina relies on three companions: LibreOffice (converts slide"
echo "  decks), FFmpeg (remuxes the broadcast feed), and Chrome (renders every"
echo "  display). Anything missing will be installed now."
apt-get install -y -qq libreoffice ffmpeg > /dev/null
echo "  LibreOffice and FFmpeg are ready."

resolve_chrome() {
    for c in google-chrome google-chrome-stable chromium chromium-browser; do
        if command -v "$c" > /dev/null 2>&1; then command -v "$c"; return 0; fi
    done
    return 1
}
CHROME_BIN=$(resolve_chrome || true)
if [ -z "$CHROME_BIN" ]; then
    echo "  Chrome not found - installing Google Chrome..."
    curl -sSL -o /tmp/chrome.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb
    apt-get install -y -qq /tmp/chrome.deb > /dev/null || true
    rm -f /tmp/chrome.deb
    CHROME_BIN=$(resolve_chrome || true)
fi
if [ -n "$CHROME_BIN" ]; then echo "  Chrome ready at $CHROME_BIN"; else echo "  WARNING: no Chrome/Chromium found - the portal will fall back to the default browser."; fi

# ----------------------------- [5/9] PAUSE PREVIOUS SESSION -----------------
echo -e "\n==> [4/9] Pausing any running Illumina session..."
pkill -f "$INSTALL_DIR/Illumina" || true
pkill -f "IlluminaKiosk" || true
sleep 2
rm -rf /tmp/IlluminaKiosk || true
echo "  Previous session paused - your open browser tabs and files are untouched."

# ----------------------------- [6/9] AVA PC ACCOUNT & SIGN-IN ---------------
echo -e "\n==> [5/9] Choosing the AVA PC account and sign-in behavior..."
echo ""
echo "  How will this AVA PC be used?"
echo ""
echo "  [1] Dedicated AVA PC Account (Recommended)"
echo "      Creates a clean, standard-user account named 'avauser' just for Illumina."
echo "      This keeps the desktop uncluttered, prevents accidental system changes,"
echo "      and provides the safest environment for Sabbath services."
echo ""
echo "  [2] Run Illumina using $INTERACTIVE_USER"
echo "      Uses your current Linux account ($INTERACTIVE_USER)."
echo "      Choose this for personal laptops or if you are just testing Illumina."
read -p "  Select setup type (press ENTER for 1): " MODE
USE_AVA_USER=true; [ "$MODE" = "2" ] && USE_AVA_USER=false

AUTO_LOGIN_ON=false
if [ "$USE_AVA_USER" = true ]; then
    HUMAN_USER="avauser"
    if ! id "$HUMAN_USER" &>/dev/null; then
        echo "  Set the password for the AVA PC account ('avauser') - used for maintenance logins:"
        while true; do
            read -s -p "  Password: " p1; echo
            read -s -p "  Confirm : " p2; echo
            if [ "$p1" = "$p2" ] && [ -n "$p1" ]; then PLAIN_PASS="$p1"; break; fi
            echo "  Passwords did not match or were empty. Try again."
        done
        useradd -m -s /bin/bash "$HUMAN_USER"
        echo "$HUMAN_USER:$PLAIN_PASS" | chpasswd
        echo "  Created dedicated account 'avauser'."
    else
        echo "  Reusing existing AVA PC account 'avauser'."
    fi
    AUTO_LOGIN_ON=true
    echo "  Auto sign-in configured for avauser - it activates at the next restart."
else
    HUMAN_USER="$INTERACTIVE_USER"
    echo ""
    echo "  Auto sign-in lets the PC boot straight into Illumina without having to login."
    echo "  Choose No if this is your own laptop or to disable Auto sign-in."
    read -p "  Enable auto sign-in for $HUMAN_USER? [y/N] (ENTER = No): " WANT_AUTO
    if [[ "$WANT_AUTO" =~ ^[yY]$ ]]; then AUTO_LOGIN_ON=true; echo "  Auto sign-in enabled for $HUMAN_USER."; fi
fi

# Grant the AVA PC account read access to the GitHub token
if [ -f "$TOKEN_FILE" ]; then
    chown root:"$HUMAN_USER" "$TOKEN_FILE"
    chmod 640 "$TOKEN_FILE"
    echo "  Granted read access to the GitHub token for $HUMAN_USER."
fi

GDM_CONF="/etc/gdm3/custom.conf"
if [ "$AUTO_LOGIN_ON" = true ] && [ -f "$GDM_CONF" ]; then
    if grep -q "^AutomaticLoginEnable" "$GDM_CONF"; then
        sed -i "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=true/" "$GDM_CONF"
        sed -i "s/^AutomaticLogin=.*/AutomaticLogin=$HUMAN_USER/" "$GDM_CONF"
    else
        sed -i "/^\[daemon\]/a AutomaticLoginEnable=true\nAutomaticLogin=$HUMAN_USER" "$GDM_CONF"
    fi
else
    if [ -f "$GDM_CONF" ]; then
        sed -i "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/" "$GDM_CONF" || true
    fi
    echo "  Auto sign-in left OFF - the PC keeps its normal logon screen."
fi

# ----------------------------- [7/9] APP FILES & PERMISSIONS ----------------
echo -e "\n==> [6/9] Installing Illumina and preparing its content folders..."
if [ -d "$INSTALL_DIR/Data" ]; then mv "$INSTALL_DIR/Data" /tmp/illumina-data-backup; fi
rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
unzip -q "$ZIP_FILE" -d "$INSTALL_DIR"; rm -f "$ZIP_FILE"
if [ -d "/tmp/illumina-data-backup" ]; then rm -rf "$INSTALL_DIR/Data"; mv /tmp/illumina-data-backup "$INSTALL_DIR/Data"; fi
mkdir -p "$INSTALL_DIR/Data"

for W_DIR in SlideContent MediaContent AppData Recordings; do
    mkdir -p "$INSTALL_DIR/$W_DIR"
    chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/$W_DIR"
    chmod 755 "$INSTALL_DIR/$W_DIR"
done
chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/Data"
chmod 500 "$INSTALL_DIR/Data"
echo "  Content folders prepared with native Linux permissions (locked to $HUMAN_USER)."
echo "$TAG_NAME" > "$MACHINE_DIR/current-version"

# ----------------------------- [8/9] SURVEY, CERT, OVERRIDES ----------------
echo -e "\n==> [7/9] Site survey, HTTPS certificate, and machine settings..."
echo ""
echo "  Every church is wired differently, so we ask five quick questions."
echo "  ENTER accepts the safe default (No) for each, and everything here can"
echo "  be changed later in Menu->Settings."
echo "  Note: the CG overlay output is always prepared as part of the core"
echo "  display set (like the Left Display); question 2 controls the broadcast"
echo "  encoder, stream monitors and Aux Hall."
read -p "  [1/5] Do you have a RIGHT Display (in addition to the Left Display)? [y/N] (ENTER = No): " R_WALL
read -p "  [2/5] Enable STREAMING display (for streaming and Aux Hall displays)? [y/N] (ENTER = No): " STREAM
read -p "  [3/5] Retrieve Prayer/Announcement slides from Google Drive? [y/N] (ENTER = No): " SYNC
echo ""
echo "  Illumina can also talk to the smart hardware many churches already own."
echo "  Both integrations are optional and can be switched on later in Settings."
echo "  Device control runs through Home Assistant; LED brightness schedules and"
echo "  cabinet health through the Novastar controller."
read -p "  [4/5] Automatically control devices (e.g. Tapo smart plugs to power off/on LED walls)? [y/N] (ENTER = No): " HA_USE
read -p "  [5/5] Automatically control brightness on Novastar Video Controller? [y/N] (ENTER = No): " NV_USE
RIGHT_ON=false;  [[ "$R_WALL" =~ ^[yY]$ ]] && RIGHT_ON=true
STREAM_ON=false; [[ "$STREAM" =~ ^[yY]$ ]] && STREAM_ON=true
SYNC_ON=false;   [[ "$SYNC"   =~ ^[yY]$ ]] && SYNC_ON=true

KEY_JSON="$MACHINE_DIR/key.json"; PRAYER_ID=""; ANN_ID=""
if [ "$SYNC_ON" = true ]; then
    if [ ! -f "$KEY_JSON" ]; then
        echo "  Fetching the Drive key from the private repository..."
        curl -s -H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github.raw" \
            "https://api.github.com/repos/nickng70/Illumina-Releases/contents/secrets/drive-key.json" -o "$KEY_JSON" || rm -f "$KEY_JSON"
    fi
    if [ -f "$KEY_JSON" ]; then
        chown "$HUMAN_USER:$HUMAN_USER" "$KEY_JSON"; chmod 400 "$KEY_JSON"
        read -p "  Prayer slides folder ID (Google Drive): " PRAYER_ID
        read -p "  Announcements slides folder ID (Google Drive): " ANN_ID
        if [ -z "$PRAYER_ID" ] || [ -z "$ANN_ID" ]; then SYNC_ON=false; echo "  A folder ID was left empty, so Drive sync stays OFF."; fi
    else
        SYNC_ON=false; echo "  No Drive key available, so Drive sync stays OFF."
    fi
fi

HA_ON=false; HA_URL=""
if [[ "$HA_USE" =~ ^[yY]$ ]]; then
    if curl -s -o /dev/null --max-time 3 http://localhost:8123; then
        HA_URL="http://localhost:8123"; HA_ON=true
        echo "  Home Assistant detected on this PC."
    fi
    if [ -z "$HA_URL" ]; then
        read -p "  Home Assistant address on your network (e.g. http://192.168.1.50:8123), or ENTER if not set up yet: " HA_URL
        if [ -n "$HA_URL" ]; then HA_ON=true; echo "  Home Assistant will be reached at $HA_URL"; fi
    fi
    if [ -z "$HA_URL" ]; then
        read -p "  Install Home Assistant now on this PC (Docker container, host networking)? [Y/n] (ENTER = Yes): " HA_INSTALL
        if [[ ! "$HA_INSTALL" =~ ^[nN] ]]; then
            if ! command -v docker > /dev/null 2>&1; then
                echo "  Installing Docker..."
                apt-get install -y -qq docker.io > /dev/null
                systemctl enable --now docker > /dev/null 2>&1 || true
            fi
            mkdir -p /var/lib/homeassistant
            if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^homeassistant$'; then
                docker run -d --name homeassistant --restart=unless-stopped --network=host \
                    -v /var/lib/homeassistant:/config ghcr.io/home-assistant/home-assistant:stable > /dev/null
            fi
            HA_URL="http://localhost:8123"; HA_ON=true
            echo "  Home Assistant installed - its dashboard appears at http://localhost:8123 once first boot finishes (1-2 minutes)."
        else
            echo "  Home Assistant is officially supported on Linux, VMs and dedicated hardware"
            echo "  (a Raspberry Pi is the church favourite). Illumina only needs its web"
            echo "  address, which you can add any time in Settings > Device Setup."
        fi
    fi
fi

NV_ON=false; NV_HOST=""
if [[ "$NV_USE" =~ ^[yY]$ ]]; then
    read -p "  Novastar controller IP address (e.g. 172.16.0.11): " NV_HOST
    if [ -n "$NV_HOST" ]; then NV_ON=true; echo "  Novastar will target $NV_HOST - pair the auth token later in Settings > Device Setup."; fi
    if [ -z "$NV_HOST" ]; then echo "  No controller address given - Novastar integration left OFF."; fi
fi

echo ""
echo "  Illumina serves its portal over HTTPS on this PC only. We create a private"
echo "  100-year certificate, trust it system-wide, and hand Kestrel the PFX path."
PFX_PATH="$MACHINE_DIR/illumina.pfx"; PFX_PASS="IlluminaKioskCert"
openssl req -x509 -newkey rsa:4096 -keyout /tmp/illumina.key -out /tmp/illumina.crt -days 36500 -nodes -subj "/CN=localhost" > /dev/null 2>&1
openssl pkcs12 -export -out "$PFX_PATH" -inkey /tmp/illumina.key -in /tmp/illumina.crt -passout pass:"$PFX_PASS" > /dev/null 2>&1
cp /tmp/illumina.crt /usr/local/share/ca-certificates/illumina.crt
update-ca-certificates > /dev/null 2>&1
rm -f /tmp/illumina.key /tmp/illumina.crt
chown "$HUMAN_USER:$HUMAN_USER" "$PFX_PATH"; chmod 400 "$PFX_PATH"
echo "  Certificate created, trusted system-wide, and ready for Kestrel."

if [ -f "$INSTALL_DIR/appsettings.json" ] && ! grep -q '"Kestrel"' "$INSTALL_DIR/appsettings.json"; then
    awk -v pfx="$PFX_PATH" -v pass="$PFX_PASS" '
        NR==1 && $0 ~ /^[[:space:]]*\{/ {
            print
            print "  \"Kestrel\": {"
            print "    \"Certificates\": {"
            print "      \"Default\": {"
            print "        \"Path\": \"" pfx "\","
            print "        \"Password\": \"" pass "\""
            print "      }"
            print "    }"
            print "  },"
            next
        }
        { print }
    ' "$INSTALL_DIR/appsettings.json" > "$INSTALL_DIR/appsettings.json.tmp" \
        && mv "$INSTALL_DIR/appsettings.json.tmp" "$INSTALL_DIR/appsettings.json"
    echo "  Patched appsettings.json with the HTTPS certificate path (text insert)."
fi

LAN_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
CV_URL=""; [ -n "$LAN_IP" ] && CV_URL="http://$LAN_IP"

OVERRIDES="$INSTALL_DIR/AppData/AppSettingsOverrides.json"
mkdir -p "$INSTALL_DIR/AppData"
[ -f "$OVERRIDES" ] || echo '{}' > "$OVERRIDES"
jq \
  --argjson right "$RIGHT_ON" --argjson stream "$STREAM_ON" --argjson sync "$SYNC_ON" \
  --argjson haon "$HA_ON" --arg haurl "$HA_URL" \
  --argjson nvon "$NV_ON" --arg nvhost "$NV_HOST" \
  --arg cvurl "$CV_URL" \
  --arg key "$KEY_JSON" --arg prayer "$PRAYER_ID" --arg ann "$ANN_ID" \
  --arg soffice "/usr/bin/soffice" --arg ffmpeg "/usr/bin/ffmpeg" \
  '
    .Urls = "https://localhost;http://0.0.0.0:80"
    | .Kiosk = ((.Kiosk // {}) + { BaseUrl: "https://localhost", Enabled: true,
                                   RightWallEnabled: $right, CgEnabled: $stream, ProgramEnabled: $stream })
    | (if $stream then . else .Kiosk.CgConfidenceMonitorEnabled = false end)
    | .SlideLibrary = ((.SlideLibrary // {}) + {
        LibreOfficePath: $soffice,
        GoogleDrive: {
          ServiceAccountKeyPath: (if $sync then $key else "" end),
          PrayerFolderId: (if $sync then $prayer else "" end),
          AnnouncementsFolderId: (if $sync then $ann else "" end)
        } })
    | .Broadcast = ((.Broadcast // {}) + { FFmpegPath: $ffmpeg })
    | .HomeAssistant = ((.HomeAssistant // {}) + { Enabled: $haon } + (if $haurl != "" then { BaseUrl: $haurl } else {} end))
    | .Novastar = ((.Novastar // {}) + { Enabled: $nvon } + (if $nvon then { Host: $nvhost } else {} end))
    | .CongregationView = ((.CongregationView // {}) + (if $cvurl != "" then { BaseUrl: $cvurl } else {} end))
  ' "$OVERRIDES" > "$OVERRIDES.tmp" && mv "$OVERRIDES.tmp" "$OVERRIDES"
chown "$HUMAN_USER:$HUMAN_USER" "$OVERRIDES"
echo "  Dependency paths stamped: LibreOffice='/usr/bin/soffice' FFmpeg='/usr/bin/ffmpeg'"
[ -n "$CV_URL" ] && echo "  Congregation phones will reach this PC at $CV_URL (QR overlay + /view page)."

# ----------------------------- [9/9] HELPERS, SHORTCUTS, NETWORK ------------
echo -e "\n==> [8/9] Writing the everyday shortcuts..."
CHROME_BIN_SAFE=${CHROME_BIN:-/usr/bin/google-chrome}

# The Backend Manager: Kills any existing backend, starts a fresh one hidden,
# and pops up a friendly native Linux message box (via zenity) telling the 
# volunteer that the engine is ready and they can now open the portal.
cat <<EOF > "$INSTALL_DIR/start-backend.sh"
#!/bin/bash
APP="$INSTALL_DIR/Illumina"
pkill -f "\$APP" || true
sleep 1
nohup "\$APP" > /dev/null 2>&1 &

if [ "\$1" != "--silent" ]; then
    if command -v zenity > /dev/null 2>&1; then
        zenity --info --title="Illumina AVA PC" --text="The Illumina backend is now running in the background.\n\nPlease click the 'Illumina Portal' shortcut on your desktop to open the control panel." --width=400 > /dev/null 2>&1 || true
    fi
fi
EOF
chmod +x "$INSTALL_DIR/start-backend.sh"

DESKTOP_DIR="$USER_HOME/Desktop"
AUTOSTART_DIR="$USER_HOME/.config/autostart"
sudo -u "$HUMAN_USER" mkdir -p "$DESKTOP_DIR" "$AUTOSTART_DIR"

create_desktop_file() {
    local FILE_PATH=$1 NAME=$2 EXEC=$3
    cat <<EOF > "$FILE_PATH"
[Desktop Entry]
Type=Application
Name=$NAME
Exec=$EXEC
Icon=utilities-terminal
Terminal=false
EOF
    chown "$HUMAN_USER:$HUMAN_USER" "$FILE_PATH"; chmod +x "$FILE_PATH"
    if command -v gio &> /dev/null; then sudo -u "$HUMAN_USER" gio set "$FILE_PATH" metadata::trusted true 2>/dev/null || true; fi
}

# Clean up old shortcuts
rm -f "$DESKTOP_DIR"/illumina*.desktop "$DESKTOP_DIR"/restart*.desktop "$AUTOSTART_DIR"/illumina*.desktop 2>/dev/null || true

# 1. The Portal Shortcut (Native Chrome, no wrapper)
create_desktop_file "$DESKTOP_DIR/illumina-portal.desktop" "Illumina Portal" "$CHROME_BIN_SAFE --app=$PORTAL_URL"

# 2. The Backend Restart Shortcut (Shows the friendly zenity pop-up)
create_desktop_file "$DESKTOP_DIR/restart-illumina.desktop" "Restart Illumina Backend" "$INSTALL_DIR/start-backend.sh"

# 3. The Auto-Start Shortcut (Runs silently on boot)
if [ "$AUTO_LOGIN_ON" = true ]; then
    create_desktop_file "$AUTOSTART_DIR/illumina-backend.desktop" "Illumina Backend" "$INSTALL_DIR/start-backend.sh --silent"
fi
echo "  Shortcuts placed for $HUMAN_USER - 'Illumina Portal' (everyday) and 'Restart Illumina Backend' (recovery)."

echo -e "\n==> [9/9] Opening the network doors and keeping the PC awake..."
if command -v ufw &> /dev/null; then
    ufw allow 443/tcp > /dev/null; ufw allow 80/tcp > /dev/null
fi
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1 || true
sudo -u "$HUMAN_USER" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' > /dev/null 2>&1 || true
echo "  Firewall allows the portal (443) and congregation phones (80); sleep is disabled."

echo ""
echo "=================================================="
echo "   Setup complete - Illumina $TAG_NAME is ready!"
echo "=================================================="
echo "   AVA PC Account: $HUMAN_USER"
echo "   Auto sign-in  : $([ "$AUTO_LOGIN_ON" = true ] && echo 'configured' || echo 'off - normal logon screen')"
echo "   Right Display : $RIGHT_ON   Streaming: $STREAM_ON   Drive sync: $SYNC_ON"
echo "   Home Assistant: $([ "$HA_ON" = true ] && echo "$HA_URL" || echo 'off')   Novastar: $([ "$NV_ON" = true ] && echo "$NV_HOST" || echo 'off')"
echo ""
echo "  Congratulations! You are all set! Here is how to start your first session:"
echo ""
echo "   1. RESTART this PC (or click 'Restart Illumina Backend'"
echo "      on the desktop). This starts the engine in the background."
echo ""
echo "   2. Click the 'Illumina Portal' shortcut on the desktop."
echo "      The control panel will open, and your displays will wake up!"
echo ""
echo "  From now on, the backend starts automatically every time the PC"
echo "  boots. You only ever need to click the 'Illumina Portal' icon."
echo ""
if [ "$AUTO_LOGIN_ON" = true ]; then
    read -p "  Would you like to restart now to finish setup? [y/N] (ENTER = No): " ANS
    if [[ "$ANS" =~ ^[yY]$ ]]; then reboot; fi
fi
