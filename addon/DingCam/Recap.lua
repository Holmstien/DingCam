-- DingCam Session Recap: what each play session added up to (time, levels, XP, gold, quests, best loot, new zones,
-- bosses, rares, deaths), plus a diary with one line per session for each character.
-- A session carries on through /reload. It closes when you next log in (so logging out, quitting and crashes all count),
-- and its diary line is written then. With the PC helper, the diary is also saved as Diary\<Character>.txt in the Journey.
-- The recap window opens when you start logging out or quitting and any time with /dingcam recap (or a right-click on
-- the minimap button). /dingcam diary prints your last few sessions.
-- Switches (Options.lua): "recap" (off: no diary lines and no window at logout; /dingcam recap still shows it) and
-- "recapPopup" (open at logout; /dingcam recap on|off sets it too).
-- Saved: DingCamRecap (this session, per character), DingCamRecapZones (zones this character has been to),
-- DingCamDiary (diary lines per character).

local _, ns = ...
local S   -- this session (DingCamRecap)
local function opt(key)   -- the switches (Options.lua); if that file ever failed to load, everything stays on
    if ns.opt then return ns.opt(key) end
    return true
end
local function setOpt(key, value)
    if ns.setOpt then ns.setOpt(key, value) end
    if ns.refreshOptions then ns.refreshOptions() end
end

local QUALITY_COLOR = { [0] = "9d9d9d", [1] = "ffffff", [2] = "1eff00", [3] = "0070dd", [4] = "a335ee", [5] = "ff8000" }
local DIARY_SHOWN = 5   -- lines printed by /dingcam diary

local function money(c, signed)
    c = math.floor(c or 0)
    local sign = signed and (c < 0 and "-" or "+") or ""
    c = math.abs(c)
    local g, s, cc = math.floor(c / 10000), math.floor((c % 10000) / 100), c % 100
    local parts = {}
    if g > 0 then table.insert(parts, g .. "g") end
    if s > 0 then table.insert(parts, s .. "s") end
    if cc > 0 or #parts == 0 then table.insert(parts, cc .. "c") end
    return sign .. table.concat(parts, " ")
end

local function duration(sec)
    sec = math.max(0, math.floor(sec or 0))
    local h, m = math.floor(sec / 3600), math.floor((sec % 3600) / 60)
    if h > 0 then return h .. "h " .. m .. "m" end
    return m .. "m"
end

local function played(sec)
    if not sec then return nil end
    local d, h = math.floor(sec / 86400), math.floor((sec % 86400) / 3600)
    if d > 0 then return d .. "d " .. h .. "h" end
    return h .. "h " .. math.floor((sec % 3600) / 60) .. "m"
end

local function newSession()
    S = {
        start = time(), last = time(),
        char = UnitName("player"),
        startLevel = UnitLevel("player"), level = UnitLevel("player"),
        xp = 0, lastXP = UnitXP("player"), lastXPMax = UnitXPMax("player"),
        startMoney = GetMoney(), lastMoney = GetMoney(),
        looted = 0, questMoney = 0, sold = 0, spent = 0,
        quests = 0, deaths = 0, newZones = 0, bosses = 0, rares = 0,
        zoneTime = {}, zone = GetRealZoneText(), zoneSince = time(),
    }
    DingCamRecap = S
end

-- The zone where most of the session was spent.
local function noteZoneTime()
    if S.zone and S.zone ~= "" then S.zoneTime[S.zone] = (S.zoneTime[S.zone] or 0) + (time() - (S.zoneSince or time())) end
    S.zone, S.zoneSince = GetRealZoneText(), time()
end
local function mainZone(s)
    local best, t = s.zone, -1
    for z, sec in pairs(s.zoneTime or {}) do if sec > t then best, t = z, sec end end
    return best or ""
end

local function diaryLine(s)
    local endT = s.last or time()
    local bits = { date("%b %d, %Y", s.start), duration(endT - s.start) }
    if s.level and s.startLevel and s.level > s.startLevel then table.insert(bits, "Level " .. s.startLevel .. " → " .. s.level)
    else table.insert(bits, "Level " .. (s.level or "?")) end
    table.insert(bits, mainZone(s))
    table.insert(bits, money((s.endMoney or s.lastMoney or 0) - (s.startMoney or 0), true))
    if s.quests > 0 then table.insert(bits, s.quests .. " quest" .. (s.quests == 1 and "" or "s")) end
    if s.bestLootName then table.insert(bits, "best: " .. s.bestLootName) end
    if s.newZones > 0 then table.insert(bits, s.newZones .. " new zone" .. (s.newZones == 1 and "" or "s")) end
    if s.bosses > 0 then table.insert(bits, s.bosses .. " boss" .. (s.bosses == 1 and "" or "es")) end
    if s.rares > 0 then table.insert(bits, s.rares .. " rare" .. (s.rares == 1 and "" or "s")) end
    if s.deaths > 0 then table.insert(bits, s.deaths .. " death" .. (s.deaths == 1 and "" or "s")) end
    if s.played then table.insert(bits, played(s.played) .. " played") end
    return table.concat(bits, " · ")
end

-- Closes the previous session into the diary (called at the next login).
local function finish(s)
    if not s or not s.char or not s.start or not opt("recap") then return end
    if (s.last or s.start) - s.start < 60 then return end   -- skip sessions shorter than a minute
    DingCamDiary = DingCamDiary or {}
    DingCamDiary[s.char] = DingCamDiary[s.char] or {}
    table.insert(DingCamDiary[s.char], diaryLine(s))
end

-- ---------- the window ----------
local frame, rowValues, footer
local ROWS = { "Time played", "Level", "Experience", "Gold (net)", "   looted & other", "   quest rewards",
               "   sold to vendors", "   spent", "Quests completed", "Best loot", "New zones", "Bosses / rares",
               "Deaths", "Main zone" }

local function buildFrame()
    local ok, f = pcall(CreateFrame, "Frame", "DingCamRecapFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then f = CreateFrame("Frame", "DingCamRecapFrame", UIParent, "BackdropTemplate") end
    f:SetSize(340, 400); f:SetPoint("CENTER", 0, 60); f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    if f.TitleText then f.TitleText:SetText("Session Recap") end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    f.title:SetPoint("TOP", 0, -32)
    rowValues = {}
    for i, label in ipairs(ROWS) do
        local y = -58 - (i - 1) * 21
        local l = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        l:SetPoint("TOPLEFT", 20, y); l:SetText(label)
        local v = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        v:SetPoint("TOPRIGHT", -20, y); v:SetJustifyH("RIGHT")
        rowValues[i] = v
    end
    footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOM", 0, 14)
    footer:SetJustifyH("CENTER")
    frame = f
end

-- Fills and opens the window for session s. isLast: a session that already ended (shown at the next login), so its
-- gold is what it ended with rather than what you have now.
local function fill(s, isLast)
    if not frame then buildFrame() end
    frame.title:SetText((isLast and "Last session: " or "") .. (s.char or "?") .. " · " .. date("%b %d", s.start))
    local nowMoney = isLast and (s.endMoney or s.lastMoney or s.startMoney or 0) or GetMoney()
    local level, startLevel = s.level or 0, s.startLevel or 0
    local values = {
        duration((s.last or s.start) - s.start) .. (s.played and ("  (" .. played(s.played) .. " total)") or ""),
        (level > startLevel) and (startLevel .. " → " .. level) or tostring(level),
        tostring(s.xp or 0) .. " XP",
        money(nowMoney - (s.startMoney or 0), true),
        money(s.looted),
        money(s.questMoney),
        money(s.sold),
        money(s.spent),
        tostring(s.quests or 0),
        s.bestLoot or "-",
        tostring(s.newZones or 0),
        (s.bosses or 0) .. " / " .. (s.rares or 0),
        tostring(s.deaths or 0),
        mainZone(s),
    }
    for i, v in ipairs(values) do rowValues[i]:SetText(v) end
    footer:SetText("/dingcam diary shows your past sessions\n" ..
        ((opt("recap") and opt("recapPopup")) and "/dingcam recap off stops this opening at logout"
         or "/dingcam recap on opens this when you log out"))
    frame:Show()
    if frame.Raise then frame:Raise() end   -- above the settings window when opened from there
end

-- This session, as it stands now.
local function show()
    if not S then return end
    noteZoneTime()
    S.last = time()
    fill(S, false)
end

-- ---------- tracking ----------
local lootPrefixes = {}
for _, fmt in ipairs({ LOOT_ITEM_SELF_MULTIPLE, LOOT_ITEM_SELF }) do
    local p = fmt and fmt:match("^(.-)%%s")
    if p and p ~= "" then table.insert(lootPrefixes, "^" .. p:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")) end
end
local function onLoot(msg)
    local own = false
    for _, p in ipairs(lootPrefixes) do if msg:match(p) then own = true; break end end
    if not own then return end
    local itemString = msg:match("|H(item:[^|]+)|h")
    if not itemString then return end
    local name, _, quality = GetItemInfo(itemString)
    if not quality or quality < 2 then return end   -- greens and better
    if quality >= (S.bestQ or -1) then
        S.bestQ = quality
        S.bestLootName = name
        S.bestLoot = "|cff" .. (QUALITY_COLOR[quality] or "ffffff") .. name .. "|r"
    end
end

local merchantOpen, pendingQuestMoney, lastGainAt, lastGain = false, 0, -100, 0
local function onMoney()
    local now = GetMoney()
    local d = now - (S.lastMoney or now)
    S.lastMoney, S.endMoney = now, now
    if d < 0 then S.spent = S.spent + (-d)
    elseif d > 0 then
        if merchantOpen then S.sold = S.sold + d
        elseif pendingQuestMoney > 0 then
            local q = math.min(d, pendingQuestMoney)
            pendingQuestMoney = pendingQuestMoney - q
            S.questMoney = S.questMoney + q
            S.looted = S.looted + (d - q)
        else
            S.looted = S.looted + d
            lastGainAt, lastGain = GetTime(), d
        end
    end
end
local function onQuestTurnedIn(rewardMoney)
    S.quests = S.quests + 1
    rewardMoney = tonumber(rewardMoney) or 0
    if rewardMoney <= 0 then return end
    if GetTime() - lastGainAt < 1 and lastGain >= rewardMoney then   -- the gold arrived just before this event
        S.looted = S.looted - rewardMoney
        S.questMoney = S.questMoney + rewardMoney
        lastGain = lastGain - rewardMoney
    else
        pendingQuestMoney = pendingQuestMoney + rewardMoney
    end
end

local function onXP()
    local x, xmax = UnitXP("player"), UnitXPMax("player")
    if x >= (S.lastXP or x) then S.xp = S.xp + (x - (S.lastXP or x))
    else S.xp = S.xp + ((S.lastXPMax or 0) - (S.lastXP or 0)) + x end   -- leveled up in between
    S.lastXP, S.lastXPMax = x, xmax
end

local function onZone()
    noteZoneTime()
    local zone = GetRealZoneText()
    if not zone or zone == "" then return end
    if not DingCamRecapZones[zone] then DingCamRecapZones[zone] = true; S.newZones = S.newZones + 1 end
end

local lastBoss = {}
local function onBoss(name)
    if not name or name == "" then return end
    if lastBoss[name] and GetTime() - lastBoss[name] < 15 then return end   -- ENCOUNTER_END and BOSS_KILL both fire
    lastBoss[name] = GetTime()
    S.bosses = S.bosses + 1
end

local rares = {}
local function noteRare(unit)
    local c = UnitExists(unit) and UnitClassification(unit)
    if (c == "rare" or c == "rareelite") and not UnitIsPlayer(unit) then rares[UnitGUID(unit)] = true end
end

local f = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT", "PLAYER_CAMPING", "PLAYER_QUITING", "PLAYER_XP_UPDATE",
        "PLAYER_LEVEL_UP", "PLAYER_MONEY", "MERCHANT_SHOW", "MERCHANT_CLOSED", "QUEST_TURNED_IN", "CHAT_MSG_LOOT",
        "ZONE_CHANGED_NEW_AREA", "PLAYER_DEAD", "ENCOUNTER_END", "BOSS_KILL", "TIME_PLAYED_MSG",
        "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "NAME_PLATE_UNIT_ADDED", "UNIT_HEALTH" }) do
    f:RegisterEvent(ev)
end
f:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
    if event == "PLAYER_ENTERING_WORLD" then
        local isLogin = a1
        if not S then
            if not DingCamRecapZones then   -- first time with the recap: zones DingCam already knows aren't "new"
                DingCamRecapZones = {}
                if DingCamCharDB and DingCamCharDB.zones then
                    for z in pairs(DingCamCharDB.zones) do DingCamRecapZones[z] = true end
                end
            end
            if isLogin or not DingCamRecap or DingCamRecap.char ~= UnitName("player") then
                local prev = DingCamRecap
                finish(prev)           -- the previous session ends here
                newSession()
                -- Logging out in an inn or a city is instant, so the window never got a chance to open (shownAt is set
                -- when it opens at logout; playing on for over a minute after that counts as not seen). Show that
                -- session now instead, once the login messages have passed.
                if prev and prev.start and prev.char == UnitName("player") and opt("recap") and opt("recapPopup")
                        and (prev.last or prev.start) - prev.start >= 60
                        and (not prev.shownAt or (prev.last or prev.shownAt) - prev.shownAt > 60) then
                    C_Timer.After(6, function() fill(prev, true) end)
                end
            else
                S = DingCamRecap       -- a /reload: same session continues
            end
            S.lastXP, S.lastXPMax, S.lastMoney = UnitXP("player"), UnitXPMax("player"), GetMoney()
        end
        onZone()
        return
    end
    if not S then return end
    S.last = time()
    if event == "UNIT_HEALTH" then
        local guid = UnitGUID(a1)
        if guid and rares[guid] and UnitIsDead(a1) then
            if not UnitIsTapDenied(a1) then S.rares = S.rares + 1 end
            rares[guid] = nil
        end
    elseif event == "PLAYER_TARGET_CHANGED" then noteRare("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then noteRare("mouseover")
    elseif event == "NAME_PLATE_UNIT_ADDED" then noteRare(a1)
    elseif event == "PLAYER_XP_UPDATE" then onXP()
    elseif event == "PLAYER_LEVEL_UP" then S.level = a1
    elseif event == "PLAYER_MONEY" then onMoney()
    elseif event == "MERCHANT_SHOW" then merchantOpen = true
    elseif event == "MERCHANT_CLOSED" then merchantOpen = false
    elseif event == "QUEST_TURNED_IN" then onQuestTurnedIn(a3)
    elseif event == "CHAT_MSG_LOOT" then onLoot(a1)
    elseif event == "ZONE_CHANGED_NEW_AREA" then onZone()
    elseif event == "PLAYER_DEAD" then S.deaths = S.deaths + 1
    elseif event == "ENCOUNTER_END" then if a5 == 1 then onBoss(a2) end
    elseif event == "BOSS_KILL" then onBoss(a2)
    elseif event == "TIME_PLAYED_MSG" then S.played = a1
    elseif event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        if opt("recap") and opt("recapPopup") then show(); S.shownAt = time() end
    elseif event == "PLAYER_LOGOUT" then noteZoneTime()
    end
end)

-- /dingcam recap, /dingcam recap on|off, /dingcam diary (called from the /dingcam command in DingCam.lua).
function ns.recapCommand(msg)
    if msg == "diary" then
        local list = DingCamDiary and DingCamDiary[UnitName("player")]
        if not list or #list == 0 then
            print("|cffe6b85cDingCam|r: no diary entries yet. One is written each time you log back in.")
            return
        end
        print("|cffe6b85cDingCam diary:|r")
        for i = math.max(1, #list - DIARY_SHOWN + 1), #list do print("  " .. list[i]) end
    elseif msg == "recap off" then
        setOpt("recapPopup", false)
        print("|cffe6b85cDingCam|r: the session recap won't open when you log out. /dingcam recap still shows it.")
    elseif msg == "recap on" then
        setOpt("recap", true)
        setOpt("recapPopup", true)
        print("|cffe6b85cDingCam|r: the session recap will open when you log out.")
    elseif frame and frame:IsShown() then
        frame:Hide()
    else
        show()
    end
end
