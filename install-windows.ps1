<#
    Illumina AVA PC Installer - Windows 10/11 (v8.0 FINAL)
    - Friendly administrator check; nothing changes before it passes
    - Provisions media engines from the internet: LibreOffice (slides),
      FFmpeg (broadcast), and Chrome itself if missing (winget)
    - Five-question survey (Right Display / Streaming / Drive sync /
      Home Assistant / Novastar); ENTER = No everywhere
    - Home Assistant: detect first, then address; Windows gets honest
      guidance (HA is officially Linux/VM/appliance territory)
    - Patches the INSTALLED appsettings.json with the machine-store Kestrel
      block when the release zip predates it (parse-free text insert)
    - Creates + trusts a private 100-year machine certificate and asserts
      the private key ACL so the AVA PC account can read it (prevents
      ERR_CONNECTION_CLOSED on fresh PCs)
    - Binding contract per AGENTS.md: HTTPS localhost-only + HTTP on all
      interfaces for congregation phones; QR BaseUrl auto-stamped
    - Clean [1]/[2] AVA PC account menu; surgical process handling
    - Content folders permission-locked and hidden quietly
    - Human-facing labels use "Display"; internal config keys keep their
      legacy names for backwards compatibility with deployed churches
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
$AutoOpenPortalAtLogon = $true
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
Write-Host "   Illumina AVA PC Installer - Windows (v8.0)     " -ForegroundColor Cyan
Write-Host "   Guided setup for a safe, self-starting AVA PC  " -ForegroundColor Cyan
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
# Only Chrome windows that belong to Illumina's own dedicated profiles - never
# the operator's personal browser tabs.
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Log "Previous session paused - your open browser tabs and files are untouched."

# ---------------- [5/9] AVA PC account & sign-in ----------------------------
Log "[5/9] Choosing the AVA PC account and sign-in behavior..."
Write-Host ""

$interactiveUser = $env:USERNAME
try {
    $csUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($csUser) { $interactiveUser = ($csUser -split '\\')[-1] }
} catch { }
$adminNames = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue | ForEach-Object { ($_.Name -split '\\')[-1] })
$currentUserIsAdmin = ($adminNames -contains $interactiveUser)

Write-Host "  How will this AVA PC be used?"
Write-Host ""
Write-Host "  [1] Dedicated AVA PC Account (Recommended)"
Write-Host "      Creates a clean, standard-user account named 'avauser' just for Illumina."
Write-Host "      This keeps the desktop uncluttered, prevents accidental system changes,"
Write-Host "      and provides the safest environment for Sunday services."
Write-Host ""
Write-Host "  [2] Run Illumina using $interactiveUser"
Write-Host "      Uses your current Windows account ($interactiveUser)."
Write-Host "      Ideal for personal laptops, IT testing, or initial setup by an administrator."

if (-not $currentUserIsAdmin) {
    Write-Host ""
    Write-Host "  (Note: Your current account is already a Standard user, which is perfectly safe for Option 2!)" -ForegroundColor Cyan
}
$mode = Read-Host "`n  Select setup type (press ENTER for 1)"
$useAvaUser = ($mode -ne '2')

$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$wl       = Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue
$autoOnNow   = ($wl.AutoAdminLogon -eq "1")
$autoUserNow = $wl.DefaultUserName

function Read-NewPassword([string]$what) {
    $p1 = Read-Host $what
    if (-not $p1) { return $null }
    $p2 = Read-Host "  Type it once more to confirm"
    if ($p1 -ne $p2) { throw "The two passwords did not match - nothing was changed. Please re-run the installer." }
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

$autoLoginOn = $false
if ($useAvaUser) {
    $HumanUser = "avauser"
    $existing  = Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue
    $reusable = $autoOnNow -and ($autoUserNow -eq $HumanUser) -and $wl.DefaultPassword
    if ($reusable) {
        $PlainPass = $wl.DefaultPassword
        Log "Reusing avauser's existing password (re-install detected)."
    } else {
        $PlainPass = Read-NewPassword "  Set the password for the AVA PC account ('avauser') - used for maintenance logins (typed twice to avoid typos)"
        if (-not $PlainPass) { throw "A new AVA PC account needs a password. Please re-run and provide one." }
    }
    $Sec = ConvertTo-SecureString $PlainPass -AsPlainText -Force
    if (-not $existing) {
        New-LocalUser -Name $HumanUser -FullName "AVA PC" -Password $Sec -PasswordNeverExpires | Out-Null
        Log "Created dedicated account 'avauser' (its sign-in tile reads 'AVA PC')."
    } else {
        Set-LocalUser -Name $HumanUser -Password $Sec -PasswordNeverExpires $true
        Log "Refreshed the existing AVA PC account 'avauser'."
    }
    $isAdminGrp = Get-LocalGroupMember -Group "Administrators" -Member $HumanUser -ErrorAction SilentlyContinue
    if ($isAdminGrp) {
        Remove-LocalGroupMember -Group "Administrators" -Member $HumanUser
        Log "Confirmed 'avauser' is a standard user (the AVA PC account must not be an admin)."
    } else { Log "Confirmed 'avauser' is a standard user." }
    Set-AutoLogin $HumanUser $PlainPass
    $autoLoginOn = $true
    Log "Auto sign-in configured for avauser - it activates at the next restart."
}
else {
    $HumanUser = $interactiveUser
    if ($currentUserIsAdmin) {
        Write-Host ""
        Write-Host "  NOTICE: continuing with an ADMINISTRATOR account ('$HumanUser')." -ForegroundColor Yellow
        Write-Host "  Anyone using this PC can delete or modify Illumina, change firewall rules,"
        Write-Host "  and install software without a password prompt. Supported for testing and"
        Write-Host "  special cases; not recommended for a church deployment."
    }
    Write-Host ""
    Write-Host "  Auto sign-in lets the PC boot straight into Illumina after a power cut - no"
    Write-Host "  volunteer needs to type a password on Sunday morning. On a personal laptop"
    Write-Host "  you may prefer the normal logon screen instead."
    if ($autoOnNow) { Write-Host "  (Auto sign-in is currently enabled for '$autoUserNow'.)" }
    $want = Read-Host "  Enable auto sign-in for $HumanUser on this PC? [y/N] (ENTER = No; any existing auto sign-in is then turned off)"
    if ($want -match '^[yY]') {
        $PlainPass = Read-NewPassword "  Windows password for $HumanUser, stored for auto sign-in (must be exact)"
        Set-AutoLogin $HumanUser $PlainPass
        $autoLoginOn = $true
        Log "Auto sign-in enabled for $HumanUser - it activates at the next restart."
    } else {
        Clear-AutoLogin
        Log "Auto sign-in left OFF (and any previous configuration cleared) - the PC keeps its normal logon screen."
    }
}

# ---------------- [6/9] App files + content folders -------------------------
Log "[6/9] Installing Illumina and preparing its content folders..."
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

# Belt-and-braces: Kestrel binds at host start, BEFORE the overrides layer
# loads, so the certificate config must exist in appsettings.json itself.
# PARSE-FREE ON PURPOSE: appsettings.json legitimately carries // comments
# and trailing commas - .NET's config reader accepts them, but Windows
# PowerShell 5.1's ConvertFrom-Json (and jq) do not; parsing it here crashed
# v8.0 installs at [6/9]. Insert the block as plain text only when missing.
$appSettingsPath = "$InstallDir\appsettings.json"
$raw = Get-Content $appSettingsPath -Raw
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
    $idx = $raw.IndexOf('{')
    $raw = $raw.Insert($idx + 1, $kestrelBlock)
    Set-Content -Path $appSettingsPath -Value $raw -Encoding UTF8
    Log "Patched appsettings.json with the machine-store HTTPS certificate block (text insert, no JSON parsing)."
}

foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
# Content folders: readable by the AVA PC account and administrators only, and
# marked as protected system files so they stay out of everyday view.
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
attrib +s +h "$InstallDir\Data" | Out-Null
Log "Content folders prepared with this machine's recommended permissions."
Set-Content "$MachineDir\current-version" $Release.tag_name

# ---------------- [7/9] Survey + certificate + machine config ---------------
Log "[7/9] Site survey, HTTPS certificate, and machine settings..."
Write-Host ""
Write-Host "  Every church is wired differently, so we ask five quick questions."
Write-Host "  ENTER accepts the safe default (No) for each, and everything here can"
Write-Host "  be changed later in Settings without reinstalling."
Write-Host "  Note: the CG overlay output is always prepared as part of the core"
Write-Host "  display set (like the Left Display); question 2 controls the broadcast"
Write-Host "  encoder, stream monitors and Aux Hall."
$rightWall = Read-Host "  [1/5] Is a RIGHT Display connected (in addition to the Left Display)? [y/N] (ENTER = No)"
$streaming = Read-Host "  [2/5] Is a STREAMING/BROADCAST setup used (encoder, stream monitors, Aux Hall)? [y/N] (ENTER = No)"
$sync      = Read-Host "  [3/5] Should Prayer/Announcement slides sync from Google Drive? [y/N] (ENTER = No)"
Write-Host ""
Write-Host "  Illumina can also talk to the smart hardware many churches already own."
Write-Host "  Both integrations are optional and can be switched on later in Settings."
$haUse       = Read-Host "  [4/5] Do you automate AV devices (e.g. Tapo smart switches for wall and rack power) through Home Assistant? [y/N] (ENTER = No)"
$novastarUse = Read-Host "  [5/5] Is a Novastar LED video controller on the local network (brightness schedules + cabinet health)? [y/N] (ENTER = No)"
$rightWallOn = ($rightWall -match '^[yY]')
$streamOn    = ($streaming -match '^[yY]')
$syncOn      = ($sync -match '^[yY]')
Log "Survey recorded - Right Display: $rightWallOn | Streaming: $streamOn | Drive sync: $syncOn"

# ---- Google Drive key + folder IDs (only when sync was requested) ----
$keyJson  = "$MachineDir\key.json"
$prayerId = ""; $annId = ""
if ($syncOn) {
    if (Test-Path $keyJson) { Log "Reusing the Google Drive key already stored on this machine." }
    else {
        try {
            Log "Fetching the Drive key from the private repository (secrets/drive-key.json)..."
            Invoke-WebRequest -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/contents/secrets/drive-key.json" `
                -Headers @{ Authorization = "Bearer $Token"; Accept = "application/vnd.github.raw" } -OutFile $keyJson
        } catch {
            Log "Repository download unavailable - a local copy works just as well."
            $src = Read-Host "  Path to a local key.json (USB/share/laptop), or blank to skip sync"
            if ($src -and (Test-Path $src)) { Copy-Item $src $keyJson -Force }
        }
    }
    if (Test-Path $keyJson) {
        icacls $keyJson /inheritance:r /grant:r "SYSTEM:F" "Administrators:F" "${HumanUser}:R" | Out-Null
        $prayerId = Read-Host "  Prayer slides folder ID (Google Drive)"
        $annId    = Read-Host "  Announcements slides folder ID (Google Drive)"
        if (-not $prayerId -or -not $annId) {
            $syncOn = $false
            Log "A folder ID was left empty, so Drive sync stays OFF on this machine."
        }
    } else { $syncOn = $false; Log "No Drive key available, so Drive sync stays OFF on this machine." }
}

# ---- Home Assistant: detect first, then address (Windows guides, never hacks) ----
$haOn = $false; $haUrl = ""
if ($haUse -match '^[yY]') {
    try {
        Invoke-WebRequest -Uri "http://localhost:8123" -UseBasicParsing -TimeoutSec 3 | Out-Null
        $haUrl = "http://localhost:8123"; $haOn = $true
        Log "Home Assistant detected on this PC."
    } catch { }
    if (-not $haUrl) {
        $haUrl = Read-Host "  Home Assistant address on your network (e.g. http://192.168.1.50:8123), or ENTER if not set up yet"
        if ($haUrl) { $haOn = $true; Log "Home Assistant will be reached at $haUrl" }
    }
    if (-not $haUrl) {
        Write-Host "  Home Assistant is officially supported on Linux, VMs and dedicated hardware"
        Write-Host "  (a Raspberry Pi is the church favourite). On this Windows PC we recommend one"
        Write-Host "  of those; Illumina only needs its web address, which you can add any time in"
        Write-Host "  Settings > Device Setup."
    }
}

# ---- Novastar: configure, don't conquer (token pairing stays in the portal) ----
$novastarOn = $false; $novastarHost = ""
if ($novastarUse -match '^[yY]') {
    $novastarHost = Read-Host "  Novastar controller IP address (e.g. 172.16.0.11)"
    if ($novastarHost) { $novastarOn = $true; Log "Novastar will target $novastarHost - pair the auth token later in Settings > Device Setup." }
    else { Log "No controller address given - Novastar integration left OFF." }
}

# ---- Private, machine-trusted HTTPS certificate (store-based) ----
Write-Host ""
Write-Host "  Illumina serves its portal over HTTPS on this PC only. We create a private"
Write-Host "  100-year certificate and trust it machine-wide, so browsers show a clean"
Write-Host "  padlock with no warnings - no internet certificate needed."
# Search for both old ("Kiosk") and new ("AVA PC") friendly names so re-runs don't duplicate
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -match "Illumina (Kiosk|AVA PC) HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina AVA PC HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$MachineDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$MachineDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Log "Certificate created and trusted for this machine."
} else { Log "Reusing this machine's existing HTTPS certificate." }

# ALWAYS (re)assert the private-key ACL. 
# On re-installs the cert is REUSED, so a grant placed inside the creation 
# branch silently never runs. A standard account that can't read the CNG key 
# aborts every TLS handshake (Chrome: ERR_CONNECTION_CLOSED; netstat fills 
# with loopback TIME_WAITs). 'Users' ensures whichever account runs the 
# app (avauser, standard admin) can read the key.
try {
    $rsa    = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $keyAcl = $rsa.Key.GetAccessControl()
    $rule   = New-Object System.Security.Cryptography.AccessControl.CngKeyAccessRule(
        'Users',
        [System.Security.Cryptography.AccessControl.CngKeyRights]::Read,
        [System.Security.Cryptography.AccessControl.AccessControlType]::Allow
    )
    $keyAcl.AddAccessRule($rule)
    $rsa.Key.SetAccessControl($keyAcl)
    Log "Certificate private key ACL asserted (readable by the AVA PC account)."
} catch {
    Write-Warning "  Could not adjust the certificate key ACL: $_"
}

# ---- Stamp machine truth into the overrides layer (merge, never clobber) ----
$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

if ($obj.PSObject.Properties.Name -contains "Kestrel") {
    $obj.PSObject.Properties.Remove("Kestrel")
    Log "Removed an outdated certificate override from a previous install."
}
# AGENTS.md binding contract: HTTPS on localhost only; congregation phones
# and tablets reach the plain-HTTP endpoint on every interface (port 80).
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://localhost;http://0.0.0.0:80"

if ($obj.PSObject.Properties.Name -notcontains "Kiosk") { $obj | Add-Member -NotePropertyName "Kiosk" -NotePropertyValue ([PSCustomObject]@{}) }
$k = $obj.Kiosk
$k | Add-Member -NotePropertyName "BaseUrl"          -NotePropertyValue $PortalUrl   -Force
$k | Add-Member -NotePropertyName "Enabled"          -NotePropertyValue $true         -Force
$k | Add-Member -NotePropertyName "RightWallEnabled" -NotePropertyValue $rightWallOn -Force
$k | Add-Member -NotePropertyName "CgEnabled"        -NotePropertyValue $streamOn     -Force
$k | Add-Member -NotePropertyName "ProgramEnabled"   -NotePropertyValue $streamOn     -Force
if (-not $streamOn) { $k | Add-Member -NotePropertyName "CgConfidenceMonitorEnabled" -NotePropertyValue $false -Force }

$sofficeResolved = if (Test-Path $SofficePath) { $SofficePath } else { "" }
$ffmpegResolved  = if (Test-Path $FfmpegPath)  { $FfmpegPath }  else { "" }
if ($obj.PSObject.Properties.Name -notcontains "SlideLibrary") { $obj | Add-Member -NotePropertyName "SlideLibrary" -NotePropertyValue ([PSCustomObject]@{}) }
$sl = $obj.SlideLibrary
$sl | Add-Member -NotePropertyName "LibreOfficePath" -NotePropertyValue $sofficeResolved -Force
if ($sl.PSObject.Properties.Name -notcontains "GoogleDrive") { $sl | Add-Member -NotePropertyName "GoogleDrive" -NotePropertyValue ([PSCustomObject]@{}) }
$gd = $sl.GoogleDrive
if ($syncOn) {
    $gd | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue $keyJson  -Force
    $gd | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue $prayerId -Force
    $gd | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue $annId    -Force
    Log "Drive sync configured for this machine."
} else {
    $gd | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue "" -Force
    Log "Drive sync left OFF on this machine."
}
if ($obj.PSObject.Properties.Name -notcontains "Broadcast") { $obj | Add-Member -NotePropertyName "Broadcast" -NotePropertyValue ([PSCustomObject]@{}) }
$obj.Broadcast | Add-Member -NotePropertyName "FFmpegPath" -NotePropertyValue $ffmpegResolved -Force

if ($obj.PSObject.Properties.Name -notcontains "HomeAssistant") { $obj | Add-Member -NotePropertyName "HomeAssistant" -NotePropertyValue ([PSCustomObject]@{}) }
$ha = $obj.HomeAssistant
$ha | Add-Member -NotePropertyName "Enabled" -NotePropertyValue $haOn -Force
if ($haUrl) { $ha | Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue $haUrl -Force }

if ($obj.PSObject.Properties.Name -notcontains "Novastar") { $obj | Add-Member -NotePropertyName "Novastar" -NotePropertyValue ([PSCustomObject]@{}) }
$nv = $obj.Novastar
$nv | Add-Member -NotePropertyName "Enabled" -NotePropertyValue $novastarOn -Force
if ($novastarOn) { $nv | Add-Member -NotePropertyName "Host" -NotePropertyValue $novastarHost -Force }

# Member phones reach the AVA PC over the LAN; the QR overlay and the /view
# page use CongregationView:BaseUrl, so stamp this machine's LAN address.
# Settings can refine it later (e.g. a static DNS name).
$lanIp = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
          Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
          Select-Object -First 1).IPAddress
if ($lanIp) {
    if ($obj.PSObject.Properties.Name -notcontains "CongregationView") { $obj | Add-Member -NotePropertyName "CongregationView" -NotePropertyValue ([PSCustomObject]@{}) }
    $obj.CongregationView | Add-Member -NotePropertyName "BaseUrl" -NotePropertyValue "http://$lanIp" -Force
    Log "Congregation phones will reach this PC at http://$lanIp (QR overlay + /view page)."
}

Log "Dependency paths stamped: LibreOffice='$sofficeResolved' FFmpeg='$ffmpegResolved'"
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath

# ---------------- [8/9] Helpers + shortcuts ---------------------------------
$portalAtLogon = $autoLoginOn -and $AutoOpenPortalAtLogon
Log $(if ($portalAtLogon) { "Logon behavior: app + portal open automatically (true AVA PC boot)." }
      else { "Logon behavior: app starts silently at logon; the desktop icon opens the portal." })

# --app= gives the portal its own dedicated window (never swallowed as a tab
# by a personal Chrome), with a clean title the positioner can recognize.
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '--app=$PortalUrl'" } else { "Start-Process '$PortalUrl'" }

Log "[8/9] Writing the everyday shortcuts..."
$AppExe = "$InstallDir\Illumina.exe"

$open = @'
param([int]$DelaySeconds = 0, [switch]$NoPortal)
if ($DelaySeconds -gt 0) { Start-Sleep -Seconds $DelaySeconds }
$app = "__APP__"
if (-not (Get-Process -Name Illumina -ErrorAction SilentlyContinue)) {
    Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
    Start-Sleep -Seconds 6
}
if (-not $NoPortal) { __PORTAL__ }
'@
$open = $open -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine
Set-Content "$InstallDir\open-illumina.ps1" $open

$restart = @'
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force "$env:TEMP\IlluminaKiosk" -ErrorAction SilentlyContinue
$app = "__APP__"
Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
Start-Sleep -Seconds 6
__PORTAL__
'@
$restart = $restart -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine
Set-Content "$InstallDir\restart-illumina.ps1" $restart

if ($HumanUser -eq $env:USERNAME) {
    $UserDesktop = [Environment]::GetFolderPath("Desktop")
    $UserStartup = [Environment]::GetFolderPath("Startup")
} else {
    $UserDesktop = "C:\Users\$HumanUser\Desktop"
    $UserStartup = "C:\Users\$HumanUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    New-Item -ItemType Directory -Path $UserDesktop -Force | Out-Null
    New-Item -ItemType Directory -Path $UserStartup -Force | Out-Null
}
$spots = @(
    [Environment]::GetFolderPath("CommonDesktopDirectory"),
    [Environment]::GetFolderPath("CommonStartup"),
    $UserDesktop,
    $UserStartup,
    "C:\Users\avauser\Desktop",
    "C:\Users\avauser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
)
foreach ($spot in $spots) {
    if (Test-Path $spot) {
        Get-ChildItem $spot -Filter "Illumina*.lnk"         -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $spot -Filter "Restart Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}
$Wsh   = New-Object -ComObject WScript.Shell
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

$s = $Wsh.CreateShortcut("$UserDesktop\Illumina.lnk")
$s.TargetPath   = $PsExe
$s.Arguments    = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\open-illumina.ps1`""
$s.IconLocation = $(if ($ChromeExe) { "$ChromeExe,0" } else { "shell32.dll,14" })
$s.Save()

$r = $Wsh.CreateShortcut("$UserDesktop\Restart Illumina (if misbehaving).lnk")
$r.TargetPath   = $PsExe
$r.Arguments    = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\restart-illumina.ps1`""
$r.IconLocation = "shell32.dll,238"
$r.Save()

$a = $Wsh.CreateShortcut("$UserStartup\Illumina Startup.lnk")
$a.TargetPath = $PsExe
$a.Arguments  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\open-illumina.ps1`" -DelaySeconds $LogonDelaySeconds" + $(if ($portalAtLogon) { "" } else { " -NoPortal" })
$a.Save()
Log "Shortcuts placed for $HumanUser - 'Illumina' (everyday) and 'Restart Illumina' (recovery)."

# ---------------- [9/9] Network, power, summary -----------------------------
Log "[9/9] Opening the network doors and keeping the PC awake..."
Remove-NetFirewallRule -DisplayName "Illumina Web App"      -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina Phones HTTP" -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Illumina Web App"      -Direction Inbound -LocalPort $HttpPort -Protocol TCP -Action Allow | Out-Null
New-NetFirewallRule -DisplayName "Illumina Phones HTTP" -Direction Inbound -LocalPort 80      -Protocol TCP -Action Allow | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null
Log "Firewall allows the portal (443) and congregation phones (80); sleep is disabled."

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Setup complete - Illumina $($Release.tag_name) is ready!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   AVA PC Account: $HumanUser$(if ($useAvaUser) { ' (dedicated standard account)' } else { ' (this PC''s existing account)' })"
Write-Host "   Auto sign-in  : $(if ($autoLoginOn) { 'configured' } else { 'off - normal logon screen' })"
Write-Host "   Right Display : $rightWallOn   Streaming: $streamOn   Drive sync: $syncOn"
Write-Host "   Home Assistant: $(if ($haOn) { $haUrl } else { 'off' })   Novastar: $(if ($novastarOn) { $novastarHost } else { 'off' })"
Write-Host "   Portal        : $PortalUrl  (desktop icon 'Illumina' opens it any time)"
if ($lanIp) { Write-Host "   Phones        : http://$lanIp  (QR overlay + /view page)" }
Write-Host ""
if ($autoLoginOn) {
    Write-Host "   Auto sign-in takes effect the next time this PC restarts - for example"
    Write-Host "   after a power cut or your next planned reboot. There is nothing you need"
    Write-Host "   to do right now: the desktop icon 'Illumina' starts everything immediately"
    Write-Host "   in this session, and from the next restart onward the PC will boot"
    Write-Host "   straight into Illumina on its own."
    $ans = Read-Host "Would you like to restart now to see auto sign-in in action? [y/N] (ENTER = No)"
    if ($ans -match '^[yY]') { Restart-Computer }
} else {
    Write-Host "   No restart is needed - everything is live already. The desktop icon"
    Write-Host "   'Illumina' starts the app and opens the portal any time, and the"
    Write-Host "   'Restart Illumina' icon is the one-click recovery if a display ever"
    Write-Host "   misbehaves."
}
