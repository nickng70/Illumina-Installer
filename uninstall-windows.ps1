<#
    Illumina AVA PC Uninstaller - Windows 10/11 (v8.0 FINAL)
    Safely removes Illumina, its shortcuts, firewall rules, and local HTTPS certificate.
    Preserves the 'avauser' account and optionally preserves machine settings.
#>
$ErrorActionPreference = "Stop"

$InstallDir  = "C:\Program Files\Illumina"
$MachineDir  = "C:\ProgramData\Illumina"

# ---------------- Administrator check ---------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  Illumina uninstaller needs administrator rights to remove program files" -ForegroundColor Yellow
    Write-Host "  and firewall rules. Please close this window, open PowerShell again with" -ForegroundColor Yellow
    Write-Host "  right-click > 'Run as administrator', and paste the same command." -ForegroundColor Yellow
    exit 1
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina AVA PC Uninstaller                    " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Stop Processes
Write-Host "==> Stopping Illumina processes..." -ForegroundColor Green
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' -or $_.CommandLine -like '*Illumina Portal*' -or $_.CommandLine -like '*https://localhost*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2

# 2. Remove Shortcuts (Cleans up v8.0 FINAL and legacy shortcuts)
Write-Host "==> Removing shortcuts..." -ForegroundColor Green
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
        # v8.0 FINAL shortcuts
        Remove-Item "$spot\Illumina Portal.lnk" -Force -ErrorAction SilentlyContinue
        Remove-Item "$spot\Restart Illumina Backend.lnk" -Force -ErrorAction SilentlyContinue
        Remove-Item "$spot\Illumina Backend AutoStart.lnk" -Force -ErrorAction SilentlyContinue
        # Legacy shortcuts cleanup
        Get-ChildItem $spot -Filter "Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $spot -Filter "Restart Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

# 3. Remove Firewall Rules
Write-Host "==> Removing firewall rules..." -ForegroundColor Green
Remove-NetFirewallRule -DisplayName "Illumina Web App" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina Phones HTTP" -ErrorAction SilentlyContinue

# 4. Remove Certificates (Cleans up v8.0 and legacy "Kiosk" certs)
Write-Host "==> Removing HTTPS certificates..." -ForegroundColor Green
Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue | 
    Where-Object { $_.FriendlyName -match "Illumina (Kiosk|AVA PC) HTTPS" } | 
    Remove-Item -Force
Get-ChildItem Cert:\LocalMachine\Root -ErrorAction SilentlyContinue | 
    Where-Object { $_.FriendlyName -match "Illumina (Kiosk|AVA PC) HTTPS" } | 
    Remove-Item -Force

# 5. Restore Normal Logon (Disable Auto-Login)
Write-Host "==> Restoring normal Windows logon screen..." -ForegroundColor Green
$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $Winlogon "AutoAdminLogon" "0" -Type String -ErrorAction SilentlyContinue
Set-ItemProperty $Winlogon "DefaultPassword" "" -Type String -ErrorAction SilentlyContinue

# 6. Remove Files
Write-Host "==> Removing application files..." -ForegroundColor Green
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }

$keepMachineDir = Read-Host "  Keep machine settings (GitHub token, Google Drive keys, display overrides) for future installs? [Y/n] (ENTER = Yes)"
if ($keepMachineDir -match '^[nN]') {
    if (Test-Path $MachineDir) { Remove-Item $MachineDir -Recurse -Force }
    Write-Host "  Machine settings removed." -ForegroundColor Yellow
} else {
    Write-Host "  Machine settings preserved in $MachineDir." -ForegroundColor Cyan
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Green
Write-Host "   Uninstall complete!                            " -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Green
Write-Host "  Note: The dedicated 'avauser' account was left intact."
Write-Host "  You can safely delete it from Windows Settings > Accounts if needed."
