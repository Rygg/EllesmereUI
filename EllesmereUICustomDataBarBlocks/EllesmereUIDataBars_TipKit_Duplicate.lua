if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
-- Verbatim duplicate of EllesmereUIDataBars/EllesmereUIDataBars.lua's "owned rich
-- tooltip" system and its ns.SetFont/ns.GetAccent dependencies, kept aligned for
-- later upstream PR reconciliation.
-- Everything between the BEGIN/END UPSTREAM DUPLICATE markers below is an exact
-- copy except for the clearly marked NEW CODE extension inside the do-block.
local ADDON_NAME, ns = ...

-- =====================================================================
-- BEGIN UPSTREAM DUPLICATE (EllesmereUIDataBars.lua) -- do not edit
-- =====================================================================

-- Upvalues (mirrors the subset of EllesmereUIDataBars.lua's upvalue block this code needs)
local CreateFrame      = CreateFrame
local UIParent         = UIParent
local InCombatLockdown = InCombatLockdown
local C_Timer          = C_Timer
local wipe             = wipe
local floor            = math.floor
local max              = math.max

local PP = EllesmereUI.PP

-------------------------------------------------------------------------------
--  Fonts (duplicated from EllesmereUIDataBars.lua's "Fonts" section)
-------------------------------------------------------------------------------
function ns.SetFont(fs, size, barCfg)
    if not (fs and fs.SetFont) then return end
    local path  = EllesmereUI.GetFontPath("dataBars")
    local flags = EllesmereUI.GetFontOutlineFlag()
    local scale = 100
    if barCfg and barCfg.fontScale then scale = barCfg.fontScale end
    local sz = max(6, floor((size or 11) * scale / 100 + 0.5))
    -- SetShadowOffset does not render on 12.x; shadows must ride a FontObject.
    -- Prime BEFORE SetFont -- the inherited shadow survives the typeface call.
    if EllesmereUI.PrimeFontShadow then
        local useShadow = flags == "" and EllesmereUI.GetFontUseShadow()
        EllesmereUI.PrimeFontShadow(fs, useShadow and true or false)
    end
    fs:SetFont(path, sz, flags)
end

function ns.GetAccent()
    if EllesmereUI.GetAccentColor then
        return EllesmereUI.GetAccentColor()
    end
    local theme = EllesmereUI.ELLESMERE_GREEN
    if theme then return theme.r, theme.g, theme.b end
    return 0.047, 0.824, 0.616
end

-------------------------------------------------------------------------------
--  Owned rich tooltip (single frame, pooled FontStrings, two columns)
--  Replaces every GameTooltip call site.
-------------------------------------------------------------------------------
do
    local tip
    local owner
    local rows = {}       -- rows[i] = { left = fs, right = fs, cols = { fs, ... } }
    local data = {}       -- data[i] = { l, r, lr, lg, lb, rr, rg, rb }
    local dataCount = 0
    local colW = {}       -- per-Tip_Show widest token per sub-column
    local PAD = 10
    local ROW_GAP = 3
    local COL_GAP = 18
    local TOKEN_GAP = 8
    local FONT_SIZE = 12
    -- TOOLTIP strata orders purely by frame level, and a frame created straight
    -- under UIParent starts at the bottom of it -- so a plain level let other
    -- tooltips (e.g. a unit tooltip through a bar block) draw over this one.
    -- Sit far above Blizzard's tooltips; overlay hosts stack on top (Tip_Show).
    local TIP_LEVEL = 900

    -- Interactive rows: secure spell buttons overlaid on action rows
    -- (Tip_AddActionDouble). SecureActionButtonTemplate, type="spell" fed a
    -- STATIC INTEGER spellID, attributes written OOC only (same contract as
    -- the QoL teleport prompt). Buttons live on a secure host under UIParent
    -- whose visibility driver yanks them the instant lockdown starts (covers
    -- a tip left open across a pull); the tip keeps no protected children, so
    -- Tip_Hide stays combat-legal. Keep-alive poll lets the cursor travel off
    -- the owner onto the tip to click a row without it closing.
    local actionPool = {}
    local activeActions = 0
    local actionHost           -- secure container, built with the first button
    local actionsDirty = false -- a teardown landed in combat; regen finishes it
    local interactive = false
    -- Caller-forced interactive mode (Tip_MarkInteractive): hover-persistent
    -- even when the shown tip has zero clickable rows. Reset per Tip_Begin.
    local forceInteractive = false
    local keepAlive

    -- Plain clickable rows: an insecure Button overlay running a Lua callback
    -- on click (Tip_AddClickable). Used by social/guild member lists, whose
    -- actions (whisper, invite, BNet whisper) are all UNPROTECTED -- unlike
    -- the spell pool above, no secure host or combat handling needed; free
    -- to create/configure in or out of combat.
    local clickPool = {}
    local activeClicks = 0

    local function EnsureTip()
        if tip then return tip end
        tip = CreateFrame("Frame", "EllesmereUIDataBarsTip", UIParent)
        tip:SetFrameStrata("TOOLTIP")
        tip:SetFrameLevel(TIP_LEVEL)
        tip:SetClampedToScreen(true)
        tip:Hide()
        local bg = tip:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0.067, 0.067, 0.067, 0.97)
        if PP and PP.CreateBorder then
            PP.CreateBorder(tip, 0, 0, 0, 0.9, 1, "OVERLAY", 7)
        end
        return tip
    end

    local function EnsureRow(i)
        local row = rows[i]
        if not row then
            row = {}
            row.left = tip:CreateFontString(nil, "OVERLAY")
            row.right = tip:CreateFontString(nil, "OVERLAY")
            row.cols = {}
            rows[i] = row
        end
        return row
    end

    local function EnsureCol(row, c)
        local fs = row.cols[c]
        if not fs then
            fs = tip:CreateFontString(nil, "OVERLAY")
            row.cols[c] = fs
        end
        return fs
    end

    -- Pooled rows: a row reused with fewer/no sub-columns must not leave
    -- the previous show's token FontStrings on screen.
    local function HideCols(row, from)
        for c = from, #row.cols do row.cols[c]:Hide() end
    end

    -- Hide/detach every overlay button. PROTECTED (SecureActionButtonTemplate),
    -- so OOC-only: a mid-combat teardown sets the dirty flag and the host's
    -- regen handler finishes it (state driver already pulled the host off
    -- screen, so nothing stays clickable meanwhile).
    local function HideActionButtons()
        if activeActions == 0 and not actionsDirty then return end
        if InCombatLockdown() then actionsDirty = true; return end
        actionsDirty = false
        for i = 1, #actionPool do
            local b = actionPool[i]
            b:Hide()
            b:ClearAllPoints()
            b:SetScript("OnEnter", nil)
            b:SetScript("OnLeave", nil)
        end
        activeActions = 0
    end

    local function EnsureActionHost()
        if actionHost then return actionHost end
        actionHost = CreateFrame("Frame", "EllesmereUIDataBarsTipActions", UIParent, "SecureHandlerStateTemplate")
        actionHost:SetFrameStrata("TOOLTIP")
        actionHost:SetFrameLevel(TIP_LEVEL + 10)
        actionHost:SetAllPoints(tip)
        -- No clickable overlays in combat, ever: the driver hides the host
        -- securely the instant lockdown starts and re-shows it on regen for
        -- the next out-of-combat tip.
        RegisterStateDriver(actionHost, "visibility", "[combat] hide; show")
        local regen = CreateFrame("Frame")
        regen:RegisterEvent("PLAYER_REGEN_ENABLED")
        regen:RegisterEvent("PLAYER_REGEN_DISABLED")
        regen:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_ENABLED" then
                if actionsDirty then HideActionButtons() end
                return
            end
            -- REGEN_DISABLED: InCombatLockdown() reports true already, but
            -- protected-frame writes are still legal until this handler returns. A
            -- protected frame left anchored would block tip:SetSize() all fight, firing
            -- ADDON_ACTION_BLOCKED on any plain tooltip hover. Sever the anchor now;
            -- next OOC Tip_Show re-attaches the host.
            actionsDirty = false
            for i = 1, #actionPool do
                local b = actionPool[i]
                b:Hide()
                b:ClearAllPoints()
                b:SetScript("OnEnter", nil)
                b:SetScript("OnLeave", nil)
            end
            activeActions = 0
            actionHost:ClearAllPoints()
        end)
        return actionHost
    end

    -- Grow-only pool; buttons configured fresh each Tip_Show. Creation/
    -- reconfiguration only run OOC (overlay build is combat-skipped), so
    -- secure attribute writes are always legal. House style: white 0.10
    -- wash on hover, HIGHLIGHT layer, no scripts -- shared by both overlay
    -- pools so the two clickable-row kinds always look identical.
    local function AddRowHighlight(b)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.10)
    end

    local function AcquireActionButton()
        activeActions = activeActions + 1
        local b = actionPool[activeActions]
        if not b then
            b = CreateFrame("Button", nil, EnsureActionHost(), "SecureActionButtonTemplate")
            b:SetFrameLevel(TIP_LEVEL + 10)
            b:EnableMouse(true)
            -- AnyUp only + useOnKeyDown=false: registering both click phases lets
            -- ActionButtonUseKeyDown fire the cast twice, and the second press
            -- cancels the cast the first started (same rule as the travel
            -- block's hearth button).
            b:RegisterForClicks("AnyUp")
            b:SetAttribute("useOnKeyDown", false)
            AddRowHighlight(b)
            -- Default type; the overlay build swaps type/payload per row
            -- (spell rows and toy rows share this pool).
            b:SetAttribute("type", "spell")
            -- Static handler, installed once; pooled reuse only swaps the
            -- action attributes and the hover recolor scripts.
            b:HookScript("PostClick", function() ns.Tip_Hide() end)
            actionPool[activeActions] = b
        end
        return b
    end

    -- Insecure clickable pool (social/guild rows): callbacks call unprotected
    -- functions only, so no secure host or combat handling needed -- buttons
    -- build/click in any lockdown state.
    local function HideClickButtons()
        if activeClicks == 0 then return end
        for i = 1, #clickPool do
            local b = clickPool[i]
            b:Hide()
            b:ClearAllPoints()
            b:SetScript("OnClick", nil)
            b:SetScript("OnEnter", nil)
            b:SetScript("OnLeave", nil)
        end
        activeClicks = 0
    end

    -- Grow-only pool; buttons parent to the tip (riding its strata/clamping)
    -- and sit above its FontStrings so the overlay wins hit testing.
    local function AcquireClickButton()
        activeClicks = activeClicks + 1
        local b = clickPool[activeClicks]
        if not b then
            b = CreateFrame("Button", nil, EnsureTip())
            b:SetFrameLevel(tip:GetFrameLevel() + 5)
            b:EnableMouse(true)
            b:RegisterForClicks("AnyUp")
            AddRowHighlight(b)
            clickPool[activeClicks] = b
        end
        return b
    end

    -- Lay an overlay button over row i and wire its hover affordance. Shared by
    -- both secure action rows and insecure clickable ones -- to the player
    -- they're the same thing, an interactive tooltip row. The accent recolor
    -- only shows if the row's left text carries no embedded |c..|r codes.
    local function PlaceRowOverlay(b, i, innerW)
        local d, row = data[i], rows[i]
        -- Re-stated per placement, not just at creation: the tip's level can
        -- rise on any Tip_Show, and a pooled button keeping the old base
        -- would sink under the background. Never lowered.
        local want = tip:GetFrameLevel() + 5
        if b:GetFrameLevel() < want then b:SetFrameLevel(want) end
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", tip, "TOPLEFT", PAD, d._y)
        b:SetSize(max(1, innerW), max(1, d._h))
        local ar, ag, ab = ns.GetAccent()
        local lr, lg, lb = d.lr or 1, d.lg or 1, d.lb or 1
        b:SetScript("OnEnter", function() row.left:SetTextColor(ar, ag, ab, 1) end)
        b:SetScript("OnLeave", function() row.left:SetTextColor(lr, lg, lb, 1) end)
        b:Show()
    end

    local function StopKeepAlive()
        if keepAlive then keepAlive:Cancel(); keepAlive = nil end
    end

    -- Dismiss once the cursor is over neither owner nor tip. IsMouseOver tests
    -- rectangles (ignores overlay buttons), so a clickable row still counts as
    -- "over the tip". Both rects test EXPANDED (the tip sits a 6px gap off the
    -- bar; unexpanded would drop the tip crossing that dead zone). Two-tick
    -- grace (~0.2s) covers slow diagonal exits past a corner.
    local KA_SLACK = 12
    local function StartKeepAlive()
        if keepAlive then return end
        local missed = 0
        keepAlive = C_Timer.NewTicker(0.1, function()
            if not (tip and tip:IsShown()) then StopKeepAlive(); return end
            local overOwner = owner and owner.IsMouseOver
                and owner:IsMouseOver(KA_SLACK, -KA_SLACK, -KA_SLACK, KA_SLACK)
            local overTip = tip:IsMouseOver(KA_SLACK, -KA_SLACK, -KA_SLACK, KA_SLACK)
            if overOwner or overTip then
                missed = 0
            else
                missed = missed + 1
                if missed >= 2 then ns.Tip_Hide() end
            end
        end)
    end

    function ns.Tip_Begin(ownerFrame)
        EnsureTip()
        owner = ownerFrame
        dataCount = 0
        forceInteractive = false
    end

    -- Secret text must never enter a row: SetText would display it, and
    -- Tip_Show sizes via GetStringWidth, which errors on a SECRET-fed
    -- FontString. Rows carrying a secret are dropped here, so the tooltip
    -- shortens instead of erroring. Add functions return true when added.
    function ns.Tip_AddLine(text, r, g, b)
        if not tip then return end
        if text ~= nil and issecretvalue(text) then return end
        -- Fixed UI strings resolve through the shared locale; dynamic content
        -- (names, numbers, already-localized strings) has no key, falls back unchanged.
        text = EllesmereUI.L(text)
        dataCount = dataCount + 1
        local d = data[dataCount]
        if not d then d = {}; data[dataCount] = d end
        d.l = text or " "
        d.lr = r; d.lg = g; d.lb = b
        d.r = nil
        d.wrap = nil
        d.action = nil
        d.actionToy = nil
        d.actionMacro = nil
        d._padBand = nil
        d.onClick = nil
        d.ncols = nil
        return true
    end

    -- Long prose (currency descriptions etc.): word-wraps at maxWidth px
    -- instead of blowing the tooltip out to the widest single line.
    function ns.Tip_AddWrappedLine(text, maxWidth, r, g, b)
        if not tip then return end
        if ns.Tip_AddLine(text, r, g, b) then
            data[dataCount].wrap = maxWidth or 280
        end
    end

    function ns.Tip_AddDouble(left, right, lr, lg, lb, rr, rg, rb)
        if not tip then return end
        if (left ~= nil and issecretvalue(left))
        or (right ~= nil and issecretvalue(right)) then return end
        left = EllesmereUI.L(left); right = EllesmereUI.L(right)   -- see Tip_AddLine
        dataCount = dataCount + 1
        local d = data[dataCount]
        if not d then d = {}; data[dataCount] = d end
        d.l = left or " "
        d.lr = lr; d.lg = lg; d.lb = lb
        d.r = right or ""
        d.rr = rr; d.rg = rg; d.rb = rb
        d.wrap = nil
        d.action = nil
        d.actionToy = nil
        d.actionMacro = nil
        d._padBand = nil
        d.onClick = nil
        d.ncols = nil
        return true
    end

    -- Like Tip_AddDouble, but the right side is tokens in pixel-aligned
    -- sub-columns instead of one right-aligned string -- a single string can't
    -- line up vertically since the proportional font makes "+10" and "0/4"
    -- different widths. Tokens carry their own inline color codes; the array
    -- is copied, so callers may reuse one buffer for every row.
    function ns.Tip_AddColumns(left, tokens, lr, lg, lb)
        if not tip then return end
        if left ~= nil and issecretvalue(left) then return end
        local n = (tokens and #tokens) or 0
        for i = 1, n do
            if issecretvalue(tokens[i]) then return end
        end
        dataCount = dataCount + 1
        local d = data[dataCount]
        if not d then d = {}; data[dataCount] = d end
        d.l = left or " "
        d.lr = lr; d.lg = lg; d.lb = lb
        d.r = nil
        d.wrap = nil
        d.action = nil
        d.actionToy = nil
        d.actionMacro = nil
        d._padBand = nil
        d.onClick = nil
        -- nil, never 0: Tip_Show tests `if d.ncols`, and 0 is true in Lua, so a
        -- token-less row would reserve the right column and pad the tip by
        -- COL_GAP for content that never renders.
        d.ncols = n > 0 and n or nil
        if n > 0 then
            local c = d.cols
            if not c then c = {}; d.cols = c end
            for i = 1, n do c[i] = tokens[i] end
        end
        return true
    end
    
    -- Click-to-cast row: like Tip_AddDouble, but Tip_Show overlays a secure
    -- spell button and keeps the tip alive while hovered. spellID MUST be a
    -- static integer (never API-derived or secret-capable -- same contract as
    -- the QoL teleport prompt). Degrades to a plain double line in combat.
    function ns.Tip_AddActionDouble(left, right, spellID, lr, lg, lb, rr, rg, rb)
        if ns.Tip_AddDouble(left, right, lr, lg, lb, rr, rg, rb) and spellID then
            data[dataCount].action = spellID
        end
    end

    -- Click-to-use TOY row: same overlay/keep-alive/combat-degrade contract as
    -- Tip_AddActionDouble, but fires type="toy" with a STATIC integer toy
    -- itemID (toy effects aren't reliably castable via the spell attribute).
    function ns.Tip_AddToyActionDouble(left, right, toyItemID, lr, lg, lb, rr, rg, rb)
        if ns.Tip_AddDouble(left, right, lr, lg, lb, rr, rg, rb) and toyItemID then
            data[dataCount].actionToy = toyItemID
        end
    end

    -- Click-to-run MACRO row: same overlay/degrade contract. macrotext MUST be built
    -- from static ids only (e.g. "/use item:NNNN") -- never API-derived strings.
    function ns.Tip_AddMacroActionDouble(left, right, macrotext, lr, lg, lb, rr, rg, rb)
        if ns.Tip_AddDouble(left, right, lr, lg, lb, rr, rg, rb) and macrotext then
            data[dataCount].actionMacro = macrotext
        end
    end

    -- Mark the row just added to carry the clickable-row padding band even
    -- without an action, so a row's spacing stays stable across its
    -- clickable/plain states (e.g. the travel hearthstone line on cooldown).
    function ns.Tip_PadRow()
        if tip and dataCount > 0 then data[dataCount]._padBand = true end
    end

    -- Click-to-act row: like Tip_AddDouble, but overlays an insecure button
    -- running onClick(mouseButton) and keeps the tip alive while hovered.
    -- onClick MUST call unprotected functions only (whisper/invite). Unlike
    -- Tip_AddActionDouble, this stays live in combat.
    function ns.Tip_AddClickable(left, right, onClick, lr, lg, lb, rr, rg, rb)
        if ns.Tip_AddDouble(left, right, lr, lg, lb, rr, rg, rb) and onClick then
            data[dataCount].onClick = onClick
        end
    end

    -- Tip_AddColumns + Tip_AddClickable: sub-column alignment AND a click
    -- overlay -- combinable since the overlay only covers the row's rect and
    -- never cares how the row was laid out.
    function ns.Tip_AddClickableColumns(left, tokens, onClick, lr, lg, lb)
        if ns.Tip_AddColumns(left, tokens, lr, lg, lb) and onClick then
            data[dataCount].onClick = onClick
        end
    end

    function ns.Tip_Show()
        if not tip or not owner then return end
        -- Re-check the level contest on every show: GameTooltip's level is not constant
        -- (Blizzard raises it, addons reparent/restack it), so a level picked once at
        -- creation could be overtaken. Only ever raises -- TIP_LEVEL is the floor.
        do
            local lvl = TIP_LEVEL
            local gt = GameTooltip and GameTooltip.GetFrameLevel and GameTooltip:GetFrameLevel()
            if gt and gt >= lvl then lvl = gt + 10 end
            if tip:GetFrameLevel() < lvl then tip:SetFrameLevel(lvl) end
        end
        local maxLeft, maxRight, totalH = 0, 0, 0
        local anyRight = false
        local colCount = 0
        -- Wrapped rows (prose: currency descriptions) are measured but NOT laid
        -- out here -- they own the whole inner width, but that width is only
        -- known once rows WITH a right column are measured. Sizing against
        -- their own wrap cap here instead would leave a dead gutter beside
        -- the prose as wide as the widest right value.
        local maxWrap, anyWrap = 0, false
        wipe(colW)
        for i = 1, dataCount do
            local d = data[i]
            local row = EnsureRow(i)
            ns.SetFont(row.left, FONT_SIZE)
            -- The right FS needs a font even on left-only rows: SetText("") on a
            -- never-fonted FontString hard-errors, and a pooled row's first use
            -- can be a plain line.
            ns.SetFont(row.right, FONT_SIZE)
            -- Rows are pooled: reset wrap state every pass so a wrapped row
            -- reused as plain measures naturally. Wrapped rows measure
            -- UNWRAPPED here so GetStringWidth reports the natural one-line
            -- width, which the wrap cap is applied to.
            row.left:SetWordWrap(false)
            row.left:SetWidth(0)
            row.left:SetText(d.l)
            row.left:SetTextColor(d.lr or 1, d.lg or 1, d.lb or 1, 1)
            row.left:Show()
            local lw = row.left:GetStringWidth() or 0
            if d.wrap then
                anyWrap = true
                if lw > d.wrap then lw = d.wrap end
                if lw > maxWrap then maxWrap = lw end
            elseif lw > maxLeft then
                maxLeft = lw
            end
            if d.r then
                anyRight = true
                row.right:SetText(d.r)
                row.right:SetTextColor(d.rr or 1, d.rg or 1, d.rb or 1, 1)
                row.right:Show()
                local rw = row.right:GetStringWidth() or 0
                if rw > maxRight then maxRight = rw end
            else
                row.right:SetText("")
                row.right:Hide()
            end
            local colH = 0
            if d.ncols then
                anyRight = true
                if d.ncols > colCount then colCount = d.ncols end
                for c = 1, d.ncols do
                    local fs = EnsureCol(row, c)
                    ns.SetFont(fs, FONT_SIZE)
                    fs:SetWordWrap(false)
                    fs:SetWidth(0)
                    fs:SetText(d.cols[c])
                    fs:Show()
                    local tw = fs:GetStringWidth() or 0
                    if tw > (colW[c] or 0) then colW[c] = tw end
                    local th = fs:GetStringHeight() or 0
                    if th > colH then colH = th end
                end
            end
            HideCols(row, (d.ncols or 0) + 1)
            -- Covers whichever of the three row shapes is in play, so a taller
            -- token can't bleed into the next row. Wrapped-row height depends
            -- on final width, so it's filled in below.
            if not d.wrap then
                local h = row.left:GetStringHeight() or FONT_SIZE
                if d.r then
                    local rh = row.right:GetStringHeight() or 0
                    if rh > h then h = rh end
                end
                if colH > h then h = colH end
                -- Clickable (or pad-marked) rows carry 2px of breathing room
                -- above and below the text; the padded band is the rect the
                -- overlay button and its hover wash cover.
                if d.action or d.actionToy or d.actionMacro or d._padBand then h = h + 4 end
                d._h = h
            end
        end
        for i = dataCount + 1, #rows do
            rows[i].left:Hide()
            rows[i].right:Hide()
            HideCols(rows[i], 1)
        end

        -- The sub-column block is as wide as its widest token per column plus
        -- the gaps, and shares the right column with plain right strings.
        local colsW = 0
        for c = 1, colCount do
            colsW = colsW + (colW[c] or 0) + (c > 1 and TOKEN_GAP or 0)
        end
        if colsW > maxRight then maxRight = colsW end

        local innerW = maxLeft
        if anyRight then innerW = maxLeft + COL_GAP + maxRight end
        -- Prose spans the whole inner width instead of stopping at the value rows' left
        -- column, wrapping into fewer, fuller lines with no dead gutter. Only widens
        -- the tip when its capped width exceeds what the other rows already need.
        if anyWrap then
            if maxWrap > innerW then innerW = maxWrap end
            for i = 1, dataCount do
                local d = data[i]
                if d.wrap then
                    local left = rows[i].left
                    left:SetWordWrap(true)
                    left:SetWidth(innerW)
                    local h = left:GetStringHeight() or FONT_SIZE
                    if d.action or d.actionToy or d.actionMacro or d._padBand then h = h + 4 end
                    d._h = h
                end
            end
        end
        for i = 1, dataCount do
            local d = data[i]
            d._h = d._h or FONT_SIZE
            totalH = totalH + d._h + (i > 1 and ROW_GAP or 0)
        end

        local w = innerW + PAD * 2
        local h = totalH + PAD * 2
        tip:SetSize(max(60, w), max(24, h))

        local y = -PAD
        for i = 1, dataCount do
            local d = data[i]
            local row = rows[i]
            -- Text sits 4px into a clickable row's padded band (centered);
            -- d._y keeps the band's top so the overlay covers all of it.
            local ty = y
            if d.action or d.actionToy or d.actionMacro or d._padBand then ty = y - 2 end
            row.left:ClearAllPoints()
            row.left:SetPoint("TOPLEFT", tip, "TOPLEFT", PAD, ty)
            if d.r then
                row.right:ClearAllPoints()
                row.right:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -PAD, ty)
            end
            if d.ncols then
                -- Walk columns right to left so the block ends flush with the
                -- tip's right edge, where a plain right string would land.
                -- Each token anchors by its own right edge at natural width.
                local off = PAD
                for c = colCount, 1, -1 do
                    local fs = c <= d.ncols and row.cols[c]
                    if fs then
                        fs:ClearAllPoints()
                        fs:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -off, ty)
                    end
                    off = off + (colW[c] or 0) + (c > 1 and TOKEN_GAP or 0)
                end
            end
            d._y = y
            y = y - d._h - ROW_GAP
        end

        -- Interactive overlay: one secure spell button per action row, spanning
        -- the full row rect. Skipped in combat (rows degrade to plain text, no
        -- protected touches fire). Rebuilt from scratch each show so a reused
        -- tip never carries stale buttons.
        HideActionButtons()
        interactive = false
        if not InCombatLockdown() then
            for i = 1, dataCount do
                local d = data[i]
                if d.action or d.actionToy or d.actionMacro then
                    interactive = true
                    -- Re-attach the host: REGEN_DISABLED detaches it (and the
                    -- buttons) from the tip at every combat start.
                    if activeActions == 0 then
                        local host = EnsureActionHost()
                        host:ClearAllPoints()
                        host:SetAllPoints(tip)
                        -- Follow the tip up if it outranked GameTooltip this show.
                        local hw = tip:GetFrameLevel() + 10
                        if host:GetFrameLevel() < hw then host:SetFrameLevel(hw) end
                    end
                    local b = AcquireActionButton()
                    -- Pooled reuse swaps type + payload; the unused payload is
                    -- cleared so a recycled button can never fire a stale one.
                    if d.action then
                        b:SetAttribute("type", "spell")
                        b:SetAttribute("spell", d.action)
                        b:SetAttribute("toy", nil)
                        b:SetAttribute("macrotext", nil)
                    elseif d.actionToy then
                        b:SetAttribute("type", "toy")
                        b:SetAttribute("toy", d.actionToy)
                        b:SetAttribute("spell", nil)
                        b:SetAttribute("macrotext", nil)
                    else
                        b:SetAttribute("type", "macro")
                        b:SetAttribute("macrotext", d.actionMacro)
                        b:SetAttribute("spell", nil)
                        b:SetAttribute("toy", nil)
                    end
                    PlaceRowOverlay(b, i, innerW)
                end
            end
        end

        -- Insecure clickable overlay (social/guild rows): callbacks are
        -- unprotected, so no combat guard. Rebuilt from scratch each show.
        HideClickButtons()
        for i = 1, dataCount do
            local d = data[i]
            if d.onClick then
                interactive = true
                local b = AcquireClickButton()
                local cb = d.onClick
                PlaceRowOverlay(b, i, innerW)
                b:SetScript("OnClick", function(_, mouseButton) cb(mouseButton) end)
            end
        end

        if forceInteractive then interactive = true end
        tip:EnableMouse(interactive)
        if interactive then StartKeepAlive() else StopKeepAlive() end

        -- Smart anchoring: opens off the BAR's roomier side (above/below H,
        -- left/right V) with a 6px gap, centered on the hovered block along
        -- the bar axis, clamped to screen. Owner coords convert through
        -- effective scale first since blocks carry their own Content Scale.
        tip:ClearAllPoints()
        local bar = owner:GetParent()
        while bar do
            local n = bar.GetName and bar:GetName()
            if n and n:find("^EllesmereUIDataBarsBar%d+$") then break end
            bar = bar:GetParent()
        end
        local ocx, ocy = owner:GetCenter()
        if bar and ocx then
            local os = owner:GetEffectiveScale()
            local ts = tip:GetEffectiveScale()
            local bcx, bcy = bar:GetCenter()
            local bs = bar:GetEffectiveScale()
            local uiScale = UIParent:GetEffectiveScale()
            local halfW = UIParent:GetWidth() * uiScale / 2
            local halfH = UIParent:GetHeight() * uiScale / 2
            if bar:GetHeight() > bar:GetWidth() then
                -- Vertical bar: open toward the roomier horizontal side.
                local oy = (ocy * os - bcy * bs) / ts
                if bcx * bs < halfW then
                    tip:SetPoint("LEFT", bar, "RIGHT", 6, oy)
                else
                    tip:SetPoint("RIGHT", bar, "LEFT", -6, oy)
                end
            else
                local ox = (ocx * os - bcx * bs) / ts
                if bcy * bs < halfH then
                    tip:SetPoint("BOTTOM", bar, "TOP", ox, 6)
                else
                    tip:SetPoint("TOP", bar, "BOTTOM", ox, -6)
                end
            end
        else
            -- Owner not inside a live bar: fall back to above/below by owner's
            -- own screen half.
            local half = UIParent:GetHeight() / 2
            if ocy and ocy < half then
                tip:SetPoint("BOTTOM", owner, "TOP", 0, 6)
            else
                tip:SetPoint("TOP", owner, "BOTTOM", 0, -6)
            end
        end
        tip:Show()
    end

    function ns.Tip_Hide(ownerFrame)
        if not tip then return end
        if ownerFrame and owner ~= ownerFrame then return end
        owner = nil
        HideActionButtons()
        HideClickButtons()
        StopKeepAlive()
        interactive = false
        tip:EnableMouse(false)
        tip:Hide()
    end

    -- Owner OnLeave hook: an interactive tip defers to its own keep-alive poll (so the
    -- cursor can move onto it to click a row); a plain tip hides immediately.
    function ns.Tip_HideUnlessInteractive(ownerFrame)
        if not tip then return end
        if ownerFrame and owner ~= ownerFrame then return end
        if interactive then return end
        ns.Tip_Hide(ownerFrame)
    end

    function ns.Tip_IsOwned(ownerFrame)
        if not tip then return false end
        return tip:IsShown() and owner == ownerFrame
    end

    -- Force the tip into interactive (hover-persistent) mode even with no
    -- clickable row, so OnLeave defers to the keep-alive poll and the cursor
    -- can travel onto the tip to read it. Call between Tip_Begin and Tip_Show.
    function ns.Tip_MarkInteractive()
        forceInteractive = true
    end

    -- BEGIN NEW CODE (not part of upstream)
    -- Tip_AddColumns + a secure spell action: like Tip_AddActionDouble, but the
    -- clickable row shows multiple aligned tokens instead of one right-hand
    -- string (needed for e.g. a dungeon row with Key/Rating/Run time columns).
    function ns.Tip_AddActionColumns(left, tokens, spellID, lr, lg, lb)
        if ns.Tip_AddColumns(left, tokens, lr, lg, lb) and spellID then
            data[dataCount].action = spellID
        end
    end
    -- END NEW CODE

end
-- =====================================================================
-- END UPSTREAM DUPLICATE
-- =====================================================================
