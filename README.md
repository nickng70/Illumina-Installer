# Illumina AVA PC Deployment Guide

Welcome to the automated deployment system for **Illumina**, the audio-visual kiosk application designed for church services.

This guide will walk you through transforming a standard PC into a dedicated, self-healing Illumina station in just a few minutes. Please select your operating system below.

---

## 🪟 Option A: Windows 10 / 11 Installation

### Before You Begin
* A PC running Windows 10 or 11.
* Google Chrome installed.
* Administrator access to the PC.
* Your GitHub Read-Only Token (provided by your IT administrator).
* *Note: Ensure IIS or other web servers are not actively using port 443.*

### Step 1: Open PowerShell as Administrator
* Right-click the **Start Button** (Windows icon).
* Select **Terminal (Admin)** or **Windows PowerShell (Admin)**.
* Click **Yes** if asked for permission.

### Step 2: Run the Installer
* Copy the command below.
* Right-click inside the PowerShell window to paste it.
* Press **Enter**.

```powershell
irm https://raw.githubusercontent.com/nickng70/Illumina-Installer/main/install-windows.ps1 -OutFile "$env:TEMP\install-windows.ps1"; Unblock-File "$env:TEMP\install-windows.ps1"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\install-windows.ps1"
```

### Step 3: Follow the Prompts
* **GitHub Token:** Paste your token (you won't see characters as you type — just paste and press Enter).
* **Admin Password:** Create a strong password for the new `avauser` kiosk account. **Write this down.** You will need it for future maintenance.

### Step 4: Reboot
* When asked to reboot, type `Y` and press **Enter**.
* The PC will restart and automatically log into the new Illumina kiosk interface.

---

## 🐧 Option B: Ubuntu Desktop Installation

### Before You Begin
* A PC running Ubuntu Desktop (22.04, 24.04, or 26.04 LTS recommended).
* An active internet connection.
* The administrator (sudo) password for the PC.
* Your GitHub Read-Only Token (provided by your IT administrator).

### Step 1: Open the Terminal
* Press **Ctrl + Alt + T** on your keyboard.
* A terminal window will appear on your screen.

### Step 2: Run the Installer
* Copy the command below.
* **Right-click** inside the terminal window and select **Paste** (*Note: Ctrl+V usually does not work in Linux terminals*).
* Press **Enter**.

```bash
curl -sSL https://raw.githubusercontent.com/nickng70/Illumina-Installer/main/install-ubuntu.sh -o /tmp/install-ubuntu.sh && sudo bash /tmp/install-ubuntu.sh
```

### Step 3: Follow the Prompts
* **Sudo Password:** It will first ask for your current PC admin password to begin the installation.
* **GitHub Token:** Paste your token when prompted.
* **Kiosk Password:** You will be asked to set a secret password for the `avauser` kiosk account. **Write this down.**
* *Note: When typing passwords in the Linux terminal, the screen will remain completely blank (no asterisks will appear). This is normal Linux security behaviour — just type the password blindly and press Enter.*

### Step 4: Reboot
* When the installation finishes, it will ask if you want to reboot. Type `Y` and press **Enter**.
* The PC will restart and automatically log into the new Illumina kiosk interface.

---

## 🖥️ Daily Operation (For AV Volunteers)

Once installed, the PC is designed to be as stress-free as possible during services.

### Powering On
Simply press the power button on the PC.
* The PC will boot up and **automatically log in** to the Illumina interface.
* No passwords are required to start the system.
* The Illumina portal and display walls will launch automatically.

### The Two Desktop Icons
If the portal browser window is accidentally closed, or the system freezes, look for these two icons on the desktop:

| Icon Name | When to use it | What it does |
| :--- | :--- | :--- |
| **Illumina** | **Everyday Use.** Click this if the browser was closed. | Safely checks if the app is running and reopens the portal. **It will never interrupt a live broadcast.** |
| **Restart Illumina (if misbehaving)** | **Emergency Only.** Click this only if the screens are frozen or glitching. | Force-closes everything and starts fresh. **Warning:** This *will* cut a live broadcast stream if one is currently running. |

---

## 🔄 Updating the Software

When your IT team releases a new version of Illumina, you do not need to uninstall anything.

Simply run the **exact same installation command** (from Step 2 above) for your operating system. The installer is smart: it will safely preserve your church's Bible and Hymn data, download the newest software, and seamlessly apply the update.

---

## 🛡️ Security & Data Protection

* **Automatic Lockdown:** The system automatically protects your church's proprietary data (Bible translations, Hymn lyrics) so it cannot be easily copied by unauthorised users.
* **Source Code Protection:** The installer only downloads the compiled, ready-to-run application. The source code is never exposed to the PC.
