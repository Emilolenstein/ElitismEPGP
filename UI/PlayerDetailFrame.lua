local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local PlayerDetailFrame = {}
UI.PlayerDetailFrame = PlayerDetailFrame
ElitismEPGP_PlayerDetailFrame = PlayerDetailFrame

local ROW_HEIGHT   = 18
local VISIBLE_ROWS = 16
local rows = {}
local currentPlayer = nil

local filters = { EP = true, GP = true, DECAY = true }

local sortKey = "time"
local sortDir = "desc"
local SORT_DEFAULT_DIR = {
    time  = "desc",
    actor = "asc",
    delta = "desc",
}

-- Sort indicator: same atlas + 180° UV flip pattern as StandingsTab.
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
        if applyArrow(arrow, sortDir) then
            arrow:Show()
        else
            arrow:Hide()
        end
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
    return "OTHER"
end

local function FormatDelta(e)
    if e.kind == "Decay" then return "|cFFFFCC00decay|r" end
    if e.kind == "AltMark" or e.kind == "AltUnmark" then return "|cFF66CCFFalt|r" end
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

-- Entry pertains to the player if it credits/debits them directly, OR if
-- it credits an alt that resolves back to them.
local function EntryTouchesPlayer(e, name)
    if not e or not name then return false end
    if e.target == name then return true end
    if e.resolvedTo == name then return true end
    return false
end

local function MatchesKindFilters(e)
    local bucket = BucketOf(e.kind)
    if bucket == "EP" then return filters.EP == true end
    if bucket == "GP" then return filters.GP == true end
    if bucket == "DECAY" then return filters.DECAY == true end
    return true  -- OTHER (alt marks etc): always shown
end

local function isOfficer()
    return CanEditOfficerNote and CanEditOfficerNote()
end

local function rgbHex(r, g, b)
    return string.format("%02X%02X%02X",
        math.floor((r or 1) * 255), math.floor((g or 1) * 255), math.floor((b or 1) * 255))
end

local function classColor(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        return RAID_CLASS_COLORS[classFile]
    end
    return { r = 1, g = 1, b = 1 }
end

local function isClassColorOnInName()
    return addon.DB and addon.DB.profile and addon.DB.profile.colorNameByClass and true or false
end

local function guildRankName(rosterEntry)
    if not rosterEntry or not rosterEntry.index then return nil end
    local _, rankName = GetGuildRosterInfo(rosterEntry.index)
    return rankName
end

local function standingRank(name)
    if not (addon.Roster and addon.Roster.Sorted) then return nil end
    local list = addon.Roster:Sorted("pr")
    for i, e in ipairs(list) do
        if e.name == name then return i end
    end
    return nil
end

------------------------------------------------------------
-- Init / Open / Refresh
------------------------------------------------------------

function PlayerDetailFrame:Init()
    if self.frame then return end
    local f = ElitismEPGPPlayerDetailFrame
    if not f then return end
    self.frame = f

    -- Bookmark banner behind the avatar (3:4 aspect), extending down.
    -- ARTWORK layer so it draws above the popup's backdrop fill, but it
    -- still renders below the classIcon Button (children always draw
    -- above parent textures regardless of layer).
    if not f.banner then
        local banner = f:CreateTexture(nil, "ARTWORK")
        banner:SetAtlas("ca-bookmark-half")
        banner:SetSize(72, 76)
        banner:SetPoint("TOP", f.classIcon, "TOP", 0, -25)
        f.banner = banner

        -- Standing rank label sits on the visible portion of the banner.
        local rankText = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        rankText:SetPoint("BOTTOM", banner, "BOTTOM", 0, 28)
        f.standingRank = rankText
    end

    -- Class icon: round class disc (ARTWORK) + ring frame on top (OVERLAY).
    -- Atlases are assigned in RefreshHeader based on classFile / online state.
    if not f.classIcon.tex then
        local disc = f.classIcon:CreateTexture(nil, "ARTWORK")
        disc:SetPoint("CENTER", f.classIcon, "CENTER", 0, 0)
        disc:SetSize(46, 46)
        f.classIcon.tex = disc

        local ring = f.classIcon:CreateTexture(nil, "OVERLAY")
        ring:SetPoint("CENTER", f.classIcon, "CENTER", 0, 0)
        ring:SetSize(64, 68)
        f.classIcon.ring = ring
    end

    f.btnUpdateEP:SetScript("OnClick", function() PlayerDetailFrame:OnUpdateClick("EP") end)
    f.btnUpdateGP:SetScript("OnClick", function() PlayerDetailFrame:OnUpdateClick("GP") end)

    if f.btnWhisper then
        f.btnWhisper:SetScript("OnClick", function()
            if not currentPlayer then return end
            ChatFrame_OpenChat("/w " .. currentPlayer .. " ")
        end)
    end
    if f.btnInvite then
        f.btnInvite:SetScript("OnClick", function()
            if not currentPlayer then return end
            if InviteUnit then InviteUnit(currentPlayer) end
        end)
    end

    local function wireKind(btn, key)
        btn:SetChecked(true)
        btn:SetScript("OnClick", function(b)
            filters[key] = b:GetChecked() and true or false
            PlayerDetailFrame:Refresh()
        end)
    end
    wireKind(f.kindEP,    "EP")
    wireKind(f.kindGP,    "GP")
    wireKind(f.kindDecay, "DECAY")

    -- Hover affordance for sortable column headers (matches StandingsTab).
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
    wireHeaderHover(f.hdrTime)
    wireHeaderHover(f.hdrActor)
    wireHeaderHover(f.hdrDelta)

    for i = 1, VISIBLE_ROWS do
        local row = CreateFrame("Frame", nil, f, "ElitismEPGP_PlayerHistoryRowTemplate")
        if i == 1 then
            row:SetPoint("TOPLEFT", f.scroll, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", rows[i - 1], "BOTTOMLEFT")
        end

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
            if self.bg then self.bg:Hide() end
        end)

        rows[i] = row
    end

    -- Live refresh when a new history entry is logged.
    if addon.Awards and addon.Awards.OnLogAppend then
        addon.Awards:OnLogAppend(function()
            if PlayerDetailFrame.frame and PlayerDetailFrame.frame:IsShown() then
                PlayerDetailFrame:Refresh()
            end
        end)
    end
end

function PlayerDetailFrame:Open(name)
    if not name then return end
    if not self.frame then self:Init() end
    if not self.frame then return end
    currentPlayer = name
    self:RefreshHeader()
    self:Refresh()
    if UI.MainFrame and UI.MainFrame.OpenSidePopup then
        UI.MainFrame:OpenSidePopup(self.frame)
    else
        self.frame:Show()
    end
end

function PlayerDetailFrame:RefreshHeader()
    local f = self.frame
    if not f or not currentPlayer then return end

    local entry = addon.Roster and addon.Roster.Get and addon.Roster:Get(currentPlayer)
    local cf    = entry and entry.classFile
    local color = classColor(cf)

    -- Round class disc.
    if f.classIcon.tex then
        if cf then
            f.classIcon.tex:SetAtlas("class-round-" .. string.lower(cf))
            f.classIcon.tex:Show()
        else
            f.classIcon.tex:Hide()
        end
    end

    -- Ring frame: online vs offline variant.
    if f.classIcon.ring then
        local online = entry and entry.online and true or false
        f.classIcon.ring:SetAtlas(online and "talents-warmode-ring" or "talents-warmode-ring-disabled")
        f.classIcon.ring:Show()
    end

    -- Name: class-colored only when online AND the colorNameByClass toggle is on.
    local online = entry and entry.online and true or false
    if online and isClassColorOnInName() then
        f.playerName:SetText(string.format("|cFF%s%s|r", rgbHex(color.r, color.g, color.b), currentPlayer))
    else
        f.playerName:SetText(currentPlayer)
    end

    -- Single info line: "<GuildRank> • Level <N>". Class is conveyed by the icon.
    local lvl = entry and entry.level and ("Level " .. entry.level) or "Level ?"
    local gr  = guildRankName(entry) or "?"
    f.lvlClass:SetText(gr .. " |c99FFFFFF•|r " .. lvl)
    if f.ranks then f.ranks:Hide() end

    -- Standing rank sits on the banner.
    local sr = standingRank(currentPlayer)
    if f.standingRank then
        f.standingRank:SetText(sr and ("#" .. sr) or "#?")
    end

    -- Officers get Update EP/GP; everyone else gets Whisper/Invite in the
    -- same slot.
    if isOfficer() then
        f.btnUpdateEP:Show()
        f.btnUpdateGP:Show()
        if f.btnWhisper then f.btnWhisper:Hide() end
        if f.btnInvite  then f.btnInvite:Hide()  end
    else
        f.btnUpdateEP:Hide()
        f.btnUpdateGP:Hide()
        if f.btnWhisper then f.btnWhisper:Show() end
        if f.btnInvite  then f.btnInvite:Show()  end
    end
end

function PlayerDetailFrame:SetSort(key)
    if not key then return end
    if key == sortKey then
        sortDir = (sortDir == "desc") and "asc" or "desc"
    else
        sortKey = key
        sortDir = SORT_DEFAULT_DIR[key] or "desc"
    end
    self:Refresh()
end

-- Numeric magnitude of an entry's point delta — used so EP/GP awards can
-- be ranked together on the Points column. Decay/alt rows fall back to 0.
local function deltaMagnitude(e)
    if (e.dEP or 0) ~= 0 then return e.dEP end
    if (e.dGP or 0) ~= 0 then return e.dGP end
    return 0
end

local function compareEntries(a, b)
    local desc = (sortDir == "desc")
    if sortKey == "actor" then
        local na, nb = a.actor or "", b.actor or ""
        if na ~= nb then
            if desc then return na > nb end
            return na < nb
        end
        local ta, tb = a.ts or 0, b.ts or 0
        return ta > tb -- stable secondary: newest first
    elseif sortKey == "delta" then
        local da, db = deltaMagnitude(a), deltaMagnitude(b)
        if da ~= db then
            if desc then return da > db end
            return da < db
        end
        local ta, tb = a.ts or 0, b.ts or 0
        return ta > tb
    end
    -- default: time
    local ta, tb = a.ts or 0, b.ts or 0
    if desc then return ta > tb end
    return ta < tb
end

function PlayerDetailFrame:Refresh()
    if not self.frame or not currentPlayer then return end

    local h = (addon.Awards and addon.Awards.GetHistory) and addon.Awards:GetHistory() or {}
    local list = {}
    for i = 1, #h do
        local e = h[i]
        if EntryTouchesPlayer(e, currentPlayer) and MatchesKindFilters(e) then
            list[#list + 1] = e
        end
    end
    table.sort(list, compareEntries)

    local total = #list
    local scroll = self.frame.scroll
    FauxScrollFrame_Update(scroll, total, VISIBLE_ROWS, ROW_HEIGHT)
    local offset = FauxScrollFrame_GetOffset(scroll)

    updateHeader(self.frame.hdrTime,  "time")
    updateHeader(self.frame.hdrActor, "actor")
    updateHeader(self.frame.hdrDelta, "delta")

    for i = 1, VISIBLE_ROWS do
        local row = rows[i]
        local e   = list[i + offset]
        if e then
            row.time:SetText(date("%m-%d %H:%M", e.ts or 0))
            row.actor:SetText(e.actor or "?")
            row.delta:SetText(FormatDelta(e))
            row.reason:SetText(FormatReason(e))
            row:Show()
        else
            row:Hide()
        end
    end

    if self.frame.summary then
        self.frame.summary:SetText(string.format("%d entr%s",
            total, total == 1 and "y" or "ies"))
    end
end

------------------------------------------------------------
-- Update EP / Update GP — open a small input dialog and apply.
------------------------------------------------------------

function PlayerDetailFrame:OnUpdateClick(kind)
    if not currentPlayer then return end
    if not isOfficer() then return end
    local target = currentPlayer
    addon.Dialog:Prompt({
        title   = "Award " .. kind,
        text    = string.format("Award %s to %s — enter signed amount (e.g. +10 or -5):", kind, target),
        letters = 8,
        accept  = "Award",
        OnAccept = function(text)
            local amount = tonumber(text)
            if not amount or amount == 0 then
                if addon.Print then addon.Print("|cFFFF6060Invalid amount.|r") end
                return
            end
            if kind == "EP" then
                addon.Awards:GiveEP(target, amount, addon.Awards.Kind.EP_CUSTOM, "")
            else
                addon.Awards:GiveGP(target, amount, addon.Awards.Kind.GP_CUSTOM, "")
            end
            addon.Awards:AnnounceAwarded("Custom", amount, kind, { target })
            if PlayerDetailFrame.Refresh then PlayerDetailFrame:Refresh() end
        end,
    })
end
