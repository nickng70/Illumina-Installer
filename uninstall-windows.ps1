<#
    Illumina AVA PC Uninstaller - Windows (v8.0)
    Companion to install-windows.ps1, for decommissioning a PC or repairing
    a corrupted install. Preserves your content folders by default, removes
    the machine store (token, Drive key, certificate), and never touches
    personal Chrome or companion tools (LibreOffice/FFmpeg/Chrome stay).
    For 99% of problems, RE-RUNNING THE INSTALLER is the correct recovery
    path - uninstall only when you truly mean it.
#>
$ErrorActionPreference = "Stop"
function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "  Please re-run this script from an elevated PowerShell (right-click > Run as administrator)." -ForegroundColor Yellow
    exit 1
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina Uninstaller - Windows                 " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
$InstallDir = "C:\Program Files\Illumina"
$MachineDir = "C:\ProgramData\Illumina"

$ans = Read-Host "This removes Illumina from this PC. Continue? [y/N] (ENTER = No)"
if ($ans -notmatch '^[yY]') { Write-Host "  Nothing was changed."; exit 0 }

$keep = Read-Host "Preserve the content folders (slides/media) as a backup first? [Y/n] (ENTER = Yes)"
$keepData = ($keep -notmatch '^[nN]')

Log "Pausing Illumina..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

if ($keepData -and (Test-Path "$InstallDir\Data")) {
    $dest = "C:\Illumina-Data-Backup"
    if (Test-Path $dest) { $dest = "C:\Illumina-Data-Backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    Move-Item "$InstallDir\Data" $dest -Force
    Log "Content folders preserved at $dest"
}

Log "Removing shortcuts..."
$spots = @(
    [Environment]::GetFolderPath("CommonDesktopDirectory"),
    [Environment]::GetFolderPath("CommonStartup"),
    [Environment]::GetFolderPath("Desktop"),
    [Environment]::GetFolderPath("Startup"),
    "C:\Users\avauser\Desktop",
    "C:\Users\avauser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
)
foreach ($spot in $spots) {
    if (Test-Path $spot) {
        Get-ChildItem $spot -Filter "Illumina*.lnk"         -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $spot -Filter "Restart Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

Log "Removing firewall rules..."
Remove-NetFirewallRule -DisplayName "Illumina Web App"      -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina Phones HTTP" -ErrorAction SilentlyContinue

$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$wl = Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue
if ($wl.AutoAdminLogon -eq "1") {
    $dis = Read-Host "Auto sign-in is currently enabled for '$($wl.DefaultUserName)'. Disable it? [y/N] (ENTER = No)"
    if ($dis -match '^[yY]') {
        Set-ItemProperty $Winlogon "AutoAdminLogon" "0" -Type String
        Set-ItemProperty $Winlogon "DefaultPassword" "" -Type String
        Log "Auto sign-in disabled."
    }
}

Log "Removing the machine certificate..."
Get-ChildItem Cert:\LocalMachine\My, Cert:\LocalMachine\Root -ErrorAction SilentlyContinue |
    Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" } | Remove-Item -Force -ErrorAction SilentlyContinue

Log "Removing program files and machine store..."
Remove-Item $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $MachineDir -Recurse -Force -ErrorAction SilentlyContinue

if (Get-LocalUser -Name "avauser" -ErrorAction SilentlyContinue) {
    $rm = Read-Host "Also remove the 'avauser' kiosk account and its profile? [y/N] (ENTER = No)"
    if ($rm -match '^[yY]') {
        Remove-LocalUser -Name "avauser" -ErrorAction SilentlyContinue
        Remove-Item "C:\Users\avauser" -Recurse -Force -ErrorAction SilentlyContinue
        Log "Kiosk account removed."
    }
}

Write-Host ""
Write-Host "  Illumina has been removed from this PC." -ForegroundColor Green
Write-Host "  Companion tools (Chrome, LibreOffice, FFmpeg) were left in place - they"
Write-Host "  are general-purpose software you may want to keep. Power settings remain"
Write-Host "  as configured; adjust them in Windows Settings if desired."
