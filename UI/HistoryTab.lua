local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local HistoryTab = {}
UI.HistoryTab = HistoryTab

local ROW_HEIGHT   = 18
local VISIBLE_ROWS = 22
local rows = {}

local filters = { target = "", EP = true, GP = true, DECAY = true, memberView = false }

local sortKey = "time"
local sortDir = "desc"

-- Sort indicator: same atlas + 180° UV flip pattern as Standings/PlayerDetail.
local ARROW_ATLAS = "rotating-minimapguidearrow"
local ARROW_UV    = { L = 0.541992, R = 0.573242, T = 0.936523, B = 0.967773 }
local arrowFile

local function ensureArrowFile(parent)
    if arrowFile ~= nil then return arrowFile or nil end
    local probe = parent:CreateTexture(nil, "BACKGROUND")
    probe:Hide()
    if not probe.SetAtlas then
        arrowFile = false
        return nil
    end
    probe:SetAtlas(ARROW_ATLAS)
    arrowFile = probe:GetTexture() or false
    return arrowFile or nil
end

local function arrowFor(btn)
    if not btn then return nil end
    if btn.eepgpSortArrow then return btn.eepgpSortArrow end
    local tex = btn:CreateTexture(nil, "OVERLAY")
    tex:SetSize(20, 20)
    local fs = btn:GetFontString()
    if fs then
        tex:SetPoint("LEFT", fs, "RIGHT", -4, 0)
    else
        tex:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
    end
    tex:Hide()
    btn.eepgpSortArrow = tex
    return tex
end

local function applyArrow(tex, dir)
    local file = arrowFile
    if not file then return false end
    tex:SetTexture(file)
    if dir == "desc" then
        tex:SetTexCoord(ARROW_UV.R, ARROW_UV.L, ARROW_UV.B, ARROW_UV.T)
    else
        tex:SetTexCoord(ARROW_UV.L, ARROW_UV.R, ARROW_UV.T, ARROW_UV.B)
    end
    return true
end

local function updateHeader(btn, key)
    if not btn then return end
    local arrow = arrowFor(btn)
    if not arrow then return end
    if key == sortKey then
        ensureArrowFile(btn)
        if applyArrow(arrow, sortDir) then arrow:Show() else arrow:Hide() end
    else
        arrow:Hide()
    end
end

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

local function BucketOf(kindStr)
    if not kindStr then return "OTHER" end
    if kindStr:sub(1, 3) == "EP:" then return "EP" end
    if kindStr:sub(1, 3) == "GP:" then return "GP" end
    if kindStr == "Decay" then return "DECAY" end
    -- Alt entries fall through to OTHER (always shown) — there is no
    -- per-kind filter for them anymore.
    return "OTHER"
end

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

local function FormatReason(e)
    if e.note and e.note ~= "" then return e.note end
    return KIND_LABELS[e.kind] or e.kind or "?"
end

-- Pulls the inner link payload (e.g. "item:18803:0:0:0:0:0:0:0:80") out of
-- the |H...|h hyperlink that GP award entries carry in their note. Returns
-- nil for entries that don't reference an item.
local function ExtractItemLink(text)
    if not text then return nil end
    return text:match("|H(.-)|h")
end

local function MatchesFilters(e)
    if filters.memberView and e.visibility == "officer" then return false end
    if filters.target and filters.target ~= "" then
        if e.kind == "Decay" then return false end
        local needle = filters.target:lower()
        local hit = false
        if e.target     and e.target:lower():find(needle, 1, true)     then hit = true end
        if e.actor      and e.actor:lower():find(needle, 1, true)      then hit = true end
        if e.resolvedTo and e.resolvedTo:lower():find(needle, 1, true) then hit = true end
        if not hit then return false end
    end
    local bucket = BucketOf(e.kind)
    if bucket == "OTHER" then return true end
    return filters[bucket] == true
end

local function UpdateMemberViewVisibility(self)
    if not self.frame then return end
    local isOfficer = CanEditOfficerNote and CanEditOfficerNote()
    if isOfficer then
        self.frame.memberView:Show()
        self.frame.memberViewLabel:Show()
    else
        self.frame.memberView:Hide()
        self.frame.memberViewLabel:Hide()
    end
end

function HistoryTab:Init(parent)
    if self.frame then return end
    self.frame = ElitismEPGPHistoryTab
    if not self.frame then return end
    self.frame:SetParent(parent)
    self.frame:SetAllPoints(parent)

    self.frame.targetFilter:SetScript("OnTextChanged", function(eb)
        filters.target = eb:GetText() or ""
        HistoryTab:Refresh()
    end)
    if UI.Skin and UI.Skin.DecorateSearchBox then
        UI.Skin:DecorateSearchBox(self.frame.targetFilter)
    end

    local function wireKind(btn, key)
        btn:SetChecked(true)
        btn:SetScript("OnClick", function(b)
            filters[key] = b:GetChecked() and true or false
            HistoryTab:Refresh()
        end)
    end
    wireKind(self.frame.kindEP,    "EP")
    wireKind(self.frame.kindGP,    "GP")
    wireKind(self.frame.kindDecay, "DECAY")

    if self.frame.memberView then
        self.frame.memberView:SetChecked(false)
        self.frame.memberView:SetScript("OnClick", function(b)
            filters.memberView = b:GetChecked() and true or false
            HistoryTab:Refresh()
        end)
    end
    UpdateMemberViewVisibility(self)

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, self.frame, "ElitismEPGP_HistoryRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", self.frame.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end

        -- Hover highlight: same search-select atlas as the standings tab,
        -- stretched 60 px past each side so the soft edges fade out beyond
        -- the row's content rect.
        if row.bg and row.bg.SetAtlas then
            row.bg:ClearAllPoints()
            row.bg:SetPoint("TOPLEFT",     row, "TOPLEFT",     -60, 0)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT",  60, 0)
            row.bg:SetAtlas("search-select")
            row.bg:Hide()
        end

        rows[i] = row
    end

    -- Live refresh when a new history entry is logged. Only update if the
    -- main window AND this tab are both shown — avoid wasted refreshes.
    if addon.Awards and addon.Awards.OnLogAppend then
        addon.Awards:OnLogAppend(function()
            if HistoryTab.frame and HistoryTab.frame:IsShown()
               and ElitismEPGPMainFrame and ElitismEPGPMainFrame:IsShown() then
                HistoryTab:Refresh()
            end
        end)
    end

    -- Hover affordance for the sortable header (only "When" supports sort
    -- in this tab for now — other columns stay as plain FontStrings).
    if self.frame.hdrTime then
        self.frame.hdrTime:HookScript("OnEnter", function(self)
            local fs = self:GetFontString()
            if fs then fs:SetTextColor(1, 0.82, 0) end
        end)
        self.frame.hdrTime:HookScript("OnLeave", function(self)
            local fs = self:GetFontString()
            if fs then fs:SetTextColor(1, 1, 1) end
        end)
    end
end

function HistoryTab:SetSort(key)
    if not key then return end
    if key == sortKey then
        sortDir = (sortDir == "desc") and "asc" or "desc"
    else
        sortKey = key
        sortDir = "desc"
    end
    self:Refresh()
end

function HistoryTab:CollectFiltered()
    -- Awards:GetHistory returns a list sorted oldest → newest. We want
    -- newest-first display, so iterate in reverse below.
    local h = (addon.Awards and addon.Awards.GetHistory)
        and addon.Awards:GetHistory() or {}

    local groups = {}
    for i = 1, #h do
        local e = h[i]
        if e.group_id then
            local g = groups[e.group_id]
            if not g then
                g = { count = 0, totalEP = 0, totalGP = 0, members = {} }
                groups[e.group_id] = g
            end
            g.count = g.count + 1
            g.totalEP = g.totalEP + (e.dEP or 0)
            g.totalGP = g.totalGP + (e.dGP or 0)
            g.members[#g.members + 1] = e
        end
    end

    local seenGroups = {}
    local out = {}
    -- GetHistory() is sorted oldest → newest. desc = newest first (iterate
    -- backward); asc = oldest first (iterate forward). Group dedup is
    -- order-aware, so we collect in display order directly.
    local function collect(e)
        if not MatchesFilters(e) then return end
        if e.group_id then
            if not seenGroups[e.group_id] then
                seenGroups[e.group_id] = true
                out[#out + 1] = { entry = e, group = groups[e.group_id] }
            end
        else
            out[#out + 1] = { entry = e, group = nil }
        end
    end
    if sortDir == "asc" then
        for i = 1, #h do collect(h[i]) end
    else
        for i = #h, 1, -1 do collect(h[i]) end
    end
    return out, #h
end

function HistoryTab:Refresh()
    if not self.frame then return end
    UpdateMemberViewVisibility(self)
    local list, total = self:CollectFiltered()
    local shown = #list
    local scroll = self.frame.scroll

    FauxScrollFrame_Update(scroll, shown, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    updateHeader(self.frame.hdrTime, "time")

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local item = list[i + offset]
        if item then
            local e = item.entry
            local g = item.group
            row.time:SetText(date("%m-%d %H:%M", e.ts or 0))
            row.actor:SetText(e.actor or "?")
            local target
            if g then
                target = string.format("|cFFFFCC00× %d player%s|r", g.count, g.count == 1 and "" or "s")
            else
                target = e.target or "?"
                if e.resolvedTo and e.resolvedTo ~= e.target then
                    target = string.format("%s |cFF888888->%s|r", target, e.resolvedTo)
                end
            end
            row.target:SetText(target)
            row.delta:SetText(FormatDelta(e))
            row.reason:SetText(FormatReason(e))
            row._entry = e
            row._group = g
            row:Show()
        else
            row._entry = nil
            row._group = nil
            row:Hide()
        end
    end

    if UI.MainFrame and UI.MainFrame.SetStatus then
        local txt
        if shown == total then
            txt = string.format("%d entr%s", total, total == 1 and "y" or "ies")
        else
            txt = string.format("%d of %d entries (filtered)", shown, total)
        end
        UI.MainFrame:SetStatus(txt, "history")
    end
end

function HistoryTab:OnRowEnter(row)
    if not row or not row._entry then return end
    if row.bg then row.bg:Show() end

    local link = ExtractItemLink(row._entry.note)
    if link then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(link)
        GameTooltip:Show()
    end
end

function HistoryTab:OnRowLeave(row)
    if row and row.bg then row.bg:Hide() end
    GameTooltip:Hide()
end

function HistoryTab:OnRowClick(row, button)
    if button ~= "LeftButton" then return end
    if not row or not row._entry then return end
    if UI.HistoryDetailFrame and UI.HistoryDetailFrame.Open then
        UI.HistoryDetailFrame:Open(row._entry, row._group)
    end
end

ElitismEPGP_HistoryTab = HistoryTab
