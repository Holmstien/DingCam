# DingCam helper: the PC side of the DingCam addon. Runs hidden in the background while you're signed in to Windows.
# By Holmstein (built with Claude). https://github.com/Holmstien/DingCam
# The DingCam addon:
#   - on a level-up, boss kill or rare kill takes a .tga screenshot 0.5 s later. That is the "save a clip" signal:
#     your own screenshots are .jpg, so they never trigger anything.
#   - on a level-up also takes a normal .jpg 5 s after the ding (the "You've Reached Level N" banner).
#   - takes normal .jpg shots for blue/purple loot (tooltip flash) and the first visit to each zone.
#   - logs everything in its SavedVariables (written at logout or /reload).
# This helper:
#   1. Sees the .tga, waits 5 s (25 s for the level 60 "big moment"), presses NVIDIA's "Save Instant Replay" hotkey
#      and hard-links the clip (from NVIDIA's save folder) into Level-ups\_New.
#   2. Moves the .tga out of Screenshots into Instant\_New, converted to .jpg.
#   3. Copies the banner .jpg (4-5.5 s after the .tga) into Banner\_New. The original stays in Screenshots.
#   4. When the SavedVariables update, files everything per character:
#      dings  -> Level-ups / Instant / Banner \<Char>\Level NN - Zone - 1d 4h played - <time>
#      bosses -> Bosses\<Char>\<Boss> - <Zone> - <time>  (clip + instant shot), rares -> Rares\<Char>\...
#      loot   -> Loot\<Char>\<Item> - <Zone> - <time>.jpg, zones -> Zones\<Char>\<Zone> - Level NN - <time>.jpg (copies)
#      Optional companion addons, if installed: DingCam Extras (Moments, Zones arrival clips, Flight paths,
#      Professions, Quests, a partner's dings) and Session Recap (diary exported to Diary\<Char>.txt).
# Your own screenshots are never moved, renamed or deleted.
#
# Settings: %APPDATA%\DingCam\settings.json (created on first run). Every value left blank is found automatically.
# Log:      %LOCALAPPDATA%\DingCam\dingcam.log
param(
    [switch]$Once,        # fire a single save immediately and exit (for testing)
    [switch]$Check,       # print what was found (folders, hotkey, Instant Replay, addon) as JSON and exit; used by the installer
    [string]$Settings     # use another settings file (for testing); default %APPDATA%\DingCam\settings.json
)

$Version = '1.0.0-dev'

# ---------------------------------------------------------------- settings
if (-not $Settings) { $Settings = Join-Path $env:APPDATA 'DingCam\settings.json' }
# The log sits in %LOCALAPPDATA%\DingCam, or next to a settings file given with -Settings (test runs stay separate).
$dataDir = if ($PSBoundParameters.ContainsKey('Settings')) { Split-Path ([IO.Path]::GetFullPath($Settings)) } else { Join-Path $env:LOCALAPPDATA 'DingCam' }
New-Item -ItemType Directory -Force $dataDir | Out-Null
$log = Join-Path $dataDir 'dingcam.log'

function Log($m) {
    if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item $log ($log -replace '\.log$', '.old.log') -Force }
    Add-Content -Path $log -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m)
}

if (-not (Test-Path $Settings)) {
    New-Item -ItemType Directory -Force (Split-Path $Settings) | Out-Null
    $default = [ordered]@{
        _help         = 'Leave a value empty ("") and DingCam finds it automatically. Restart the helper after editing.'
        WowFolder     = ''   # the World of Warcraft folder (the one containing _retail_, _classic_, ...)
        JourneyFolder = ''   # where your clips and pictures are filed; empty = Videos\DingCam Journey
        ClipFolder    = ''   # where NVIDIA saves Instant Replay clips; empty = NVIDIA's own setting
        SaveHotkey    = ''   # e.g. "Alt+F10"; empty = NVIDIA's "Save the last ... minutes" hotkey; "none" = never press
    }
    [IO.File]::WriteAllText($Settings, ($default | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
}
$cfg = Get-Content $Settings -Raw | ConvertFrom-Json

# The World of Warcraft folder: the setting, else where Battle.net says it installed it, else the usual places.
function Find-WowFolder {
    $cands = @()
    $db = Join-Path $env:ProgramData 'Battle.net\Agent\product.db'
    if (Test-Path $db) {
        $s = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($db))
        $cands += [regex]::Matches($s, '[A-Za-z]:[\\/][ -~]{3,200}') | % { if ($_.Value -match '^(.*?World of Warcraft)') { $Matches[1] -replace '/', '\' } }
    }
    foreach ($d in [IO.DriveInfo]::GetDrives() | ? { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
        foreach ($rel in 'Program Files (x86)\World of Warcraft', 'Program Files\World of Warcraft', 'World of Warcraft', 'Games\World of Warcraft') {
            $cands += Join-Path $d.RootDirectory.FullName $rel
        }
    }
    foreach ($c in $cands) { if (Get-ChildItem $c -Directory -Filter '_*_' -ErrorAction SilentlyContinue) { return $c } }
    $null
}

# NVIDIA's save folder (the NVIDIA app / GeForce Experience keep it in the registry), else Videos.
function Find-ClipFolder {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS' -ErrorAction Stop).DefaultPathW
        if ($v -is [byte[]]) { $p = [Text.Encoding]::Unicode.GetString($v).TrimEnd([char]0); if ($p -and (Test-Path $p)) { return $p } }
    } catch { }
    [Environment]::GetFolderPath('MyVideos')
}

$wow     = if ($cfg.WowFolder) { $cfg.WowFolder } else { Find-WowFolder }
$clipDir = if ($cfg.ClipFolder) { $cfg.ClipFolder } else { Find-ClipFolder }
$journey = if ($cfg.JourneyFolder) { $cfg.JourneyFolder } else { Join-Path ([Environment]::GetFolderPath('MyVideos')) 'DingCam Journey' }
$nvSettings = "$env:LOCALAPPDATA\NVIDIA Corporation\NVIDIA Overlay\ShareSettings.json"

$clipRoot    = Join-Path $journey 'Level-ups'   # one subfolder per character
$bannerRoot  = Join-Path $journey 'Banner'
$instantRoot = Join-Path $journey 'Instant'     # the 0.5 s glow shots
$lootRoot    = Join-Path $journey 'Loot'
$bossRoot    = Join-Path $journey 'Bosses'
$rareRoot    = Join-Path $journey 'Rares'
$zoneRoot    = Join-Path $journey 'Zones'
$momentRoot  = Join-Path $journey 'Moments'       # DingCam Extras: Clip that!, first mount, clutch survivals
$flightRoot  = Join-Path $journey 'Flight paths'
$profRoot    = Join-Path $journey 'Professions'
$questRoot   = Join-Path $journey 'Quests'
$diaryRoot   = Join-Path $journey 'Diary'          # Session Recap diary, one text file per character
$pendingName = '_New (filed at logout or reload)'

# One helper per settings file (a test copy with its own settings can run next to the real one).
$mutexName = if ($PSBoundParameters.ContainsKey('Settings')) { 'Local\DingCamHelper-' + ($Settings -replace '[^A-Za-z0-9]', '_') } else { 'Local\DingCamHelper' }
if (-not $Check) {
    $mutex = New-Object Threading.Mutex($false, $mutexName)
    if (-not $mutex.WaitOne(0)) { exit }   # already running
}

if (-not $wow -and -not $Check) {
    Log 'World of Warcraft folder not found. Set "WowFolder" in the settings file, then restart the helper.'
    exit 1
}

Add-Type -Namespace DingCam -Name Keys -MemberDefinition @'
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
[DllImport("user32.dll")] public static extern uint MapVirtualKey(uint code, uint mapType);
'@

# WoW's .tga screenshot -> .jpg (uncompressed or RLE, 24 or 32 bit), so no outside converter is needed.
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System; using System.IO; using System.Drawing; using System.Drawing.Imaging; using System.Runtime.InteropServices;
namespace DingCam {
public static class Tga {
    public static void ToJpeg(string src, string dst, long quality) {
        byte[] d = File.ReadAllBytes(src);
        int idLen = d[0], cmapType = d[1], type = d[2];
        int cmapLen = d[5] | (d[6] << 8), cmapDepth = d[7];
        int w = d[12] | (d[13] << 8), h = d[14] | (d[15] << 8), bpp = d[16], desc = d[17];
        if (cmapType != 0 || (type != 2 && type != 10) || (bpp != 24 && bpp != 32))
            throw new NotSupportedException("TGA type " + type + ", " + bpp + " bit");
        int bp = bpp / 8, pos = 18 + idLen + cmapLen * ((cmapDepth + 7) / 8), n = w * h, i = 0;
        byte[] px = new byte[n * 4];
        while (i < n) {
            int count = 1; bool repeat = false;
            if (type == 10) { int hdr = d[pos++]; count = (hdr & 0x7f) + 1; repeat = (hdr & 0x80) != 0; }
            for (int k = 0; k < count && i < n; k++, i++) {
                int s = repeat ? pos : pos + k * bp;
                px[i * 4] = d[s]; px[i * 4 + 1] = d[s + 1]; px[i * 4 + 2] = d[s + 2]; px[i * 4 + 3] = 255;
            }
            pos += repeat ? bp : count * bp;
        }
        bool topDown = (desc & 0x20) != 0;
        using (var bmp = new Bitmap(w, h, PixelFormat.Format32bppRgb)) {
            var bd = bmp.LockBits(new Rectangle(0, 0, w, h), ImageLockMode.WriteOnly, PixelFormat.Format32bppRgb);
            for (int y = 0; y < h; y++) {
                int row = topDown ? y : h - 1 - y;
                Marshal.Copy(px, row * w * 4, new IntPtr(bd.Scan0.ToInt64() + (long)y * bd.Stride), w * 4);
            }
            bmp.UnlockBits(bd);
            var codec = Array.Find(ImageCodecInfo.GetImageEncoders(), c => c.MimeType == "image/jpeg");
            var ep = new EncoderParameters(1);
            ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
            bmp.Save(dst, codec, ep);
        }
    }
}
}
'@

function Clean($s) { ($s -replace '[\\/:*?"<>|]', '').Trim() }

# "Alt+F10" -> virtual-key codes. Modifiers, F1-F24, letters and digits.
function Parse-Hotkey($text) {
    foreach ($part in $text -split '\+' | % { $_.Trim().ToUpper() }) {
        switch -regex ($part) {
            '^(ALT)$'          { 0x12; break }
            '^(CTRL|CONTROL)$' { 0x11; break }
            '^SHIFT$'          { 0x10; break }
            '^WIN$'            { 0x5B; break }
            '^F([1-9]|1\d|2[0-4])$' { 0x6F + [int]$Matches[1]; break }
            '^[A-Z0-9]$'       { [int][char]$part; break }
            default            { throw "Unknown key '$part' in SaveHotkey" }
        }
    }
}

# The keys that save an Instant Replay: the setting, else NVIDIA's own "DVRSave" shortcut, else Alt+F10.
function Get-SaveKeys {
    if ($cfg.SaveHotkey -eq 'none') { return @() }
    if ($cfg.SaveHotkey) { return @(Parse-Hotkey $cfg.SaveHotkey) }
    try { $k = @((Get-Content $nvSettings -Raw | ConvertFrom-Json).settings.shortcuts.DVRSave); if ($k.Count) { return [int[]]$k } } catch { }
    @(0x12, 0x79)
}

# Virtual-key codes -> "Alt+F10".
function Format-Hotkey($vks) {
    if (-not $vks) { return 'none' }
    (@($vks) | % {
        switch ($_) { 0x12 { 'Alt' } 0x11 { 'Ctrl' } 0x10 { 'Shift' } 0x5B { 'Win' }
                      default { if ($_ -ge 0x70 -and $_ -le 0x87) { 'F' + ($_ - 0x6F) } else { [string][char]$_ } } }
    }) -join '+'
}

if ($Check) {
    $replayOn = $null; $replaySec = 0
    try { $v = (Get-Content $nvSettings -Raw | ConvertFrom-Json).settings.video; $replayOn = [bool]$v.irEnabled; $replaySec = [int]$v.irBufferLength } catch { }
    $addonIn = if ($wow) { @(Get-ChildItem "$wow\_*_\Interface\AddOns\DingCam\DingCam.toc" -ErrorAction SilentlyContinue | % { $_.Directory.Parent.Parent.Parent.Name }) } else { @() }
    [pscustomobject]@{
        Version = $Version; Settings = $Settings; Log = $log
        WowFolder = $wow; ClipFolder = $clipDir; JourneyFolder = $journey
        SaveHotkey = Format-Hotkey (Get-SaveKeys)
        Nvidia = (Test-Path $nvSettings); ReplayOn = $replayOn; ReplaySeconds = $replaySec
        AddonIn = $addonIn
    } | ConvertTo-Json -Compress
    exit
}

function Send-Keys($vks) {
    foreach ($vk in $vks) {
        [DingCam.Keys]::keybd_event([byte]$vk, [byte][DingCam.Keys]::MapVirtualKey($vk, 0), 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 40
    for ($i = $vks.Count - 1; $i -ge 0; $i--) {
        [DingCam.Keys]::keybd_event([byte]$vks[$i], [byte][DingCam.Keys]::MapVirtualKey($vks[$i], 0), 2, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40
    }
}

$script:bigMoment = $false   # armed when the newest ding on record is level 59: the 60 ding gets extra time after it
function Save-Clip($dingTime) {
    $wait = if ($script:bigMoment) { 25 } else { 5 }   # wait so the moment (and, at 60, the celebration) lands inside the clip
    Start-Sleep -Seconds $wait
    $t0 = Get-Date
    $keys = @(Get-SaveKeys)
    if ($keys.Count) { Send-Keys $keys; Log "Signal seen: pressed the Instant Replay save hotkey after $wait s." }
    else { Log "Signal seen: SaveHotkey is ""none"", so no key was pressed (waiting for a clip anyway)." }
    $deadline = $t0.AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $clip = Get-ChildItem $clipDir -Recurse -Filter *.mp4 -File -ErrorAction SilentlyContinue |
                ? { $_.CreationTime -gt $t0.AddSeconds(-3) } | Sort CreationTime | Select -Last 1
        if (-not $clip) { continue }
        try { $s = [IO.File]::Open($clip.FullName, 'Open', 'Read', 'None'); $s.Close() } catch { continue }   # still being written
        $newDir = Join-Path $clipRoot $pendingName
        New-Item -ItemType Directory -Force $newDir | Out-Null
        $dest = Join-Path $newDir ("Ding {0:yyyy-MM-dd HH-mm-ss}.mp4" -f $dingTime)
        try { New-Item -ItemType HardLink -Path $dest -Target $clip.FullName -ErrorAction Stop | Out-Null }
        catch { Copy-Item $clip.FullName $dest }
        Log "Clip saved: $($clip.FullName) -> $dest"
        if ($script:lastFail) { $script:lastFail = $null; Update-Status }
        return
    }
    Log "No clip appeared in $clipDir within 45 s. Is NVIDIA Instant Replay turned on (Alt+Z > Instant Replay)?"
    $script:lastFail = '{0:MMM d, h:mm tt}' -f $dingTime; Update-Status
    Notify 'DingCam: clip NOT saved' 'NVIDIA Instant Replay looks off. Press Alt+Z and turn Instant Replay on.'
}

function Notify($title, $text) {
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $t = $xml.GetElementsByTagName('text'); [void]$t.Item(0).AppendChild($xml.CreateTextNode($title)); [void]$t.Item(1).AppendChild($xml.CreateTextNode($text))
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
    } catch { Log "Notification failed: $($_.Exception.Message)" }
}

function Save-Instant($path, $dingTime) {
    # Move the .tga out of the game's Screenshots folder into Instant\_New, as .jpg (falls back to moving the .tga).
    $newDir = Join-Path $instantRoot $pendingName
    New-Item -ItemType Directory -Force $newDir | Out-Null
    $base = Join-Path $newDir ("Ding {0:yyyy-MM-dd HH-mm-ss}" -f $dingTime)
    for ($i = 0; $i -lt 20; $i++) {   # wait until WoW has finished writing it
        try { $s = [IO.File]::Open($path, 'Open', 'Read', 'None'); $s.Close(); break } catch { Start-Sleep -Milliseconds 250 }
    }
    try { [DingCam.Tga]::ToJpeg($path, "$base.jpg", 92) } catch { Log "Conversion failed: $($_.Exception.Message)" }
    if ((Test-Path "$base.jpg") -and (Get-Item "$base.jpg").Length -gt 10KB) {
        Remove-Item $path -Force
        Log "Instant shot saved: $path -> $base.jpg"
    } else {
        Move-Item $path "$base.tga" -Force
        Log "Instant shot moved as .tga (conversion failed): $path -> $base.tga"
    }
}

function Save-Banner($path, $dingTime) {
    $newDir = Join-Path $bannerRoot $pendingName
    New-Item -ItemType Directory -Force $newDir | Out-Null
    $dest = Join-Path $newDir ("Ding {0:yyyy-MM-dd HH-mm-ss}{1}" -f $dingTime, [IO.Path]::GetExtension($path))
    Start-Sleep -Milliseconds 500   # let WoW finish writing it
    Copy-Item $path $dest
    $script:bannerSources[$path] = 1
    $script:bannerOf[$dest] = $path
    Log "Banner saved: $path -> $dest"
}
$script:bannerSources = @{}   # screenshots already used as banners (so loot/zone filing doesn't claim them)
$script:bannerOf = @{}        # pending banner copy -> its source screenshot

# Tells the addon (read at login or /reload): Instant Replay on/off and length, last failed clip, level 60 mode armed,
# and when the helper last checked in (so the addon can tell you if the helper isn't running).
$script:lastFail = $null
function Update-Status {
    $on = $null; $len = 0
    try { $v = (Get-Content $nvSettings -Raw | ConvertFrom-Json).settings.video; $on = [bool]$v.irEnabled; $len = [int]$v.irBufferLength } catch { }
    $seen = [Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / 60) * 60   # to the minute, so the file changes at most once a minute
    $lua = "-- Written by the DingCam helper on your PC. Do not edit.`r`nDingCamStatus = {{ replayOff = {0}, lastFail = {1}, bigMoment = {2}, bigMomentChar = `"{4}`", replayLength = {3}, helperVersion = `"{5}`", helperSeen = {6} }}`r`n" -f `
           ($(if ($on -eq $false) { 'true' } else { 'false' })), ($(if ($script:lastFail) { '"' + $script:lastFail + '"' } else { 'nil' })),
           ($(if ($script:bigMoment) { 'true' } else { 'false' })), $len, ($script:bigMomentChar -replace '["\\]', ''), $Version, $seen
    foreach ($d in Get-ChildItem "$wow\_*_\Interface\AddOns\DingCam" -Directory -ErrorAction SilentlyContinue) {
        $p = Join-Path $d.FullName 'Status.lua'
        if (-not (Test-Path $p) -or (Get-Content $p -Raw) -ne $lua) { [IO.File]::WriteAllText($p, $lua) }
    }
    if ($on -eq $false -and $script:replayWasOn -and (Get-Process Wow* -ErrorAction SilentlyContinue)) {
        Notify 'DingCam: Instant Replay is OFF' 'Clips will not be saved. Press Alt+Z and turn Instant Replay on.'
    }
    $script:replayWasOn = ($on -ne $false)
}
$script:replayWasOn = $true

# Reads one table (DingCamDB, DingCamEvents, DingCamLoot, DingCamZones; DingCamExtras from DingCamExtras.lua)
# from the addons' SavedVariables.
function Get-SvEntries($varName, $file = 'DingCam.lua') {
    foreach ($sv in Get-ChildItem "$wow\_*_\WTF\Account\*\SavedVariables\$file" -ErrorAction SilentlyContinue) {
        $raw = Get-Content $sv.FullName -Raw
        $block = [regex]::Match($raw, "(?ms)^$varName = \{(.*?)^\}\s*$")   # the table's own closing brace sits alone on its line
        if (-not $block.Success) { continue }
        foreach ($m in [regex]::Matches($block.Groups[1].Value, '\{([^{}]*)\}')) {
            $b = $m.Groups[1].Value
            $g = { param($k) if ($b -match "\[`"$k`"\]\s*=\s*(?:`"((?:[^`"\\]|\\.)*)`"|([^,\r\n]*))") { if ($Matches[1]) { $Matches[1] -replace '\\(.)', '$1' } else { $Matches[2].Trim() } } }
            if (& $g 'time') {
                [pscustomobject]@{ Level = & $g 'level'; Item = & $g 'item'; Name = & $g 'name'; Kind = & $g 'kind'; With = & $g 'with'
                                   Char = & $g 'char'; Zone = & $g 'zone'; Played = & $g 'played'; Test = [bool](& $g 'test')
                                   When = [DateTimeOffset]::FromUnixTimeSeconds([long](& $g 'time')).LocalDateTime }
            }
        }
    }
}

function Format-Played($sec) {
    if (-not $sec) { return $null }
    $t = [TimeSpan]::FromSeconds([double]$sec)
    if ($t.TotalDays -ge 1) { '{0}d {1}h played' -f [int][Math]::Floor($t.TotalDays), $t.Hours } else { '{0}h {1}m played' -f $t.Hours, $t.Minutes }
}

# Level 60 "big moment": armed while the character last saved as playing (DingCamActive, written by the addon at
# login and on each ding, saved on reload/logout) is level 59. Alts don't disarm it unless you're playing them.
$script:bigMomentChar = ''
function Update-BigMoment {
    $armed = $false; $char = ''
    # Oldest first, so the most recently saved game folder has the final say.
    foreach ($sv in Get-ChildItem "$wow\_*_\WTF\Account\*\SavedVariables\DingCam.lua" -ErrorAction SilentlyContinue | Sort LastWriteTime) {
        $m = [regex]::Match((Get-Content $sv.FullName -Raw), '(?ms)^DingCamActive = \{(.*?)^\}\s*$')
        if (-not $m.Success) { continue }
        $b = $m.Groups[1].Value
        if ($b -match '\["level"\]\s*=\s*(\d+)') { $armed = ([int]$Matches[1] -eq 59) }
        if ($b -match '\["char"\]\s*=\s*"([^"]*)"') { $char = $Matches[1] }
    }
    if (-not $armed) { $char = '' }
    if ($armed -ne $script:bigMoment -or $char -ne $script:bigMomentChar) {
        $script:bigMoment = $armed; $script:bigMomentChar = $char
        Log "Level 60 big moment $(if ($armed) { "ARMED for $char" } else { 'off' })."; Update-Status
    }
}

# Files pending clips / instant shots / banners. Each belongs to the closest ding or kill on record.
function File-Pending {
    $entries = $null
    foreach ($root in $clipRoot, $bannerRoot, $instantRoot) {
        $files = Get-ChildItem (Join-Path $root $pendingName) -Filter 'Ding *' -File -ErrorAction SilentlyContinue
        if (-not $files) { continue }
        if ($null -eq $entries) {
            $entries = @(@(Get-SvEntries 'DingCamDB' | % { $_.Kind = 'ding'; $_ }) + @(Get-SvEntries 'DingCamEvents') +
                         @(Get-SvEntries 'DingCamExtras' 'DingCamExtras.lua'))
        }
        foreach ($f in $files) {
            $t = [datetime]::ParseExact($f.BaseName.Substring(5), 'yyyy-MM-dd HH-mm-ss', $null)
            $near = @($entries | ? { [Math]::Abs(($t - $_.When).TotalSeconds) -le 30 } |
                      Sort { [Math]::Abs(($t - $_.When).TotalSeconds) })   # closest first (two quick levels)
            if (-not $near) { continue }
            # One clip can belong to several moments at once (a boss kill that also dings you): the closest moment,
            # plus any other within 3 s of it, each get the file.
            $owners = @($near | ? { [Math]::Abs(($_.When - $near[0].When).TotalSeconds) -le 3 })
            if ($root -eq $bannerRoot) { $owners = @($owners | ? Kind -eq 'ding') }   # only dings have a banner
            if (-not $owners) {   # a "banner" next to a kill was really some other screenshot (loot, zone)
                $src = $script:bannerOf[$f.FullName]
                if ($src) { $script:bannerSources.Remove($src) }   # hand the original back to loot/zone filing
                Remove-Item $f.FullName -Force; continue
            }
            $dests = foreach ($e in $owners) {
                $test = if ($e.Test) { 'TEST ' } else { '' }
                $at = '{0:yyyy-MM-dd HH-mm-ss}' -f $e.When
                switch ($e.Kind) {
                    'ding' {
                        $played = Format-Played $e.Played
                        $name = "{0}Level {1:D2} - {2}{3} - {4:yyyy-MM-dd HH-mm}{5}" -f $test, [int]$e.Level, $e.Zone, ($(if ($played) { " - $played" } else { '' })), $e.When, $f.Extension
                        $destRoot = $root }
                    'partyding' {   # partner's ding while grouped: filed under THEIR character
                        $name = "{0}Level {1:D2} - {2} - with {3} - {4:yyyy-MM-dd HH-mm}{5}" -f $test, [int]$e.Level, $e.Zone, $e.With, $e.When, $f.Extension
                        $destRoot = $root }
                    'boss'       { $destRoot = $bossRoot;   $name = "$test$($e.Name) - $($e.Zone) - $at$($f.Extension)" }
                    'rare'       { $destRoot = $rareRoot;   $name = "$test$($e.Name) - $($e.Zone) - $at$($f.Extension)" }
                    'moment'     { $destRoot = $momentRoot; $name = "$test$($e.Zone) - $at$($f.Extension)" }
                    'firstmount' { $destRoot = $momentRoot; $name = "${test}First mount - $($e.Zone) - $at$($f.Extension)" }
                    'clutch'     { $destRoot = $momentRoot; $name = "${test}Clutch survival - $($e.Zone) - $at$($f.Extension)" }
                    'arrival'    { $destRoot = $zoneRoot;   $name = "$test$($e.Name) - arrival - $at$($f.Extension)" }
                    'flightpath' { $destRoot = $flightRoot; $name = "$test$($e.Name) - $at$($f.Extension)" }
                    'profession' { $destRoot = $profRoot;   $name = "$test$($e.Name) - $($e.Zone) - $at$($f.Extension)" }
                    'quest'      { $destRoot = $questRoot;  $name = "$test$($e.Name) - $at$($f.Extension)" }
                    default      { $destRoot = $momentRoot; $name = "$test$($e.Kind) - $($e.Zone) - $at$($f.Extension)" }
                }
                $charDir = Join-Path $destRoot (Clean $e.Char)
                New-Item -ItemType Directory -Force $charDir | Out-Null
                Join-Path $charDir (Clean $name)
            }
            $dests = @($dests | ? { -not (Test-Path $_) })
            # An instant shot belongs to ONE moment: the closest one still without its picture (two moments at once
            # each took their own shot). Clips and banners are shared by every moment within 3 s.
            if ($root -eq $instantRoot) { $dests = @($dests | Select -First 1) }
            if (-not $dests) {
                if ($root -eq $instantRoot) { Remove-Item $f.FullName -Force; Log "Extra shot of an already-pictured moment removed: $($f.Name)" }
                continue
            }
            foreach ($extra in $dests | Select -Skip 1) {   # extra owners get a hard link (same file, no extra space), or a copy
                try { New-Item -ItemType HardLink -Path $extra -Target $f.FullName -ErrorAction Stop | Out-Null } catch { Copy-Item $f.FullName $extra }
                Log "Filed (also): $($f.Name) -> $extra"
            }
            Move-Item $f.FullName $dests[0]; Log "Filed: $($f.Name) -> $($dests[0])"
        }
    }
}

# Loot and zone shots stay in Screenshots; copies are filed per character. Each screenshot is used once,
# matched to the entry it was taken for (taken within about a second of the logged time).
function File-Copies {
    $shots = @(Get-ChildItem "$wow\_*_\Screenshots\*.jpg" -File -ErrorAction SilentlyContinue | ? { -not $script:bannerSources.ContainsKey($_.FullName) })
    if (-not $shots) { return }
    $todo = @(@(Get-SvEntries 'DingCamLoot' | % { $_.Kind = 'loot'; $_ }) + @(Get-SvEntries 'DingCamZones' | % { $_.Kind = 'zone'; $_ })) | Sort When
    $used = @{}
    foreach ($e in $todo) {
        $test = if ($e.Test) { 'TEST ' } else { '' }
        if ($e.Kind -eq 'loot') {
            $dir = Join-Path $lootRoot (Clean $e.Char)
            $name = "{0}{1} - {2} - {3:yyyy-MM-dd HH-mm-ss}.jpg" -f $test, $e.Item, $e.Zone, $e.When
        } else {
            $dir = Join-Path $zoneRoot (Clean $e.Char)
            $name = "{0} - Level {1:D2} - {2:yyyy-MM-dd HH-mm}.jpg" -f $e.Zone, [int]$e.Level, $e.When
        }
        $dest = Join-Path $dir (Clean $name)
        $target = $e.When.AddSeconds(0.5)   # the logged time is rounded down to the second
        $shot = $shots | ? { -not $used.ContainsKey($_.FullName) } |
                ? { $d = ($_.CreationTime - $e.When).TotalSeconds; $d -ge -1 -and $d -le 4 } |
                Sort { [Math]::Abs(($_.CreationTime - $target).TotalSeconds) } | Select -First 1
        if (-not $shot) { continue }
        $used[$shot.FullName] = 1
        if (Test-Path $dest) { continue }
        New-Item -ItemType Directory -Force $dir | Out-Null
        Copy-Item $shot.FullName $dest
        Log "$(if ($e.Kind -eq 'loot') { 'Loot' } else { 'Zone' }) shot filed: $($shot.Name) -> $dest"
    }
}

# Session Recap diary (optional companion addon) -> Diary\<Character>.txt (one line per session, rewritten when it changes).
function Export-Diary {
    foreach ($sv in Get-ChildItem "$wow\_*_\WTF\Account\*\SavedVariables\SessionRecap.lua" -ErrorAction SilentlyContinue) {
        $block = [regex]::Match((Get-Content $sv.FullName -Raw -Encoding UTF8), '(?ms)^SessionRecapDiary = \{(.*?)^\}\s*$')
        if (-not $block.Success) { continue }
        foreach ($c in [regex]::Matches($block.Groups[1].Value, '\["((?:[^"\\]|\\.)*)"\]\s*=\s*\{([^{}]*)\}')) {
            $char = Clean ($c.Groups[1].Value -replace '\\(.)', '$1')
            $lines = [regex]::Matches($c.Groups[2].Value, '"((?:[^"\\]|\\.)*)"') | % { $_.Groups[1].Value -replace '\\(.)', '$1' }
            if (-not $lines) { continue }
            New-Item -ItemType Directory -Force $diaryRoot | Out-Null
            $path = Join-Path $diaryRoot "$char.txt"
            $text = ($lines -join "`r`n") + "`r`n"
            if (-not (Test-Path $path) -or [IO.File]::ReadAllText($path) -ne $text) {
                [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false)))
                Log "Diary exported: $path ($(@($lines).Count) sessions)"
            }
        }
    }
}

if ($Once) { Save-Clip (Get-Date); File-Pending; exit }

Log "DingCam helper $Version started. WoW: $wow | Clips: $clipDir | Journey: $journey | Save hotkey: $(Format-Hotkey (Get-SaveKeys))"
Update-BigMoment
Update-Status
$seen = @{}
foreach ($d in Get-ChildItem "$wow\_*_\Screenshots" -Directory -ErrorAction SilentlyContinue) { foreach ($p in [IO.Directory]::GetFiles($d.FullName)) { $seen[$p] = 1 } }
$lastDing = [datetime]::MinValue      # creation time of the last .tga signal
$bannerTaken = $true
$svStamp = $null; $lastSvCheck = Get-Date; $lastSvPoll = Get-Date; $lastNvStamp = $null

while ($true) {
  try {
    Start-Sleep -Milliseconds 500
    $now = Get-Date
    $new = foreach ($d in Get-ChildItem "$wow\_*_\Screenshots" -Directory -ErrorAction SilentlyContinue) {
        foreach ($p in [IO.Directory]::GetFiles($d.FullName)) { if (-not $seen.ContainsKey($p)) { $seen[$p] = 1; Get-Item $p } }
    }
    foreach ($f in $new | Sort CreationTime) {
        if ($f.Extension -eq '.tga') {
            if (($f.CreationTime - $lastDing).TotalSeconds -gt 3) {   # a 2nd event seconds later (double level) still gets its own clip
                $lastDing = $f.CreationTime; $bannerTaken = $false
                try { Save-Instant $f.FullName $lastDing } catch { Log "Instant shot error: $($_.Exception.Message)" }
                Save-Clip $lastDing
            } else {
                # A second signal within 3 s (DingCam and DingCam Extras at the same moment): the clip already being
                # saved covers it, and filing gives that clip to every moment within 3 s. Its shot still gets filed.
                try { Save-Instant $f.FullName $f.CreationTime } catch { Log "Instant shot error: $($_.Exception.Message)" }
            }
        } elseif (-not $bannerTaken) {
            $gap = ($f.CreationTime - $lastDing).TotalSeconds
            # banner is taken 4.5 s after the glow shot; tight window so a loot or zone shot can't be mistaken for it
            if ($gap -ge 4.0 -and $gap -le 5.5) { $bannerTaken = $true; Save-Banner $f.FullName $lastDing }
        }
    }
    $nvStamp = (Get-Item $nvSettings -ErrorAction SilentlyContinue).LastWriteTime   # Instant Replay toggled? update the addon's status right away
    if ($nvStamp -ne $lastNvStamp) {
        if ($lastNvStamp) { $script:lastFail = $null }   # NVIDIA settings changed: clear the old "clip not saved" warning
        $lastNvStamp = $nvStamp; Update-Status
    }
    if (($now - $lastSvCheck).TotalSeconds -ge 30) { $lastSvCheck = $now; Update-Status }
    # SavedVariables written (logout or /reload)? File everything and re-check the level 60 arming within ~2 s.
    if (($now - $lastSvPoll).TotalSeconds -ge 2) {
        $lastSvPoll = $now
        # (-Include silently matches nothing with wildcard folders in the path, so each name is listed on its own)
        $stamp = ('DingCam.lua', 'DingCamExtras.lua', 'SessionRecap.lua' | % { Get-ChildItem "$wow\_*_\WTF\Account\*\SavedVariables\$_" -ErrorAction SilentlyContinue } |
                  Measure LastWriteTime -Maximum).Maximum
        if ($stamp -and $stamp -ne $svStamp) { $svStamp = $stamp; Start-Sleep -Milliseconds 500; Update-BigMoment; File-Pending; File-Copies; Export-Diary }
    }
  } catch { Log "Error (helper keeps running): $($_.Exception.Message)"; Start-Sleep -Seconds 2 }
}
