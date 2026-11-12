-- DingCam settings: an on/off switch for every feature, in a small window. Open it with /dingcam, the minimap button
-- or the AddOns list. Saved account-wide in DingCamOptions; a value that was never set means the default (on).
-- Changes apply right away. The PC helper reads the "no clip / no screenshot / no banner" choices from each moment's
-- entry, so it files only what you kept.

local _, ns = ...

local DEFAULTS = {
    dingClip = true, dingGlow = true, dingBanner = true, bigMoment = true,
    bossClip = true, bossShot = true, rareClip = true, rareShot = true,
    lootWorld = true, lootDungeon = true,
    zones = true, gearStart = true, gearEvery = true,
    recap = true, recapPopup = true,
    warnings = true, helperUpdate = true, played = true, minimap = true,
    minimapAngle = 200,
}

function ns.opt(key)
    local o = DingCamOptions
    if type(o) == "table" and o[key] ~= nil then return o[key] end
    return DEFAULTS[key]
end

function ns.setOpt(key, value)
    if type(DingCamOptions) ~= "table" then DingCamOptions = {} end
    DingCamOptions[key] = value
end

-- "Remind me when the PC helper isn't running" is the older DingCamNoHelperWarn ("Don't remind me" on the popup).
local function get(key)
    if key == "helperRemind" then return not DingCamNoHelperWarn end
    return ns.opt(key) and true or false
end
local function set(key, on)
    if key == "helperRemind" then
        DingCamNoHelperWarn = (not on) or nil
    else
        ns.setOpt(key, on)
    end
    if key == "minimap" and ns.minimapButton then ns.minimapButton() end
end

-- ---------- the settings window ----------
local NEW = " |cff40ff40NEW|r"
local COLUMNS = {
    {
        { head = "Level-ups" },
        { key = "dingClip",   label = "Video clip" },
        { key = "dingGlow",   label = "Golden glow screenshot" },
        { key = "dingBanner", label = "Level-up banner screenshot" },
        { key = "bigMoment",  label = "Longer clip at level 60 (reminder at 59)" },
        { head = "Boss kills" },
        { key = "bossClip",   label = "Video clip" },
        { key = "bossShot",   label = "Screenshot" },
        { head = "Rare kills" },
        { key = "rareClip",   label = "Video clip" },
        { key = "rareShot",   label = "Screenshot" },
        { head = "Blue and purple loot" },
        { key = "lootWorld",  label = "Out in the world (Bind on Equip)" },
        { key = "lootDungeon", label = "In dungeons and raids" },
    },
    {
        { head = "New zones" },
        { key = "zones",      label = "Screenshot on your first visit" },
        { head = "Gear" },
        { key = "gearStart",  label = "Screenshot at level 1" },
        { key = "gearEvery",  label = "Screenshot every 10 levels" },
        { head = "Session recap" .. NEW },
        { key = "recap",      label = "Keep a recap and diary" },
        { key = "recapPopup", label = "Open the recap when you log out" },
        { head = "Reminders" },
        { key = "warnings",   label = "When a clip can't be saved" },
        { key = "helperRemind", label = "When the PC helper isn't running" },
        { key = "helperUpdate", label = "When the PC helper needs an update" .. NEW },
        { head = "Other" },
        { key = "played",     label = "Ask for /played at login" },
        { key = "minimap",    label = "Minimap button" .. NEW },
    },
}
local HEAD_GAP, ROW_GAP, COL_WIDTH = 24, 22, 290

local panel, boxes, status = nil, {}, nil

local function refresh()
    if not panel then return end
    for key, b in pairs(boxes) do b:SetChecked(get(key)) end
    local old = ns.helperOutdated and ns.helperOutdated()
    if old then
        status:SetText("|cff40ff40The PC helper is running|r (version " .. old .. "). |cffffd100Update it to " ..
            ns.HELPER_NEEDED .. "|r for the switches below, the diary file and full-name folders:\n" ..
            "download it from github.com/Holmstien/DingCam and run Install DingCam again.")
    elseif ns.helperRunning and ns.helperRunning() then
        status:SetText("|cff40ff40The PC helper is running.|r Video clips are saved.")
    else
        status:SetText("|cffff4040The PC helper isn't running|r, so moments are saved as screenshots only (no clips).\n" ..
            "Get it at |cffffff00github.com/Holmstien/DingCam|r.")
    end
end
ns.refreshOptions = refresh

local function build()
    local ok, f = pcall(CreateFrame, "Frame", "DingCamOptionsFrame", UIParent, "BasicFrameTemplateWithInset")
    if not ok then f = CreateFrame("Frame", "DingCamOptionsFrame", UIParent, "BackdropTemplate") end
    f:SetSize(2 * COL_WIDTH + 30, 486); f:SetPoint("CENTER", 0, 40); f:SetFrameStrata("DIALOG")
    f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton"); f:SetClampedToScreen(true)
    f:SetScript("OnDragStart", f.StartMoving); f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetScript("OnShow", refresh)
    if f.TitleText then f.TitleText:SetText("DingCam") end
    tinsert(UISpecialFrames, "DingCamOptionsFrame")   -- Escape closes it

    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", 18, -32); status:SetPoint("TOPRIGHT", -18, -32)
    status:SetJustifyH("LEFT")

    for c, items in ipairs(COLUMNS) do
        local x, y = 14 + (c - 1) * COL_WIDTH, -78   -- below the status lines (up to 3)
        for _, item in ipairs(items) do
            if item.head then
                local h = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                h:SetPoint("TOPLEFT", x + 4, y - 6); h:SetText(item.head)
                y = y - HEAD_GAP
            else
                local b = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
                b:SetSize(24, 24)
                b:SetPoint("TOPLEFT", x, y)
                local text = type(b.Text) == "table" and b.Text or b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
                text:ClearAllPoints(); text:SetPoint("LEFT", b, "RIGHT", 2, 1)
                text:SetFontObject("GameFontHighlight"); text:SetText(item.label)
                b:SetHitRectInsets(0, -(COL_WIDTH - 40), 0, 0)   -- the words are clickable too
                local key = item.key
                b:SetScript("OnClick", function(self) set(key, self:GetChecked() and true or false) end)
                boxes[key] = b
                y = y - ROW_GAP
            end
        end
    end

    local recapBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    recapBtn:SetSize(130, 22); recapBtn:SetPoint("BOTTOMLEFT", 18, 14); recapBtn:SetText("Session recap")
    recapBtn:SetScript("OnClick", function() if ns.recapCommand then ns.recapCommand("recap") end end)
    local close = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    close:SetSize(90, 22); close:SetPoint("BOTTOMRIGHT", -18, 14); close:SetText(CLOSE or "Close")
    close:SetScript("OnClick", function() f:Hide() end)
    local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("BOTTOM", 0, 20); hint:SetText("Changes apply right away. /dingcam opens this window.")

    f:Hide()   -- new frames start shown; toggleOptions shows it (and OnShow fills it in)
    panel = f
end

function ns.toggleOptions()
    if not panel then build() end
    if panel:IsShown() then panel:Hide() else panel:Show() end
end

-- The AddOns list / addon compartment entry (## AddonCompartmentFunc in the .toc).
function DingCam_OnAddonCompartmentClick()
    ns.toggleOptions()
end

-- ---------- the minimap button ----------
-- Laid out exactly like other add-ons' minimap buttons (LibDBIcon's classic layout) so it matches them: a 31 px button,
-- WoW's own tracking ring at its top left, a dark disc and a 17 px icon (MinimapIcon.tga: the camera from the DingCam
-- bubble, without the bubble's own gold ring). Drag it around the ring; the angle is saved in DingCamOptions.
local SHAPES = {   -- which quarters of the minimap are round (1 bottom right, 2 bottom left, 3 top right, 4 top left)
    ["ROUND"] = { true, true, true, true }, ["SQUARE"] = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true }, ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false }, ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true }, ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true }, ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true }, ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true }, ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}
local mini

local function place()
    local a = math.rad(ns.opt("minimapAngle") or 200)
    local x, y = math.cos(a), math.sin(a)
    local q = 1 + (x < 0 and 1 or 0) + (y > 0 and 2 or 0)
    local shape = SHAPES[(GetMinimapShape and GetMinimapShape()) or "ROUND"] or SHAPES.ROUND
    local w = (tonumber(Minimap:GetWidth()) or 140) / 2 + 5
    local h = (tonumber(Minimap:GetHeight()) or 140) / 2 + 5
    if shape[q] then
        x, y = x * w, y * h
    else   -- square corner: put it on the edge along the same angle
        local edge = math.max(math.abs(x) / w, math.abs(y) / h)
        x, y = x / edge, y / edge
    end
    mini:ClearAllPoints()
    mini:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function tooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("DingCam")
    if ns.helperRunning and ns.helperRunning() then
        GameTooltip:AddLine("PC helper running: video clips on", 0.25, 1, 0.25)
    else
        GameTooltip:AddLine("PC helper not running: screenshots only", 1, 0.25, 0.25)
    end
    GameTooltip:AddLine("Left-click: settings", 1, 1, 1)
    GameTooltip:AddLine("Right-click: session recap", 1, 1, 1)
    GameTooltip:AddLine("Shift-click: gear card", 1, 1, 1)
    GameTooltip:AddLine("Drag: move this button", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

function ns.minimapButton()
    if not Minimap then return end
    if mini then mini:SetShown(ns.opt("minimap")); return end
    if not ns.opt("minimap") then return end
    mini = CreateFrame("Button", "DingCamMinimapButton", Minimap)
    mini:SetSize(31, 31)
    mini:SetFrameStrata("MEDIUM")
    mini:SetFrameLevel(8)
    local disc = mini:CreateTexture(nil, "BACKGROUND")
    disc:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    disc:SetSize(20, 20)
    disc:SetPoint("TOPLEFT", 7, -5)
    local icon = mini:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\AddOns\\DingCam\\MinimapIcon")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    local function crop(down)   -- trim the square edge; pressed, it shows whole (a slight push), like LibDBIcon
        local d = down and 0 or 0.05
        icon:SetTexCoord(d, 1 - d, d, 1 - d)
    end
    crop(false)
    local border = mini:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    place()
    if Minimap.HookScript then Minimap:HookScript("OnSizeChanged", place) end
    mini:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    mini:RegisterForDrag("LeftButton")
    mini:SetScript("OnMouseDown", function() crop(true) end)
    mini:SetScript("OnMouseUp", function() crop(false) end)
    mini:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            if ns.recapCommand then ns.recapCommand("recap") end
        elseif IsShiftKeyDown() and ns.viewCard then
            ns.viewCard()
        else
            ns.toggleOptions()
        end
    end)
    mini:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        if self.LockHighlight then self:LockHighlight() end
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            ns.setOpt("minimapAngle", math.deg(math.atan2(cy / s - my, cx / s - mx)) % 360)
            place()
        end)
    end)
    mini:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        if self.UnlockHighlight then self:UnlockHighlight() end
        crop(false)
    end)
    mini:SetScript("OnEnter", tooltip)
    mini:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_LOGIN")
ev:SetScript("OnEvent", function() ns.minimapButton() end)
