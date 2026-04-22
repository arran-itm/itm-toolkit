#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$SkipDism,
    [ValidateRange(5, 120)]
    [int]$DismTimeoutMinutes = 20,
    [switch]$ForceDism
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$services = @("wuauserv", "bits", "dosvc", "cryptsvc")
$stepResults = New-Object System.Collections.Generic.List[object]
$reportDir = "C:\diskcleanup"
$reportFile = "report-{0}.txt" -f (Get-Date -Format "ddMMyyyy")
$reportPath = Join-Path $reportDir $reportFile
$transcriptStarted = $false

try {
    if (-not (Test-Path -LiteralPath $reportDir)) {
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
    }

    Start-Transcript -Path $reportPath -Append | Out-Null
    $transcriptStarted = $true
}
catch {
    Write-Warning "Could not start transcript logging at '$reportPath': $($_.Exception.Message)"
}

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

function Invoke-CmdLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log -Message "Running: $Command"
    & cmd.exe /c $Command
    $exitCode = $LASTEXITCODE

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "Command failed with exit code $($exitCode): $Command"
    }

    return $exitCode
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

function Get-FreeSpaceGB {
    try {
        $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction Stop
        return [math]::Round(($disk.FreeSpace / 1GB), 2)
    }
    catch {
        $drive = Get-PSDrive -Name C -PSProvider FileSystem -ErrorAction Stop
        return [math]::Round(($drive.Free / 1GB), 2)
    }
}

function Test-PendingReboot {
    $pendingKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired"
    )

    foreach ($key in $pendingKeys) {
        if (Test-Path -LiteralPath $key) {
            return $true
        }
    }

    try {
        $sessionManager = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -ErrorAction Stop
        if ($sessionManager.PSObject.Properties.Name -contains "PendingFileRenameOperations") {
            return $true
        }
    }
    catch {
        Write-Log -Level WARN -Message "Could not query pending reboot registry markers: $($_.Exception.Message)"
    }

    return $false
}

function Invoke-ProcessWithTimeout {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$ArgumentList,
        [int]$TimeoutMinutes = 20,
        [int]$HeartbeatSeconds = 20,
        [int[]]$AllowedExitCodes = @(0)
    )

    Write-Log -Message "Running with timeout: $FilePath $ArgumentList"
    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -PassThru -WindowStyle Hidden
    $maxSeconds = $TimeoutMinutes * 60
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    while (-not $process.HasExited) {
        Start-Sleep -Seconds $HeartbeatSeconds
        $process.Refresh()

        if ($process.HasExited) {
            break
        }

        $elapsedMinutes = [math]::Round($stopwatch.Elapsed.TotalMinutes, 1)
        Write-Log -Message "$FilePath still running ($elapsedMinutes min elapsed)..."

        if ($stopwatch.Elapsed.TotalSeconds -ge $maxSeconds) {
            try {
                $process.Kill()
                Write-Log -Level WARN -Message "$FilePath exceeded timeout and was terminated."
            }
            catch {
                Write-Log -Level WARN -Message "Failed to terminate timed-out process '$FilePath': $($_.Exception.Message)"
            }

            throw "$FilePath timed out after $TimeoutMinutes minutes."
        }
    }

    $exitCode = $process.ExitCode
    $elapsedTotal = [math]::Round($stopwatch.Elapsed.TotalMinutes, 1)
    Write-Log -Message "$FilePath finished in $elapsedTotal min (exit code: $exitCode)."

    if ($AllowedExitCodes -notcontains $exitCode) {
        throw "$FilePath failed with exit code $exitCode."
    }

    return $exitCode
}

function Wait-ServiceStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [System.ServiceProcess.ServiceControllerStatus]$TargetStatus,
        [int]$TimeoutSeconds = 60
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $svc = Get-Service -Name $Name -ErrorAction Stop
    } while ($svc.Status -ne $TargetStatus -and (Get-Date) -lt $deadline)

    if ($svc.Status -ne $TargetStatus) {
        throw "Service '$Name' did not reach state '$TargetStatus' within $TimeoutSeconds seconds."
    }
}

function Stop-ServiceSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Log -Level WARN -Message "Service '$Name' not found. Skipping."
        return
    }

    if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Write-Log -Message "Service '$Name' is already stopped."
        return
    }

    Write-Log -Message "Stopping service '$Name'..."
    Stop-Service -Name $Name -Force -ErrorAction Stop
    Wait-ServiceStatus -Name $Name -TargetStatus ([System.ServiceProcess.ServiceControllerStatus]::Stopped)
    Write-Log -Message "Service '$Name' stopped."
}

function Start-ServiceSafe {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $svc = Get-Service -Name $Name -ErrorAction Stop
    }
    catch {
        Write-Log -Level WARN -Message "Service '$Name' not found. Skipping."
        return
    }

    if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
        Write-Log -Message "Service '$Name' is already running."
        return
    }

    Write-Log -Message "Starting service '$Name'..."
    Start-Service -Name $Name -ErrorAction Stop
    Wait-ServiceStatus -Name $Name -TargetStatus ([System.ServiceProcess.ServiceControllerStatus]::Running)
    Write-Log -Message "Service '$Name' started."
}

function Clear-DirectoryContents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log -Message "Path not found, skipping: $Path"
        return
    }

    Write-Log -Message "Cleaning contents of: $Path"
    $removed = 0
    $failed = 0

    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $entry = $_
        try {
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction Stop
            $removed++
        }
        catch {
            $failed++
            $entryPath = if ($null -ne $entry -and $entry.PSObject.Properties["FullName"]) { $entry.FullName } else { $Path }
            Write-Log -Level WARN -Message "Could not remove '$entryPath': $($_.Exception.Message)"
        }
    }

    Write-Log -Message "Finished: $Path (removed items: $removed, failed: $failed)"
}

function Remove-PathIfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log -Message "Path not found, skipping: $Path"
        return
    }

    Write-Log -Message "Removing path: $Path"
    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
}

Write-Log -Message "Starting cleanup-disk3 (faster + higher reclaim profile)..."
$freeBeforeGB = Get-FreeSpaceGB
Write-Log -Message "Free space before cleanup: $freeBeforeGB GB"

Invoke-Step -Number 1 -Name "Turn off hibernation" -Action {
    Invoke-CmdLine -Command "powercfg.exe -h off" | Out-Null
}

Invoke-Step -Number 2 -Name "Stop update-related services" -Action {
    $errors = @()
    foreach ($service in $services) {
        try {
            Stop-ServiceSafe -Name $service
        }
        catch {
            $errors += "${service}: $($_.Exception.Message)"
            Write-Log -Level WARN -Message "Could not stop service '$service'. Continuing."
        }
    }

    if ($errors.Count -gt 0) {
        Write-Log -Level WARN -Message "Some services could not be stopped: $($errors -join ' | ')"
    }
}

Invoke-Step -Number 3 -Name "Clear Windows Update and Delivery Optimization caches" -Action {
    Invoke-CmdLine -Command "if exist C:\Windows\SoftwareDistribution\Download rd /s /q C:\Windows\SoftwareDistribution\Download & md C:\Windows\SoftwareDistribution\Download" | Out-Null
    Invoke-CmdLine -Command "if exist C:\Windows\SoftwareDistribution\DataStore\Logs rd /s /q C:\Windows\SoftwareDistribution\DataStore\Logs & md C:\Windows\SoftwareDistribution\DataStore\Logs" | Out-Null
    Invoke-CmdLine -Command "if exist C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache rd /s /q C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache & md C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" | Out-Null
    Invoke-CmdLine -Command "if exist C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache rd /s /q C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache & md C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache" | Out-Null
}

Invoke-Step -Number 4 -Name "Delete restore points and shadow copies" -Action {
    $querySucceeded = $true
    $shadowCopies = @()

    try {
        $shadowCopies = @(Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction Stop)
    }
    catch {
        $querySucceeded = $false
        Write-Log -Level WARN -Message "Could not query shadow copies using CIM. Attempting delete anyway."
    }

    if ($querySucceeded -and $shadowCopies.Count -eq 0) {
        Write-Log -Message "No shadow copies found. Skipping deletion."
        return
    }

    Invoke-CmdLine -Command "vssadmin delete shadows /all /quiet" | Out-Null
}

Invoke-Step -Number 5 -Name "Clear temp, dumps, and Windows diagnostic files" -Action {
    $paths = @(
        "C:\Windows\Temp",
        "C:\Windows\SoftwareDistribution\DataStore\Logs",
        "C:\ProgramData\Microsoft\Windows\WER\ReportArchive",
        "C:\ProgramData\Microsoft\Windows\WER\ReportQueue",
        "C:\ProgramData\Microsoft\Windows\WER\Temp",
        "C:\Windows\Minidump",
        "C:\Windows\Logs\CBS",
        "C:\Windows\Logs\DISM",
        "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Temp",
        "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Temp",
        "C:\Windows\ccmcache"
    )

    foreach ($path in $paths) {
        Clear-DirectoryContents -Path $path
    }

    if (Test-Path -LiteralPath "C:\Windows\MEMORY.DMP") {
        Write-Log -Message "Removing C:\Windows\MEMORY.DMP"
        Remove-Item -LiteralPath "C:\Windows\MEMORY.DMP" -Force -ErrorAction Stop
    }

    Get-ChildItem -Path "C:\Users" -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $userProfile = $_
        $userTempPath = Join-Path $userProfile.FullName "AppData\Local\Temp"
        Clear-DirectoryContents -Path $userTempPath
    }
}

Invoke-Step -Number 6 -Name "Remove old Windows upgrade leftovers" -Action {
    $paths = @(
        "C:\Windows.old",
        'C:\$WINDOWS.~BT',
        'C:\$WINDOWS.~WS',
        'C:\$SysReset',
        "C:\ESD"
    )

    foreach ($path in $paths) {
        try {
            Remove-PathIfExists -Path $path
        }
        catch {
            Write-Log -Level WARN -Message "Could not remove '$path': $($_.Exception.Message)"
        }
    }
}

Invoke-Step -Number 7 -Name "Clear recycle bins on all local drives" -Action {
    $drives = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty DeviceID
    foreach ($drive in $drives) {
        $cmd = 'if exist "{0}\$Recycle.Bin" rd /s /q "{0}\$Recycle.Bin"' -f $drive
        Invoke-CmdLine -Command $cmd | Out-Null
    }
}

Invoke-Step -Number 8 -Name "Run DISM component cleanup (extra reclaim)" -Action {
    if ($SkipDism) {
        Write-Log -Message "Skipping DISM because -SkipDism was provided."
        return
    }

    if ((Test-PendingReboot) -and (-not $ForceDism)) {
        Write-Log -Level WARN -Message "Pending reboot detected. Skipping DISM (use -ForceDism to override)."
        return
    }

    $analyzeOutput = $null
    $analyzeExitCode = 0
    Write-Log -Message "Analyzing component store before cleanup..."
    $analyzeOutput = (& cmd.exe /c "Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore" 2>&1 | Out-String)
    $analyzeExitCode = $LASTEXITCODE

    if ($analyzeExitCode -eq 0) {
        if (($analyzeOutput -match "Component Store Cleanup Recommended\s*:\s*No") -and (-not $ForceDism)) {
            Write-Log -Message "DISM reports cleanup is not recommended. Skipping StartComponentCleanup."
            return
        }
    }
    else {
        Write-Log -Level WARN -Message "AnalyzeComponentStore failed with exit code $analyzeExitCode. Continuing to StartComponentCleanup."
    }

    $dismExit = Invoke-ProcessWithTimeout -FilePath "Dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup /NoRestart" -TimeoutMinutes $DismTimeoutMinutes -AllowedExitCodes @(0, 3010)
    if ($dismExit -eq 3010) {
        Write-Log -Level WARN -Message "DISM completed and reported reboot required (3010)."
    }
}

Invoke-Step -Number 9 -Name "Restart previously stopped services" -Action {
    $errors = @()
    foreach ($service in $services) {
        try {
            Start-ServiceSafe -Name $service
        }
        catch {
            $errors += "${service}: $($_.Exception.Message)"
            Write-Log -Level WARN -Message "Could not start service '$service'. Continuing."
        }
    }

    if ($errors.Count -gt 0) {
        Write-Log -Level WARN -Message "Some services could not be started: $($errors -join ' | ')"
    }
}

$freeAfterGB = Get-FreeSpaceGB
$spaceReclaimedGB = [math]::Round(($freeAfterGB - $freeBeforeGB), 2)

Write-Host ""
Write-Host "========== Cleanup Summary ==========" -ForegroundColor Cyan

$orderedResults = $stepResults | Sort-Object Step
foreach ($result in $orderedResults) {
    if ($result.Status -eq "SUCCESS") {
        Write-Host ("Step {0}: SUCCESS" -f $result.Step) -ForegroundColor Green
    }
    else {
        Write-Host ("Step {0}: FAILED" -f $result.Step) -ForegroundColor Red
        Write-Host ("  Reason: {0}" -f $result.Detail) -ForegroundColor DarkYellow
    }
}

$successCount = @($orderedResults | Where-Object { $_.Status -eq "SUCCESS" }).Count
$failedCount = @($orderedResults | Where-Object { $_.Status -eq "FAILED" }).Count

Write-Host ""
Write-Host ("Completed. Success: {0}, Failed: {1}" -f $successCount, $failedCount) -ForegroundColor Cyan
Write-Host ("Free space before: {0} GB | after: {1} GB | reclaimed: {2} GB" -f $freeBeforeGB, $freeAfterGB, $spaceReclaimedGB) -ForegroundColor Cyan
Write-Host ("Report file: {0}" -f $reportPath) -ForegroundColor Cyan

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
