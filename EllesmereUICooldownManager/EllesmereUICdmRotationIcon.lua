local _, ns = ...
if not ns.ECME then return end

-- A display-only consumer of Blizzard's recommendation changes. No secure
-- action button, Blizzard-frame writes, hooks, timers or polling.
local frame, icon, textOverlay, keybind, gcd
local active, preview = false, false
local gcdActive, recommendationShown = false, false
local moverKey = "CDM_RotationAssistIcon"
local callbacks = {
    "AssistedCombatManager.OnAssistedHighlightSpellChange",
    "AssistedCombatManager.OnSetUseAssistedHighlight",
    "AssistedCombatManager.RotationSpellsUpdated",
}
local events = {
    "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED",
    "PLAYER_SPECIALIZATION_CHANGED", "UPDATE_SHAPESHIFT_FORM",
    "UPDATE_OVERRIDE_ACTIONBAR", "UPDATE_VEHICLE_ACTIONBAR",
    "PET_BATTLE_OPENING_START", "PET_BATTLE_CLOSE",
}

local function Settings()
    local p = ns.ECME.db and ns.ECME.db.profile
    return p and p.rotationAssistIcon
end

local function SpellID(value)
    if issecretvalue(value) or type(value) ~= "number" or value <= 0 then return nil end
    return value
end

local function ReadKeybind(id)
    local value = ns.CDMKeybindCache[id]
    if not issecretvalue(value) and type(value) == "string" then return value end
end

local function FindKeybind(spellID)
    local key = ReadKeybind(spellID)
    if not key then
        local override = SpellID(C_Spell.GetOverrideSpell(spellID))
        if override then key = ReadKeybind(override) end
    end
    if not key then
        local base = SpellID(C_Spell.GetBaseSpell(spellID))
        if base then key = ReadKeybind(base) end
    end
    if not key then
        local name = C_Spell.GetSpellName(spellID)
        if not issecretvalue(name) and type(name) == "string" then key = ReadKeybind(name) end
    end
    if not issecretvalue(key) and type(key) == "string" then return key end
end

local function ClearGCD()
    if gcd then gcd:Clear(); gcd:Hide() end
end

local function UpdateGCD()
    if not gcdActive then return end
    if not recommendationShown or not frame:IsShown() then ClearGCD(); return end
    -- The global cooldown is independent of the recommended spell's cooldown.
    -- Pass its duration object directly to the native widget; no timing reads.
    local duration = C_Spell.GetSpellCooldownDuration(61304)
    if duration then
        gcd:Show()
        gcd:SetCooldownFromDurationObject(duration, true)
    else
        ClearGCD()
    end
end

local function Update()
    if not active then return end
    local cfg = Settings()
    local editing = preview and not InCombatLockdown()
    local spellID
    if cfg and cfg.enabled and GetCVarBool("assistedCombatHighlight")
        and (editing or not cfg.onlyInCombat or InCombatLockdown())
        and not C_ActionBar.HasVehicleActionBar() and not C_ActionBar.HasOverrideActionBar()
        and not C_PetBattles.IsInBattle() and C_AssistedCombat.IsAvailable() then
        spellID = SpellID(C_AssistedCombat.GetNextCastSpell(true))
    end
    if not cfg or not cfg.enabled or (not spellID and not editing) then
        recommendationShown = false
        ClearGCD()
        keybind:SetText("")
        keybind:Hide()
        frame:Hide()
        return
    end
    local texture = spellID and C_Spell.GetSpellTexture(spellID) or 134400
    if issecretvalue(texture) or not texture then
        recommendationShown = false
        ClearGCD()
        keybind:SetText("")
        keybind:Hide()
        frame:Hide()
        return
    end
    icon:SetTexture(texture)
    local key = cfg.showKeybind and spellID and FindKeybind(spellID)
    keybind:SetText(key or "")
    keybind:SetShown(key ~= nil and key ~= false and key ~= "")
    ns.RefreshCDMKeybindBadge(keybind, cfg)
    recommendationShown = spellID ~= nil
    frame:Show()
    UpdateGCD()
end

local function OnEvent(_, event)
    if event == "SPELL_UPDATE_COOLDOWN" then UpdateGCD() else Update() end
end

local function ApplyPosition()
    if not frame or EllesmereUI._unlockActive then return end
    local cfg = Settings()
    local pos = cfg and cfg.position
    frame:ClearAllPoints()
    frame:SetPoint(pos and pos.point or "CENTER", UIParent,
        pos and pos.relPoint or "CENTER", pos and pos.x or 0, pos and pos.y or -140)
end

local function OnUnlock(activeSession)
    preview = activeSession
    if not activeSession then ApplyPosition() end
    Update()
end

local function RegisterMover()
    EllesmereUI:RegisterUnlockElements({ EllesmereUI.MakeUnlockElement({
        key = moverKey, label = "Rotation Assist Icon", group = "Cooldown Manager", order = 601,
        getFrame = function() return frame end,
        getSize = function() return frame:GetWidth(), frame:GetHeight() end,
        noResize = true, noAnchorTo = true, noAnchorTarget = true, noSizeMatchTarget = true,
        savePos = function(_, point, relPoint, x, y)
            local cfg = Settings()
            if cfg then cfg.position = { point = point, relPoint = relPoint, x = x, y = y } end
            ApplyPosition()
        end,
        loadPos = function() local cfg = Settings(); return cfg and cfg.position end,
        clearPos = function() local cfg = Settings(); if cfg then cfg.position = nil end end,
        applyPos = ApplyPosition,
    }) }, "EllesmereUICooldownManager")
    EllesmereUI:RegisterUnlockModeListener(frame, OnUnlock)
end

local function CreateIcon()
    frame = ns.TakeShell()
    frame:SetParent(UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:EnableMouse(false)
    frame:Hide()
    local background = frame:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0, 0, 0, 1)
    icon = frame:CreateTexture(nil, "ARTWORK")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    -- Badge textures must sit above the icon, even on the BACKGROUND layer.
    textOverlay = CreateFrame("Frame", nil, frame)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameLevel(frame:GetFrameLevel() + 1)
    textOverlay:EnableMouse(false)
    keybind = textOverlay:CreateFontString(nil, "OVERLAY")
    -- SetText also requires a font when the opt-in label is still hidden.
    EllesmereUI.ApplyIconTextFont(keybind, ns.GetCDMFont(), 14 * EllesmereUI.PP.mult, "cdm")
end

local function ConfigureGCD(cfg)
    if cfg.showGCD and not gcdActive then
        if not gcd then
            gcd = CreateFrame("Cooldown", nil, frame, "CooldownFrameTemplate")
            gcd:SetAllPoints(icon)
            gcd:SetFrameLevel(frame:GetFrameLevel() + 1)
            gcd:EnableMouse(false)
            gcd:SetDrawSwipe(true)
            gcd:SetSwipeColor(0, 0, 0, 0.65)
            gcd:SetDrawEdge(true)
            gcd:SetDrawBling(false)
            gcd:SetHideCountdownNumbers(true)
            textOverlay:SetFrameLevel(gcd:GetFrameLevel() + 1)
        end
        gcdActive = true
        frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    elseif not cfg.showGCD and gcdActive then
        gcdActive = false
        frame:UnregisterEvent("SPELL_UPDATE_COOLDOWN")
        ClearGCD()
    end
end

function ns.RefreshRotationAssistIcon()
    local cfg = Settings()
    if not cfg or not cfg.enabled then
        if not active then return end
        active, preview = false, false
        gcdActive, recommendationShown = false, false
        ClearGCD()
        ns.UpdateRotationAssistIconKeybind = nil
        frame:UnregisterAllEvents()
        frame:SetScript("OnEvent", nil)
        for i = 1, #callbacks do EventRegistry:UnregisterCallback(callbacks[i], frame) end
        EllesmereUI:UnregisterUnlockModeListener(frame)
        EllesmereUI:UnregisterUnlockElement(moverKey)
        keybind:SetText("")
        keybind:Hide()
        frame:Hide()
        return
    end
    if not frame then CreateIcon() end
    EllesmereUI.PP.Size(frame, cfg.iconSize or 48, cfg.iconSize or 48)
    EllesmereUI.PP.Point(icon, "TOPLEFT", frame, "TOPLEFT", 1, -1)
    EllesmereUI.PP.Point(icon, "BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    ns.StyleCDMKeybind(keybind, cfg, textOverlay, EllesmereUI.PP.mult, ns.GetCDMFont())
    ApplyPosition()
    if not active then
        active = true
        ns.UpdateRotationAssistIconKeybind = Update
        frame:SetScript("OnEvent", OnEvent)
        for i = 1, #events do frame:RegisterEvent(events[i]) end
        for i = 1, #callbacks do EventRegistry:RegisterCallback(callbacks[i], Update, frame) end
        RegisterMover()
    end
    ConfigureGCD(cfg)
    Update()
end
