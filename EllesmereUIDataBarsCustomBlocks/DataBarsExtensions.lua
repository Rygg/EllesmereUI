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

function DataBarsExtensions.RegisterBlock(blockType, label, defaults, factory)
    if type(blockType) ~= "string" or type(label) ~= "string" or type(factory) ~= "function" then
        return false
    end

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