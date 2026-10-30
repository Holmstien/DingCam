-- DingCam: on level-up (and boss or rare kills), take one screenshot in TGA format (your normal
-- screenshots stay JPG). A new .tga in the Screenshots folder is the signal the
-- DingCam helper on your PC watches for; it waits a few seconds so the moment is in the clip,
-- then saves a clip with NVIDIA or AMD Instant Replay or OBS's Replay Buffer. Dings are logged in DingCamDB (with /played), kills in
-- DingCamEvents, first zone visits in DingCamZones, loot in DingCamLoot, so the helper can
-- file everything per character after you log out or /reload.
-- Without the helper, moments are saved as normal screenshots (no clips) and you're told how to get it.
-- Commands: /dingcam status | test | gear | loot | dungeon | zone | boss | rare | 59 | warn | remind | clearloot

local GLOW_DELAY = 0.5   -- seconds after the ding for the glow screenshot (the golden column is fully up by then)
local BANNER_DELAY = 5 -- seconds after the ding for the banner screenshot
local savedFormat   -- the player's screenshot format, restored right after our shot

local HELPER_URL = "github.com/Holmstien/DingCam"   -- where the PC helper is downloaded
local HELPER_STALE = 300   -- seconds: the helper checks in about once a minute, so older than this means it isn't running

-- Is the PC helper running? It rewrites Status.lua (DingCamStatus.helperSeen) while it runs; WoW reads that file once,
-- at login or /reload.
local function helperRunning()
    local s = DingCamStatus
    return (s and s.helperSeen and math.abs(time() - s.helperSeen) < HELPER_STALE) and true or false
end
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

local function signal(level, isTest)
    DingCamDB = DingCamDB or {}
    local entry = {
        level = level,
        time = time(),
        char = UnitName("player"),
        zone = GetRealZoneText() or "",
        played = currentPlayed(),
        test = isTest or nil,
    }
    table.insert(DingCamDB, entry)
    C_Timer.After(GLOW_DELAY, function() signalShot() end)
    -- Banner shot in the normal format once the "You've Reached Level N" banner is up.
    -- The helper recognises it by timing (BANNER_DELAY after the .tga) and files it under Banner\<Character>.
    C_Timer.After(BANNER_DELAY, function() normalShot() end)
end

-- Boss and rare kills: same clip + instant shot as a ding, logged in DingCamEvents (kind = "boss" or "rare").
local lastEvent = {}
local function killEvent(kind, name, isTest)
    if not name or name == "" then return end
    if lastEvent[name] and GetTime() - lastEvent[name] < 15 then return end   -- ENCOUNTER_END and BOSS_KILL both fire
    lastEvent[name] = GetTime()
    DingCamEvents = DingCamEvents or {}
    table.insert(DingCamEvents, {
        kind = kind,
        name = name,
        time = time(),
        char = UnitName("player"),
        zone = GetRealZoneText() or "",
        level = UnitLevel("player"),
        test = isTest or nil,
    })
    C_Timer.After(GLOW_DELAY, function() signalShot() end)
end

-- Rares: remember rare/rare-elite mobs we see (target, mouseover, nameplates); if one dies while tagged to us
-- (not grey-tapped by someone else), that's a rare kill.
local rares = {}
local function noteRare(unit)
    local c = UnitExists(unit) and UnitClassification(unit)
    if (c == "rare" or c == "rareelite") and not UnitIsPlayer(unit) then rares[UnitGUID(unit)] = UnitName(unit) end
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
            table.insert(DingCamZones, { zone = zone, time = time(), char = UnitName("player"), level = UnitLevel("player") })
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

-- Level 59: one level to go. Popup (after the banner shot) asking for a longer replay, then Reload UI to arm DingCam.
StaticPopupDialogs["DINGCAM_ALMOST_60"] = {
    text = "|cffffd100One level to go!|r\n\nYour level 60 moment deserves the full story.\n\nFor a longer clip, %s.\nThen click |cffffff00Reload UI|r and DingCam will film your 60 ding with extra time for the celebration.",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function() DingCamArmPending = time(); ReloadUI() end,   -- the reload saves DingCamActive, which arms the helper
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}
local function almost60()
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: one level to go! Get ready for 60.", { r = 1, g = 0.82, b = 0 })
    PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    StaticPopup_Show("DINGCAM_ALMOST_60", recorder().length)
end

-- Warning at login/reload if the PC helper (via Status.lua) reports the recorder off or a failed clip.
local function warn(text)
    print("|cffff4040DingCam WARNING:|r " .. text .. " To fix: " .. plain(recorder().fix) .. ", then /reload.")
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: " .. text, ChatTypeInfo["RAID_WARNING"])
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
end

-- Classic WoW popup (alert icon) with a Reload UI button.
StaticPopupDialogs["DINGCAM_WARNING"] = {
    text = "|cffe6b85cDingCam|r\n\n%s\n\nTo fix: %s.\nThen click |cffffff00Reload UI|r.",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- No helper on the PC (never installed, or not running): moments are still saved, as normal screenshots.
StaticPopupDialogs["DINGCAM_NO_HELPER"] = {
    text = "|cffe6b85cDingCam|r\n\n|cffff4040The DingCam helper isn't running on your PC.|r\nLevel-ups, boss kills and rares are saved as screenshots only, without video clips.\n\nTo get clips, download the helper from\n|cffffff00%s|r\nand run |cffffff00Install DingCam|r. Then type /reload.",
    button1 = "Got it",
    button2 = "Don't remind me",
    OnCancel = function(_, _, reason)
        if reason == "clicked" then
            DingCamNoHelperWarn = true
            print("|cffe6b85cDingCam|r: OK, no more helper reminders. /dingcam remind turns them back on.")
        end
    end,
    showAlert = true,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    noCancelOnEscape = true,   -- Escape just closes it; only the button turns reminders off
    preferredIndex = 3,
}

local function checkStatus()
    local s = DingCamStatus
    if not helperRunning() then
        if not DingCamNoHelperWarn then
            print("|cffff4040DingCam:|r the PC helper isn't running, so moments are saved as screenshots only (no clips). " ..
                  "Get it at " .. HELPER_URL .. ", or type /dingcam status.")
            StaticPopup_Show("DINGCAM_NO_HELPER", HELPER_URL)
        end
        return
    end
    local rec = recorder()
    if s.replayOff then
        DingCamWarned = true
        warn(rec.name .. " is OFF, so your level-ups will NOT be recorded.")
        StaticPopup_Show("DINGCAM_WARNING", "|cffff4040" .. rec.name .. " is OFF.|r\nYour level-ups will NOT be recorded.", rec.fix)
    elseif s.lastFail then
        DingCamWarned = true
        warn("your clip from " .. s.lastFail .. " was NOT saved.")
        StaticPopup_Show("DINGCAM_WARNING", "|cffff4040Your clip from " .. s.lastFail .. " was NOT saved.|r\n" .. rec.name .. " may be off.", rec.fix)
    elseif DingCamWarned then
        DingCamWarned = nil
        print("|cff40ff40DingCam:|r " .. rec.name .. " is on. You're all set, level-ups will be recorded.")
        RaidNotice_AddMessage(RaidWarningFrame, "DingCam: " .. rec.name .. " is on, you're all set.", { r = 0.25, g = 1, b = 0.25 })
    end
    -- At 59: the helper arms the "big moment" for the character it last saw at 59 (DingCamActive, saved on reload/logout).
    -- Armed for us (or we just reloaded from the popup) -> confirm, and nudge if the replay is short. Otherwise ask for a reload.
    if UnitLevel("player") == 59 and not s.replayOff then
        local me = UnitName("player")
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
        char = UnitName("player"),
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
    if boe or dungeon then lootShot(link or itemString, simDungeon or nil) end
end

-- Gear snapshots: at level 1 and every 10 levels, once you're out of combat, the character panel opens just long enough
-- to be screenshotted (normal format), then closes as soon as WoW reports the shot saved. Logged in DingCamGear; the
-- helper files the picture under Gear\<Character> at logout or /reload.
local GEAR_EVERY = 10
local GEAR_DELAY = BANNER_DELAY + 1.5   -- seconds after a ding: after the banner shot, so they never collide
local gearWaiting, gearOpened, gearShooting, gearTimer

local function gearDone()
    if not gearShooting then return end
    gearShooting = false
    if gearTimer then gearTimer:Cancel(); gearTimer = nil end
    if gearOpened and CharacterFrame:IsShown() then ToggleCharacter("PaperDollFrame") end
    gearOpened = false
end

local function gearShot(level, isTest)
    if InCombatLockdown() then gearWaiting = { level, isTest }; return end   -- PLAYER_REGEN_ENABLED picks it up
    if lootBusy or savedFormat or gearShooting or (InCinematic and InCinematic()) then
        C_Timer.After(0.5, function() gearShot(level, isTest) end)
        return
    end
    gearOpened = not CharacterFrame:IsShown()
    if gearOpened then ToggleCharacter("PaperDollFrame") end
    C_Timer.After(0.3, function()   -- lets the panel draw
        normalShot(function()
            DingCamGear = DingCamGear or {}
            table.insert(DingCamGear, { level = level, time = time(), char = UnitName("player"), test = isTest or nil })
            gearShooting = true
            gearTimer = C_Timer.NewTimer(2, gearDone)
        end)
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
        if guid and rares[guid] and UnitIsDead(level) then
            if not UnitIsTapDenied(level) then killEvent("rare", rares[guid]) end
            rares[guid] = nil
        end
    elseif event == "PLAYER_TARGET_CHANGED" then noteRare("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then noteRare("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then noteRare(level)   -- first arg is the nameplate unit
    elseif event == "PLAYER_LEVEL_UP" then
        signal(level)
        DingCamActive = { char = UnitName("player"), level = level }
        if level % GEAR_EVERY == 0 then C_Timer.After(GEAR_DELAY, function() gearShot(level) end) end
        if level == 59 and helperRunning() then C_Timer.After(BANNER_DELAY + 2, almost60) end   -- after the banner shot, so it never covers it
    elseif event == "PLAYER_REGEN_ENABLED" then   -- a gear snapshot that came due mid-fight
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
        onLoot(level)   -- first arg is the chat text
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        zoneCheck()
    elseif event == "PLAYER_ENTERING_WORLD" then
        if firstEnter then
            firstEnter = false
            DingCamActive = { char = UnitName("player"), level = UnitLevel("player") }   -- who's playing (for the level 60 moment)
            -- Safety net: if a session ever ended mid signal shot, put screenshots back to JPG (DingCam needs your shots non-TGA).
            if GetCVar("screenshotFormat") == "tga" then SetCVar("screenshotFormat", "jpeg") end
            C_Timer.After(8, checkStatus)   -- after the login spam, so it's noticed
            C_Timer.After(5, function() if not playedBase then RequestTimePlayed() end end)   -- once per login, only if nothing else asked
            zoneCheck(3)                    -- a brand-new character's first zone (after the loading screen)
            DingCamCharDB = DingCamCharDB or {}
            if UnitLevel("player") == 1 and not DingCamCharDB.gearStart then   -- starting gear, once per character
                DingCamCharDB.gearStart = true
                C_Timer.After(12, function() gearShot(1) end)   -- after the login messages and the zone shot
            end
        else
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
    if msg == "status" then   -- is the PC helper running, and is its recorder on?
        local s = DingCamStatus
        if helperRunning() then
            print("|cffe6b85cDingCam|r: the PC helper (version " .. (s.helperVersion or "?") .. ") is running. Moments are saved as clips.")
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
        StaticPopup_Show("DINGCAM_WARNING", "|cffff4040" .. recorder().name .. " is OFF.|r\nYour level-ups will NOT be recorded.\n(Preview only)", recorder().fix)
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
        print("|cffe6b85cDingCam|r: test gear snapshot" .. (InCombatLockdown() and " after this fight." or " now."))
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
              ". /dingcam test saves a test moment, /dingcam status checks the PC helper.")
    end
end
