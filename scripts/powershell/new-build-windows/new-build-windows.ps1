#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Provisioning script for a new Windows PC build.

.DESCRIPTION
    Debloats Microsoft and OEM (Dell/HP/Lenovo/Samsung) preinstalled apps,
    runs Windows Update (including driver updates), installs the NinjaRMM
    agent from a prompted URL, installs Microsoft 365 Apps for Business
    (Word, Excel, PowerPoint, Outlook classic, OneDrive, Teams), Chrome
    and Adobe Acrobat Reader, pins the core apps to the taskbar, adjusts
    power settings so the device never sleeps on AC, applies the itm
    desktop wallpaper and account picture from PNGs bundled alongside
    this script, and cleans temp files.

.NOTES
    Run from an elevated PowerShell prompt on the local "itm" admin account
    described in documentation/new-build-windows.md. A reboot is recommended
    after the script finishes.
#>

[CmdletBinding()]
param(
    [string]$NinjaInstallerUrl,
    [string]$OdtUrl,
    [ValidateSet("Current", "MonthlyEnterprise", "SemiAnnual")]
    [string]$OfficeChannel = "Current",
    [ValidateSet(
        "O365BusinessRetail",            # Microsoft 365 Business Standard / Premium
        "O365BusinessEEANoTeamsRetail",  # Microsoft 365 Apps for business (EEA, incl. Ireland)
        "O365ProPlusRetail",             # Microsoft 365 Apps for Enterprise / E3 / E5
        "O365ProPlusEEANoTeamsRetail"    # Apps for Enterprise / E3 / E5 (EEA)
    )]
    [string]$OfficeProductId = "O365BusinessRetail",
    [ValidateRange(10, 240)]
    [int]$OfficeTimeoutMinutes = 90,
    [ValidateRange(5, 240)]
    [int]$WindowsUpdateTimeoutMinutes = 120,
    # Run only these step numbers (e.g. -Only 10 or -Only 9,10). Empty = run all.
    [int[]]$Only,
    # Skip these step numbers (e.g. -Skip 4,6). Ignored for any step listed in -Only.
    [int[]]$Skip
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$stepResults = New-Object System.Collections.Generic.List[object]
$reportDir = "C:\itm-build"
$reportFile = "new-build-{0}.txt" -f (Get-Date -Format "ddMMyyyy-HHmm")
$reportPath = Join-Path $reportDir $reportFile
$transcriptStarted = $false
$workDir = Join-Path $env:TEMP "itm-build"

# Script-bundled assets (copied alongside this .ps1, e.g. C:\temp\new-build-windows\)
$assetsDir = $PSScriptRoot
$wallpaperSource = Join-Path $assetsDir "itm-wallpaper.png"
$profilePicSource = Join-Path $assetsDir "itm-profile.png"

try {
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $workDir)) {
        New-Item -ItemType Directory -Path $workDir -Force | Out-Null
    }

    Start-Transcript -Path $reportPath -Append | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Could not start transcript logging at '$reportPath': $($_.Exception.Message)"
}

$itmBanner = @'

                      ===
                    =---==
                   -==----==
                 ===-===---=-=   ==                   =
               ====---===--=---=  ===               ==-===    ##
             =======-=-=-==-=-==-=  ====            ==--==    ##
           ======-=-=-  =--=-=----==  =-==            =      ###              #####      ####
         ========-==      =-=-=-=----=  =---         ###    #########   ############# ##########
       ===========          -=-===-==--=  ==---      ###      ##        ####       ####       ###
    ===========-               ---==--=--=   ==-=    ###      ##        ###         ##         ##
    ============               ---=--==--==  =--=    ###      ##        ###         ##         ##
       ===========           =====--==-=   ---=      ###      ##        ###         ##         ##
         ========-==      =-----=---==   -=-         ###      ##        ###         ##         ##
           ========-==   =-==--=-===  ==-=           ###      ##        ###         ##         ##
             =====---=--=--==-==-=  -===             ###      ###       ###         ##         ##
               ======-=-=--=---=  ===                 #        #######   ##         ##         ##
                 =-=-=-=-==-==   ==
                   -=-=--===
                    ==-=-=
                      =-=

'@
Write-Host $itmBanner -ForegroundColor DarkYellow

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "STEP")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        "ERROR" { Write-Host "[$timestamp] [ERROR] $Message" -ForegroundColor Red }
        "WARN"  { Write-Host "[$timestamp] [WARN ] $Message" -ForegroundColor DarkYellow }
        "STEP"  { Write-Host "[$timestamp] [STEP ] $Message" -ForegroundColor Yellow }
        default { Write-Host "[$timestamp] [INFO ] $Message" }
    }
}

function Invoke-Step {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Number,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [scriptblock]$Action
    )

    $label = "Step $Number"

    if ($Only -and ($Only.Count -gt 0) -and ($Only -notcontains $Number)) {
        $stepResults.Add([pscustomobject]@{
                Step     = $Number
                Name     = $Name
                Status   = "SKIPPED"
                Duration = 0
                Detail   = "Not in -Only list"
            }) | Out-Null
        Write-Log -Message "$label ($Name) skipped - not in -Only list."
        return
    }
    if ($Skip -and ($Skip -contains $Number)) {
        $stepResults.Add([pscustomobject]@{
                Step     = $Number
                Name     = $Name
                Status   = "SKIPPED"
                Duration = 0
                Detail   = "Listed in -Skip"
            }) | Out-Null
        Write-Log -Message "$label ($Name) skipped via -Skip."
        return
    }

    $started = Get-Date
    Write-Log -Level STEP -Message "${label}: $Name"

    try {
        & $Action
        $duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        $stepResults.Add([pscustomobject]@{
                Step     = $Number
                Name     = $Name
                Status   = "SUCCESS"
                Duration = $duration
                Detail   = ""
            }) | Out-Null
        Write-Log -Message "$label completed successfully in $duration sec."
    }
    catch {
        $duration = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
        $errorMessage = $_.Exception.Message
        $stepResults.Add([pscustomobject]@{
                Step     = $Number
                Name     = $Name
                Status   = "FAILED"
                Duration = $duration
                Detail   = $errorMessage
            }) | Out-Null
        Write-Log -Level ERROR -Message "$label failed after $duration sec. $errorMessage"
    }
}

function Remove-AppxByPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Patterns
    )

    foreach ($pattern in $Patterns) {
        $packages = @()
        try {
            $packages = @(Get-AppxPackage -AllUsers -Name $pattern -ErrorAction SilentlyContinue)
        }
        catch {
            Write-Log -Level WARN -Message "Get-AppxPackage failed for '$pattern': $($_.Exception.Message)"
            continue
        }

        foreach ($pkg in $packages) {
            try {
                Write-Log -Message "Removing Appx package: $($pkg.Name)"
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-Log -Level WARN -Message "Failed to remove '$($pkg.Name)': $($_.Exception.Message)"
            }
        }

        try {
            $provisioned = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like $pattern })
            foreach ($prov in $provisioned) {
                Write-Log -Message "Removing provisioned package: $($prov.DisplayName)"
                Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
            }
        }
        catch {
            Write-Log -Level WARN -Message "Provisioned package cleanup for '$pattern' failed: $($_.Exception.Message)"
        }
    }
}

function Get-InstalledPrograms {
    $keys = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $programs = @()
    foreach ($key in $keys) {
        try {
            # StrictMode rejects $_.DisplayName when the property is missing on a registry entry,
            # so gate on PSObject.Properties first.
            $programs += Get-ItemProperty -Path $key -ErrorAction SilentlyContinue |
                Where-Object {
                    ($_.PSObject.Properties.Name -contains 'DisplayName') -and
                    -not [string]::IsNullOrWhiteSpace($_.DisplayName)
                } |
                ForEach-Object {
                    [pscustomobject]@{
                        DisplayName          = $_.DisplayName
                        UninstallString      = if ($_.PSObject.Properties.Name -contains 'UninstallString') { $_.UninstallString } else { $null }
                        QuietUninstallString = if ($_.PSObject.Properties.Name -contains 'QuietUninstallString') { $_.QuietUninstallString } else { $null }
                        PSChildName          = $_.PSChildName
                        Publisher            = if ($_.PSObject.Properties.Name -contains 'Publisher') { $_.Publisher } else { $null }
                    }
                }
        }
        catch {
            Write-Log -Level WARN -Message "Could not enumerate '$key': $($_.Exception.Message)"
        }
    }
    return $programs
}

function Uninstall-ProgramByPattern {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$NamePatterns
    )

    $programs = Get-InstalledPrograms
    foreach ($pattern in $NamePatterns) {
        $matched = @($programs | Where-Object { $_.DisplayName -like $pattern })
        foreach ($program in $matched) {
            $displayName = $program.DisplayName
            $uninstall = if ($program.QuietUninstallString) { $program.QuietUninstallString } else { $program.UninstallString }
            if (-not $uninstall) {
                Write-Log -Level WARN -Message "No uninstall string for '$displayName'. Skipping."
                continue
            }

            try {
                Write-Log -Message "Uninstalling: $displayName"
                if ($uninstall -match "^MsiExec(\.exe)?\s+(.*)$") {
                    $msiArgs = $Matches[2]
                    if ($msiArgs -notmatch "/qn|/quiet") { $msiArgs = "$msiArgs /qn /norestart" }
                    Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -NoNewWindow
                }
                else {
                    $cmd = $uninstall
                    if ($cmd -notmatch "/S|/silent|/quiet|/qn") { $cmd = "$cmd /S" }
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -NoNewWindow
                }
            }
            catch {
                Write-Log -Level WARN -Message "Failed to uninstall '$displayName': $($_.Exception.Message)"
            }
        }
    }
}

function Test-WingetAvailable {
    $cmd = Get-Command winget -ErrorAction SilentlyContinue
    return [bool]$cmd
}

function Invoke-HttpDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile,
        [int]$MinBytes = 1024
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ok = $false
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing `
            -UserAgent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36" `
            -MaximumRedirection 10 -ErrorAction Stop
        $ok = $true
    }
    catch {
        Write-Log -Level WARN -Message "Invoke-WebRequest failed for '$Uri' ($($_.Exception.Message)). Falling back to curl.exe."
    }

    if (-not $ok) {
        $curlExe = Join-Path $env:SystemRoot "System32\curl.exe"
        if (-not (Test-Path -LiteralPath $curlExe)) {
            throw "curl.exe is not available; cannot download '$Uri'."
        }
        & $curlExe -L --fail --silent --show-error -o $OutFile $Uri
        if ($LASTEXITCODE -ne 0) {
            throw "curl.exe failed to download '$Uri' (exit $LASTEXITCODE)."
        }
    }

    if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -lt $MinBytes) {
        throw "Download of '$Uri' produced an empty or missing file."
    }
}

function Test-ProgramInstalled {
    param([Parameter(Mandatory = $true)][string]$NamePattern)
    $found = @(Get-InstalledPrograms | Where-Object { $_.DisplayName -like $NamePattern })
    return ($found.Count -gt 0)
}

function Install-WingetPackage {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [string]$Scope = "machine"
    )

    if (-not (Test-WingetAvailable)) {
        throw "winget is not available on this machine."
    }

    Write-Log -Message "winget install $Id (scope: $Scope)"
    $args = @(
        "install", "--id", $Id,
        "--exact",
        "--source", "winget",
        "--accept-package-agreements",
        "--accept-source-agreements",
        "--silent",
        "--scope", $Scope
    )
    & winget @args
    $code = $LASTEXITCODE
    # 0 = success; -1978335189 (0x8A15002B) = no applicable upgrade / already installed
    if ($code -ne 0 -and $code -ne -1978335189) {
        throw "winget install '$Id' failed with exit code $code"
    }
}

function Get-FreeSpaceMB {
    param([string]$DriveLetter = "C")
    try {
        $drive = Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction Stop
        return [math]::Round($drive.Free / 1MB, 0)
    }
    catch {
        return -1
    }
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ArgumentList,
        [int]$TimeoutMinutes = 60,
        [int]$HeartbeatSeconds = 30,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log -Message "Running with ${TimeoutMinutes}-min timeout: $FilePath $ArgumentList"
    $proc = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    $maxSeconds = $TimeoutMinutes * 60
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $proc.HasExited) {
        Start-Sleep -Seconds $HeartbeatSeconds
        $proc.Refresh()
        if ($proc.HasExited) { break }
        $elapsed = [math]::Round($sw.Elapsed.TotalMinutes, 1)
        Write-Log -Message "$FilePath still running ($elapsed min elapsed)..."
        if ($sw.Elapsed.TotalSeconds -ge $maxSeconds) {
            try { $proc.Kill() } catch {}
            throw "$FilePath exceeded ${TimeoutMinutes}-min timeout and was terminated."
        }
    }

    $exit = $proc.ExitCode
    Write-Log -Message "$FilePath finished in $([math]::Round($sw.Elapsed.TotalMinutes,1)) min (exit $exit)."
    if ($AllowedExitCodes -notcontains $exit) {
        throw "$FilePath failed with exit code $exit."
    }
    return $exit
}

Write-Log -Message "Starting new-build-windows provisioning..."
$manufacturer = ""
try {
    $manufacturer = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer
    Write-Log -Message "Detected manufacturer: $manufacturer"
}
catch {
    Write-Log -Level WARN -Message "Could not detect manufacturer: $($_.Exception.Message)"
}

Invoke-Step -Number 1 -Name "Set power plan to never sleep on AC" -Action {
    & powercfg.exe /change standby-timeout-ac 0
    & powercfg.exe /change hibernate-timeout-ac 0
    & powercfg.exe /change disk-timeout-ac 0
    & powercfg.exe /change monitor-timeout-ac 15
    Write-Log -Message "AC sleep/hibernate/disk timeouts set to 0; monitor timeout 15 min."
}

Invoke-Step -Number 2 -Name "Remove Microsoft consumer bloatware" -Action {
    $msBloat = @(
        "Microsoft.3DBuilder",
        "Microsoft.BingFinance",
        "Microsoft.BingNews",
        "Microsoft.BingSports",
        "Microsoft.BingWeather",
        "Microsoft.BingSearch",
        "Microsoft.Getstarted",
        "Microsoft.GetHelp",
        "Microsoft.Messaging",
        "Microsoft.Microsoft3DViewer",
        "Microsoft.MicrosoftOfficeHub",
        "Microsoft.MicrosoftSolitaireCollection",
        "Microsoft.MixedReality.Portal",
        "Microsoft.NetworkSpeedTest",
        "Microsoft.Office.Sway",
        "Microsoft.OneConnect",
        "Microsoft.People",
        "Microsoft.Print3D",
        "Microsoft.SkypeApp",
        "Microsoft.Wallet",
        "Microsoft.WindowsAlarms",
        "Microsoft.WindowsCommunicationsApps",
        "Microsoft.WindowsFeedbackHub",
        "Microsoft.WindowsMaps",
        "Microsoft.WindowsSoundRecorder",
        "Microsoft.Xbox.TCUI",
        "Microsoft.XboxApp",
        "Microsoft.XboxGameOverlay",
        "Microsoft.XboxGamingOverlay",
        "Microsoft.XboxIdentityProvider",
        "Microsoft.XboxSpeechToTextOverlay",
        "Microsoft.YourPhone",
        "Microsoft.ZuneMusic",
        "Microsoft.ZuneVideo",
        "Microsoft.MicrosoftStickyNotes",
        "Microsoft.Todos",
        "Clipchamp.Clipchamp",
        "MicrosoftTeams",
        "MSTeams",
        "*LinkedInforWindows*",
        "*CandyCrush*",
        "*Disney*",
        "*Spotify*",
        "*Netflix*",
        "*TikTok*",
        "*Facebook*",
        "*Twitter*",
        "*EclipseManager*",
        "*ActiproSoftwareLLC*",
        "*AdobePhotoshopExpress*",
        "*Duolingo*",
        "*PandoraMediaInc*",
        "*BubbleWitch3Saga*",
        "*Wunderlist*",
        "*Minecraft*",
        "*Asphalt*",
        "*RoyalRevolt*",
        "*Shazam*",
        "*Sway*",
        "*Dolby*"
    )
    Remove-AppxByPattern -Patterns $msBloat
}

Invoke-Step -Number 3 -Name "Remove OEM bloatware (Dell/HP/Lenovo/Samsung)" -Action {
    $appxPatterns = @(
        # Dell
        "*DellInc*", "*DellCustomerConnect*", "*DellDigitalDelivery*",
        "*DellMobileConnect*", "*DellOptimizer*", "*MyDell*", "*PartnerPromo*",
        "*DellSupportAssist*",
        # HP
        "AD2F1837.HPJumpStarts", "AD2F1837.HPPCHardwareDiagnosticsWindows",
        "AD2F1837.HPPowerManager", "AD2F1837.HPPrivacySettings", "AD2F1837.HPSupportAssistant",
        "AD2F1837.HPSureShieldAI", "AD2F1837.HPSystemInformation", "AD2F1837.HPQuickDrop",
        "AD2F1837.HPWorkWell", "AD2F1837.myHP", "AD2F1837.HPDesktopSupportUtilities",
        "AD2F1837.HPEasyClean", "AD2F1837.HPPCHardwareDiagnosticsWindows",
        "*HPJumpStart*", "*HPInc*",
        # Lenovo
        "E046963F.LenovoCompanion", "E046963F.LenovoSettingsforEnterprise",
        "E0469640.SmartAppearance", "E046963F.LenovoCompanion", "*LenovoVantage*",
        "*LenovoUtility*", "*LenovoNow*", "*LenovoWelcome*", "*LenovoSmartPrivacy*",
        "*LenovoCommercialVantage*",
        # Samsung
        "*SamsungElectronics*", "*SamsungFlow*", "*SamsungNotes*",
        "*SamsungUpdate*", "*SamsungSettings*", "*SamsungSecurity*"
    )
    Remove-AppxByPattern -Patterns $appxPatterns

    $programPatterns = @(
        # Dell
        "Dell SupportAssist*", "Dell Update*", "Dell Digital Delivery*",
        "Dell Customer Connect*", "Dell Mobile Connect*", "Dell Optimizer*",
        "DellInc.PartnerPromo*", "Dell Core Services", "Dell Power Manager*",
        # HP
        "HP Support Assistant*", "HP JumpStart*", "HP Audio Switch*",
        "HP Documentation*", "HP Wolf Security*", "HP Connection Optimizer*",
        "HP Client Security Manager*", "HP Notifications*", "HP Sure Recover*",
        "HP Sure Run*", "HP Sure Sense*", "myHP*",
        # Lenovo
        "Lenovo Vantage*", "Lenovo Smart*", "Lenovo Now*", "Lenovo Welcome*",
        "Lenovo Utility*", "Lenovo Commercial Vantage*", "Lenovo Voice*",
        "Lenovo Migration Assistant*",
        # Samsung
        "Samsung Flow*", "Samsung Notes*", "Samsung Update*", "Samsung Settings*",
        # Preinstalled AVs
        "McAfee*", "Norton*", "NortonLifeLock*", "WildTangent*", "ExpressVPN*"
    )
    Uninstall-ProgramByPattern -NamePatterns $programPatterns
}

Invoke-Step -Number 4 -Name "Install Windows updates (including drivers)" -Action {
    if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
        Write-Log -Message "Installing PSWindowsUpdate module (NuGet provider may be required)..."
        try {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction SilentlyContinue | Out-Null
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
            Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers -ErrorAction Stop
        }
        catch {
            throw "Could not install PSWindowsUpdate: $($_.Exception.Message)"
        }
    }

    Import-Module PSWindowsUpdate -Force
    # Register Microsoft Update service so driver updates are offered
    try {
        Add-WUServiceManager -MicrosoftUpdate -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    }
    catch {
        Write-Log -Level WARN -Message "Could not register Microsoft Update service: $($_.Exception.Message)"
    }

    $job = Start-Job -ScriptBlock {
        Import-Module PSWindowsUpdate -Force
        Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot -Verbose
    }

    $deadline = (Get-Date).AddMinutes($WindowsUpdateTimeoutMinutes)
    while ($job.State -eq "Running" -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        Write-Log -Message "Windows Update still running..."
    }

    if ($job.State -eq "Running") {
        Stop-Job -Job $job -ErrorAction SilentlyContinue
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        throw "Windows Update exceeded timeout of $WindowsUpdateTimeoutMinutes minutes."
    }

    Receive-Job -Job $job -Keep | Out-String | Write-Host
    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    Write-Log -Message "Windows Update pass completed. A second pass after reboot is recommended."
}

Invoke-Step -Number 5 -Name "Download and install NinjaRMM agent" -Action {
    $url = $NinjaInstallerUrl
    if (-not $url) {
        $url = Read-Host -Prompt "Paste the NinjaRMM installer URL (from Ninja admin > Add a device)"
    }

    if (-not $url -or $url -notmatch '^(https?)://') {
        throw "NinjaRMM URL was not provided or is invalid."
    }

    $extension = [System.IO.Path]::GetExtension(($url -split '\?')[0])
    if ([string]::IsNullOrWhiteSpace($extension)) { $extension = ".msi" }
    $installerPath = Join-Path $workDir ("NinjaRMM-Installer" + $extension)

    Write-Log -Message "Downloading NinjaRMM installer to $installerPath"
    try {
        Invoke-HttpDownload -Uri $url -OutFile $installerPath
    }
    catch {
        throw "NinjaRMM download failed: $($_.Exception.Message). The URL may have expired - regenerate it in Ninja (Add a device > copy fresh link)."
    }

    if ($extension -ieq ".msi") {
        Write-Log -Message "Installing NinjaRMM via msiexec (silent)..."
        $proc = Start-Process -FilePath "msiexec.exe" -ArgumentList "/i `"$installerPath`" /qn /norestart" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "NinjaRMM msiexec install failed with exit code $($proc.ExitCode)."
        }
    }
    else {
        Write-Log -Message "Installing NinjaRMM via exe (silent)..."
        $proc = Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait -PassThru -NoNewWindow
        if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
            throw "NinjaRMM exe install failed with exit code $($proc.ExitCode)."
        }
    }

    Write-Log -Message "NinjaRMM agent install finished."
}

Invoke-Step -Number 6 -Name "Install Microsoft 365 Apps for Business via ODT" -Action {
    # Pre-flight: Office needs ~5.5 GB of scratch space during install.
    # Fail fast with a clear message instead of hanging for 45 min and then logging
    # PipelineInsufficientDiskSpace deep in the ODT logs.
    $requiredMB = 8192  # 8 GB to leave headroom for Office + temp extraction
    $freeMB = Get-FreeSpaceMB -DriveLetter "C"
    if ($freeMB -lt 0) {
        Write-Log -Level WARN -Message "Could not determine free space on C:. Proceeding anyway."
    }
    elseif ($freeMB -lt $requiredMB) {
        throw "Insufficient disk space on C: to install Office. Required: ${requiredMB} MB (8 GB), Free: ${freeMB} MB. Free up space (clear Downloads, run Disk Cleanup, or expand the VM disk) and re-run with -Skip 4 to skip Windows Update."
    }
    else {
        Write-Log -Message "Disk space check passed: ${freeMB} MB free on C: (need ${requiredMB} MB)."
    }

    $odtDir = Join-Path $workDir "ODT"
    if (-not (Test-Path -LiteralPath $odtDir)) {
        New-Item -ItemType Directory -Path $odtDir -Force | Out-Null
    }

    # MS rotates ODT download URLs. Accept a parameter, fall back to prompt.
    $odtDownloadUrl = $OdtUrl
    if (-not $odtDownloadUrl) {
        Write-Host ""
        Write-Host "The Office Deployment Tool URL changes with each release." -ForegroundColor Yellow
        Write-Host "  1. Open https://www.microsoft.com/en-us/download/details.aspx?id=49117" -ForegroundColor Gray
        Write-Host "  2. Click Download, then copy the resulting 'download.microsoft.com/...' URL." -ForegroundColor Gray
        $odtDownloadUrl = Read-Host -Prompt "Paste the current ODT download URL"
    }

    if (-not $odtDownloadUrl -or $odtDownloadUrl -notmatch '^(https?)://') {
        throw "ODT URL was not provided or is invalid."
    }

    $odtExe = Join-Path $odtDir "ODTSetup.exe"
    Write-Log -Message "Downloading Office Deployment Tool..."
    Invoke-HttpDownload -Uri $odtDownloadUrl -OutFile $odtExe -MinBytes 1048576

    Write-Log -Message "Extracting ODT..."
    Start-Process -FilePath $odtExe -ArgumentList "/extract:`"$odtDir`" /quiet" -Wait -NoNewWindow

    $setupExe = Join-Path $odtDir "setup.exe"
    if (-not (Test-Path -LiteralPath $setupExe)) {
        throw "ODT setup.exe not found after extraction."
    }

    $odtLogDir = Join-Path $reportDir "office-logs"
    if (-not (Test-Path -LiteralPath $odtLogDir)) {
        New-Item -ItemType Directory -Path $odtLogDir -Force | Out-Null
    }

    # Pre-scrub any preinstalled Click-to-Run Office (OEM trials often conflict with a fresh install).
    $existingOffice = @(Get-InstalledPrograms | Where-Object {
        $_.DisplayName -match "Microsoft (365|Office)" -and $_.DisplayName -notmatch "Deployment Tool"
    })
    if ($existingOffice.Count -gt 0) {
        Write-Log -Level WARN -Message "Existing Office installs detected; running ODT remove first."
        foreach ($e in $existingOffice) { Write-Log -Message "  - $($e.DisplayName)" }

        $removeXml = @"
<Configuration>
  <Remove All="TRUE" />
  <Display Level="None" AcceptEULA="TRUE" />
</Configuration>
"@
        $removeCfg = Join-Path $odtDir "remove.xml"
        Set-Content -Path $removeCfg -Value $removeXml -Encoding ASCII
        try {
            Invoke-ProcessWithTimeout -FilePath $setupExe -ArgumentList "/configure `"$removeCfg`"" -TimeoutMinutes 30
        }
        catch {
            Write-Log -Level WARN -Message "ODT Remove step failed or timed out: $($_.Exception.Message). Continuing with install anyway."
        }
    }

    $configXml = @"
<Configuration>
  <Add OfficeClientEdition="64" Channel="$OfficeChannel">
    <Product ID="$OfficeProductId">
      <Language ID="en-GB" />
      <ExcludeApp ID="Groove" />
      <ExcludeApp ID="Lync" />
      <ExcludeApp ID="Access" />
      <ExcludeApp ID="Publisher" />
      <ExcludeApp ID="OutlookForWindows" />
    </Product>
  </Add>
  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE" />
  <Updates Enabled="TRUE" Channel="$OfficeChannel" />
  <Display Level="None" AcceptEULA="TRUE" />
  <RemoveMSI />
</Configuration>
"@
    $configPath = Join-Path $odtDir "configuration.xml"
    Set-Content -Path $configPath -Value $configXml -Encoding ASCII

    Write-Log -Message "Running Office setup (product=$OfficeProductId, channel=$OfficeChannel). Will time out after $OfficeTimeoutMinutes min. Logs at $odtLogDir"
    try {
        Invoke-ProcessWithTimeout -FilePath $setupExe -ArgumentList "/configure `"$configPath`"" -TimeoutMinutes $OfficeTimeoutMinutes
    }
    catch {
        $errMsg = $_.Exception.Message

        # Collect candidate log files from ODT's usual locations.
        $candidateLogs = @()
        $candidateLogs += Get-ChildItem -LiteralPath $odtLogDir -Filter "*.log" -ErrorAction SilentlyContinue
        $candidateLogs += Get-ChildItem -LiteralPath "C:\Windows\Temp" -Filter "*.log" -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-2) }
        $candidateLogs = @($candidateLogs | Sort-Object LastWriteTime -Descending)

        # Scan logs for the specific ODT failure we've hit before.
        $diskSpaceHit = $null
        foreach ($log in $candidateLogs) {
            $match = Select-String -LiteralPath $log.FullName -Pattern 'PipelineInsufficientDiskSpace' -SimpleMatch -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($match) { $diskSpaceHit = $match; break }
        }

        if ($diskSpaceHit) {
            $currentFree = Get-FreeSpaceMB -DriveLetter "C"
            Write-Log -Level ERROR -Message "ODT reports PipelineInsufficientDiskSpace. Free on C: = ${currentFree} MB."
            Write-Log -Level ERROR -Message "Log line: $($diskSpaceHit.Line.Trim())"
            throw "Office install failed: insufficient disk space. Current free on C: = ${currentFree} MB. Office needs ~5.5 GB of scratch space. Clear disk space and re-run with -Skip 4 to skip Windows Update."
        }

        $latestLog = $candidateLogs | Select-Object -First 1
        if ($latestLog) {
            Write-Log -Level ERROR -Message "Last 40 lines of $($latestLog.FullName):"
            Get-Content -LiteralPath $latestLog.FullName -Tail 40 | ForEach-Object { Write-Host "    $_" }
        }
        throw "Office setup failed: $errMsg. Full logs: $odtLogDir and C:\Windows\Temp"
    }
    Write-Log -Message "Office install finished."
}

Invoke-Step -Number 7 -Name "Install Chrome and Adobe Acrobat Reader via winget" -Action {
    if (-not (Test-WingetAvailable)) {
        throw "winget is not available on this machine."
    }

    Install-WingetPackage -Id "Google.Chrome"
    if (-not (Test-ProgramInstalled -NamePattern "Google Chrome*")) {
        Write-Log -Level WARN -Message "Chrome not detected after winget install - verify manually."
    }

    $adobeInstalled = $false
    try {
        Install-WingetPackage -Id "Adobe.Acrobat.Reader.64-bit"
    }
    catch {
        Write-Log -Level WARN -Message "winget 64-bit Adobe install errored: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 5
    if (Test-ProgramInstalled -NamePattern "Adobe Acrobat*") {
        $adobeInstalled = $true
    }
    else {
        Write-Log -Level WARN -Message "Adobe Acrobat not detected after 64-bit install. Retrying with 32-bit package..."
        try {
            Install-WingetPackage -Id "Adobe.Acrobat.Reader.32-bit"
            Start-Sleep -Seconds 5
            if (Test-ProgramInstalled -NamePattern "Adobe Acrobat*") {
                $adobeInstalled = $true
            }
        }
        catch {
            Write-Log -Level WARN -Message "winget 32-bit Adobe install errored: $($_.Exception.Message)"
        }
    }

    if (-not $adobeInstalled) {
        throw "Adobe Acrobat Reader could not be installed via winget. Install manually from https://get.adobe.com/reader/enterprise/ or via Ninja."
    }
}

Invoke-Step -Number 8 -Name "Pin core apps to taskbar (via policy XML)" -Action {
    # Windows 11 22H2+ only honours taskbar pin changes via this policy XML.
    $pinXmlDir = "C:\ProgramData\itm-build"
    if (-not (Test-Path -LiteralPath $pinXmlDir)) {
        New-Item -ItemType Directory -Path $pinXmlDir -Force | Out-Null
    }
    $pinXmlPath = Join-Path $pinXmlDir "TaskbarLayout.xml"

    $xml = @'
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Outlook.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Word.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Excel.lnk" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\PowerPoint.lnk" />
        <taskbar:UWA AppUserModelID="MSTeams_8wekyb3d8bbwe!MSTeams" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="%ALLUSERSPROFILE%\Microsoft\Windows\Start Menu\Programs\Acrobat Reader.lnk" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
'@
    Set-Content -Path $pinXmlPath -Value $xml -Encoding UTF8

    $policyKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer"
    if (-not (Test-Path -LiteralPath $policyKey)) {
        New-Item -Path $policyKey -Force | Out-Null
    }
    Set-ItemProperty -Path $policyKey -Name "LockedStartLayout" -Value 0 -Type DWord
    Set-ItemProperty -Path $policyKey -Name "StartLayoutFile" -Value $pinXmlPath -Type ExpandString

    Write-Log -Message "Taskbar pin XML written to $pinXmlPath. It will apply to new user profiles on first sign-in."
    Write-Log -Level WARN -Message "Windows 11 only applies this layout to new users - existing profiles (incl. 'itm') may need to re-pin manually."
}

Invoke-Step -Number 9 -Name "Set desktop wallpaper from itm-wallpaper.png" -Action {
    if (-not (Test-Path -LiteralPath $wallpaperSource)) {
        throw "Wallpaper source not found at '$wallpaperSource'. Ensure itm-wallpaper.png is copied alongside the script."
    }

    $wallpaperDestDir = "C:\Windows\Web\Wallpaper\itm"
    if (-not (Test-Path -LiteralPath $wallpaperDestDir)) {
        New-Item -ItemType Directory -Path $wallpaperDestDir -Force | Out-Null
    }
    $wallpaperDest = Join-Path $wallpaperDestDir "itm-wallpaper.png"
    Copy-Item -LiteralPath $wallpaperSource -Destination $wallpaperDest -Force
    Write-Log -Message "Copied wallpaper to $wallpaperDest"

    $desktopKey = "HKCU:\Control Panel\Desktop"
    Set-ItemProperty -Path $desktopKey -Name "Wallpaper" -Value $wallpaperDest -Type String
    Set-ItemProperty -Path $desktopKey -Name "WallpaperStyle" -Value "10" -Type String  # 10 = Fill
    Set-ItemProperty -Path $desktopKey -Name "TileWallpaper" -Value "0" -Type String

    if (-not ("ItmWallpaperRefresh" -as [type])) {
        Add-Type @"
using System.Runtime.InteropServices;
public class ItmWallpaperRefresh {
    [DllImport("user32.dll", CharSet=CharSet.Auto)]
    public static extern int SystemParametersInfo(int uAction, int uParam, string lpvParam, int fuWinIni);
}
"@
    }
    $SPI_SETDESKWALLPAPER = 0x0014
    $SPIF_UPDATEINIFILE = 0x01
    $SPIF_SENDWININICHANGE = 0x02
    [ItmWallpaperRefresh]::SystemParametersInfo(
        $SPI_SETDESKWALLPAPER, 0, $wallpaperDest,
        ($SPIF_UPDATEINIFILE -bor $SPIF_SENDWININICHANGE)) | Out-Null

    Write-Log -Message "Wallpaper applied for current user (itm)."
}

Invoke-Step -Number 10 -Name "Set itm user account picture from itm-profile.png" -Action {
    # Per Microsoft Learn: Windows.System.UserProfile.UserInformation.SetAccountPictureAsync
    # is deprecated on Windows 10+ and its replacement Windows.System.User exposes no
    # SetPictureAsync method, so there is no supported API a provisioning script can call.
    # Settings > Accounts writes to HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\
    # AccountPicture\Users\<SID> pointing at PNGs sized 32/40/48/96/192/240/448; this step
    # reproduces that and invalidates the per-user tile cache so the change actually shows.

    if (-not (Test-Path -LiteralPath $profilePicSource)) {
        throw "Profile picture source not found at '$profilePicSource'. Ensure itm-profile.png is copied alongside the script."
    }

    $srcInfo = Get-Item -LiteralPath $profilePicSource
    Write-Log -Message "Source: $($srcInfo.FullName) ($([math]::Round($srcInfo.Length / 1KB, 1)) KB, last modified $($srcInfo.LastWriteTime))"

    Add-Type -AssemblyName System.Drawing
    $source = $null
    try {
        $source = [System.Drawing.Image]::FromFile($profilePicSource)
    }
    catch {
        throw "Could not load '$profilePicSource' as an image: $($_.Exception.Message). Confirm it's a valid PNG."
    }
    Write-Log -Message "Loaded source image: $($source.Width)x$($source.Height), pixel format $($source.PixelFormat), raw format $($source.RawFormat.Guid)"

    $itmUser = Get-LocalUser -Name "itm" -ErrorAction SilentlyContinue
    if (-not $itmUser) {
        $source.Dispose()
        throw "Local user 'itm' not found (Get-LocalUser returned nothing). Cannot assign profile picture."
    }
    $sid = $itmUser.SID.Value
    Write-Log -Message "Resolved itm user: Name='$($itmUser.Name)', Enabled=$($itmUser.Enabled), SID='$sid'"

    $destDir = "C:\Users\Public\AccountPictures\$sid"
    if (Test-Path -LiteralPath $destDir) {
        Write-Log -Message "Destination dir already exists: $destDir (will overwrite)"
    }
    else {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        Write-Log -Message "Created destination dir: $destDir"
    }

    $sizes = @(32, 40, 48, 96, 192, 240, 448)
    $writtenPaths = [ordered]@{}
    try {
        foreach ($size in $sizes) {
            $outPath = Join-Path $destDir "Image$size.png"
            $bitmap = New-Object System.Drawing.Bitmap $size, $size
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            try {
                $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                $graphics.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
                $graphics.Clear([System.Drawing.Color]::Transparent)
                $graphics.DrawImage($source, 0, 0, $size, $size)
            }
            finally {
                $graphics.Dispose()
            }
            $bitmap.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Dispose()

            $bytesOnDisk = (Get-Item -LiteralPath $outPath).Length
            Write-Log -Message "  wrote $outPath ($bytesOnDisk bytes)"
            $writtenPaths["Image$size"] = $outPath
        }
    }
    finally {
        $source.Dispose()
    }

    $regKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AccountPicture\Users\$sid"
    if (Test-Path -LiteralPath $regKey) {
        Write-Log -Message "Registry key exists: $regKey"
    }
    else {
        New-Item -Path $regKey -Force | Out-Null
        Write-Log -Message "Created registry key: $regKey"
    }

    foreach ($entry in $writtenPaths.GetEnumerator()) {
        Set-ItemProperty -Path $regKey -Name $entry.Key -Value $entry.Value -Type String -Force
        Write-Log -Message "  set $($entry.Key) = $($entry.Value)"
    }

    Write-Log -Message "Verifying registry values were written correctly..."
    $verifyOk = $true
    foreach ($name in $writtenPaths.Keys) {
        $expected = $writtenPaths[$name]
        $actual = (Get-ItemProperty -Path $regKey -Name $name -ErrorAction SilentlyContinue).$name
        if ($actual -ne $expected) {
            $verifyOk = $false
            Write-Log -Level WARN -Message "  MISMATCH ${name}: expected '$expected' got '$actual'"
        }
        else {
            Write-Log -Message "  ok       $name = $actual"
        }
    }
    if (-not $verifyOk) {
        Write-Log -Level WARN -Message "One or more registry values did not match expected path. Check permissions on $regKey."
    }

    # Clear the per-user tile cache. Windows re-reads HKLM on fresh sign-in, but the
    # current session renders from this cache and will keep showing the old tile until
    # these files are gone.
    $itmCacheDir = "C:\Users\itm\AppData\Roaming\Microsoft\Windows\AccountPictures"
    if (Test-Path -LiteralPath $itmCacheDir) {
        $cached = @(Get-ChildItem -LiteralPath $itmCacheDir -Filter "*.accountpicture-ms" -ErrorAction SilentlyContinue)
        if ($cached.Count -eq 0) {
            Write-Log -Message "Tile cache dir present but empty: $itmCacheDir"
        }
        foreach ($c in $cached) {
            try {
                Remove-Item -LiteralPath $c.FullName -Force -ErrorAction Stop
                Write-Log -Message "  cleared cached tile $($c.Name) ($($c.Length) bytes)"
            }
            catch {
                Write-Log -Level WARN -Message "  could not remove '$($c.FullName)': $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Log -Message "Tile cache dir does not exist yet (expected on a fresh profile): $itmCacheDir"
    }

    Write-Log -Message "Profile picture step complete. Sign out and back in as itm - the new tile takes effect on next sign-in."
}

Invoke-Step -Number 11 -Name "Clean temp files from installation" -Action {
    $paths = @(
        "C:\Windows\Temp",
        $env:TEMP,
        $workDir
    )
    foreach ($p in $paths) {
        if (-not (Test-Path -LiteralPath $p)) { continue }
        Write-Log -Message "Cleaning $p"
        $items = @(Get-ChildItem -LiteralPath $p -Force -ErrorAction SilentlyContinue)
        foreach ($item in $items) {
            $itemPath = $item.FullName
            try {
                Remove-Item -LiteralPath $itemPath -Recurse -Force -ErrorAction Stop
            }
            catch {
                Write-Log -Level WARN -Message "Could not remove '$itemPath': $($_.Exception.Message)"
            }
        }
    }
}

Write-Host ""
Write-Host "========== New Build Summary ==========" -ForegroundColor Cyan

$orderedResults = $stepResults | Sort-Object Step
foreach ($result in $orderedResults) {
    switch ($result.Status) {
        "SUCCESS" { Write-Host ("Step {0} ({1}): SUCCESS" -f $result.Step, $result.Name) -ForegroundColor Green }
        "SKIPPED" { Write-Host ("Step {0} ({1}): SKIPPED ({2})" -f $result.Step, $result.Name, $result.Detail) -ForegroundColor DarkGray }
        default {
            Write-Host ("Step {0} ({1}): FAILED" -f $result.Step, $result.Name) -ForegroundColor Red
            Write-Host ("  Reason: {0}" -f $result.Detail) -ForegroundColor DarkYellow
        }
    }
}

$successCount = @($orderedResults | Where-Object { $_.Status -eq "SUCCESS" }).Count
$failedCount = @($orderedResults | Where-Object { $_.Status -eq "FAILED" }).Count
$skippedCount = @($orderedResults | Where-Object { $_.Status -eq "SKIPPED" }).Count

Write-Host ""
Write-Host ("Completed. Success: {0}, Failed: {1}, Skipped: {2}" -f $successCount, $failedCount, $skippedCount) -ForegroundColor Cyan
Write-Host ("Report file: {0}" -f $reportPath) -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Reboot the device." -ForegroundColor Gray
Write-Host "  2. Re-run with -Skip 6 to pick up any remaining Windows Updates after reboot (skips Office)." -ForegroundColor Gray
Write-Host "  3. Sign the user into Office / Teams to activate the licence." -ForegroundColor Gray
Write-Host "  4. Verify NinjaRMM check-in from the Ninja dashboard." -ForegroundColor Gray

$exitCode = if ($failedCount -gt 0) { 1 } else { 0 }

if ($transcriptStarted) {
    try {
        Stop-Transcript | Out-Null
    }
    catch {
        Write-Warning "Could not stop transcript cleanly: $($_.Exception.Message)"
    }
}

exit $exitCode
