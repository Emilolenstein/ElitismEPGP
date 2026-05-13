local _, addon = ...

local Tooltip = {}
addon.Tooltip = Tooltip

------------------------------------------------------------
-- Appends two lines to the tooltip when hovering an equippable item:
--   EE GP        100 MS / 10 OS  [(override)]
--   PR after Need  3.21 (Δ -0.42)
-- Gated by quality (default Epic+) and per-user toggles. Skips
-- non-equippable items so consumables/quest items don't get noise.
------------------------------------------------------------

local function profile() return addon.DB and addon.DB.profile end

local function appendItemInfo(tip)
    if not (tip and tip.GetItem and tip.AddLine) then return end
    if not addon.Prices then return end

    local p = profile()
    if p and p.tooltipShowGP == false and p.tooltipShowPR == false then return end

    local _, link = tip:GetItem()
    if not link then return end
    local desc = addon.Prices:Describe(link)
    if not desc then return end

    -- Tokens (tier set tokens, etc.) have empty equipLoc; show the GP line
    -- whenever Prices can resolve a value — explicit override OR an auto-
    -- resolved token (AtlasLoot maps the token to its converted piece).
    -- For items with no resolution, only show on equippable gear at or
    -- above min quality so consumable/quest tooltips stay clean.
    local hasResolution = addon.Prices:HasResolution(desc.itemID)
    if not hasResolution and (not desc.equipLoc or desc.equipLoc == "") then return end

    local minQuality = (p and p.tooltipMinQuality) or 4
    if not hasResolution and (desc.quality or 0) < minQuality then return end

    local gp, source = addon.Prices:GetGP(link)
    local osGP = addon.Prices:OffSpecGP(gp)

    local showGP = (not p or p.tooltipShowGP ~= false)
    local showPR = (not p or p.tooltipShowPR ~= false) and addon.Roster
    if not (showGP or showPR) then return end

    tip:AddLine(" ")

    if showGP then
        local right = string.format("|cFFFFCC00%d|r MS / |cFFFFCC00%d|r OS", gp, osGP)
        if source == "override" then
            right = right .. "  |cFFAAAAAA(override)|r"
        elseif source == "linked" then
            right = right .. "  |cFFAAAAAA(linked)|r"
        elseif source == "auto" then
            right = right .. "  |cFFAAAAAA(auto)|r"
        end
        tip:AddDoubleLine("|cFF66CCFFEE GP|r", right)
    end

    if showPR then
        local me = UnitName("player")
        local entry, mainName
        if addon.Roster.ResolveMain then
            entry, mainName = addon.Roster:ResolveMain(me)
        end
        entry = entry or (addon.Roster.Get and addon.Roster:Get(me))
        local epNow = (entry and entry.ep) or 0
        local gpNow = (entry and entry.gp) or 0
        local minGP = (addon.DB and addon.DB.global and addon.DB.global.basegp) or addon.VARS.basegp or 100
        local prNow    = epNow / math.max(minGP, gpNow)
        local prAfter  = epNow / math.max(minGP, gpNow + gp)
        local label    = "|cFF66CCFFPR after Need|r"
        if mainName and mainName ~= me then
            label = label .. " |cFFAAAAAA(" .. mainName .. ")|r"
        end
        -- "\206\148" = Δ (U+0394). Lua 5.1 source is byte-oriented, so we
        -- emit the raw UTF-8 escape rather than a literal char.
        tip:AddDoubleLine(label,
            string.format("|cFFFFCC00%.2f|r |cFFAAAAAA(\206\148 %+.2f)|r",
                prAfter, prAfter - prNow))
    end

    if showGP and desc.itemID then
        tip:AddDoubleLine("|cFF66CCFFItem ID|r",
            string.format("|cFFFFCC00%d|r", desc.itemID))
    end

    tip:AddLine(" ")
    tip:Show()
end

function Tooltip:Init()
    if self._hooked then return end
    -- HookScript calls our handler AFTER Blizzard sets up the tooltip,
    -- so :GetItem() returns the item being shown. Hook the main and chat
    -- ref tooltips; comparison tooltips inherit text from their owners.
    if GameTooltip and GameTooltip.HookScript then
        GameTooltip:HookScript("OnTooltipSetItem", appendItemInfo)
    end
    if ItemRefTooltip and ItemRefTooltip.HookScript then
        ItemRefTooltip:HookScript("OnTooltipSetItem", appendItemInfo)
    end
    self._hooked = true
end
