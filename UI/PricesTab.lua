local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local PricesTab = {}
UI.PricesTab = PricesTab

local ROW_HEIGHT   = 20
local VISIBLE_ROWS = 19
local rows = {}

-- Per-group expand state. Persists for the life of the session only;
-- groups default to collapsed.
local expanded = {}

-- Search query for the override list. Matches case-insensitively against
-- the direct item's display name (and link text). Empty string = no filter.
local searchQuery = ""

------------------------------------------------------------
-- Difficulty inference: given a member itemID and the direct/Normal id,
-- find which difficulty index this member is. Returns 1-6 or nil.
------------------------------------------------------------

local DIFFICULTY_LABEL = {
    [1] = "Bloodforged",
    [2] = "Heroic Bloodforged",
    [3] = "Normal",
    [4] = "Heroic",
    [5] = "Mythic",
    [6] = "Ascended",
}

local DIFFICULTY_COLOR = {
    [1] = "FFFF8C00", -- bloodforged: dark orange
    [2] = "FFFF8C00",
    [3] = "FFFFFFFF", -- normal: white
    [4] = "FF1EFF00", -- heroic: green
    [5] = "FF0070FF", -- mythic: blue
    [6] = "FFA335EE", -- ascended: purple
}

local function inferDifficulty(memberID, directID)
    if memberID == directID then return 3 end
    if type(GetItemDifficultyID) ~= "function" then return nil end
    for _, dif in ipairs({ 4, 5, 6, 1, 2 }) do
        if GetItemDifficultyID(directID, dif) == memberID then return dif end
    end
    return nil
end

------------------------------------------------------------
-- Init
------------------------------------------------------------

local function showRowTooltip(self)
    local link = self._itemLink
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    GameTooltip:Show()
end

local function hideRowTooltip()
    GameTooltip:Hide()
end

function PricesTab:Init(parent)
    if self.frame then return end
    local f = ElitismEPGPPricesTab
    if not f then return end
    f:SetParent(parent)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", 0, 0)
    self.frame = f

    -- Wire the popup form (lives in ElitismEPGPPriceOverrideFrame). Promoted
    -- from a side panel to a centred modal so it matches the addon's other
    -- popups (Bid Player, Award, Start/End Raid, Weekly Maintenance, ...) —
    -- same SimpleMetal chrome and StaticPopup1-anchored position.
    local popup = ElitismEPGPPriceOverrideFrame
    self.popup = popup
    if popup then
        popup.hint:SetText("Drag-shift, paste a link, or type a numeric itemID into any field. Direct GP overrides the formula; Linked treats the Item as the linked itemID (for items missing from AtlasLoot).")

        -- All three EditBoxes get the same affordances: select-on-focus and
        -- accept-dropped-item-link. linkEntry previously had neither — drag
        -- onto it silently failed.
        local function wireItemDrop(eb)
            eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
            eb:SetScript("OnReceiveDrag", function(self)
                local cursor, _, link = GetCursorInfo()
                if cursor == "item" and link then
                    self:SetText(link)
                    ClearCursor()
                end
            end)
        end
        wireItemDrop(popup.itemEntry)
        wireItemDrop(popup.linkEntry)
        -- gpEntry is numeric-only — selecting on focus still helps for fast retypes.
        popup.gpEntry:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)

        popup.setGPBtn:SetScript("OnClick",   function() PricesTab:OnSetGP()    end)
        popup.setLinkBtn:SetScript("OnClick", function() PricesTab:OnSetLinked() end)
        popup.cancelBtn:SetScript("OnClick",  function() popup:Hide() end)

        -- Skin to match the other modals: close button tucked into the corner
        -- pocket FIRST (AddCloseFiligree positions the filigree relative to the
        -- close button), then SimpleMetal border + filigree.
        if popup.closeButton then
            popup.closeButton:ClearAllPoints()
            popup.closeButton:SetPoint("TOPRIGHT", popup, "TOPRIGHT", 6, 5)
            popup.closeButton:SetSize(32, 32)
        end
        if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
            UI.Skin:ApplySimpleMetalBorder(popup)
            if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(popup) end
        end
        popup:SetFrameStrata("FULLSCREEN_DIALOG")
        popup:SetMovable(true)
        popup:SetClampedToScreen(true)
        popup:HookScript("OnShow", function(self)
            self:ClearAllPoints()
            if StaticPopup1 then
                self:SetPoint("TOP", StaticPopup1, "TOP", 0, 0)
            else
                self:SetPoint("TOP", UIParent, "TOP", 0, -135)
            end
        end)
        popup:SetScript("OnMouseDown", function(self, btn)
            if btn == "LeftButton" then self:StartMoving() end
        end)
        popup:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
        if UISpecialFrames then
            local already
            for _, n in ipairs(UISpecialFrames) do
                if n == "ElitismEPGPPriceOverrideFrame" then already = true; break end
            end
            if not already then table.insert(UISpecialFrames, "ElitismEPGPPriceOverrideFrame") end
        end
    end

    f.addOverrideBtn:SetScript("OnClick", function()
        if not popup then return end
        if popup:IsShown() then
            popup:Hide()
        else
            popup:Show()      -- OnShow re-pins to StaticPopup1
            PricesTab:OnEntryChanged()
        end
    end)

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_PriceRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end

        -- Hover highlight: same search-select atlas as standings/history,
        -- stretched 60 px past each side.
        if row.bg and row.bg.SetAtlas then
            row.bg:ClearAllPoints()
            row.bg:SetPoint("TOPLEFT",     row, "TOPLEFT",     -60, 0)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT",  60, 0)
            row.bg:SetAtlas("search-select")
            row.bg:Hide()
        end

        -- Row click: header rows toggle expand/collapse; child rows are inert
        -- (their tooltip still fires on hover).
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self, button)
            if button ~= "LeftButton" then return end
            -- Only expandable headers (those with linked variants) toggle on click.
            if self._isHeader and self._directID and self._hasMembers then
                expanded[self._directID] = not expanded[self._directID]
                PricesTab:Refresh()
            end
        end)
        row:SetScript("OnEnter", function(self)
            if self.bg then self.bg:Show() end
            showRowTooltip(self)
        end)
        row:SetScript("OnLeave", function(self)
            if self.bg then self.bg:Hide() end
            hideRowTooltip()
        end)
        -- Clear button (only meaningful on header rows; we hide it on
        -- child rows in Refresh). Clicking clears the entire group via
        -- ClearTierOverrides so all linked variants vanish too.
        row.clearButton:SetScript("OnClick", function()
            if not row._directID then return end
            addon.Prices:ClearTierOverrides(row._directID)
            expanded[row._directID] = nil
            PricesTab:Refresh()
        end)
        rows[i] = row
    end

    if f.searchFilter then
        f.searchFilter:SetScript("OnTextChanged", function(eb)
            searchQuery = (eb:GetText() or ""):lower()
            PricesTab:Refresh()
        end)
        if UI.Skin and UI.Skin.DecorateSearchBox then
            UI.Skin:DecorateSearchBox(f.searchFilter)
        end
    end
end

------------------------------------------------------------
-- Form handlers (popup — fallback for items not in AtlasLoot)
------------------------------------------------------------

local function currentEntryItemID()
    local p = ElitismEPGPPriceOverrideFrame
    if not p then return nil end
    local txt = p.itemEntry:GetText() or ""
    txt = txt:match("^%s*(.-)%s*$")
    if txt == "" then return nil end
    return addon.Prices:ItemIDFromLink(txt)
end

function PricesTab:OnEntryChanged()
    local p = ElitismEPGPPriceOverrideFrame
    if not p then return end
    local id = currentEntryItemID()
    if not id then
        p.itemPreview:SetText("|cFFAAAAAA(paste a link or itemID)|r")
        return
    end
    local desc = addon.Prices:Describe(id)
    if not desc then
        p.itemPreview:SetText(string.format("|cFFFFCC00item:%d|r |cFFAAAAAA(loading...)|r", id))
        return
    end
    local slotLabel = (addon.SLOT_LABELS and addon.SLOT_LABELS[desc.equipLoc]) or desc.equipLoc or "—"
    p.itemPreview:SetText(string.format("%s |cFFAAAAAA[ilvl %d %s]|r",
        desc.link or desc.name, desc.ilvl or 0, slotLabel))
end

function PricesTab:OnSetGP()
    local id = currentEntryItemID()
    if not id then
        if addon.Print then addon.Print("|cFFFF6060Enter an item link or itemID first.|r") end
        return
    end
    local p = ElitismEPGPPriceOverrideFrame
    local gp = tonumber(p.gpEntry:GetText() or "")
    if not gp or gp < 0 then
        if addon.Print then addon.Print("|cFFFF6060Enter a non-negative GP value.|r") end
        return
    end
    -- Use the tier-fanout helper so manual entries also auto-link variants.
    local ok, err = addon.Prices:SetTierBaseOverride(id, gp)
    if not ok then
        if addon.Print then addon.Print("|cFFFF6060SetTierBaseOverride failed:|r " .. tostring(err)) end
        return
    end
    p.gpEntry:SetText("")
    p:Hide()
    self:Refresh()
end

function PricesTab:OnSetLinked()
    local id = currentEntryItemID()
    if not id then
        if addon.Print then addon.Print("|cFFFF6060Enter an item link or itemID first.|r") end
        return
    end
    local p = ElitismEPGPPriceOverrideFrame
    local linkID = addon.Prices:ItemIDFromLink(p.linkEntry:GetText() or "")
    if not linkID then
        if addon.Print then addon.Print("|cFFFF6060Enter the linked item's ID or link.|r") end
        return
    end
    local ok, err = addon.Prices:SetLinkedOverride(id, linkID)
    if not ok then
        if addon.Print then addon.Print("|cFFFF6060SetLinkedOverride failed:|r " .. tostring(err)) end
        return
    end
    p.linkEntry:SetText("")
    p:Hide()
    self:Refresh()
end

------------------------------------------------------------
-- Group construction
--
-- A group is anchored on the "direct" item (the one with a real GP
-- override). Linked overrides become members of the group whose direct
-- they point at. Orphan linked entries (target has no direct override)
-- get their own pseudo-group keyed by the link target.
------------------------------------------------------------

local function buildGroups()
    local groups = {}
    local g = addon.DB and addon.DB.global
    if not g or not g.prices then return groups end

    for itemID, entry in pairs(g.prices) do
        if entry and entry.gp ~= nil then
            groups[itemID] = {
                directID = itemID,
                gp       = entry.gp,
                ts       = entry.ts,
                members  = {},  -- filled below
            }
        end
    end
    for itemID, entry in pairs(g.prices) do
        if entry and entry.linkedItemID ~= nil then
            local target = entry.linkedItemID
            local group = groups[target]
            if not group then
                group = { directID = target, gp = nil, ts = entry.ts, members = {}, orphan = true }
                groups[target] = group
            end
            group.members[#group.members + 1] = itemID
        end
    end
    return groups
end

local function flattenForRender()
    local groups = buildGroups()
    local headerKeys = {}
    for k in pairs(groups) do
        if searchQuery == "" then
            headerKeys[#headerKeys + 1] = k
        else
            local d = addon.Prices:Describe(k)
            local hay = ((d and d.name) or ("item:" .. k)):lower()
            if hay:find(searchQuery, 1, true) then
                headerKeys[#headerKeys + 1] = k
            end
        end
    end
    table.sort(headerKeys, function(a, b)
        local da, db = addon.Prices:Describe(a), addon.Prices:Describe(b)
        return ((da and da.name) or ("item:" .. a)) < ((db and db.name) or ("item:" .. b))
    end)

    local out = {}
    for _, directID in ipairs(headerKeys) do
        local group = groups[directID]
        out[#out + 1] = { type = "header", group = group }
        if expanded[directID] then
            local sortedMembers = {}
            for _, m in ipairs(group.members) do
                sortedMembers[#sortedMembers + 1] = { id = m, dif = inferDifficulty(m, directID) }
            end
            table.sort(sortedMembers, function(a, b)
                return (a.dif or 99) < (b.dif or 99)
            end)
            for _, mem in ipairs(sortedMembers) do
                out[#out + 1] = { type = "member", id = mem.id, dif = mem.dif, parentDirectID = directID }
            end
        end
    end
    return out
end

------------------------------------------------------------
-- Refresh — populate visible rows from the flattened list
------------------------------------------------------------

-- Expand/collapse uses Blizzard's bundled +/- button textures (used by
-- the QuestLogFrame and Friends list for the same purpose). Friz Quadrata
-- renders ▼ but not ▶/►, so a text glyph isn't reliable here.
local TEX_COLLAPSED = "Interface\\Buttons\\UI-PlusButton-UP"
local TEX_EXPANDED  = "Interface\\Buttons\\UI-MinusButton-UP"

local function setHeaderRow(row, group)
    local directID = group.directID
    local desc     = addon.Prices:Describe(directID)
    local _, _, _, _, _, _, _, _, _, iconTex = (desc and GetItemInfo(directID)) or nil
    row.icon:SetNormalTexture(iconTex or (desc and desc.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
    row.icon:Show()

    local memberCount = #group.members
    if row.expander then
        if memberCount > 0 then
            row.expander:SetTexture(expanded[directID] and TEX_EXPANDED or TEX_COLLAPSED)
            row.expander:Show()
        else
            -- No linked variants — nothing to expand into, so hide the glyph.
            row.expander:Hide()
        end
    end

    local nameText = (desc and desc.link) or string.format("item:%d", directID)
    local suffix = memberCount > 0
        and string.format(" |cFFAAAAAA(%d variants)|r", memberCount) or ""
    row.itemName:SetText(nameText .. suffix)

    if group.gp ~= nil then
        row.mode:SetText("|cFFFFFFFFNormal|r")
        row.value:SetText(string.format("|cFFFFCC00%d GP|r", group.gp))
    else
        row.mode:SetText("|cFF888888Orphan|r")
        row.value:SetText("|cFFAAAAAA(no direct)|r")
    end

    row.clearButton:Show()
    row._isHeader     = true
    row._hasMembers   = memberCount > 0
    row._directID     = directID
    row._itemLink     = desc and desc.link
    row._itemID       = directID
end

local function setMemberRow(row, mem)
    local desc = addon.Prices:Describe(mem.id)
    -- Hide icon and expander to give the indented child rows a cleaner look.
    row.icon:Hide()
    if row.expander then row.expander:Hide() end

    local label = (desc and desc.link) or string.format("item:%d", mem.id)
    -- Light indent so the variant nests visually under its header without
    -- pushing the name half-way across the row.
    row.itemName:SetText("  \226\148\148 " .. label)

    local difLabel = mem.dif and DIFFICULTY_LABEL[mem.dif] or "?"
    local difColor = mem.dif and DIFFICULTY_COLOR[mem.dif] or "FFAAAAAA"
    row.mode:SetText(string.format("|c%s%s|r", difColor, difLabel))

    local resolvedGP = addon.Prices:GetGP(mem.id)
    row.value:SetText(string.format("|cFFFFCC00%d GP|r", resolvedGP or 0))

    row.clearButton:Hide()
    row._isHeader   = false
    row._hasMembers = false
    row._directID   = nil
    row._itemLink   = desc and desc.link
    row._itemID     = mem.id
end

function PricesTab:Refresh()
    if not self.frame then return end

    local list = flattenForRender()
    local total = #list
    local scroll = self.frame.scroll
    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local entry = list[i + offset]
        if entry then
            if entry.type == "header" then
                setHeaderRow(row, entry.group)
            else
                setMemberRow(row, entry)
            end
            row:Show()
        else
            row._itemID, row._itemLink, row._directID, row._isHeader = nil, nil, nil, nil
            row:Hide()
        end
    end

    if self.frame.emptyText then
        if total == 0 then self.frame.emptyText:Show() else self.frame.emptyText:Hide() end
    end

    -- Footer summary: total direct overrides + linked variants. Counts include
    -- everything in DB.global.prices, not just the rows currently visible
    -- after a search filter (which we surface alongside when active).
    if UI.MainFrame and UI.MainFrame.SetStatus then
        local g = addon.DB and addon.DB.global
        local directs, links = 0, 0
        if g and g.prices then
            for _, entry in pairs(g.prices) do
                if entry and entry.gp ~= nil           then directs = directs + 1 end
                if entry and entry.linkedItemID ~= nil then links   = links + 1 end
            end
        end
        local headerCount = #list
        for _, row in ipairs(list) do
            if row.type ~= "header" then headerCount = headerCount - 1 end
        end
        local txt = string.format("%d direct override%s · %d linked variant%s",
            directs, directs == 1 and "" or "s",
            links,   links   == 1 and "" or "s")
        if searchQuery ~= "" then
            txt = string.format("%s · %d match%s",
                txt, headerCount, headerCount == 1 and "" or "es")
        end
        UI.MainFrame:SetStatus(txt, "prices")
    end
end

ElitismEPGP_PricesTab = PricesTab
