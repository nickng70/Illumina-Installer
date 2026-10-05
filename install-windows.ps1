#Requires -RunAsAdministrator
<#
    Illumina AVA PC Installer - Windows 10/11 (v6.2 FINAL)
    - Kiosk account: dedicated standard user (avauser) or current user (testing)
    - Binaries in Program Files (tamper-protected); runtime-writable folders
      ACL-granted to the kiosk account; Data locked to runtime account + admins
    - Machine-trusted 100-year HTTPS cert; Kestrel bound via AppSettingsOverrides
    - Google Drive key auto-fetched from secrets/drive-key.json in the private
      Illumina-Releases repo (or copied from a local path) - never shipped in
      the release zip, never a manual pre-step
#>
$ErrorActionPreference = "Stop"

# ----------------------------- CONFIG ---------------------------------------
$GitHubOwner = "nickng70"
$GitHubRepo  = "Illumina-Releases"
$AssetName   = "illumina-win-x64.zip"
$InstallDir  = "C:\Program Files\Illumina"
$MachineDir  = "C:\ProgramData\Illumina"   # update-surviving machine store
$HttpPort    = "443"
$PortalUrl   = "https://localhost"
$TokenFile   = "$MachineDir\github-token"
$LogonDelaySeconds     = 12
$AutoOpenPortalAtLogon = $true
# ----------------------------------------------------------------------------

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Illumina AVA PC Installer (Windows) v6.2       " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# ---------------- [1/8] GitHub token ----------------------------------------
Log "[1/8] GitHub token..."
New-Item -ItemType Directory -Path $MachineDir -Force | Out-Null
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

# ---------------- [5/8] App files + ACL model -------------------------------
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

# Runtime-writable working folders: Program Files (and the C:\ root) are
# write-protected for standard tokens, so the account that RUNS the app needs
# explicit Modify on exactly these - the fix for the SlideContent /
# MediaContent / AppData UnauthorizedAccessException crashes.
foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
# Data lockdown: runtime account + admins only; every other account denied.
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
Set-Content "$MachineDir\current-version" $Release.tag_name

# ---------------- [6/8] Cert + Kestrel + Drive key --------------------------
Log "[6/8] HTTPS certificate, Kestrel binding, Drive key..."
$PfxPath = "$MachineDir\illumina.pfx"
$PfxPass = "IlluminaKioskCert"   # non-secret by design; the PFX file is ACL-protected
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina Kiosk HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$MachineDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$MachineDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
}
$sec = ConvertTo-SecureString -String $PfxPass -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath $PfxPath -Password $sec -Force | Out-Null
# The app PROCESS (standard kiosk token) must be able to READ the cert:
icacls $PfxPath /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "${HumanUser}:R" | Out-Null

# Per-machine overrides through the app's own supported layer. Existing keys
# are preserved; only these sections are force-refreshed per install.
$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }
$obj | Add-Member -NotePropertyName "Kestrel" -Force -NotePropertyValue ([PSCustomObject]@{
    Certificates = [PSCustomObject]@{ Default = [PSCustomObject]@{ Path = $PfxPath; Password = $PfxPass } }
})
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://0.0.0.0:$HttpPort"

# ---- Google Drive slide sync (optional, per machine) ----
# The service-account key is a SECRET: it never lives in the public installer
# repo, the publish folder, or the release zip. It is fetched on demand from
# the PRIVATE Illumina-Releases repo (secrets/drive-key.json) using the same
# read-only token the installer already holds, or copied from a local path
# (USB/share/laptop) - so there is never a manual pre-step.
$keyJson = "$MachineDir\key.json"
$sync = Read-Host "Enable Google Drive slide sync on this machine? (y/N)"
if ($sync -match '^[yY]') {
    if (Test-Path $keyJson) {
        Log "Existing key.json found in $MachineDir - reusing."
    } else {
        try {
            Log "Fetching secrets/drive-key.json from $GitHubOwner/$GitHubRepo..."
            Invoke-WebRequest -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/contents/secrets/drive-key.json" `
                -Headers @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github.raw" } `
                -OutFile $keyJson
        } catch {
            Log "Repo download unavailable - falling back to a local copy."
            $src = Read-Host "Path to a local key.json (USB/share/laptop), or blank to skip sync"
            if ($src -and (Test-Path $src)) { Copy-Item $src $keyJson -Force }
        }
    }
}
if (Test-Path $keyJson) {
    icacls $keyJson /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "${HumanUser}:R" | Out-Null
}
# Key + opt-in => sync on; anything else => folder IDs blanked so this machine
# skips sync silently instead of logging missing-key errors forever.
$drive = [PSCustomObject]@{}
if ((Test-Path $keyJson) -and ($sync -match '^[yY]')) {
    $drive | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue $keyJson
    Log "Google Drive sync ENABLED via $keyJson"
} else {
    $drive | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue ""
    $drive | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue ""
    Log "Google Drive sync disabled on this machine."
}
$obj | Add-Member -NotePropertyName "SlideLibrary" -Force -NotePropertyValue ([PSCustomObject]@{ GoogleDrive = $drive })
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath

# ---------------- Chrome + helpers + shortcuts ------------------------------
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
   Kiosk account : $HumanUser (standard user)
   Portal        : $PortalUrl
   Machine store : $MachineDir (token, cert, key.json)
==================================================
"@ -ForegroundColor Cyan
$ans = Read-Host "Reboot now to apply auto sign-in? [Y/n]"
if ($ans -notmatch '^[nN]') { Restart-Computer }
