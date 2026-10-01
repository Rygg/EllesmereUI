if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  Bag Bar on WoW Forever
--
--  The Bag Bar slot buttons (backpack, the four bag slots, the reagent bag and
--  the keyring) have no house treatment on any client. On Forever -- where the
--  micro menu now takes the flat dark look (see WindowPacks) -- a bare Blizzard
--  bag bar sitting next to it reads as unfinished. This gives each slot the same
--  square, flat-dark, 1px-border cell: the bevelled icon frame art faded, the
--  icon cropped square, a theme background behind it, an accent border on hover
--  and a quality-tinted border for a coloured bag; the BagsBar container's own
--  dark strip art is flattened too. Visual only -- never Hides/reparents the
--  Edit-Mode-owned BagsBar (that would taint); it only alphas art and adds a
--  border frame in place. Nothing here runs on retail (IS_FOREVER is false).
--------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
local WSkin = ns.WSkin
if not (WSkin and WSkin.RegisterWindow) then return end

local Theme = WSkin.Theme
local FFD = setmetatable({}, { __mode = "k" })
local function GetFFD(frame)
    local d = FFD[frame]
    if not d then d = {}; FFD[frame] = d end
    return d
end

local WHITE     = "Interface\\Buttons\\WHITE8X8"
local ICON_CROP = 0.08
-- BagsBar container backdrop atlases to flatten (the dark strip behind the slots).
local FRAME_ATLASES = { "actionbar-frame", "iconframe-background" }
local BAG_BUTTONS = {
    "MainMenuBarBackpackButton",
    "CharacterBag0Slot", "CharacterBag1Slot", "CharacterBag2Slot", "CharacterBag3Slot",
    "CharacterReagentBag0Slot", "KeyRingButton",
}

local function AccentColor()
    if WSkin.GetAccentColor then local r, g, b = WSkin.GetAccentColor(); if r then return r, g, b end end
    return 144 / 255, 12 / 255, 210 / 255
end
local function CellColor()
    return (Theme and Theme.bgR) or 0.08, (Theme and Theme.bgG) or 0.08,
           (Theme and Theme.bgB) or 0.08, (Theme and Theme.bgA) or 0.92
end
-- A darker-than-theme border for these flat cells (matches the micro menu cells).
local BORDER_DARK = { 0.14, 0.14, 0.14 }
local function RestBorder()
    return BORDER_DARK[1], BORDER_DARK[2], BORDER_DARK[3]
end

-- 1px border (accent on hover, quality-tinted at rest for a coloured bag) + flat
-- cell background, mirroring the micro menu pack's look.
local function EnsureChrome(btn)
    local d = GetFFD(btn)
    if d.box then return d end
    local box = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    box:SetAllPoints(btn)
    box:EnableMouse(false)
    box:SetBackdrop({ edgeFile = WHITE, edgeSize = 1 })
    local gr, gg, gb = RestBorder()
    box:SetBackdropBorderColor(gr, gg, gb, 1)
    d.box = box
    d.rest = { gr, gg, gb }
    local br, bg2, bb, ba = CellColor()
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetColorTexture(br, bg2, bb, ba)
    bg:SetAllPoints(btn)
    d.bg = bg
    btn:HookScript("OnEnter", function()
        local r, g, b = AccentColor()
        box:SetBackdropBorderColor(r, g, b, 1)
    end)
    btn:HookScript("OnLeave", function()
        box:SetBackdropBorderColor(d.rest[1], d.rest[2], d.rest[3], 1)
    end)
    local hl = btn.GetHighlightTexture and btn:GetHighlightTexture()
    if hl and hl.SetColorTexture then
        hl:SetColorTexture(1, 1, 1, 0.1)
        if hl.SetTexCoord then hl:SetTexCoord(0, 1, 0, 1) end
    end
    return d
end

local function SetRest(btn, r, g, b)
    local d = GetFFD(btn)
    if not d.box then return end
    d.rest[1], d.rest[2], d.rest[3] = r, g, b
    if not btn:IsMouseOver() then d.box:SetBackdropBorderColor(r, g, b, 1) end
end

local function BagQuality(btn)
    local id = btn.GetID and btn:GetID()
    if not id or id <= 0 then return nil end
    local q = GetInventoryItemQuality and GetInventoryItemQuality("player", id)
    if q and q >= 2 and C_Item and C_Item.GetItemQualityColor then
        return C_Item.GetItemQualityColor(q)
    end
end

-- Alpha-out the BagsBar container's Blizzard strip art (never :Hide() -- it is
-- Edit-Mode owned and a raw Hide taints).
local function FlattenFrameArt(frame)
    if not frame or not frame.GetRegions then return end
    for i = 1, select("#", frame:GetRegions()) do
        local r = select(i, frame:GetRegions())
        local atlas = r and r.GetAtlas and r:GetAtlas()
        if atlas then
            local la = atlas:lower()
            for _, want in ipairs(FRAME_ATLASES) do
                if la:find(want, 1, true) then r:SetAlpha(0); break end
            end
        end
    end
end

local function SkinBag(btn)
    if not btn then return end
    EnsureChrome(btn)
    local isKeyRing = (btn == _G.KeyRingButton)
    local icon = btn.icon or (btn.GetName and _G[btn:GetName() .. "IconTexture"])
    local nt = (btn.GetNormalTexture and btn:GetNormalTexture()) or btn.NormalTexture
    if isKeyRing then
        -- The keyring is a special Forever frame. Detach its rounded SquareMask, then
        -- clear its leftover frame art: Blizzard nests a NineSlice border in CHILD
        -- frames that are created lazily (AFTER our skin pass), so a one-shot fade
        -- misses them. Fade every descendant frame texture now AND hook each child's
        -- OnShow, so the border stays gone whenever Blizzard (re)shows it.
        local sm = btn.SquareMask
        if sm then
            for _, t in ipairs({ _G.KeyRingButtonIconTexture, nt }) do
                if t and t.RemoveMaskTexture then pcall(t.RemoveMaskTexture, t, sm) end
            end
        end
        local function fadeTex(f)
            if not (f and f.GetRegions) then return end
            for j = 1, select("#", f:GetRegions()) do
                local r = select(j, f:GetRegions())
                if r and r.SetAlpha and r.GetObjectType and r:GetObjectType() == "Texture" then r:SetAlpha(0) end
            end
        end
        local function walkKids(f)
            if not (f and f.GetChildren) then return end
            for i = 1, f:GetNumChildren() do
                local c = select(i, f:GetChildren())
                if c then
                    fadeTex(c)
                    local d = GetFFD(c)
                    if not d.krHook and c.HookScript then
                        d.krHook = true
                        c:HookScript("OnShow", function() fadeTex(c) end)
                    end
                    walkKids(c)
                end
            end
        end
        walkKids(btn)
        if not (icon and icon.GetTexture and icon:GetTexture()) then icon = nt end
    end
    if icon and icon.SetTexCoord then
        icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
    end
    -- Fade the bevel NormalTexture, except when it is serving as the keyring glyph.
    if nt and nt ~= icon then nt:SetAlpha(0) end
    if btn.IconBorder then btn.IconBorder:SetAlpha(0) end
    -- Detach masks so the square crop reads square (normal slots' rounding mask +
    -- any keyring mask), and fade iconframe bevel art.
    for i = 1, select("#", btn:GetRegions()) do
        local r = select(i, btn:GetRegions())
        local isMask = r and r.GetObjectType and r:GetObjectType() == "MaskTexture"
        local atlas = r and r.GetAtlas and r:GetAtlas()
        if isMask then
            if icon and icon.RemoveMaskTexture then pcall(icon.RemoveMaskTexture, icon, r) end
            if nt and nt.RemoveMaskTexture then pcall(nt.RemoveMaskTexture, nt, r) end
        elseif atlas and atlas:lower():find("iconframe", 1, true) then
            r:SetAlpha(0)
        end
    end
    local qr, qg, qb = BagQuality(btn)
    if qr then SetRest(btn, qr, qg, qb)
    else local gr, gg, gb = RestBorder(); SetRest(btn, gr, gg, gb) end
end

local function Skin_BagBar()
    FlattenFrameArt(_G.BagsBar)
    for _, name in ipairs(BAG_BUTTONS) do SkinBag(_G[name]) end
end

local _bagHook = false
WSkin.RegisterWindow({
    key = "bagbar",
    apply = function()
        pcall(Skin_BagBar)
        -- The keyring's NineSlice child frames initialise a beat after login; a few
        -- staggered re-skins catch them without waiting for the first bag update.
        if C_Timer and C_Timer.After then
            for _, delay in ipairs({ 0.3, 1, 2 }) do C_Timer.After(delay, function() pcall(Skin_BagBar) end) end
        end
        if not _bagHook then
            _bagHook = true
            -- Re-skin as bag contents change (quality borders track the equipped bag).
            local repaint = (WSkin.Debounce and WSkin.Debounce(function() pcall(Skin_BagBar) end))
                or function() pcall(Skin_BagBar) end
            local f = CreateFrame("Frame")
            f:RegisterEvent("BAG_UPDATE_DELAYED")
            f:SetScript("OnEvent", repaint)
        end
    end,
})
