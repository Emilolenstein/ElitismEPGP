local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local StandingsTab = {}
UI.StandingsTab = StandingsTab

local ROW_HEIGHT   = 18
local VISIBLE_ROWS = 22
local rows = {}
local sortKey = "pr"
local sortDir = "desc"  -- pr/ep/gp/level default desc; name defaults asc

-- Filter state for the search row (anchored above the standings frame,
-- inline with the close button). Search matches name OR class case-
-- insensitively; checkboxes post-filter the sorted list.
local filters = { search = "", hasPROnly = false, onlineOnly = false }

-- Self-marker icon shown next to the current player's name. Inline texture
-- syntax expects pixel coords, so we probe the atlas's underlying file
-- path once via SetAtlas+GetTexture, then reconstruct the |T|t string
-- using a reference texture size that decodes the normalized UVs into
-- whole integers (the engine only cares about the ratio):
--   L=0, R=176, T=387, B=476 at a 2048-px reference.
local SELF_MARKER = {
    atlas   = "realm-one-character",
    refSize = 2048,
    L = 0, R = 176, T = 387, B = 476,
    display = 14,  -- screen pixels — sized to match the small font glyph
}
local selfMarkerInline  -- nil = unprobed, false = unsupported, string = ready
local function getSelfMarker()
    if selfMarkerInline ~= nil then return selfMarkerInline or nil end
    local probe = UIParent:CreateTexture(nil, "BACKGROUND")
    probe:Hide()
    if not probe.SetAtlas then selfMarkerInline = false; return nil end
    probe:SetAtlas(SELF_MARKER.atlas)
    local file = probe:GetTexture()
    if not file or file == "" then selfMarkerInline = false; return nil end
    selfMarkerInline = string.format(
        "|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t",
        file, SELF_MARKER.display, SELF_MARKER.display,
        SELF_MARKER.refSize, SELF_MARKER.refSize,
        SELF_MARKER.L, SELF_MARKER.R, SELF_MARKER.T, SELF_MARKER.B)
    return selfMarkerInline
end

-- Default direction per sort key. Used to decide whether to reverse the
-- list returned by Roster:Sorted (which always returns the default order).
local SORT_DEFAULT_DIR = {
    name  = "asc",
    class = "asc",
    level = "desc",
    ep    = "desc",
    gp    = "desc",
    pr    = "desc",
}

-- Sort direction indicator: a small atlas icon attached to each header
-- button, shown only on the active sort column. The atlas points up by
-- default; for descending we flip it 180° via SetTexCoord (swap L↔R and
-- T↔B) — equivalent to rotation for a 4-corner UV remap.
local ARROW_ATLAS = "rotating-minimapguidearrow"
local ARROW_UV    = { L = 0.541992, R = 0.573242, T = 0.936523, B = 0.967773 }
local arrowFile   -- nil = unprobed, false = SetAtlas unsupported, string = file path

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
    -- Anchor next to the button's label text, regardless of LEFT/RIGHT
    -- justification. GetFontString returns the Button's primary text
    -- FontString, which auto-positions based on its justify setting.
    -- The atlas slice has transparent padding around the arrow shape, so
    -- a small negative offset overlaps that padding with the label edge
    -- and visually tucks the glyph closer.
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

local function passesFilters(entry)
    if filters.hasPROnly and (entry.ep or 0) <= 0 and (entry.gp or 0) <= 0 then return false end
    if filters.onlineOnly and not entry.online then return false end
    if filters.search ~= "" then
        local needle = filters.search:lower()
        local nameHit  = entry.name  and entry.name:lower():find(needle, 1, true)
        local classHit = entry.class and entry.class:lower():find(needle, 1, true)
        if not nameHit and not classHit then return false end
    end
    return true
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

-- Two independent toggles drive coloring:
--   classColorsInStandings → controls the Class column only.
--   colorNameByClass       → controls Name + Rank columns together.
-- Default behavior keeps Name (and therefore Rank) in the standard yellow
-- of GameFontNormalSmall; the new toggle in the Display tab opts in to
-- class-tinted names.
local function classColorOf(classFile)
    if not classFile then return nil end
    return addon.CLASS_COLORS[classFile]
end

local function isClassColorOnInClass()
    return not (addon.DB and addon.DB.profile and addon.DB.profile.classColorsInStandings == false)
end

local function isClassColorOnInName()
    return addon.DB and addon.DB.profile and addon.DB.profile.colorNameByClass and true or false
end

local function ColorClassName(localized, classFile)
    if not isClassColorOnInClass() then return localized or "" end
    local col = classColorOf(classFile)
    if not col then return localized or "" end
    return string.format("|cFF%s%s|r", col, localized or "")
end

-- Rank tracks the Name column's color. Default font color (yellow) when
-- online, gray when offline; class color when colorNameByClass is on.
local function ColorRank(rankNum, entry)
    local text = tostring(rankNum) .. "."
    if not entry.online then
        return "|cFF888888" .. text .. "|r"
    end
    if isClassColorOnInName() then
        local col = classColorOf(entry.classFile)
        if col then return "|cFF" .. col .. text .. "|r" end
    end
    return text
end

-- Returns the entry name with optional class color applied. Caller layers
-- the offline-fade and any suffix annotations on top.
local function ColorName(name, entry)
    if not entry.online or not isClassColorOnInName() then return name end
    local col = classColorOf(entry.classFile)
    if not col then return name end
    return "|cFF" .. col .. name .. "|r"
end

function StandingsTab:Init(parent)
    if self.frame then return end
    self.frame = ElitismEPGPStandingsTab
    if not self.frame then return end
    self.frame:SetParent(parent)
    self.frame:SetAllPoints(parent)

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, self.frame, "ElitismEPGP_RowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", self.frame.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end

        -- Highlight bg: 60 px past each side. Two atlases:
        --   search-highlight → persistent self-row band (toggleable)
        --   search-select    → hover highlight (overrides while moused)
        -- The "default" state per row is set in Refresh based on whether
        -- it's the player's own row + the option; OnEnter/OnLeave swaps in
        -- the hover atlas and restores the default on leave.
        if row.bg then
            row.bg:ClearAllPoints()
            row.bg:SetPoint("TOPLEFT",     row, "TOPLEFT",     -60, 0)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT",  60, 0)
            row.bg:Hide()
        end
        row:SetScript("OnEnter", function(self)
            if self.bg and self.bg.SetAtlas then
                self.bg:SetAtlas("search-select")
                self.bg:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            if not self.bg then return end
            if self._isSelf and addon.DB and addon.DB.profile
               and addon.DB.profile.selfRowHighlight ~= false then
                if self.bg.SetAtlas then self.bg:SetAtlas("search-highlight") end
                self.bg:Show()
            else
                self.bg:Hide()
            end
        end)
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            if self._playerName and UI.PlayerDetailFrame and UI.PlayerDetailFrame.Open then
                UI.PlayerDetailFrame:Open(self._playerName)
            end
        end)

        rows[i] = row
    end

    if self.frame.searchFilter then
        self.frame.searchFilter:SetScript("OnTextChanged", function(eb)
            filters.search = eb:GetText() or ""
            StandingsTab:Refresh()
        end)
        if UI.Skin and UI.Skin.DecorateSearchBox then
            UI.Skin:DecorateSearchBox(self.frame.searchFilter)
        end
    end
    if self.frame.hasPRFilter then
        self.frame.hasPRFilter:SetChecked(false)
        self.frame.hasPRFilter:SetScript("OnClick", function(b)
            filters.hasPROnly = b:GetChecked() and true or false
            StandingsTab:Refresh()
        end)
    end
    if self.frame.onlineFilter then
        self.frame.onlineFilter:SetChecked(false)
        self.frame.onlineFilter:SetScript("OnClick", function(b)
            filters.onlineOnly = b:GetChecked() and true or false
            StandingsTab:Refresh()
        end)
    end

    -- Hover affordance for sortable column headers: tint the label gold while
    -- the mouse is over it so users can tell the labels are clickable.
    local function wireHeaderHover(btn)
        if not btn then return end
        btn:HookScript("OnEnter", function(self)
            local fs = self:GetFontString()
            if fs then fs:SetTextColor(1, 0.82, 0) end
        end)
        btn:HookScript("OnLeave", function(self)
            local fs = self:GetFontString()
            if fs then fs:SetTextColor(1, 1, 1) end
        end)
    end
    wireHeaderHover(self.frame.hdrRank)
    wireHeaderHover(self.frame.hdrName)
    wireHeaderHover(self.frame.hdrClass)
    wireHeaderHover(self.frame.hdrLevel)
    wireHeaderHover(self.frame.hdrEP)
    wireHeaderHover(self.frame.hdrGP)
    wireHeaderHover(self.frame.hdrPR)
end

-- Maintenance label / officer button visibility / action buttons used to
-- live in the standings footer; they were moved to the icon-tab dropdown.
-- Stub functions are kept so callers (OpenWeeklyMaintenanceDialog reaches
-- back here on success) don't need to be guarded individually.
function StandingsTab:RefreshMaintenanceLabel() end
function StandingsTab:RefreshButtonVisibility() end

function StandingsTab:OpenWeeklyMaintenanceDialog(decayMult)
    local preview = addon.Awards:WeeklyMaintenancePreview(decayMult)
    if preview.memberCount == 0 then
        addon.Print("|cFFFF6060Roster is empty — nothing to do.|r")
        return
    end
    local rankSummary = (preview.rankNames and #preview.rankNames > 0)
        and (" (" .. table.concat(preview.rankNames, ", ") .. ")")
        or ""
    local text = string.format(
        "Weekly Maintenance preview:\n\n  +25 EP to %d officer%s%s\n  -%d%% EP and GP for %d member%s\n\nAlts (notes starting with =) are skipped.\n\nProceed?",
        preview.officerCount, preview.officerCount == 1 and "" or "s",
        rankSummary,
        preview.decayPct,
        preview.memberCount, preview.memberCount == 1 and "" or "s")
    local decayMult = preview.decayMult
    addon.Dialog:Confirm({
        title  = "Weekly Maintenance",
        text   = text,
        accept = "Apply",
        OnAccept = function()
            local ok, result = addon.Awards:WeeklyMaintenance(decayMult)
            if not ok then
                addon.Print("|cFFFF6060Weekly maintenance failed:|r " .. tostring(result))
                return
            end
            addon.Print(string.format("Weekly maintenance: +25 EP to %d officers, decayed %d members by %d%%.",
                result.officerCount, result.memberCount, result.decayPct))
            if result.syncOk then
                addon.Print("Guild Info synced (Last decay timestamp updated).")
            elseif result.syncErr then
                addon.Print("|cFFFFCC00Guild Info sync skipped: " .. result.syncErr .. "|r")
            end
            for _, f in ipairs(result.officerFails) do
                addon.Print(string.format("  |cFFFF6060- officer %s: %s|r", addon.ColorName(f.name), f.err))
            end
            for _, f in ipairs(result.memberFails) do
                addon.Print(string.format("  |cFFFF6060- member %s: %s|r", addon.ColorName(f.name), f.err))
            end
            if UI.MainFrame then UI.MainFrame:Refresh() end
            if StandingsTab.RefreshMaintenanceLabel then StandingsTab:RefreshMaintenanceLabel() end
        end,
    })
end

function StandingsTab:SetSort(key)
    if not key then return end
    if key == sortKey then
        sortDir = (sortDir == "desc") and "asc" or "desc"
    else
        sortKey = key
        sortDir = SORT_DEFAULT_DIR[key] or "desc"
    end
    self:Refresh()
end

local function updateHeader(btn, label, key)
    if not btn then return end
    btn:SetText(label)
    local arrow = arrowFor(btn)
    if not arrow then return end
    if key == sortKey then
        ensureArrowFile(btn)
        if applyArrow(arrow, sortDir) then
            arrow:Show()
        else
            arrow:Hide()
        end
    else
        arrow:Hide()
    end
end

function StandingsTab:Refresh()
    if not self.frame then return end

    -- Rank is always PR-based (rank 1 = highest PR), regardless of the
    -- column the user is currently sorting by. Build a name→rank map up
    -- front so the row loop can look it up by entry name.
    local prList = addon.Roster:Sorted("pr")
    local prRank = {}
    for i, e in ipairs(prList) do prRank[e.name] = i end

    local list = addon.Roster:Sorted(sortKey)
    -- Roster:Sorted returns the default direction for each key. If the
    -- user toggled the header to the opposite direction, reverse here.
    if sortDir ~= (SORT_DEFAULT_DIR[sortKey] or "desc") then
        local rev = {}
        for i = #list, 1, -1 do rev[#rev + 1] = list[i] end
        list = rev
    end

    -- Apply the search/checkbox filters AFTER sorting. Doing it post-sort
    -- keeps the rank column accurate (PR-rank is computed on the full
    -- roster above) and cheaper than sorting a smaller list separately.
    do
        local out = {}
        for i = 1, #list do
            if passesFilters(list[i]) then out[#out + 1] = list[i] end
        end
        list = out
    end

    local total = #list
    local scroll = self.frame.scroll

    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    updateHeader(self.frame.hdrName,  "Name",  "name")
    updateHeader(self.frame.hdrClass, "Class", "class")
    updateHeader(self.frame.hdrLevel, "Lvl",   "level")
    updateHeader(self.frame.hdrEP,    "EP",    "ep")
    updateHeader(self.frame.hdrGP,    "GP",    "gp")
    updateHeader(self.frame.hdrPR,    "PR",    "pr")

    local me = UnitName("player")
    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local entry = list[i + offset]
        if entry then
            row.rank:SetText(ColorRank(prRank[entry.name] or "?", entry))
            row.level:SetText(entry.level and tostring(entry.level) or "")
            local nameText = ColorName(entry.name, entry)
            if not entry.online then
                nameText = "|cFF888888" .. entry.name .. "|r"
            end
            if entry.altOrphan then
                nameText = nameText .. " |cFFFF6060(alt of " .. (entry.altOf or "?") .. " — main missing)|r"
            elseif entry.altOf then
                nameText = nameText .. " |cFF888888(alt of " .. entry.altOf .. ")|r"
            end
            if entry.isMock then
                nameText = nameText .. " |cFFAAAAFF(mock)|r"
            end
            if entry.name == me and not (addon.DB and addon.DB.profile and addon.DB.profile.showSelfStar == false) then
                local marker = getSelfMarker()
                nameText = nameText .. " " .. (marker or "|cFFFFCC00\226\152\133|r")
            end
            row.name:SetText(nameText)
            row.class:SetText(ColorClassName(entry.class, entry.classFile))
            row.ep:SetText(tostring(entry.ep))
            row.gp:SetText(tostring(entry.gp))
            row.pr:SetText(string.format("%.2f", entry.pr))

            row._playerName = entry.name

            -- Persistent highlight on the player's own row. The hover
            -- handler swaps to the search-select atlas while moused; this
            -- sets the resting state.
            row._isSelf = (entry.name == me)
            if row.bg and row.bg.SetAtlas then
                if row._isSelf and addon.DB and addon.DB.profile
                   and addon.DB.profile.selfRowHighlight ~= false then
                    row.bg:SetAtlas("search-highlight")
                    row.bg:Show()
                else
                    row.bg:Hide()
                end
            end

            row:Show()
        else
            row._playerName = nil
            row._isSelf = nil
            if row.bg then row.bg:Hide() end
            row:Hide()
        end
    end

    if UI.MainFrame and UI.MainFrame.SetStatus then
        local ld = addon.DB and addon.DB.global.lastDecay
        local ldText
        if ld then
            local days = math.floor((time() - ld) / 86400)
            local stamp = date("%d %b %H:%M", ld)
            if days > 8 then
                ldText = string.format("|cFFFFCC00Last decay: %s (%dd ago, overdue)|r", stamp, days)
            else
                ldText = string.format("Last decay: %s", stamp)
            end
        else
            ldText = "|cFFAAAAAALast decay: never|r"
        end
        UI.MainFrame:SetStatus(string.format(
            "%s  |  %d members  |  Sort: %s",
            ldText, total, sortKey
        ), "standings")
    end

    self:RefreshMaintenanceLabel()
    self:RefreshButtonVisibility()
end

function StandingsTab:Reload()
    if not IsInGuild() then
        if UI.MainFrame and UI.MainFrame.SetStatus then
            UI.MainFrame:SetStatus("Not in a guild.", "standings")
        end
        self:Refresh()
        return
    end
    addon.Roster:Request()
    addon.Roster:Rebuild()
    self:Refresh()
end

ElitismEPGP_StandingsTab = StandingsTab
