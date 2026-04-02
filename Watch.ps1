$folder = "C:\Users\ohkod\OneDrive\Desktop\lucent-roblox\src"
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $folder
$watcher.IncludeSubdirectories = $true
$watcher.EnableRaisingEvents = $true
$watcher.Filter = "*.luau"

$action = {
    $path = $Event.SourceEventArgs.FullPath
    $type = $Event.SourceEventArgs.ChangeType
    $time = Get-Date -Format "HH:mm:ss"
    Write-Host "`n[$time] $type : $path" -ForegroundColor Cyan
    if ($type -ne "Deleted") {
        Start-Sleep -Milliseconds 100
        Get-Content $path | ForEach-Object { Write-Host "  $_" -ForegroundColor Gray }
    }
}

Register-ObjectEvent $watcher "Created" -Action $action | Out-Null
Register-ObjectEvent $watcher "Changed" -Action $action | Out-Null

Write-Host "Watching src/ for changes... (Ctrl+C to stop)" -ForegroundColor Yellow
while ($true) { Start-Sleep -Seconds 1 }