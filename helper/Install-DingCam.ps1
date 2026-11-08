# DingCam installer: copies the helper to %LOCALAPPDATA%\DingCam\app, starts it now and every time you sign in to
# Windows, checks every 15 minutes that it's still running (restarting it if not), then checks your setup.
# No admin rights needed. Run it again any time to update or repair: your settings and your Journey folder are kept.
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'DingCam\app'),
    [string]$Settings,                                                       # testing: a settings file for the helper
    [string]$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', # testing: another key, so Windows startup isn't touched
    [string]$TaskName = 'DingCam helper'                                     # testing: another task name
)
$ErrorActionPreference = 'Stop'

function Ok($t)   { Write-Host "  [OK] $t" -ForegroundColor Green }
function Warn($t) { Write-Host "  [!!] $t" -ForegroundColor Yellow }
function Info($t) { Write-Host "       $t" }

# Stops a running helper that was started from $dir (only ours: matched on its exact -File argument).
function Stop-Helper($dir) {
    $file = '-File "' + (Join-Path $dir 'DingCam-Helper.ps1') + '"'
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | ? { $_.CommandLine -and $_.CommandLine.Contains($file) }) {
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
}
function Get-Helper($dir) {
    $file = '-File "' + (Join-Path $dir 'DingCam-Helper.ps1') + '"'
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | ? { $_.CommandLine -and $_.CommandLine.Contains($file) })
}

Write-Host "`nDingCam installer`n" -ForegroundColor White

# 1. Copy the helper in (stopping an older copy first, so an update takes effect).
$helper = Join-Path $InstallDir 'DingCam-Helper.ps1'
$updating = Test-Path $helper
Stop-Helper $InstallDir
New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'DingCam-Helper.ps1') $helper -Force
Copy-Item (Join-Path $PSScriptRoot 'Uninstall-DingCam.ps1') $InstallDir -Force
Get-ChildItem $InstallDir -File | Unblock-File   # downloaded files are marked "from the internet"

# 2. A tiny launcher that starts it with no window, run at every Windows sign-in.
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$helper"""
if ($Settings) { $psArgs += " -Settings ""$Settings""" }
$vbs = Join-Path $InstallDir 'Start-DingCam.vbs'
$vbsCmd = ('powershell.exe ' + $psArgs).Replace('"', '""')   # VBScript escapes a quote inside a string by doubling it
$vbsText = "' Starts the DingCam helper with no window. Written by the DingCam installer.`r`n" +
           'CreateObject("WScript.Shell").Run "' + $vbsCmd + '", 0, False' + "`r`n"
[IO.File]::WriteAllText($vbs, $vbsText, [Text.Encoding]::Unicode)   # UTF-16 so any user-name characters survive
if (-not (Test-Path $RunKey)) { New-Item $RunKey -Force | Out-Null }
Set-ItemProperty -Path $RunKey -Name 'DingCam' -Value ('"{0}\System32\wscript.exe" "{1}"' -f $env:SystemRoot, $vbs)
Ok "$(if ($updating) { 'Updated' } else { 'Installed' }) to $InstallDir"
Ok 'Starts automatically when you sign in to Windows (Task Manager > Startup apps lists it as "wscript")'

# 2b. Every 15 minutes while you're signed in, run the same launcher. If the helper has stopped for any reason, this
# starts it again; if it's running, the extra copy exits at once (the helper allows only one of itself).
$start = (Get-Date).AddMinutes(1).ToString('yyyy-MM-ddTHH:mm:ss')
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$taskXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.3" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>$(& $esc "Keeps the DingCam helper running: every 15 minutes, starts it again if it has stopped. Installed by Install DingCam; removed by Uninstall DingCam.")</Description></RegistrationInfo>
  <Principals><Principal id="Author"><UserId>$sid</UserId><LogonType>InteractiveToken</LogonType></Principal></Principals>
  <Settings>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
  </Settings>
  <Triggers><TimeTrigger><StartBoundary>$start</StartBoundary><Repetition><Interval>PT15M</Interval></Repetition></TimeTrigger></Triggers>
  <Actions Context="Author"><Exec><Command>$(& $esc "$env:SystemRoot\System32\wscript.exe")</Command><Arguments>$(& $esc "//B //Nologo `"$vbs`"")</Arguments></Exec></Actions>
</Task>
"@
try {
    Register-ScheduledTask -TaskName $TaskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null
    Ok 'Checks every 15 minutes that it is still running, and starts it again if not'
} catch {
    Warn "Couldn't set up the 15-minute check ($($_.Exception.Message)). The helper still starts when you sign in."
}

# 3. Start it now and make sure it's running.
Start-Process "$env:SystemRoot\System32\wscript.exe" -ArgumentList "`"$vbs`""
$running = $false
for ($i = 0; $i -lt 20 -and -not $running; $i++) { Start-Sleep -Milliseconds 500; $running = @(Get-Helper $InstallDir).Count -gt 0 }
if ($running) { Ok 'Running now' } else { Warn 'The helper did not start. Try running this installer again, or restart your PC.' }

# 4. What it found, and anything you need to fix.
$checkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-Check')
if ($Settings) { $checkArgs += '-Settings', $Settings }
$c = ((& powershell @checkArgs) -join "`n") | ConvertFrom-Json
Write-Host "`nYour setup" -ForegroundColor White
if ($c.WowFolder) { Ok "World of Warcraft: $($c.WowFolder)" }
else { Warn 'World of Warcraft not found. Open the settings file below, set "WowFolder", then run this installer again.' }
switch ($c.Recorder) {
    'nvidia' {
        if ($c.ReplayOn -eq $false) { Warn 'Recording with NVIDIA Instant Replay, but it is OFF. Press Alt+Z > Instant Replay > turn it On.' }
        else { Ok "Recording with NVIDIA Instant Replay$(if ($c.ReplaySeconds) { " ($($c.ReplaySeconds) s)" })$(if ($c.ReplaySeconds -and $c.ReplaySeconds -lt 30) { '. Tip: 30 s or more catches the run-up to the moment.' })" }
    }
    'amd' {
        Ok 'Recording with AMD Instant Replay'
        Info 'Make sure it is on: AMD Software (Alt+R) > Record & Stream > Instant Replay.'
    }
    'obs' {
        if ($c.ObsError) { Warn "Recording with OBS, but DingCam can't reach it: $($c.ObsError)"; Info 'In OBS: Tools > WebSocket Server Settings > Enable WebSocket server. Keep OBS open while you play.' }
        elseif ($c.ReplayOn) { Ok 'Recording with the OBS Replay Buffer (running)' }
        else { Warn 'Recording with OBS, but its Replay Buffer is off. In OBS, click "Start Replay Buffer".' }
    }
    default {
        Warn 'No recorder found. DingCam saves clips with NVIDIA or AMD Instant Replay, or with OBS (Replay Buffer).'
        Info 'Screenshots still work without one.'
    }
}
if ($c.Recorder -in 'nvidia', 'amd') {
    if ($c.SaveHotkey -eq 'none') { Warn 'SaveHotkey is set to "none" in the settings file, so no clips will be saved.' }
    else { Ok "Save-clip hotkey: $($c.SaveHotkey)" }
    Ok "Clips are saved in: $($c.ClipFolder)"
}
if ($c.Recorder -ne 'obs' -and $c.ObsInstalled -and -not $c.RecorderFromSettings) {
    Info 'Tip: you have OBS. To record with it instead, turn on its WebSocket server (Tools > WebSocket Server Settings)'
    Info 'and start its Replay Buffer; DingCam then uses OBS automatically whenever it is open.'
}
if (@($c.AddonIn).Count) { Ok "DingCam addon found in: $(@($c.AddonIn) -join ', ')" }
else { Warn 'The DingCam addon is not installed yet. Get it from CurseForge (search "DingCam"), or copy the "addon\DingCam"'; Info 'folder from this download into  World of Warcraft\<your game>\Interface\AddOns' }

Write-Host "`nYour Journey (clips and pictures, one folder per character):" -ForegroundColor White
Info $c.JourneyFolder
Write-Host "Settings: " -NoNewline; Write-Host $c.Settings
Write-Host "Log:      " -NoNewline; Write-Host $c.Log
Write-Host "`nIn game, type  /dingcam test  to save a test clip. To remove DingCam, run 'Uninstall DingCam'.`n" -ForegroundColor White
