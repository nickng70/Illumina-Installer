#Requires -RunAsAdministrator
<#
    Illumina AVA PC Installer - Windows 10/11 (v3 - HTTPS/443)
    Public host : nickng70/Illumina-Installer
    Private src : nickng70/Illumina-Releases
#>
$ErrorActionPreference = "Stop"

# ----------------------------- CONFIG ---------------------------------------
$GitHubOwner = "nickng70"
$GitHubRepo  = "Illumina-Releases"
$AssetName   = "illumina-win-x64.zip"
$InstallDir  = "C:\Program Files\Illumina"
$HumanUser   = "avauser"
$HttpPort    = "443"
$PortalUrl   = "https://localhost"
$TokenFile   = "C:\ProgramData\Illumina\github-token"
$LogonDelaySeconds     = 12
$AutoOpenPortalAtLogon = $true
# ----------------------------------------------------------------------------

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina AVA PC Installer (Windows) v3         " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------- [1/9] GitHub token ----------------------------------------
Log "[1/9] GitHub token..."
New-Item -ItemType Directory -Path "C:\ProgramData\Illumina" -Force | Out-Null
if ($env:GITHUB_TOKEN) { $Token = $env:GITHUB_TOKEN }
elseif (Test-Path $TokenFile) { $Token = (Get-Content $TokenFile -Raw).Trim(); Log "Reusing stored token." }
else {
    $Token = Read-Host "Enter GitHub read-only token for $GitHubRepo"
    if (-not $Token) { throw "No token provided." }
    Set-Content -Path $TokenFile -Value $Token
    icacls $TokenFile /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
}
$Api = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }

# ---------------- [2/9] Latest release asset --------------------------------
Log "[2/9] Locating latest release..."
try { $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/latest" -Headers $Api }
catch { throw "GitHub API failed. $_" }
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if (-not $Asset) { throw "Asset '$AssetName' not found in release $($Release.tag_name)." }
$Zip = Join-Path $env:TEMP $AssetName
Log "Downloading $AssetName..."
Invoke-WebRequest -Uri $Asset.url -Headers @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream" } -OutFile $Zip

# ---------------- [3/9] Stop running instances ------------------------------
Log "[3/9] Stopping running Illumina/Chrome..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ---------------- [4/9] avauser + auto sign-in ------------------------------
Log "[4/9] Configuring kiosk account '$HumanUser'..."
$PlainPass = Read-Host "Set/refresh the SECRET admin password for $HumanUser"
if (-not $PlainPass) { throw "Password cannot be empty." }
$Sec = ConvertTo-SecureString $PlainPass -AsPlainText -Force
if (-not (Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue)) {
    New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $Sec -PasswordNeverExpires | Out-Null
} else {
    Set-LocalUser -Name $HumanUser -Password $Sec -PasswordNeverExpires $true
}
$admins = (Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue).Name
if ($admins -notlike "*\$HumanUser") { Add-LocalGroupMember -Group "Administrators" -Member $HumanUser }
$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty $Winlogon "AutoAdminLogon"    "1"               -Type String
Set-ItemProperty $Winlogon "DefaultUserName"   $HumanUser        -Type String
Set-ItemProperty $Winlogon "DefaultPassword"   $PlainPass        -Type String
Set-ItemProperty $Winlogon "DefaultDomainName" $env:COMPUTERNAME -Type String

# ---------------- [5/9] App files (preserve Data) ---------------------------
Log "[5/9] Installing app to $InstallDir..."
$Backup = $null
if (Test-Path "$InstallDir\Data") { $Backup = Join-Path $env:TEMP "illumina-data-backup"; Move-Item "$InstallDir\Data" $Backup -Force }
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Expand-Archive -Path $Zip -DestinationPath $InstallDir -Force
Remove-Item $Zip -Force
if ($Backup) {
    if (Test-Path "$InstallDir\Data") { Remove-Item "$InstallDir\Data" -Recurse -Force }
    Move-Item $Backup "$InstallDir\Data" -Force
}
New-Item -ItemType Directory -Path "$InstallDir\Data" -Force | Out-Null
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" | Out-Null
Set-Content "C:\ProgramData\Illumina\current-version" $Release.tag_name

# ---------------- Chrome resolution -----------------------------------------
function Resolve-Chrome {
    foreach ($c in @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if (Test-Path $c) { return $c } }
    $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue
    if ($ap -and $ap.'(default)' -and (Test-Path $ap.'(default)')) { return $ap.'(default)' }
    return $null
}
$ChromeExe = Resolve-Chrome
if (-not $ChromeExe) { Write-Warning "Chrome not found - portal links fall back to default browser." }
# IMPORTANT: Since we are using HTTPS with a self-signed dev cert, we add --ignore-certificate-errors 
# so Chrome doesn't block the kiosk windows with a privacy warning.
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '$PortalUrl', '--ignore-certificate-errors'" } else { "Start-Process '$PortalUrl'" }

# ---------------- [6/9] Helper scripts (with HTTPS env var) -----------------
Log "[6/9] Writing helper scripts..."
$AppExe = "$InstallDir\Illumina.exe"

# We inject ASPNETCORE_URLS here so the app binds to HTTPS on port 443 automatically
$EnvUrls = "https://0.0.0.0:$HttpPort"

$open = @'
param([int]$DelaySeconds = 0, [switch]$NoPortal)
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
$env:ASPNETCORE_URLS = "__ENV_URLS__"
$app = "__APP__"
if (-not (Get-Process -Name Illumina -ErrorAction SilentlyContinue)) {
    Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
    Start-Sleep -Seconds 4
}
if (-not $NoPortal) { __PORTAL__ }
'@
$open = $open -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine -replace '__ENV_URLS__', $EnvUrls
Set-Content "$InstallDir\open-illumina.ps1" $open

$restart = @'
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force "$env:TEMP\IlluminaKiosk" -ErrorAction SilentlyContinue
$env:ASPNETCORE_URLS = "__ENV_URLS__"
$app = "__APP__"
Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
Start-Sleep -Seconds 4
__PORTAL__
'@
$restart = $restart -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine -replace '__ENV_URLS__', $EnvUrls
Set-Content "$InstallDir\restart-illumina.ps1" $restart

# ---------------- [7/9] Shortcuts -------------------------------------------
Log "[7/9] Creating desktop icons and logon autostart..."
$Wsh     = New-Object -ComObject WScript.Shell
$Startup = [Environment]::GetFolderPath("CommonStartup")
$Desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
Get-ChildItem $Startup -Filter "Illumina*.lnk"        -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $Desktop -Filter "Illumina*.lnk"        -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $Desktop -Filter "Restart Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$s = $Wsh.CreateShortcut("$Desktop\Illumina.lnk")
$s.TargetPath   = $PsExe
$s.Arguments    = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\open-illumina.ps1`""
$s.IconLocation = $(if ($ChromeExe) { "$ChromeExe,0" } else { "shell32.dll,14" })
$s.Save()

$r = $Wsh.CreateShortcut("$Desktop\Restart Illumina (if misbehaving).lnk")
$r.TargetPath   = $PsExe
$r.Arguments    = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\restart-illumina.ps1`""
$r.IconLocation = "shell32.dll,238"
$r.Save()

$a = $Wsh.CreateShortcut("$Startup\Illumina Startup.lnk")
$a.TargetPath = $PsExe
$a.Arguments  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\open-illumina.ps1`" -DelaySeconds $LogonDelaySeconds" + $(if ($AutoOpenPortalAtLogon) { "" } else { " -NoPortal" })
$a.Save()

# ---------------- [8/9] Firewall + power ------------------------------------
Log "[8/9] Firewall and power..."
Remove-NetFirewallRule -DisplayName "Illumina Web App" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Illumina Web App" -Direction Inbound -LocalPort $HttpPort -Protocol TCP -Action Allow | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null

# ---------------- [9/9] Summary ---------------------------------------------
Log "[9/9] Done!"
Write-Host @"

==================================================
   Installation complete! ($($Release.tag_name))
   Portal    : $PortalUrl
   Everyday  : desktop icon 'Illumina'
   Emergency : desktop icon 'Restart Illumina (if misbehaving)'
==================================================
"@ -ForegroundColor Cyan
$ans = Read-Host "Reboot now to apply auto sign-in? [Y/n]"
if ($ans -notmatch '^[nN]') { Restart-Computer }
