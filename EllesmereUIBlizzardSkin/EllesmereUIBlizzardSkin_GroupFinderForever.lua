if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
--------------------------------------------------------------------------------
--  Looking For Group on WoW Forever
--
--  Forever's "Looking For Group" window is the vanilla LFGParentFrame (from the
--  load-on-demand Blizzard_GroupFinder_VanillaStyle addon), NOT retail's
--  PVEFrame -- so EllesmereUIBlizzardSkin_GroupFinder.lua (the retail Group
--  Finder skin) never touches it. This gives that window the standard house
--  treatment under the SAME "LFG Menu" card and key the retail skin uses
--  (winKey "lfg", enable key reskinLFGMenu), so the option applies on both
--  clients and no retail table gains a key. Three swappable views are covered
--  -- the listing/post view, the group browser and the who list -- with their
--  dropdowns, buttons, result rows, side tabs, comment box, row checkboxes and
--  the group-entry tooltip. Nothing here runs on retail (IS_FOREVER is false).
--------------------------------------------------------------------------------
local ADDON_NAME, ns = ...
local EllesmereUI = _G.EllesmereUI
if not (EllesmereUI and EllesmereUI.IS_FOREVER) then return end
local WSkin = ns.WSkin
if not (WSkin and WSkin.RegisterWindow and WSkin.Shell) then return end

-- Per-frame skin state in an external weak-keyed table (never custom keys on
-- Blizzard frame tables), the standard pattern across the window packs.
local FFD = setmetatable({}, { __mode = "k" })
local function GetFFD(frame)
    local d = FFD[frame]
    if not d then d = {}; FFD[frame] = d end
    return d
end

-- Blizzard chrome atlases this window draws (per swappable view), covering the
-- house shell: the ornate metal frame + textured backdrops. Faded recursively.
-- The pack's helpers (LFG_FADE, FadeLFGArt, SkinBrowseFrame, ClampBrowseBottom,
-- SkinLFGTooltip, Skin_LFGVanilla) are wrapped in a do-block to keep them private
-- to this file.
do
local LFG_FADE = {
    "ui-frame-metal", "ui-frame-portraitmetal", "toptilestreaks",
    "groupfinder-background", "groupfinder-stat-stonebg", "common-insideframe",
    "gamepad-uiframemetal", "groupfinder-button-cover",
}
local function FadeLFGArt(fr, depth)
    if depth > 5 or not fr or (fr.IsForbidden and fr:IsForbidden()) then return end
    for i = 1, fr:GetNumRegions() do
        local r = select(i, fr:GetRegions())
        local a = r and r.GetAtlas and r:GetAtlas()
        if a then
            local la = a:lower()
            for _, w in ipairs(LFG_FADE) do
                if la:find(w, 1, true) then r:SetAlpha(0); break end
            end
            -- Role-icon gold ring: fade "roleicon-<role>-background" but keep the
            -- role glyph itself ("roleicon-<role>", no -background).
            if la:find("roleicon", 1, true) and la:find("background", 1, true) then
                -- Darken the gold role ring to a neutral house tone rather than
                -- removing it, so the round role buttons keep a framed look.
                if r.SetVertexColor then r:SetVertexColor(0.32, 0.32, 0.34) else r:SetAlpha(0) end
            end
        end
    end
    for i = 1, fr:GetNumChildren() do FadeLFGArt(select(i, fr:GetChildren()), depth + 1) end
end

-- Group Browser list frame (one pooled Button from LFGBrowseFrameScrollBox). A
-- frame is a collapse HEADER if it carries a "collapseExpand" atlas, else a result
-- ROW. Rows: fade the light "button-list-*" stripe to clean dark rows and recolor
-- the gold -hover/-selected wash to the house accent. Headers: fade the ornate
-- fill, drop a dark house fill behind it, gold the title, and keep the +/- toggles
-- (mirrors the Forever profession window's collapse headers). Role icons + the
-- leader/class/newcomer glyphs are left stock.
local function SkinBrowseFrame(row)
    if not row or (row.IsForbidden and row:IsForbidden()) or not row.GetRegions then return end
    local d = GetFFD(row)
    local ar, ag, ab = WSkin.AccentBarColor()
    local regions = { row:GetRegions() }
    local isHeader = false
    for _, r in ipairs(regions) do
        local a = r.GetAtlas and r:GetAtlas()
        if a and a:lower():find("collapseexpand", 1, true) then isHeader = true break end
    end
    for _, r in ipairs(regions) do
        local ot = r:GetObjectType()
        if ot == "FontString" then
            if WSkin.Font then pcall(WSkin.Font, r) end
            -- Gold header titles (Groups / Players); row text keeps its own color.
            if isHeader and r.SetTextColor then r:SetTextColor(0.95, 0.78, 0.32) end
        elseif ot == "Texture" then
            local a = r.GetAtlas and r:GetAtlas()
            local la = a and a:lower()
            if la then
                if la:find("collapseexpand", 1, true) then
                    if r:GetDrawLayer() == "HIGHLIGHT" then
                        if r.SetVertexColor then r:SetVertexColor(ar, ag, ab) end
                    else
                        r:SetAlpha(0)
                        if not d.hdrFill then
                            local fill = row:CreateTexture(nil, "BACKGROUND")
                            fill:SetColorTexture(0.08, 0.08, 0.08, 0.92)
                            fill:SetPoint("TOPLEFT", r, "TOPLEFT")
                            fill:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT")
                            d.hdrFill = fill
                        end
                    end
                elseif la:find("-hover", 1, true) or la:find("-selected", 1, true) then
                    if r.SetVertexColor then r:SetVertexColor(ar, ag, ab) end
                elseif la:find("button-list-", 1, true)
                    and not la:find("plus", 1, true) and not la:find("minus", 1, true) then
                    r:SetAlpha(0)
                end
            end
        end
    end
end

-- Raise the browse ScrollBox's bottom anchor up to the list's bottom divider line
-- (the lower groupfinder-ScrollLine) so the last partial row clips above it instead
-- of overhanging toward the footer. Blizzard anchors the box ~24px too low; the
-- exact overhang is measured once (when the list is laid out) and the raised BOTTOM
-- point stored, then re-asserted on every ScrollBox Update (idempotent -- same values
-- -> no size change, no loop) so a Blizzard relayout can't undo it.
local function ClampBrowseBottom(sb)
    local sd = GetFFD(sb)
    if not sd.clampPt then
        local bf = _G.LFGBrowseFrame
        if not bf then return end
        local line
        for i = 1, bf:GetNumRegions() do
            local r = select(i, bf:GetRegions())
            local a = r.GetAtlas and r:GetAtlas()
            if a and a:lower():find("scrollline", 1, true)
               and (not line or (r:GetTop() or 0) < (line:GetTop() or 0)) then line = r end
        end
        local target = line and line:GetTop()
        local cur = sb:GetBottom()
        if not (target and cur and (target - cur) > 1) then return end
        for i = 1, sb:GetNumPoints() do
            local p, rel, rp, x, y = sb:GetPoint(i)
            if p and p:find("BOTTOM", 1, true) and y then
                sd.clampPt = { p, rel, rp, x, y + (target - cur) }
                break
            end
        end
    end
    local c = sd.clampPt
    if c then sb:SetPoint(c[1], c[2], c[3], c[4], c[5]) end
end

-- The Group Browser's search-entry tooltip (LFGBrowseSearchEntryTooltip -- a LoD
-- Frame from Blizzard_GroupFinder_VanillaStyle, NOT GameTooltip) is never reached by
-- EllesmereUI's tooltip skin, so it keeps Blizzard's ornate red NineSlice border.
-- Give it the same house look the tooltip skin applies: hide the NineSlice, drop the
-- shared GetTooltipBg fill, and apply the user's configured house tooltip border via
-- the public helper -- honoring the customTooltips toggle. Re-applied on every show
-- (Blizzard re-shows the NineSlice) and the roster/comment lines get the house font.
local function SkinLFGTooltip()
    local t = _G.LFGBrowseSearchEntryTooltip
    if not t or (t.IsForbidden and t:IsForbidden()) then return end
    if EllesmereUIDB and EllesmereUIDB.customTooltips == false then return end
    if t.NineSlice then t.NineSlice:SetAlpha(0) end
    local d = GetFFD(t)
    if not d.ttBg then
        d.ttBg = t:CreateTexture(nil, "BACKGROUND", nil, -8)
        d.ttBg:SetAllPoints()
    end
    if EllesmereUI.GetTooltipBg then d.ttBg:SetColorTexture(EllesmereUI.GetTooltipBg()) end
    d.ttBg:Show()
    if EllesmereUI._applyBlizzardConfiguredBorder then
        local ls
        if EllesmereUI.GetTooltipBorder then ls = select(5, EllesmereUI.GetTooltipBorder()) end
        EllesmereUI._applyBlizzardConfiguredBorder(t, "tooltip", ls)
    end
    local function Font(fr, depth)
        if depth > 4 or not fr then return end
        if fr.GetNumRegions then
            for i = 1, fr:GetNumRegions() do
                local r = select(i, fr:GetRegions())
                if r:GetObjectType() == "FontString" and WSkin.Font then pcall(WSkin.Font, r) end
            end
        end
        for i = 1, fr:GetNumChildren() do Font(select(i, fr:GetChildren()), depth + 1) end
    end
    Font(t, 0)
end

-- Dungeon-row checkboxes live pooled inside LFGListingFrameActivityViewScrollBox
-- (each a 30x29 CheckButton in a wide row frame). Recursively find CheckButtons in
-- whatever the ScrollBox yields and give them the house look with borderInset=4 so
-- the border hugs the inset dark fill instead of sitting proud of it (WSkin.Checkbox
-- guards per-frame, so re-running on scroll is a no-op for already-skinned boxes).
local function SkinRowChecks(fr, depth)
    -- ScrollBox:ForEachFrame calls this as (frame, elementData) -- ignore that 2nd
    -- arg (a table) and only honor a numeric recursion depth.
    depth = type(depth) == "number" and depth or 0
    if not fr or depth > 6 or (fr.IsForbidden and fr:IsForbidden()) then return end
    if fr.IsObjectType and fr:IsObjectType("CheckButton") and WSkin.Checkbox then
        local cd = GetFFD(fr)
        WSkin.Checkbox(fr, { borderInset = 4 })
        -- WSkin.Checkbox clears the Highlight texture; restore a subtle house hover
        -- (inset to match the dark box) so mouse-over feedback survives.
        if not cd.hlRestored then
            cd.hlRestored = true
            fr:SetHighlightTexture("Interface\\Buttons\\WHITE8x8")
            local hl = fr:GetHighlightTexture()
            if hl then
                hl:SetVertexColor(1, 1, 1, 0.18)
                hl:ClearAllPoints()
                hl:SetPoint("TOPLEFT", 4, -4)
                hl:SetPoint("BOTTOMRIGHT", -4, 4)
            end
        end
    end
    for i = 1, fr:GetNumChildren() do SkinRowChecks(select(i, fr:GetChildren()), depth + 1) end
end

local function Skin_LFGVanilla()
    local f = _G.LFGParentFrame
    if not f then return end
    WSkin.Shell("lfg", f)
    WSkin.RemovePortrait(f)
    WSkin.CommonChrome(f, "LFGParentFrame")
    -- Fade Blizzard's ornate metal frame + textured backdrops across every view,
    -- revealing the house shell (modern backdrop + AdventureMap border) on the parent.
    FadeLFGArt(f, 0)
    -- Each view also carries a plain grey BACKGROUND color-fill (no atlas, so the
    -- fade above misses it) that sits over the shell -- clear it on the views.
    for _, vn in ipairs({ "LFGListingFrame", "LFGBrowseFrame", "LFGWhoListFrame",
        "LFGListingFrameCategoryView", "LFGListingFrameActivityView", "LFGListingFrameLockedView" }) do
        local v = _G[vn]
        if v and v.GetNumRegions then
            for i = 1, v:GetNumRegions() do
                local r = select(i, v:GetRegions())
                if r and r:GetObjectType() == "Texture" and not (r.GetAtlas and r:GetAtlas())
                   and r:GetDrawLayer() == "BACKGROUND" then
                    r:SetAlpha(0)
                end
            end
        end
    end
    local title = (f.TitleContainer and f.TitleContainer.TitleText) or _G.LFGParentFrameTitleText
    if title then WSkin.Font(title); WSkin.White(title) end
    -- Controls: flat buttons + house dropdowns + themed scroll bars.
    local function SkinBtn(name)
        local b = _G[name]
        if b then WSkin.Button(b); if WSkin.WhiteButtonLabel then WSkin.WhiteButtonLabel(b) end end
    end
    local function SkinDD(name) local d = _G[name]; if d then WSkin.Dropdown(d) end end
    SkinDD("LFGBrowseFrameCategoryDropdown")
    SkinDD("LFGBrowseFrameActivityDropdown")
    SkinBtn("LFGBrowseFrameRefreshButton")
    SkinBtn("LFGBrowseFrameOptionsButton")
    SkinBtn("LFGBrowseFrameSendMessageButton")
    SkinBtn("LFGBrowseFrameGroupInviteButton")
    SkinBtn("LFGListingFrameBackButton")
    SkinBtn("LFGListingFramePostButton")
    if _G.WhoFrameEditBox then WSkin.EditBox(_G.WhoFrameEditBox) end
    if _G.LFGBrowseFrameScrollBar then WSkin.ScrollBar(_G.LFGBrowseFrameScrollBar) end
    -- Catch remaining parent-key dropdowns/edit boxes per view (depth 0 skips the
    -- foreign-frame guard that stopped the recursive pass on the parent).
    for _, vn in ipairs({ "LFGBrowseFrame", "LFGListingFrame", "LFGWhoListFrame" }) do
        local v = _G[vn]
        if v and WSkin.ControlsIn then WSkin.ControlsIn(v) end
    end
    -- 1px house border that HUGS a button's content (its .Icon, or its largest
    -- visible art texture) instead of the padded frame edge, so it sits tight.
    local function BorderContent(btn)
        if not btn then return end
        local d = GetFFD(btn)
        if d.contentBorder then return end
        local anchor = btn.Icon
        if not anchor then
            local best, bestArea
            for i = 1, btn:GetNumRegions() do
                local r = select(i, btn:GetRegions())
                if r:GetObjectType() == "Texture" and r:IsShown() and (r:GetAlpha() or 0) > 0.1 then
                    local atl = r.GetAtlas and r:GetAtlas()
                    if not (atl and atl:lower():find("background", 1, true)) then
                        local area = (r:GetWidth() or 0) * (r:GetHeight() or 0)
                        if area > 0 and (not bestArea or area > bestArea) then best, bestArea = r, area end
                    end
                end
            end
            anchor = best
        end
        anchor = anchor or btn
        local host = CreateFrame("Frame", nil, btn)
        host:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
        host:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        if WSkin.AddBorder then WSkin.AddBorder(host) end
        d.contentBorder = host
    end
    -- Right-side view tabs (Listing / Browsing / WhoListing): fade the gold tab
    -- frame + glow, keep the icon, and clamp a thin dark border to the round icon.
    for _, tn in ipairs({ "ListingTab", "BrowsingTab", "WhoListingTab" }) do
        local tab = f[tn]
        if tab then
            if tab.Background and tab.Background.SetAlpha then tab.Background:SetAlpha(0) end
            if tab.TabGlow and tab.TabGlow.SetAlpha then tab.TabGlow:SetAlpha(0) end
            local d = GetFFD(tab)
            if not d.tabBorder and tab.SelectedTexture then
                -- Inactive state: a constant, always-present copy of the HOVER frame
                -- element (common-sidetab-hover -- the thick, good-looking one),
                -- colored BLACK. The selected-frame copy was a too-thin hairline;
                -- the hover art is the visible weight we want. Real hover (gold) and
                -- active (soft-white) draw over it, giving three clean states.
                local b = tab:CreateTexture(nil, "OVERLAY", nil, -1)
                b:SetAtlas("common-sidetab-hover")
                b:SetAllPoints(tab.SelectedTexture)
                b:SetVertexColor(0, 0, 0)
                d.tabBorder = b
            end
            -- Active tab: recolor the real selected border to a soft white.
            if tab.SelectedTexture and tab.SelectedTexture.SetVertexColor then
                tab.SelectedTexture:SetVertexColor(0.90, 0.90, 0.92)
            end
        end
    end
    -- "More details" comment box (List Self view): a multi-line EditBox inside the
    -- LFGListingComment ScrollFrame whose border is 9 file-texture BACKGROUND pieces
    -- (no NineSlice/backdrop) -- WSkin.EditBox on the inner EditBox mangled it, so
    -- skin the WRAPPER instead: fade Blizzard's border/bg textures, drop a house dark
    -- fill + border. The inner EditBox is left alone (font handled by ApplyFont).
    local cmt = _G.LFGListingComment
    if cmt then
        local cd = GetFFD(cmt)
        for i = 1, cmt:GetNumRegions() do
            local r = select(i, cmt:GetRegions())
            if r:GetObjectType() == "Texture" and r:GetDrawLayer() == "BACKGROUND"
               and r ~= cd.commentFill then
                r:SetAlpha(0)
            end
        end
        if not cd.commentFill then
            cd.commentFill = cmt:CreateTexture(nil, "BACKGROUND", nil, -8)
            cd.commentFill:SetColorTexture(0.08, 0.08, 0.08, 0.92)
            cd.commentFill:SetAllPoints(cmt)
            if WSkin.AddBorder then WSkin.AddBorder(cmt) end
        end
    end
    -- Checkboxes in the List Self view: the role selectors, "Show All Level Ranges",
    -- and the dungeon rows. Recursively skin all of them now (dark fill + accent tick
    -- + tight border + restored house hover); the dungeon-row checks are pooled in the
    -- ActivityView ScrollBox, so also hook its Update so re-skin survives scrolling.
    if _G.LFGListingFrame then SkinRowChecks(_G.LFGListingFrame) end
    local asb = _G.LFGListingFrameActivityViewScrollBox
    if asb and asb.ForEachFrame then
        local ad = GetFFD(asb)
        if not ad.checksHooked and asb.Update then
            ad.checksHooked = true
            hooksecurefunc(asb, "Update", function() asb:ForEachFrame(SkinRowChecks) end)
        end
    end
    -- Category tiles: border the tile art tight (wide buttons only).
    local function BorderTiles(fr, depth)
        if depth > 5 or not fr or (fr.IsForbidden and fr:IsForbidden()) then return end
        if fr:GetObjectType() == "Button" and (fr:GetWidth() or 0) >= 100 then BorderContent(fr) end
        for i = 1, fr:GetNumChildren() do BorderTiles(select(i, fr:GetChildren()), depth + 1) end
    end
    BorderTiles(_G.LFGListingFrameCategoryView, 0)
    -- House font on every FontString across the window. Checkboxes + the comment
    -- edit box are left stock (non-standard frames the house control skins break).
    local function ApplyFont(fr, depth)
        if depth > 9 or not fr or (fr.IsForbidden and fr:IsForbidden()) then return end
        if fr.GetNumRegions then
            for i = 1, fr:GetNumRegions() do
                local r = select(i, fr:GetRegions())
                if r:GetObjectType() == "FontString" and WSkin.Font then pcall(WSkin.Font, r) end
            end
        end
        for i = 1, fr:GetNumChildren() do ApplyFont(select(i, fr:GetChildren()), depth + 1) end
    end
    ApplyFont(f, 0)
    -- Group Browser result list: rows + Groups/Players collapse headers are pooled
    -- Buttons in a modern WowScrollBox. Skin the currently-visible frames now, and
    -- hook the ScrollBox's Update once so re-skin survives scrolling (the pool reuses
    -- ~15 frame objects, so per-frame textures/state stay bounded via GetFFD).
    local sb = _G.LFGBrowseFrameScrollBox
    if sb and sb.ForEachFrame then
        -- Clip the viewport so the last partial row can't bleed below the list's
        -- bottom divider into the footer (Send Message / Group Invite).
        if sb.SetClipsChildren then sb:SetClipsChildren(true) end
        ClampBrowseBottom(sb)
        sb:ForEachFrame(SkinBrowseFrame)
        local sd = GetFFD(sb)
        if not sd.browseHooked and sb.Update then
            sd.browseHooked = true
            hooksecurefunc(sb, "Update", function()
                ClampBrowseBottom(sb)
                sb:ForEachFrame(SkinBrowseFrame)
            end)
        end
    end
    -- Group-entry tooltip (LFGBrowseSearchEntryTooltip): give it the house tooltip
    -- look instead of Blizzard's ornate red border. Skin now + hook its show once.
    local tip = _G.LFGBrowseSearchEntryTooltip
    if tip then
        SkinLFGTooltip()
        local td = GetFFD(tip)
        if not td.lfgTipHooked then
            td.lfgTipHooked = true
            tip:HookScript("OnShow", SkinLFGTooltip)
        end
    end
    -- Re-run (debounced) on the window's show AND each view's show so view content
    -- (role rings, list rows) gets re-skinned when swapped in.
    local d = GetFFD(f)
    if not d.lfgHooked then
        d.lfgHooked = true
        local repaint = WSkin.Debounce(function()
            if f:IsVisible() then Skin_LFGVanilla() end
        end)
        WSkin.HookShow(f, repaint)
        for _, vn in ipairs({ "LFGListingFrame", "LFGBrowseFrame", "LFGWhoListFrame",
            "LFGListingFrameCategoryView", "LFGListingFrameActivityView" }) do
            local v = _G[vn]
            if v then WSkin.HookShow(v, repaint) end
        end
    end
end

WSkin.RegisterWindow({
    key = "lfg",
    apply = Skin_LFGVanilla,
    addons = { Blizzard_GroupFinder_VanillaStyle = true },
})
end  -- LFG pack do-block