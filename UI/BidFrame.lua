local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local BidFrame = {}
UI.BidFrame = BidFrame

local ROW_HEIGHT   = 20
local VISIBLE_ROWS = 12
local rows = {}

local CHOICE_SHORT = {
    ms   = "|cFF55FF55MS|r",
    os   = "|cFFFFCC66OS|r",
    bank = "|cFF888888Bank|r",
    pass = "|cFFAAAAAAPass|r",
}

local function ColorClassName(name, classFile)
    if not classFile or not addon.CLASS_COLORS or not addon.CLASS_COLORS[classFile] then
        return name or "?"
    end
    return string.format("|cFF%s%s|r", addon.CLASS_COLORS[classFile], name)
end

local function FormatTime(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("0:%02d", seconds)
end

-- Rarity frame around the item icon, keyed by item quality — only blue (3) /
-- epic (4) / legendary (5) get one. Atlas slices for Skin:PaintAtlasSlice
-- (same LootToast item borders the loot-bid popup uses).
local QUALITY_ICON_BORDER = {
    [3] = { atlas = "loottoast-itemborder-blue",   L = 0.729492, R = 0.786133, T = 0.425781, B = 0.539062 },
    [4] = { atlas = "loottoast-itemborder-purple", L = 0.272461, R = 0.329102, T = 0.703125, B = 0.816406 },
    [5] = { atlas = "loottoast-itemborder-orange", L = 0.272461, R = 0.329102, T = 0.585938, B = 0.699219 },
}

-- Winner badge shown inline (right of the leader's name) in the bid list —
-- same quest-wrapper-available atlas as the loot popup, same |T|t-escape
-- pattern as the standings list's "this is you" marker. Probe the atlas's
-- underlying file once, then build the inline-texture string with a
-- reference texture size that decodes the normalized UVs into whole pixels
-- (the engine only cares about the L/refSize ratio, so the value just needs
-- to be consistent).
local WINNER_MARKER = {
    atlas   = "quest-wrapper-available",
    refSize = 2048,
    L = 1314, R = 1378, T = 1102, B = 1166,
    display = 14,  -- screen px, sized to match the small-font glyph
}
local winnerMarkerInline   -- nil = unprobed, false = unsupported, string = ready
local function getWinnerMarker()
    if winnerMarkerInline ~= nil then return winnerMarkerInline or nil end
    local probe = UIParent:CreateTexture(nil, "BACKGROUND")
    probe:Hide()
    if not probe.SetAtlas then winnerMarkerInline = false; return nil end
    probe:SetAtlas(WINNER_MARKER.atlas)
    local file = probe:GetTexture()
    if not file or file == "" then winnerMarkerInline = false; return nil end
    winnerMarkerInline = string.format(
        "|T%s:%d:%d:0:0:%d:%d:%d:%d:%d:%d|t",
        file, WINNER_MARKER.display, WINNER_MARKER.display,
        WINNER_MARKER.refSize, WINNER_MARKER.refSize,
        WINNER_MARKER.L, WINNER_MARKER.R, WINNER_MARKER.T, WINNER_MARKER.B)
    return winnerMarkerInline
end

------------------------------------------------------------
-- Init
------------------------------------------------------------

local function setItemTooltip(self)
    local s = addon.Loot and addon.Loot:GetSession()
    if not s or not s.link then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(s.link)
    GameTooltip:Show()
end

local function clearTooltip()
    GameTooltip:Hide()
end

function BidFrame:Init()
    if self.frame then return end
    local f = ElitismEPGPBidFrame
    if not f then return end
    self.frame = f

    -- Same chrome as the Raid Manager / side panels: SimpleMetal border
    -- (default scale, close-button corner pocket), decorative filigree by
    -- the close button, bgOpacity-driven dark bg (the metal border's
    -- stripOriginalEdge swaps the XML dialog-border backdrop for that).
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
        if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(f) end
    end

    self:RestorePos()

    -- Rarity frame: pin it to a small outset around the item icon so it tracks
    -- the icon's position/size; Refresh paints/hides it per item quality.
    if f.itemIconBorder and f.itemIcon then
        f.itemIconBorder:ClearAllPoints()
        f.itemIconBorder:SetPoint("TOPLEFT",     f.itemIcon, "TOPLEFT",     -3,  3)
        f.itemIconBorder:SetPoint("BOTTOMRIGHT", f.itemIcon, "BOTTOMRIGHT",  3, -3)
    end

    -- Fancy ui-frame-bar-* countdown bar, same as the loot-bid popup: stays
    -- blue (solidColor — no value ramp); the ticker only feeds it SetValue.
    if UI.Skin and UI.Skin.CreateProgressBar then
        local pb = UI.Skin:CreateProgressBar(f, { width = 352, height = 16, solidColor = true })
        if pb then
            pb:ClearAllPoints()
            pb:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -70)
            f.timerBar = pb
        end
    end

    -- One horizontal divider in the footer (silver SimpleMetal edge art, same
    -- scale as the window border) above the Bid Again / Cancel row. ARTWORK
    -- sublayer -1 so it rides above the dark bg but below the labels and the
    -- metal border.
    do
        local div = f:CreateTexture(nil, "ARTWORK", nil, -1)
        div:SetPoint("BOTTOMLEFT",  f, "BOTTOMLEFT",  0, -5)
        div:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, -5)
        div:SetHeight(60)
        if div.SetAtlas then div:SetAtlas("_UI-Frame-SimpleMetal-EdgeTop") end
        f.dividerButtons = div
    end

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Button", nil, f, "ElitismEPGP_BidRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end
        row.awardButton:SetScript("OnClick", function()
            if not row._bidder then return end
            BidFrame:OnAwardClick(row._bidder)
        end)
        -- Hover band: same "search-select" atlas the standings rows use.
        -- Outset ±12 so the visible band covers the row plus its column gutters.
        if row.bg then
            row.bg:ClearAllPoints()
            row.bg:SetPoint("TOPLEFT",     row, "TOPLEFT",     -30, 0)
            row.bg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT",  30, 0)
            row.bg:Hide()
        end
        row:SetScript("OnEnter", function(self)
            if self.bg and self.bg.SetAtlas then
                self.bg:SetAtlas("search-select")
                self.bg:Show()
            end
            if self._bidder and self._bidder.altOf then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self._bidder.name)
                GameTooltip:AddLine("|cFF888888alt of " .. self._bidder.altOf .. "|r")
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            if self.bg then self.bg:Hide() end
            GameTooltip:Hide()
        end)
        rows[i] = row
    end

    f.itemMouseover:SetScript("OnEnter", setItemTooltip)
    f.itemMouseover:SetScript("OnLeave", clearTooltip)

    -- "Bid Again" re-broadcasts the loot popup to raiders (recorded bids stand,
    -- timer restarts); "Bid Player" opens the add-bid modal (records a manual
    -- bid for a named raider); "Cancel" closes the session with no award (the
    -- old Pass behaviour); the corner X cancels too.
    f.btnAgain:SetScript  ("OnClick", function() if addon.Loot then addon.Loot:Reannounce() end end)
    f.btnAddBid:SetScript ("OnClick", function() BidFrame:OpenAddBidDialog() end)
    f.btnCancel:SetScript ("OnClick", function() if addon.Loot then addon.Loot:PassSession() end end)
    f.closeButton:SetScript("OnClick", function() if addon.Loot then addon.Loot:CancelSession("closed") end end)

    -- Wire the add-bid modal (same chrome / position pattern as the Raid
    -- Manager's custom-award popup). Lives in BidFrame.xml; opened by the
    -- "Bid Player" footer button.
    local m = ElitismEPGPAddBidFrame
    if m then
        if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
            UI.Skin:ApplySimpleMetalBorder(m)
            if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(m) end
        end
        m.btnMS:SetScript     ("OnClick", function() BidFrame:ApplyAddBid("ms") end)
        m.btnOS:SetScript     ("OnClick", function() BidFrame:ApplyAddBid("os") end)
        m.btnCancel:SetScript ("OnClick", function() m:Hide() end)
        m.closeButton:SetScript("OnClick", function() m:Hide() end)
        m.nameEdit:SetScript  ("OnEnterPressed", function() BidFrame:ApplyAddBid("ms") end)
        -- ESC closes the modal (and only the modal — BidFrame stays open).
        if UISpecialFrames then
            local already
            for _, n in ipairs(UISpecialFrames) do
                if n == "ElitismEPGPAddBidFrame" then already = true; break end
            end
            if not already then table.insert(UISpecialFrames, "ElitismEPGPAddBidFrame") end
        end
    end

    -- Smooth the countdown: the shared Loot tick only fires every 0.5s, so the
    -- bar (and the "(m:ss)" in the title) would visibly step. A local ~20 fps
    -- OnUpdate keeps them moving between full Refreshes. The bidder list / stats
    -- still come from Refresh on session events.
    do
        local ticker = CreateFrame("Frame", nil, f)
        local acc = 0
        ticker:SetScript("OnUpdate", function(_, dt)
            acc = acc + dt
            if acc < 0.05 then return end
            acc = 0
            if not f:IsShown() then return end
            if addon.Loot and addon.Loot:GetSession() then
                BidFrame:_PaintTimer(addon.Loot:GetTimeRemaining())
            end
        end)
    end

    -- Intentionally NOT registered in UISpecialFrames: Escape must not touch
    -- the bid-list window (it would silently Hide() it mid-session and would
    -- swallow the keypress so the game menu never opens). The officer closes
    -- it with the X (which cancels the session) — like the raider popup.

    if addon.Loot and addon.Loot.Subscribe then
        addon.Loot:Subscribe(function(event, session, ...) BidFrame:OnSessionEvent(event, session, ...) end)
    end
end

------------------------------------------------------------
-- Position memory
------------------------------------------------------------

function BidFrame:SavePos()
    if not self.frame or not addon.DB then return end
    local point, _, relPoint, x, y = self.frame:GetPoint()
    addon.DB.profile.bidFramePos = { point = point, relPoint = relPoint, x = x, y = y }
end

function BidFrame:RestorePos()
    if not self.frame or not addon.DB then return end
    local pos = addon.DB.profile.bidFramePos
    if not pos then return end
    self.frame:ClearAllPoints()
    self.frame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or pos.point or "CENTER", pos.x or 0, pos.y or 0)
end

------------------------------------------------------------
-- Add-bid modal
------------------------------------------------------------

-- Open the add-bid popup at the StaticPopup1 spot (the XML OnShow re-pins
-- there) with the name field cleared and focused. Used by the "Bid Player"
-- footer button.
function BidFrame:OpenAddBidDialog()
    local m = ElitismEPGPAddBidFrame
    if not m then return end
    if not (addon.Loot and addon.Loot:GetSession()) then
        if addon.Print then addon.Print("|cFFAAAAAANo active bid session.|r") end
        return
    end
    m.nameEdit:SetText("")
    m:Show()
    m.nameEdit:SetFocus()
end

-- Read the name from the modal, record a manual bid for the given choice,
-- and hide the modal. Title-cases the name (Foo).
function BidFrame:ApplyAddBid(choice)
    local m = ElitismEPGPAddBidFrame
    if not m or not addon.Loot then return end
    local name = (m.nameEdit:GetText() or ""):match("^%s*(.-)%s*$")
    if name == "" then
        if addon.Print then addon.Print("|cFFFF6060Enter a player name first.|r") end
        return
    end
    name = name:sub(1, 1):upper() .. name:sub(2):lower()
    local ok, err = addon.Loot:AddBid(name, choice or "ms", "manual")
    if not ok then
        if addon.Print then addon.Print("|cFFFF6060Add bid failed:|r " .. tostring(err)) end
        return
    end
    m:Hide()
end

------------------------------------------------------------
-- Award flow
------------------------------------------------------------

function BidFrame:OnAwardClick(bidder)
    if not addon.Loot then return end
    local s = addon.Loot:GetSession()
    if not s then return end
    local cost = addon.Loot:CostForChoice(bidder.choice)
    local name, choice = bidder.name, bidder.choice
    addon.Dialog:Confirm({
        title  = "Confirm Award",
        text   = string.format("Award %s\nto %s (%s) for %d GP?",
            s.link or s.name or "?", name,
            addon.Loot.ChoiceLabel[choice] or choice, cost),
        accept = "Award",
        OnAccept = function() addon.Loot:Award(name, choice) end,
    })
end

------------------------------------------------------------
-- Refresh
------------------------------------------------------------

-- Repaint just the time-driven bits — the countdown bar fill and the
-- "(m:ss)" tacked onto the title line. Called from Refresh and (much more
-- often) from the local smoothing ticker, so the bar drains continuously
-- rather than in 0.5s steps. Uses the bidder-count prefix cached by Refresh.
function BidFrame:_PaintTimer(secs)
    local f = self.frame
    if not f then return end
    local s = addon.Loot and addon.Loot:GetSession()
    if not s then return end
    secs = secs or addon.Loot:GetTimeRemaining()
    if f.timerBar then
        local span = (s.timeoutAt or 0) - (s.openedAt or 0)
        f.timerBar:SetValue(span > 0 and math.max(0, math.min(1, secs / span)) or 0)
    end
    if f.bidStatTop then
        f.bidStatTop:SetText(string.format("%s  |cFFFFFFFF(%s)|r",
            self._whoText or "", FormatTime(secs)))
    end
end

function BidFrame:Refresh()
    if not self.frame then return end
    local s = addon.Loot and addon.Loot:GetSession()
    if not s then
        self.frame:Hide()
        return
    end

    local f = self.frame
    f.itemIcon:SetTexture(s.icon or "Interface\\Icons\\INV_Misc_QuestionMark")

    -- Rarity frame around the icon (blue / epic / legendary only).
    if f.itemIconBorder then
        local slice = QUALITY_ICON_BORDER[s.quality or 0]
        if slice and UI.Skin and UI.Skin.PaintAtlasSlice and UI.Skin:PaintAtlasSlice(f.itemIconBorder, slice) then
            f.itemIconBorder:Show()
        else
            f.itemIconBorder:Hide()
        end
    end

    local list  = addon.Loot:GetBidders()
    local total = #list   -- includes passes (shown in the list, below offspec)

    -- Count actual bidders (MS + OS) and passes separately; passes are shown
    -- below the offspec group but don't count toward the "bidding" total or
    -- the leader.
    local nms, nos, npass = 0, 0, 0
    local lead
    for _, b in ipairs(list) do
        if     b.choice == "ms"   then nms = nms + 1; lead = lead or b
        elseif b.choice == "os"   then nos = nos + 1; lead = lead or b
        elseif b.choice == "pass" then npass = npass + 1 end
    end
    local bidding = nms + nos

    -- Title line prefix: "N / M bidding" — non-pass bidders vs. raid size.
    -- Cached so the smoothing ticker can rebuild the line with the live countdown.
    local raidN = (GetNumRaidMembers and GetNumRaidMembers()) or 0
    self._whoText = raidN > 0
        and string.format("|cFFFFD200%d|r / %d bidding", bidding, raidN)
        or  string.format("|cFFFFD200%d|r bidding", bidding)
    self:_PaintTimer(addon.Loot:GetTimeRemaining())

    -- Details line: the MS/OS split with each spec's GP cost. The leader is
    -- flagged with the winner badge on their row instead (no room here). MS GP
    -- gets the yellow hilite so its cost reads as the headline number.
    local osCost = addon.Prices and addon.Prices:OffSpecGP(s.gp) or 0
    if bidding > 0 then
        f.bidStatBot:SetText(string.format(
            "%d Mainspec (|cFFFFD200%d|r GP)  |cFF808080•|r  %d Offspec (|cFFFFD200%d|r GP)",
            nms, s.gp or 0, nos, osCost))
    else
        f.bidStatBot:SetText(string.format(
            "Mainspec |cFFFFD200%d|r GP  |cFF808080•|r  Offspec |cFFFFD200%d|r GP  |cFF808080•|r  |cFF888888no bids yet|r",
            s.gp or 0, osCost))
    end

    local scroll = f.scroll
    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local b = list[i + offset]
        if b then
            local nameText = ColorClassName(b.name, b.classFile)
            if b == lead then
                local marker = getWinnerMarker()
                if marker then nameText = nameText .. " " .. marker end
            end
            row.player:SetText(nameText)
            local choiceText = CHOICE_SHORT[b.choice] or b.choice
            if b.source == "whisper" then choiceText = choiceText .. " |cFFFF80FF(w)|r" end
            row.choice:SetText(choiceText)
            row.pr:SetText(string.format("%.2f", b.pr))
            if b.choice == "pass" then
                row.awardButton:Disable()    -- you don't award an item to a passer
            else
                row.awardButton:Enable()
            end
            row._bidder = b
            row:Show()
        else
            row._bidder = nil
            row:Hide()
        end
    end

    if f.emptyText then
        if total == 0 then f.emptyText:Show() else f.emptyText:Hide() end
    end
end

------------------------------------------------------------
-- Session events
------------------------------------------------------------

function BidFrame:OnSessionEvent(event, session, ...)
    if not self.frame then return end
    if event == "OPEN" then
        self.frame:Show()
        self:Refresh()
        if PlaySound then PlaySound("igMainMenuOpen") end
    elseif event == "AWARD" or event == "CANCEL" or event == "PASS" then
        self.frame:Hide()
    elseif event == "BIDDERS" or event == "TICK" or event == "TIMEOUT" then
        self:Refresh()
    end
end

function BidFrame:Open()
    if not self.frame then self:Init() end
    if not self.frame then return end
    self.frame:Show()
    self:Refresh()
end

function BidFrame:Reopen()
    -- Re-show an existing-session panel that was hidden via ESC.
    if not self.frame then self:Init() end
    if not self.frame then return end
    if not (addon.Loot and addon.Loot:GetSession()) then
        addon.Print("|cFFAAAAAANo active bid session to show.|r")
        return
    end
    self.frame:Show()
    self:Refresh()
end

function BidFrame:Close()
    if self.frame then self.frame:Hide() end
end

ElitismEPGP_BidFrame = BidFrame
