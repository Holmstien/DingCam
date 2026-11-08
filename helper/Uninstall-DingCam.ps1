# DingCam uninstaller: stops the helper, removes it from Windows startup and deletes %LOCALAPPDATA%\DingCam\app.
# Your Journey folder (clips and pictures) is never touched. Settings and the log are kept unless -RemoveSettings.
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'DingCam\app'),
    [string]$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',   # testing: another key
    [string]$TaskName = 'DingCam helper',                                      # testing: another task name
    [switch]$RemoveSettings
)

function Ok($t) { Write-Host "  [OK] $t" -ForegroundColor Green }

Write-Host "`nDingCam uninstaller`n" -ForegroundColor White

$file = '-File "' + (Join-Path $InstallDir 'DingCam-Helper.ps1') + '"'
$procs = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | ? { $_.CommandLine -and $_.CommandLine.Contains($file) })
foreach ($p in $procs) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
Ok $(if ($procs.Count) { 'Helper stopped' } else { 'Helper was not running' })

if ((Get-ItemProperty $RunKey -ErrorAction SilentlyContinue).DingCam) { Remove-ItemProperty $RunKey -Name 'DingCam' }
# The 15-minute "keep it running" task, only if it really runs DingCam's launcher.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task -and (@($task.Actions | ? { $_.Arguments -like '*Start-DingCam.vbs*' }).Count)) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Ok 'Removed from Windows startup and the 15-minute check'

# Only delete a folder that really is a DingCam install (guards against a mistyped -InstallDir).
if ((Test-Path (Join-Path $InstallDir 'DingCam-Helper.ps1')) -or (Test-Path (Join-Path $InstallDir 'Start-DingCam.vbs'))) {
    Set-Location $env:TEMP   # in case this script runs from inside the folder being deleted
    Remove-Item $InstallDir -Recurse -Force
}
Ok "Deleted $InstallDir"

if ($RemoveSettings) {
    Remove-Item (Join-Path $env:APPDATA 'DingCam'), (Join-Path $env:LOCALAPPDATA 'DingCam') -Recurse -Force -ErrorAction SilentlyContinue
    Ok 'Settings and log deleted'
}
Write-Host "`nYour Journey folder (clips and pictures) was not touched. The DingCam addon itself is removed in CurseForge" -ForegroundColor White
Write-Host "or by deleting its folder in  World of Warcraft\<your game>\Interface\AddOns.`n" -ForegroundColor White
