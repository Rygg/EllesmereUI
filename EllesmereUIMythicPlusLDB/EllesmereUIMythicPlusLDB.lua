local EUI = EllesmereUI
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local PORTALS = EUI and EUI.SEASON_PORTALS
if not (LDB and type(PORTALS) == "table") then return end

local MAX_RUNS = 16
local TIP_WIDTH = 312
local ROW_HEIGHT = 16
local TIP_TOP = 46

local format = string.format
local floor = math.floor
local max = math.max
local type = type
local ipairs = ipairs
local pcall = pcall
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown

local dataObject
local eventFrame
local tooltip
local owner
local titleText
local dungeonHeader
local keyHeader
local ratingHeader
local timeHeader
local hintText
local rows = {}
local actionHost
local actionButtons = {}
local actionsDirty = false
local IsCursorOver, HideTooltip, HideTeleportActions, RenderTooltip

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function GetScore()
    if not (C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary) then return nil end
    local ok, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
    if not ok or IsSecret(summary) or type(summary) ~= "table" then return nil end
    local score = summary.currentSeasonScore
    if IsSecret(score) or type(score) ~= "number" then return nil end
    return max(0, floor(score + 0.5))
end

local function GetScoreColor(score)
    if score and C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor then
        local ok, color = pcall(C_ChallengeMode.GetDungeonScoreRarityColor, score)
        if ok and type(color) == "table"
           and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
            return color.r, color.g, color.b
        end
    end
    return 1, 1, 1
end

local function FormatRunTime(seconds)
    if IsSecret(seconds) or type(seconds) ~= "number" or seconds < 0 then return nil end
    seconds = floor(seconds)
    local hours = floor(seconds / 3600)
    local minutes = floor((seconds % 3600) / 60)
    local remainder = seconds % 60
    if hours > 0 then return format("%d:%02d:%02d", hours, minutes, remainder) end
    return format("%d:%02d", minutes, remainder)
end

local function TimerChestCount(elapsed, limit, inTime)
    if not inTime then return 0 end
    if IsSecret(elapsed) or IsSecret(limit) or type(elapsed) ~= "number"
       or type(limit) ~= "number" or limit <= 0 then
        return nil
    end
    if elapsed > limit then return 0 end
    if elapsed <= limit * 0.6 then return 3 end
    if elapsed <= limit * 0.8 then return 2 end
    return 1
end

local function GetDungeonScoreColor(score)
    if IsSecret(score) or type(score) ~= "number"
       or not (C_ChallengeMode and C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor) then
        return 1, 1, 1
    end
    local ok, color = pcall(C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor, score)
    if ok and not IsSecret(color) and type(color) == "table"
       and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
        return color.r, color.g, color.b
    end
    return 1, 1, 1
end

local function IsKnownSpell(spellID)
    if type(spellID) ~= "number" or not IsPlayerSpell then return false end
    local ok, known = pcall(IsPlayerSpell, spellID)
    return ok and known == true
end

local function GetKnownPortal(dungeonName)
    if type(dungeonName) ~= "string" or IsSecret(dungeonName) or not GetLFGDungeonInfo then return nil end
    local normalizedName = dungeonName:lower()
    for _, portal in ipairs(PORTALS) do
        if portal.dungeonID then
            local ok, portalName = pcall(GetLFGDungeonInfo, portal.dungeonID)
            if ok and type(portalName) == "string" and portalName:lower() == normalizedName then
                if IsKnownSpell(portal.spellID) then return portal.spellID end
                if type(portal.altSpellIDs) == "table" then
                    for _, spellID in ipairs(portal.altSpellIDs) do
                        if IsKnownSpell(spellID) then return spellID end
                    end
                end
                return nil
            end
        end
    end
end

local function SpellReady(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or IsSecret(info) or type(info) ~= "table" then return false end
    local startTime, duration = info.startTime, info.duration
    if IsSecret(startTime) or IsSecret(duration)
       or type(startTime) ~= "number" or type(duration) ~= "number" then
        return false
    end
    if not canaccessvalue(startTime) or not canaccessvalue(duration) then return false end
    if duration <= 0 then return true end
    return startTime + duration <= GetTime()
end

local function EnsureTooltip()
    if tooltip then return tooltip end
    tooltip = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    tooltip:SetFrameStrata("TOOLTIP")
    tooltip:SetFrameLevel(900)
    tooltip:SetClampedToScreen(true)
    tooltip:SetSize(TIP_WIDTH, 80)
    tooltip:EnableMouse(true)
    tooltip:SetPropagateMouseClicks(false)
    tooltip:SetPropagateMouseMotion(false)
    tooltip:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 8,
        edgeSize = 12,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    tooltip:SetBackdropColor(0.055, 0.055, 0.055, 0.96)
    tooltip:SetBackdropBorderColor(0.18, 0.18, 0.18, 1)
    tooltip:Hide()

    titleText = tooltip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    titleText:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 12, -10)

    dungeonHeader = tooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    dungeonHeader:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 12, -32)
    dungeonHeader:SetWidth(112)
    dungeonHeader:SetJustifyH("LEFT")
    dungeonHeader:SetText("Dungeon")

    keyHeader = tooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    keyHeader:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 128, -32)
    keyHeader:SetWidth(46)
    keyHeader:SetJustifyH("RIGHT")
    keyHeader:SetText("Key")

    ratingHeader = tooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    ratingHeader:SetPoint("TOPRIGHT", tooltip, "TOPRIGHT", -92, -32)
    ratingHeader:SetWidth(36)
    ratingHeader:SetJustifyH("RIGHT")
    ratingHeader:SetText("Rating")

    timeHeader = tooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    timeHeader:SetPoint("TOPRIGHT", tooltip, "TOPRIGHT", -12, -32)
    timeHeader:SetWidth(78)
    timeHeader:SetJustifyH("RIGHT")
    timeHeader:SetText("Run (Limit)")

    hintText = tooltip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hintText:SetJustifyH("CENTER")

    for index = 1, MAX_RUNS do
        local row = {}
        row.frame = CreateFrame("Frame", nil, tooltip)
        row.name = row.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", row.frame, "LEFT", 0, 0)
        row.name:SetWidth(112)
        row.name:SetJustifyH("LEFT")
        row.level = row.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.level:SetPoint("RIGHT", row.name, "RIGHT", 50, 0)
        row.level:SetWidth(46)
        row.level:SetJustifyH("RIGHT")
        row.rating = row.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.rating:SetPoint("LEFT", row.name, "RIGHT", 60, 0)
        row.rating:SetWidth(36)
        row.rating:SetJustifyH("RIGHT")
        row.time = row.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.time:SetPoint("LEFT", row.rating, "RIGHT", 2, 0)
        row.time:SetWidth(78)
        row.time:SetJustifyH("RIGHT")
        row.time:SetTextColor(0.65, 0.65, 0.65)
        row.frame:Hide()
        rows[index] = row
    end

    tooltip:SetScript("OnLeave", function()
        if not IsCursorOver(owner) and not IsCursorOver(tooltip) then HideTooltip() end
    end)
    tooltip:SetScript("OnHide", function()
        if actionHost then HideTeleportActions() end
    end)
    return tooltip
end

IsCursorOver = function(frame)
    if not (frame and frame.IsShown and frame:IsShown()) then return false end
    local left, right, top, bottom = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    local scale = frame:GetEffectiveScale()
    if not (left and right and top and bottom and scale and scale > 0) then return false end
    local cursorX, cursorY = GetCursorPosition()
    cursorX, cursorY = cursorX / scale, cursorY / scale
    return cursorX >= left and cursorX <= right and cursorY >= bottom and cursorY <= top
end

HideTeleportActions = function()
    if not actionHost then return end
    if InCombatLockdown() then
        actionsDirty = true
        return
    end
    actionsDirty = false
    for index = 1, #actionButtons do
        local button = actionButtons[index]
        button:Hide()
        button:ClearAllPoints()
    end
    actionHost:Hide()
    actionHost:ClearAllPoints()
    actionHost:SetSize(1, 1)
end

HideTooltip = function()
    if tooltip and tooltip:IsShown() then tooltip:Hide() end
    if actionHost and not InCombatLockdown() then HideTeleportActions() end
    owner = nil
end

local function EnsureActionHost()
    if actionHost then return true end
    if InCombatLockdown() then return false end
    actionHost = CreateFrame("Frame", nil, UIParent, "SecureHandlerStateTemplate")
    actionHost:SetFrameStrata("TOOLTIP")
    actionHost:SetFrameLevel(910)
    RegisterStateDriver(actionHost, "visibility", "[combat] hide; show")
    actionHost:Hide()
    return true
end

local function EnsureActionButton(index)
    local button = actionButtons[index]
    if button then return button end
    button = CreateFrame("Button", nil, actionHost, "SecureActionButtonTemplate")
    button:SetFrameLevel(actionHost:GetFrameLevel() + 1)
    button:EnableMouse(true)
    button:RegisterForClicks("AnyUp")
    button:SetAttribute("useOnKeyDown", false)
    button:SetAttribute("type1", "spell")
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.10)
    button:HookScript("PostClick", HideTooltip)
    actionButtons[index] = button
    return button
end

local function UpdateTeleportActions(runCount)
    if InCombatLockdown() then return end
    local hasReadyAction = false
    for index = 1, runCount do
        if rows[index].spellID then hasReadyAction = true; break end
    end
    if not hasReadyAction then
        HideTeleportActions()
        return
    end
    if not EnsureActionHost() then return end

    actionHost:ClearAllPoints()
    actionHost:SetAllPoints(tooltip)
    for index = 1, runCount do
        local row = rows[index]
        local button = EnsureActionButton(index)
        if row.spellID then
            button:SetAttribute("spell1", row.spellID)
            button:ClearAllPoints()
            button:SetAllPoints(row.frame)
            button:Show()
        else
            button:Hide()
            button:ClearAllPoints()
        end
    end
    for index = runCount + 1, #actionButtons do
        actionButtons[index]:Hide()
        actionButtons[index]:ClearAllPoints()
    end
    actionHost:Show()
end

local function PositionTooltip()
    if not (owner and owner.GetTop) then
        tooltip:SetPoint("CENTER", UIParent, "CENTER")
        return
    end
    tooltip:ClearAllPoints()
    local ownerTop = owner:GetTop()
    local tipHeight = tooltip:GetHeight()
    local screenHeight = UIParent:GetHeight()
    if ownerTop and ownerTop + tipHeight + 4 < screenHeight then
        tooltip:SetPoint("BOTTOMLEFT", owner, "TOPLEFT", 0, -2)
    else
        tooltip:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, 2)
    end
end

RenderTooltip = function()
    if not tooltip then return end
    local score = GetScore()
    local title = "Current Rating: "
    if score then
        local red, green, blue = GetScoreColor(score)
        local hex = format("%02x%02x%02x", floor(red * 255 + 0.5), floor(green * 255 + 0.5), floor(blue * 255 + 0.5))
        title = title .. "|cff" .. hex .. tostring(score) .. "|r"
    else
        title = title .. "-"
    end
    titleText:SetText(title)

    local runCount, readyCount = 0, 0
    local mapsOK, mapIDs = false, nil
    if C_ChallengeMode and C_ChallengeMode.GetMapTable
       and C_ChallengeMode.GetMapUIInfo and C_MythicPlus and C_MythicPlus.GetSeasonBestForMap then
        mapsOK, mapIDs = pcall(C_ChallengeMode.GetMapTable)
    end
    if mapsOK and not IsSecret(mapIDs) and type(mapIDs) == "table" then
        for _, mapID in ipairs(mapIDs) do
            if runCount >= MAX_RUNS then break end
            local nameOK, dungeonName, _, timeLimit = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
            if nameOK and not IsSecret(dungeonName) and type(dungeonName) == "string" and dungeonName ~= "" then
                local runOK, intimeInfo, overtimeInfo = pcall(C_MythicPlus.GetSeasonBestForMap, mapID)
                local runInfo, isInTime
                if runOK then
                    if IsSecret(intimeInfo) then intimeInfo = nil end
                    if IsSecret(overtimeInfo) then overtimeInfo = nil end
                    if type(intimeInfo) == "table" then
                        runInfo, isInTime = intimeInfo, true
                    elseif type(overtimeInfo) == "table" then
                        runInfo, isInTime = overtimeInfo, false
                    end
                end

                runCount = runCount + 1
                local row = rows[runCount]
                row.name:SetText(dungeonName)
                local spellID = GetKnownPortal(dungeonName)
                local ready = spellID and SpellReady(spellID) or false
                if ready then
                    row.spellID = spellID
                    readyCount = readyCount + 1
                else
                    row.spellID = nil
                end

                local level, elapsed, dungeonScore, runTime
                if runInfo then
                    level = runInfo.level
                    elapsed = runInfo.durationSec
                    dungeonScore = runInfo.dungeonScore
                    runTime = FormatRunTime(elapsed)
                end
                if not IsSecret(level) and type(level) == "number" and runTime then
                    level = floor(level)
                    local chestCount = TimerChestCount(elapsed, timeLimit, isInTime)
                    local keyPrefix = "+"
                    if chestCount == 0 then keyPrefix = ""
                    elseif chestCount == 2 then keyPrefix = "++"
                    elseif chestCount == 3 then keyPrefix = "+++" end
                    row.level:SetText(keyPrefix .. tostring(level))
                    if not IsSecret(dungeonScore) and type(dungeonScore) == "number" then
                        row.rating:SetText(tostring(floor(dungeonScore + 0.5)))
                        local red, green, blue = GetDungeonScoreColor(dungeonScore)
                        row.level:SetTextColor(red, green, blue)
                        row.rating:SetTextColor(red, green, blue)
                    else
                        row.rating:SetText("-")
                        row.level:SetTextColor(1, 1, 1)
                        row.rating:SetTextColor(0.86, 0.86, 0.86)
                    end
                    local limitText = FormatRunTime(timeLimit)
                    row.time:SetText(runTime .. " |cff888888(" .. (limitText or "-") .. ")|r")
                    if chestCount == 0 then
                        row.time:SetTextColor(0.65, 0.65, 0.65)
                    else
                        row.time:SetTextColor(1, 1, 1)
                    end
                else
                    row.level:SetText("-")
                    row.level:SetTextColor(0.65, 0.65, 0.65)
                    row.rating:SetText("-")
                    row.rating:SetTextColor(0.65, 0.65, 0.65)
                    local limitText = FormatRunTime(timeLimit)
                    row.time:SetText("- |cff888888(" .. (limitText or "-") .. ")|r")
                    row.time:SetTextColor(0.65, 0.65, 0.65)
                end

                row.frame:ClearAllPoints()
                row.frame:SetPoint("TOPLEFT", tooltip, "TOPLEFT", 12, -(TIP_TOP + (runCount - 1) * ROW_HEIGHT))
                row.frame:SetPoint("TOPRIGHT", tooltip, "TOPRIGHT", -12,
                    -(TIP_TOP + (runCount - 1) * ROW_HEIGHT))
                row.frame:SetHeight(ROW_HEIGHT)
                row.frame:Show()
            end
        end
    end

    for index = runCount + 1, MAX_RUNS do
        rows[index].frame:Hide()
        rows[index].spellID = nil
        rows[index].level:SetText("")
        rows[index].rating:SetText("")
        rows[index].time:SetText("")
    end

    local contentHeight = TIP_TOP + max(runCount, 1) * ROW_HEIGHT
    hintText:ClearAllPoints()
    if readyCount > 0 then
        hintText:SetText("Ready portals: click a dungeon")
        hintText:SetPoint("TOP", tooltip, "TOP", 0, -(contentHeight + 4))
        hintText:Show()
        contentHeight = contentHeight + 22
    else
        hintText:Hide()
    end
    tooltip:SetHeight(contentHeight + 12)
    PositionTooltip()
    tooltip:Show()
    UpdateTeleportActions(runCount)
end

local function ShowTooltip(frame)
    owner = frame
    EnsureTooltip()
    RenderTooltip()
end

local function HideIfOutside()
    if IsCursorOver(owner) or IsCursorOver(tooltip) then return end
    HideTooltip()
end

local function OpenMythicPlusMenu()
    if InCombatLockdown() or not C_AddOns then return end
    if not C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder") then
        local ok, loaded = pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
        if not ok or not loaded then return end
    end
    if PVEFrame_ToggleFrame then pcall(PVEFrame_ToggleFrame, "ChallengesFrame") end
end

local function RefreshScore()
    if not dataObject then return end
    local score = GetScore()
    if not score then
        dataObject.text = "-"
        return
    end
    local red, green, blue = GetScoreColor(score)
    local hex = format("%02x%02x%02x", floor(red * 255 + 0.5), floor(green * 255 + 0.5), floor(blue * 255 + 0.5))
    dataObject.text = "|cff" .. hex .. tostring(score) .. "|r"
end

local function OnLDBClick(_, mouseButton)
    if mouseButton == "LeftButton" then OpenMythicPlusMenu() end
end

local objectOK, registeredObject = pcall(LDB.NewDataObject, LDB, "EllesmereUI Mythic+ Rating", {
    type = "data source",
    label = "Mythic+ Rating",
    text = "-",
    OnEnter = ShowTooltip,
    OnLeave = HideIfOutside,
    OnClick = OnLDBClick,
})
if not objectOK or type(registeredObject) ~= "table" then return end
dataObject = registeredObject

eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        if actionHost then
            actionsDirty = false
            for index = 1, #actionButtons do
                actionButtons[index]:Hide()
                actionButtons[index]:ClearAllPoints()
            end
            actionHost:ClearAllPoints()
            actionHost:SetSize(1, 1)
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" and actionsDirty then
        HideTeleportActions()
    end
    if event == "PLAYER_ENTERING_WORLD" or event == "CHALLENGE_MODE_COMPLETED" then
        RefreshScore()
    end
    if tooltip and tooltip:IsShown()
       and (IsCursorOver(owner) or IsCursorOver(tooltip)) then
        RenderTooltip()
    end
end)
RefreshScore()