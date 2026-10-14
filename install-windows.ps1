<#
    Illumina AVA PC Installer - Windows 10/11 (v1.0)
    - Friendly administrator check; nothing changes before it passes
    - Provisions media engines from the internet: LibreOffice (slides),
      FFmpeg (broadcast), and Chrome itself if missing (winget)
    - Quick survey (Right Display / Drive sync / primary + secondary display
      language); ENTER takes the suggestion. Streaming/CG, smart-plug
      automation and Novastar brightness are NOT asked here - they are
      usually not set up yet on install day, and the factory defaults
      already cover them. Rotating "Did you know?" tips during the
      downloads point the user at Menu->Settings for those
    - Stamps the machine-store Kestrel HTTPS block into the per-machine
      overrides layer (AppData/AppSettingsOverrides.json) - the factory
      appsettings.json is never touched
    - Updates preserve machine state: AppData (settings + secrets),
      MediaContent, SlideContent, Recordings and any customized
      Data/Localization strings survive a re-install; the app and the
      Bible/hymn corpus refresh from the new build
    - Creates + trusts a private 100-year machine certificate and asserts
      the private-key ACL via the key FILE's ACL (works on Windows
      PowerShell 5.1, prevents ERR_CONNECTION_CLOSED)
    - Binding contract per AGENTS.md: HTTPS localhost-only + HTTP on all
      interfaces for congregation phones; one PROGRAM firewall rule for
      Illumina.exe covers every port the app binds. The congregation QR
      address is AUTO-DETECTED by the app at runtime (physical LAN NIC,
      gateway preferred) - no IP is stamped here anymore, so a DHCP
      reassignment never breaks the QR code; Settings can pin it
    - Clean [1]/[2] AVA PC account menu; surgical process handling
    - Content folders permission-locked and hidden quietly
    - Simplified, bulletproof desktop shortcuts (Native Chrome portal +
      Backend manager with friendly UI prompts)
    - Human-facing labels use "Display" and "Sabbath"; internal config keys
      keep their legacy names for backwards compatibility
#>
$ErrorActionPreference = "Stop"

# ----------------------------- CONFIG ---------------------------------------
$GitHubOwner = "nickng70"
$GitHubRepo  = "Illumina-Releases"
$AssetName   = "illumina-win-x64.zip"
$InstallDir  = "C:\Program Files\Illumina"
$MachineDir  = "C:\ProgramData\Illumina"   # update-surviving machine store
$PortalUrl   = "https://localhost"
$TokenFile   = "$MachineDir\github-token"
$SofficePath = "C:\Program Files\LibreOffice\program\soffice.exe"
$FfmpegPath  = "C:\ffmpeg\ffmpeg.exe"
# ----------------------------------------------------------------------------

function Log($m) { Write-Host "`n==> $m" -ForegroundColor Green }

# Rotating "Did you know?" tips, shown before each long download/install so
# the wait doubles as a tour of what Menu->Settings can do later.
$script:TipIndex = 0
$Tips = @(
    @("Members can follow the service on their phones - the Congregation QR",
      "overlay appears on the wall displays at your cue. Nothing to set up:",
      "it always uses this PC's live network address."),
    @("Ready to stream or record? Settings -> Displays wakes up the CG",
      "overlay and the Broadcast Encoder whenever you are - no reinstall."),
    @("Settings -> Device Setup can power LED walls on and off on a schedule",
      "with Tapo smart plugs (via Home Assistant) - the rack switches itself",
      "off after the service."),
    @("Have a Novastar video controller? Settings -> Device Setup adds",
      "day/evening brightness schedules and cabinet health monitoring -",
      "no more climbing into the rack."),
    @("Illumina speaks five languages - English, Chinese (Simplified and",
      "Traditional), Indonesian and Malay - each with its own hymn corpus",
      "and display fonts. See Settings -> Appearance."),
    @("Hymns can display top-and-bottom or side-by-side, per screen, and the",
      "Edit Hymns page proofreads every layout while you type."),
    @("A pulpit tablet becomes the speaker's console at /tablet - slide",
      "advance, laser pointer and ink annotations included."),
    @("PTZ cameras can be driven from the portal with named presets tied to",
      "broadcast scenes - one tap frames the shot."),
    @("Menu -> Check for Updates brings new features and fresh hymn/Bible",
      "content to this PC with one tap - library updates need no restart."),
    @("Capture devices (cameras, switchers) can join any broadcast scene -",
      "add them in Settings whenever your hardware arrives.")
)
function Show-Tip {
    $t = $Tips[$script:TipIndex % $Tips.Count]; $script:TipIndex++
    Write-Host ""
    Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
    Write-Host "  DID YOU KNOW?" -ForegroundColor Cyan
    foreach ($line in $t) { Write-Host "  $line" -ForegroundColor Gray }
    Write-Host "  --------------------------------------------" -ForegroundColor DarkCyan
    Write-Host ""
}

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
Write-Host "   Illumina AVA PC Installer - Windows (v1.0)     " -ForegroundColor Cyan
Write-Host "   Guided setup for a safe, self-starting AVA PC  " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Welcome! In the next few minutes this PC will become your" -ForegroundColor White
Write-Host "  church's presentation hub - displays, hymns, streaming and all." -ForegroundColor White
Write-Host "  Here is what we will do together:" -ForegroundColor White
Write-Host "   1. Fetch the latest Illumina release and its media engines," -ForegroundColor White
Write-Host "   2. Set up secure local HTTPS with a private certificate, and" -ForegroundColor White
Write-Host "   3. Match the software to your church with a few quick questions." -ForegroundColor White
Write-Host "  Sit back - most of it is automatic, everything can be adjusted" -ForegroundColor White
Write-Host "  later in Menu->Settings, and we will share a few tips while" -ForegroundColor White
Write-Host "  the downloads run." -ForegroundColor White

# ---------------- [1/9] GitHub token ----------------------------------------
Log "[1/9] Accessing GitHub Illumina repository..."
New-Item -ItemType Directory -Path $MachineDir -Force | Out-Null
if ($env:GITHUB_TOKEN) { $Token = $env:GITHUB_TOKEN; Log "Using the token from this session's environment." }
elseif (Test-Path $TokenFile) { $Token = (Get-Content $TokenFile -Raw).Trim(); Log "Reusing the token stored on this machine." }
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
Show-Tip
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
Write-Host "  display). Anything missing will be installed now."

if (Test-Path $SofficePath) { Log "LibreOffice already present." }
else {
    Log "Installing LibreOffice..."
    Show-Tip
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        winget install --id TheDocumentFoundation.LibreOffice -e --accept-source-agreements --accept-package-agreements --silent | Out-Null
        if (Test-Path $SofficePath) { Log "LibreOffice installed." } else { Write-Warning "  LibreOffice install could not be verified - install it manually if slides must convert." }
    } else { Write-Warning "  winget not available on this PC - please install LibreOffice manually after setup." }
}

if (Test-Path $FfmpegPath) { Log "FFmpeg already present." }
else {
    Log "Installing FFmpeg..."
    Show-Tip
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
    Show-Tip
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
Write-Host "      and provides the safest environment for Sabbath services."
Write-Host ""
Write-Host "  [2] Run Illumina using $interactiveUser"
Write-Host "      Uses your current Windows account ($interactiveUser)."
Write-Host "      Choose this for personal laptops or if you are just testing Illumina."

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
    Write-Host "  Auto sign-in lets the PC boot straight into Illumina without having to login."
    Write-Host "  Choose No if this is your own laptop or to disable Auto sign-in."
    if ($autoOnNow) { Write-Host "  (Auto sign-in is currently enabled for '$autoUserNow'.)" }
    $want = Read-Host "  Enable auto sign-in for $HumanUser on this PC? [y/N] (ENTER = No)"
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

# The app runs as $HumanUser and reads the GitHub token for in-app update
# checks - grant that account read access (the token was locked to
# SYSTEM/Administrators when it was stored, before the account was chosen).
if (Test-Path $TokenFile) {
    icacls $TokenFile /grant "${HumanUser}:R" | Out-Null
    Log "Granted read access to the GitHub token for $HumanUser (in-app update checks)."
}

# ---------------- [6/9] App files + content folders -------------------------
Log "[6/9] Installing Illumina and preparing its content folders..."
Show-Tip

# Move the machine's state aside before wiping, restore it after the new
# build lands. AppData holds every machine setting + secret (overrides,
# operator form, kiosk geometry); MediaContent/SlideContent/Recordings are
# the church's own libraries; Data/Localization keeps any customized UI
# strings. Everything else under Data (the Bible/hymn corpus) deliberately
# REFRESHES from the new build so content fixes reach every church.
$Preserve = Join-Path $env:TEMP ("illumina-preserve-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Preserve -Force | Out-Null
foreach ($item in @("AppData", "MediaContent", "SlideContent", "Recordings")) {
    $src = Join-Path $InstallDir $item
    if (Test-Path $src) { Move-Item $src (Join-Path $Preserve $item) -Force }
}
if (Test-Path "$InstallDir\Data\Localization") {
    New-Item -ItemType Directory -Path "$Preserve\Data" -Force | Out-Null
    Move-Item "$InstallDir\Data\Localization" "$Preserve\Data\Localization" -Force
}
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
Expand-Archive -Path $Zip -DestinationPath $InstallDir -Force
Remove-Item $Zip -Force
foreach ($item in @("AppData", "MediaContent", "SlideContent", "Recordings")) {
    $saved = Join-Path $Preserve $item
    if (Test-Path $saved) {
        $dest = Join-Path $InstallDir $item
        if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
        Move-Item $saved $dest -Force
    }
}
if (Test-Path "$Preserve\Data\Localization") {
    if (Test-Path "$InstallDir\Data\Localization") { Remove-Item "$InstallDir\Data\Localization" -Recurse -Force }
    New-Item -ItemType Directory -Path "$InstallDir\Data" -Force | Out-Null
    Move-Item "$Preserve\Data\Localization" "$InstallDir\Data\Localization" -Force
}
Remove-Item $Preserve -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$InstallDir\Data" -Force | Out-Null
Log "Machine state preserved (settings, media, slides, recordings, custom UI strings); app and Bible/hymn corpus refreshed."

foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
attrib +s +h "$InstallDir\Data" | Out-Null
Log "Content folders prepared with this machine's recommended permissions."
Set-Content "$MachineDir\current-version" $Release.tag_name

# ---------------- [7/9] Survey + certificate + machine config ---------------
Log "[7/9] Site survey, HTTPS certificate, and machine settings..."
Write-Host ""
Write-Host "  Every church is wired differently, so we ask a few quick questions."
Write-Host "  ENTER accepts the suggested default for each, and everything here can"
Write-Host "  be changed later in Menu->Settings. Streaming, smart plugs and LED"
Write-Host "  brightness are not asked here - they are usually not wired up yet on"
Write-Host "  install day, and Settings switches them on whenever you are ready."
$rightWall = Read-Host "  [1/4] Do you have a RIGHT Display (in addition to the Left Display)? [y/N] (ENTER = No)"
$sync      = Read-Host "  [2/4] Retrieve Prayer/Announcement slides from Google Drive? [y/N] (ENTER = No)"
$rightWallOn = ($rightWall -match '^[yY]')
$syncOn      = ($sync -match '^[yY]')

# Display languages. On a re-install the machine's existing choices become
# the defaults (ENTER keeps them); fresh installs default to English primary
# + Simplified Chinese secondary. Values are the app's LanguageCode enum
# names - they land in AppSettingsOverrides.json's Localization section.
$LangCodes = @("", "English", "ChineseSimplified", "ChineseTraditional", "Indonesian", "Malay")
$LangNames = @("", "English", "Simplified Chinese", "Traditional Chinese", "Bahasa Indonesia", "Bahasa Melayu")
$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
$existingLoc = $null
if (Test-Path $overridesPath) { try { $existingLoc = (Get-Content $overridesPath -Raw | ConvertFrom-Json).Localization } catch { } }
$primaryDefault = 1; $secondaryDefault = 2
if ($existingLoc -and $existingLoc.PrimaryLanguage) {
    $idx = [Array]::IndexOf($LangCodes, [string]$existingLoc.PrimaryLanguage)
    if ($idx -gt 0) { $primaryDefault = $idx }
}
if ($existingLoc -and $existingLoc.SelectedSecondaryLanguage) {
    $idx = [Array]::IndexOf($LangCodes, [string]$existingLoc.SelectedSecondaryLanguage)
    if ($idx -gt 0) { $secondaryDefault = $idx }
}

function Read-Language([string]$role, [int]$default) {
    Write-Host ""
    Write-Host "  [$role] Choose the $role display language:"
    Write-Host "        [1] English   [2] Simplified Chinese   [3] Traditional Chinese"
    Write-Host "        [4] Bahasa Indonesia   [5] Bahasa Melayu"
    $sel = Read-Host "  Press ENTER for $default ($($LangNames[$default]))"
    if ($sel -notmatch '^[1-5]$') { $sel = "$default" }
    return [int]$sel
}
$primaryIdx = Read-Language "3/4 - PRIMARY" $primaryDefault
$secondaryIdx = Read-Language "4/4 - SECONDARY" $secondaryDefault
while ($secondaryIdx -eq $primaryIdx) {
    Write-Host "  Secondary cannot be the same as primary ($($LangNames[$primaryIdx])) - please pick a different one." -ForegroundColor Yellow
    $secondaryIdx = Read-Language "4/4 - SECONDARY" $secondaryDefault
}
$primaryLang   = $LangCodes[$primaryIdx]
$secondaryLang = $LangCodes[$secondaryIdx]
Log "Survey recorded - Right Display: $rightWallOn | Drive sync: $syncOn | Languages: $($LangNames[$primaryIdx]) + $($LangNames[$secondaryIdx])"

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

Write-Host ""
Write-Host "  Illumina serves its portal over HTTPS on this PC only. We create a private"
Write-Host "  100-year certificate and trust it machine-wide, so browsers show a clean"
Write-Host "  padlock with no warnings - no internet certificate needed."
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

try {
    $rsa        = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($cert)
    $uniqueName = $rsa.Key.UniqueName
    $keyFile    = @(
        (Join-Path $env:ProgramData "Microsoft\Crypto\Keys\$uniqueName"),
        (Join-Path $env:ProgramData "Microsoft\Crypto\SystemKeys\$uniqueName")
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($keyFile) {
        icacls $keyFile /grant "*S-1-5-32-545:(R)" | Out-Null
        Log "Certificate private key readable by local users (key-file ACL asserted)."
    } else {
        Write-Warning "  Private key file for '$uniqueName' not found in the machine key store - if the portal shows ERR_CONNECTION_CLOSED, grant 'Users' Read on it manually."
    }
} catch {
    Write-Warning "  Could not adjust the certificate key ACL: $_"
}

if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

# Display languages chosen in the survey (Localization:PrimaryLanguage /
# SelectedSecondaryLanguage - the app's new-shape keys).
if ($obj.PSObject.Properties.Name -notcontains "Localization") { $obj | Add-Member -NotePropertyName "Localization" -NotePropertyValue ([PSCustomObject]@{}) }
$loc = $obj.Localization
$loc | Add-Member -NotePropertyName "PrimaryLanguage"           -NotePropertyValue $primaryLang   -Force
$loc | Add-Member -NotePropertyName "SelectedSecondaryLanguage" -NotePropertyValue $secondaryLang -Force

# The factory appsettings.json ships no Kestrel block (it must be OS-neutral),
# so the HTTPS certificate wiring lives here in the machine's overrides layer.
$kestrel = [PSCustomObject]@{
    Certificates = [PSCustomObject]@{
        Default = [PSCustomObject]@{
            Subject      = "localhost"
            Store        = "My"
            Location     = "LocalMachine"
            AllowInvalid = $true
        }
    }
}
$obj | Add-Member -NotePropertyName "Kestrel" -Force -NotePropertyValue $kestrel
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://localhost;http://0.0.0.0:80"

if ($obj.PSObject.Properties.Name -notcontains "Kiosk") { $obj | Add-Member -NotePropertyName "Kiosk" -NotePropertyValue ([PSCustomObject]@{}) }
$k = $obj.Kiosk
$k | Add-Member -NotePropertyName "BaseUrl"          -NotePropertyValue $PortalUrl   -Force
$k | Add-Member -NotePropertyName "Enabled"          -NotePropertyValue $true         -Force
$k | Add-Member -NotePropertyName "RightWallEnabled" -NotePropertyValue $rightWallOn -Force
# CgEnabled/ProgramEnabled/CgConfidenceMonitorEnabled are deliberately NOT
# stamped: the compiled-in defaults (CG + encoder on, CG monitor off) cover
# install day, Settings -> Displays owns them thereafter, and a re-install
# must never clobber what the church later chose.

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

# HomeAssistant/Novastar are likewise left to Settings -> Device Setup:
# untouched here so existing machine choices survive a re-install.

# No CongregationView:BaseUrl stamping here anymore: the app auto-detects the
# physical LAN address at runtime (CongregationViewUrlService), so a DHCP
# reassignment can never strand the congregation QR on a stale IP. Settings ->
# Application Paths remains the pin-down override for dual-LAN machines.

Log "Dependency paths stamped: LibreOffice='$sofficeResolved' FFmpeg='$ffmpegResolved'"
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath -Encoding UTF8

# ---------------- [8/9] Helpers + shortcuts ---------------------------------
Log "[8/9] Writing the everyday shortcuts..."
$AppExe = "$InstallDir\Illumina.exe"

# The Backend Manager: Kills any existing backend, starts a fresh one hidden,
# and pops up a friendly native Windows message box telling the volunteer 
# that the engine is ready and they can now open the portal.
# Takes a -Silent switch for the Startup folder (no pop-up on boot).
$backendScript = @'
param([switch]$Silent)
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
$app = "__APP__"
Start-Process -FilePath $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden

if (-not $Silent) {
    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "The Illumina backend is now running in the background.`n`nPlease double-click the 'Illumina Portal' shortcut on your desktop to open the control panel.",
        "Illumina AVA PC",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}
'@
$backendScript = $backendScript -replace '__APP__', $AppExe
Set-Content "$InstallDir\start-backend.ps1" $backendScript

if ($HumanUser -eq $env:USERNAME) {
    $UserDesktop = [Environment]::GetFolderPath("Desktop")
    $UserStartup = [Environment]::GetFolderPath("Startup")
} else {
    $UserDesktop = "C:\Users\$HumanUser\Desktop"
    $UserStartup = "C:\Users\$HumanUser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup"
    New-Item -ItemType Directory -Path $UserDesktop -Force | Out-Null
    New-Item -ItemType Directory -Path $UserStartup -Force | Out-Null
}

# Clean up old shortcuts
$spots = @([Environment]::GetFolderPath("CommonDesktopDirectory"), [Environment]::GetFolderPath("CommonStartup"), $UserDesktop, $UserStartup, "C:\Users\avauser\Desktop", "C:\Users\avauser\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup")
foreach ($spot in $spots) {
    if (Test-Path $spot) {
        Get-ChildItem $spot -Filter "Illumina*.lnk" -ErrorAction SilentlyContinue | Remove-Item -Force
        Get-ChildItem $spot -Filter "Restart*.lnk"  -ErrorAction SilentlyContinue | Remove-Item -Force
    }
}

$Wsh   = New-Object -ComObject WScript.Shell
$PsExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"

# 1. The Portal Shortcut (Native Chrome, no PowerShell wrapper)
$portal = $Wsh.CreateShortcut("$UserDesktop\Illumina Portal.lnk")
$portal.TargetPath   = $ChromeExe
$portal.Arguments    = "--app=$PortalUrl"
$portal.IconLocation = "$ChromeExe,0"
$portal.Save()

# 2. The Backend Restart Shortcut (Shows the friendly pop-up)
$restart = $Wsh.CreateShortcut("$UserDesktop\Restart Illumina Backend.lnk")
$restart.TargetPath   = $PsExe
$restart.Arguments    = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\start-backend.ps1`""
$restart.IconLocation = "shell32.dll,238" # Refresh/Restart icon
$restart.Save()

# 3. The Auto-Start Shortcut (Runs silently on boot so the engine is always ready)
$autoStart = $Wsh.CreateShortcut("$UserStartup\Illumina Backend AutoStart.lnk")
$autoStart.TargetPath = $PsExe
$autoStart.Arguments  = "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\start-backend.ps1`" -Silent"
$autoStart.Save()

Log "Shortcuts placed for $HumanUser - 'Illumina Portal' (everyday) and 'Restart Illumina Backend' (recovery)."

# ---------------- [9/9] Network, power, summary -----------------------------
Log "[9/9] Opening the network doors and keeping the PC awake..."
# One PROGRAM rule covers every port Illumina.exe binds: HTTP on the LAN for
# congregation phones + pulpit tablets, and the localhost-only HTTPS portal.
# A program rule can never go stale if ports change later. (The portal's HTTPS
# binding stays localhost-only by design - see AGENTS.md's binding contract.)
Remove-NetFirewallRule -DisplayName "Illumina Web App"      -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina Phones HTTP" -ErrorAction SilentlyContinue
Remove-NetFirewallRule -DisplayName "Illumina App"         -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName "Illumina App" -Direction Inbound -Program $AppExe -Protocol TCP -Action Allow | Out-Null
powercfg /change standby-timeout-ac 0 | Out-Null
powercfg /change monitor-timeout-ac 0 | Out-Null
Log "Firewall welcomes Illumina (congregation phones and tablets can reach this PC); sleep is disabled."

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Setup complete - Illumina $($Release.tag_name) is ready!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   AVA PC Account: $HumanUser$(if ($useAvaUser) { ' (dedicated standard account)' } else { ' (this PC''s existing account)' })"
Write-Host "   Auto sign-in  : $(if ($autoLoginOn) { 'configured' } else { 'off - normal logon screen' })"
Write-Host "   Right Display : $rightWallOn   Drive sync: $syncOn"
Write-Host "   Languages     : $($LangNames[$primaryIdx]) (primary) + $($LangNames[$secondaryIdx]) (secondary)"
Write-Host ""
Write-Host "  When you are ready for more, Menu->Settings grows with you:" -ForegroundColor Cyan
Write-Host "   - Displays       : CG overlay, Broadcast Encoder, confidence monitors" -ForegroundColor Gray
Write-Host "   - Device Setup   : Tapo smart plugs (power schedules), Novastar brightness" -ForegroundColor Gray
Write-Host "   - Appearance     : languages, hymn layouts, display fonts, themes" -ForegroundColor Gray
Write-Host "   - Check for Updates : one-tap software and hymn/Bible library updates" -ForegroundColor Gray
Write-Host ""
Write-Host "  Congratulations! You are all set! Here is how to start your first session:" -ForegroundColor Yellow
Write-Host ""
Write-Host "   1. RESTART this PC (or double-click 'Restart Illumina Backend'" -ForegroundColor White
Write-Host "      on the desktop). This starts the engine in the background." -ForegroundColor White
Write-Host ""
Write-Host "   2. Double-click the 'Illumina Portal' shortcut on the desktop." -ForegroundColor White
Write-Host "      The control panel will open, and your displays will wake up!" -ForegroundColor White
Write-Host ""
Write-Host "  From now on, the backend starts automatically every time the PC" -ForegroundColor Cyan
Write-Host "  boots. You only ever need to click the 'Illumina Portal' icon." -ForegroundColor Cyan
Write-Host ""
if ($autoLoginOn) {
    $ans = Read-Host "  Would you like to restart now to finish setup? [y/N] (ENTER = No)"
    if ($ans -match '^[yY]') { Restart-Computer }
}
