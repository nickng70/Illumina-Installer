#Requires -RunAsAdministrator
<#
    Illumina AVA PC Installer - Windows 10/11 (v6 - Option A final)
    Kiosk account = dedicated standard user (avauser) or current user (testing).
    Binaries in Program Files; writable folders ACL-granted; Data locked to
    runtime account + Administrators only.
#>
$ErrorActionPreference = "Stop"

# ----------------------------- CONFIG ---------------------------------------
$GitHubOwner = "nickng70"
$GitHubRepo  = "Illumina-Releases"
$AssetName   = "illumina-win-x64.zip"
$InstallDir  = "C:\Program Files\Illumina"
$HttpPort    = "443"
$PortalUrl   = "https://localhost"
$TokenFile   = "C:\ProgramData\Illumina\github-token"
$LogonDelaySeconds     = 12
$AutoOpenPortalAtLogon = $true
# ----------------------------------------------------------------------------

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina AVA PC Installer (Windows) v6         " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------- [1/8] GitHub token ----------------------------------------
Log "[1/8] GitHub token..."
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

# ---------------- [2/8] Latest release asset --------------------------------
Log "[2/8] Locating latest release..."
try { $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/latest" -Headers $Api }
catch { throw "GitHub API failed. $_" }
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if (-not $Asset) { throw "Asset '$AssetName' not found in release $($Release.tag_name)." }
$Zip = Join-Path $env:TEMP $AssetName
Log "Downloading $AssetName..."
Invoke-WebRequest -Uri $Asset.url -Headers @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream" } -OutFile $Zip

# ---------------- [3/8] Stop running instances ------------------------------
Log "[3/8] Stopping running Illumina/Chrome..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

# ---------------- [4/8] Kiosk account selection -----------------------------
Log "[4/8] Choosing the kiosk account..."
$mode = Read-Host "Install for dedicated 'avauser' (church AVA PCs) or 'current' user (local testing)? [avauser/current]"
$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if ($mode -eq 'current') {
    $HumanUser = $env:USERNAME
    Log "Kiosk account: current user ($HumanUser)."
    $PlainPass = Read-Host "Windows password for $HumanUser (for auto-login; leave blank to skip auto-login)"
    if ($PlainPass) {
        Set-ItemProperty $Winlogon "AutoAdminLogon"    "1"               -Type String
        Set-ItemProperty $Winlogon "DefaultUserName"   $HumanUser        -Type String
        Set-ItemProperty $Winlogon "DefaultPassword"   $PlainPass        -Type String
        Set-ItemProperty $Winlogon "DefaultDomainName" $env:COMPUTERNAME -Type String
        Log "Configured auto sign-in for $HumanUser."
    } else { Log "Skipped auto sign-in." }
}
else {
    $HumanUser = "avauser"
    $PlainPass = Read-Host "Set/refresh the SECRET admin-gate password for $HumanUser"
    if (-not $PlainPass) { throw "Password cannot be empty." }
    $Sec = ConvertTo-SecureString $PlainPass -AsPlainText -Force
    if (-not (Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue)) {
        New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $Sec -PasswordNeverExpires | Out-Null
        Log "Created kiosk user: $HumanUser"
    } else {
        Set-LocalUser -Name $HumanUser -Password $Sec -PasswordNeverExpires $true
        Log "Updated password for existing kiosk user: $HumanUser"
    }
    # Kiosk account is a STANDARD user by design: every privileged action
    # (updates, ACL changes, installs) must demand the admin password.
    $isAdmin = Get-LocalGroupMember -Group "Administrators" -Member $HumanUser -ErrorAction SilentlyContinue
    if ($isAdmin) {
        Remove-LocalGroupMember -Group "Administrators" -Member $HumanUser
        Log "Demoted $HumanUser to standard user (kiosk accounts must not be admins)."
    } else {
        Log "$HumanUser is a standard user (correct for a kiosk)."
    }
    Set-ItemProperty $Winlogon "AutoAdminLogon"    "1"               -Type String
    Set-ItemProperty $Winlogon "DefaultUserName"   $HumanUser        -Type String
    Set-ItemProperty $Winlogon "DefaultPassword"   $PlainPass        -Type String
    Set-ItemProperty $Winlogon "DefaultDomainName" $env:COMPUTERNAME -Type String
    Log "Configured auto sign-in for $HumanUser."
}

# ---------------- [5/8] App files + ACL lockdown ----------------------------
Log "[5/8] Installing app to $InstallDir..."
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

# Writable working folders: the app (running as the kiosk account) must be
# able to create/update these inside Program Files - this is the fix for the
# SlideContent UnauthorizedAccessException.
foreach ($w in @("SlideContent", "MediaContent", "AppData")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
# Data lockdown: runtime account + admins only; every other account denied.
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
Set-Content "C:\ProgramData\Illumina\current-version" $Release.tag_name

# ---------------- [6/8] Machine cert + Kestrel overrides --------------------
Log "[6/8] Ensuring machine-level HTTPS certificate..."
$CertDir = "C:\ProgramData\Illumina"
$PfxPath = "$CertDir\illumina.pfx"
$PfxPass = "IlluminaKioskCert"
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina Kiosk HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$CertDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$CertDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
}
$sec = ConvertTo-SecureString -String $PfxPass -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $sec -Force | Out-Null
icacls $PfxPath /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null

$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }
$obj | Add-Member -NotePropertyName "Kestrel" -Force -NotePropertyValue ([PSCustomObject]@{
    Certificates = [PSCustomObject]@{ Default = [PSCustomObject]@{ Path = $PfxPath; Password = $PfxPass } }
})
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://0.0.0.0:$HttpPort"
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath

# ---------------- Chrome + helper scripts + shortcuts -----------------------
function Resolve-Chrome {
    foreach ($c in @("C:\Program Files\Google\Chrome\Application\chrome.exe",
                     "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if (Test-Path $c) { return $c } }
    $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue
    if ($ap -and $ap.'(default)' -and (Test-Path $ap.'(default)')) { return $ap.'(default)' }
    return $null
}
$ChromeExe = Resolve-Chrome
if (-not $ChromeExe) { Write-Warning "Chrome not found - portal links fall back to default browser." }
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '$PortalUrl'" } else { "Start-Process '$PortalUrl'" }

Log "[7/8] Writing helper scripts and shortcuts..."
$AppExe  = "$InstallDir\Illumina.exe"
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

$Wsh     = New-Object -ComObject WScript.Shell
$Startup = [Environment]::GetFolderPath("CommonStartup")
$Desktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
Get-ChildItem $Startup -Filter "Illumina*.lnk"         -ErrorAction SilentlyContinue | Remove-Item -Force
Get-ChildItem $Desktop -Filter "Illumina*.lnk"         -ErrorAction SilentlyContinue | Remove-Item -Force
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

# ---------------- [8/8] Firewall + power + summary --------------------------
Log "[8/8] Firewall and power..."
Remove-NetFirewallRule -DisplayName "Illumina Web App" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Illumina Web App" -Direction Inbound -LocalPort $HttpPort -Protocol TCP -Action Allow | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null

Write-Host @"
==================================================
   Installation complete! ($($Release.tag_name))
   Kiosk account : $HumanUser
   Portal        : $PortalUrl
==================================================
"@ -ForegroundColor Cyan
$ans = Read-Host "Reboot now to apply auto sign-in? [Y/n]"
if ($ans -notmatch '^[nN]') { Restart-Computer }
