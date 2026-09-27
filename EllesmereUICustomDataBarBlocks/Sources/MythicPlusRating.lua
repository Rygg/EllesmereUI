if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local ADDON_NAME, ns = ...
local EUI = EllesmereUI
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local PORTALS = EUI and EUI.SEASON_PORTALS
if not (LDB and type(PORTALS) == "table") then return end

local MAX_RUNS = 16

local format = string.format
local floor = math.floor
local ceil = math.ceil
local type = type
local ipairs = ipairs
local pcall = pcall
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local ITEM_QUALITY_COLORS = ITEM_QUALITY_COLORS
local MUTED_TEXT_COLOR = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[0]
    or { r = 0.667, g = 0.667, b = 0.667 }

local dataObject
local eventFrame
local owner
local tokenBuffer = {}

local function IsSecret(value)
    return issecretvalue and issecretvalue(value)
end

local function GetScore()
    if not (C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary) then return nil end
    local ok, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
    if not ok or IsSecret(summary) or type(summary) ~= "table" then return nil end
    local score = summary.currentSeasonScore
    if IsSecret(score) or type(score) ~= "number" then return nil end
    return math.max(0, floor(score + 0.5))
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
        local color = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[3]
        if color then return GetColorHex(color) end
        return GetColorHex(EUI.TEXT_WHITE)
    end
    if chestCount == 2 then
        return GetColorHex(GetAccentColor())
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
    if not canaccessvalue(startTime) or not canaccessvalue(duration) then return nil end
    if duration <= 0 then return 0 end
    return math.max(0, startTime + duration - GetTime())
end

local function RenderTooltip()
    local score = GetScore()
    local title = "Current Rating: "
    if score then
        title = title .. "|cff" .. GetColorHex(GetScoreColor(score)) .. tostring(score) .. "|r"
    else
        title = title .. "-"
    end

    ns.Tip_Begin(owner)
    ns.Tip_AddLine(title, 1, 1, 1)
    ns.Tip_AddLine(" ")
    ns.Tip_AddColumns("Dungeon", {
        "|cff" .. MUTED_HEX .. "Key|r",
        "|cff" .. MUTED_HEX .. "Rating|r",
        "|cff" .. MUTED_HEX .. "Run (Limit)|r",
    }, 0.8, 0.8, 0.8)

    local runCount, readyCount = 0, 0
    local soonestCooldown
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
                local spellID = GetKnownPortal(dungeonName)
                local cooldown = spellID and GetSpellCooldownRemaining(spellID)
                local readySpellID
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
                    ns.Tip_AddActionColumns(dungeonName, tokenBuffer, readySpellID)
                else
                    ns.Tip_AddColumns(dungeonName, tokenBuffer)
                end
            end
        end
    end

    if runCount > 0 and readyCount == 0 then
        local hint = "No portals available"
        if soonestCooldown then
            hint = hint .. " - Available in " .. FormatRunTime(ceil(soonestCooldown))
        end
        ns.Tip_AddLine(hint, 0.8, 0.8, 0.8)
    end

    local ar, ag, ab = GetAccentColor()
    ns.Tip_AddLine(" ")
    ns.Tip_AddDouble("Left Click:", "Open Mythic+ Menu", 1, 1, 1, ar, ag, ab)
    ns.Tip_Show()
end

local function ShowTooltip(frame)
    owner = frame
    RenderTooltip()
end

local function HideTooltip(frame)
    ns.Tip_HideUnlessInteractive(frame)
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
    dataObject.text = "|cff" .. GetColorHex(GetScoreColor(score)) .. tostring(score) .. "|r"
end

local function OnLDBClick(_, mouseButton)
    if mouseButton == "LeftButton" then OpenMythicPlusMenu() end
end

local objectOK, registeredObject = pcall(LDB.NewDataObject, LDB, "EllesmereUI Mythic+ Rating", {
    type = "data source",
    label = "Mythic+ Rating",
    text = "-",
    OnEnter = ShowTooltip,
    OnLeave = HideTooltip,
    OnClick = OnLDBClick,
})
if not objectOK or type(registeredObject) ~= "table" then return end
dataObject = registeredObject

eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" or event == "CHALLENGE_MODE_COMPLETED" then
        RefreshScore()
    end
    if ns.Tip_IsOwned(owner) then
        RenderTooltip()
    end
end)
RefreshScore()
