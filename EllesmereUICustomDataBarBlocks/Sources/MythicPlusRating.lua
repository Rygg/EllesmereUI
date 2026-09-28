if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local _, addonNS = ...
local DataBarsExtensions = addonNS and addonNS.DataBarsExtensions
local EUI = EllesmereUI
-- DataBars keeps its module namespace private to its addon. Its engine publishes
-- that namespace on the parent for its own options integration; this addon uses
-- the same internal seam to register a separately updateable block. The hard
-- TOC dependency guarantees DataBars has loaded first. Fail closed if that
-- implementation detail changes instead of breaking the UI at startup.
local ns = DataBarsExtensions and DataBarsExtensions.DataBars
if not (DataBarsExtensions and DataBarsExtensions.RegisterBlock and DataBarsExtensions.Tip_AddActionColumns
    and ns and ns.BlockFactories and ns.BLOCK_TYPES and ns.BLOCK_DEFAULTS and ns.BlockKit) then
    return
end
if not (ns.Tip_AddDouble and ns.Tip_AddColumns and ns.Tip_AddActionDouble) then return end
local L = EUI.L or function(text) return text end
local K = ns.BlockKit
local PORTALS = EUI and EUI.SEASON_PORTALS
if type(PORTALS) ~= "table" then return end

local BLOCK_TYPE = "mythicplusrating"

local MAX_RUNS = 16

-- Upvalues
local CreateFrame         = CreateFrame
local InCombatLockdown    = InCombatLockdown
local GetTime             = GetTime
local type                = type
local ipairs              = ipairs
local pcall               = pcall
local format              = string.format
local floor               = math.floor
local ceil                = math.ceil
local max                 = math.max
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS

local CONTENT_BASE = K.CONTENT_BASE
local InstKey = K.InstKey
local MakeEventFrame = K.MakeEventFrame
local RegisterInstEvents = K.RegisterInstEvents
local UnregisterInstEvents = K.UnregisterInstEvents
local VSlotW = K.VSlotW
local MaybeRelayout = K.MaybeRelayout
local MUTED_TEXT_COLOR = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[0]
    or { r = 0.667, g = 0.667, b = 0.667 }

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
    return EUI.ELLESMERE_GREEN.r, EUI.ELLESMERE_GREEN.g, EUI.ELLESMERE_GREEN.b
end

local function GetDungeonScoreColor(score)
    if not (C_ChallengeMode and C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor) then
        return GetScoreColor(score)
    end
    local ok, color = pcall(C_ChallengeMode.GetSpecificDungeonOverallScoreRarityColor, score)
    if ok and type(color) == "table"
       and type(color.r) == "number" and type(color.g) == "number" and type(color.b) == "number" then
        return color.r, color.g, color.b
    end
    return GetScoreColor(score)
end

local function GetAccentColor()
    if EUI.GetAccentColor then
        local red, green, blue = EUI.GetAccentColor()
        if type(red) == "number" and type(green) == "number" and type(blue) == "number" then
            return red, green, blue
        end
    end
    local accent = EUI.ELLESMERE_GREEN
    if type(accent) == "table" then return accent.r, accent.g, accent.b end
    return EUI.TEXT_WHITE.r, EUI.TEXT_WHITE.g, EUI.TEXT_WHITE.b
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

local function GetRunNumber(runInfo, field)
    if type(runInfo) ~= "table" then return nil end
    local value = runInfo[field]
    if IsSecret(value) or type(value) ~= "number" then return nil end
    return value
end

local function SelectSeasonBest(inTimeInfo, overtimeInfo)
    local hasInTime = type(inTimeInfo) == "table"
    local hasOvertime = type(overtimeInfo) == "table"
    if not hasInTime then return hasOvertime and overtimeInfo or nil, false end
    if not hasOvertime then return inTimeInfo, true end

    local inTimeScore = GetRunNumber(inTimeInfo, "dungeonScore")
    local overtimeScore = GetRunNumber(overtimeInfo, "dungeonScore")
    if inTimeScore and overtimeScore then
        if overtimeScore > inTimeScore then return overtimeInfo, false end
        if inTimeScore > overtimeScore then return inTimeInfo, true end
    elseif overtimeScore then
        return overtimeInfo, false
    elseif inTimeScore then
        return inTimeInfo, true
    end

    local inTimeLevel = GetRunNumber(inTimeInfo, "level")
    local overtimeLevel = GetRunNumber(overtimeInfo, "level")
    if inTimeLevel and overtimeLevel then
        if overtimeLevel > inTimeLevel then return overtimeInfo, false end
        if inTimeLevel > overtimeLevel then return inTimeInfo, true end
    elseif overtimeLevel then
        return overtimeInfo, false
    elseif inTimeLevel then
        return inTimeInfo, true
    end

    return inTimeInfo, true
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

local function GetColorHex(red, green, blue)
    if type(red) == "table" then
        red, green, blue = red.r, red.g, red.b
    end
    if type(red) ~= "number" or type(green) ~= "number" or type(blue) ~= "number" then
        red, green, blue = EUI.TEXT_WHITE.r, EUI.TEXT_WHITE.g, EUI.TEXT_WHITE.b
    end
    return format("%02x%02x%02x", floor(red * 255 + 0.5), floor(green * 255 + 0.5), floor(blue * 255 + 0.5))
end

local MUTED_HEX = GetColorHex(MUTED_TEXT_COLOR)

local function GetRunTimeColor(chestCount)
    if chestCount == 0 then return MUTED_HEX end
    if chestCount == 3 then
        local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[4]
        if color then return GetColorHex(color) end
        return GetColorHex(EUI.TEXT_WHITE)
    end
    if chestCount == 2 then
        local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[2]
        if color then return GetColorHex(color) end
        return GetColorHex(EUI.TEXT_WHITE)
    end
    return GetColorHex(EUI.TEXT_WHITE)
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

local function GetSpellCooldownRemaining(spellID)
    if not (C_Spell and C_Spell.GetSpellCooldown) then return false end
    local ok, info = pcall(C_Spell.GetSpellCooldown, spellID)
    if not ok or IsSecret(info) or type(info) ~= "table" then return nil end
    local startTime, duration = info.startTime, info.duration
    if IsSecret(startTime) or IsSecret(duration)
       or type(startTime) ~= "number" or type(duration) ~= "number" then
        return nil
    end
    if canaccessvalue and (not canaccessvalue(startTime) or not canaccessvalue(duration)) then return nil end
    if duration <= 0 then return 0 end
    return max(0, startTime + duration - GetTime())
end

local function ShowMythicPlusTooltip(button)
    -- Compose the tooltip with DataBars' helpers so this extension uses the shared tooltip frame.
    local score = GetScore()
    local title = L("Mythic+ Rating") .. ": "
    if score then
        title = title .. "|cff" .. GetColorHex(GetScoreColor(score)) .. tostring(score) .. "|r"
    else
        title = title .. "-"
    end

    local ar, ag, ab = GetAccentColor()

    ns.Tip_Begin(button)
    ns.Tip_AddLine(title, 1, 1, 1)
    ns.Tip_AddLine(" ")
    ns.Tip_AddColumns(L("Dungeon"), {
        "|cff" .. MUTED_HEX .. L("Level") .. "|r",
        "|cff" .. MUTED_HEX .. L("Score") .. "|r",
        "|cff" .. MUTED_HEX .. L("Time (Limit)") .. "|r",
    }, ar, ag, ab)

    local runCount, readyCount, knownCount = 0, 0, 0
    local soonestCooldown
    local tokenBuffer = {}
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
                    runInfo, isInTime = SelectSeasonBest(intimeInfo, overtimeInfo)
                end

                runCount = runCount + 1
                local spellID = GetKnownPortal(dungeonName)
                local cooldown = spellID and GetSpellCooldownRemaining(spellID)
                local readySpellID
                if spellID then knownCount = knownCount + 1 end
                if cooldown == 0 then
                    readySpellID = spellID
                    readyCount = readyCount + 1
                elseif cooldown and (not soonestCooldown or cooldown < soonestCooldown) then
                    soonestCooldown = cooldown
                end

                local level, elapsed, dungeonScore, runTime
                if runInfo then
                    level = runInfo.level
                    elapsed = runInfo.durationSec
                    dungeonScore = runInfo.dungeonScore
                    runTime = FormatRunTime(elapsed)
                end

                local keyText, ratingText, timeText
                if not IsSecret(level) and type(level) == "number" and runTime then
                    level = floor(level)
                    local chestCount = TimerChestCount(elapsed, timeLimit, isInTime)
                    local keyPrefix = "+"
                    if chestCount == 0 then keyPrefix = ""
                    elseif chestCount == 2 then keyPrefix = "++"
                    elseif chestCount == 3 then keyPrefix = "+++" end
                    local limitText = FormatRunTime(timeLimit)
                    if not IsSecret(dungeonScore) and type(dungeonScore) == "number" then
                        local hex = GetColorHex(GetDungeonScoreColor(dungeonScore))
                        keyText = "|cff" .. hex .. keyPrefix .. tostring(level) .. "|r"
                        ratingText = "|cff" .. hex .. tostring(floor(dungeonScore + 0.5)) .. "|r"
                    else
                        keyText = "|cff" .. MUTED_HEX .. keyPrefix .. tostring(level) .. "|r"
                        ratingText = "|cff" .. MUTED_HEX .. "-|r"
                    end
                    timeText = "|cff" .. GetRunTimeColor(chestCount) .. runTime
                        .. "|r |cff" .. MUTED_HEX .. "(" .. (limitText or "-") .. ")|r"
                else
                    local limitText = FormatRunTime(timeLimit)
                    keyText = "|cff" .. MUTED_HEX .. "-|r"
                    ratingText = "|cff" .. MUTED_HEX .. "-|r"
                    timeText = "- |cff" .. MUTED_HEX .. "(" .. (limitText or "-") .. ")|r"
                end

                tokenBuffer[1] = keyText
                tokenBuffer[2] = ratingText
                tokenBuffer[3] = timeText
                if readySpellID then
                    DataBarsExtensions.Tip_AddActionColumns(dungeonName, tokenBuffer, readySpellID)
                else
                    ns.Tip_AddColumns(dungeonName, tokenBuffer)
                end
            end
        end
    end

    if knownCount > 0 then
        ns.Tip_AddLine(" ")
        ns.Tip_AddLine(L("Portals"), ar, ag, ab)
        if readyCount > 0 then
            ns.Tip_AddLine(L("Click a dungeon to teleport"), 0.8, 0.8, 0.8)
        else
            -- On-cooldown portals share one cooldown group, so show the soonest remaining time once.
            local cdText = soonestCooldown and FormatRunTime(ceil(soonestCooldown)) or "-"
            ns.Tip_AddDouble(L("On Cooldown"), cdText, 0.65, 0.65, 0.65, 0.5, 0.5, 0.5)
        end
    end

    ns.Tip_AddLine(" ")
    ns.Tip_AddDouble(L("Left Click") .. ":", L("Open Mythic+ Dungeons"), 1, 1, 1, ar, ag, ab)
    ns.Tip_AddDouble(L("Right Click") .. ":", L("Open Dungeons & Raids"), 1, 1, 1, ar, ag, ab)
    ns.Tip_Show()
end

local function OpenMythicPlusDungeons()
    if InCombatLockdown() or not C_AddOns then return end
    if not C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder") then
        local ok, loaded = pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
        if not ok or not loaded then return end
    end
    if PVEFrame_ToggleFrame then pcall(PVEFrame_ToggleFrame, "ChallengesFrame") end
end

local function OpenDungeonsAndRaids()
    if InCombatLockdown() or not C_AddOns then return end
    if not C_AddOns.IsAddOnLoaded("Blizzard_GroupFinder") then
        local ok, loaded = pcall(C_AddOns.LoadAddOn, "Blizzard_GroupFinder")
        if not ok or not loaded then return end
    end
    -- Pass the Group Finder frame and LFD panel so an open PVEFrame switches there instead of toggling closed.
    if PVEFrame_ToggleFrame then pcall(PVEFrame_ToggleFrame, "GroupFinderFrame", _G.LFDParentFrame) end
end

DataBarsExtensions.RegisterBlock(BLOCK_TYPE, "Mythic+ Rating", {}, function(blockCfg, slot, content, barCtx)
    local inst = { cfg = blockCfg, slot = slot, content = content, ctx = barCtx }
    inst.key = InstKey(barCtx, blockCfg)
    inst.events = {
        "PLAYER_ENTERING_WORLD",
        "CHALLENGE_MODE_COMPLETED",
        "SPELLS_CHANGED",
        "SPELL_UPDATE_COOLDOWN",
    }

    local mouseOver = false
    local button = CreateFrame("Button", nil, content)
    button:SetAllPoints()
    button:EnableMouse(true)
    button:RegisterForClicks("AnyUp")

    local scoreText = button:CreateFontString(nil, "OVERLAY")
    scoreText:SetPoint("CENTER")

    function inst:Refresh()
        if self._dead then return end
        local score = GetScore()
        local text = score and tostring(score) or "-"
        local barCfg = barCtx.cfg
        local fontSize = max(9, floor(CONTENT_BASE * 0.4333 + 0.5))

        ns.SetFont(scoreText, fontSize, barCfg)
        scoreText:SetText(text)
        scoreText:ClearAllPoints()

        if barCtx.IsVertical() then
            local slotW = VSlotW(self)
            local innerW = max(24, slotW - 8)
            ns.SetWrappedText(scoreText, innerW, "CENTER")
            scoreText:SetPoint("CENTER", button, "CENTER")
            local totalH = max(barCtx.GetThickness(), ns.SnapToPixelGrid(scoreText:GetStringHeight()) + 8)
            content:SetSize(slotW, totalH)
        else
            ns.ResetInlineText(scoreText, "CENTER")
            scoreText:SetPoint("CENTER", button, "CENTER")
            local totalW = max(24, ns.SnapToPixelGrid(scoreText:GetStringWidth()) + 12)
            content:SetSize(totalW, barCtx.GetThickness())
        end
        button:SetAllPoints(content)

        local red, green, blue
        if mouseOver then
            red, green, blue = ns.GetAccent()
        elseif score then
            red, green, blue = GetScoreColor(score)
        else
            red, green, blue = MUTED_TEXT_COLOR.r, MUTED_TEXT_COLOR.g, MUTED_TEXT_COLOR.b
        end
        scoreText:SetTextColor(red, green, blue, 1)
        MaybeRelayout(self)
    end

    button:SetScript("OnEnter", function()
        mouseOver = true
        inst:Refresh()
        ShowMythicPlusTooltip(button)
    end)
    button:SetScript("OnLeave", function()
        mouseOver = false
        ns.Tip_HideUnlessInteractive(button) -- lets the cursor travel onto the tip to click a portal
        inst:Refresh()
    end)
    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "LeftButton" then
            OpenMythicPlusDungeons()
        elseif mouseButton == "RightButton" then
            OpenDungeonsAndRaids()
        end
    end)

    inst.eventFrame = MakeEventFrame(inst, function(self, event)
        if self._dead then return end
        self:Refresh()
        if ns.Tip_IsOwned(button) then ShowMythicPlusTooltip(button) end
    end)

    function inst:Enable()
        content:Show()
        RegisterInstEvents(self)
    end

    function inst:Disable()
        UnregisterInstEvents(self)
        ns.Tip_Hide(button)
        mouseOver = false
        content:Hide()
    end

    function inst:GetAutoLength()
        if not content:IsShown() then return 0 end
        if barCtx.IsVertical() then
            return max(content:GetHeight() or 40, 30)
        end
        return max(content:GetWidth() or 40, 24)
    end

    function inst:Destroy()
        self._dead = true
        UnregisterInstEvents(self)
        ns.Tip_Hide(button)
        content:Hide()
    end

    return inst
end)
