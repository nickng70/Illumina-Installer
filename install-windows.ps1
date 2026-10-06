#Requires -RunAsAdministrator
<#
    Illumina AVA PC Installer - Windows 10/11 (v6.4 FINAL)
    - Numbered kiosk-account menu (ENTER = recommended avauser, standard user);
      "current" mode shows your real username and skips portal auto-open
    - Site survey: Right Wall / Streaming-Broadcast / Google Drive sync,
      stamped per-machine into AppData/AppSettingsOverrides.json (merged
      key-by-key, never clobbering Settings-saved geometry)
    - Readiness-polled helpers: Chrome only opens once https://localhost
      actually answers, so boot-time tabs never land on blank/error pages
    - Binaries in Program Files (tamper-protected); runtime-writable folders
      ACL-granted to the kiosk account; Data locked to runtime account + admins
    - Machine-trusted 100-year HTTPS cert; Kestrel bound via overrides
    - Drive key auto-fetched from secrets/drive-key.json (private repo) or
      copied from a local path - never shipped, never a manual pre-step
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
Write-Host "   Illumina AVA PC Installer (Windows) v6.4       " -ForegroundColor Cyan
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
Write-Host ""
Write-Host "  [1] avauser       - dedicated kiosk account (recommended for church AVA PCs)"
Write-Host "  [2] $env:USERNAME - your current Windows account (local testing)"
$mode = Read-Host "Choose kiosk account (press ENTER for 1)"
$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"

if ($mode -eq '2') {
    $HumanUser = $env:USERNAME
    Log "Kiosk account: $HumanUser (current user)."
    $PlainPass = Read-Host "Windows password for $HumanUser (for auto-login; ENTER to skip auto-login)"
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
    $existing  = Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue
    $PlainPass = Read-Host "SECRET admin-gate password for $HumanUser (ENTER keeps existing)"
    if (-not $PlainPass) {
        # Re-run convenience: reuse the password auto-login already stores,
        # so updates are a pure ENTER-ENTER-ENTER affair.
        $PlainPass = (Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue).DefaultPassword
        if (-not $PlainPass) { throw "No stored password found - please type one." }
        Log "Keeping existing password for $HumanUser."
    }
    $Sec = ConvertTo-SecureString $PlainPass -AsPlainText -Force
    if (-not $existing) {
        New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $Sec -PasswordNeverExpires | Out-Null
        Log "Created kiosk user: $HumanUser (sign-in tile shows 'AVA Kiosk')."
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
    } else { Log "$HumanUser is a standard user (correct for a kiosk)." }
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

# ---------------- [6/8] Site survey + cert + machine config -----------------
Log "[6/8] Site survey and machine configuration..."
Write-Host ""
Write-Host "  Answer for THIS PC's connected hardware (ENTER accepts the default):"
$rightWall = Read-Host "  [1/3] Is a Right Wall display connected, in addition to the Left Wall? [Y/n]"
$streaming = Read-Host "  [2/3] Is a Streaming/Broadcast display connected (CG overlay + encoder + stream output)? [y/N]"
$sync      = Read-Host "  [3/3] Does this church sync Prayer/Announcement slides from Google Drive? [y/N]"
$rightWallOn = ($rightWall -notmatch '^[nN]')
$streamOn    = ($streaming -match '^[yY]')
$syncOn      = ($sync -match '^[yY]')
Log "Right Wall: $rightWallOn | Streaming/Broadcast: $streamOn | Drive sync: $syncOn"

# ---- Google Drive key + folder IDs ----
$keyJson  = "$MachineDir\key.json"
$prayerId = ""; $annId = ""
if ($syncOn) {
    if (Test-Path $keyJson) { Log "Existing key.json found in $MachineDir - reusing." }
    else {
        try {
            Log "Fetching secrets/drive-key.json from $GitHubOwner/$GitHubRepo..."
            Invoke-WebRequest -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/contents/secrets/drive-key.json" `
                -Headers @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github.raw" } -OutFile $keyJson
        } catch {
            Log "Repo download unavailable - falling back to a local copy."
            $src = Read-Host "  Path to a local key.json (USB/share/laptop), or blank to skip sync"
            if ($src -and (Test-Path $src)) { Copy-Item $src $keyJson -Force }
        }
    }
    if (Test-Path $keyJson) {
        icacls $keyJson /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "${HumanUser}:R" | Out-Null
        $prayerId = Read-Host "  Prayer slides Google Drive folder ID"
        $annId    = Read-Host "  Announcements slides Google Drive folder ID"
    } else { $syncOn = $false; Log "No key available - Drive sync disabled on this machine." }
}

# ---- Machine-trusted HTTPS certificate ----
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

# ---- Stamp machine truth into the overrides layer (merge, never clobber) ----
$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

$obj | Add-Member -NotePropertyName "Kestrel" -Force -NotePropertyValue ([PSCustomObject]@{
    Certificates = [PSCustomObject]@{ Default = [PSCustomObject]@{ Path = $PfxPath; Password = $PfxPass } }
})
# Kept until base appsettings.json carries Urls; identical value, harmless.
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://0.0.0.0:$HttpPort;http://0.0.0.0:80"

if ($obj.PSObject.Properties.Name -notcontains "Kiosk") { $obj | Add-Member -NotePropertyName "Kiosk" -NotePropertyValue ([PSCustomObject]@{}) }
$k = $obj.Kiosk
$k | Add-Member -NotePropertyName "BaseUrl"          -NotePropertyValue $PortalUrl   -Force
$k | Add-Member -NotePropertyName "Enabled"          -NotePropertyValue $true         -Force
$k | Add-Member -NotePropertyName "RightWallEnabled" -NotePropertyValue $rightWallOn  -Force
$k | Add-Member -NotePropertyName "CgEnabled"        -NotePropertyValue $streamOn     -Force
$k | Add-Member -NotePropertyName "ProgramEnabled"   -NotePropertyValue $streamOn     -Force
if (-not $streamOn) { $k | Add-Member -NotePropertyName "CgConfidenceMonitorEnabled" -NotePropertyValue $false -Force }

if ($obj.PSObject.Properties.Name -notcontains "SlideLibrary") { $obj | Add-Member -NotePropertyName "SlideLibrary" -NotePropertyValue ([PSCustomObject]@{}) }
$sl = $obj.SlideLibrary
if ($sl.PSObject.Properties.Name -notcontains "GoogleDrive") { $sl | Add-Member -NotePropertyName "GoogleDrive" -NotePropertyValue ([PSCustomObject]@{}) }
$gd = $sl.GoogleDrive
if ($syncOn) {
    $gd | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue $keyJson  -Force
    $gd | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue $prayerId -Force
    $gd | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue $annId    -Force
    Log "Google Drive sync ENABLED via $keyJson"
} else {
    # Explicit blanks shadow any personal IDs still in the shipped appsettings.json
    $gd | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue "" -Force
    Log "Google Drive sync disabled on this machine."
}
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath

# ---------------- [7/8] Helpers + shortcuts (readiness-polled) --------------
# Portal auto-open at logon is KIOSK behavior: a dedicated avauser boots
# straight into the service (zero-click), while a personal "current" account
# only gets the app running silently - a stray auto-opened portal tab would
# also count as LOCAL presence and keep the walls alive unintentionally.
$portalAtLogon = ($mode -ne '2') -and $AutoOpenPortalAtLogon
Log $(if ($portalAtLogon) { "Logon behavior: app + portal auto-open (kiosk mode)." }
      else { "Logon behavior: app starts silently - no browser auto-open." })

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
$EnvUrls = "https://0.0.0.0:$HttpPort;http://0.0.0.0:80"

$open = @'
param([int]$DelaySeconds = 0, [switch]$NoPortal)
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
$env:ASPNETCORE_URLS = "__ENV_URLS__"
$app = "__APP__"
if (-not (Get-Process -Name Illumina -ErrorAction SilentlyContinue)) {
    Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
}
# Wait until the portal ACTUALLY answers before opening Chrome, so an
# auto-opened tab never lands on a blank/error page during cold boot
# (Kestrel binds only after startup finishes loading Bible/hymns/indexes).
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try { Invoke-WebRequest -Uri "__PROBE__" -UseBasicParsing -TimeoutSec 2 | Out-Null; $ready = $true; break }
    catch { Start-Sleep -Seconds 2 }
}
if (-not $NoPortal -and $ready) { __PORTAL__ }
'@
$open = $open -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine -replace '__ENV_URLS__', $EnvUrls -replace '__PROBE__', $PortalUrl
Set-Content "$InstallDir\open-illumina.ps1" $open

$restart = @'
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force "$env:TEMP\IlluminaKiosk" -ErrorAction SilentlyContinue
$env:ASPNETCORE_URLS = "__ENV_URLS__"
$app = "__APP__"
Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
# A human clicked this button, so the portal ALWAYS opens - but we wait for
# readiness first so they land on a live portal, not a blank page. If the app
# is genuinely broken, the error page after the timeout is itself the signal.
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    try { Invoke-WebRequest -Uri "__PROBE__" -UseBasicParsing -TimeoutSec 2 | Out-Null; $ready = $true; break }
    catch { Start-Sleep -Seconds 2 }
}
__PORTAL__
'@
$restart = $restart -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine -replace '__ENV_URLS__', $EnvUrls -replace '__PROBE__', $PortalUrl
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
$a.Arguments  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\open-illumina.ps1`" -DelaySeconds $LogonDelaySeconds" + $(if ($portalAtLogon) { "" } else { " -NoPortal" })
$a.Save()

# ---------------- [8/8] Firewall + power + summary --------------------------
Log "[8/8] Firewall and power..."
Remove-NetFirewallRule -DisplayName "Illumina Web App"      -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina Phones HTTP" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Illumina Web App"      -Direction Inbound -LocalPort $HttpPort -Protocol TCP -Action Allow | Out-Null
New-NetFirewallRule -DisplayName "Illumina Phones HTTP" -Direction Inbound -LocalPort 80      -Protocol TCP -Action Allow | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null

Write-Host @"
==================================================
   Installation complete! ($($Release.tag_name))
   Kiosk account : $HumanUser (standard user)
   Right Wall    : $rightWallOn
   Streaming     : $streamOn
   Drive sync    : $syncOn
   Portal at boot: $portalAtLogon
   Portal        : $PortalUrl
   Machine store : $MachineDir (token, cert, key.json)
==================================================
"@ -ForegroundColor Cyan
$ans = Read-Host "Reboot now to apply auto sign-in? [Y/n]"
if ($ans -notmatch '^[nN]') { Restart-Computer }
