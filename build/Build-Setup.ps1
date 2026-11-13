# Builds dist\DingCam-Setup-<version>.exe with Inno Setup, from the release zip that build\Build-Release.ps1 made
# (so the helper inside is the same version-stamped copy). Run Build-Release.ps1 first.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot
$toc = Get-Content "$root\addon\DingCam\DingCam.toc" -Raw
if ($toc -notmatch '## Version:\s*(\S+)') { throw 'No "## Version:" in DingCam.toc' }
$ver = $Matches[1]
$zip = "$root\dist\DingCam-$ver.zip"
if (-not (Test-Path $zip)) { throw "Missing $zip - run Build-Release.ps1 first" }
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found' }
$ff = 'C:\Users\James\PC-fixes\dingcam\ffmpeg\ffmpeg.exe'

$stage = "$PSScriptRoot\stage"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory "$stage\helper" | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$z = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    foreach ($e in $z.Entries | Where-Object { $_.FullName -match '/helper/[^/]+\.ps1$' }) {
        [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path "$stage\helper" $e.Name), $true)
    }
} finally { $z.Dispose() }

Copy-Item "$root\helper\Update-DingCam.ps1", "$root\helper\Update-DingCam.vbs" "$stage\helper\"   # the Start menu updater (Setup only)

# Icon and wizard pictures from the DingCam logo (dark navy background to match it).
$logo = "$root\media\logo-full-1254.png"
& $ff -hide_banner -loglevel error -y -i $logo -vf "scale=256:256" "$stage\DingCam.ico"
& $ff -hide_banner -loglevel error -y -i $logo -vf "scale=110:110" -pix_fmt bgr24 "$stage\wizard-small.bmp"
& $ff -hide_banner -loglevel error -y -f lavfi -i "color=c=0x0b1a33:s=328x628" -i $logo `
    -filter_complex "[1:v]scale=300:300[l];[0:v][l]overlay=(W-w)/2:(H-h)/2-40" -frames:v 1 -pix_fmt bgr24 "$stage\wizard.bmp"

& $iscc /Q "/DAppVer=$ver" "$PSScriptRoot\DingCam.iss"
if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
$out = "$root\dist\DingCam-Setup-$ver.exe"
"Built $out ($([math]::Round((Get-Item $out).Length / 1KB)) KB)"
