# Define your array of device IDs here
$DeviceIDs = @(
    "04200733B0000A96520E",
    "04203913B0000AA3EF65",
    "04219275B0000B34FB78"
)

# Force the directory path from your layout
$TargetFolder = "D:\LONG"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# Ensure the directory exists
if (-not (Test-Path $TargetFolder)) {
    New-Item -ItemType Directory -Path $TargetFolder -Force | Out-Null
}

Write-Host "Starting OTA and Power log capture for multiple devices..." -ForegroundColor Cyan
Write-Host "Logs will save to: $TargetFolder" -ForegroundColor Gray

# Loop through each device and start a background job for it
foreach ($Device in $DeviceIDs) {
    $JobBlock = {
        param($DeviceID, $Folder, $ScriptTimestamp)
        
        # Updated filename pattern to reflect both update engine and power tracking
        $LogFileName = "ota_power_${DeviceID}_${ScriptTimestamp}.log"
        $OutputFile = Join-Path $Folder $LogFileName

        while($true) {
            Write-Output "[$(Get-Date -Format 'HH:mm:ss')] Waiting for $DeviceID..."
            adb -s $DeviceID wait-for-device
            
            Write-Output "[$(Get-Date -Format 'HH:mm:ss')] Connected! Capturing logs for $DeviceID..."
            
            # FILTERS ADDED: 'PowerManagerService:I' and 'PowerHAL:I' to stream power status states
            adb -s $DeviceID logcat -v threadtime update_engine:I update_engine_client:I PowerManagerService:I PowerHAL:I *:S | Out-File -FilePath $OutputFile -Append -Encoding utf8
            
            Write-Output "[$(Get-Date -Format 'HH:mm:ss')] Connection lost for $DeviceID. Retrying..."
            Start-Sleep -Seconds 2
        }
    }
    
    # Safely pass parameters into the background worker
    Start-Job -ScriptBlock $JobBlock -ArgumentList $Device, $TargetFolder, $Timestamp | Out-Null
    Write-Host "Started background monitoring for: $Device" -ForegroundColor Green
}

Write-Host "======================================================="
Write-Host "All devices are being monitored in the background." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop all logging and exit." -ForegroundColor Yellow
Write-Host "======================================================="

try {
    while($true) {
        Get-Job | Receive-Job
        Start-Sleep -Seconds 1
    }
}
finally {
    Write-Host "`nStopping all background ADB jobs..." -ForegroundColor Red
    Get-Job | Stop-Job
    Get-Job | Remove-Job
}