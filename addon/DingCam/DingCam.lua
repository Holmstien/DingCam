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
local HELPER_NEEDED = "1.3.13"   -- 1.3.13: the level 60 clip never waits so long that the ding falls out of it
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
local UPDATE_HOW = "To update, open |cffffff00Update DingCam|r from the Windows Start menu (or download DingCam-Setup from " ..
                   HELPER_URL .. " and run it). Your settings and files are kept."
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
local reloadBtn, reloadDialogOpen   -- the secure Reload UI button; see showReloadButton below
local function showDialog(text, button1, onButton1, button2, onButton2)
    reloadDialogOpen = nil
    if reloadBtn and reloadBtn:IsShown() and not InCombatLockdown() then reloadBtn:Hide() end
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

-- A real "Reload UI" button. WoW Forever blocks ReloadUI() from addon code (1.3.9), but a secure macro button that
-- runs /reload is the same as the player typing it. Secure frames can't be shown, hidden or moved in combat, so:
--  * it is parented to UIParent (NOT the dialog), so the dialog itself stays a plain frame (Escape, dragging, hiding);
--  * it is only shown out of combat, laid over the dialog's first button, and hidden again on PLAYER_REGEN_DISABLED
--    (that event still allows changes) and whenever the dialog closes or moves;
--  * no PreClick or other addon code runs on the click, so the /reload stays untainted.
-- If anything is off, the dialog's own "Got it" button and the "/reload" text are always there underneath.
local function soloButton()   -- the plain layout: one "Got it" button in the middle
    local b = dialog.b1
    b:ClearAllPoints(); b:SetPoint("BOTTOM", 0, 16); b:SetText("Got it")
end
local function hideReloadButton()
    if reloadBtn and reloadBtn:IsShown() and not InCombatLockdown() then reloadBtn:Hide() end
end
local function showReloadButton()
    if InCombatLockdown() or not reloadDialogOpen or not dialog or not dialog:IsShown() then return end
    if not reloadBtn then
        local ok, btn = pcall(CreateFrame, "Button", "DingCamReloadButton", UIParent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
        if not ok or not btn then return end
        reloadBtn = btn
        reloadBtn:SetAttribute("type", "macro")
        reloadBtn:SetAttribute("macrotext", "/reload")   -- set again for each dialog (out of combat)
        reloadBtn:RegisterForClicks("AnyUp", "AnyDown")
        reloadBtn:SetText("Reload UI")
        reloadBtn:SetFrameStrata("FULLSCREEN_DIALOG")
        reloadBtn:Hide()
        local ev = CreateFrame("Frame")
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")   -- fires just before combat lockdown, so the secure button can still be hidden
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        ev:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                if reloadBtn:IsShown() then reloadBtn:Hide() end
                if reloadDialogOpen and dialog:IsShown() then soloButton() end
            else
                C_Timer.After(0.2, showReloadButton)
            end
        end)
        -- Follow the dialog without hooking it (Escape closes the dialog from Blizzard code, which DingCam must not touch):
        -- while shown (only ever out of combat), hide when the dialog is gone and follow it when it's dragged.
        reloadBtn:SetScript("OnUpdate", function(self)
            if InCombatLockdown() then return end
            if not reloadDialogOpen or not dialog:IsShown() then reloadDialogOpen = nil; self:Hide(); return end
            local l, bt = dialog:GetLeft(), dialog:GetBottom()
            if l ~= self.dl or bt ~= self.db then self.dl, self.db = l, bt; showReloadButton() end
        end)
    end
    -- two buttons: the secure action on the left, the dialog's own button (now "Later") on the right
    reloadBtn:SetAttribute("macrotext", reloadDialogOpen.macro)
    reloadBtn:SetText(reloadDialogOpen.label)
    local d, b = dialog, dialog.b1
    b:ClearAllPoints(); b:SetPoint("BOTTOMLEFT", d, "BOTTOM", 6, 16); b:SetText("Later")
    local s = d:GetEffectiveScale() / UIParent:GetEffectiveScale()
    local l, bt, w = d:GetLeft(), d:GetBottom(), d:GetWidth()
    if not l or not bt or not w then soloButton(); return end
    reloadBtn:ClearAllPoints()
    reloadBtn:SetSize(140 * s, 24 * s)
    reloadBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", (l + w / 2 - 6 - 140) * s, (bt + 16) * s)
    reloadBtn:Show()
end
-- A dialog with a secure action: "Got it" plus the typed alternative in the text always; the action button out of combat.
local function showActionDialog(text, label, macro)
    hideReloadButton()
    showDialog(text, "Got it")
    reloadDialogOpen = { label = label, macro = macro }
    C_Timer.After(0, showReloadButton)
end
local function showReloadDialog(text) showActionDialog(text, "Reload UI", "/reload") end

-- Level 59: one level to go. Popup (after the banner shot) asking for a longer replay, then a /reload to arm DingCam.
-- WoW Forever blocks addons from calling ReloadUI() (ADDON_ACTION_BLOCKED, 1.3.9), so the player types /reload.
local ALMOST60_TEXT = "|cffffd100One level to go!|r\n\nYour level 60 moment deserves the full story.\n\nFor a longer clip, %s.\nThen click |cffffff00Reload UI|r (or type |cffffff00/reload|r) and DingCam will film your 60 ding with extra time for the celebration."
local function almost60()
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: one level to go! Get ready for 60.", { r = 1, g = 0.82, b = 0 })
    PlaySound(SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
    -- the reload saves DingCamActive, which arms the helper
    DingCamArmPending = time()
    showReloadDialog(ALMOST60_TEXT:format(recorder().length))
end

-- Warning at login/reload if the PC helper (via Status.lua) reports the recorder off or a failed clip.
local function warn(text)
    print("|cffff4040DingCam WARNING:|r " .. text .. " To fix: " .. plain(recorder().fix) .. ", then /reload.")
    RaidNotice_AddMessage(RaidWarningFrame, "DingCam: " .. text, ChatTypeInfo["RAID_WARNING"])
    PlaySound(SOUNDKIT and SOUNDKIT.RAID_WARNING or 8959)
end

-- The recorder warning popup, with the secure Reload UI button out of combat.
local function warningDialog(what, fix)
    showReloadDialog("|cffe6b85cDingCam|r\n\n" .. what .. "\n\nTo fix: " .. fix .. ".\nThen click |cffffff00Reload UI|r (or type |cffffff00/reload|r).")
end

-- No helper on the PC (never installed, or not running): moments are still saved, as normal screenshots.
-- Escape just closes it; only the button turns reminders off.
local function noHelperDialog()
    showDialog("|cffe6b85cDingCam|r\n\n|cffff4040The DingCam helper isn't running on your PC.|r\nLevel-ups, boss kills and rares are saved as screenshots only, without video clips.\n\nTo get clips, download |cffffff00DingCam-Setup|r from\n|cffffff00" .. HELPER_URL .. "|r\nand run it. Then type /reload.",
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

-- Gear snapshots: at level 1 and every N levels (gearInterval, 1-10, default 10; set with the slider in the settings). Since 1.3.10 DingCam shows its OWN gear card (your 3D model and every
-- equipped item), screenshots it and closes it: nothing to press. It never opens Blizzard's character panel: a Blizzard
-- panel opened by addon code "taints" Blizzard's health bars, which then error on every update (health is a secret
-- value in this client; that was the 1.3.8 "Fatality" loop). Logged in DingCamGear; the helper files the picture under
-- Gear\<Character> at logout or /reload. A shot that comes due mid-fight waits for the fight to end.
local function gearEvery()   -- how many levels between gear cards (the settings slider), 1 to 10
    local n = math.floor(tonumber(opt("gearInterval")) or 10)
    return math.max(1, math.min(10, n))
end
local GEAR_DELAY = BANNER_DELAY + 1.5   -- seconds after a ding: after the banner shot, so they never collide
local gearWaiting, gearShooting

local function gearDone() gearShooting = false end

local function gearPending() return DingCamCharDB and DingCamCharDB.gearPending end

local SLOTS_LEFT   = { 1, 2, 3, 15, 5, 4, 19, 9 }     -- head, neck, shoulder, back, chest, shirt, tabard, wrist
local SLOTS_RIGHT  = { 10, 6, 7, 8, 11, 12, 13, 14 }  -- hands, waist, legs, feet, two rings, two trinkets
local SLOTS_BOTTOM = { 16, 17, 18 }                   -- main hand, off hand, ranged
local CARD_W, CARD_H = 840, 580
local function plainValue(v)   -- nil for anything this client hides from addons
    if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

local card
local function buildCard()
    local c = CreateFrame("Frame", "DingCamGearCard", UIParent, "BackdropTemplate")
    c:SetSize(CARD_W, CARD_H); c:SetPoint("CENTER", 0, 20)
    c:SetFrameStrata("FULLSCREEN_DIALOG"); c:SetClampedToScreen(true)
    c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    c:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    c:SetBackdropBorderColor(0.9, 0.72, 0.36)
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"); c.title:SetPoint("TOP", 0, -18)
    c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); c.sub:SetPoint("TOP", c.title, "BOTTOM", 0, -6)
    c.model = CreateFrame("PlayerModel", nil, c); c.model:SetSize(280, 400); c.model:SetPoint("TOP", 0, -64)
    c.footer = c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"); c.footer:SetPoint("BOTTOM", 0, 14)
    c.slots = {}
    local function slot(id, x, y, side)
        local s = CreateFrame("Frame", nil, c); s:SetSize(36, 36); s:SetPoint("TOPLEFT", c, "TOPLEFT", x, y)
        s.icon = s:CreateTexture(nil, "ARTWORK"); s.icon:SetAllPoints()
        s.glow = s:CreateTexture(nil, "OVERLAY"); s.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        s.glow:SetBlendMode("ADD"); s.glow:SetSize(66, 66); s.glow:SetPoint("CENTER")
        s.name = s:CreateFontString(nil, "OVERLAY", "GameFontNormal"); s.name:SetWordWrap(true)
        if side == "right" then
            s.name:SetWidth(210); s.name:SetPoint("RIGHT", s, "LEFT", -8, 0); s.name:SetJustifyH("RIGHT")
        elseif side == "left" then
            s.name:SetWidth(210); s.name:SetPoint("LEFT", s, "RIGHT", 8, 0); s.name:SetJustifyH("LEFT")
        else
            s.name:SetWidth(150); s.name:SetPoint("LEFT", s, "RIGHT", 8, 0); s.name:SetJustifyH("LEFT")
        end
        s.id = id; c.slots[#c.slots + 1] = s
    end
    for i, id in ipairs(SLOTS_LEFT) do slot(id, 22, -64 - (i - 1) * 50, "left") end
    for i, id in ipairs(SLOTS_RIGHT) do slot(id, CARD_W - 22 - 36, -64 - (i - 1) * 50, "right") end
    for i, id in ipairs(SLOTS_BOTTOM) do slot(id, 150 + (i - 1) * 200, -478, "bottom") end
    -- only shown when the card is opened by hand (/dingcam card); never in the saved picture
    c.closeBtn = CreateFrame("Button", nil, c, "UIPanelCloseButton")
    c.closeBtn:SetPoint("TOPRIGHT", -4, -4); c.closeBtn:Hide()
    c:SetScript("OnMouseUp", function(self) if self.viewing then self:Hide() end end)
    c:SetScript("OnHide", function(self)
        if not self.viewing then return end
        self.viewing = nil; self:EnableMouse(false); self.closeBtn:Hide()
        for i = #UISpecialFrames, 1, -1 do if UISpecialFrames[i] == "DingCamGearCard" then table.remove(UISpecialFrames, i) end end
    end)
    c:Hide()
    return c
end

local function playedLabel()
    local s = currentPlayed()
    if not s then return nil end
    local d, h, m = math.floor(s / 86400), math.floor(s % 86400 / 3600), math.floor(s % 3600 / 60)
    return d > 0 and ("%dd %dh played"):format(d, h) or ("%dh %dm played"):format(h, m)
end

local function fillCard(level)
    local c = card
    c.title:SetText(charKey())
    local cls = plainValue((UnitClass("player")))
    local zone = plainValue(GetRealZoneText()) or ""
    local parts = { "Level " .. level .. (cls and (" " .. cls) or "") }
    if zone ~= "" then parts[#parts + 1] = zone end
    local pl = playedLabel(); if pl then parts[#parts + 1] = pl end
    c.sub:SetText(table.concat(parts, "  -  "))
    c.footer:SetText("Saved by DingCam  -  " .. date("%d %b %Y"))
    pcall(function() c.model:SetUnit("player"); c.model:SetFacing(0.35) end)
    for _, s in ipairs(c.slots) do
        local link = plainValue(GetInventoryItemLink("player", s.id))
        local tex = plainValue(GetInventoryItemTexture("player", s.id))
        local q = plainValue(GetInventoryItemQuality("player", s.id))
        local name = link and link:match("%[(.-)%]")
        s.icon:SetTexture(tex or "Interface\\PaperDoll\\UI-Backpack-EmptySlot")
        s.icon:SetDesaturated(not tex)
        s.icon:SetAlpha(tex and 1 or 0.35)
        local r, g, b = 1, 1, 1
        if q and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q] then r, g, b = ITEM_QUALITY_COLORS[q].r, ITEM_QUALITY_COLORS[q].g, ITEM_QUALITY_COLORS[q].b end
        s.name:SetText(name or "")
        -- a little lighter than the tooltip colours, so blues and purples read well on the dark card
        s.name:SetTextColor(r + (1 - r) * 0.3, g + (1 - g) * 0.3, b + (1 - b) * 0.3)
        if q and q >= 2 then s.glow:SetVertexColor(r, g, b); s.glow:Show() else s.glow:Hide() end
    end
end

-- Shows the card, waits for the 3D model to load, takes the picture (normal format), closes the card.
local function takeGearShot()
    local p = gearPending()
    if not p or gearShooting then return end
    if InCombatLockdown() then gearWaiting = { p.level, p.test }; return end
    if lootBusy or savedFormat or (InCinematic and InCinematic()) then
        C_Timer.After(0.5, takeGearShot)
        return
    end
    if not card then
        local ok, c = pcall(buildCard)
        if not ok or not c then print("|cffe6b85cDingCam|r: couldn't build the gear card (" .. tostring(c) .. ")."); return end
        card = c
    end
    if card.viewing then card:Hide() end   -- closes the hand-opened view (and its close button) first
    gearShooting = true
    local ok, err = pcall(fillCard, p.level)
    if not ok then print("|cffe6b85cDingCam|r: gear card problem (" .. tostring(err) .. ").") end
    -- about three quarters of the screen height, whatever the UI scale, so the card is the picture
    local h = UIParent:GetHeight()
    card:SetScale(math.max(1, math.min(1.8, (h and h > 0) and (h * 0.75 / CARD_H) or 1.25)))
    card:Show()
    C_Timer.After(1.2, function()   -- the model and item icons need a moment to load
        if not card:IsShown() then gearShooting = false; return end
        normalShot(function()
            DingCamCharDB.gearPending = nil
            DingCamGear = DingCamGear or {}
            table.insert(DingCamGear, { level = p.level, time = time(), char = charKey(), test = p.test })
            C_Timer.After(0.6, function() card:Hide() end)
            C_Timer.After(2, gearDone)
            print("|cffe6b85cDingCam|r: " .. (p.test and "test gear card saved." or ("level " .. p.level .. " gear card saved.")))
        end)
    end)
    C_Timer.After(8, function() if card and card:IsShown() then card:Hide() end; gearDone() end)   -- safety
end

local function gearShot(level, isTest)
    if InCombatLockdown() then gearWaiting = { level, isTest }; return end   -- taken after the fight (PLAYER_REGEN_ENABLED)
    DingCamCharDB = DingCamCharDB or {}
    DingCamCharDB.gearPending = { level = level, test = isTest or nil }
    C_Timer.After(0.2, takeGearShot)
end

-- /dingcam card (or Shift-click the minimap button): look at the gear card any time. Nothing is saved.
-- Click it, press Escape or its X to close it.
function ns.viewCard()
    if gearShooting then return end
    if card and card:IsShown() then card:Hide(); return end
    if not card then
        local ok, c = pcall(buildCard)
        if not ok or not c then print("|cffe6b85cDingCam|r: couldn't build the gear card (" .. tostring(c) .. ")."); return end
        card = c
    end
    local ok, err = pcall(fillCard, UnitLevel("player"))
    if not ok then print("|cffe6b85cDingCam|r: gear card problem (" .. tostring(err) .. ").") end
    card.footer:SetText("DingCam  -  " .. date("%d %b %Y") .. "  -  click to close")
    local h = UIParent:GetHeight()
    card:SetScale(math.max(1, math.min(1.8, (h and h > 0) and (h * 0.75 / CARD_H) or 1.25)))
    card.viewing = true
    card:EnableMouse(true); card.closeBtn:Show()
    tinsert(UISpecialFrames, "DingCamGearCard")
    card:Show()
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
        -- At 60 the helper may wait up to 25 s before saving the longer clip, so the card waits until after that (30 s).
        if level % gearEvery() == 0 and opt("gearEvery") then C_Timer.After(level == 60 and 30 or GEAR_DELAY, function() gearShot(level) end) end
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
            local p = DingCamCharDB.gearPending
            if p then   -- a gear snapshot still waiting from before the /reload or logout (e.g. an older DingCam asked for C)
                C_Timer.After(14, function() if gearPending() then gearShot(p.level, p.test) end end)
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
                  " ago). Run the DingCam installer again, or sign out of Windows and back in, then /reload.")
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
    elseif msg == "card" or msg == "sheet" then   -- just look at the gear card; nothing is saved
        ns.viewCard()
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
              "/dingcam card shows your gear card, /dingcam status checks the PC helper.")
    end
end
