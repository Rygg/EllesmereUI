if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local _, addonNS = ...
local EUI = EllesmereUI
local DataBarsExtensions = addonNS and addonNS.DataBarsExtensions
-- DataBars keeps its module namespace private to its addon. Its engine publishes
-- that namespace on the parent for its own options integration; this addon uses
-- the same internal seam to register a separately updateable block. The hard
-- TOC dependency guarantees DataBars has loaded first. Fail closed if that
-- implementation detail changes instead of breaking the UI at startup.
local ns = DataBarsExtensions and DataBarsExtensions.DataBars
if not (DataBarsExtensions and DataBarsExtensions.RegisterBlock
    and ns and ns.BlockFactories and ns.BLOCK_TYPES and ns.BLOCK_DEFAULTS and ns.BlockKit) then
    return
end
if not (ns.CreateFramePool and ns.CreatePopupFrame and ns.GetAccent and ns.SetFont
    and ns.SetWrappedText and ns.ResetInlineText and ns.SnapToPixelGrid) then
    return
end
if not (C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs and C_EquipmentSet.GetEquipmentSetInfo) then
    return
end

local K = ns.BlockKit
-- Mirrors DataBars' own `local L = ns.L` per-file convention: shared keys
-- (LEFT_CLICK, ILVL, ITEM_LEVEL, ...) fall through to ns.L, new keys live here.
local L = setmetatable({
    EQUIPMENT_SET        = "Equipment Set",
    CHANGE_EQUIPMENT_SET = "Change Equipment Set",
    NO_SET               = "No Set",
}, { __index = ns.L or {} })

local BLOCK_TYPE = "equipmentset"
local POPUP_FONT_SIZE = 12
local POPUP_PAD = 8

-- Upvalues
local CreateFrame      = CreateFrame
local _G               = _G
local UIParent         = UIParent
local InCombatLockdown = InCombatLockdown
local ipairs           = ipairs
local format           = string.format
local sort             = table.sort
local floor            = math.floor
local max              = math.max
local min              = math.min

local ICON_GAP             = K.ICON_GAP
local CONTENT_BASE         = K.CONTENT_BASE
local InstKey              = K.InstKey
local MakeEventFrame       = K.MakeEventFrame
local RegisterInstEvents   = K.RegisterInstEvents
local UnregisterInstEvents = K.UnregisterInstEvents
local HBudget              = K.HBudget
local VSlotW               = K.VSlotW
local MaybeRelayout        = K.MaybeRelayout
local AttachTextOffset     = K.AttachTextOffset
local BlockColorOf         = K.BlockColorOf
local IconColorOf          = K.IconColorOf

-------------------------------------------------------------------------------
--  Data helpers
-------------------------------------------------------------------------------
-- Item level returns can be secret values (see DataBars' ItemLevel.lua); strip them here, once.
local function AvgIlvl()
    local total, equipped, pvp = GetAverageItemLevel()
    if issecretvalue then
        if issecretvalue(total) then total = nil end
        if issecretvalue(equipped) then equipped = nil end
        if issecretvalue(pvp) then pvp = nil end
    end
    return total, equipped, pvp
end

local function Fmt(v, p)
    if not v then return "-" end
    return format("%." .. p .. "f", v)
end

local function LongLabel()
    return STAT_AVERAGE_ITEM_LEVEL or EUI.L(L["ITEM_LEVEL"])
end

-- Alphabetical, like the Bags addon's equipment-set category split.
local function GetSetList()
    local list = {}
    local ids = C_EquipmentSet.GetEquipmentSetIDs()
    if not ids then return list end
    for _, setID in ipairs(ids) do
        local name, icon, _, isEquipped = C_EquipmentSet.GetEquipmentSetInfo(setID)
        if name then
            list[#list + 1] = { id = setID, name = name, icon = icon, isEquipped = isEquipped == true }
        end
    end
    sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- The set whose gear exactly matches what's worn; nil when gear doesn't match any saved set.
local function GetActiveSet(list)
    for i = 1, #list do
        if list[i].isEquipped then return list[i] end
    end
    return nil
end

-- Prefer EquipmentManager_EquipSet over raw C_EquipmentSet (cleaner from insecure code); equipping is blocked in combat.
local function EquipSet(setID)
    if InCombatLockdown() or not setID then return end
    if EquipmentManager_EquipSet then
        EquipmentManager_EquipSet(setID)
    else
        C_EquipmentSet.UseEquipmentSet(setID)
    end
end

DataBarsExtensions.RegisterBlock(BLOCK_TYPE, "Equipment Set",
    { showIcon = true, useUppercase = false, precision = 0, ilvlPrefix = "short" },
    function(blockCfg, slot, content, barCtx)
    local inst = { cfg = blockCfg, slot = slot, content = content, ctx = barCtx }
    inst.key = InstKey(barCtx, blockCfg)
    inst.events = { "EQUIPMENT_SETS_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
                    "PLAYER_AVG_ITEM_LEVEL_UPDATE", "PLAYER_ENTERING_WORLD",
                    "PLAYER_REGEN_ENABLED" }

    local mouseOver = false
    local setList = {}
    local activeSet = nil
    local pool
    local clickBtn

    local function D() return blockCfg.settings or {} end
    local function BC() return barCtx.cfg end

    local button = CreateFrame("Button", nil, content)
    button:SetAllPoints()
    button:EnableMouse(true)
    button:RegisterForClicks("AnyUp")

    local setIcon = content:CreateTexture(nil, "OVERLAY"); setIcon:SetSize(16, 16)
    local setText = content:CreateFontString(nil, "OVERLAY")
    local infoText = content:CreateFontString(nil, "OVERLAY")
    AttachTextOffset(inst, setText) -- infoText chains to setText

    local function GetDisplayName()
        local name = activeSet and activeSet.name or EUI.L(L["NO_SET"])
        if D().useUppercase == true then return name:upper() end
        return name
    end

    local function GetIlvlText()
        local d = D()
        local _, equipped = AvgIlvl()
        local p = d.precision
        if p == nil then p = 0 end
        local body = Fmt(equipped, p)
        local prefix = d.ilvlPrefix or "short"
        if prefix == "short" then
            return EUI.L(L["ILVL"]) .. " " .. body
        elseif prefix == "long" then
            return LongLabel() .. " " .. body
        end
        return body
    end

    -- Hover-driven popup, same recipe as Spec.lua's spec switcher: catcher-free,
    -- dismissed by a hover-watch OnUpdate instead of a fullscreen click-catcher.
    local hoverWatch

    local function BuildPopup()
        if not pool then pool = ns.CreateFramePool("Button", UIParent) end
        pool:ReleaseAll()
        local popup = pool._popup
        if not popup then
            popup = ns.CreatePopupFrame(button)
            pool._popup = popup
        end
        popup._wbNoCatcher = true
        popup._wbOnHide = function() pool:ReleaseAll() end
        popup:Show()

        local ar, ag, ab = ns.GetAccent()
        local fontSize = POPUP_FONT_SIZE
        local iconSz = fontSize + 2
        local PAD, LINE = POPUP_PAD, 18

        if not popup._title then popup._title = popup:CreateFontString(nil, "OVERLAY") end
        popup._title:ClearAllPoints()
        popup._title:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, -PAD)
        ns.SetFont(popup._title, fontSize)
        popup._title:SetText(EUI.L(L["CHANGE_EQUIPMENT_SET"]))
        popup._title:SetTextColor(1, 1, 1, 1)
        popup._title:Show()
        local maxW = popup._title:GetStringWidth()
        local yOff = PAD + LINE + PAD

        local rowBtns = {}
        for _, entry in ipairs(setList) do
            local btn = pool:Acquire()
            btn:SetParent(popup)
            btn:SetHeight(iconSz + 4)
            btn:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, -yOff)
            btn:EnableMouse(true); btn:RegisterForClicks("AnyUp")
            if not btn._hl then
                btn._hl = btn:CreateTexture(nil, "HIGHLIGHT")
                btn._hl:SetAllPoints()
            end
            btn._hl:SetColorTexture(1, 1, 1, 0.10)

            if not btn._icon then btn._icon = btn:CreateTexture(nil, "OVERLAY") end
            btn._icon:SetSize(iconSz, iconSz)
            btn._icon:ClearAllPoints()
            btn._icon:SetPoint("LEFT")
            if entry.icon then
                btn._icon:SetTexture(entry.icon)
                btn._icon:SetTexCoord(4 / 64, 60 / 64, 4 / 64, 60 / 64)
                btn._icon:Show()
            else
                btn._icon:Hide()
            end

            if not btn._label then btn._label = btn:CreateFontString(nil, "OVERLAY") end
            btn:Show()
            ns.SetFont(btn._label, fontSize)
            btn._label:SetText(entry.name)
            btn._label:Show()
            btn._label:ClearAllPoints()
            if entry.icon then
                btn._label:SetPoint("LEFT", btn._icon, "RIGHT", 4, 0)
            else
                btn._label:SetPoint("LEFT", btn, "LEFT", 0, 0)
            end

            if entry.isEquipped then btn._label:SetTextColor(ar, ag, ab, 1)
            else btn._label:SetTextColor(1, 1, 1, 1) end

            btn:SetScript("OnEnter", function() btn._label:SetTextColor(ar, ag, ab, 1) end)
            btn:SetScript("OnLeave", function()
                if entry.isEquipped then btn._label:SetTextColor(ar, ag, ab, 1)
                else btn._label:SetTextColor(1, 1, 1, 1) end
            end)
            btn:SetScript("OnClick", function(_, mb)
                if mb == "LeftButton" and not InCombatLockdown() then
                    EquipSet(entry.id)
                    popup:Hide()
                end
            end)

            local iconExtra = 0
            if btn._icon:IsShown() then iconExtra = iconSz + 4 end
            local bw = iconExtra + btn._label:GetStringWidth()
            if bw > maxW then maxW = bw end
            btn:SetWidth(bw)
            rowBtns[#rowBtns + 1] = btn
            yOff = yOff + (iconSz + 4) + 3
        end
        if #setList > 0 then yOff = yOff - 3 end

        yOff = yOff + 8
        if not popup._footL then popup._footL = popup:CreateFontString(nil, "OVERLAY") end
        if not popup._footR then popup._footR = popup:CreateFontString(nil, "OVERLAY") end
        ns.SetFont(popup._footL, fontSize); ns.SetFont(popup._footR, fontSize)
        popup._footL:SetText(EUI.L(L["LEFT_CLICK"])); popup._footL:SetTextColor(1, 1, 1, 1)
        popup._footR:SetText(EUI.L(L["OPEN_CHARACTER"])); popup._footR:SetTextColor(1, 1, 1, 1)
        popup._footL:ClearAllPoints(); popup._footL:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, -yOff)
        popup._footR:ClearAllPoints(); popup._footR:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -PAD, -yOff)
        popup._footL:Show(); popup._footR:Show()
        local fw = (popup._footL:GetStringWidth() or 0) + 16 + (popup._footR:GetStringWidth() or 0)
        if fw > maxW then maxW = fw end
        yOff = yOff + fontSize + 4

        if maxW < 60 then maxW = 60 end -- floor so an empty set list never renders a degenerate sliver
        popup:SetSize(maxW + PAD * 2, yOff + PAD)
        for i = 1, #rowBtns do rowBtns[i]:SetWidth(maxW) end

        popup:ClearAllPoints()
        if barCtx.IsVertical() then
            local cx = button:GetCenter()
            if cx and cx > UIParent:GetWidth() / 2 then
                popup:SetPoint("RIGHT", button, "LEFT", -4, 0)
            else
                popup:SetPoint("LEFT", button, "RIGHT", 4, 0)
            end
        else
            if barCtx.IsBarAtTop() then
                popup:SetPoint("TOP", button, "BOTTOM", 0, -4)
            else
                popup:SetPoint("BOTTOM", button, "TOP", 0, 4)
            end
        end
        popup:SetClampedToScreen(true)
        return popup
    end

    local function TogglePopup()
        if pool and pool._popup and pool._popup:IsShown() then
            pool._popup:Hide(); return
        end
        BuildPopup()
    end

    hoverWatch = CreateFrame("Frame")
    hoverWatch:Hide()
    hoverWatch:SetScript("OnUpdate", function(self)
        local popup = pool and pool._popup
        if not (popup and popup:IsShown()) then self:Hide(); return end
        if button:IsMouseOver(8, -8, -8, 8) or popup:IsMouseOver(8, -8, -8, 8) then return end
        popup:Hide()
        self:Hide()
    end)

    button:SetScript("OnEnter", function()
        mouseOver = true; inst:Refresh()
        if not (pool and pool._popup and pool._popup:IsShown()) then
            TogglePopup()
        end
        hoverWatch:Show()
    end)
    button:SetScript("OnLeave", function() mouseOver = false; inst:Refresh() end)
    button:SetScript("OnClick", function(_, mb)
        if mb == "LeftButton" and ToggleCharacter then
            ToggleCharacter("PaperDollFrame")
        end
    end)

    local function EnsureClickButton()
        if clickBtn or InCombatLockdown() then return clickBtn end
        local micro = _G.CharacterMicroButton
        if not micro then return nil end
        clickBtn = CreateFrame("Button", "EWB_EQUIPMENTSET_" .. inst.key, button,
            "SecureActionButtonTemplate,SecureHandlerStateTemplate")
        clickBtn:SetAllPoints(button)
        clickBtn:SetAttribute("*clickbutton1", micro)
        clickBtn:SetAttribute("useOnKeyDown", false)
        clickBtn:SetAttribute("*type1", "click")
        clickBtn:EnableMouse(true)
        clickBtn:RegisterForClicks("AnyUp")
        RegisterStateDriver(clickBtn, "combatlock", "[combat] combat; nocombat")
        clickBtn:SetAttribute("_onstate-combatlock", [[
            if newstate == 'combat' then
                self:SetAttribute('*type1', nil)
            else
                self:SetAttribute('*type1', 'click')
            end
        ]])
        clickBtn:SetScript("OnEnter", button:GetScript("OnEnter"))
        clickBtn:SetScript("OnLeave", button:GetScript("OnLeave"))
        return clickBtn
    end

    function inst:Refresh()
        EnsureClickButton()
        setList = GetSetList()
        activeSet = GetActiveSet(setList)

        local d = D()
        local barCfg = BC()
        local barH = barCtx.GetThickness()
        local fontSize = max(9, floor(CONTENT_BASE * 0.4333 + 0.5))
        local infoSz = max(8, floor(CONTENT_BASE * 0.36 + 0.5))
        local gap = 4
        local iconGap = ICON_GAP
        local ar, ag, ab = ns.GetAccent()
        local isSide = barCtx.IsVertical()

        ns.SetFont(setText, fontSize, barCfg); ns.SetFont(infoText, infoSz, barCfg)
        setText:SetText(GetDisplayName())
        infoText:SetText(GetIlvlText())

        local iconTexture = activeSet and activeSet.icon
        local showIcon = d.showIcon ~= false and iconTexture ~= nil
        if showIcon then
            setIcon:SetTexture(iconTexture)
            setIcon:SetTexCoord(0, 1, 0, 1)
            setIcon:Show()
        else
            setIcon:Hide()
        end

        if mouseOver then
            setText:SetTextColor(ar, ag, ab, 1); setIcon:SetVertexColor(ar, ag, ab, 1)
        else
            local br, bgr, bb = BlockColorOf(blockCfg)
            local ir, ig, ib = IconColorOf(blockCfg)
            setText:SetTextColor(br, bgr, bb, 1); setIcon:SetVertexColor(ir, ig, ib, 1)
        end
        infoText:SetTextColor(1, 1, 1, 0.8)

        local iconSz = fontSize + 8
        if isSide then
            iconSz = min(iconSz, max(14, floor(CONTENT_BASE * 0.72 + 0.5)))
        end
        if not showIcon then iconSz = 0 end

        if isSide then
            local slotW = VSlotW(inst)
            local innerW = max(30, slotW - 8)
            local totalH = 8

            if showIcon then
                setIcon:SetSize(iconSz, iconSz)
                setIcon:ClearAllPoints()
                setIcon:SetPoint("TOP", content, "TOP", 0, -4)
                totalH = totalH + iconSz + 2
            end

            ns.SetWrappedText(setText, innerW, "CENTER")
            setText:ClearAllPoints()
            if showIcon then
                setText:SetPoint("TOP", setIcon, "BOTTOM", 0, -2)
            else
                setText:SetPoint("TOP", content, "TOP", 0, -4)
            end
            totalH = totalH + ns.SnapToPixelGrid(setText:GetStringHeight())

            ns.SetWrappedText(infoText, innerW, "CENTER")
            infoText:ClearAllPoints()
            infoText:SetPoint("TOP", setText, "BOTTOM", 0, -2)
            totalH = totalH + 2 + ns.SnapToPixelGrid(infoText:GetStringHeight())

            totalH = max(totalH, barH)
            content:SetSize(slotW, totalH)
        else
            local slotW = HBudget(inst, 140)
            ns.ResetInlineText(setText, "LEFT")
            ns.ResetInlineText(infoText, "LEFT")

            local effIconGap = showIcon and iconGap or 0
            if showIcon then
                setIcon:SetSize(iconSz, iconSz)
                setIcon:ClearAllPoints(); setIcon:SetPoint("LEFT", content, "LEFT", 0, 0)
            end
            setText:ClearAllPoints(); setText:SetPoint("LEFT", content, "LEFT", iconSz + effIconGap, 0)
            local tw = ns.SnapToPixelGrid(setText:GetStringWidth())
            infoText:ClearAllPoints(); infoText:SetPoint("LEFT", setText, "RIGHT", gap, 0)
            local iw = ns.SnapToPixelGrid(infoText:GetStringWidth() or 0)

            local totalW = min(slotW, iconSz + effIconGap + tw + gap + iw + 4)
            content:SetSize(max(totalW, 10), barH)
        end
        button:ClearAllPoints(); button:SetAllPoints(content)
        MaybeRelayout(inst)
    end

    inst.eventFrame = MakeEventFrame(inst, function(self)
        self:Refresh()
    end)

    function inst:Enable()
        content:Show()
        RegisterInstEvents(self)
    end

    function inst:Disable()
        UnregisterInstEvents(self)
        if pool and pool._popup and pool._popup:IsShown() then pool._popup:Hide() end
        content:Hide()
    end

    function inst:GetAutoLength()
        local barH = barCtx.GetThickness()
        if barCtx.IsVertical() then
            local textH = setText:GetStringHeight() or 10
            local infoH = infoText:GetStringHeight() or 0
            return max(8 + textH + 2 + infoH + 4, barH, 60)
        end
        return max(content:GetWidth() or 120, 40)
    end

    function inst:Destroy()
        self._dead = true
        if pool and pool._popup and pool._popup:IsShown() then pool._popup:Hide() end
        content:Hide()
    end

    return inst
end)
