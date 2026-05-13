local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local SessionLogs = {}
UI.SessionLogs = SessionLogs

local ROW_HEIGHT   = 16
local VISIBLE_ROWS = 13   -- 13 * 16 = 208px, fits the 216px-tall scroll viewport
local rows = {}

-- Column sorting (same UX as the main window's Standings/History tabs).
local sortKey, sortDir = "time", "desc"
local SORT_DEFAULT_DIR = { time = "desc", target = "asc", delta = "desc", reason = "asc" }

-- Top-right search box: case-insensitive substring match on player / reason.
local searchFilter = ""

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
    ["Decay"]            = "Maintenance",
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

local function FormatReason(e)
    if e.note and e.note ~= "" then return e.note end
    return KIND_LABELS[e.kind] or e.kind or "?"
end

-- True when the search box is empty, or `needle` (already lowercased) appears
-- in the entry's player name, its resolved-to name, or its reason text.
local function matchesSearch(e, needle)
    if not needle then return true end
    local hay = (e.target or "")
    if e.resolvedTo then hay = hay .. " " .. e.resolvedTo end
    hay = (hay .. " " .. FormatReason(e)):lower()
    return hay:find(needle, 1, true) ~= nil
end

-- A list item is {entry=representative, group=nil-or-{count,totalEP,totalGP,members}}.
-- It matches the search if the representative does, or — for grouped rows — if
-- any member does (so e.g. searching a name reveals the bulk award it's part of).
local function itemMatchesSearch(item, needle)
    if not needle then return true end
    if matchesSearch(item.entry, needle) then return true end
    if item.group then
        for _, m in ipairs(item.group.members) do
            if matchesSearch(m, needle) then return true end
        end
    end
    return false
end

local function GetSessionStart()
    return (addon.DB and addon.DB.global and addon.DB.global.sessionStart) or 0
end

local function StartNewSession()
    if addon.DB and addon.DB.global then
        addon.DB.global.sessionStart = time()
    end
end

-- Collapse bulk awards into a single row (same as the History tab): entries
-- sharing a group_id are folded into one {entry, group} item, where `group`
-- carries the count/totals and the full member list (clicking the row opens
-- the per-player breakdown). Standalone entries keep group=nil.
local function CollectSessionItems()
    local h = (addon.Awards and addon.Awards.GetHistory)
        and addon.Awards:GetHistory({ since = GetSessionStart() }) or {}

    local groups = {}
    for i = 1, #h do
        local e = h[i]
        if e.group_id then
            local g = groups[e.group_id]
            if not g then
                g = { count = 0, totalEP = 0, totalGP = 0, members = {} }
                groups[e.group_id] = g
            end
            g.count   = g.count + 1
            g.totalEP = g.totalEP + (e.dEP or 0)
            g.totalGP = g.totalGP + (e.dGP or 0)
            g.members[#g.members + 1] = e
        end
    end

    local seen, out = {}, {}
    for i = 1, #h do
        local e = h[i]
        local g = e.group_id and groups[e.group_id]
        if g and g.count > 1 then
            if not seen[e.group_id] then
                seen[e.group_id] = true
                out[#out + 1] = { entry = e, group = g }
            end
        else
            -- Standalone entry (or a "bulk" award that ended up with one
            -- recipient) — show it on its own line.
            out[#out + 1] = { entry = e, group = nil }
        end
    end
    return out
end

function SessionLogs:Init()
    if self.frame then return end
    local f = ElitismEPGPSessionLogsFrame
    if not f then return end
    self.frame = f

    -- Same chrome as the Raid Manager: SimpleMetal 9-slice border, the
    -- close-button corner pocket, the decorative filigree, and the dark
    -- bg whose opacity follows the profile's bgOpacity slider.
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
        if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(f) end
    end
    if UI.Skin and UI.Skin.WireSortHeader then
        UI.Skin:WireSortHeader(f.hdrTime)
        UI.Skin:WireSortHeader(f.hdrTarget)
        UI.Skin:WireSortHeader(f.hdrDelta)
        UI.Skin:WireSortHeader(f.hdrReason)
    end

    if f.searchFilter then
        f.searchFilter:SetScript("OnTextChanged", function(eb)
            searchFilter = eb:GetText() or ""
            SessionLogs:Refresh()
        end)
        if UI.Skin and UI.Skin.DecorateSearchBox then
            UI.Skin:DecorateSearchBox(f.searchFilter)
        end
    end

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_SessionLogRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end
        -- Row hover highlight, same as the main window's standings rows.
        row:SetScript("OnEnter", function(self)
            if self.bg and self.bg.SetAtlas then
                self.bg:SetAtlas("search-select")
                self.bg:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            if self.bg then self.bg:Hide() end
        end)
        -- Left-click a row → the per-group breakdown popup beside the log.
        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self._entry
               and UI.SessionLogDetail and UI.SessionLogDetail.Open then
                UI.SessionLogDetail:Open(self._entry, self._group)
            end
        end)
        rows[i] = row
    end

    -- Live refresh on new history entries (only when shown).
    if addon.Awards and addon.Awards.OnLogAppend then
        addon.Awards:OnLogAppend(function()
            if SessionLogs.frame and SessionLogs.frame:IsShown() then
                SessionLogs:Refresh()
            end
        end)
    end
end

function SessionLogs:AnchorBeside(rmFrame)
    if not self.frame or not rmFrame then return end
    local screenWidth = UIParent:GetWidth()
    local rmCenterX = (rmFrame:GetLeft() or 0) + (rmFrame:GetWidth() or 0) / 2
    self.frame:ClearAllPoints()
    if rmCenterX > screenWidth / 2 then
        self.frame:SetPoint("TOPRIGHT", rmFrame, "TOPLEFT", -4, 0)
    else
        self.frame:SetPoint("TOPLEFT", rmFrame, "TOPRIGHT", 4, 0)
    end
end

function SessionLogs:SetSort(key)
    if not key then return end
    if key == sortKey then
        sortDir = (sortDir == "asc") and "desc" or "asc"
    else
        sortKey = key
        sortDir = SORT_DEFAULT_DIR[key] or "desc"
    end
    self:Refresh()
end

-- Numeric value used for the "Delta" column sort: the entry's EP change if
-- non-zero, else its GP change (else 0 for non-point entries like alt marks).
local function deltaValue(e)
    if (e.dEP or 0) ~= 0 then return e.dEP end
    if (e.dGP or 0) ~= 0 then return e.dGP end
    return 0
end

local function sortItems(items)
    local asc = (sortDir == "asc")
    table.sort(items, function(ia, ib)
        local a, b = ia.entry, ib.entry
        if sortKey == "target" then
            -- Grouped rows show "x N players" rather than a name; sort them
            -- as "" so they cluster instead of jumbling among real names.
            local at = ia.group and "" or (a.target or "?"):lower()
            local bt = ib.group and "" or (b.target or "?"):lower()
            if at ~= bt then if asc then return at < bt else return at > bt end end
        elseif sortKey == "delta" then
            local ad, bd = deltaValue(a), deltaValue(b)
            if ad ~= bd then if asc then return ad < bd else return ad > bd end end
        elseif sortKey == "reason" then
            local ar, br = FormatReason(a):lower(), FormatReason(b):lower()
            if ar ~= br then if asc then return ar < br else return ar > br end end
        else -- time
            local at, bt = (a.ts or 0), (b.ts or 0)
            if at ~= bt then if asc then return at < bt else return at > bt end end
            return false
        end
        -- Stable tiebreak: most-recent first regardless of the active column.
        return (a.ts or 0) > (b.ts or 0)
    end)
end

function SessionLogs:Refresh()
    if not self.frame then return end
    local items = CollectSessionItems()
    if searchFilter ~= "" then
        local needle, filtered = searchFilter:lower(), {}
        for _, item in ipairs(items) do
            if itemMatchesSearch(item, needle) then filtered[#filtered + 1] = item end
        end
        items = filtered
    end
    sortItems(items)
    local total = #items
    local scroll = self.frame.scroll

    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    if UI.Skin and UI.Skin.UpdateSortArrow then
        UI.Skin:UpdateSortArrow(self.frame.hdrTime,   sortKey == "time",   sortDir)
        UI.Skin:UpdateSortArrow(self.frame.hdrTarget, sortKey == "target", sortDir)
        UI.Skin:UpdateSortArrow(self.frame.hdrDelta,  sortKey == "delta",  sortDir)
        UI.Skin:UpdateSortArrow(self.frame.hdrReason, sortKey == "reason", sortDir)
    end

    for i = 1, VISIBLE_ROWS do
        local row  = rows[i]
        local item = items[i + offset]
        if item then
            local e, g = item.entry, item.group
            row.time:SetText(date("%H:%M", e.ts or 0))   -- hour:minute only; the date is "today's raid"
            local target
            if g then
                target = string.format("|cFFFFCC00x %d player%s|r", g.count, g.count == 1 and "" or "s")
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

    if self.frame.emptyText then
        if total == 0 then self.frame.emptyText:Show() else self.frame.emptyText:Hide() end
    end

    if self.frame.summary then
        local sessionStart = GetSessionStart()
        if total == 0 then
            self.frame.summary:SetText(string.format("No entries since %s", date("%H:%M:%S", sessionStart)))
        else
            self.frame.summary:SetText(string.format("%d entr%s since %s",
                total, total == 1 and "y" or "ies", date("%H:%M:%S", sessionStart)))
        end
    end
end

function SessionLogs:Open(rmFrame)
    if not self.frame then self:Init() end
    if not self.frame then return end
    -- The Players and Session Log panels are mutually exclusive — opening
    -- one closes the other.
    if UI.RaidInfo and UI.RaidInfo.frame then UI.RaidInfo.frame:Hide() end
    self.frame:Show()
    self:Refresh()
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    elseif rmFrame then
        self:AnchorBeside(rmFrame)
    end
end

function SessionLogs:Close()
    if self.frame then self.frame:Hide() end
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    end
end

function SessionLogs:Toggle(rmFrame)
    if not self.frame then self:Init() end
    if not self.frame then return end
    if self.frame:IsShown() then
        self:Close()
    else
        self:Open(rmFrame)
    end
end

ElitismEPGP_SessionLogs = SessionLogs
