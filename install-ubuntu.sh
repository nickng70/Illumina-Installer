#!/bin/bash
# ==============================================================================
# Illumina AVA PC Installer - Ubuntu 22.04/24.04 LTS (v1.0)
# - Friendly sudo check; nothing changes before it passes
# - Provisions media engines via apt: LibreOffice, FFmpeg, wmctrl, zenity,
#   libnss3-tools (Chrome's certificate store), and Google Chrome
#   (official .deb) if missing
# - Quick survey (Right Display / Drive sync / primary + secondary display
#   language); ENTER takes the suggestion. Streaming/CG, smart-plug
#   automation and Novastar brightness are NOT asked here - they are
#   usually not set up yet on install day, and the factory defaults
#   already cover them. Rotating "Did you know?" tips during the
#   downloads point the user at Menu->Settings for those
# - Stamps the PFX Kestrel HTTPS block into the per-machine overrides layer
#   (AppData/AppSettingsOverrides.json) via jq - the factory
#   appsettings.json is never touched
# - Imports the machine certificate into Chrome's NSS database as well as
#   the system CA store (Chrome ignores the system store on Linux)
# - Updates preserve machine state: AppData (settings + secrets),
#   MediaContent, SlideContent, Recordings and any customized
#   Data/Localization strings survive a re-install; the app and the
#   Bible/hymn corpus refresh from the new build
# - Grants the AVA PC account read access to the GitHub token for in-app updates
# - Binding contract per AGENTS.md: HTTPS localhost-only + HTTP on all
#   interfaces. The congregation QR address is AUTO-DETECTED by the app at
#   runtime (physical LAN NIC, gateway preferred) - no IP is stamped here
#   anymore, so a DHCP reassignment never breaks the QR code; Settings can
#   pin it
# - Resolved dependency paths + integration settings stamped into the
#   per-machine overrides layer (merge, never clobber)
# - Clean [1]/[2] AVA PC account menu; GDM3 auto sign-in; ufw; sleep masked
# - Backend autostart is installed for EVERY setup (auto sign-in only
#   controls the login screen, not whether the app starts)
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
PORTAL_URL="https://localhost"

# Rotating "Did you know?" tips, shown before each long download/install so
# the wait doubles as a tour of what Menu->Settings can do later.
TIP_INDEX=0
TIPS=(
"Members can follow the service on their phones - the Congregation QR overlay appears on the wall displays at your cue. Nothing to set up: it always uses this PC's live network address."
"Ready to stream or record? Settings -> Displays wakes up the CG overlay and the Broadcast Encoder whenever you are - no reinstall."
"Settings -> Device Setup can power LED walls on and off on a schedule with Tapo smart plugs (via Home Assistant) - the rack switches itself off after the service."
"Have a Novastar video controller? Settings -> Device Setup adds day/evening brightness schedules and cabinet health monitoring - no more climbing into the rack."
"Illumina speaks five languages - English, Chinese (Simplified and Traditional), Indonesian and Malay - each with its own hymn corpus and display fonts. See Settings -> Appearance."
"Hymns can display top-and-bottom or side-by-side, per screen, and the Edit Hymns page proofreads every layout while you type."
"A pulpit tablet becomes the speaker's console at /tablet - slide advance, laser pointer and ink annotations included."
"PTZ cameras can be driven from the portal with named presets tied to broadcast scenes - one tap frames the shot."
"Menu -> Check for Updates brings new features and fresh hymn/Bible content to this PC with one tap - library updates need no restart."
"Capture devices (cameras, switchers) can join any broadcast scene - add them in Settings whenever your hardware arrives."
)
show_tip() {
    local T="${TIPS[$((TIP_INDEX % ${#TIPS[@]}))]}"
    TIP_INDEX=$((TIP_INDEX + 1))
    echo ""
    echo "  --------------------------------------------"
    echo "  DID YOU KNOW?"
    echo "  $T" | fold -s -w 66 | sed 's/^/  /'
    echo "  --------------------------------------------"
    echo ""
}

echo "=================================================="
echo "   Illumina AVA PC Installer - Ubuntu (v1.0)      "
echo "   Guided setup for a safe, self-starting AVA PC  "
echo "=================================================="
echo ""
echo "  Welcome! In the next few minutes this PC will become your"
echo "  church's presentation hub - displays, hymns, streaming and all."
echo "  Here is what we will do together:"
echo "   1. Fetch the latest Illumina release and its media engines,"
echo "   2. Set up secure local HTTPS with a private certificate, and"
echo "   3. Match the software to your church with a few quick questions."
echo "  Sit back - most of it is automatic, everything can be adjusted"
echo "  later in Menu->Settings, and we will share a few tips while"
echo "  the downloads run."

# ----------------------------- [1/9] DEPENDENCIES ---------------------------
echo -e "\n==> [1/9] Accessing GitHub Illumina repository..."
apt-get update -qq > /dev/null
# Added zenity for the native Linux pop-up message box; libcap2-bin provides
# setcap, which lets the unprivileged kiosk account bind ports 80/443.
apt-get install -y -qq curl unzip jq openssl wmctrl zenity libnss3-tools libcap2-bin > /dev/null
# curl is NOT preinstalled on a fresh Ubuntu - and neither are some of the
# others on minimal installs. Verify the essentials actually landed rather
# than failing mysteriously three steps later.
for TOOL in curl unzip jq openssl; do
    if ! command -v "$TOOL" > /dev/null 2>&1; then
        echo "  ERROR: the '$TOOL' tool could not be installed. Please check this PC's"
        echo "  internet connection, run 'sudo apt update', then re-run this installer."
        exit 1
    fi
done
echo "  Core tools (curl, unzip, jq, openssl, wmctrl, zenity, libnss3-tools) are ready."

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
show_tip
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
show_tip
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
    show_tip
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
show_tip

# Move the machine's state aside before wiping, restore it after the new
# build lands. AppData holds every machine setting + secret (overrides,
# operator form, kiosk geometry); MediaContent/SlideContent/Recordings are
# the church's own libraries; Data/Localization keeps any customized UI
# strings. Everything else under Data (the Bible/hymn corpus) deliberately
# REFRESHES from the new build so content fixes reach every church.
PRESERVE=$(mktemp -d)
for ITEM in AppData MediaContent SlideContent Recordings; do
    if [ -d "$INSTALL_DIR/$ITEM" ]; then mv "$INSTALL_DIR/$ITEM" "$PRESERVE/$ITEM"; fi
done
if [ -d "$INSTALL_DIR/Data/Localization" ]; then
    mkdir -p "$PRESERVE/Data"
    mv "$INSTALL_DIR/Data/Localization" "$PRESERVE/Data/Localization"
fi
# Extract into a STAGING folder first and verify it before swapping anything
# in. unzip exit codes: 0 = success, 1 = warnings only (e.g. the historical
# "backslashes as path separators" notice from Windows-built zips) - both are
# fine; anything above 1 is a real error and must not be swallowed by set -e.
STAGE=$(mktemp -d)
UNZIP_RC=0
unzip -q "$ZIP_FILE" -d "$STAGE" || UNZIP_RC=$?
rm -f "$ZIP_FILE"
if [ "$UNZIP_RC" -gt 1 ]; then
    echo "  ERROR: the release package could not be extracted (unzip error $UNZIP_RC)."
    echo "  The download may have been interrupted - please re-run this installer."
    echo "  Your preserved settings and libraries are safe in: $PRESERVE"
    rm -rf "$STAGE"
    exit 1
fi
if [ ! -f "$STAGE/Illumina" ]; then
    echo "  ERROR: the extracted package does not contain the expected Illumina binary."
    if ls "$STAGE" | grep -q '\\'; then
        echo "  This package was published with an old publisher that used Windows-style"
        echo "  backslash paths. Please publish a fresh release and run this installer again."
    else
        echo "  The download looks incomplete - please re-run this installer."
    fi
    echo "  Your preserved settings and libraries are safe in: $PRESERVE"
    rm -rf "$STAGE"
    exit 1
fi
rm -rf "$INSTALL_DIR"; mkdir -p "$INSTALL_DIR"
cp -a "$STAGE/." "$INSTALL_DIR/"
rm -rf "$STAGE"
# cp -a of a mktemp dir's "/." also copies the staging dir's own 0700 mode
# onto the install dir, locking the kiosk account out entirely ("cd:
# /opt/illumina: Permission denied" - observed on the first real install).
chmod 755 "$INSTALL_DIR"
# A zip built on Windows carries no Unix exec bits - restore them (harmless if
# the package already stamped them via entry attributes).
chmod +x "$INSTALL_DIR/Illumina" 2>/dev/null || true
for ITEM in AppData MediaContent SlideContent Recordings; do
    if [ -d "$PRESERVE/$ITEM" ]; then
        rm -rf "$INSTALL_DIR/$ITEM"
        mv "$PRESERVE/$ITEM" "$INSTALL_DIR/$ITEM"
    fi
done
if [ -d "$PRESERVE/Data/Localization" ]; then
    # Per-key merge, NOT a wholesale restore: a release may add UI strings,
    # and a wholesale restore strands the UI on "[key]" placeholders for
    # every new feature (observed at v0.4). The new build's file is the base;
    # the church's customized values win key-by-key. Array files
    # (PresetTitles/EventTitles) and unparsable files take the church's copy.
    while IFS= read -r P_FILE; do
        REL="${P_FILE#"$PRESERVE"/Data/Localization/}"
        DEST="$INSTALL_DIR/Data/Localization/$REL"
        mkdir -p "$(dirname "$DEST")"
        if [ -f "$DEST" ] \
            && [ "$(jq -r 'type' "$DEST" 2>/dev/null)" = "object" ] \
            && [ "$(jq -r 'type' "$P_FILE" 2>/dev/null)" = "object" ] \
            && jq -s '.[0] * .[1]' "$DEST" "$P_FILE" > "$DEST.merged" 2>/dev/null; then
            mv "$DEST.merged" "$DEST"
        else
            rm -f "$DEST.merged"
            cp "$P_FILE" "$DEST"
        fi
    done < <(find "$PRESERVE/Data/Localization" -type f -name '*.json')
fi
rm -rf "$PRESERVE"
mkdir -p "$INSTALL_DIR/Data"
echo "  Machine state preserved (settings, media, slides, recordings, custom UI strings); app and Bible/hymn corpus refreshed."

for W_DIR in SlideContent MediaContent AppData Recordings; do
    mkdir -p "$INSTALL_DIR/$W_DIR"
    chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/$W_DIR"
    chmod 755 "$INSTALL_DIR/$W_DIR"
done
chown -R "$HUMAN_USER:$HUMAN_USER" "$INSTALL_DIR/Data"
chmod 500 "$INSTALL_DIR/Data"
echo "  Content folders prepared with native Linux permissions (locked to $HUMAN_USER)."
echo "$TAG_NAME" > "$MACHINE_DIR/current-version"

# Let the unprivileged kiosk account bind ports 80/443 (production config).
# No-op where the kernel already allows unprivileged binding; essential on
# older LTS kernels. Re-applied by the updater after every binary swap.
setcap 'cap_net_bind_service=+ep' "$INSTALL_DIR/Illumina" 2>/dev/null || true

# ----------------------------- [8/9] SURVEY, CERT, OVERRIDES ----------------
echo -e "\n==> [7/9] Site survey, HTTPS certificate, and machine settings..."
echo ""
echo "  Every church is wired differently, so we ask a few quick questions."
echo "  ENTER accepts the suggested default for each, and everything here can"
echo "  be changed later in Menu->Settings. Streaming, smart plugs and LED"
echo "  brightness are not asked here - they are usually not wired up yet on"
echo "  install day, and Settings switches them on whenever you are ready."
read -p "  [1/4] Do you have a RIGHT Display (in addition to the Left Display)? [y/N] (ENTER = No): " R_WALL
read -p "  [2/4] Retrieve Prayer/Announcement slides from Google Drive? [y/N] (ENTER = No): " SYNC
RIGHT_ON=false;  [[ "$R_WALL" =~ ^[yY]$ ]] && RIGHT_ON=true
SYNC_ON=false;   [[ "$SYNC"   =~ ^[yY]$ ]] && SYNC_ON=true

# Display languages. On a re-install the machine's existing choices become
# the defaults (ENTER keeps them); fresh installs default to English primary
# + Simplified Chinese secondary. Values are the app's LanguageCode enum
# names - they land in AppSettingsOverrides.json's Localization section.
LANG_CODES=("" "English" "ChineseSimplified" "ChineseTraditional" "Indonesian" "Malay")
LANG_NAMES=("" "English" "Simplified Chinese" "Traditional Chinese" "Bahasa Indonesia" "Bahasa Melayu")
OVERRIDES="$INSTALL_DIR/AppData/AppSettingsOverrides.json"
PRIMARY_DEFAULT=1; SECONDARY_DEFAULT=2
if [ -f "$OVERRIDES" ]; then
    CUR_P=$(jq -r '.Localization.PrimaryLanguage // empty' "$OVERRIDES" 2>/dev/null || true)
    CUR_S=$(jq -r '.Localization.SelectedSecondaryLanguage // empty' "$OVERRIDES" 2>/dev/null || true)
    for i in 1 2 3 4 5; do
        [ "$CUR_P" = "${LANG_CODES[$i]}" ] && PRIMARY_DEFAULT=$i
        [ "$CUR_S" = "${LANG_CODES[$i]}" ] && SECONDARY_DEFAULT=$i
    done
fi
read_language() {
    local LABEL=$1 DEFAULT=$2 SEL
    echo ""
    echo "  $LABEL"
    echo "        [1] English   [2] Simplified Chinese   [3] Traditional Chinese"
    echo "        [4] Bahasa Indonesia   [5] Bahasa Melayu"
    read -p "  Press ENTER for $DEFAULT (${LANG_NAMES[$DEFAULT]}): " SEL
    [[ "$SEL" =~ ^[1-5]$ ]] || SEL=$DEFAULT
    LANG_PICK=$SEL
}
read_language "[3/4] Choose the PRIMARY display language:" "$PRIMARY_DEFAULT"; PRIMARY_IDX=$LANG_PICK
while true; do
    read_language "[4/4] Choose the SECONDARY display language:" "$SECONDARY_DEFAULT"; SECONDARY_IDX=$LANG_PICK
    [ "$SECONDARY_IDX" != "$PRIMARY_IDX" ] && break
    echo "  Secondary cannot be the same as primary (${LANG_NAMES[$PRIMARY_IDX]}) - please pick a different one."
done
PRIMARY_LANG=${LANG_CODES[$PRIMARY_IDX]}; SECONDARY_LANG=${LANG_CODES[$SECONDARY_IDX]}
echo "  Languages: ${LANG_NAMES[$PRIMARY_IDX]} (primary) + ${LANG_NAMES[$SECONDARY_IDX]} (secondary)"

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

# Home Assistant / Novastar are deliberately not asked here: they are usually
# not wired up yet on install day. Settings -> Device Setup enables them later,
# and a re-install must never clobber what the church chose there.

echo ""
echo "  Illumina serves its portal over HTTPS on this PC only. We create a private"
echo "  100-year certificate, trust it system-wide and in Chrome, and hand Kestrel"
echo "  the PFX path via the machine's overrides layer."
PFX_PATH="$MACHINE_DIR/illumina.pfx"; PFX_PASS="IlluminaKioskCert"
openssl req -x509 -newkey rsa:4096 -keyout /tmp/illumina.key -out /tmp/illumina.crt -days 36500 -nodes -subj "/CN=localhost" > /dev/null 2>&1
openssl pkcs12 -export -out "$PFX_PATH" -inkey /tmp/illumina.key -in /tmp/illumina.crt -passout pass:"$PFX_PASS" > /dev/null 2>&1
cp /tmp/illumina.crt /usr/local/share/ca-certificates/illumina.crt
update-ca-certificates > /dev/null 2>&1
chown "$HUMAN_USER:$HUMAN_USER" "$PFX_PATH"; chmod 400 "$PFX_PATH"
# Chrome/Chromium ignore the system CA store on Linux - the certificate must
# also live in each runtime user's NSS database or every kiosk window warns.
import_nss_cert() {
    local U="$1"
    local U_HOME
    U_HOME=$(eval echo "~$U")
    [ -d "$U_HOME" ] || return 0
    sudo -u "$U" mkdir -p "$U_HOME/.pki/nssdb"
    if [ ! -f "$U_HOME/.pki/nssdb/cert9.db" ]; then
        sudo -u "$U" certutil -d sql:"$U_HOME/.pki/nssdb" -N --empty-password > /dev/null 2>&1 || true
    fi
    sudo -u "$U" certutil -d sql:"$U_HOME/.pki/nssdb" -A -t "C,," -n Illumina -i /tmp/illumina.crt > /dev/null 2>&1 || true
}
import_nss_cert "$HUMAN_USER"
[ "$INTERACTIVE_USER" != "$HUMAN_USER" ] && import_nss_cert "$INTERACTIVE_USER"
rm -f /tmp/illumina.key /tmp/illumina.crt
echo "  Certificate created, trusted system-wide and in Chrome, and ready for Kestrel."

# No CongregationView:BaseUrl stamping here anymore: the app auto-detects the
# physical LAN address at runtime (CongregationViewUrlService), so a DHCP
# reassignment can never strand the congregation QR on a stale IP. Settings ->
# Application Paths remains the pin-down override for dual-LAN machines.
# (Detection code removed - virtual adapters like docker0 can never win now.)

mkdir -p "$INSTALL_DIR/AppData"
[ -f "$OVERRIDES" ] || echo '{}' > "$OVERRIDES"
jq \
  --argjson right "$RIGHT_ON" --argjson sync "$SYNC_ON" \
  --arg plang "$PRIMARY_LANG" --arg slang "$SECONDARY_LANG" \
  --arg key "$KEY_JSON" --arg prayer "$PRAYER_ID" --arg ann "$ANN_ID" \
  --arg soffice "/usr/bin/soffice" --arg ffmpeg "/usr/bin/ffmpeg" \
  --arg pfx "$PFX_PATH" --arg pfxpass "$PFX_PASS" \
  '
    .Urls = "https://localhost;http://0.0.0.0:80"
    | .Kestrel = { Certificates: { Default: { Path: $pfx, Password: $pfxpass } } }
    | .Kiosk = ((.Kiosk // {}) + { BaseUrl: "https://localhost", Enabled: true,
                                   RightWallEnabled: $right })
    | .Localization = ((.Localization // {}) + { PrimaryLanguage: $plang, SelectedSecondaryLanguage: $slang })
    | .SlideLibrary = ((.SlideLibrary // {}) + {
        LibreOfficePath: $soffice,
        GoogleDrive: {
          ServiceAccountKeyPath: (if $sync then $key else "" end),
          PrayerFolderId: (if $sync then $prayer else "" end),
          AnnouncementsFolderId: (if $sync then $ann else "" end)
        } })
    | .Broadcast = ((.Broadcast // {}) + { FFmpegPath: $ffmpeg })
  ' "$OVERRIDES" > "$OVERRIDES.tmp" && mv "$OVERRIDES.tmp" "$OVERRIDES"
chown "$HUMAN_USER:$HUMAN_USER" "$OVERRIDES"
echo "  Dependency paths stamped: LibreOffice='/usr/bin/soffice' FFmpeg='/usr/bin/ffmpeg'"

# Launch check: boot the freshly installed engine EXACTLY as it will run in
# production - the runtime account, the install dir as working directory
# (ASP.NET Core's content root is the cwd), the real 80/443 bindings from the
# freshly stamped overrides + certificate. Success = the portal answers
# within 40s; a crash aborts the install with the log tail. On success the
# engine is LEFT RUNNING, so the install ends with a live portal.
# (A previous version tested a synthetic Development port via ASPNETCORE_URLS,
# which the minimal-hosting config precedence silently ignores - appsettings
# Urls wins over that env var - so it tested nothing real and died on the
# missing Linux dev cert. Testing the real thing is simpler AND truthful.)
echo "  Running a quick launch check to prove the engine starts cleanly..."
SMOKE_LOG=/tmp/illumina-launch-check.log
sudo -u "$HUMAN_USER" bash -c "cd '$INSTALL_DIR' && exec ./Illumina" > "$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
SMOKE_OK=false
for i in $(seq 1 40); do
    kill -0 "$SMOKE_PID" 2>/dev/null || break
    CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://127.0.0.1/" 2>/dev/null || true)
    case "$CODE" in 2*|3*) SMOKE_OK=true; break;; esac
    CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/" 2>/dev/null || true)
    case "$CODE" in 2*|3*) SMOKE_OK=true; break;; esac
    sleep 1
done
if [ "$SMOKE_OK" = true ]; then
    echo "  Launch check passed - the portal is already live at https://localhost."
else
    kill "$SMOKE_PID" 2>/dev/null || true
    pkill -f "$INSTALL_DIR/Illumina" 2>/dev/null || true
    echo "  ERROR: Illumina did not start correctly on this PC. The last log lines:"
    tail -n 15 "$SMOKE_LOG" 2>/dev/null | sed 's/^/    /'
    echo "  Full log: $SMOKE_LOG"
    exit 1
fi

# ----------------------------- [9/9] HELPERS, SHORTCUTS, NETWORK ------------
echo -e "\n==> [8/9] Writing the everyday shortcuts..."
CHROME_BIN_SAFE=${CHROME_BIN:-/usr/bin/google-chrome}

# The Backend Manager: Kills any existing backend, starts a fresh one hidden,
# and pops up a friendly native Linux message box (via zenity) telling the 
# volunteer that the engine is ready and they can now open the portal.
cat <<EOF > "$INSTALL_DIR/start-backend.sh"
#!/bin/bash
# Content root = current working directory for ASP.NET Core, so the app must
# be launched FROM its own folder - otherwise wwwroot/Data aren't found and
# the process crashes inside MediaLibraryService (observed on first Ubuntu
# install). cd to this script's home before anything else.
cd "\$(dirname "\$0")" || exit 1
APP="$INSTALL_DIR/Illumina"
pkill -f "\$APP" || true
sleep 1
nohup "\$APP" > /dev/null 2>&1 &

if [ "\$1" != "--silent" ]; then
    if command -v zenity > /dev/null 2>&1; then
        zenity --info --title="Illumina AVA PC" --text="The Illumina backend is now running in the background.\n\nPlease click the 'Illumina Portal' icon on the taskbar to open the control panel." --width=400 > /dev/null 2>&1 || true
    fi
fi
EOF
chmod +x "$INSTALL_DIR/start-backend.sh"

# Taskbar pinner: adds the portal to the GNOME dash (taskbar) favorites.
# GNOME favorites can only be changed from inside the user's own graphical
# session, so the installer drops a one-time autostart that pins the icon at
# the account's first login and then removes itself (an immediate pin is also
# attempted below when the account happens to be logged in already).
cat <<'EOF' > "$INSTALL_DIR/pin-taskbar.sh"
#!/bin/bash
APPS=$(gsettings get org.gnome.shell favorite-apps 2>/dev/null) || exit 0
case "$APPS" in
  *illumina-portal.desktop*) exit 0;;
esac
if [ "$APPS" = "@as []" ] || [ -z "$APPS" ]; then
    NEW="['illumina-portal.desktop']"
else
    NEW=$(echo "$APPS" | sed "s/]$/, 'illumina-portal.desktop']/")
fi
gsettings set org.gnome.shell favorite-apps "$NEW" 2>/dev/null || true
EOF
chmod +x "$INSTALL_DIR/pin-taskbar.sh"

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

# 1. The Portal Launcher lives in the system application menu so the taskbar
# (GNOME dash) can find and pin it - no desktop icon to double-click by
# mistake mid-service.
cat <<EOF > /usr/share/applications/illumina-portal.desktop
[Desktop Entry]
Type=Application
Name=Illumina Portal
Comment=Illumina operator control panel
Exec=$CHROME_BIN_SAFE --app=$PORTAL_URL
Icon=$INSTALL_DIR/wwwroot/icon-256.png
Terminal=false
Categories=Utility;
EOF
chmod 644 /usr/share/applications/illumina-portal.desktop

# Pin it to the taskbar right away when the account's session is available...
USER_UID=$(id -u "$HUMAN_USER")
if [ -S "/run/user/$USER_UID/bus" ]; then
    sudo -u "$HUMAN_USER" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_UID/bus" \
        bash "$INSTALL_DIR/pin-taskbar.sh" 2>/dev/null || true
fi
# ...and guarantee the pin at the account's next login (self-removing).
cat <<EOF > "$AUTOSTART_DIR/illumina-pin-taskbar.desktop"
[Desktop Entry]
Type=Application
Name=Pin Illumina Portal to Taskbar
Exec=bash -c "$INSTALL_DIR/pin-taskbar.sh; rm -f \"\$HOME/.config/autostart/illumina-pin-taskbar.desktop\""
Terminal=false
EOF
chown "$HUMAN_USER:$HUMAN_USER" "$AUTOSTART_DIR/illumina-pin-taskbar.desktop"

# 2. The Backend Restart Shortcut (Shows the friendly zenity pop-up). The
# cautionary name keeps volunteers from clicking it casually - it is the
# recovery path only, never the everyday launch.
create_desktop_file "$DESKTOP_DIR/restart-illumina.desktop" "Restart Illumina (only if frozen)" "$INSTALL_DIR/start-backend.sh"

# 3. The Auto-Start Shortcut (Runs silently on every login - auto SIGN-IN only
# controls whether a password is needed, never whether the backend starts)
create_desktop_file "$AUTOSTART_DIR/illumina-backend.desktop" "Illumina Backend" "$INSTALL_DIR/start-backend.sh --silent"
echo "  'Illumina Portal' is pinned to the taskbar for $HUMAN_USER; the emergency restart stays on the desktop, clearly marked."

echo -e "\n==> [9/9] Opening the network doors and keeping the PC awake..."
# The portal binds HTTPS to localhost only, so no inbound 443 rule is needed
# (delete any legacy one); port 80 serves congregation phones and tablets.
if command -v ufw &> /dev/null; then
    ufw delete allow 443/tcp > /dev/null 2>&1 || true
    ufw allow 80/tcp > /dev/null
fi
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1 || true
sudo -u "$HUMAN_USER" gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' > /dev/null 2>&1 || true
echo "  Firewall allows congregation phones (port 80); the portal stays localhost-only. Sleep is disabled."

echo ""
echo "=================================================="
echo "   Setup complete - Illumina $TAG_NAME is ready!"
echo "=================================================="
echo "   AVA PC Account: $HUMAN_USER"
echo "   Auto sign-in  : $([ "$AUTO_LOGIN_ON" = true ] && echo 'configured' || echo 'off - normal logon screen')"
echo "   Right Display : $RIGHT_ON   Drive sync: $SYNC_ON"
echo "   Languages     : ${LANG_NAMES[$PRIMARY_IDX]} (primary) + ${LANG_NAMES[$SECONDARY_IDX]} (secondary)"
echo ""
echo "  When you are ready for more, Menu->Settings grows with you:"
echo "   - Displays       : CG overlay, Broadcast Encoder, confidence monitors"
echo "   - Device Setup   : Tapo smart plugs (power schedules), Novastar brightness"
echo "   - Appearance     : languages, hymn layouts, display fonts, themes"
echo "   - Check for Updates : one-tap software and hymn/Bible library updates"
echo ""
echo "  Congratulations! You are all set! Here is how to start your first session:"
echo ""
echo "   1. The engine is ALREADY RUNNING (the launch check started it), and"
echo "      from the next boot on it will start itself automatically."
echo ""
echo "   2. Click the 'Illumina Portal' icon on the taskbar."
echo "      The control panel will open, and your displays will wake up!"
echo ""
echo "  From now on, the backend starts automatically every time the PC"
echo "  boots. You only ever need to click the 'Illumina Portal' icon."
echo ""
if [ "$USE_AVA_USER" = true ]; then
    echo "  Maintenance note: '$HUMAN_USER' has no administrator rights by design"
    echo "  (that is what makes the kiosk safe). To re-run this installer or do"
    echo "  system maintenance later, sign in as $INTERACTIVE_USER instead."
    echo ""
fi
if [ "$AUTO_LOGIN_ON" = true ]; then
    read -p "  Would you like to restart now to finish setup? [y/N] (ENTER = No): " ANS
    if [[ "$ANS" =~ ^[yY]$ ]]; then reboot; fi
fi
