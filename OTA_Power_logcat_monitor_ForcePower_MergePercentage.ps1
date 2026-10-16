# Define your array of device IDs here
$DeviceIDs = @(
    "04200733B0000A96520E",
    "04203913B0000AA3EF65",
    "04219275B0000B34FB78",
    "90000000B0000B1F9D0D",
    "04215947B0000B2B7B6D" 
)

# Force the directory path
$TargetFolder = "D:\LONG"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Ensure the directory exists
if (-not (Test-Path $TargetFolder)) {
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
}

Write-Host "Starting OTA/Power monitoring with automated Hard Power Down (reboot -p) injection..." -ForegroundColor Cyan
Write-Host "Logs will save to: $TargetFolder" -ForegroundColor Gray

# Loop through each device and start a background job for it
foreach ($Device in $DeviceIDs) {
    $JobBlock = {
        param($DeviceID, $Folder, $ScriptTimestamp)
        
        $LogFileName = "ota_powerdown_${DeviceID}_${ScriptTimestamp}.log"
        $OutputFile = Join-Path $Folder $LogFileName

        while($true) {
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Waiting for $DeviceID to be online..."
            & adb -s $DeviceID wait-for-device
            
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connected! Capturing logs for $DeviceID..."
            
            # Stream logcat line-by-line to allow simultaneous saving and live parsing
            & adb -s $DeviceID logcat -v threadtime 'update_engine:I' 'update_engine_client:I' 'PowerManagerService:I' 'PowerHAL:I' 'HdmiControlService:I' 'DisplayManagerService:I' 'AndroidRuntime:E' 'DEBUG:I' '*:S' | ForEach-Object {
                $line = $_
                
                # Append line directly to drive with safe UTF-8 encoding
                $line | Out-File -FilePath $OutputFile -Append -Encoding utf8
                
                # Matches 1%, 23%, or 40% merge progress thresholds using regex grouping
                if ($line -match "Waiting for merge to complete: (1%|23%|40%)") {
                    $MatchedPercent = $Matches[1]
                    
                    # 1. Log the sudden termination to the text file before losing connection
                    "--- TARGET STRING MATCHED (Waiting for merge to complete: $MatchedPercent) ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    "--- ACTION: INJECTING HARD POWER DOWN (reboot -p) SIMULATION NOW ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    
                    # 2. Fire alert signal containing Device ID and the matched percentage up to the host process
                    Write-Output "POWERDOWN_TRIGGERED:${DeviceID}:${MatchedPercent}"
                    
                    # 3. CHANGED: INJECT CRASH POWER DOWN COMMAND
                    & adb -s $DeviceID shell reboot -p
                }
            }
            
            # The hard power off cuts the ADB pipe immediately, bringing execution here
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] 🚨 HARD POWER DOWN EXECUTED on $DeviceID (Device is now offline)."
            Start-Sleep -Seconds 5
        }
    }
    
    # Safely pass parameters into the background workers
    Start-Job -ScriptBlock $JobBlock -ArgumentList $Device, $TargetFolder, $Timestamp | Out-Null
    Write-Host "Started background monitoring for: $Device" -ForegroundColor Green
}

Write-Host "======================================================="
Write-Host "All 5 devices are being monitored in the background." -ForegroundColor Cyan
Write-Host "The system will forcefully shut down devices instantly upon seeing 1%, 23%, or 40% merge." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop all logging and exit." -ForegroundColor Yellow
Write-Host "======================================================="

# Load the GUI presentation framework package for the desktop prompt window
Add-Type -AssemblyName PresentationFramework

try {
    while($true) {
        # Fetch output blocks returning from the background daemons
        $jobOutputs = Get-Job | Receive-Job
        
        foreach ($output in $jobOutputs) {
            if ($output -like "POWERDOWN_TRIGGERED:*") {
                # Unpack Device ID and matched percentage values
                $Parts = $output.Split(":")
                $MatchedDevice = $Parts[1]
                $Percent = $Parts[2]
                
                # 1. Trigger Sound Alert (Warning Cadence Sequence)
                [Console]::Beep(880, 100)
                [Console]::Beep(880, 100)
                [Console]::Beep(587, 300)
                
                # 2. Flash Red Warning Window in Console
                Write-Host "`n=======================================================" -ForegroundColor White -BackgroundColor Red
                Write-Host " CRITICAL POWER CUT SIMULATED ON DEVICE: $MatchedDevice " -ForegroundColor White -BackgroundColor Red
                Write-Host " Snapshot merge reached $Percent. Sent 'reboot -p' kill code. " -ForegroundColor White -BackgroundColor Red
                Write-Host "=======================================================\n" -ForegroundColor White -BackgroundColor Red
                
                # 3. Show explicit Windows GUI Prompt box detailing the exact percentage captured
                [System.Windows.MessageBox]::Show("Device ID: $MatchedDevice has been shut down via software automation:`n`nString Matched: Waiting for merge to complete: $Percent`n`nAn 'adb shell reboot -p' command was executed instantly.", "Automated Hard Power-Down Notification")
            }
            elseif ($output -like "STATUS:*") {
                # Output standard connectivity changes cleanly to prompt line
                $Msg = $output.Substring(7)
                if ($Msg -like "*HARD POWER DOWN EXECUTED*") {
                    Write-Host $Msg -ForegroundColor Red -BackgroundColor Black
                } else {
                    Write-Host $Msg -ForegroundColor Gray
                }
            }
        }
        Start-Sleep -Seconds 1
    }
}
finally {
    # Ensure automated cleanup when dropping suite
    Write-Host "`nStopping all background ADB jobs..." -ForegroundColor Red
    Get-Job | Stop-Job
    Get-Job | Remove-Job
}