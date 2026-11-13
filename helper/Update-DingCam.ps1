# "Update DingCam" (Start menu shortcut, installed by DingCam-Setup.exe). A small window that checks GitHub for the
# newest DingCam release and, if it's newer than this PC's, downloads its DingCam-Setup-<version>.exe and runs it.
# This is the ONLY part of DingCam that goes online, and only when you open it. The helper itself never does.
param([switch]$Check)   # -Check: print "installed latest" and exit (no window), for testing
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'Holmstien/DingCam'
$appKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{6B3D2F1E-7C4A-4E2B-9A61-D1C9A0E5B7F3}_is1'

function Get-Installed {
    $v = (Get-ItemProperty $appKey -ErrorAction SilentlyContinue).DisplayVersion
    if ($v) { return $v }
    $f = Join-Path $env:LOCALAPPDATA 'DingCam\app\DingCam-Helper.ps1'
    if ((Test-Path $f) -and ((Get-Content $f -Raw) -match "\`$Version = '([^']+)'")) { return $Matches[1] }
    ''
}
function As-Version($s) { try { [version](($s -replace '^v', '') -replace '-.*$', '') } catch { [version]'0.0' } }
function Get-Latest {
    $r = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'DingCam-Updater' } -TimeoutSec 20
    $asset = $r.assets | Where-Object { $_.name -like 'DingCam-Setup-*.exe' } | Select-Object -First 1
    [pscustomobject]@{ Version = ($r.tag_name -replace '^v', ''); Url = $(if ($asset) { $asset.browser_download_url }) }
}

if ($Check) { $l = Get-Latest; "installed=$(Get-Installed) latest=$($l.Version) setup=$($l.Url)"; exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$form = New-Object Windows.Forms.Form
$form.Text = 'Update DingCam'; $form.ClientSize = New-Object Drawing.Size(420, 170)
$form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false; $form.StartPosition = 'CenterScreen'
$ico = Join-Path $PSScriptRoot 'DingCam.ico'
if (Test-Path $ico) { $form.Icon = New-Object Drawing.Icon($ico) }
$label = New-Object Windows.Forms.Label
$label.SetBounds(20, 20, 380, 80); $label.Font = New-Object Drawing.Font('Segoe UI', 10)
$label.Text = 'Checking for a newer DingCam...'
$bar = New-Object Windows.Forms.ProgressBar
$bar.SetBounds(20, 100, 380, 14); $bar.Style = 'Marquee'
$update = New-Object Windows.Forms.Button
$update.SetBounds(214, 126, 90, 30); $update.Text = 'Update'; $update.Visible = $false
$close = New-Object Windows.Forms.Button
$close.SetBounds(310, 126, 90, 30); $close.Text = 'Close'; $close.Add_Click({ $form.Close() })
$form.Controls.AddRange(@($label, $bar, $update, $close)); $form.AcceptButton = $update; $form.CancelButton = $close

$script:latest = $null
$form.Add_Shown({
    $form.Refresh()
    $installed = Get-Installed
    try { $script:latest = Get-Latest }
    catch {
        $bar.Visible = $false
        $label.Text = "Couldn't reach GitHub to check for updates.`nCheck your internet connection and try again."
        return
    }
    $bar.Visible = $false
    if ($installed -and (As-Version $script:latest.Version) -le (As-Version $installed)) {
        $label.Text = "You're up to date.`n`nDingCam $installed is the newest version."
    } elseif (-not $script:latest.Url) {
        $label.Text = "DingCam $($script:latest.Version) is out, but its installer isn't ready yet.`nPlease try again later."
    } else {
        $from = if ($installed) { "from $installed " } else { '' }
        $label.Text = "A new version of DingCam is out: $($script:latest.Version).`n`nClick Update to update ${from}now. Your settings, clips and pictures are kept."
        $update.Visible = $true; $update.Focus()
    }
})
$update.Add_Click({
    $update.Enabled = $false; $close.Enabled = $false; $bar.Visible = $true
    $label.Text = "Downloading DingCam $($script:latest.Version)..."; $form.Refresh()
    try {
        $exe = Join-Path $env:TEMP "DingCam-Setup-$($script:latest.Version).exe"
        (New-Object Net.WebClient).DownloadFile($script:latest.Url, $exe)
        $label.Text = "Updating to DingCam $($script:latest.Version)..."; $form.Refresh()
        $p = Start-Process $exe -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -PassThru
        while (-not $p.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        Remove-Item $exe -ErrorAction SilentlyContinue
        $bar.Visible = $false
        $now = Get-Installed
        if ($p.ExitCode -eq 0 -and $now -eq $script:latest.Version) {
            $label.Text = "Done! DingCam is updated to $now.`n`nThe helper restarted by itself. Type /reload in game if it's open."
        } else {
            $label.Text = "The update didn't finish (code $($p.ExitCode)).`nYou can download DingCam-Setup from github.com/$repo/releases and run it."
        }
    } catch {
        $bar.Visible = $false
        $label.Text = "The update couldn't be downloaded:`n$($_.Exception.Message)"
    }
    $update.Visible = $false; $close.Enabled = $true; $close.Focus()
})
[void]$form.ShowDialog()
