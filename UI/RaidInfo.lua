local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local RaidInfo = {}
UI.RaidInfo = RaidInfo

local ROW_HEIGHT   = 16
local VISIBLE_ROWS = 13   -- 13 * 16 = 208px, fits the 216px-tall scroll viewport
local rows = {}

-- Column sorting (same UX as the main window's Standings/History tabs).
local sortKey, sortDir = "name", "asc"
local SORT_DEFAULT_DIR = { name = "asc", class = "asc" }

-- Top-right search box: case-insensitive substring match on name / class.
local searchFilter = ""

local function ColorClassName(localized, classFile, level)
    local levelSuffix = level and (" " .. level) or ""
    if not classFile or not addon.CLASS_COLORS[classFile] then
        return (localized or "") .. levelSuffix
    end
    return string.format("|cFF%s%s|r%s", addon.CLASS_COLORS[classFile], localized, levelSuffix)
end

local function CollectTargets()
    if UI.RaidManager and UI.RaidManager.GetTargets then
        return UI.RaidManager:GetTargets()
    end
    return addon.Awards:RaidPlusStandby()
end

function RaidInfo:Init()
    if self.frame then return end
    local f = ElitismEPGPRaidInfoFrame
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
        UI.Skin:WireSortHeader(f.hdrName)
        UI.Skin:WireSortHeader(f.hdrClass)
    end

    if f.searchFilter then
        f.searchFilter:SetScript("OnTextChanged", function(eb)
            searchFilter = eb:GetText() or ""
            RaidInfo:Refresh()
        end)
        if UI.Skin and UI.Skin.DecorateSearchBox then
            UI.Skin:DecorateSearchBox(f.searchFilter)
        end
    end

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_RaidInfoRowTemplate")
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
        -- Left-click a player → the Award menu, scoped to just that player.
        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self._playerName
               and UI.RaidManager and UI.RaidManager.OpenPlayerAwardMenu then
                UI.RaidManager:OpenPlayerAwardMenu(self._playerName)
            end
        end)
        rows[i] = row
    end
end

function RaidInfo:AnchorBeside(rmFrame)
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

function RaidInfo:SetSort(key)
    if not key then return end
    if key == sortKey then
        sortDir = (sortDir == "asc") and "desc" or "asc"
    else
        sortKey = key
        sortDir = SORT_DEFAULT_DIR[key] or "asc"
    end
    self:Refresh()
end

-- Build the display list (name + roster entry), sorted per the active
-- column. "~" sentinels push players with no roster entry (not in guild)
-- to the bottom in ascending order; ties always break by name ascending.
local function buildSortedList()
    local names = CollectTargets()
    local needle = (searchFilter ~= "") and searchFilter:lower() or nil
    local list = {}
    for _, name in ipairs(names) do
        local entry = addon.Roster:Get(name)
        if not needle
           or name:lower():find(needle, 1, true)
           or (entry and entry.class and entry.class:lower():find(needle, 1, true)) then
            list[#list + 1] = { name = name, entry = entry }
        end
    end
    local asc = (sortDir == "asc")
    table.sort(list, function(a, b)
        if sortKey == "class" then
            local ac = ((a.entry and a.entry.class) or "~"):lower()
            local bc = ((b.entry and b.entry.class) or "~"):lower()
            if ac ~= bc then
                if asc then return ac < bc else return ac > bc end
            end
        end
        local an, bn = a.name:lower(), b.name:lower()
        if an == bn then return false end
        if asc then return an < bn else return an > bn end
    end)
    return list
end

function RaidInfo:Refresh()
    if not self.frame then return end
    local list = buildSortedList()
    local total = #list
    local scroll = self.frame.scroll

    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    if UI.Skin and UI.Skin.UpdateSortArrow then
        UI.Skin:UpdateSortArrow(self.frame.hdrName,  sortKey == "name",  sortDir)
        UI.Skin:UpdateSortArrow(self.frame.hdrClass, sortKey == "class", sortDir)
    end

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local item = list[i + offset]
        if item then
            local name, entry = item.name, item.entry
            row._playerName = name
            if entry then
                local nameText = name
                if not entry.online then
                    nameText = "|cFF888888" .. name .. " (offline)|r"
                end
                row.player:SetText(nameText)
                row.class:SetText(ColorClassName(entry.class, entry.classFile, entry.level))
            else
                row.player:SetText(name)
                row.class:SetText("|cFFFF6060not in guild|r")
            end
            row:Show()
        else
            row._playerName = nil
            row:Hide()
        end
    end

    if self.frame.summary then
        self.frame.summary:SetText(string.format("%d recipient%s", total, total == 1 and "" or "s"))
    end
end

function RaidInfo:Open(rmFrame)
    if not self.frame then self:Init() end
    if not self.frame then return end
    -- The Players and Session Log panels are mutually exclusive — opening
    -- one closes the other.
    if UI.SessionLogs and UI.SessionLogs.frame then UI.SessionLogs.frame:Hide() end
    self.frame:Show()
    self:Refresh()
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    elseif rmFrame then
        self:AnchorBeside(rmFrame)
    end
end

function RaidInfo:Close()
    if self.frame then self.frame:Hide() end
    if UI.RaidManager and UI.RaidManager.LayoutSidePanels then
        UI.RaidManager:LayoutSidePanels()
    end
end

function RaidInfo:Toggle(rmFrame)
    if not self.frame then self:Init() end
    if not self.frame then return end
    if self.frame:IsShown() then
        self:Close()
    else
        self:Open(rmFrame)
    end
end

ElitismEPGP_RaidInfo = RaidInfo
