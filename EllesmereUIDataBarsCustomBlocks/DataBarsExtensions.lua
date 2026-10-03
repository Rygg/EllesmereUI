if EUI_CLIENT_BLOCKED then return end -- pre-12.1 client failsafe (EllesmereUI_ClientGate.lua)
local _, addonNS = ...
local EUI = EllesmereUI
local dataBarsNS = EUI and EUI._ModuleNS and EUI._ModuleNS.EllesmereUIDataBars
if not (addonNS and dataBarsNS and dataBarsNS.BlockFactories and dataBarsNS.BLOCK_TYPES
    and dataBarsNS.BLOCK_DEFAULTS) then
    return
end

-- Keep these extensions in the dependent addon because DataBars itself cannot
-- be edited in this context.
local DataBarsExtensions = addonNS.DataBarsExtensions or {}
addonNS.DataBarsExtensions = DataBarsExtensions
DataBarsExtensions.DataBars = dataBarsNS

local optionBuilders = {} -- blockType -> function(blockCfg, settings, ctx) -> row configs
local blockLabels = {}    -- blockType -> label

-- buildOptions (optional): returns native-style row configs (toggle / dropdown /
-- slider ...; add `key = "x"` to register a deep-link target for the row).
function DataBarsExtensions.RegisterBlock(blockType, label, defaults, factory, buildOptions)
    if type(blockType) ~= "string" or type(label) ~= "string" or type(factory) ~= "function" then
        return false
    end
    blockLabels[blockType] = label
    if type(buildOptions) == "function" then optionBuilders[blockType] = buildOptions end

    local found = false
    for _, registeredType in ipairs(dataBarsNS.BLOCK_TYPES) do
        if registeredType.key == blockType then
            found = true
            break
        end
    end
    if not found then
        dataBarsNS.BLOCK_TYPES[#dataBarsNS.BLOCK_TYPES + 1] = { key = blockType, label = label }
    end

    if type(dataBarsNS.BLOCK_DEFAULTS[blockType]) ~= "table" then
        dataBarsNS.BLOCK_DEFAULTS[blockType] = type(defaults) == "table" and defaults or {}
    end
    dataBarsNS.BlockFactories[blockType] = factory
    return true
end

-- DataBars currently has no upstream Tip_AddActionColumns helper. This
-- extension fills that gap here; Tip_AddActionDouble dynamically calls
-- Tip_AddDouble before marking the row, so intercept table-valued right sides.
if not dataBarsNS.Tip_AddActionColumns
   and dataBarsNS.Tip_AddDouble and dataBarsNS.Tip_AddColumns and dataBarsNS.Tip_AddActionDouble then
    local tipAddDouble = dataBarsNS.Tip_AddDouble
    dataBarsNS.Tip_AddDouble = function(left, right, lr, lg, lb, rr, rg, rb)
        if type(right) == "table" then
            return dataBarsNS.Tip_AddColumns(left, right, lr, lg, lb)
        end
        return tipAddDouble(left, right, lr, lg, lb, rr, rg, rb)
    end
    dataBarsNS.Tip_AddActionColumns = function(left, tokens, spellID, lr, lg, lb)
        return dataBarsNS.Tip_AddActionDouble(left, tokens, spellID, lr, lg, lb)
    end
end

if dataBarsNS.Tip_AddActionColumns then
    function DataBarsExtensions.Tip_AddActionColumns(left, tokens, spellID, lr, lg, lb)
        return dataBarsNS.Tip_AddActionColumns(left, tokens, spellID, lr, lg, lb)
    end
end

-------------------------------------------------------------------------------
--  Options injection. The DataBars options page builds per-block rows from a
--  hard-coded type chain, so custom types get none. For the duration of that
--  page's buildPage we swap EllesmereUI.Widgets for a proxy whose
--  SectionHeader/Spacer flush the rows a block registered via RegisterBlock's
--  buildOptions: they land at the END of the block's section, i.e. just before
--  the next block's header (or the page's closing spacer).
--  Blocks are matched by order (Nth block header after "BAR SETTINGS" == Nth
--  block of the selected bar) and verified against the header text; any
--  mismatch or error injects nothing.
-------------------------------------------------------------------------------
local MODULE = "EllesmereUIDataBars"

local function BlockLabelHeader(blockType)
    local label = blockLabels[blockType] or blockType
    for _, t in ipairs(dataBarsNS.BLOCK_TYPES) do
        if t.key == blockType then label = t.label break end
    end
    return string.upper(EUI.L(label))
end

local function SelectedBlocks()
    local p = dataBarsNS.GetProfile and dataBarsNS.GetProfile()
    if not p or not p.bars or #p.bars == 0 then return nil end
    local cfg = p.selectedBarId and dataBarsNS.GetBar and dataBarsNS.GetBar(p.selectedBarId) or p.bars[1]
    if not cfg or not cfg.blocks then return nil end
    local shown = {}
    for _, b in ipairs(cfg.blocks) do
        if not (EUI.IS_FOREVER and not dataBarsNS.BlockFactories[b.type]) then shown[#shown + 1] = b end
    end
    return cfg, shown
end

local function WrapBuildPage(config)
    if config._customOptionsWrapped or type(config.buildPage) ~= "function" then return end
    config._customOptionsWrapped = true
    local origBuild = config.buildPage

    config.buildPage = function(pageName, parent, yOffset)
        local realW = EUI.Widgets
        local cfg, blocks = SelectedBlocks()
        if not (realW and cfg and blocks) then return origBuild(pageName, parent, yOffset) end

        local idx, pending, pendingHdr = 0, nil, nil
        local inBlocks = false

        local function Flush(y)
            local b, hdr = pending, pendingHdr
            pending, pendingHdr = nil, nil
            if not b then return 0 end
            local ok, extra = pcall(function()
                local s = b.settings
                if not s then s = {}; b.settings = s end
                local function Apply() dataBarsNS.ApplyBar(cfg.id) end
                local function Toggle(label, key, tip, defaultOn)
                    return { type = "toggle", text = label, tooltip = tip,
                        getValue = function()
                            if defaultOn then return s[key] ~= false end
                            return s[key] == true
                        end,
                        setValue = function(v) s[key] = v and true or false; Apply() end }
                end
                local ctx = { Apply = Apply, Refresh = function() EUI:RefreshPage() end,
                              Toggle = Toggle, barCfg = cfg }
                local rows = optionBuilders[b.type](b, s, ctx)
                local used = 0
                if type(rows) ~= "table" then return 0 end
                for k = 1, #rows, 2 do
                    local left, right = rows[k], rows[k + 1] or { type = "label", text = "" }
                    local row, h = realW:DualRow(parent, y - used, left, right)
                    used = used + (h or 0)
                    for side, rc in pairs({ left = left, right = right }) do
                        if rc.key and parent._edbClickTargets then
                            parent._edbClickTargets["block:" .. b.id .. ":" .. rc.key] =
                                { section = hdr, target = row, slotSide = side }
                        end
                    end
                end
                return used
            end)
            return ok and extra or 0
        end

        local proxy = setmetatable({
            SectionHeader = function(_, p, text, y)
                local extra = Flush(y)
                local hdr, h
                hdr, h = realW:SectionHeader(p, text, y - extra)
                if text == "BAR SETTINGS" then
                    inBlocks, idx = true, 0
                elseif inBlocks then
                    idx = idx + 1
                    local b = blocks[idx]
                    if b and optionBuilders[b.type] and BlockLabelHeader(b.type) == text then
                        pending, pendingHdr = b, hdr
                    end
                end
                return hdr, (h or 0) + extra
            end,
            Spacer = function(_, p, y, height)
                local extra = Flush(y)
                local s, h = realW:Spacer(p, y - extra, height)
                return s, (h or 0) + extra
            end,
        }, { __index = function(_, k) return realW[k] end })

        EUI.Widgets = proxy
        local ok, res = pcall(origBuild, pageName, parent, yOffset)
        EUI.Widgets = realW
        if not ok then error(res, 0) end
        return res
    end
end

local function TryWrap()
    local config = EUI._modules and EUI._modules[MODULE]
    if config then WrapBuildPage(config) end
end

-- The options addon is load-on-demand and registers its pages later; a post-hook
-- keeps RegisterModule's caller-folder check untouched.
if hooksecurefunc then
    hooksecurefunc(EUI, "RegisterModule", function(_, folderName)
        if folderName == MODULE then TryWrap() end
    end)
end
TryWrap()
