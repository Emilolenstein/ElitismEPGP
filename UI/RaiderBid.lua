local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local RaiderBid = {}
UI.RaiderBid = RaiderBid

local function FormatTime(seconds)
    seconds = math.max(0, math.floor(seconds + 0.5))
    return string.format("0:%02d", seconds)
end

local function CurrentItemID(self)
    return self._itemID
end

-- Rarity frame around the item icon, keyed by item quality. Only blue (3),
-- epic (4) and legendary (5) get one — green/white/grey loot stays bare.
-- Values are atlas slices for Skin:PaintAtlasSlice (LootToast item borders).
local QUALITY_ICON_BORDER = {
    [3] = { atlas = "loottoast-itemborder-blue",   L = 0.729492, R = 0.786133, T = 0.425781, B = 0.539062 },
    [4] = { atlas = "loottoast-itemborder-purple", L = 0.272461, R = 0.329102, T = 0.703125, B = 0.816406 },
    [5] = { atlas = "loottoast-itemborder-orange", L = 0.272461, R = 0.329102, T = 0.585938, B = 0.699219 },
}

-- "You're winning this" badge laid over the item icon (both views). Shown
-- only while your live MS/OS bid currently holds top PR in its tier; if it's
-- not there when the timer runs out, you very likely didn't win. Atlas slice
-- for Skin:PaintAtlasSlice (quest "available" wrapper marker).
-- TODO(art): swap this slice for the supplied winner icon.
local WINNER_ICON = { atlas = "quest-wrapper-available", L = 0.641602, R = 0.672852, T = 0.538086, B = 0.569336 }

------------------------------------------------------------
-- Init
------------------------------------------------------------

local function setItemTooltip(self)
    local r = UI.RaiderBid
    if not r or not r._itemLink then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(r._itemLink)
    -- If the "you're winning" badge is up, explain what it means right on the
    -- item tooltip (the badge frame itself is click-through, so the icon
    -- hover is where this naturally lands).
    if r.frame and r.frame.winnerIcon and r.frame.winnerIcon:IsShown() then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("You're holding this", 0.25, 1, 0.25)
        GameTooltip:AddLine("Highest priority of the bids so far. If this badge is gone when the timer ends, someone outbid you.", 0.9, 0.9, 0.9, true)
    end
    GameTooltip:Show()
end

local function clearTooltip()
    GameTooltip:Hide()
end

function RaiderBid:Init()
    if self.frame then return end
    local f = ElitismEPGPRaiderBidFrame
    if not f then return end
    self.frame = f

    -- Remember the expanded-layout placement of the item icon (relative to
    -- the frame) so Restore can put it back after Minimize re-anchors it for
    -- the collapsed card. (Skip the GetPoint relativeTo slot — it's the
    -- parent frame; re-using `f` avoids a nil-hole in a packed table.)
    do
        local p, _, rp, x, y = f.itemIcon:GetPoint(1)
        self._expIcon = { p = p or "TOPLEFT", rp = rp or p or "TOPLEFT", x = x or 0, y = y or 0 }
    end

    -- Same chrome as the Raid Manager / side panels: SimpleMetal border
    -- (default scale, close-button corner pocket), bgOpacity-driven dark bg.
    -- The popup has no close X by design (ESC mustn't dismiss a live bid),
    -- so the top-right control is the Raid Manager's post-start red-refresh
    -- "toggle" button — here it minimizes the popup (the minimized icon
    -- restores it). Re-skin the minimize button to that look + tuck it into
    -- the SimpleMetal corner pocket where a close button would sit.
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
    end
    do
        local mb = f.minimizeButton
        if mb then
            mb:SetSize(20, 20)
            mb:ClearAllPoints()
            mb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1.5, -1)
            local nt, pt = mb:GetNormalTexture(), mb:GetPushedTexture()
            if nt and nt.SetAtlas then nt:SetAtlas("128-redbutton-refresh") end
            if pt and pt.SetAtlas then pt:SetAtlas("128-redbutton-refresh-pressed") end
            local hl = mb:GetHighlightTexture()
            if hl then
                hl:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
                hl:SetTexCoord(0, 1, 0, 1)
                hl:SetBlendMode("ADD")
            end
        end
    end
    -- AddCloseFiligree anchors to frame.closeButton; the popup has none, so
    -- point that key at the toggle button for the decorative trim. Then
    -- re-anchor it straight to the frame's TOPRIGHT at (-20, 1) — the exact
    -- spot it lands on the BLW / side panels (whose close button is a 32×32
    -- UIPanelCloseButton at TOPRIGHT 6,5; the toggle here is smaller/more
    -- inset, so the helper's button-relative offset would land it wrong).
    if UI.Skin and UI.Skin.AddCloseFiligree then
        f.closeButton = f.minimizeButton
        UI.Skin:AddCloseFiligree(f)
        if f.closeFiligree then
            f.closeFiligree:ClearAllPoints()
            f.closeFiligree:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, 1)
        end
    end

    -- Fancy ui-frame-bar-* countdown bar (replaces the old plain StatusBar).
    -- Lives in the top row alongside the small timerText label, left of it.
    -- Its colour (blue→yellow→red) is driven by value internally, so the
    -- ticker only feeds it SetValue.
    if UI.Skin and UI.Skin.CreateProgressBar then
        -- Same 215 px width as the row, but scaled down from the textures'
        -- native 31 px height (caps shrink proportionally; the centre stretches
        -- to keep the total width). solidColor: stays blue, no value ramp.
        local EXP_BAR_W = 215
        local pb = UI.Skin:CreateProgressBar(f, { width = EXP_BAR_W, height = 16, solidColor = true })
        if pb then
            pb:ClearAllPoints()
            pb:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -5)
            f.timerBar = pb
            -- Expanded-layout placement/width, restored by RaiderBid:Restore
            -- after Minimize narrows + re-anchors it for the collapsed card.
            local p, _, rp, x, y = pb:GetPoint(1)
            self._expBar = { p = p or "TOPLEFT", rp = rp or p or "TOPLEFT", x = x or 0, y = y or 0, w = EXP_BAR_W }
        end
    end

    -- Rarity frame: pin it to a small outset around the item icon so it
    -- tracks the icon's position/size (the LootToast border art frames the
    -- icon with a bit of overhang). The XML anchor is a placeholder; this
    -- two-point anchor overrides it.
    if f.itemIconBorder and f.itemIcon then
        f.itemIconBorder:ClearAllPoints()
        f.itemIconBorder:SetPoint("TOPLEFT",     f.itemIcon, "TOPLEFT",     -3,  3)
        f.itemIconBorder:SetPoint("BOTTOMRIGHT", f.itemIcon, "BOTTOMRIGHT",  3, -3)
    end

    -- "You're winning" badge pinned to the item icon's top-middle edge — the
    -- badge's own centre sits on that edge (half on, half off the icon). It
    -- lives in its own little child frame with a bumped frame level so it
    -- draws above the item icon, the rarity frame, and the mouseover / restore
    -- hit-rects covering the icon (a plain OVERLAY region on `f` would still
    -- render under those child frames). Anchored to itemIcon so it rides along
    -- when Minimize/Restore re-anchor the icon. Painted once; shown/hidden
    -- (via the frame) by RefreshStatus.
    if f.itemIcon and not f.winnerIcon then
        local wf = CreateFrame("Frame", nil, f)
        wf:SetFrameLevel(f:GetFrameLevel() + 5)
        wf:SetSize(20, 20)
        wf:SetPoint("CENTER", f.itemIcon, "TOP", 0, 0)
        local tex = wf:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints(wf)
        if UI.Skin and UI.Skin.PaintAtlasSlice then
            UI.Skin:PaintAtlasSlice(tex, WINNER_ICON)
        end
        wf:Hide()
        f.winnerIcon = wf
    end

    -- Bump the item-name label a touch past the GameFontHighlight (12pt) it
    -- inherits — keep the same font face/flags, just a larger point size.
    if f.itemName then
        local file, _, flags = f.itemName:GetFont()
        if file then f.itemName:SetFont(file, 14, flags) end
    end
    -- Likewise nudge the "ilvl N • <bid status>" row up from GameFontDisableSmall (10pt).
    if f.itemMeta then
        local file, _, flags = f.itemMeta:GetFont()
        if file then f.itemMeta:SetFont(file, 12, flags) end
    end
    -- Collapsed-only bid-action label: a touch above GameFontHighlightSmall (10pt).
    if f.minBidAction then
        local file, _, flags = f.minBidAction:GetFont()
        if file then f.minBidAction:SetFont(file, 11, flags) end
    end
    -- Collapsed-only shadow strip behind that label so it reads against the
    -- busy item icon (a thin UI-Frame "disabled subtitle" gradient). Created
    -- here, parented/positioned/shown in Minimize, hidden in Restore.
    if not f.minBidShadow then
        f.minBidShadow = f:CreateTexture(nil, "ARTWORK")
        f.minBidShadow:SetSize(80, 22)
        if UI.Skin and UI.Skin.PaintAtlasSlice then
            UI.Skin:PaintAtlasSlice(f.minBidShadow, {
                atlas = "UI-Frame-Alliance-DisableSubtitle",
                L = 0.000976562, R = 0.203125, T = 0.851562, B = 0.880859 })
        end
        f.minBidShadow:Hide()
    end


    f.itemMouseover:SetScript("OnEnter", setItemTooltip)
    f.itemMouseover:SetScript("OnLeave", clearTooltip)
    -- Clicking the item icon while expanded collapses the popup — mirrors the
    -- collapsed card, where clicking the icon (restoreButton) expands it. Give
    -- it the same square ADD-blend hover glow restoreButton has so the icon
    -- reads as clickable in both states.
    f.itemMouseover:SetScript("OnClick", function() RaiderBid:Minimize() end)
    f.itemMouseover:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

    f.btnNeed:SetScript ("OnClick", function() RaiderBid:Submit("ms")   end)
    f.btnGreed:SetScript("OnClick", function() RaiderBid:Submit("os")   end)
    f.btnPass:SetScript ("OnClick", function() RaiderBid:Submit("pass") end)

    -- Same look as the pre-raid Raid Manager "Select…" pickers
    -- (auctionhouse-nav-button-secondary bg + hover), minus the dropdown
    -- arrow since these are action buttons, not menus — noArrow centres
    -- the label and shows the select-state overlay while pressed. Each
    -- gets a small left icon (raw UVs into the atlas's sheet) so the
    -- option reads at a glance: green upgrade arrow / gold hammer / a
    -- "leave it" stablemaster glyph.
    if UI.Skin and UI.Skin.SkinDropdownButton then
        UI.Skin:SkinDropdownButton(f.btnNeed,  { noArrow = true,
            icon = { atlas = "upgradeitem-32x32",  L = 0.774414, R = 0.805664, T = 0.604492, B = 0.635742 } })
        UI.Skin:SkinDropdownButton(f.btnGreed, { noArrow = true,
            icon = { atlas = "vehicle-hammergold", L = 0.608398, R = 0.639648, T = 0.670898, B = 0.702148 } })
        UI.Skin:SkinDropdownButton(f.btnPass,  { noArrow = true, groupNudgeX = -1,
            icon = { atlas = "stablemaster",       L = 0.874023, R = 0.905273, T = 0.571289, B = 0.602539 } })
    end

    -- The red-refresh corner button toggles collapse/expand (it's shown in
    -- both states); clicking the minimized icon also expands.
    f.minimizeButton:SetScript("OnClick", function()
        if RaiderBid._minimized then RaiderBid:Restore() else RaiderBid:Minimize() end
    end)
    f.restoreButton:SetScript ("OnClick", function() RaiderBid:Restore() end)
    -- Show item tooltip when hovering the minimized icon, too.
    f.restoreButton:SetScript("OnEnter", setItemTooltip)
    f.restoreButton:SetScript("OnLeave", clearTooltip)

    -- Tick frame for the countdown.
    local ticker = CreateFrame("Frame", nil, f)
    local acc = 0
    ticker:SetScript("OnUpdate", function(_, dt)
        acc = acc + dt
        if acc < 0.1 then return end
        acc = 0
        if not f:IsShown() then return end
        local remaining = (RaiderBid._timeoutAt or 0) - GetTime()
        -- Plain white "0:NN" — no low-time colour transition (the fonts are
        -- white in both states).
        local label = FormatTime(math.max(0, remaining))
        f.timerText:SetText(label)
        f.minTimer:SetText(label)
        local total = RaiderBid._totalTime or 1
        local ratio = math.max(0, math.min(1, remaining / total))
        -- Fancy bar (both states): solidColor, so it stays blue regardless of value.
        if f.timerBar then f.timerBar:SetValue(ratio) end
        if remaining <= 0 then
            RaiderBid:Hide()
        end
    end)

    -- Intentionally NOT registered in UISpecialFrames — ESC must not dismiss
    -- the popup; the only "get-it-out-of-my-face" affordance is Minimize.
end

------------------------------------------------------------
-- Show / Hide
------------------------------------------------------------

local CHOICE_LABEL = {
    ms   = "|cFF55FF55Mainspec|r",
    os   = "|cFFFFCC66Offspec|r",
    pass = "|cFFAAAAAAPass|r",
}

function RaiderBid:RefreshStatus()
    if not self.frame then return end
    local status, action
    if self._currentChoice then
        local label = CHOICE_LABEL[self._currentChoice] or self._currentChoice
        status = "|cFFFFFFFFYour bid:|r " .. label
        action = label                       -- collapsed view: just the action word
    else
        status = "|cFFAAAAAANo bid yet.|r"
        action = ""                          -- collapsed view: blank until they pick
    end
    -- Expanded: "ilvl N" (white label / yellow number) • bid status, on the item row.
    if self.frame.itemMeta then
        self.frame.itemMeta:SetText(string.format(
            "|cFFFFFFFFilvl|r |cFFFFCC00%d|r  |cFF808080•|r  %s", self._ilvl or 0, status))
    end
    -- Collapsed: the bare action over the icon, on its shadow strip. Both
    -- only appear once a choice is in (action == "" otherwise).
    if self.frame.minBidAction then self.frame.minBidAction:SetText(action) end
    if self.frame.minBidShadow then
        if self._minimized and self._currentChoice then
            self.frame.minBidShadow:Show()
        else
            self.frame.minBidShadow:Hide()
        end
    end
    -- "You're winning" badge over the item icon: live MS/OS bid that currently
    -- holds top PR (self._leader == us). Nothing for Pass / no bid / not yet
    -- leading — if it isn't showing when the timer ends, you probably lost.
    if self.frame.winnerIcon then
        local winning = (self._currentChoice == "ms" or self._currentChoice == "os")
            and self._leader and self._leader == UnitName("player")
        if winning then self.frame.winnerIcon:Show() else self.frame.winnerIcon:Hide() end
    end
end

-- Sync the Need/Greed/Pass buttons' "checked" state to self._currentChoice
-- (radio-button group — exactly one or none checked). The checked button
-- shows the select overlay and stops reacting to hover.
function RaiderBid:RefreshChoiceButtons()
    local f = self.frame
    if not f then return end
    local byChoice = { ms = f.btnNeed, os = f.btnGreed, pass = f.btnPass }
    for choice, btn in pairs(byChoice) do
        if btn and btn.eepgpSetChecked then btn.eepgpSetChecked(self._currentChoice == choice) end
    end
end

-- Element groups toggled between the expanded and collapsed states. The
-- item icon + its rarity border, the fancy countdown bar, and the
-- red-refresh corner toggle live in BOTH states (just re-anchored), so
-- they're in neither list — Minimize/Restore reposition them by hand.
local COLLAPSED_W, COLLAPSED_H = 90, 102
local COLLAPSED_BAR_W          = 70

local EXPANDED_ONLY_REGIONS = { "itemName", "itemMeta", "timerText" }
local EXPANDED_ONLY_FRAMES  = { "itemMouseover", "btnNeed", "btnGreed", "btnPass" }
local COLLAPSED_ONLY_REGIONS = { "minTimer", "minBidAction" }
local COLLAPSED_ONLY_FRAMES  = { "restoreButton" }

-- Show/hide the SimpleMetal border (corners + edges) and the close-button
-- filigree as a set. Kept shown in BOTH states now — the collapsed card is
-- sized large enough (COLLAPSED_W × COLLAPSED_H) for the 60px corners.
local function setMetalChromeShown(f, shown)
    local metal = f.eepgpSimpleMetalBorder
    if metal then
        for _, set in ipairs({ metal.corners, metal.edges }) do
            for _, t in pairs(set) do if shown then t:Show() else t:Hide() end end
        end
    end
    if f.closeFiligree then if shown then f.closeFiligree:Show() else f.closeFiligree:Hide() end end
end

function RaiderBid:Minimize()
    if not self.frame or self._minimized then return end
    self._minimized = true
    local f = self.frame
    for _, key in ipairs(EXPANDED_ONLY_REGIONS) do if f[key] then f[key]:Hide() end end
    for _, key in ipairs(EXPANDED_ONLY_FRAMES)  do if f[key] then f[key]:Hide() end end

    -- Compact card: icon (with rarity border) centred near the top, the
    -- fancy countdown bar below it, then the countdown text and the bid
    -- action stacked under that.
    f.itemIcon:ClearAllPoints()
    f.itemIcon:SetPoint("TOP", f, "TOP", 0, -25)
    if f.restoreButton then
        f.restoreButton:ClearAllPoints()
        f.restoreButton:SetSize(f.itemIcon:GetWidth(), f.itemIcon:GetHeight())
        f.restoreButton:SetPoint("TOPLEFT", f.itemIcon, "TOPLEFT", 0, 0)
        f.restoreButton:SetNormalTexture("")   -- the real itemIcon shows; this is just the click/hover area
    end
    if f.timerBar then
        if f.timerBar.SetBarWidth then f.timerBar:SetBarWidth(COLLAPSED_BAR_W) end
        f.timerBar:ClearAllPoints()
        f.timerBar:SetPoint("TOP", f.itemIcon, "BOTTOM", 0, -10)
    end
    -- Countdown text overlays the loading bar, centred on it. Re-parent it
    -- onto the bar frame (on its OVERLAY layer) so it draws ON TOP of the
    -- bar's fill/handle rather than behind it (the bar is a child frame, so
    -- a region on `f` would always render below it).
    f.minTimer:ClearAllPoints()
    f.minTimer:SetJustifyH("CENTER")
    if f.timerBar then
        f.minTimer:SetParent(f.timerBar)
        f.minTimer:SetDrawLayer("OVERLAY")
        f.minTimer:SetPoint("CENTER", f.timerBar, "CENTER", 0, 0)
    else
        f.minTimer:SetParent(f)
        f.minTimer:SetPoint("TOP", f, "TOP", 0, -3)
    end
    if f.minBidAction then
        -- Bid action hangs BELOW the whole collapsed card (centred, a few px
        -- under the bottom edge) with its shadow strip behind it — keeps it
        -- clear of the cramped icon/bar stack packed inside the card.
        f.minBidAction:ClearAllPoints()
        f.minBidAction:SetJustifyH("CENTER")
        f.minBidAction:SetParent(f)
        f.minBidAction:SetDrawLayer("OVERLAY", 7)
        f.minBidAction:SetPoint("TOP", f, "BOTTOM", 0, -3)
        -- Shadow strip behind the label (lower layer so the text sits on top),
        -- centred on it; RefreshStatus shows/hides it with the label.
        if f.minBidShadow then
            f.minBidShadow:SetParent(f)
            f.minBidShadow:SetDrawLayer("BORDER")
            f.minBidShadow:ClearAllPoints()
            f.minBidShadow:SetPoint("CENTER", f.minBidAction, "CENTER", 0, 0)
        end
    end

    for _, key in ipairs(COLLAPSED_ONLY_REGIONS) do if f[key] then f[key]:Show() end end
    for _, key in ipairs(COLLAPSED_ONLY_FRAMES)  do if f[key] then f[key]:Show() end end
    self:RefreshStatus()           -- refresh minBidAction text for this item/bid
    f:SetSize(COLLAPSED_W, COLLAPSED_H)
end

function RaiderBid:Restore()
    if not self.frame or not self._minimized then return end
    self._minimized = false
    local f = self.frame
    f:SetSize(320, 126)
    for _, key in ipairs(COLLAPSED_ONLY_REGIONS) do if f[key] then f[key]:Hide() end end
    for _, key in ipairs(COLLAPSED_ONLY_FRAMES)  do if f[key] then f[key]:Hide() end end
    -- Undo the collapsed-state re-parents (minTimer → bar, minBidAction → restoreButton).
    if f.minTimer then f.minTimer:SetParent(f); f.minTimer:SetDrawLayer("ARTWORK") end
    if f.minBidAction then f.minBidAction:SetParent(f); f.minBidAction:SetDrawLayer("ARTWORK") end
    if f.minBidShadow then f.minBidShadow:Hide(); f.minBidShadow:SetParent(f); f.minBidShadow:SetDrawLayer("ARTWORK") end

    -- Put the shared widgets back where the expanded layout wants them.
    f.itemIcon:ClearAllPoints()
    if self._expIcon then
        f.itemIcon:SetPoint(self._expIcon.p, f, self._expIcon.rp, self._expIcon.x, self._expIcon.y)
    end
    if f.timerBar and self._expBar then
        if f.timerBar.SetBarWidth then f.timerBar:SetBarWidth(self._expBar.w) end
        f.timerBar:ClearAllPoints()
        f.timerBar:SetPoint(self._expBar.p, f, self._expBar.rp, self._expBar.x, self._expBar.y)
    end

    for _, key in ipairs(EXPANDED_ONLY_REGIONS) do if f[key] then f[key]:Show() end end
    for _, key in ipairs(EXPANDED_ONLY_FRAMES)  do if f[key] then f[key]:Show() end end
    setMetalChromeShown(f, true)
    self:_ApplyIconBorder()       -- re-assert the rarity frame against the current item
    self:RefreshChoiceButtons()   -- re-assert the checked option
end

-- Show + paint the rarity frame around the item icon for the current item.
-- Only blue (3) / epic (4) / legendary (5) get a frame; everything else
-- (and an unresolved atlas) leaves it hidden. Pass `desc` to skip a
-- re-Describe of self._itemLink.
function RaiderBid:_ApplyIconBorder(desc)
    local f = self.frame
    if not f or not f.itemIconBorder then return end
    if desc == nil and self._itemLink and addon.Prices and addon.Prices.Describe then
        desc = addon.Prices:Describe(self._itemLink)
    end
    local slice = QUALITY_ICON_BORDER[(desc and desc.quality) or 0]
    if slice and UI.Skin and UI.Skin.PaintAtlasSlice and UI.Skin:PaintAtlasSlice(f.itemIconBorder, slice) then
        f.itemIconBorder:Show()
    else
        f.itemIconBorder:Hide()
    end
end

function RaiderBid:Show(itemLink, gp, timeoutSec, openerName)
    if not self.frame then self:Init() end
    if not self.frame then return end

    local newItemID = (addon.Prices and addon.Prices.ItemIDFromLink and addon.Prices:ItemIDFromLink(itemLink)) or nil
    -- A re-announce of the item we're already showing ("Bid Again" on the ML)
    -- keeps the raider's current pick + the leader flag; anything else is a
    -- fresh popup and resets them.
    local sameItem = self.frame:IsShown() and newItemID and self._itemID == newItemID
    if not sameItem then
        self._currentChoice = nil
        self._leader        = nil   -- updated by SetLeader on BID_LEAD packets
    end

    self._itemLink = itemLink
    self._gp       = tonumber(gp) or 0
    self._opener   = openerName
    local total = tonumber(timeoutSec) or 60
    self._openedAt  = GetTime()
    self._totalTime = total
    self._timeoutAt = GetTime() + total
    self._itemID   = newItemID

    -- New popup always starts expanded.
    if self._minimized then self:Restore() end

    -- Populate display from GetItemInfo if cached; otherwise update on the fly.
    local desc = addon.Prices and addon.Prices.Describe and addon.Prices:Describe(itemLink)
    self.frame.itemIcon:SetTexture((desc and desc.icon) or "Interface\\Icons\\INV_Misc_QuestionMark")
    self:_ApplyIconBorder(desc)
    self.frame.itemName:SetText(itemLink or (desc and desc.name) or "?")
    self._ilvl = (desc and desc.ilvl) or 0   -- RefreshStatus folds this into itemMeta

    self:RefreshStatus()           -- builds itemMeta = "ilvl N • <bid status>"
    self:RefreshChoiceButtons()    -- fresh item → no bid yet → all three unchecked
    self.frame:Show()
    if PlaySound then PlaySound("igMainMenuOpen") end
end

function RaiderBid:Hide()
    if self.frame then self.frame:Hide() end
    self._itemLink, self._gp, self._opener, self._timeoutAt, self._itemID, self._currentChoice, self._leader =
        nil, nil, nil, nil, nil, nil, nil
end

-- ML broadcast: `name` currently holds the item (highest PR, MS tier first);
-- "" means no bids yet. We only keep it; RefreshStatus turns it into the
-- win/lose glyph next to our own bid (no other names are shown).
function RaiderBid:SetLeader(itemID, name)
    if not self.frame then return end
    if not self._itemID or self._itemID ~= itemID then return end
    self._leader = (name and name ~= "") and name or nil
    self:RefreshStatus()
end

-- Called when an incoming CLOSE_BID matches the item we're showing.
function RaiderBid:HideForItem(itemID)
    if not self.frame or not self.frame:IsShown() then return end
    if self._itemID and itemID and self._itemID == itemID then
        self:Hide()
    end
end

-- Called when ML hits +30s. Both numerator (remaining) and denominator
-- (total) grow by addSeconds, so the bar fills back up proportionally.
function RaiderBid:Extend(itemID, addSeconds)
    if not self.frame or not self.frame:IsShown() then return end
    if self._itemID ~= itemID then return end
    local add = tonumber(addSeconds) or 0
    if add <= 0 then return end
    self._timeoutAt = (self._timeoutAt or GetTime()) + add
    self._totalTime = (self._totalTime or 60) + add
end

------------------------------------------------------------
-- Submit a bid back to the opener via AceComm whisper. The chosen button
-- becomes "checked" and the popup stays open — the raider can switch to a
-- different option until the timer ends (each switch re-sends).
------------------------------------------------------------

function RaiderBid:Submit(choice)
    if not self.frame or not self.frame:IsShown() then return end
    if not self._itemID or not self._opener then return end
    -- Re-clicking the same choice is a no-op (don't spam the ML's comm).
    if self._currentChoice == choice then return end

    if addon.Loot and addon.Loot.SendBidResponse then
        addon.Loot:SendBidResponse(self._itemID, choice, self._opener)
    end
    self._currentChoice = choice
    self:RefreshStatus()          -- the popup itself shows the picked option
    self:RefreshChoiceButtons()   -- check the chosen button, uncheck the others
end

ElitismEPGP_RaiderBid = RaiderBid
