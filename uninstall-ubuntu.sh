#!/bin/bash
# ==============================================================================
# Illumina AVA PC Uninstaller - Ubuntu (v8.0)
# Companion to install-ubuntu.sh. Preserves content folders by default,
# removes the machine store and certificate, restores sleep behavior.
# Never touches Home Assistant, Docker, Chrome, LibreOffice or FFmpeg.
# For 99% of problems, RE-RUNNING THE INSTALLER is the correct recovery path.
# ==============================================================================
set -e
if [ "$EUID" -ne 0 ]; then echo "  Please re-run with sudo."; exit 1; fi

INSTALL_DIR="/opt/illumina"
MACHINE_DIR="/var/lib/illumina"

echo "=================================================="
echo "   Illumina Uninstaller - Ubuntu                  "
echo "=================================================="
read -p "This removes Illumina from this PC. Continue? [y/N] (ENTER = No): " ANS
[[ "$ANS" =~ ^[yY]$ ]] || { echo "  Nothing was changed."; exit 0; }
read -p "Preserve the content folders (slides/media) as a backup first? [Y/n] (ENTER = Yes): " KEEP
KEEP_DATA=true; [[ "$KEEP" =~ ^[nN]$ ]] && KEEP_DATA=false

echo -e "\n==> Pausing Illumina..."
pkill -f "$INSTALL_DIR/Illumina" || true
pkill -f "IlluminaKiosk" || true
sleep 2

if [ "$KEEP_DATA" = true ] && [ -d "$INSTALL_DIR/Data" ]; then
    DEST="/var/backups/illumina-data"
    [ -e "$DEST" ] && DEST="/var/backups/illumina-data-$(date +%Y%m%d-%H%M%S)"
    mkdir -p /var/backups
    mv "$INSTALL_DIR/Data" "$DEST"
    echo "  Content folders preserved at $DEST"
fi

echo -e "\n==> Removing shortcuts..."
for HOME_DIR in /home/* /root; do
    [ -d "$HOME_DIR" ] || continue
    rm -f "$HOME_DIR/Desktop/illumina.desktop" "$HOME_DIR/Desktop/restart-illumina.desktop" \
          "$HOME_DIR/.config/autostart/illumina.desktop" 2>/dev/null || true
done

echo -e "\n==> Removing firewall rules..."
if command -v ufw > /dev/null 2>&1; then
    ufw delete allow 443/tcp > /dev/null 2>&1 || true
    ufw delete allow 80/tcp  > /dev/null 2>&1 || true
fi

GDM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CONF" ] && grep -q "^AutomaticLogin=avauser" "$GDM_CONF"; then
    read -p "Auto sign-in is enabled for 'avauser'. Disable it? [y/N] (ENTER = No): " DIS
    if [[ "$DIS" =~ ^[yY]$ ]]; then
        sed -i "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/" "$GDM_CONF"
        sed -i "/^AutomaticLogin=avauser/d" "$GDM_CONF"
        echo "  Auto sign-in disabled."
    fi
fi

echo -e "\n==> Removing the machine certificate..."
if [ -f /usr/local/share/ca-certificates/illumina.crt ]; then
    rm -f /usr/local/share/ca-certificates/illumina.crt
    update-ca-certificates > /dev/null 2>&1 || true
fi

echo -e "\n==> Removing program files and machine store..."
rm -rf "$INSTALL_DIR" "$MACHINE_DIR"

if id "avauser" &>/dev/null; then
    read -p "Also remove the 'avauser' kiosk account and its profile? [y/N] (ENTER = No): " RM
    if [[ "$RM" =~ ^[yY]$ ]]; then
        userdel -r avauser 2>/dev/null || userdel avauser || true
        echo "  Kiosk account removed."
    fi
fi

systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1 || true

echo ""
echo "  Illumina has been removed from this PC."
echo "  Home Assistant, Docker, Chrome, LibreOffice and FFmpeg were left in"
echo "  place - they are general-purpose software you may want to keep."
