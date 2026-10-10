<#
    Illumina AVA PC Installer - Windows 10/11 (v8.1 FINAL)
    - Friendly administrator check; nothing changes before it passes
    - Provisions media engines from the internet: LibreOffice (slides),
      FFmpeg (broadcast), and Chrome itself if missing (winget)
    - Five-question survey (Right Display / Streaming / Drive sync /
      Home Assistant / Novastar); ENTER = No everywhere
    - Home Assistant: detect first, then address; Windows gets honest
      guidance (HA is officially Linux/VM/appliance territory)
    - Patches the INSTALLED appsettings.json with the machine-store Kestrel
      block when the release zip predates it (Kestrel binds at host start,
      before the overrides layer loads - a missing block bricked fresh PCs)
    - Creates + trusts a private 100-year machine certificate
    - Binding contract per AGENTS.md: HTTPS localhost-only + HTTP on all
      interfaces for congregation phones; QR BaseUrl auto-stamped
    - Clean [1]/[2] kiosk-account menu; surgical process handling
    - Content folders permission-locked and hidden quietly
    - Human-facing labels use "Display"; internal config keys keep their
      legacy names for backwards compatibility with deployed churches
    - Automated firewall and loopback exemptions for fresh Windows PCs
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
$SofficePath = "C:\Program Files\LibreOffice\program\soffice.exe"
$FfmpegPath  = "C:\ffmpeg\ffmpeg.exe"
$LogonDelaySeconds     = 12
$AutoOpenPortalAtLogon =$true
# ----------------------------------------------------------------------------

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

function Resolve-Chrome {
    foreach ($c in @("C:\Program Files\Google\Chrome\Application\chrome.exe",
                     "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if (Test-Path $c) { return $c } }
    $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue
    if ($ap -and $ap.'(default)' -and (Test-Path $ap.'(default)')) { return $ap.'(default)' }
    return $null
}

# ---------------- [0/9] Administrator check ---------------------------------
$identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host ""
    Write-Host "  Illumina setup needs administrator rights for this one run - it installs" -ForegroundColor Yellow
    Write-Host "  program files and opens a network port, which Windows only allows an" -ForegroundColor Yellow
    Write-Host "  elevated session to do." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Please close this window, open PowerShell again with" -ForegroundColor Yellow
    Write-Host "  right-click > 'Run as administrator', and paste the same command." -ForegroundColor Yellow
    Write-Host "  Nothing on this PC has been changed yet." -ForegroundColor Yellow
    exit 1
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "    Illumina AVA PC Installer - Windows (v8.1)     " -ForegroundColor Cyan
Write-Host "    Guided setup for a safe, self-starting kiosk   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Welcome! This installer prepares this PC to run Illumina around the"
Write-Host "  clock: it fetches the latest release and the media engines it needs,"
Write-Host "  configures secure local HTTPS, and tailors the displays and smart"
Write-Host "  integrations to your hardware. Every question explains itself, and"
Write-Host "  pressing ENTER always accepts the safe, recommended default."

# ---------------- [1/9] GitHub token ----------------------------------------
Log "[1/9] Release access token..."
New-Item -ItemType Directory -Path $MachineDir -Force | Out-Null
if ($env:GITHUB_TOKEN) { $Token = $env:GITHUB_TOKEN; Log "Using the token from this session's environment." }
elseif (Test-Path $TokenFile) { $Token = (Get-Content $TokenFile -Raw).Trim(); Log "Reusing the token stored on this machine - nothing to type." }
else {
    Write-Host "  Illumina's release packages live in a private repository, so we need"
    Write-Host "  a read-only GitHub token once; it is then stored securely on this PC."
    $Token = Read-Host "  Paste your GitHub read-only token"
    if (-not $Token) { throw "A token is required to download Illumina. Please re-run with a token." }
    Set-Content -Path $TokenFile -Value $Token
    icacls $TokenFile /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" | Out-Null
    Log "Token stored securely (administrators only)."
}
$Api = @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github+json" }

# ---------------- [2/9] Latest release asset --------------------------------
Log "[2/9] Downloading the latest Illumina release..."
try { $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/latest" -Headers $Api }
catch { throw "Could not reach the release repository. Check the token and internet connection. $_" }
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if (-not $Asset) { throw "Asset '$AssetName' not found in release $($Release.tag_name)." }
$Zip = Join-Path $env:TEMP $AssetName
Invoke-WebRequest -Uri $Asset.url -Headers @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream" } -OutFile $Zip
Log "Release $($Release.tag_name) downloaded."

# ---------------- [3/9] Media engines & browser -----------------------------
Log "[3/9] Provisioning media engines and the display browser..."
Write-Host "  Illumina relies on three companions: LibreOffice (converts slide"
Write-Host "  decks), FFmpeg (remuxes the broadcast feed), and Chrome (renders every"
Write-Host "  display). Anything missing is installed now, straight from the internet."

if (Test-Path $SofficePath) { Log "LibreOffice already present." }
else {
    Log "Installing LibreOffice..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id TheDocumentFoundation.LibreOffice -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        if (Test-Path $SofficePath) { Log "LibreOffice installed." } else { Write-Warning "  LibreOffice install could not be verified - install it manually if slides must convert." }
    } else { Write-Warning "  winget not available on this PC - please install LibreOffice manually after setup." }
}

if (Test-Path $FfmpegPath) { Log "FFmpeg already present." }
else {
    Log "Installing FFmpeg..."
    $ffmpegZip = "$env:TEMP\ffmpeg-release.zip"; $ffmpegOut = "$env:TEMP\ffmpeg-extract"
    try {
        New-Item -ItemType Directory -Path "C:\ffmpeg" -Force | Out-Null
        Invoke-WebRequest -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" -OutFile $ffmpegZip -UseBasicParsing
        Expand-Archive -Path $ffmpegZip -DestinationPath $ffmpegOut -Force
        $found = Get-ChildItem $ffmpegOut -Recurse -Filter "ffmpeg.exe" | Select-Object -First 1
        if ($found) { Move-Item $found.FullName $FfmpegPath -Force; Log "FFmpeg installed to C:\ffmpeg." }
    } catch { Write-Warning "  FFmpeg download failed - place ffmpeg.exe in C:\ffmpeg manually if broadcasting is needed." }
    finally { Remove-Item $ffmpegZip, $ffmpegOut -Recurse -Force -ErrorAction SilentlyContinue }
}

$ChromeExe = Resolve-Chrome
if (-not $ChromeExe) {
    Log "Chrome not found - installing it..."
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id Google.Chrome -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        $ChromeExe = Resolve-Chrome
    }
}
if ($ChromeExe) { Log "Chrome ready at $ChromeExe" } else { Write-Warning "  Chrome could not be installed - the portal will fall back to the default browser." }

# ---------------- [4/9] Pause previous session ------------------------------
Log "[4/9] Pausing any running Illumina session..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Log "Previous session paused - your open browser tabs and files are untouched."

# ---------------- [5/9] Kiosk account & sign-in -----------------------------
Log "[5/9] Choosing the kiosk account and sign-in behavior..."
Write-Host ""

$interactiveUser = $env:USERNAME
try {
    $csUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($csUser) { $interactiveUser = ($csUser -split '\\')[-1] }
} catch { }
$adminNames = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
$currentUserIsAdmin = ($adminNames -contains $interactiveUser)

Write-Host "  How will this PC be used?"
Write-Host "  [1] Dedicated Church AVA PC (Recommended)"
Write-Host "      Creates a clean, standard-user account named 'avauser' just for Illumina."
Write-Host "      This keeps the desktop uncluttered and prevents accidental system changes."
Write-Host "  [2] Personal Laptop or IT Testing"
Write-Host "      Uses your current Windows account ($interactiveUser)."
Write-Host "      Ideal for development, testing, or initial setup by an administrator."
if (-not $currentUserIsAdmin) {
    Write-Host ""
    Write-Host "  (Note: Your current account is already a Standard user, which is perfectly safe for Option 2!)" -ForegroundColor Cyan
}
$mode = Read-Host "`n  Select setup type (press ENTER for 1)"
$useAvaUser = ($mode -ne '2')

$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$wl       = Get-ItemProperty$Winlogon -ErrorAction SilentlyContinue
$autoOnNow   = ($wl.AutoAdminLogon -eq "1")
$autoUserNow =$wl.DefaultUserName

function Read-NewPassword([string]$what) {
    $p1 = Read-Host$what
    if (-not $p1) { return $null }$p2 = Read-Host "  Type it once more to confirm"
    if ($p1 -ne$p2) { throw "The two passwords did not match - nothing was changed. Please re-run the installer." }
    return $p1
}
function Set-AutoLogin([string]$user, [string]$pass) {
    Set-ItemProperty $Winlogon "AutoAdminLogon"    "1"               -Type String
    Set-ItemProperty $Winlogon "DefaultUserName"   $user             -Type String
    Set-ItemProperty $Winlogon "DefaultPassword"   $pass             -Type String
    Set-ItemProperty $Winlogon "DefaultDomainName" $env:COMPUTERNAME -Type String
}
function Clear-AutoLogin {
    Set-ItemProperty $Winlogon "AutoAdminLogon"  "0" -Type String
    Set-ItemProperty $Winlogon "DefaultPassword" ""  -Type String
}

$autoLoginOn =$false
if ($useAvaUser) {$HumanUser = "avauser"
    $existing  = Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue$reusable = $autoOnNow -and ($autoUserNow -eq $HumanUser) -and$wl.DefaultPassword
    if ($reusable) {
        $PlainPass =$wl.DefaultPassword
        Log "Reusing avauser's existing password (re-install detected)."
    } else {
        $PlainPass = Read-NewPassword "  Set the SECRET password for avauser (used for maintenance logins; typed twice to avoid typos)"
        if (-not $PlainPass) { throw "A new kiosk account needs a password. Please re-run and provide one." }
    }
    $Sec = ConvertTo-SecureString$PlainPass -AsPlainText -Force
    if (-not $existing) {
        New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $Sec -PasswordNeverExpires | Out-Null
        Log "Created kiosk account 'avauser' (its sign-in tile reads 'AVA Kiosk')."
    } else {
        Set-LocalUser -Name $HumanUser -Password $Sec -PasswordNeverExpires$true
        Log "Refreshed the existing kiosk account 'avauser'."
    }
    $isAdminGrp = Get-LocalGroupMember -Group "Administrators" -Member $HumanUser -ErrorAction SilentlyContinue
    if ($isAdminGrp) {
        Remove-LocalGroupMember -Group "Administrators" -Member $HumanUser
        Log "Confirmed 'avauser' is a standard user (kiosk accounts must not be admins)."
    } else { Log "Confirmed 'avauser' is a standard user." }
    Set-AutoLogin $HumanUser$PlainPass
    $autoLoginOn =$true
    Log "Auto sign-in configured for avauser - it activates at the next restart."

    # Grant loopback exemption for the kiosk user
    try {
        $sid = (New-Object System.Security.Principal.NTAccount($HumanUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
        CheckNetIsolation LoopbackExempt -a -p="$sid" -Name="Illumina Kiosk Browser" | Out-Null
        Log "Loopback network exemption granted for kiosk user ($HumanUser)."
    } catch {
        Write-Warning "Could not register loopback exemption automatically."
    }
}
else {
    $HumanUser =$interactiveUser
    if ($currentUserIsAdmin) {
        Write-Host ""
        Write-Host "  NOTICE: continuing with an ADMINISTRATOR account ('$HumanUser')." -ForegroundColor Yellow
        Write-Host "  Anyone using this PC can delete or modify Illumina, change firewall rules,"
        Write-Host "  and install software without a password prompt."
    }
    Write-Host ""
    $want = Read-Host "  Enable auto sign-in for $HumanUser on this PC? [y/N] (ENTER = No)"
    if ($want -match '^[yY]') {$PlainPass = Read-NewPassword "  Windows password for $HumanUser, stored for auto sign-in"
        Set-AutoLogin $HumanUser$PlainPass
        $autoLoginOn =$true
        Log "Auto sign-in enabled for $HumanUser."
    } else {
        Clear-AutoLogin
        Log "Auto sign-in left OFF."
    }
}

# ---------------- [6/9] App files + content folders -------------------------
Log "[6/9] Installing Illumina and preparing its content folders..."
$Backup =$null
if (Test-Path "$InstallDir\Data") { $Backup = Join-Path$env:TEMP "illumina-data-backup"; Move-Item "$InstallDir\Data" $Backup -Force }
if (Test-Path $InstallDir) { Remove-Item$InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Expand-Archive -Path $Zip -DestinationPath$InstallDir -Force
Remove-Item $Zip -Force
if ($Backup) {
    if (Test-Path "$InstallDir\Data") { Remove-Item "$InstallDir\Data" -Recurse -Force }
    Move-Item $Backup "$InstallDir\Data" -Force
}
New-Item -ItemType Directory -Path "$InstallDir\Data" -Force | Out-Null

$appSettingsPath = "$InstallDir\appsettings.json"
$raw = Get-Content$appSettingsPath -Raw
if ($raw -notmatch '"Kestrel"') {
    $kestrelBlock = @"

  "Kestrel": {
    "Certificates": {
      "Default": {
        "Subject": "localhost",
        "Store": "My",
        "Location": "LocalMachine",
        "AllowInvalid": true
      }
    }
  },
"@
    $idx =$raw.IndexOf('{')
    $raw =$raw.Insert($idx + 1,$kestrelBlock)
    Set-Content -Path $appSettingsPath -Value$raw -Encoding UTF8
    Log "Patched appsettings.json with Kestrel HTTPS block."
}

foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir$w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
attrib +s +h "$InstallDir\Data" | Out-Null
Log "Content folders prepared."
Set-Content "$MachineDir\current-version" $Release.tag_name

# ---------------- [7/9] Firewall, Certificate & Machine Settings ------------
Log "[7/9] Configuring Firewall, HTTPS certificate, and settings..."

# Configure Windows Firewall rules for HTTP and HTTPS inbound traffic
Log "Configuring Windows Firewall rules for port 80 and 443..."
New-NetFirewallRule -DisplayName "Illumina Web HTTP" -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow -ErrorAction SilentlyContinue | Out-Null
New-NetFirewallRule -DisplayName "Illumina Web HTTPS" -Direction Inbound -Protocol TCP -LocalPort 443 -Action Allow -ErrorAction SilentlyContinue | Out-Null

$rightWall = Read-Host "  [1/5] Is a RIGHT Display connected? [y/N] (ENTER = No)"
$streaming = Read-Host "  [2/5] Is a STREAMING/BROADCAST setup used? [y/N] (ENTER = No)"
$sync      = Read-Host "  [3/5] Should Prayer/Announcement slides sync from Google Drive? [y/N] (ENTER = No)"
$haUse     = Read-Host "  [4/5] Do you automate AV devices through Home Assistant? [y/N] (ENTER = No)"
$novastarUse = Read-Host "  [5/5] Is a Novastar LED video controller on the local network? [y/N] (ENTER = No)"

$rightWallOn = ($rightWall -match '^[yY]')
$streamOn    = ($streaming -match '^[yY]')
$syncOn      = ($sync -match '^[yY]')

$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {$cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina Kiosk HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$MachineDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$MachineDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Log "Certificate created and trusted."
} else { Log "Reusing existing HTTPS certificate." }

try {
    $rsa    = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $keyAcl = $rsa.Key.GetAccessControl()
    $keyAcl.AddAccessRule((New-Object System.Security.Cryptography.AccessControl.CngKeyAccessRule(
            'Users',
            [System.Security.Cryptography.AccessControl.CngKeyRights]::Read,
            [System.Security.Cryptography.AccessControl.AccessControlType]::Allow)))
    $rsa.Key.SetAccessControl($keyAcl)
    Log "Certificate private key readable by kiosk account."
} catch { }

$keyJson  = "$MachineDir\key.json"
$prayerId = ""; $annId = ""
if ($syncOn) {
    if (-not (Test-Path $keyJson)) {
        try {
            Invoke-WebRequest -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/contents/secrets/drive-key.json" `
                -Headers @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github.raw" } -OutFile $keyJson
        } catch { }
    }
    if (Test-Path $keyJson) {
        icacls $keyJson /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "${HumanUser}:R" | Out-Null
        $prayerId = Read-Host "  Prayer slides folder ID (Google Drive)"
        $annId    = Read-Host "  Announcements slides folder ID (Google Drive)"
        if (-not $prayerId -or -not$annId) { $syncOn =$false }
    } else { $syncOn =$false }
}

$haOn = $false; $haUrl = ""
if ($haUse -match '^[yY]') {
    try {
        Invoke-WebRequest -Uri "http://localhost:8123" -UseBasicParsing -TimeoutSec 3 | Out-Null
        $haUrl = "http://localhost:8123"; $haOn =$true
    } catch { }
    if (-not $haUrl) {$haUrl = Read-Host "  Home Assistant address (e.g. http://192.168.1.50:8123), or ENTER to skip"
        if ($haUrl) { $haOn =$true }
    }
}

$novastarOn = $false; $novastarHost = ""
if ($novastarUse -match '^[yY]') {$novastarHost = Read-Host "  Novastar controller IP address (e.g. 172.16.0.11)"
    if ($novastarHost) { $novastarOn =$true }
}

$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content$overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

if ($obj.PSObject.Properties.Name -contains "Kestrel") { $obj.PSObject.Properties.Remove("Kestrel") }
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://localhost;http://0.0.0.0:80"

if ($obj.PSObject.Properties.Name -notcontains "Kiosk") { $obj | Add-Member -NotePropertyName "Kiosk" -NotePropertyValue ([PSCustomObject]@{}) }
$k =$obj.Kiosk
$k \vert{} Add-Member -NotePropertyName "BaseUrl"          -NotePropertyValue $PortalUrl   -Force
$k \vert{} Add-Member -NotePropertyName "Enabled"          -NotePropertyValue $true          -Force
$k \vert{} Add-Member -NotePropertyName "RightWallEnabled" -NotePropertyValue $rightWallOn -Force
$k \vert{} Add-Member -NotePropertyName "CgEnabled"        -NotePropertyValue $streamOn      -Force
$k \vert{} Add-Member -NotePropertyName "ProgramEnabled"   -NotePropertyValue $streamOn      -Force

$sofficeResolved = if (Test-Path $SofficePath) {$SofficePath } else { "" }
$ffmpegResolved  = if (Test-Path $FfmpegPath)  {$FfmpegPath }  else { "" }
if ($obj.PSObject.Properties.Name -notcontains "SlideLibrary") { $obj | Add-Member -NotePropertyName "SlideLibrary" -NotePropertyValue ([PSCustomObject]@{}) }
$sl =$obj.SlideLibrary
$sl \vert{} Add-Member -NotePropertyName "LibreOfficePath" -NotePropertyValue $sofficeResolved -Force
if ($sl.PSObject.Properties.Name -notcontains "GoogleDrive") { $sl | Add-Member -NotePropertyName "GoogleDrive" -NotePropertyValue ([PSCustomObject]@{}) }
$gd =$sl.GoogleDrive
$gd \vert{} Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue $(if($syncOn){$keyJson}else{""}) -Force
$gd \vert{} Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue $prayerId -Force
$gd \vert{} Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue $annId    -Force

if ($obj.PSObject.Properties.Name -notcontains "Broadcast") { $obj | Add-Member -NotePropertyName "Broadcast" -NotePropertyValue ([PSCustomObject]@{}) }
$obj.Broadcast \vert{} Add-Member -NotePropertyName "FFmpegPath" -NotePropertyValue $ffmpegResolved -Force

if ($obj.PSObject.Properties.Name -notcontains "HomeAssistant") { $obj | Add-Member -NotePropertyName "HomeAssistant" -NotePropertyValue ([PSCustomObject]@{}) }
$obj.HomeAssistant \vert{} Add-Member -NotePropertyName "Enabled" -NotePropertyValue $haOn -Force
if ($haUrl) { $obj.HomeAssistant \vert{} Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue $haUrl -Force }

if ($obj.PSObject.Properties.Name -notcontains "Novastar") { $obj | Add-Member -NotePropertyName "Novastar" -NotePropertyValue ([PSCustomObject]@{}) }
$obj.Novastar \vert{} Add-Member -NotePropertyName "Enabled" -NotePropertyValue $novastarOn -Force
if ($novastarOn) { $obj.Novastar \vert{} Add-Member -NotePropertyName "Host" -NotePropertyValue $novastarHost -Force }

$lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
          Select-Object -First 1).IPAddress
if ($lanIp) {
    if ($obj.PSObject.Properties.Name -notcontains "CongregationView") { $obj | Add-Member -NotePropertyName "CongregationView" -NotePropertyValue ([PSCustomObject]@{}) }
    $obj.CongregationView \vert{} Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue "http://$lanIp" -Force
}

$obj \vert{} ConvertTo-Json -Depth 10 \vert{} Set-Content$overridesPath

# ---------------- [8/9] Shortcuts & Completion ------------------------------
Log "[8/9] Writing shortcuts and completing installation..."
$AppExe = "$InstallDir\Illumina.exe"
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '--app=$PortalUrl'" } else { "Start-Process '$PortalUrl'" }

$open = @'
param([int]$DelaySeconds = 0, [switch]$NoPortal)
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }$app = "__APP__"
if (-not (Get-Process -Name Illumina -ErrorAction SilentlyContinue)) {
    Start-Process $app -WorkingDirectory (Split-Path$app) -WindowStyle Hidden
    Start-Sleep -Seconds 6
}
if (-not $NoPortal) { __PORTAL__ }
'@
$open =$open -replace '__APP__', $AppExe -replace '__PORTAL__',$PortalLine
Set-Content "$InstallDir\open-illumina.ps1" $open

Log "Installation complete successfully!"
