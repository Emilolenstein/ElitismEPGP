local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

-- Per-group breakdown popup for a Session Log row. Mirrors the History
-- detail panel: shows the award/kind + count in the header and one row per
-- member with their individual delta and before -> after standing. It's
-- skinned like the Session Log itself, and LayoutSidePanels positions it
-- beside the log on whichever side the log sits relative to the Raid Manager.
local SessionLogDetail = {}
UI.SessionLogDetail = SessionLogDetail

local ROW_HEIGHT   = 18
local VISIBLE_ROWS = 12   -- 12 * 18 = 216px, fits the 232px scroll viewport
local rows = {}
local currentMembers = {}

local KIND_LABELS = {
    ["EP:OnTime"]        = "On-time",
    ["EP:EndOfRaid"]     = "End of raid",
    ["EP:FirstKill"]     = "First kill",
    ["EP:BossKill"]      = "Boss kill",
    ["EP:OfficerWeekly"] = "Officer +25",
    ["EP:Custom"]        = "Custom EP",
    ["GP:Award"]         = "Item award",
    ["GP:Refund"]        = "GP refund",
    ["GP:Custom"]        = "Custom GP",
    ["Decay"]            = "Weekly maintenance",
    ["AltMark"]          = "Marked alt",
    ["AltUnmark"]        = "Unmarked alt",
}

local function FormatDelta(e)
    if e.kind == "Decay" then return "|cFFFFCC00decay|r" end
    if e.kind == "AltMark" or e.kind == "AltUnmark" then return "|cFF66CCFFalt|r" end
    if (e.dEP or 0) ~= 0 then
        return string.format("|cFF%s%+d EP|r", e.dEP > 0 and "55FF55" or "FF6060", e.dEP)
    end
    if (e.dGP or 0) ~= 0 then
        return string.format("|cFF%s%+d GP|r", e.dGP > 0 and "FFCC66" or "55FF55", e.dGP)
    end
    return "—"
end

local function FormatChange(e)
    if e.before and e.after then
        return string.format("%d:%d -> %d:%d",
            e.before.ep or 0, e.before.gp or 0,
            e.after.ep  or 0, e.after.gp  or 0)
    end
    return "—"
end

function SessionLogDetail:Init()
    if self.frame then return end
    local f = ElitismEPGPSessionLogDetailFrame
    if not f then return end
    self.frame = f

    -- Same chrome as the Session Log: SimpleMetal border + close-button
    -- pocket + filigree + bgOpacity-driven dark backdrop.
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
        if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(f) end
    end

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_DetailRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end
        rows[i] = row
    end
end

-- entry = the representative log entry (carries kind/actor/ts/delta), group =
-- the {count, totalEP, totalGP, members} table when this row was a bulk award
-- (nil = a single-player entry, in which case we show just that one).
function SessionLogDetail:Open(entry, group)
    self:Init()
    if not self.frame or not entry then return end

    currentMembers = {}
    if group and group.members then
        for i = 1, #group.members do currentMembers[i] = group.members[i] end
    else
        currentMembers[1] = entry
    end

    local count     = #currentMembers
    local kindLabel = KIND_LABELS[entry.kind] or entry.kind or "?"
    local suffix
    if (entry.dEP or 0) ~= 0 then
        suffix = string.format("  %+d EP", entry.dEP)
    elseif (entry.dGP or 0) ~= 0 then
        suffix = string.format("  %+d GP", entry.dGP)
    else
        suffix = ""
    end
    if group then
        suffix = suffix .. string.format("  x %d player%s", count, count == 1 and "" or "s")
    end
    self.frame.title:SetText(kindLabel .. suffix)
    self.frame.metaLine:SetText(string.format("by %s  -  %s",
        entry.actor or "?", date("%H:%M:%S", entry.ts or 0)))

    if entry.kind == "Decay" then
        currentMembers = {}
        self.frame.emptyText:SetText("No per-player breakdown stored for maintenance.")
        self.frame.emptyText:Show()
    else
        self.frame.emptyText:Hide()
    end

    self:Refresh()
    self.frame:Show()
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    end
end

function SessionLogDetail:Refresh()
    if not self.frame then return end
    local total  = #currentMembers
    local scroll = self.frame.scroll

    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local m = currentMembers[i + offset]
        if m then
            local name = m.target or "?"
            if m.resolvedTo and m.resolvedTo ~= m.target then
                name = string.format("%s |cFF888888->%s|r", name, m.resolvedTo)
            end
            row.player:SetText(name)
            row.delta:SetText(FormatDelta(m))
            row.change:SetText(FormatChange(m))
            row:Show()
        else
            row:Hide()
        end
    end
end

function SessionLogDetail:Close()
    if self.frame then self.frame:Hide() end
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    end
end

ElitismEPGP_SessionLogDetail = SessionLogDetail
