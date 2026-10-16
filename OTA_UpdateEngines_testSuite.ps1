# Define your array of device IDs here
$DeviceIDs = @(
    "04200733B0000A96520E",
    "04203913B0000AA3EF65",
    "04219275B0000B34FB78",
    "90000000B0000B1F9D0D",
    "04215947B0000B2B7B6D" 
)

# --- NEW: DEFINE YOUR STARTING BASELINE SOFTWARE ---
$ExpectedBaseSW = "612030140:userdebug"

# --- FOLDER ORGANIZATION BY DATE ---
$BaseFolder = "D:\LONG"
$DateFolder = Get-Date -Format "yyyy_MMM_dd"
$TargetFolder = Join-Path $BaseFolder $DateFolder
$Timestamp = Get-Date -Format "yyyy_MMM_dd_HHmmss"

# Ensure the date-specific directory exists
if (-not (Test-Path $TargetFolder)) {
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
}

# --- START TERMINAL TRANSCRIPT (SUMMARY FILE) ---
$SummaryFile = Join-Path $TargetFolder "Summary_Terminal_Output_${Timestamp}.txt"
Start-Transcript -Path $SummaryFile -Append -NoClobber | Out-Null

# =========================================================================
# INTERACTIVE SELECTION MENU
# =========================================================================
Clear-Host
Write-Host "=======================================================" -ForegroundColor Cyan
Write-Host "         AOSP VIRTUAL A/B INTERRUPT TEST SUITE          " -ForegroundColor White -BackgroundColor DarkBlue
Write-Host "=======================================================" -ForegroundColor Cyan

Write-Host "`n[STEP 1] Select Log Target Condition to Monitor:" -ForegroundColor Yellow
Write-Host "  1) 'Switching snapshot to merge: system_a' or 'system_b'"
Write-Host "  2) 'MergeSecondPhaseSnapshots invoked'"
Write-Host "  3) 'Waiting for merge to complete: 1%', '23%', or '40%'"
Write-Host "  4) 'Attempting to initiate merge'"
$TargetInput = Read-Host "Choose option (1-4)"

switch ($TargetInput) {
    "1" { $RegexPattern = "Switching snapshot to merge: (system_[ab])"; $TargetDesc = "Switching snapshot to merge" }
    "2" { $RegexPattern = "MergeSecondPhaseSnapshots invoked"; $TargetDesc = "MergeSecondPhaseSnapshots invoked" }
    "3" { $RegexPattern = "Waiting for merge to complete: (1%|23%|40%)"; $TargetDesc = "Merge Progress Threshold" }
    "4" { $RegexPattern = "Attempting to initiate merge"; $TargetDesc = "Attempting to initiate merge" }
    Default {
        Write-Host "Invalid selection. Defaulting to Option 1." -ForegroundColor Red
        $RegexPattern = "Switching snapshot to merge: (system_[ab])"
        $TargetDesc = "Switching snapshot to merge"
        Start-Sleep -Seconds 2
    }
}

Write-Host "`n[STEP 2] Select Interruption Action upon Target Match:" -ForegroundColor Yellow
Write-Host "  1) Just Alert (Keep Device Online & Continue Capturing)"
Write-Host "  2) Quiescent Reboot (adb reboot quiescent)"
Write-Host "  3) Hard Power Off (adb shell reboot -p)"
$ActionInput = Read-Host "Choose option (1-3)"

switch ($ActionInput) {
    "1" { $ActionType = "ALERT_ONLY"; $ActionDesc = "Alert & Keep Device Online" }
    "2" { $ActionType = "REBOOT_QUIESCENT"; $ActionDesc = "Injected Quiescent Reboot" }
    "3" { $ActionType = "POWER_OFF"; $ActionDesc = "Injected Hard Power Off (-p)" }
    Default {
        Write-Host "Invalid selection. Defaulting to Option 1 (Alert Only)." -ForegroundColor Red
        $ActionType = "ALERT_ONLY"
        $ActionDesc = "Alert & Keep Device Online"
        Start-Sleep -Seconds 2
    }
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

# Loop through each device and start a background job for it
foreach ($Device in $DeviceIDs) {
    $JobBlock = {
        param($DeviceID, $Folder, $ScriptTimestamp, $Regex, $Desc, $ActType, $ActDesc, $BaseSw)
        
        $LogFileName = "ota_suite_${DeviceID}_${ScriptTimestamp}.log"
        $OutputFile = Join-Path $Folder $LogFileName
        
        # --- Pre-load state tracking with your hardcoded baseline ---
        $LastKnownSwVersion = $BaseSw
        $UpdateCycleCount = 0

        while($true) {
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Waiting for $DeviceID to be online..."
            & adb -s $DeviceID wait-for-device
            Start-Sleep -Seconds 2 # Give OS properties 2 seconds to populate after connection
            
            # --- CHANGED: Use ro.build.display.id for clean userdebug strings ---
            $CurrentSwVersion = (& adb -s $DeviceID shell getprop ro.build.display.id).Trim()
            if (-not $CurrentSwVersion) { $CurrentSwVersion = "Unknown/Offline" }
            
            # Check if SW Version changed from baseline (indicates successful OTA update)
            if ($LastKnownSwVersion -ne "Unknown/Offline" -and $CurrentSwVersion -ne "Unknown/Offline" -and $LastKnownSwVersion -ne $CurrentSwVersion) {
                $UpdateCycleCount++
                
                # Log success directly to the text file
                "--- [$(Get-Date -Format 'HH:mm:ss')] 🟢 SW UPDATE DETECTED! Cycle #$UpdateCycleCount ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                "--- Old: $LastKnownSwVersion ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                "--- New: $CurrentSwVersion ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                
                # Send alert up to main UI thread
                Write-Output "SW_UPDATED|${DeviceID}|${LastKnownSwVersion}|${CurrentSwVersion}|${UpdateCycleCount}"
                
                # Update the baseline so it tracks the next jump correctly
                $LastKnownSwVersion = $CurrentSwVersion
            }
            
            # Write standard connection UI update
            Write-Output "SW_VERSION|${DeviceID}|${CurrentSwVersion}|${UpdateCycleCount}"
            "--- [$(Get-Date -Format 'HH:mm:ss')] DEVICE CONNECTED | SW VERSION: $CurrentSwVersion | CYCLES: $UpdateCycleCount ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
            
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connected! Capturing logs for $DeviceID..."
            
            # Stream logcat line-by-line to allow simultaneous saving and live parsing
            & adb -s $DeviceID logcat -v threadtime 'update_engine:I' 'update_engine_client:I' 'PowerManagerService:I' 'PowerHAL:I' 'HdmiControlService:I' 'DisplayManagerService:I' 'AndroidRuntime:E' 'DEBUG:I' '*:S' | ForEach-Object {
                $line = $_
                
                $line | Out-File -FilePath $OutputFile -Append -Encoding utf8
                
                if ($line -match $Regex) {
                    $CapturedValue = if ($Matches[1]) { $Matches[1] } else { "" }
                    
                    "--- TARGET LOG HIT ($Desc $CapturedValue) ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    "--- EXECUTION PROFILE EVENT triggered: $ActDesc ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    
                    Write-Output "MATCH_FOUND:${DeviceID}:${CapturedValue}:${ActType}"
                    
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
    
    # Safely pass configuration parameters into background workers
    Start-Job -ScriptBlock $JobBlock -ArgumentList $Device, $TargetFolder, $Timestamp, $RegexPattern, $TargetDesc, $ActionType, $ActionDesc, $ExpectedBaseSW | Out-Null
    Write-Host "Started background monitoring thread for: $Device" -ForegroundColor Green
}

Write-Host "`nAll background automation jobs are now armed." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to safely terminate monitoring and exit." -ForegroundColor Yellow
Write-Host "======================================================="

# Load UI presentation package for the modal notification box
Add-Type -AssemblyName PresentationFramework

try {
    while($true) {
        $jobOutputs = Get-Job | Receive-Job
        
        foreach ($output in $jobOutputs) {
            
            # --- Catch Software Update Success Alert ---
            if ($output -like "SW_UPDATED|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $OldVer = $Parts[2]
                $NewVer = $Parts[3]
                $Cycles = $Parts[4]
                
                [Console]::Beep(880, 150)
                [Console]::Beep(1046, 150)
                [Console]::Beep(1318, 300)
                
                Write-Host "`n*******************************************************" -ForegroundColor Black -BackgroundColor Green
                Write-Host " 🟢 OTA UPDATE SUCCESSFUL ON DEVICE: $MatchedDevice " -ForegroundColor Black -BackgroundColor Green
                Write-Host " Cycle Count: $Cycles Completed " -ForegroundColor Black -BackgroundColor Green
                Write-Host " Old SW: $OldVer " -ForegroundColor Black -BackgroundColor Green
                Write-Host " New SW: $NewVer " -ForegroundColor Black -BackgroundColor Green
                Write-Host "*******************************************************`n" -ForegroundColor Black -BackgroundColor Green
            }
            # --- Handle standard SW Version printout ---
            elseif ($output -like "SW_VERSION|*") {
                $Parts = $output.Split("|")
                $MatchedDevice = $Parts[1]
                $Version = $Parts[2]
                $Cycles = $Parts[3]
                Write-Host ">>> [DEVICE $MatchedDevice] SW: $Version (Cycles: $Cycles)" -ForegroundColor Magenta
            }
            # --- Handle Interrupt/Disruption Event Match ---
            elseif ($output -like "MATCH_FOUND:*") {
                $Parts = $output.Split(":")
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
                Write-Host "=======================================================\n" -ForegroundColor White -BackgroundColor Red
                
                $PromptMsg = "Device ID: $MatchedDevice has satisfied test profile criteria.`n`nCondition Matched: $TargetDesc $ContextInfo`n`nAction Taken: $ActionDesc"
                [System.Windows.MessageBox]::Show($PromptMsg, "OTA Test Automation Interrupt Notification")
            }
            # --- Handle Status Strings ---
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
    Get-Job | Stop-Job
    Get-Job | Remove-Job
    
    Stop-Transcript | Out-Null
    Write-Host "Terminal summary saved to: $SummaryFile" -ForegroundColor Cyan
}