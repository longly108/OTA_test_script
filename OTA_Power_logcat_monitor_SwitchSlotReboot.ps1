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

Write-Host "Starting OTA/Power monitoring with automated Quiescent Reboot injection..." -ForegroundColor Cyan
Write-Host "Logs will save to: $TargetFolder" -ForegroundColor Gray

# Loop through each device and start a background job for it
foreach ($Device in $DeviceIDs) {
    $JobBlock = {
        param($DeviceID, $Folder, $ScriptTimestamp)
        
        $LogFileName = "ota_quiescent_${DeviceID}_${ScriptTimestamp}.log"
        $OutputFile = Join-Path $Folder $LogFileName

        while($true) {
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Waiting for $DeviceID..."
            & adb -s $DeviceID wait-for-device
            
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connected! Capturing logs for $DeviceID..."
            
            # Stream logcat line-by-line to allow simultaneous saving and live parsing
            & adb -s $DeviceID logcat -v threadtime 'update_engine:I' 'update_engine_client:I' 'PowerManagerService:I' 'PowerHAL:I' 'HdmiControlService:I' 'DisplayManagerService:I' 'AndroidRuntime:E' 'DEBUG:I' '*:S' | ForEach-Object {
                $line = $_
                
                # Append line directly to drive with safe UTF-8 encoding
                $line | Out-File -FilePath $OutputFile -Append -Encoding utf8
                
                # UPDATED: Matches the specific snapshot merge initialization log string
                if ($line -like "*Switching snapshot to merge:*") {
                    
                    # 1. Log the actions taken to the text file before losing connection
                    "--- TARGET STRING MATCHED (Switching snapshot to merge:) ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    "--- ACTION: INJECTING AUTOMATED ADB REBOOT QUIESCENT COMMAND NOW ---" | Out-File -FilePath $OutputFile -Append -Encoding utf8
                    
                    # 2. Fire alert signal up to parent process console
                    Write-Output "QUIESCENT_TRIGGERED:${DeviceID}"
                    
                    # 3. UPDATED: FORCE IMMEDIATE QUIESCENT REBOOT INJECTION
                    & adb -s $DeviceID reboot quiescent
                }
            }
            
            # The reboot drops the interface connection, bringing execution out of the logcat pipe to here
            Write-Output "STATUS:[$(Get-Date -Format 'HH:mm:ss')] Connection broken for $DeviceID (Device is restarting in Quiescent mode)."
            Start-Sleep -Seconds 5
        }
    }
    
    # Safely pass parameters into the background workers
    Start-Job -ScriptBlock $JobBlock -ArgumentList $Device, $TargetFolder, $Timestamp | Out-Null
    Write-Host "Started background monitoring for: $Device" -ForegroundColor Green
}

Write-Host "======================================================="
Write-Host "All 5 devices are being monitored in the background." -ForegroundColor Cyan
Write-Host "The system will auto-reboot quiescent immediately upon seeing 'Switching snapshot to merge:'." -ForegroundColor Yellow
Write-Host "Press Ctrl+C to stop all logging and exit." -ForegroundColor Yellow
Write-Host "======================================================="

# Load the GUI presentation framework package for the desktop prompt window
Add-Type -AssemblyName PresentationFramework

try {
    while($true) {
        # Fetch output blocks returning from the background daemons
        $jobOutputs = Get-Job | Receive-Job
        
        foreach ($output in $jobOutputs) {
            if ($output -like "QUIESCENT_TRIGGERED:*") {
                $MatchedDevice = $output.Split(":")[1]
                
                # 1. Trigger Sound Alert (Arpeggio Beep Sequence)
                [Console]::Beep(523, 150) # C5
                [Console]::Beep(659, 150) # E5
                [Console]::Beep(784, 250) # G5
                
                # 2. Flash Red Warning Window in Console
                Write-Host "`n=======================================================" -ForegroundColor White -BackgroundColor Red
                Write-Host " AUTOMATED QUIESCENT REBOOT INJECTED ON DEVICE: $MatchedDevice " -ForegroundColor White -BackgroundColor Red
                Write-Host " Snapshot framework state changed to merge sequence.   " -ForegroundColor White -BackgroundColor Red
                Write-Host "=======================================================\n" -ForegroundColor White -BackgroundColor Red
                
                # 3. Show explicit Windows GUI Prompt box detailing the exact percentage captured
                [System.Windows.MessageBox]::Show("Device ID: $MatchedDevice has reached targeted merge state:`n`nString Matched: Switching snapshot to merge:`n`nAn 'adb reboot quiescent' command was executed instantly.", "Automated Quiescent Reboot Notification")
            }
            elseif ($output -like "STATUS:*") {
                # Output standard connectivity changes cleanly to prompt line
                Write-Host ($output.Substring(7)) -ForegroundColor Gray
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