#Requires -RunAsAdministrator
<#
    Illumina AVA PC Installer - Windows 10/11 (v7.0 FINAL)
    - Detects whether the logged-in user is an administrator and guides the
      operator to the safest kiosk account for THIS machine:
        * admin logged in   -> offers a dedicated standard 'avauser'
                               (auto sign-in enabled silently, by design)
        * standard logged in-> uses that account (ideal kiosk duty)
        * declining avauser -> proceeds with a clear, honest NOTICE
    - Auto sign-in is asked only for current-user installs; ENTER = No and
      any stale configuration is cleared, so the state is always known
    - Bible/Hymn data: ACL-locked to kiosk account + administrators AND
      marked System+Hidden, so Explorer hides it behind a scary warning
    - HTTPS via a private 100-year certificate in the machine store
      (Kestrel reads it from the store through appsettings.json - the
      legacy file-based pfx override is removed from old installs)
    - Site survey (Right Wall / Streaming / Drive sync), ENTER = No
    - Minimal helpers: start the exe if needed, wait, open the portal in
      its own --app window; per-user shortcuts + logon autostart
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
Write-Host "   Illumina AVA PC Installer - Windows (v7.0)     " -ForegroundColor Cyan
Write-Host "   Guided setup for a safe, self-starting kiosk   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Welcome! This installer prepares this PC to run Illumina around the"
Write-Host "  clock: it fetches the latest release, protects the Bible and Hymn"
Write-Host "  library, configures HTTPS, and tailors the displays to your hardware."
Write-Host "  Every question below explains itself, and pressing ENTER always"
Write-Host "  accepts the safe, recommended default."

# ---------------- [1/8] GitHub token ----------------------------------------
Log "[1/8] Release access token..."
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

# ---------------- [2/8] Latest release asset --------------------------------
Log "[2/8] Downloading the latest Illumina release..."
try { $Release = Invoke-RestMethod -Uri "https://api.github.com/repos/$GitHubOwner/$GitHubRepo/releases/latest" -Headers $Api }
catch { throw "Could not reach the release repository. Check the token and internet connection. $_" }
$Asset = $Release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
if (-not $Asset) { throw "Asset '$AssetName' not found in release $($Release.tag_name)." }
$Zip = Join-Path $env:TEMP $AssetName
Invoke-WebRequest -Uri $Asset.url -Headers @{ Authorization = "Bearer $Token"; Accept = "application/octet-stream" } -OutFile $Zip
Log "Release $($Release.tag_name) downloaded."

# ---------------- [3/8] Stop running instances ------------------------------
Log "[3/8] Pausing any running Illumina session..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Log "Previous session closed cleanly; your Bible/Hymn data is untouched."

# ---------------- [4/8] Kiosk account & sign-in -----------------------------
Log "[4/8] Choosing the kiosk account and sign-in behavior..."
Write-Host ""
Write-Host "  Illumina is designed to run all day, every day, unattended. For that"
Write-Host "  life, the account it runs under should be a STANDARD (non-administrator)"
Write-Host "  account: standard accounts cannot delete the app, change its permissions,"
Write-Host "  or install system-wide software - exactly the protection a church AVA PC"
Write-Host "  wants, while still letting Illumina read what it needs to display."

# Who is actually logged on at this desktop? (The installer itself runs
# elevated, so we must NOT trust our own token for this question.)
$interactiveUser = $env:USERNAME
try {
    $csUser = (Get-CimInstance Win32_ComputerSystem).UserName
    if ($csUser) { $interactiveUser = ($csUser -split '\\')[-1] }
} catch { }
$adminNames = @(Get-LocalGroupMember -Group "Administrators" -ErrorAction SilentlyContinue |
                ForEach-Object { ($_.Name -split '\\')[-1] })
$currentUserIsAdmin = ($adminNames -contains $interactiveUser)

$Winlogon = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$wl       = Get-ItemProperty $Winlogon -ErrorAction SilentlyContinue
$autoOnNow   = ($wl.AutoAdminLogon -eq "1")
$autoUserNow = $wl.DefaultUserName

# Any time we STORE a new password (registry auto-login and/or a new kiosk
# account), confirm it twice: a silent typo here means a kiosk PC that
# auto-logs into a logon screen, or an account whose password nobody knows.
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

$useAvaUser = $false
if ($currentUserIsAdmin) {
    Write-Host ""
    Write-Host "  This PC's logged-in account ('$interactiveUser') HAS administrator rights."
    Write-Host "  Running a kiosk as an administrator would let anyone at this PC delete"
    Write-Host "  or modify Illumina without any password prompt, so we recommend a"
    Write-Host "  dedicated standard kiosk account named 'avauser' instead."
    $makeAva = Read-Host "  Create the dedicated standard kiosk account 'avauser' (recommended)? [Y/n] (ENTER = Yes)"
    $useAvaUser = ($makeAva -notmatch '^[nN]')
}
else {
    Write-Host ""
    Write-Host "  This PC's logged-in account ('$interactiveUser') is already a STANDARD user -"
    Write-Host "  ideal for kiosk duty, so no extra account is needed."
    Write-Host "  Good to know: future updates and system-level maintenance will ask for"
    Write-Host "  an administrator password. That prompt is the protection working as intended."
}

if ($useAvaUser) {
    $HumanUser = "avauser"
    $existing  = Get-LocalUser -Name $HumanUser -ErrorAction SilentlyContinue
    # Reuse the stored auto-login password ONLY when it already belongs to
    # avauser - never inherit a password left behind by another account.
    $reusable = $autoOnNow -and ($autoUserNow -eq $HumanUser) -and $wl.DefaultPassword
    if ($reusable) {
        $PlainPass = $wl.DefaultPassword
        Log "Reusing avauser's existing password (re-install detected)."
    } else {
        $PlainPass = Read-NewPassword "  Set the SECRET password for avauser (used for maintenance logins; typed twice to avoid typos)"
        if (-not $PlainPass) { throw "A new kiosk account needs a password. Please re-run and provide one." }
    }
    $Sec = ConvertTo-SecureString $PlainPass -AsPlainText -Force
    if (-not $existing) {
        New-LocalUser -Name $HumanUser -FullName "AVA Kiosk" -Password $Sec -PasswordNeverExpires | Out-Null
        Log "Created kiosk account 'avauser' (its sign-in tile reads 'AVA Kiosk')."
    } else {
        Set-LocalUser -Name $HumanUser -Password $Sec -PasswordNeverExpires $true
        Log "Refreshed the existing kiosk account 'avauser'."
    }
    $isAdmin = Get-LocalGroupMember -Group "Administrators" -Member $HumanUser -ErrorAction SilentlyContinue
    if ($isAdmin) {
        Remove-LocalGroupMember -Group "Administrators" -Member $HumanUser
        Log "Confirmed 'avauser' is a standard user (kiosk accounts must not be admins)."
    } else { Log "Confirmed 'avauser' is a standard user (kiosk accounts must not be admins)." }
    Set-AutoLogin $HumanUser $PlainPass
    Log "Auto sign-in enabled for avauser - after a reboot this PC boots straight into Illumina."
}
else {
    $HumanUser = $interactiveUser
    if ($currentUserIsAdmin) {
        Write-Host ""
        Write-Host "  NOTICE: continuing with an ADMINISTRATOR kiosk account ('$HumanUser')." -ForegroundColor Yellow
        Write-Host "  Anyone using this PC can delete or modify Illumina, change firewall"
        Write-Host "  rules, and install software without a password prompt. Your Bible and"
        Write-Host "  Hymn files stay hidden and locked, but the machine itself is open."
        Write-Host "  Supported for testing and special cases; not recommended for churches."
    }
    Write-Host ""
    Write-Host "  Auto sign-in lets the PC boot straight into Illumina after a power cut -"
    Write-Host "  no volunteer needs to type a password on Sunday morning. On a personal"
    Write-Host "  laptop you may prefer the normal logon screen instead."
    if ($autoOnNow) { Write-Host "  (Auto sign-in is currently enabled for '$autoUserNow'.)" }
    $want = Read-Host "  Enable auto sign-in for $HumanUser on this PC? [y/N] (ENTER = No; any existing auto sign-in is then turned off)"
    if ($want -match '^[yY]') {
        $PlainPass = Read-NewPassword "  Windows password for $HumanUser, stored for auto sign-in (must be exact)"
        Set-AutoLogin $HumanUser $PlainPass
        Log "Auto sign-in enabled for $HumanUser."
    } else {
        Clear-AutoLogin
        Log "Auto sign-in left OFF (and any previous configuration cleared) - the PC will show its normal logon screen."
    }
}

# ---------------- [5/8] App files + data protection -------------------------
Log "[5/8] Installing Illumina and protecting its library..."
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

# Working folders the app writes at runtime (Program Files is write-protected
# for standard accounts, so the kiosk account gets explicit Modify here).
foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
# Library lockdown: readable by the kiosk account and administrators only...
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
# ...and marked as protected system files, so Explorer hides the folder
# behind the 'these files are required to run Windows' warning by default.
attrib +s +h "$InstallDir\Data" | Out-Null
Write-Host "  The Bible and Hymn library is now (a) readable only by the kiosk account"
Write-Host "  and administrators, and (b) hidden from casual browsing - Explorer shows"
Write-Host "  it only if someone deliberately reveals protected operating-system files."
Set-Content "$MachineDir\current-version" $Release.tag_name

# ---------------- [6/8] Survey + certificate + machine config ---------------
Log "[6/8] Site survey, HTTPS certificate, and machine settings..."
Write-Host ""
Write-Host "  Every church is wired differently, so we ask three quick questions."
Write-Host "  ENTER accepts the safe default (No) for each, and everything here can"
Write-Host "  be changed later in Settings > Displays without reinstalling."
$rightWall = Read-Host "  [1/3] Is a RIGHT Wall display connected (in addition to the Left Wall)? [y/N] (ENTER = No)"
$streaming = Read-Host "  [2/3] Is a STREAMING/BROADCAST output used (CG overlay + encoder + stream monitors)? [y/N] (ENTER = No)"
$sync      = Read-Host "  [3/3] Should Prayer/Announcement slides sync from Google Drive? [y/N] (ENTER = No)"
$rightWallOn = ($rightWall -match '^[yY]')
$streamOn    = ($streaming -match '^[yY]')
$syncOn      = ($sync -match '^[yY]')
Log "Survey recorded - Right Wall: $rightWallOn | Streaming: $streamOn | Drive sync: $syncOn"

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

# ---- Private, machine-trusted HTTPS certificate (store-based) ----
Write-Host ""
Write-Host "  Illumina serves its portal over HTTPS on this PC only. We create a"
Write-Host "  private 100-year certificate and trust it machine-wide, so browsers"
Write-Host "  show a clean padlock with no warnings - no internet certificate needed."
$cert = Get-ChildItem Cert:\LocalMachine\My -ErrorAction SilentlyContinue |
        Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina Kiosk HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$MachineDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$MachineDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Log "Certificate created and trusted for this machine."
} else { Log "Reusing this machine's existing HTTPS certificate." }

# ---- Stamp machine truth into the overrides layer (merge, never clobber) ----
$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

# Retire the legacy file-based certificate override from older installs:
# Kestrel now reads the certificate from the Windows store (appsettings.json),
# and a stale pfx path here could confuse it on config reloads.
if ($obj.PSObject.Properties.Name -contains "Kestrel") {
    $obj.PSObject.Properties.Remove("Kestrel")
    Log "Removed an outdated certificate override from a previous install."
}
$obj | Add-Member -NotePropertyName "Urls" -Force -NotePropertyValue "https://0.0.0.0:$HttpPort;http://0.0.0.0:80"

if ($obj.PSObject.Properties.Name -notcontains "Kiosk") { $obj | Add-Member -NotePropertyName "Kiosk" -NotePropertyValue ([PSCustomObject]@{}) }
$k = $obj.Kiosk
$k | Add-Member -NotePropertyName "BaseUrl"          -NotePropertyValue $PortalUrl   -Force
$k | Add-Member -NotePropertyName "Enabled"          -NotePropertyValue $true         -Force
$k | Add-Member -NotePropertyName "RightWallEnabled" -NotePropertyValue $rightWallOn -Force
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
    Log "Drive sync configured for this machine."
} else {
    $gd | Add-Member -NotePropertyName "ServiceAccountKeyPath" -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "PrayerFolderId"        -NotePropertyValue "" -Force
    $gd | Add-Member -NotePropertyName "AnnouncementsFolderId" -NotePropertyValue "" -Force
    Log "Drive sync left OFF on this machine."
}
$obj | ConvertTo-Json -Depth 10 | Set-Content $overridesPath

# ---------------- [7/8] Helpers + shortcuts ---------------------------------
$portalAtLogon = ($useAvaUser -and $AutoOpenPortalAtLogon) -or (-not $useAvaUser -and $autoOnNow -and $AutoOpenPortalAtLogon -and ($want -match '^[yY]'))
# Simpler and truer: the portal auto-opens at logon whenever this install
# configured auto sign-in (kiosk boots straight into the service); a manual
# logon machine stays quiet and uses the desktop icon.
$portalAtLogon = $autoOnNow -or ($useAvaUser) -or ($want -match '^[yY]')
if (-not $useAvaUser -and -not ($want -match '^[yY]')) { $portalAtLogon = $false }
Log $(if ($portalAtLogon) { "Logon behavior: app + portal open automatically (true kiosk boot)." }
      else { "Logon behavior: app starts silently at logon; open the portal with the desktop icon." })

function Resolve-Chrome {
    foreach ($c in @("C:\Program Files\Google\Chrome\Application\chrome.exe",
                     "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
                     "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) { if (Test-Path $c) { return $c } }
    $ap = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe" -ErrorAction SilentlyContinue
    if ($ap -and $ap.'(default)' -and (Test-Path $ap.'(default)')) { return $ap.'(default)' }
    return $null
}
$ChromeExe = Resolve-Chrome
if (-not $ChromeExe) { Write-Warning "Chrome not found - the portal will open in the default browser." }
# --app= gives the portal its own dedicated window (never swallowed as a tab
# by a personal Chrome), with a clean title the positioner can recognize.
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '--app=$PortalUrl'" } else { "Start-Process '$PortalUrl'" }

Log "[7/8] Writing the everyday shortcuts..."
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
Get-Process -Name chrome   -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force "$env:TEMP\IlluminaKiosk" -ErrorAction SilentlyContinue
$app = "__APP__"
Start-Process $app -WorkingDirectory (Split-Path $app) -WindowStyle Hidden
Start-Sleep -Seconds 6
__PORTAL__
'@
$restart = $restart -replace '__APP__', $AppExe -replace '__PORTAL__', $PortalLine
Set-Content "$InstallDir\restart-illumina.ps1" $restart

# Shortcuts live in the KIOSK account's own profile: maintenance logins by
# other accounts stay clean, and two accounts never start each other's runs.
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
Log "Shortcuts placed for $HumanUser: 'Illumina' (everyday) and 'Restart Illumina' (emergency)."

# ---------------- [8/8] Network, power, summary -----------------------------
Log "[8/8] Opening the network doors and keeping the PC awake..."
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
Write-Host "   Kiosk account : $HumanUser$(if ($useAvaUser) { ' (dedicated standard account)' } else { ' (this PC''s logged-in account)' })"
Write-Host "   Auto sign-in  : $(if ($autoOnNow -or ($want -match '^[yY]') -or $useAvaUser) { 'ON - boots straight into Illumina after reboot' } else { 'OFF - normal logon screen' })"
Write-Host "   Right Wall    : $rightWallOn   Streaming: $streamOn   Drive sync: $syncOn"
Write-Host "   Portal        : $PortalUrl  (desktop icon 'Illumina' opens it any time)"
Write-Host "   Library       : hidden + locked at $InstallDir\Data"
Write-Host ""
Write-Host "   Remember: auto sign-in and the new shortcuts take effect at the NEXT"
Write-Host "   reboot. When in doubt later, the desktop icon 'Restart Illumina'"
Write-Host "   always brings every display back to life."
$ans = Read-Host "Reboot now to finish? [y/N] (ENTER = No - reboot when convenient)"
if ($ans -match '^[yY]') { Restart-Computer }
