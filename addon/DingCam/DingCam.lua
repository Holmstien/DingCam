-- DingCam: on level-up (and boss or rare kills), take one screenshot in TGA format (your normal
-- screenshots stay JPG). A new .tga in the Screenshots folder is the signal the
-- DingCam helper on your PC watches for; it waits a few seconds so the moment is in the clip,
-- then saves a clip with NVIDIA or AMD Instant Replay or OBS's Replay Buffer. Dings are logged in DingCamDB (with /played), kills in
-- DingCamEvents, first zone visits in DingCamZones, loot in DingCamLoot, so the helper can
-- file everything per character after you log out or /reload.
-- Without the helper, moments are saved as normal screenshots (no clips) and you're told how to get it.
-- Every feature has an on/off switch (Options.lua: /dingcam or the minimap button). A moment whose clip, screenshot or
-- banner is switched off is logged with noclip / noshot / nobanner, so the helper files only what was kept.
-- Session Recap is in Recap.lua.
-- Commands: /dingcam (settings) | status | recap | diary | test | gear | loot | dungeon | zone | boss | rare | 59 | warn | remind | clearloot

local _, ns = ...

-- Newer clients hide some unit details ("secret values") inside dungeons and in combat. They can't be used as table
-- keys or compared, so anything secret is skipped (rares are out in the world, where nothing is secret).
local function readable(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
-- The switches (Options.lua loads first). If that file ever failed to load, everything simply stays on.
local opt = ns.opt or function() return true end

-- The name DingCam files a character under: its full name ("Confessor Faithforge"). WoW Forever characters have a
-- second name (UnitName's second value) and only the full name is unique, so no two characters ever share a folder or
-- a diary. Older versions (before 1.3.6) used the first name only. DingCamNames remembers which character those
-- first-name folders and diary belong to, so the helper moves the folders to the full name and the diary carries on.
local cachedKey
local function charKey()
    if cachedKey then return cachedKey end
    local first, second = UnitName("player")
    if not first or first == "" then return first end
    if not second or second == "" then cachedKey = first; return first end   -- no second name: the first name, as always
    local full = first .. " " .. second
    DingCamNames = DingCamNames or {}
    if not DingCamNames[first] then
        -- Old moments saved under this first name are this character's, unless they reached a higher level than this
        -- character has (then they're another character's with the same first name, which claims them when it logs in).
        local top, found = 0, DingCamDiary and DingCamDiary[first] and true or false
        for _, list in ipairs({ DingCamDB, DingCamGear, DingCamZones, DingCamLoot, DingCamEvents }) do
            if type(list) == "table" then
                for _, e in ipairs(list) do
                    if e.char == first then
                        found = true
                        if not e.test and (tonumber(e.level) or 0) > top then top = tonumber(e.level) end
                    end
                end
            end
        end
        if found and top <= (UnitLevel("player") or 1) then DingCamNames[first] = full end
    end
    -- The diary carries on under the full name (older entries first).
    if DingCamNames[first] == full and DingCamDiary and DingCamDiary[first] then
        local old = DingCamDiary[first]
        DingCamDiary[first] = nil
        DingCamDiary[full] = DingCamDiary[full] or {}
        for i = #old, 1, -1 do table.insert(DingCamDiary[full], 1, old[i]) end
    end
    cachedKey = full
    return full
end
ns.charKey = charKey
DingCam_CharKey = charKey   -- DingCam Extras files its moments under the same name

local GLOW_DELAY = 0.5   -- seconds after the ding for the glow screenshot (the golden column is fully up by then)
local BANNER_DELAY = 5 -- seconds after the ding for the banner screenshot
local savedFormat   -- the player's screenshot format, restored right after our shot

local HELPER_URL = "github.com/Holmstien/DingCam"   -- where the PC helper is downloaded
local HELPER_STALE = 300   -- seconds: the helper checks in about once a minute, so older than this means it isn't running

-- Is the PC helper running? It rewrites Status.lua (DingCamStatus.helperSeen) about once a minute while it runs, but WoW
-- reads that file only once, at login or /reload (just before this file loads). So the check is made once, now, and
-- kept for the whole session. (Until 1.3.0 it was re-checked at every moment against that frozen time, so 5 minutes
-- after login the helper looked stopped and moments got plain screenshots instead of clips.)
local helperUp = (function()
    local s = DingCamStatus
    return (s and s.helperSeen and math.abs(time() - s.helperSeen) < HELPER_STALE) and true or false
end)()
local function helperRunning()
    return helperUp
end
ns.helperRunning = helperRunning

-- The oldest PC helper that knows everything this addon does (1.3.0: the on/off switches for clips, screenshots and
-- banners, and the Session Recap diary file; 1.3.6: folders named with the full character name). Raise it only when the addon needs a new helper.
local HELPER_NEEDED = "1.3.6"
local function versionLess(a, b)   -- "1.2.1" < "1.3.0"; a "-dev" suffix is ignored
    local x, y = {}, {}
    for n in tostring(a):gmatch("%d+") do x[#x + 1] = tonumber(n) end
    for n in tostring(b):gmatch("%d+") do y[#y + 1] = tonumber(n) end
    for i = 1, 3 do
        if (x[i] or 0) ~= (y[i] or 0) then return (x[i] or 0) < (y[i] or 0) end
    end
    return false
end
-- The running helper's version when it's older than HELPER_NEEDED, else nil.
local function helperOutdated()
    local v = DingCamStatus and DingCamStatus.helperVersion
    if helperRunning() and v and versionLess(v, HELPER_NEEDED) then return v end
end
ns.helperOutdated = helperOutdated
ns.HELPER_NEEDED = HELPER_NEEDED
local UPDATE_HOW = "To update, download it from " .. HELPER_URL .. " and double-click Install DingCam again " ..
                   "(it replaces the old one and keeps your settings and files)."
local function clipNote()
    return helperRunning() and ", clip saves in 5 seconds." or " (screenshot only: the PC helper isn't running, see /dingcam status)."
end

-- The .tga screenshot is the "save a clip now" signal for the PC helper (dings, boss kills, rare kills).
-- Must be wrapped in a function when used with C_Timer: passing Screenshot itself silently takes no picture.
-- A boss kill that also dings you fires two moments at once: one signal covers both (the helper files the clip
-- under each), and the player's own format is only ever remembered once, never as "tga".
local lastSignal = -100
local function signalShot()
    if GetTime() - lastSignal < 3 then return end
    lastSignal = GetTime()
    if not helperRunning() then   -- nobody to turn a .tga into a clip (it would just pile up): a normal screenshot instead
        Screenshot()
        return
    end
    if not savedFormat then
        local fmt = GetCVar("screenshotFormat")
        savedFormat = (fmt ~= "tga") and fmt or "jpeg"
    end
    SetCVar("screenshotFormat", "tga")
    Screenshot()
end

-- Normal-format screenshots (banner, zone, loot) wait while a .tga signal shot is still in progress,
-- so they can never come out as .tga and be mistaken for a signal.
local function normalShot(after)
    if savedFormat then
        C_Timer.After(0.25, function() normalShot(after) end)
        return
    end
    Screenshot()
    if after then after() end
end

-- /played at each ding. DingCam listens for the played total whenever the game reports it (RestedXP at login, you
-- typing /played) and counts forward with the session clock, exact to the second. If nothing has reported it about
-- 5 s after login, DingCam asks once itself (the normal "Total time played" lines show in chat, as with /played).
-- The chat reply is never hidden: replacing Blizzard's chat function to hide it taints the UI.
local playedBase, playedAt
local function currentPlayed()
    if not playedBase then return nil end
    return math.floor(playedBase + (GetTime() - playedAt))
end

-- The moment's picture: the .tga signal (clip + instant shot) when its clip is on and the helper is running,
-- otherwise a normal screenshot if its screenshot is on. With the clip on and the screenshot off, the .tga is still
-- taken (it starts the clip) and the helper throws the picture away (noshot).
local function momentShot(clip, shot)
    if clip and helperRunning() then
        C_Timer.After(GLOW_DELAY, function() signalShot() end)
    elseif shot then
        C_Timer.After(GLOW_DELAY, function() normalShot() end)
    end
end

-- Tests (/dingcam test, boss, rare) always do everything, whatever the switches say.
local function signal(level, isTest)
    local clip, glow, banner = opt("dingClip"), opt("dingGlow"), opt("dingBanner")
    if isTest then clip, glow, banner = true, true, true end
    if not (clip or glow or banner) then return end
    DingCamDB = DingCamDB or {}
    local entry = {
        level = level,
        time = time(),
        char = charKey(),
        zone = GetRealZoneText() or "",
        played = currentPlayed(),
        test = isTest or nil,
        noclip = (not clip) or nil,
        noshot = (not glow) or nil,
        nobanner = (not banner) or nil,
    }
    table.insert(DingCamDB, entry)
    momentShot(clip, glow)
    -- Banner shot in the normal format once the "You've Reached Level N" banner is up.
    -- The helper recognises it by timing (BANNER_DELAY after the .tga, or after the logged time when there's no clip)
    -- and files it under Banner\<Character>.
    if banner then C_Timer.After(BANNER_DELAY, function() normalShot() end) end
end

-- Boss and rare kills: same clip + instant shot as a ding, logged in DingCamEvents (kind = "boss" or "rare").
local lastEvent = {}
local function killEvent(kind, name, isTest)
    if not readable(name) or name == "" then return end
    local clip, shot = opt(kind .. "Clip"), opt(kind .. "Shot")   -- bossClip / bossShot, rareClip / rareShot
    if isTest then clip, shot = true, true end
    if not (clip or shot) then return end
    if lastEvent[name] and GetTime() - lastEvent[name] < 15 then return end   -- ENCOUNTER_END and BOSS_KILL both fire
    lastEvent[name] = GetTime()
    DingCamEvents = DingCamEvents or {}
    table.insert(DingCamEvents, {
        kind = kind,
        name = name,
        time = time(),
        char = charKey(),
        zone = GetRealZoneText() or "",
        level = UnitLevel("player"),
        test = isTest or nil,
        noclip = (not clip) or nil,
        noshot = (not shot) or nil,
    })
    momentShot(clip, shot)
end

-- Rares: remember rare/rare-elite mobs we see (target, mouseover, nameplates); if one dies while tagged to us
-- (not grey-tapped by someone else), that's a rare kill.
local rares = {}
local function noteRare(unit)
    local c = UnitExists(unit) and UnitClassification(unit)
    if not readable(c) then return end
    local guid = UnitGUID(unit)
    if not readable(guid) then return end
    if (c == "rare" or c == "rareelite") and not UnitIsPlayer(unit) then rares[guid] = UnitName(unit) end
end

-- First visit to a zone (per character): screenshot once the big zone-name text is up.
local ZONE_DELAY = 1.2
local function zoneCheck(delay)
    local zone = GetRealZoneText()
    if not zone or zone == "" then return end
    DingCamCharDB = DingCamCharDB or {}
    DingCamCharDB.zones = DingCamCharDB.zones or {}
    if DingCamCharDB.zones[zone] then return end
    DingCamCharDB.zones[zone] = true
    C_Timer.After(delay or ZONE_DELAY, function()
        normalShot(function()
            DingCamZones = DingCamZones or {}
            table.insert(DingCamZones, { zone = zone, time = time(), char = charKey(), level = UnitLevel("player") })
        end)
    end)
end

-- How to turn on or lengthen each recorder the PC helper can use (DingCamStatus.recorder; older helpers mean NVIDIA).
local RECORDERS = {
    nvidia = { name = "NVIDIA Instant Replay",
               fix = "press |cffffff00Alt+Z|r, open |cffffff00Instant Replay|r and turn it |cffffff00On|r",
               length = "press |cffffff00Alt+Z|r, open |cffffff00Instant Replay|r and set the length to |cffffff001 minute|r (or more)" },
    amd    = { name = "AMD Instant Replay",
               fix = "open |cffffff00AMD Software|r (Alt+R) > Record & Stream and turn |cffffff00Instant Replay|r on",
               length = "in |cffffff00AMD Software|r (Alt+R) > Record & Stream, set the Instant Replay duration to |cffffff001 minute|r (or more)" },
    obs    = { name = "OBS Replay Buffer",
               fix = "in |cffffff00OBS|r, click |cffffff00Start Replay Buffer|r",
               length = "in |cffffff00OBS|r, set Settings > Output > Replay Buffer > Maximum Replay Time to |cffffff0060 s|r (or more)" },
}
local function recorder()
    return RECORDERS[DingCamStatus and DingCamStatus.recorder or "nvidia"] or RECORDERS.nvidia
end
local function plain(s) return (s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end   -- without colour codes, for chat

-- DingCam's own popup window. WoW's shared StaticPopup is avoided on purpose (since 1.3.4): an addon showing it can
-- leave that popup "tainted", and a later Blizzard popup that does a protected action (release spirit, confirmations)
-- then gets blocked with "DingCam has been blocked from an action only available to the Blizzard UI".
local dialog
local function showDialog(text, button1, onButton1, button2, onButton2)
    if not dialog then
        local ok, d = pcall(CreateFrame, "Frame", "DingCamDialog", UIParent, "BasicFrameTemplateWithInset")
        if not ok then d = CreateFrame("Frame", "DingCamDialog", UIParent, "BackdropTemplate") end
        d:SetWidth(420); d:SetPoint("TOP", 0, -140); d:SetFrameStrata("DIALOG"); d:SetClampedToScreen(true)
        d:SetMovable(true); d:EnableMouse(true); d:RegisterForDrag("LeftButton")
        d:SetScript("OnDragStart", d.StartMoving); d:SetScript("OnDragStop", d.StopMovingOrSizing)
        if d.TitleText then d.TitleText:SetText("DingCam") end
        d.text = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        d.text:SetPoint("TOP", 0, -36); d.text:SetWidth(380); d.text:SetJustifyH("CENTER")
        d.b1 = CreateFrame("Button", nil, d, "UIPanelButtonTemplate"); d.b1:SetSize(140, 24)
        d.b2 = CreateFrame("Button", nil, d, "UIPanelButtonTemplate"); d.b2:SetSize(140, 24)
        tinsert(UISpecialFrames, "DingCamDialog")   -- Escape closes it (and does nothing else)
        dialog = d
    end
    local d = dialog
    d.text:SetText(text)
    d:SetHeight(math.max(140, d.text:GetStringHeight() + 96))
    d.b1:ClearAllPoints(); d.b2:ClearAllPoints()
    d.b1:SetText(button1)
    d.b1:SetScript("OnClick", function() d:Hide(); if onButton1 then onButton1() end end)
    if button2 then
        d.b2:SetText(button2)
        d.b2:SetScript("OnClick", function() d:Hide(); if onButton2 then onButton2() end end)
        d.b1:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -6, 16); d.b2:SetPoint("BOTTOMLEFT", d, "BOTTOM", 6, 16)
        d.b2:Show()
    else
        d.b1:SetPoint("BOTTOM", 0, 16); d.b2:Hide()
    end
    d:Show()
    if d.Raise then d:Raise() end
end

-- Level 59: one level to go. Popup (after the banner shot) asking for a longer replay, then Reload UI to arm DingCam.
local ALMOST60_TEXT = "|cffffd100One level to go!|r\n\nYour level 60 moment deserves the full story.\n\nFor a longer clip, %s.\nThen click |cffffff00Reload UI|r and DingCam will film your 60 ding with extra time for the celebration."
local function almost60()
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: one level to go! Get ready for 60.", { r = 1, g = 0.82, b = 0 })
    PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    -- the reload saves DingCamActive, which arms the helper
    showDialog(ALMOST60_TEXT:format(recorder().length), "Reload UI", function() DingCamArmPending = time(); ReloadUI() end, "Later")
end

-- Warning at login/reload if the PC helper (via Status.lua) reports the recorder off or a failed clip.
local function warn(text)
    print("|cffff4040DingCam WARNING:|r " .. text .. " To fix: " .. plain(recorder().fix) .. ", then /reload.")
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: " .. text, ChatTypeInfo["RAID_WARNING"])
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
end

-- The recorder warning popup, with a Reload UI button.
local function warningDialog(what, fix)
    showDialog("|cffe6b85cDingCam|r\n\n" .. what .. "\n\nTo fix: " .. fix .. ".\nThen click |cffffff00Reload UI|r.",
               "Reload UI", function() ReloadUI() end, "Later")
end

-- No helper on the PC (never installed, or not running): moments are still saved, as normal screenshots.
-- Escape just closes it; only the button turns reminders off.
local function noHelperDialog()
    showDialog("|cffe6b85cDingCam|r\n\n|cffff4040The DingCam helper isn't running on your PC.|r\nLevel-ups, boss kills and rares are saved as screenshots only, without video clips.\n\nTo get clips, download the helper from\n|cffffff00" .. HELPER_URL .. "|r\nand run |cffffff00Install DingCam|r. Then type /reload.",
               "Got it", nil, "Don't remind me", function()
                   DingCamNoHelperWarn = true
                   print("|cffe6b85cDingCam|r: OK, no more helper reminders. /dingcam remind turns them back on.")
               end)
end

local function checkStatus()
    local s = DingCamStatus
    if not helperRunning() then
        -- Never seen the helper on this account: maybe they chose screenshots only, so tell them about clips ONCE and
        -- then stay quiet (/dingcam status still explains). If the helper has run here before, it has stopped and their
        -- clips are being lost, so warn at every login until it's back or they click "Don't remind me".
        if not DingCamNoHelperWarn and (DingCamHelperSeen or not DingCamHelperIntro) then
            DingCamHelperIntro = true
            print("|cffff4040DingCam:|r the PC helper isn't running, so moments are saved as screenshots only (no clips). " ..
                  "Get it at " .. HELPER_URL .. ", or type /dingcam status.")
            noHelperDialog()
        end
        return
    end
    DingCamHelperSeen = true
    -- An older helper still makes clips, but doesn't know the newer switches or the diary file: say so once per
    -- needed version, in chat only (/dingcam status and the settings window keep showing it).
    local old = helperOutdated()
    if old and opt("helperUpdate") and DingCamHelperUpdateSeen ~= HELPER_NEEDED then
        DingCamHelperUpdateSeen = HELPER_NEEDED
        print("|cffe6b85cDingCam:|r |cff40ff40new features are here!|r A |cffffff00Session Recap|r of every play session " ..
              "(it opens when you log out, or type /dingcam recap), an |cffffff00on/off switch for every feature|r " ..
              "(type /dingcam), and a |cffffff00minimap button|r.")
        print("|cffe6b85cDingCam:|r your PC helper is version " .. old .. ". Update it to " .. HELPER_NEEDED ..
              " so the new switches for clips and screenshots work fully, your session diary is also saved as a " ..
              "text file, and your folders use your full character name. " .. UPDATE_HOW)
    end
    local rec = recorder()
    if not opt("warnings") then   -- switched off: no clip warnings (/dingcam status still reports them)
        DingCamWarned = nil
    elseif s.replayOff then
        DingCamWarned = true
        warn(rec.name .. " is OFF, so your level-ups will NOT be recorded.")
        warningDialog("|cffff4040" .. rec.name .. " is OFF.|r\nYour level-ups will NOT be recorded.", rec.fix)
    elseif s.lastFail then
        DingCamWarned = true
        warn("your clip from " .. s.lastFail .. " was NOT saved.")
        warningDialog("|cffff4040Your clip from " .. s.lastFail .. " was NOT saved.|r\n" .. rec.name .. " may be off.", rec.fix)
    elseif DingCamWarned then
        DingCamWarned = nil
        print("|cff40ff40DingCam:|r " .. rec.name .. " is on. You're all set, level-ups will be recorded.")
        RaidNotice_AddMessage(RaidWarningFrame, "DingCam: " .. rec.name .. " is on, you're all set.", { r = 0.25, g = 1, b = 0.25 })
    end
    -- At 59: the helper arms the "big moment" for the character it last saw at 59 (DingCamActive, saved on reload/logout).
    -- Armed for us (or we just reloaded from the popup) -> confirm, and nudge if the replay is short. Otherwise ask for a reload.
    if UnitLevel("player") == 59 and not s.replayOff and opt("bigMoment") then
        local me = charKey()
        local armed = (s.bigMoment and s.bigMomentChar == me) or (DingCamArmPending and time() - DingCamArmPending < 600)
        DingCamArmPending = nil
        if not armed then
            almost60()
            return
        end
        local len = s.replayLength or 0   -- 0: the recorder doesn't report its length (AMD, OBS)
        if len >= 60 then
            print("|cffffd100DingCam:|r Ready for your level 60 moment. The clip will run " .. len .. " s with extra time after the ding.")
            RaidNotice_AddMessage(RaidWarningFrame, "DingCam is ready for your level 60 moment.", { r = 1, g = 0.82, b = 0 })
        elseif len > 0 then
            print("|cffffd100DingCam:|r Ready for 60, but " .. rec.name .. " is only " .. len .. " s. For the full moment, " .. plain(rec.length) .. ".")
            RaidNotice_AddMessage(RaidWarningFrame, "DingCam: set " .. rec.name .. " to 1 minute for your 60 ding.", { r = 1, g = 0.82, b = 0 })
        else
            print("|cffffd100DingCam:|r Ready for your level 60 moment. For the full celebration, " .. plain(rec.length) .. ".")
            RaidNotice_AddMessage(RaidWarningFrame, "DingCam is ready for your level 60 moment.", { r = 1, g = 0.82, b = 0 })
        end
    end
end

-- Loot shots: a looted blue/purple item (Bind-on-Equip in the world; anything in a dungeon or raid) is flashed as a tooltip mid-screen just long enough to be
-- screenshotted (normal format), then hidden as soon as WoW reports the screenshot saved.
-- Logged in DingCamLoot; the helper files the picture under Loot\<Character> at logout or /reload.
local LOOT_SHOT_DELAY = 0.1   -- seconds after the tooltip appears (lets it render for one frame)
local LOOT_GAP = 0.5          -- pause before the next drop's tooltip when one mob dropped several

local lootTip = CreateFrame("GameTooltip", "DingCamLootTip", UIParent, "GameTooltipTemplate")
local scanTip = CreateFrame("GameTooltip", "DingCamScanTip", nil, "GameTooltipTemplate")
scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function isBindOnEquip(link)
    local bindType = select(14, GetItemInfo(link))
    if bindType then return bindType == 2 end
    scanTip:ClearLines()
    scanTip:SetHyperlink(link)
    for i = 2, math.min(scanTip:NumLines(), 5) do
        local line = _G["DingCamScanTipTextLeft" .. i]
        if line and line:GetText() == ITEM_BIND_ON_EQUIP then return true end
    end
    return false
end

-- Several drops from one corpse are shown one after another, each with its own screenshot.
local lootQueue, lootBusy, lootShooting, fallbackTimer = {}, false, false, nil
local showNextLoot

-- Called when WoW reports our screenshot saved (or after a 2 s fallback): hide at once, then do the next drop.
local function lootDone()
    if not lootShooting then return end
    lootShooting = false
    if fallbackTimer then fallbackTimer:Cancel(); fallbackTimer = nil end
    lootTip:Hide()
    C_Timer.After(LOOT_GAP, function() lootBusy = false; showNextLoot() end)
end

function showNextLoot()
    if lootBusy then return end
    local nextItem = table.remove(lootQueue, 1)
    if not nextItem then return end
    lootBusy = true
    local link, isTest = nextItem[1], nextItem[2]
    local name, fullLink, quality = GetItemInfo(link)
    link = fullLink or link
    if not name then lootBusy = false; showNextLoot(); return end
    DingCamLoot = DingCamLoot or {}
    table.insert(DingCamLoot, {
        item = name,
        quality = quality,
        time = time(),
        char = charKey(),
        zone = GetRealZoneText() or "",
        test = isTest or nil,
    })
    lootTip:SetOwner(UIParent, "ANCHOR_NONE")
    lootTip:ClearAllPoints()
    lootTip:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    lootTip:SetHyperlink(link)
    lootTip:Show()
    C_Timer.After(LOOT_SHOT_DELAY, function()
        normalShot(function()
            lootShooting = true
            fallbackTimer = C_Timer.NewTimer(2, lootDone)
        end)
    end)
end

local function lootShot(link, isTest)
    table.insert(lootQueue, { link, isTest })
    showNextLoot()
end

-- "You receive loot: %s." / "You receive loot: %sx%d." (real drops only; quest rewards and purchases use other messages).
-- Only the text before the item is matched, so trailing punctuation or stack counts can't break it.
local lootPatterns = {}
for _, fmt in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF }) do
    if fmt then
        local prefix = fmt:match("^(.-)%%s")
        if prefix and prefix ~= "" then
            table.insert(lootPatterns, "^" .. prefix:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
        end
    end
end

local LOOT_DEBUG = false   -- true: report every blue/purple loot in chat (for troubleshooting)
local simDungeon = false   -- set briefly by /dingcam dungeon to pretend we're inside an instance

local function onLoot(msg, retried)
    if not readable(msg) then return end   -- loot text can be secret in dungeons
    local own = false
    for _, p in ipairs(lootPatterns) do
        if msg:match(p) then own = true; break end
    end
    if not own then return end
    -- Link colour codes differ between clients (|cff... or |cnIQ4:), so key on the item string itself.
    local itemString = msg:match("|H(item:[^|]+)|h")
    if not itemString then
        if LOOT_DEBUG then print("|cffe6b85cDingCam debug:|r loot message had no item link: " .. (msg:gsub("|", "||"))) end
        return
    end
    local _, link, quality = GetItemInfo(itemString)
    link = link or msg:match("|c.-|H.-|h.-|h|r")
    if not quality then   -- item not in the client cache yet: try once more shortly
        if not retried then C_Timer.After(0.5, function() onLoot(msg, true) end)
        elseif LOOT_DEBUG then print("|cffe6b85cDingCam debug:|r no item info for " .. itemString) end
        return
    end
    if quality < 3 or quality > 4 then return end
    -- In the world only Bind-on-Equip drops count; in a dungeon or raid any blue/purple you receive does
    -- (boss loot, rolls you win, master loot are all "You receive loot:" for you).
    local inInstance, instanceType = IsInInstance()
    local dungeon = (inInstance and (instanceType == "party" or instanceType == "raid")) or simDungeon
    local boe = (not simDungeon) and isBindOnEquip(itemString)   -- the simulation ignores BoE so only the dungeon rule can fire
    if simDungeon then
        print("|cffe6b85cDingCam|r: dungeon rule " .. (dungeon and "matched -> loot shot." or "did NOT match."))
    end
    if LOOT_DEBUG then
        print("|cffe6b85cDingCam debug:|r " .. (link or itemString) .. " quality " .. quality ..
              ((boe or dungeon) and (dungeon and " dungeon/raid loot" or " BoE") .. " -> taking loot shot" or " not BoE -> skipped"))
    end
    local wanted = simDungeon or (dungeon and opt("lootDungeon")) or (not dungeon and boe and opt("lootWorld"))
    if wanted then lootShot(link or itemString, simDungeon or nil) end
end

-- Gear snapshots: at level 1 and every 10 levels. DingCam never opens the character panel itself: a Blizzard panel opened
-- by addon code "taints" Blizzard's health bars, which then error on every update (health is a secret value in this
-- client). Instead it asks you to press C, and takes the shot (normal format) the next time YOU open the panel, even
-- after a /reload. Logged in DingCamGear; the helper files the picture under Gear\<Character> at logout or /reload.
local GEAR_EVERY = 10
local GEAR_DELAY = BANNER_DELAY + 1.5   -- seconds after a ding: after the banner shot, so they never collide
local gearWaiting, gearShooting

local function gearDone() gearShooting = false end

local function gearPending() return DingCamCharDB and DingCamCharDB.gearPending end

-- Takes the pending gear shot; only called while the character panel is open (opened by the player).
local function takeGearShot()
    local p = gearPending()
    if not p or gearShooting then return end
    if lootBusy or savedFormat or (InCinematic and InCinematic()) then
        C_Timer.After(0.5, function() if CharacterFrame and CharacterFrame:IsShown() then takeGearShot() end end)
        return
    end
    gearShooting = true
    normalShot(function()
        DingCamCharDB.gearPending = nil
        DingCamGear = DingCamGear or {}
        table.insert(DingCamGear, { level = p.level, time = time(), char = charKey(), test = p.test })
        C_Timer.After(2, gearDone)
    end)
    C_Timer.After(5, gearDone)   -- safety: never stay stuck if the shot never reports back
end

local function gearShot(level, isTest)
    if InCombatLockdown() then gearWaiting = { level, isTest }; return end   -- asked after the fight (PLAYER_REGEN_ENABLED)
    DingCamCharDB = DingCamCharDB or {}
    DingCamCharDB.gearPending = { level = level, test = isTest or nil }
    if CharacterFrame and CharacterFrame:IsShown() then
        C_Timer.After(0.3, takeGearShot)
    else
        print("|cffe6b85cDingCam|r: " .. (isTest and "test gear snapshot: " or ("level " .. level .. " gear snapshot: ")) ..
              "press |cffffd100C|r (or open your character panel) and DingCam saves a picture of your gear.")
    end
end

-- Hooked after Blizzard's own code runs, so it never taints the panel. Set up at login (the panel exists by then).
local gearHooked
local function hookGearPanel()
    if gearHooked or not CharacterFrame then return end
    gearHooked = true
    CharacterFrame:HookScript("OnShow", function()
        if gearPending() then C_Timer.After(0.3, takeGearShot) end   -- lets the panel draw
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LEVEL_UP")
f:RegisterEvent("CHAT_MSG_LOOT")
if LOOT_DEBUG then print("|cffe6b85cDingCam|r loaded (loot debug on).") end
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("SCREENSHOT_SUCCEEDED")
f:RegisterEvent("SCREENSHOT_FAILED")
f:RegisterEvent("TIME_PLAYED_MSG")
f:RegisterEvent("ZONE_CHANGED_NEW_AREA")
f:RegisterEvent("ENCOUNTER_END")
f:RegisterEvent("BOSS_KILL")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("UNIT_HEALTH")   -- not the combat log: this client forbids addons from registering for it
f:RegisterEvent("PLAYER_REGEN_ENABLED")
local firstEnter = true
f:SetScript("OnEvent", function(_, event, level, a2, a3, a4, a5)
    if event == "UNIT_HEALTH" then   -- a rare we're watching (target or nameplate) just died while tagged to us
        local guid = UnitGUID(level)
        if readable(guid) and rares[guid] and UnitIsDead(level) then
            if not UnitIsTapDenied(level) then killEvent("rare", rares[guid]) end   -- killEvent checks the switches
            rares[guid] = nil
        end
    elseif event == "PLAYER_TARGET_CHANGED" then noteRare("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then noteRare("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then noteRare(level)   -- first arg is the nameplate unit
    elseif event == "PLAYER_LEVEL_UP" then
        signal(level)   -- checks the level-up switches
        -- nobig: the longer level 60 clip is switched off, so the helper doesn't arm it at 59
        DingCamActive = { char = charKey(), level = level, nobig = (not opt("bigMoment")) or nil }
        if level % GEAR_EVERY == 0 and opt("gearEvery") then C_Timer.After(GEAR_DELAY, function() gearShot(level) end) end
        if level == 59 and helperRunning() and opt("bigMoment") then C_Timer.After(BANNER_DELAY + 2, almost60) end   -- after the banner shot, so it never covers it
    elseif event == "PLAYER_REGEN_ENABLED" then   -- a gear snapshot that came due mid-fight: ask after the fight
        if gearWaiting then
            local g = gearWaiting
            gearWaiting = nil
            C_Timer.After(1.5, function() gearShot(g[1], g[2]) end)
        end
    elseif event == "TIME_PLAYED_MSG" then
        playedBase, playedAt = level, GetTime()   -- first arg is total time played (seconds)
    elseif event == "ENCOUNTER_END" then
        if a5 == 1 then killEvent("boss", a2) end   -- encounterID, name, difficulty, size, success
    elseif event == "BOSS_KILL" then
        killEvent("boss", a2)                       -- encounterID, name
    elseif event == "CHAT_MSG_LOOT" then
        if opt("lootWorld") or opt("lootDungeon") then onLoot(level) end   -- first arg is the chat text
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if opt("zones") then zoneCheck() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if firstEnter then
            firstEnter = false
            -- who's playing (for the level 60 moment)
            DingCamActive = { char = charKey(), level = UnitLevel("player"), nobig = (not opt("bigMoment")) or nil }
            -- Safety net: if a session ever ended mid signal shot, put screenshots back to JPG (DingCam needs your shots non-TGA).
            if GetCVar("screenshotFormat") == "tga" then SetCVar("screenshotFormat", "jpeg") end
            C_Timer.After(8, checkStatus)   -- after the login spam, so it's noticed
            -- once per login, only if nothing else asked and it's switched on
            C_Timer.After(5, function() if not playedBase and opt("played") then RequestTimePlayed() end end)
            if opt("zones") then zoneCheck(3) end   -- a brand-new character's first zone (after the loading screen)
            DingCamCharDB = DingCamCharDB or {}
            hookGearPanel()
            local p = DingCamCharDB.gearPending
            if p then   -- a gear snapshot still waiting from before the /reload or logout
                C_Timer.After(14, function()
                    if gearPending() then print("|cffe6b85cDingCam|r: your level " .. p.level ..
                        " gear snapshot is still waiting: press |cffffd100C|r (or open your character panel).") end
                end)
            end
            if UnitLevel("player") == 1 and not DingCamCharDB.gearStart and opt("gearStart") then   -- starting gear, once per character
                DingCamCharDB.gearStart = true
                C_Timer.After(12, function() gearShot(1) end)   -- after the login messages and the zone shot
            end
        elseif opt("zones") then
            zoneCheck()                     -- arriving somewhere new through a loading screen (dungeons, boats)
        end
    else   -- SCREENSHOT_SUCCEEDED / SCREENSHOT_FAILED
        if savedFormat then
            SetCVar("screenshotFormat", savedFormat)
            savedFormat = nil
        end
        lootDone()
        gearDone()
    end
end)

SLASH_DINGCAM1 = "/dingcam"
SlashCmdList.DINGCAM = function(msg)
    msg = ((msg or ""):lower():match("^%s*(.-)%s*$")) or ""
    if msg == "" then   -- the same line as always, plus the settings window
        print("|cffe6b85cDingCam|r: active" .. (helperRunning() and "" or " (screenshots only: the PC helper isn't running)") ..
              ". /dingcam test saves a test moment, /dingcam status checks the PC helper, /dingcam recap shows this session.")
        if ns.toggleOptions then ns.toggleOptions() end
    elseif (msg == "options" or msg == "settings" or msg == "config") and ns.toggleOptions then   -- the settings window
        ns.toggleOptions()
    elseif (msg == "recap" or msg == "recap on" or msg == "recap off" or msg == "diary") and ns.recapCommand then   -- Recap.lua
        ns.recapCommand(msg)
    elseif msg == "status" then   -- is the PC helper running, and is its recorder on?
        local s = DingCamStatus
        if helperRunning() then
            print("|cffe6b85cDingCam|r: the PC helper (version " .. (s.helperVersion or "?") .. ") is running. Moments are saved as clips.")
            if helperOutdated() then
                print("|cffe6b85cDingCam|r: |cffffd100an update is available:|r helper " .. HELPER_NEEDED ..
                      " is needed for the new on/off switches, the diary file and full-name folders. " .. UPDATE_HOW)
            end
            local rec = recorder()
            print("|cffe6b85cDingCam|r: recording with " .. rec.name .. ": " .. (s.replayOff and ("|cffff4040OFF|r. To fix: " .. plain(rec.fix) .. ", then /reload")
                  or ((s.replayLength or 0) > 0 and ("on (" .. s.replayLength .. " s)") or "ready")) .. ".")
            if s.lastFail then print("|cffe6b85cDingCam|r: |cffff4040your clip from " .. s.lastFail .. " was NOT saved.|r") end
        elseif s and s.helperSeen then
            print("|cffe6b85cDingCam|r: |cffff4040the PC helper isn't running|r (last seen " .. SecondsToTime(math.abs(time() - s.helperSeen)) ..
                  " ago). Run Install DingCam again, or sign out of Windows and back in, then /reload.")
        else
            print("|cffe6b85cDingCam|r: |cffff4040no PC helper found.|r Moments are saved as screenshots only. For clips, get the helper at " .. HELPER_URL .. ".")
        end
        if DingCamNoHelperWarn then print("|cffe6b85cDingCam|r: helper reminders are off (/dingcam remind turns them on).") end
    elseif msg == "remind" then
        DingCamNoHelperWarn = nil
        print("|cffe6b85cDingCam|r: helper reminders are back on.")
    elseif msg == "warn" then   -- preview the warning without turning the recorder off
        warn("this is a PREVIEW of the recorder warning.")
        warningDialog("|cffff4040" .. recorder().name .. " is OFF.|r\nYour level-ups will NOT be recorded.\n(Preview only)", recorder().fix)
    elseif msg == "dungeon" then   -- simulate winning a roll in a dungeon, using a blue/purple item from your bags
        local GetLink = (C_Container and C_Container.GetContainerItemLink) or GetContainerItemLink
        local GetSlots = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
        local found
        for bag = 0, 4 do
            for slot = 1, (GetSlots(bag) or 0) do
                local l = GetLink(bag, slot)
                local q = l and select(3, GetItemInfo(l))
                if q and q >= 3 and q <= 4 then found = l; break end
            end
            if found then break end
        end
        if not found then
            print("|cffe6b85cDingCam|r: no blue or purple item in your bags to test with.")
        else
            print("|cffe6b85cDingCam|r: simulating dungeon loot: " .. found .. " (pretending you're in a dungeon).")
            simDungeon = true
            onLoot(LOOT_ITEM_SELF:format(found))   -- the exact message WoW sends when you win or loot an item
            C_Timer.After(2, function() simDungeon = false end)
        end
    elseif msg == "gear" then   -- test the gear snapshot
        if InCombatLockdown() then print("|cffe6b85cDingCam|r: test gear snapshot after this fight.") end
        gearShot(UnitLevel("player"), true)
    elseif msg == "zone" then   -- re-take the first-visit shot for the zone you're in
        local zone = GetRealZoneText()
        if DingCamCharDB and DingCamCharDB.zones then DingCamCharDB.zones[zone] = nil end
        print("|cffe6b85cDingCam|r: first-visit shot for " .. zone .. ".")
        zoneCheck()
    elseif msg == "boss" then   -- simulate a boss kill (clip + instant shot)
        print("|cffe6b85cDingCam|r: test boss kill" .. clipNote())
        killEvent("boss", "Test Boss", true)
    elseif msg == "rare" then   -- simulate a rare kill, using your target's name if you have one
        print("|cffe6b85cDingCam|r: test rare kill" .. clipNote())
        killEvent("rare", UnitExists("target") and UnitName("target") or "Test Rare", true)
    elseif msg == "59" then   -- preview the one-level-to-go popup
        almost60()
    elseif msg == "clearloot" then   -- forget logged drops (e.g. after beta testing); the pictures themselves aren't touched
        DingCamLoot = {}
        print("|cffe6b85cDingCam|r: loot log cleared. Type /reload to save that.")
    elseif msg == "loot" then   -- test the loot shot with whatever you have equipped in your main hand (or chest)
        local link = GetInventoryItemLink("player", 16) or GetInventoryItemLink("player", 5)
        if link then
            print("|cffe6b85cDingCam|r: test loot shot with " .. link .. ".")
            lootShot(link, true)
        else
            print("|cffe6b85cDingCam|r: equip a weapon or chest piece to test the loot shot.")
        end
    elseif msg == "test" then
        print("|cffe6b85cDingCam|r: test screenshot now" .. clipNote())
        signal(UnitLevel("player"), true)
    else
        print("|cffe6b85cDingCam|r: active" .. (helperRunning() and "" or " (screenshots only: the PC helper isn't running)") ..
              ". /dingcam opens the settings, /dingcam recap shows this session, /dingcam test saves a test moment, " ..
              "/dingcam status checks the PC helper.")
    end
end
