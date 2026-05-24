local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local HistoryDetailFrame = {}
UI.HistoryDetailFrame = HistoryDetailFrame

local ROW_HEIGHT   = 18
local VISIBLE_ROWS = 17
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
    if e.kind == "Decay" then
        return "|cFFFFCC00decay|r"
    end
    if e.kind == "AltMark" or e.kind == "AltUnmark" then
        return "|cFF66CCFFalt|r"
    end
    if (e.dEP or 0) ~= 0 then
        local color = e.dEP > 0 and "55FF55" or "FF6060"
        return string.format("|cFF%s%+d EP|r", color, e.dEP)
    end
    if (e.dGP or 0) ~= 0 then
        local color = e.dGP > 0 and "FFCC66" or "55FF55"
        return string.format("|cFF%s%+d GP|r", color, e.dGP)
    end
    return "—"
end

local function FormatChange(e)
    if e.before and e.after then
        return string.format("%d:%d -> %d:%d",
            e.before.ep or 0, e.before.gp or 0,
            e.after.ep or 0,  e.after.gp or 0)
    end
    return "—"
end

local function ExtractItemLink(text)
    if not text then return nil end
    return text:match("|H(.-)|h")
end

function HistoryDetailFrame:Init()
    if self.frame then return end
    local frame = ElitismEPGPHistoryDetailFrame
    if not frame then return end
    self.frame = frame

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, frame, "ElitismEPGP_DetailRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", frame.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end
        rows[i] = row
    end

    -- Re-anchor the FauxScrollFrame slider so it shifts down 5 and is 25
    -- shorter than the template default. The template's defaults are
    -- TOPRIGHT(-2,-16) / BOTTOMRIGHT(-2,+16) (the ±16 gutter is for the
    -- up/down arrow buttons that flank the slider track). Shifting top
    -- y by -5 moves the whole bar down; pushing bottom y up by +20 nets
    -- the −25 height drop after that shift.
    --
    -- Slider lookup: prefer the named global (FauxScrollFrameTemplate's
    -- slider is `<Slider name="$parentScrollBar">`, so giving the scroll
    -- frame a name in XML gives the slider one too). Fall back to iterating
    -- the scroll frame's child frames in case the template differs.
    local scrollbar = (frame.scroll.GetName and _G[(frame.scroll:GetName() or "") .. "ScrollBar"]) or nil
    if not scrollbar then
        for _, kid in ipairs({ frame.scroll:GetChildren() }) do
            if kid.GetObjectType and kid:GetObjectType() == "Slider" then
                scrollbar = kid
                break
            end
        end
    end
    if scrollbar then
        scrollbar:ClearAllPoints()
        scrollbar:SetPoint("TOPRIGHT",    frame.scroll, "TOPRIGHT",    18, -21)
        scrollbar:SetPoint("BOTTOMRIGHT", frame.scroll, "BOTTOMRIGHT", 18,  31)
    end

    -- Hover the header info area to see the item tooltip when this entry
    -- references an item (GP awards embed the link in note).
    if frame.itemHover then
        frame.itemHover:SetScript("OnEnter", function(self)
            local link = self._itemLink
            if not link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            GameTooltip:Show()
        end)
        frame.itemHover:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
end

function HistoryDetailFrame:Open(entry, group)
    self:Init()
    if not self.frame then return end

    currentMembers = {}
    if group and group.members then
        for i = 1, #group.members do
            currentMembers[#currentMembers + 1] = group.members[i]
        end
    else
        currentMembers[1] = entry
    end

    local count = #currentMembers
    local kindLabel = KIND_LABELS[entry.kind] or entry.kind or "?"
    local headerSuffix = ""
    if group then
        if (entry.dEP or 0) ~= 0 then
            headerSuffix = string.format("  %+d EP × %d player%s", entry.dEP, count, count == 1 and "" or "s")
        elseif (entry.dGP or 0) ~= 0 then
            headerSuffix = string.format("  %+d GP × %d player%s", entry.dGP, count, count == 1 and "" or "s")
        else
            headerSuffix = string.format("  × %d player%s", count, count == 1 and "" or "s")
        end
    elseif (entry.dEP or 0) ~= 0 then
        headerSuffix = string.format("  %+d EP", entry.dEP)
    elseif (entry.dGP or 0) ~= 0 then
        headerSuffix = string.format("  %+d GP", entry.dGP)
    end
    self.frame.kindLabel:SetText(kindLabel .. headerSuffix)

    self.frame.metaLine:SetText(string.format("by %s  -  %s",
        entry.actor or "?",
        date("%Y-%m-%d %H:%M:%S", entry.ts or 0)))

    if entry.note and entry.note ~= "" then
        self.frame.reasonLabel:Show()
        self.frame.reasonText:SetText(entry.note)
    else
        self.frame.reasonLabel:Hide()
        self.frame.reasonText:SetText("")
    end

    -- Cache the item link (if any) on the hover frame so OnEnter can pull it.
    if self.frame.itemHover then
        self.frame.itemHover._itemLink = ExtractItemLink(entry.note)
    end

    if entry.kind == "Decay" then
        -- v0.1.3+ decay entries carry a per-member breakdown in
        -- entry.members; legacy entries (logged before v0.1.3) don't,
        -- so fall through to the empty-text message.
        if entry.members and #entry.members > 0 then
            currentMembers = {}
            for i = 1, #entry.members do
                currentMembers[#currentMembers + 1] = entry.members[i]
            end
            self.frame.emptyText:Hide()
        else
            self.frame.emptyText:SetText("No per-player breakdown stored for this decay (logged before v0.1.3).")
            self.frame.emptyText:Show()
            currentMembers = {}
        end
    else
        self.frame.emptyText:Hide()
    end

    self:Refresh()
    if UI.MainFrame and UI.MainFrame.OpenSidePopup then
        UI.MainFrame:OpenSidePopup(self.frame)
    else
        self.frame:Show()
    end
end

function HistoryDetailFrame:Refresh()
    if not self.frame then return end
    local total = #currentMembers
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

function HistoryDetailFrame:Close()
    if self.frame then self.frame:Hide() end
end

ElitismEPGP_HistoryDetailFrame = HistoryDetailFrame
