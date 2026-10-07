<#
    Illumina AVA PC Installer - Windows 10/11 (v7.1 FINAL)
    - Friendly administrator check (reassures nothing was changed)
    - Surgical process handling (leaves personal Chrome alone)
    - Clean [1]/[2] menu for account selection with smart Standard-user detection
    - Auto sign-in activates at the next restart; no reboot is demanded
    - Content folders are permission-locked and hidden quietly (security-by-obscurity)
    - Minimal helpers: everyday icon starts the app; Restart icon relaunches
    - HTTPS via a private 100-year certificate in the machine store
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

# ---------------- [0/8] Administrator check ---------------------------------
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
Write-Host "   Illumina AVA PC Installer - Windows (v7.1)     " -ForegroundColor Cyan
Write-Host "   Guided setup for a safe, self-starting kiosk   " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Welcome! This installer prepares this PC to run Illumina around the"
Write-Host "  clock: it fetches the latest release, configures secure local HTTPS,"
Write-Host "  and tailors the displays to your hardware. Every question explains"
Write-Host "  itself, and pressing ENTER always accepts the safe, recommended default."

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

# ---------------- [3/8] Pause previous session ------------------------------
Log "[3/8] Pausing any running Illumina session..."
Get-Process -Name Illumina -ErrorAction SilentlyContinue | Stop-Process -Force
# Only Chrome windows that belong to Illumina's own kiosk profiles - never
# the operator's personal browser tabs.
Get-CimInstance Win32_Process -Filter "Name='chrome.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*IlluminaKiosk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 2
Get-ChildItem "C:\Users\*\AppData\Local\Temp\IlluminaKiosk" -Directory -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Log "Previous session paused - your open browser tabs and files are untouched."

# ---------------- [4/8] Kiosk account & sign-in -----------------------------
Log "[4/8] Choosing the kiosk account and sign-in behavior..."
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
    $isAdminGrp = Get-LocalGroupMember -Group "Administrators" -Member $HumanUser -ErrorAction SilentlyContinue
    if ($isAdminGrp) {
        Remove-LocalGroupMember -Group "Administrators" -Member $HumanUser
        Log "Confirmed 'avauser' is a standard user (kiosk accounts must not be admins)."
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

# ---------------- [5/8] App files + content folders -------------------------
Log "[5/8] Installing Illumina and preparing its content folders..."
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

foreach ($w in @("SlideContent", "MediaContent", "AppData", "Recordings")) {
    $p = Join-Path $InstallDir $w
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    icacls $p /grant "${HumanUser}:(OI)(CI)M" | Out-Null
}
# Content folders: readable by the kiosk account and administrators only, and
# marked as protected system files so they stay out of everyday view.
icacls "$InstallDir\Data" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F" "${HumanUser}:(OI)(CI)RX" | Out-Null
attrib +s +h "$InstallDir\Data" | Out-Null
Log "Content folders prepared with this machine's recommended permissions."
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
        Where-Object { $_.FriendlyName -eq "Illumina Kiosk HTTPS" -and $_.NotAfter -gt (Get-Date).AddMonths(1) } |
        Select-Object -First 1
if (-not $cert) {
    $cert = New-SelfSignedCertificate -DnsName "localhost" -CertStoreLocation "Cert:\LocalMachine\My" `
            -FriendlyName "Illumina Kiosk HTTPS" -NotAfter (Get-Date).AddYears(100)
    Export-Certificate -Cert $cert -FilePath "$MachineDir\illumina.cer" -Force | Out-Null
    Import-Certificate -FilePath "$MachineDir\illumina.cer" -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
    Log "Certificate created and trusted for this machine."
} else { Log "Reusing this machine's existing HTTPS certificate." }

$overridesPath = "$InstallDir\AppData\AppSettingsOverrides.json"
if (Test-Path $overridesPath) { $obj = Get-Content $overridesPath -Raw | ConvertFrom-Json }
else { $obj = [PSCustomObject]@{} }

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
$portalAtLogon = $autoLoginOn -and $AutoOpenPortalAtLogon
Log $(if ($portalAtLogon) { "Logon behavior: app + portal open automatically (true kiosk boot)." }
      else { "Logon behavior: app starts silently at logon; the desktop icon opens the portal." })

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
$PortalLine = if ($ChromeExe) { "Start-Process '$ChromeExe' -ArgumentList '--app=$PortalUrl'" } else { "Start-Process '$PortalUrl'" }

Log "[7/8] Writing the everyday shortcuts..."
$AppExe = "$InstallDir\Illumina.exe"

# Everyday icon: start the app if it isn't running, then open the portal.
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

# Restart icon: tears down and relaunches Illumina + kiosk Chrome only.
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
Write-Host "   Kiosk account : $HumanUser$(if ($useAvaUser) { ' (dedicated standard account)' } else { ' (this PC''s existing account)' })"
Write-Host "   Auto sign-in  : $(if ($autoLoginOn) { 'configured' } else { 'off - normal logon screen' })"
Write-Host "   Right Wall    : $rightWallOn   Streaming: $streamOn   Drive sync: $syncOn"
Write-Host "   Portal        : $PortalUrl  (desktop icon 'Illumina' opens it any time)"
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
