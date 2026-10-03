#Requires -RunAsAdministrator
<#
  Illumina AVA PC Installer - Windows 10/11
  Hosted PUBLICLY in nickng70/Illumina-Installer (contains NO secrets).
  Downloads the self-contained app from the PRIVATE nickng70/Illumina-Releases
  repo using a read-only token entered at runtime.
  Run from an ELEVATED PowerShell:  .\install-windows.ps1
#>
$ErrorActionPreference = "Stop"

# ----------------------------- CONFIG ---------------------------------------
$GitHubOwner = "nickng70"
$GitHubRepo  = "Illumina-Releases"     # PRIVATE repo holding release assets
$AssetName   = "illumina-win-x64.zip"
$InstallDir  = "C:\Program Files\Illumina"
$HumanUser   = "avauser"               # kiosk/operator account (auto sign-in)
$HttpPort    = "5152"
$TokenFile   = "C:\ProgramData\Illumina\github-token"
# ----------------------------------------------------------------------------

function Log($msg) { Write-Host "`n==> $msg" -ForegroundColor Green }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina AVA PC Installer (Windows)            " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------- GitHub token (stored admin-only for future updates) -------
Log "[1/8] GitHub token..."
New-Item -ItemType Directory -Path "C:\ProgramData\Illumina" -Force | Out-Null
if ($env:GITHUB_TOKEN) {
    $Token = $env:GITHUB_TOKEN
} elseif (Test-Path $TokenFile) {
    $Token = Get-Content $TokenFile -Raw
    Log "Reusing stored GitHub token."
} else {
    $Token = Read-Host "Enter GitHub read-only token for $GitHubRepo"
    if (-not $Token) { throw "No token provided." }
    Set-Content -Path $TokenFile -Value $Token
    icacls $TokenFile /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
}
$ApiHeaders = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }

# ---------------- Locate latest release asset -------------------------------
Log "[2/8] Locating latest release in $GitHubOwner/$GitHubRepo..."
try {
    $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/latest" -Headers $ApiHeaders
} catch {
    throw "GitHub API call failed - check the token has Contents:Read on $GitHubRepo."
}
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if (-not $Asset) { throw "Asset '$AssetName' not found in latest release ($($Release.tag_name))." }

Log "Downloading $AssetName ($($Release.tag_name))..."
$ZipPath = Join-Path $env:TEMP $AssetName
Invoke-WebRequest -Uri $Asset.url -Headers @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream" } -OutFile $ZipPath

# ---------------- Human kiosk account: avauser ------------------------------
Log "[3/8] Configuring kiosk account '$HumanUser'..."
$PlainPass = Read-Host "Set/refresh the SECRET admin password for $HumanUser"
if (-not $PlainPass) { throw "Password cannot be empty (admin elevation depends on it)." }
$SecPass = ConvertTo-SecureString $PlainPass -AsPlainText -Force

if (-not (Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $SecPass -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name $HumanUser -Password $SecPass -PasswordNeverExpires $true
}
if (-not ((Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue).Name -like "*\$HumanUser")) {
    Add-LocalGroupMember -Group "Administrators" -Member $HumanUser
}

# Automatic sign-in (boots straight to desktop, no password prompt)
$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $Winlogon -Name "AutoAdminLogon"    -Value "1"              -Type String
Set-ItemProperty -Path $Winlogon -Name "DefaultUserName"   -Value $HumanUser       -Type String
Set-ItemProperty -Path $Winlogon -Name "DefaultPassword"   -Value $PlainPass       -Type String
Set-ItemProperty -Path $Winlogon -Name "DefaultDomainName" -Value $env:COMPUTERNAME -Type String

# ---------------- Install app files (preserve Data) -------------------------
Log "[4/8] Installing app to $InstallDir..."
$DataBackup = $null
if (Test-Path "$InstallDir\Data") {
    $DataBackup = Join-Path $env:TEMP "illumina-data-backup"
    Move-Item "$InstallDir\Data" $DataBackup -Force
}
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item $ZipPath -Force
if ($DataBackup) {
    if (Test-Path "$InstallDir\Data") { Remove-Item "$InstallDir\Data" -Recurse -Force }
    Move-Item $DataBackup "$InstallDir\Data" -Force
}
New-Item -ItemType Directory -Path "$InstallDir\Data" -Force | Out-Null

# Data lockdown: only SYSTEM + Administrators (the app runs interactively as
# avauser, who IS an admin - on Windows this is the 'inconvenience' level).
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null

Set-Content -Path "C:\ProgramData\Illumina\current-version" -Value $Release.tag_name

# ---------------- Auto-start at logon ---------------------------------------
Log "[5/8] Creating auto-start and shortcuts..."
$Wsh = New-Object -ComObject WScript.Shell

$Startup = [Environment]::GetFolderPath("CommonStartup")
$lnk = $Wsh.CreateShortcut("$Startup\Illumina.lnk")
$lnk.TargetPath = "$InstallDir\Illumina.exe"
$lnk.WorkingDirectory = $InstallDir
$lnk.Save()

# Restart helper (no elevation needed - avauser owns its own process)
$RestartPs1 = "$InstallDir\restart-illumina.ps1"
@'
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process "C:\Program Files\Illumina\Illumina.exe" -WorkingDirectory "C:\Program Files\Illumina" -WindowStyle Hidden
Start-Sleep -Seconds 3
Start-Process "http://localhost:5152"
'@ | Set-Content -Path $RestartPs1

$Desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
$r = $Wsh.CreateShortcut("$Desktop\Restart Illumina.lnk")
$r.TargetPath = "powershell.exe"
$r.Arguments  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$RestartPs1`""
$r.IconLocation = "shell32.dll,238"
$r.Save()

$p = $Wsh.CreateShortcut("$Desktop\Illumina Portal.lnk")
$p.TargetPath = "http://localhost:$HttpPort"
$p.Save()

# ---------------- Firewall + power ------------------------------------------
Log "[6/8] Configuring firewall and power..."
New-NetFirewallRule -DisplayName "Illumina Web App" -Direction Inbound -LocalPort $HttpPort -Protocol TCP -Action Allow -ErrorAction SilentlyContinue | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null

# ---------------- First launch ----------------------------------------------
Log "[7/8] Starting Illumina for the first time..."
Start-Process "$InstallDir\Illumina.exe" -WorkingDirectory $InstallDir -WindowStyle Hidden

Log "[8/8] Done!"
Write-Host @"

==================================================
   Installation complete! ($($Release.tag_name))
   Portal:   http://localhost:$HttpPort
   Kiosk:    auto sign-in as $HumanUser
   Admin:    Run as administrator (secret password)
==================================================
"@ -ForegroundColor Cyan
$ans = Read-Host "Reboot now to apply auto sign-in? [Y/n]"
if ($ans -notmatch '^[nN]') { Restart-Computer }