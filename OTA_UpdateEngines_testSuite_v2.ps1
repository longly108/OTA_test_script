# =========================================================================
# AOSP VIRTUAL A/B INTERRUPT TEST SUITE
# =========================================================================
# Fixes applied vs. previous version:
#   - Literal "\n" on the MATCH_FOUND banner replaced with real newline (`n)
#   - MATCH_FOUND now pipe-delimited (colon-delimited broke on TCP/IP serials
#     like 192.168.1.5:5555, which contain a colon in the device ID itself)
#   - First read per device is treated as "establishing baseline", not as an
#     update event, even if it doesn't match $ExpectedBaseSW (avoids a false
#     "OTA UPDATE SUCCESSFUL" the instant the script starts on a device that
#     was left on different software from a previous run)
#   - Job tracking is scoped to jobs this script started ($Jobs array),
#     instead of Get-Job/Stop-Job hitting every job in the session
#   - adb availability is checked up front, before spawning workers
#   - Menu prompts now re-ask on invalid input instead of silently defaulting
#   - Match notification uses a non-blocking balloon tip instead of a modal
#     MessageBox, so it can't stall log processing/display while open
#   - A per-device CSV summary is written on exit (cycles, first/last SW)
# =========================================================================

# Define your array of device IDs here
$DeviceIDs = @(
    "04200733B0000A96520E",
    "04203913B0000AA3EF65",
    "04219275B0000B34FB78",
    "04215947B0000B2B7B6D"
)

# --- DEFINE YOUR STARTING BASELINE SOFTWARE ---
$ExpectedBaseSW = "612030140:userdebug"

# --- FOLDER ORGANIZATION BY DATE ---
$BaseFolder = "D:\LONG"
$DateFolder = Get-Date -Format "yyyy_MMM_dd"
$TargetFolder = Join-Path $BaseFolder $DateFolder
$Timestamp = Get-Date -Format "yyyy_MMM_dd_HHmmss"

if (-not (Test-Path $TargetFolder)) {
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
}

# --- PRE-FLIGHT CHECK: adb must be reachable before we spawn 5 workers that
#     would otherwise all fail identically ---
$AdbCheck = Get-Command adb -ErrorAction SilentlyContinue
if (-not $AdbCheck) {
    Write-Host "ERROR: 'adb' was not found on PATH. Install platform-tools or fix your PATH before running this suite." -ForegroundColor Red
    exit 1
}

# --- START TERMINAL TRANSCRIPT (SUMMARY FILE) ---
$SummaryFile = Join-Path $TargetFolder "Summary_Terminal_Output_${Timestamp}.txt"
Start-Transcript -Path $SummaryFile -Append -NoClobber | Out-Null

# =========================================================================
# INTERACTIVE SELECTION MENU
# =========================================================================
function Read-MenuChoice {
    param(
        [string]$Prompt,
        [string[]]$ValidChoices
    )
    while ($true) {
        $choice = Read-Host $Prompt
        if ($ValidChoices -contains $choice) { return $choice }
        Write-Host "Invalid selection. Please enter one of: $($ValidChoices -join ', ')" -ForegroundColor Red
    }
}

Clear-Host
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "         AOSP VIRTUAL A/B INTERRUPT TEST SUITE          " -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "=======================================================" -ForegroundColor Cyan

Write-Host "`n[STEP 1] Select Log Target Condition to Monitor:" -ForegroundColor Yellow
Write-Host "  1) 'Switching snapshot to merge: system_a' or 'system_b'"
Write-Host "  2) 'MergeSecondPhaseSnapshots invoked'"
Write-Host "  3) 'Waiting for merge to complete' at any percent from 1% to 20%"
Write-Host "  4) 'Attempting to initiate merge'"
$TargetInput = Read-MenuChoice -Prompt "Choose option (1-4)" -ValidChoices @("1","2","3","4")

switch ($TargetInput) {
    "1" { $RegexPattern = "Switching snapshot to merge: (system_[ab])"; $TargetDesc = "Switching snapshot to merge" }
    "2" { $RegexPattern = "MergeSecondPhaseSnapshots invoked"; $TargetDesc = "MergeSecondPhaseSnapshots invoked" }
    "3" { $RegexPattern = "Waiting for merge to complete: ((?:[1-9]|1[0-9]|20)%)"; $TargetDesc = "Merge Progress 1-20%" }
    "4" { $RegexPattern = "Attempting to initiate merge"; $TargetDesc = "Attempting to initiate merge" }
}

Write-Host "`n[STEP 2] Select Interruption Action upon Target Match:" -ForegroundColor Yellow
Write-Host "  1) Just Alert (Keep Device Online & Continue Capturing)"
Write-Host "  2) Quiescent Reboot (adb reboot quiescent)"
Write-Host "  3) Hard Power Off (adb shell reboot -p)"
$ActionInput = Read-MenuChoice -Prompt "Choose option (1-3)" -ValidChoices @("1","2","3")

switch ($ActionInput) {
    "1" { $ActionType = "ALERT_ONLY"; $ActionDesc = "Alert & Keep Device Online" }
    "2" { $ActionType = "REBOOT_QUIESCENT"; $ActionDesc = "Injected Quiescent Reboot" }
    "3" { $ActionType = "POWER_OFF"; $ActionDesc = "Injected Hard Power Off (-p)" }
}

# =========================================================================
# EXECUTION LIFECYCLE PIPELINE
# =========================================================================
Clear-Host
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host " RUNTIME CONFIGURATION:" -ForegroundColor Cyan
Write-Host " Monitoring Tag : $TargetDesc" -ForegroundColor White
Write-Host " Target Action  : $ActionDesc" -ForegroundColor White
Write-Host " Base SW Target : $ExpectedBaseSW" -ForegroundColor Yellow
Write-Host " Output Folder  : $TargetFolder" -ForegroundColor White
Write-Host " Run Timestamp  : $Timestamp" -ForegroundColor White
Write-Host " Summary Log    : $SummaryFile" -ForegroundColor White
Write-Host "=======================================================" -ForegroundColor Cyan

# Track only the jobs *this run* spawns, so Get-Job/Stop-Job elsewhere in
# the session (if any) are never touched by this script.
$Jobs = @()

# Loop through each device and start a background job for it
foreach ($Device in $DeviceIDs) {
    $JobBlock = {
        param($DeviceID, $Folder, $ScriptTimestamp, $Regex, $Desc, $ActType, $ActDesc, $BaseSw)

        $LogFileName = "ota_suite_${DeviceID}_${ScriptTimestamp}.log"
        $OutputFile = Join-Path $Folder $LogFileName

        $LastKnownSwVersion = $null   # unset until we take our first real reading
        $UpdateCycleCount = 0
        $FirstSwSeen = $null

        while ($true) {
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Waiting for $DeviceID to be online..."
            & adb -s $DeviceID wait-for-device
            Start-Sleep -Seconds 2 # Give OS properties 2 seconds to populate after connection

            $CurrentSwVersion = (& adb -s $DeviceID shell getprop ro.build.display.id).Trim()
            if (-not $CurrentSwVersion) { $CurrentSwVersion = "Unknown/Offline" }

            if ($null -eq $LastKnownSwVersion) {
                # First reading for this device this run: establish baseline,
                # don't count it as an update even if it differs from
                # $ExpectedBaseSW (device may have carried over state from a
                # previous run).
                $FirstSwSeen = $CurrentSwVersion
                if ($CurrentSwVersion -ne "Unknown/Offline" -and $CurrentSwVersion -ne $BaseSw) {
                    "--- [$(Get-Date -Format 'HH:mm:ss')] NOTE: device started on '$CurrentSwVersion', not expected baseline '$BaseSw'. Tracking from here. ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    Write-Output "BASELINE_MISMATCH|${DeviceID}|${BaseSw}|${CurrentSwVersion}"
                }
                if ($CurrentSwVersion -ne "Unknown/Offline") {
                    $LastKnownSwVersion = $CurrentSwVersion
                }
            }
            elseif ($CurrentSwVersion -ne "Unknown/Offline" -and $LastKnownSwVersion -ne $CurrentSwVersion) {
                $UpdateCycleCount++

                "--- [$(Get-Date -Format 'HH:mm:ss')] SW UPDATE DETECTED! Cycle #$UpdateCycleCount ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                "--- Old: $LastKnownSwVersion ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                "--- New: $CurrentSwVersion ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8

                Write-Output "SW_UPDATED|${DeviceID}|${LastKnownSwVersion}|${CurrentSwVersion}|${UpdateCycleCount}"

                $LastKnownSwVersion = $CurrentSwVersion
            }

            Write-Output "SW_VERSION|${DeviceID}|${CurrentSwVersion}|${UpdateCycleCount}"
            "--- [$(Get-Date -Format 'HH:mm:ss')] DEVICE CONNECTED | SW VERSION: $CurrentSwVersion | CYCLES: $UpdateCycleCount ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8

            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connected! Capturing logs for $DeviceID..."

            & adb -s $DeviceID logcat -v threadtime 'update_engine:I' 'update_engine_client:I' 'PowerManagerService:I' 'PowerHAL:I' 'HdmiControlService:I' 'DisplayManagerService:I' 'AndroidRuntime:E' 'DEBUG:I' '*:S' | ForEach-Object {
                $line = $_

                $line | Out-File -FilePath $OutputFile -Append -Encoding utf8

                if ($line -match $Regex) {
                    $CapturedValue = if ($Matches[1]) { $Matches[1] } else { "" }

                    "--- TARGET LOG HIT ($Desc $CapturedValue) ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    "--- EXECUTION PROFILE EVENT triggered: $ActDesc ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8

                    Write-Output "MATCH_FOUND|${DeviceID}|${CapturedValue}|${ActType}"

                    if ($ActType -eq "REBOOT_QUIESCENT") {
                        & adb -s $DeviceID reboot quiescent
                    }
                    elseif ($ActType -eq "POWER_OFF") {
                        & adb -s $DeviceID shell reboot -p
                    }
                }
            }

            if ($ActType -eq "POWER_OFF") {
                Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] HARD SHUTDOWN COMPLETED on $DeviceID (Set is now Powered Off)."
            } elseif ($ActType -eq "REBOOT_QUIESCENT") {
                Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] QUIESCENT REBOOT INJECTED on $DeviceID (Restarting screen-off)."
            } else {
                Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connection broken for $DeviceID. Retrying..."
            }
            Start-Sleep -Seconds 5
        }
    }

    $Jobs += Start-Job -ScriptBlock $JobBlock -ArgumentList $Device, $TargetFolder, $Timestamp, $RegexPattern, $TargetDesc, $ActionType, $ActionDesc, $ExpectedBaseSW
    Write-Host "Started background monitoring thread for: $Device" -ForegroundColor Green
}

Write-Host "`nAll background automation jobs are now armed." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to safely terminate monitoring and exit." -ForegroundColor Yellow
Write-Host "======================================================="

# Load UI assemblies: WPF for nothing blocking now, WinForms for the
# non-blocking balloon-tip notification.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
$NotifyIcon.Visible = $true

# Per-device tracking for the end-of-run CSV summary
$DeviceStats = @{}
foreach ($d in $DeviceIDs) {
    $DeviceStats[$d] = [PSCustomObject]@{
        DeviceID        = $d
        FirstSwSeen     = ""
        LastSwSeen      = ""
        UpdateCycles    = 0
        MatchesTriggered = 0
    }
}

try {
    while ($true) {
        $jobOutputs = $Jobs | Receive-Job

        foreach ($output in $jobOutputs) {

            if ($output -like "BASELINE_MISMATCH|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $Expected = $Parts[2]
                $Actual = $Parts[3]
                Write-Host ">>> [DEVICE $MatchedDevice] Started on '$Actual', not expected baseline '$Expected'. Tracking from current state." -ForegroundColor Yellow
                $DeviceStats[$MatchedDevice].FirstSwSeen = $Actual
            }
            elseif ($output -like "SW_UPDATED|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $OldVer = $Parts[2]
                $NewVer = $Parts[3]
                $Cycles = $Parts[4]

                [Console]::Beep(880, 150)
                [Console]::Beep(1046, 150)
                [Console]::Beep(1318, 300)

                Write-Host "`n*******************************************************" -ForegroundColor Black -BackgroundColor Green
                Write-Host " OTA UPDATE SUCCESSFUL ON DEVICE: $MatchedDevice " -ForegroundColor Black -BackgroundColor Green
                Write-Host " Cycle Count: $Cycles Completed " -ForegroundColor Black -BackgroundColor Green
                Write-Host " Old SW: $OldVer " -ForegroundColor Black -BackgroundColor Green
                Write-Host " New SW: $NewVer " -ForegroundColor Black -BackgroundColor Green
                Write-Host "*******************************************************`n" -ForegroundColor Black -BackgroundColor Green

                $DeviceStats[$MatchedDevice].UpdateCycles = [int]$Cycles
                $DeviceStats[$MatchedDevice].LastSwSeen = $NewVer
            }
            elseif ($output -like "SW_VERSION|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $Version = $Parts[2]
                $Cycles = $Parts[3]
                Write-Host ">>> [DEVICE $MatchedDevice] SW: $Version (Cycles: $Cycles)" -ForegroundColor Magenta

                if (-not $DeviceStats[$MatchedDevice].FirstSwSeen) {
                    $DeviceStats[$MatchedDevice].FirstSwSeen = $Version
                }
                $DeviceStats[$MatchedDevice].LastSwSeen = $Version
            }
            elseif ($output -like "MATCH_FOUND|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $ContextInfo = $Parts[2]
                $ExecutedType = $Parts[3]

                [Console]::Beep(523, 120)
                [Console]::Beep(659, 120)
                [Console]::Beep(784, 200)

                Write-Host "`n=======================================================" -ForegroundColor White -BackgroundColor Red
                Write-Host " INTERRUPT RULE EXECUTED ON DEVICE: $MatchedDevice " -ForegroundColor White -BackgroundColor Red
                Write-Host " Log Context: $TargetDesc ($ContextInfo) " -ForegroundColor White -BackgroundColor Red
                Write-Host " Action Type: $ActionDesc " -ForegroundColor White -BackgroundColor Red
                Write-Host "=======================================================`n" -ForegroundColor White -BackgroundColor Red

                $DeviceStats[$MatchedDevice].MatchesTriggered++

                # Non-blocking balloon tip instead of a modal MessageBox, so
                # log processing/display for other devices doesn't stall
                # while this is on screen.
                $NotifyIcon.BalloonTipTitle = "OTA Test Automation Interrupt Notification"
                $NotifyIcon.BalloonTipText = "Device $MatchedDevice matched: $TargetDesc $ContextInfo`nAction taken: $ActionDesc"
                $NotifyIcon.ShowBalloonTip(6000)
            }
            elseif ($output -like "STATUS:*") {
                $Msg = $output.Substring(7)
                if ($Msg -like "*SHUTDOWN COMPLETED*" -or $Msg -like "*REBOOT INJECTED*") {
                    Write-Host $Msg -ForegroundColor White -BackgroundColor DarkRed
                } else {
                    Write-Host $Msg -ForegroundColor Gray
                }
            }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host "`nStopping and flushing background tracking pipelines..." -ForegroundColor Red
    $Jobs | Stop-Job
    $Jobs | Remove-Job

    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()

    # Write per-device summary CSV
    $SummaryCsv = Join-Path $TargetFolder "DeviceSummary_${Timestamp}.csv"
    $DeviceStats.Values | Select-Object DeviceID, FirstSwSeen, LastSwSeen, UpdateCycles, MatchesTriggered |
        Export-Csv -Path $SummaryCsv -NoTypeInformation -Encoding utf8
    Write-Host "Per-device summary saved to: $SummaryCsv" -ForegroundColor Cyan

    Stop-Transcript | Out-Null
    Write-Host "Terminal summary saved to: $SummaryFile" -ForegroundColor Cyan
}
