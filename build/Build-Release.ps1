# Builds the two release zips into dist\:
#   DingCam-<version>.zip        the full download for GitHub Releases (installer, helper, addon, README)
#   DingCam-addon-<version>.zip  just the DingCam addon folder, for CurseForge
# The version comes from the addon's .toc ("## Version:") and is stamped into the helper copy.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$toc = Get-Content "$root\addon\DingCam\DingCam.toc" -Raw
if ($toc -notmatch '## Version:\s*(\S+)') { throw 'No "## Version:" in DingCam.toc' }
$version = $Matches[1]
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Zip entries always use "/" (Compress-Archive in Windows PowerShell writes "\", which some tools mishandle).
function New-Zip($path, $entries) {
    if (Test-Path $path) { Remove-Item $path -Force }
    $zip = [IO.Compression.ZipFile]::Open($path, 'Create')
    try {
        foreach ($e in $entries) {
            if ($e.Text) {
                $entry = $zip.CreateEntry($e.Name, 'Optimal')
                $w = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
                $w.Write($e.Text); $w.Dispose()
            } else {
                [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $e.File, $e.Name, 'Optimal')
            }
        }
    } finally { $zip.Dispose() }
}

$top = "DingCam-$version"
$helper = (Get-Content "$root\helper\DingCam-Helper.ps1" -Raw) -replace "\`$Version = '[^']*'", "`$Version = '$version'"
$full = @(
    @{ Name = "$top/Install DingCam.cmd";   File = "$root\Install DingCam.cmd" }
    @{ Name = "$top/Uninstall DingCam.cmd"; File = "$root\Uninstall DingCam.cmd" }
    @{ Name = "$top/README.md";             File = "$root\README.md" }
    @{ Name = "$top/helper/DingCam-Helper.ps1";    Text = $helper }
    @{ Name = "$top/helper/Install-DingCam.ps1";   File = "$root\helper\Install-DingCam.ps1" }
    @{ Name = "$top/helper/Uninstall-DingCam.ps1"; File = "$root\helper\Uninstall-DingCam.ps1" }
)
if (Test-Path "$root\LICENSE") { $full += @{ Name = "$top/LICENSE"; File = "$root\LICENSE" } }
$addon = @(Get-ChildItem "$root\addon\DingCam" -File | % { @{ Name = "DingCam/$($_.Name)"; File = $_.FullName } })
if (Test-Path "$root\LICENSE") { $addon += @{ Name = 'DingCam/LICENSE'; File = "$root\LICENSE" } }   # MIT: copies carry the notice
$full += $addon | % { @{ Name = "$top/addon/$($_.Name)"; File = $_.File } }

New-Zip (Join-Path $dist "DingCam-$version.zip") $full
New-Zip (Join-Path $dist "DingCam-addon-$version.zip") $addon
Get-ChildItem $dist -Filter "*$version.zip" | % { "{0}  ({1} KB)" -f $_.Name, [Math]::Round($_.Length / 1KB) }
