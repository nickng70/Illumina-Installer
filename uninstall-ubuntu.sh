#!/bin/bash
# ==============================================================================
# Illumina AVA PC Uninstaller - Ubuntu 22.04/24.04 LTS (v8.0 FINAL)
# Safely removes Illumina, its shortcuts, firewall rules, and local HTTPS cert.
# ==============================================================================
set -e

INSTALL_DIR="/opt/illumina"
MACHINE_DIR="/var/lib/illumina"

if [ "$EUID" -ne 0 ]; then
  echo "  Illumina uninstaller needs administrator (sudo) rights to remove program"
  echo "  files and firewall rules. Please run: sudo ./uninstall-ubuntu.sh"
  exit 1
fi

INTERACTIVE_USER=$(logname 2>/dev/null || echo "$SUDO_USER")
USER_HOME=$(eval echo "~$INTERACTIVE_USER")

echo "=================================================="
echo "   Illumina AVA PC Uninstaller                    "
echo "=================================================="
echo ""

# 1. Stop processes
echo -e "\n==> Stopping Illumina processes..."
pkill -f "$INSTALL_DIR/Illumina" || true
pkill -f "IlluminaKiosk" || true
pkill -f "https://localhost" || true
sleep 2

# 2. Remove shortcuts (Cleans up v8.0 FINAL and legacy shortcuts)
echo -e "\n==> Removing shortcuts..."
DESKTOP_DIR="$USER_HOME/Desktop"
AUTOSTART_DIR="$USER_HOME/.config/autostart"

rm -f "$DESKTOP_DIR"/illumina*.desktop 2>/dev/null || true
rm -f "$DESKTOP_DIR"/restart*.desktop 2>/dev/null || true
rm -f "$AUTOSTART_DIR"/illumina*.desktop 2>/dev/null || true
# Also clean up avauser's desktop just in case
rm -f /home/avauser/Desktop/illumina*.desktop 2>/dev/null || true
rm -f /home/avauser/.config/autostart/illumina*.desktop 2>/dev/null || true

# 3. Remove Firewall rules
echo -e "\n==> Removing firewall rules..."
if command -v ufw &> /dev/null; then
    ufw delete allow 443/tcp > /dev/null 2>&1 || true
    ufw delete allow 80/tcp > /dev/null 2>&1 || true
fi

# 4. Remove Certificates
echo -e "\n==> Removing HTTPS certificates..."
rm -f /usr/local/share/ca-certificates/illumina.crt
update-ca-certificates > /dev/null 2>&1 || true

# 5. Restore Normal Logon (Disable Auto-Login)
echo -e "\n==> Restoring normal logon screen..."
GDM_CONF="/etc/gdm3/custom.conf"
if [ -f "$GDM_CONF" ]; then
    sed -i "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/" "$GDM_CONF" || true
    sed -i "/^AutomaticLogin=/d" "$GDM_CONF" || true
fi

# 6. Unmask sleep
echo -e "\n==> Restoring sleep settings..."
systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target > /dev/null 2>&1 || true

# 7. Remove Files
echo -e "\n==> Removing application files..."
rm -rf "$INSTALL_DIR"

read -p "  Keep machine settings (GitHub token, Google Drive keys, display overrides) for future installs? [Y/n] (ENTER = Yes): " KEEP_MACHINE
if [[ "$KEEP_MACHINE" =~ ^[nN]$ ]]; then
    rm -rf "$MACHINE_DIR"
    echo "  Machine settings removed."
else
    echo "  Machine settings preserved in $MACHINE_DIR."
fi

echo ""
echo "=================================================="
echo "   Uninstall complete!                            "
echo "=================================================="
echo "  Note: The dedicated 'avauser' account was left intact."
echo "  You can safely delete it via 'sudo userdel -r avauser' if needed."
