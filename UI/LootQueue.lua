local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local LootQueue = {}
UI.LootQueue = LootQueue

local QUALITY_THRESHOLD = 4 -- Epic+ only.
local MAX_ROWS = 6
local TOP_PAD, ROW_PITCH, BOTTOM_PAD = 36, 28, 32

local rows = {}

------------------------------------------------------------
-- Position memory
------------------------------------------------------------

function LootQueue:SavePos()
    if not self.frame or not addon.DB then return end
    local point, _, relPoint, x, y = self.frame:GetPoint()
    addon.DB.profile.lootQueuePos = { point = point, relPoint = relPoint, x = x, y = y }
end

function LootQueue:RestorePos()
    if not self.frame or not addon.DB then return end
    local pos = addon.DB.profile.lootQueuePos
    if not pos then return end
    self.frame:ClearAllPoints()
    self.frame:SetPoint(pos.point or "TOP", UIParent, pos.relPoint or pos.point or "TOP",
        pos.x or 0, pos.y or -200)
end

------------------------------------------------------------
-- Init / row construction
------------------------------------------------------------

function LootQueue:Init()
    if self.frame then return end
    local f = ElitismEPGPLootQueueFrame
    if not f then return end
    self.frame = f

    self:RestorePos()

    f.closeButton:SetScript("OnClick", function() f:Hide() end)

    for i = 1, MAX_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_LootQueueRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT", 0, -2)
        end
        row.bidButton:SetScript("OnClick", function()
            if not row._link then return end
            -- row._slot is nil for dev-test rows; OnBidClick handles that.
            LootQueue:OnBidClick(row._slot, row._link)
        end)
        row.icon:SetScript("OnEnter", function(self)
            if not row._link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(row._link)
            GameTooltip:Show()
        end)
        row.icon:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[i] = row
    end

    -- React to bid session lifecycle so the per-row Bid button disables
    -- while a session is active for that exact item.
    local refreshOnSession = function(event)
        if event == "OPEN" or event == "AWARD" or event == "CANCEL" or event == "PASS" then
            LootQueue:Refresh()
        end
    end
    if addon.Loot and addon.Loot.Subscribe then addon.Loot:Subscribe(refreshOnSession) end
end

------------------------------------------------------------
-- Refresh from current loot window contents
------------------------------------------------------------

local function collectEpicSlots()
    local out = {}
    local n = (GetNumLootItems and GetNumLootItems()) or 0
    if n == 0 then return out end
    for slot = 1, n do
        -- 3.3.5a: GetLootSlotInfo returns texture, item, quantity, quality, locked
        local _, _, _, quality = GetLootSlotInfo(slot)
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        if quality and quality >= QUALITY_THRESHOLD and link and link:match("item:%d+") then
            out[#out + 1] = { slot = slot, link = link, quality = quality }
        end
    end
    return out
end

function LootQueue:Refresh()
    if not self.frame then return end

    -- Master loot only — other loot methods don't have GiveMasterLoot semantics.
    local method = GetLootMethod and GetLootMethod()
    local isML   = IsMasterLooter and IsMasterLooter()
    if method ~= "master" or not isML then
        self.frame:Hide()
        return
    end

    local items = collectEpicSlots()
    if #items == 0 then
        self.frame:Hide()
        return
    end

    self.frame.title:SetText(string.format("Master Loot Queue (%d)", #items))

    local bidLink
    if addon.Loot and addon.Loot:GetSession() then
        bidLink = addon.Loot:GetSession().lootSlotLink
    end

    local shown = 0
    for i = 1, MAX_ROWS do
        local row = rows[i]
        local item = items[i]
        if item then
            local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(item.link)
            row.icon:SetNormalTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.itemName:SetText(item.link)
            row._slot = item.slot
            row._link = item.link
            if bidLink and bidLink == item.link then
                row.bidButton:SetText("...")
                row.bidButton:Disable()
            else
                row.bidButton:SetText("Bid")
                row.bidButton:Enable()
            end
            row:Show()
            shown = shown + 1
        else
            row._slot, row._link = nil, nil
            row:Hide()
        end
    end

    self.frame:SetHeight(TOP_PAD + shown * ROW_PITCH + BOTTOM_PAD)
    self.frame:Show()
end

------------------------------------------------------------
-- Bid click → open session with lootSlot context
------------------------------------------------------------

function LootQueue:OnBidClick(slot, link)
    if not addon.Loot then return end

    local devActive = addon.Dev and addon.Dev:IsActive()
    if not devActive then
        if not (addon.CanRunBidSession and addon.CanRunBidSession()) then
            addon.Print("|cFFFF6060You don't have permission to run a bid session.|r")
            return
        end
        if not (addon.RaidSession and addon.RaidSession:IsActive()) then
            addon.Print("|cFFFF6060Start Raid first — bid sessions require an active session.|r")
            return
        end
    end

    local s = addon.Loot:GetSession()
    if s then
        addon.Print("|cFFFFCC00Finish the current bid first.|r")
        return
    end

    local opts = { opener = UnitName("player") }

    if slot then
        -- Real loot window: re-resolve the slot's link in case items shifted
        -- after another item left the loot window.
        local liveLink = GetLootSlotLink and GetLootSlotLink(slot)
        if liveLink ~= link then
            addon.Print("|cFFFFCC00Loot window changed — try again.|r")
            self:Refresh()
            return
        end
        opts.lootSlot     = slot
        opts.lootSlotLink = link
    end
    -- slot==nil happens for dev-test rows; session opens like a regular
    -- modifier-click bid (no GiveMasterLoot path on Award).

    local ok, err = addon.Loot:OpenSession(link, opts)
    if not ok then
        addon.Print("|cFFFF6060Bid open failed:|r " .. tostring(err))
    end
end

------------------------------------------------------------
-- Dev preview: pop the panel with caller-supplied item links so the UI
-- can be verified without an actual master-loot scenario. Rows have no
-- lootSlot, so the bid flow falls through to manual-trade messaging.
------------------------------------------------------------

function LootQueue:DevShow(links)
    if not self.frame then self:Init() end
    if not self.frame or not links or #links == 0 then return end

    self.frame.title:SetText(string.format("Master Loot Queue (%d) [dev]", #links))

    local bidLink
    if addon.Loot and addon.Loot:GetSession() then bidLink = addon.Loot:GetSession().link end

    local shown = 0
    for i = 1, MAX_ROWS do
        local row = rows[i]
        local link = links[i]
        if link then
            local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(link)
            row.icon:SetNormalTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            row.itemName:SetText(link)
            row._slot = nil
            row._link = link
            if bidLink == link then
                row.bidButton:SetText("...")
                row.bidButton:Disable()
            else
                row.bidButton:SetText("Bid")
                row.bidButton:Enable()
            end
            row:Show()
            shown = shown + 1
        else
            row._slot, row._link = nil, nil
            row:Hide()
        end
    end

    self.frame:SetHeight(TOP_PAD + shown * ROW_PITCH + BOTTOM_PAD)
    self.frame:Show()
end

------------------------------------------------------------
-- Event wiring
------------------------------------------------------------

local watchFrame = CreateFrame("Frame")
watchFrame:RegisterEvent("LOOT_OPENED")
watchFrame:RegisterEvent("LOOT_CLOSED")
watchFrame:RegisterEvent("LOOT_SLOT_CLEARED")
watchFrame:SetScript("OnEvent", function(_, event)
    if event == "LOOT_CLOSED" then
        if LootQueue.frame then LootQueue.frame:Hide() end
        return
    end
    -- Defer one frame to let GetItemInfo populate icons for newly seen items.
    if not LootQueue.frame then return end
    LootQueue:Refresh()
end)

ElitismEPGP_LootQueue = LootQueue
