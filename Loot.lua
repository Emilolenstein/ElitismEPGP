local _, addon = ...

local Loot = {}
addon.Loot = Loot

local AceComm = LibStub("AceComm-3.0")
AceComm:Embed(Loot)

-- Single active bid session at a time. Multi-item queue can come later.

-- Field separator for AceComm payloads. \1 (SOH) never appears in item links,
-- player names, or numeric fields, so a simple split() round-trips cleanly.
local SEP = "\1"

local function packetSplit(s)
    local out, start = {}, 1
    while true do
        local pos = s:find(SEP, start, true)
        if not pos then
            out[#out + 1] = s:sub(start)
            return out
        end
        out[#out + 1] = s:sub(start, pos - 1)
        start = pos + 1
    end
end

local function packetJoin(...)
    return table.concat({ ... }, SEP)
end

local CHOICE_MS, CHOICE_OS, CHOICE_BANK, CHOICE_PASS = "ms", "os", "bank", "pass"
Loot.Choice = { MS = CHOICE_MS, OS = CHOICE_OS, BANK = CHOICE_BANK, PASS = CHOICE_PASS }

local CHOICE_LABEL = {
    [CHOICE_MS]   = "Mainspec",
    [CHOICE_OS]   = "Offspec",
    [CHOICE_BANK] = "Bank-D/E",
    [CHOICE_PASS] = "Pass",
}
Loot.ChoiceLabel = CHOICE_LABEL

-- Sort order: MS → OS → Bank → Pass. Within each, PR descending (then EP).
-- Passes are tracked so the officer can see who explicitly opted out, but
-- they're ranked last and excluded from the leader / "bidding" count.
local CHOICE_RANK = {
    [CHOICE_MS]   = 1,
    [CHOICE_OS]   = 2,
    [CHOICE_BANK] = 3,
    [CHOICE_PASS] = 4,
}

local function bidTimeout()
    local g = addon.DB and addon.DB.global
    return (g and g.bidTimeout) or addon.VARS.bidTimeout or 60
end

local function notify(event, ...)
    if not Loot.listeners then return end
    for fn in pairs(Loot.listeners) do
        local ok, err = pcall(fn, event, ...)
        if not ok and addon.Print then
            addon.Print("|cFFFF6060Loot listener error:|r " .. tostring(err))
        end
    end
end

------------------------------------------------------------
-- Listener API (BidFrame subscribes for refreshes)
------------------------------------------------------------

function Loot:Subscribe(fn)
    self.listeners = self.listeners or {}
    self.listeners[fn] = true
end

function Loot:Unsubscribe(fn)
    if self.listeners then self.listeners[fn] = nil end
end

------------------------------------------------------------
-- Session lifecycle
------------------------------------------------------------

local startWhisperListener, stopWhisperListener  -- forward decls

function Loot:OpenSession(itemLinkOrID, opts)
    if self.session then
        return false, "a bid session is already in progress"
    end
    if not addon.Prices then
        return false, "Prices module not loaded"
    end
    local desc = addon.Prices:Describe(itemLinkOrID)
    if not desc then
        return false, "item info not yet cached — try again in a moment"
    end
    local gp = addon.Prices:GetGP(desc.itemID)
    local timeout = bidTimeout()
    self.session = {
        itemID       = desc.itemID,
        link         = desc.link,
        name         = desc.name,
        icon         = desc.icon,
        ilvl         = desc.ilvl,
        quality      = desc.quality,
        gp           = gp,
        openedAt     = GetTime(),
        timeoutAt    = GetTime() + timeout,
        bidders      = {},
        opener       = (opts and opts.opener) or UnitName("player"),
        notes        = (opts and opts.notes) or nil,
        -- Set when the session was opened from the master-loot queue.
        -- Lets Award() auto-distribute via GiveMasterLoot instead of relying
        -- on a manual trade. nil sessions (modifier-click from bags etc.)
        -- always fall back to manual-trade behavior.
        lootSlot     = opts and opts.lootSlot or nil,
        lootSlotLink = opts and opts.lootSlotLink or nil,
    }
    notify("OPEN", self.session)

    -- Broadcast to raid so addon-using raiders see a Need/Greed/Pass popup.
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) and not (opts and opts.silent) then
        self:SendCommMessage(addon.COMM_PREFIX,
            packetJoin("OPEN_BID", tostring(gp), tostring(timeout), desc.link),
            "RAID")
        -- Visible chat heads-up so raiders without the addon know they can
        -- whisper-bid. The addon-popup carries the same info for installed users.
        SendChatMessage(string.format(
            "ElitismEPGP: bid on %s (%ds) — whisper '+' for Need or '-' for Greed. No reply = pass.",
            desc.link, timeout),
            "RAID")
    end

    -- Show the raider popup for the officer too — broadcasts don't self-deliver
    -- (we filter own messages in OnCommReceived). The popup routes the bid back
    -- through SendBidResponse, which short-circuits to a local AddBid when the
    -- opener is the player themselves.
    if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.Show then
        addon.UI.RaiderBid:Show(desc.link, gp, timeout, UnitName("player"))
    end

    if startWhisperListener then startWhisperListener() end
    return true, self.session
end

-- Push the current front-runner (highest-PR bidder, MS tier first) out to the
-- raid so each raider's popup can flag "you're winning this" vs. "you're
-- outbid". Sends a single name (or "" for no bids); the name is only used
-- client-side to pick an icon, never displayed. Also applied locally for the
-- officer's own raider popup (RAID broadcasts don't self-deliver).
local function broadcastLead(self)
    local s = self.session
    if not s then return end
    local top = self:TopBidder()
    local name = (top and top.name) or ""
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        self:SendCommMessage(addon.COMM_PREFIX,
            packetJoin("BID_LEAD", tostring(s.itemID), name),
            "RAID")
    end
    if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.SetLeader then
        addon.UI.RaiderBid:SetLeader(s.itemID, name)
    end
end

local function broadcastClose(self, itemID, reason)
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        self:SendCommMessage(addon.COMM_PREFIX,
            packetJoin("CLOSE_BID", tostring(itemID), reason),
            "RAID")
    end
    -- Hide the officer's own raider popup. AceComm's RAID broadcast is
    -- filtered for self in OnCommReceived, so the local hide has to be
    -- explicit.
    if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.HideForItem then
        addon.UI.RaiderBid:HideForItem(itemID)
    end
end

function Loot:CancelSession(reason)
    if not self.session then return false end
    -- Clear before notify so listeners that call GetSession() see nil — keeps
    -- "is a session active?" UI checks (e.g. RaidManager's View Bid button)
    -- in sync with the actual state.
    local s = self.session
    self.session = nil
    broadcastClose(self, s.itemID, "cancelled")
    if stopWhisperListener then stopWhisperListener() end
    notify("CANCEL", s, reason)
    return true
end

function Loot:PassSession()
    if not self.session then return false end
    local s = self.session
    self.session = nil
    broadcastClose(self, s.itemID, "passed")
    if stopWhisperListener then stopWhisperListener() end
    notify("PASS", s)
    return true
end

function Loot:GetSession() return self.session end

function Loot:GetTimeRemaining()
    if not self.session then return 0 end
    return math.max(0, self.session.timeoutAt - GetTime())
end

function Loot:ExtendTime(seconds)
    if not self.session then return end
    local add = tonumber(seconds) or 30
    self.session.timeoutAt = self.session.timeoutAt + add
    notify("TICK", self.session)
    -- Tell raiders to extend their popups too so their progress bars
    -- and digital countdown stay in sync with ML.
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        self:SendCommMessage(addon.COMM_PREFIX,
            packetJoin("EXTEND_BID", tostring(self.session.itemID), tostring(add)),
            "RAID")
    end
end

-- "Bid again": re-broadcast the loot popup to the raid (and re-show the
-- officer's own popup) and restart the countdown — without clearing recorded
-- bids. Used when raiders missed the heads-up or should reconsider. The raider
-- popup, on receiving OPEN_BID for the item it's already showing, keeps that
-- raider's current pick (see RaiderBid:Show).
function Loot:Reannounce()
    local s = self.session
    if not s then return false, "no active session" end
    local timeout = bidTimeout()
    s.openedAt  = GetTime()
    s.timeoutAt = GetTime() + timeout
    -- Re-arm the countdown + timeout announcers for the new window.
    s._lastCountdown = nil
    s._timedOut      = nil
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        self:SendCommMessage(addon.COMM_PREFIX,
            packetJoin("OPEN_BID", tostring(s.gp), tostring(timeout), s.link),
            "RAID")
        SendChatMessage(string.format(
            "ElitismEPGP: bid again on %s (%ds) — whisper '+' for Need or '-' for Greed. Recorded bids stand.",
            s.link, timeout),
            "RAID")
    end
    -- Self isn't reached by the RAID broadcast — re-show the officer's popup.
    if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.Show then
        addon.UI.RaiderBid:Show(s.link, s.gp, timeout, s.opener or UnitName("player"))
    end
    broadcastLead(self)            -- re-feed the leader so re-opened popups flag it
    notify("TICK", s)              -- BidFrame: refresh timer text/bar
    return true
end

------------------------------------------------------------
-- Bidders
------------------------------------------------------------

local function findBidder(s, name)
    for i, b in ipairs(s.bidders) do
        if b.name == name then return i, b end
    end
    return nil
end

function Loot:AddBid(name, choice, source)
    local s = self.session
    if not s then return false, "no active session" end
    if not name or name == "" then return false, "missing name" end
    if choice ~= CHOICE_MS and choice ~= CHOICE_OS and choice ~= CHOICE_BANK and choice ~= CHOICE_PASS then
        return false, "invalid choice"
    end
    local i, existing = findBidder(s, name)
    if existing then
        existing.choice = choice
        existing.source = source or existing.source
        existing.updatedAt = GetTime()
    else
        s.bidders[#s.bidders + 1] = {
            name      = name,
            choice    = choice,
            source    = source or "manual",
            addedAt   = GetTime(),
            updatedAt = GetTime(),
        }
    end
    notify("BIDDERS", s)
    broadcastLead(self)
    return true
end

function Loot:RemoveBid(name)
    local s = self.session
    if not s then return false end
    local i = findBidder(s, name)
    if not i then return false end
    table.remove(s.bidders, i)
    notify("BIDDERS", s)
    broadcastLead(self)
    return true
end

-- Returns a copy of bidders with EP/GP/PR resolved + sorted.
-- Each entry: { name, choice, source, ep, gp, pr, classFile, online, missing }
function Loot:GetBidders()
    local s = self.session
    if not s then return {} end
    local out = {}
    for i, b in ipairs(s.bidders) do
        local entry = addon.Roster and addon.Roster:Get(b.name)
        local resolvedEntry, mainName
        if addon.Roster and addon.Roster.ResolveMain then
            resolvedEntry, mainName = addon.Roster:ResolveMain(b.name)
        end
        local source = resolvedEntry or entry
        local ep = source and source.ep or 0
        local gp = source and source.gp or 0
        local pr = (addon.Roster and addon.Roster.PR and addon.Roster:PR(ep, gp)) or 0
        out[i] = {
            name      = b.name,
            choice    = b.choice,
            source    = b.source,
            ep        = ep,
            gp        = gp,
            pr        = pr,
            classFile = source and source.classFile,
            class     = source and source.class,
            online    = source and source.online,
            altOf     = mainName,
            missing   = (entry == nil),
        }
    end
    -- Option A tiebreaker: tier first (MS > OS > BANK > PASS), then PR
    -- descending, then GP ASCENDING (the player who's received less wins
    -- the tie), then name alphabetical. Lower-GP tiebreak means after an
    -- award the recipient's GP rises and they drop below tied peers, so
    -- the next item rotates to a different player without the floor
    -- "stickiness".
    table.sort(out, function(a, b)
        local ra, rb = CHOICE_RANK[a.choice] or 99, CHOICE_RANK[b.choice] or 99
        if ra ~= rb then return ra < rb end
        if a.pr ~= b.pr then return a.pr > b.pr end
        if (a.gp or 0) ~= (b.gp or 0) then return (a.gp or 0) < (b.gp or 0) end
        return a.name < b.name
    end)
    return out
end

function Loot:TopBidder()
    -- Skip passes — they're tracked for visibility but aren't "winning".
    local list = self:GetBidders()
    for _, b in ipairs(list) do
        if b.choice ~= CHOICE_PASS then return b end
    end
    return nil
end

------------------------------------------------------------
-- Award
------------------------------------------------------------

function Loot:CostForChoice(choice)
    local s = self.session
    if not s then return 0 end
    if choice == CHOICE_MS   then return s.gp end
    if choice == CHOICE_OS   then return addon.Prices and addon.Prices:OffSpecGP(s.gp) or 0 end
    if choice == CHOICE_BANK then return 0 end
    return 0
end

function Loot:Award(name, choice)
    local s = self.session
    if not s then return false, "no active session" end
    if not name or name == "" then return false, "missing recipient" end
    choice = choice or CHOICE_MS
    if choice ~= CHOICE_MS and choice ~= CHOICE_OS and choice ~= CHOICE_BANK then
        return false, "invalid choice"
    end
    local cost = self:CostForChoice(choice)
    local kind = addon.Awards and addon.Awards.Kind and addon.Awards.Kind.GP_AWARD
    local note = string.format("%s (%s)", s.link or s.name or "?", CHOICE_LABEL[choice])
    if cost > 0 then
        local ok, err = addon.Awards:GiveGP(name, cost, kind, note)
        if not ok then
            return false, "GiveGP failed: " .. tostring(err)
        end
    elseif addon.Awards and addon.Awards.Log then
        local entry = addon.Roster and addon.Roster:Get(name)
        local epNow = entry and entry.ep or 0
        local gpNow = entry and entry.gp or 0
        addon.Awards:Log({
            ts     = time(),
            actor  = UnitName("player"),
            target = name,
            kind   = kind or "GP:Award",
            dEP    = 0,
            dGP    = 0,
            before = { ep = epNow, gp = gpNow },
            after  = { ep = epNow, gp = gpNow },
            note   = note,
        })
    end
    -- If the session originated from the master-loot queue and the loot
    -- window is still showing the same item in the same slot, hand the
    -- item off via GiveMasterLoot. Otherwise the officer trades manually.
    local distributed = false
    if s.lootSlot and IsMasterLooter and IsMasterLooter()
        and (GetNumLootItems and GetNumLootItems() or 0) > 0 then
        local liveLink = GetLootSlotLink and GetLootSlotLink(s.lootSlot)
        if liveLink and liveLink == s.lootSlotLink then
            local idx
            for i = 1, 40 do
                local cand = GetMasterLootCandidate and GetMasterLootCandidate(i)
                if cand == name then idx = i break end
            end
            if idx and GiveMasterLoot then
                GiveMasterLoot(s.lootSlot, idx)
                distributed = true
            end
        end
    end

    -- Trade-it-yourself hint only fires when the master-loot fast path
    -- couldn't deliver the item — surfaces a real action the officer needs
    -- to take, not bidding-flow chatter.
    if not distributed and s.lootSlot and addon.Print then
        addon.Print(string.format(
            "|cFFFFCC00Trade %s to %s manually (loot window changed or recipient out of range).|r",
            s.link or s.name or "?", addon.ColorName(name)))
    end

    -- Official winner declaration to raid chat. The top-3 line that fires on
    -- timeout is informational; THIS is the canonical "X won Y" callout.
    -- Raid chat parser is finicky about extra colour-escapes alongside the
    -- item hyperlink, so the broadcast uses a plain player name and the
    -- local Print mirror carries the class-coloured version.
    if (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        SendChatMessage(string.format("ElitismEPGP: %s awarded to %s (%s, %d GP).",
            s.link or s.name or "?", name, CHOICE_LABEL[choice], cost),
            "RAID")
    end

    self.session = nil
    broadcastClose(self, s.itemID, "awarded")
    if stopWhisperListener then stopWhisperListener() end
    notify("AWARD", s, name, choice, cost)
    return true
end

------------------------------------------------------------
-- Modifier-click → open bid session.
-- Hooks HandleModifiedItemClick (3.3.5a universal modified-click entry
-- point covering bag items, loot window slots, equipment, chat links,
-- quest rewards, auctioneer, etc.) and opens a bid for the clicked item
-- when the configured modifier matches AND the player has permission.
------------------------------------------------------------

-- Surface a click-blocked message to both chat AND UIErrorsFrame (the
-- floating yellow text at the top of the screen). UIErrorsFrame is the
-- same surface Blizzard uses for "Not enough energy" / "You are silenced"
-- — officers can't miss it. The chat copy stays as the durable record.
local function flashBlocked(text)
    if UIErrorsFrame and UIErrorsFrame.AddMessage then
        UIErrorsFrame:AddMessage(text, 1.0, 0.4, 0.4, 1.0)
    end
    if addon.Print then
        addon.Print("|cFFFF6060" .. text .. "|r")
    end
end

function Loot:OnModifiedItemClick(link)
    local devActive = addon.Dev and addon.Dev:IsActive()

    if not link or not link:match("item:%d+") then return end
    local p = addon.DB and addon.DB.profile
    if not p then return end

    local mod = p.bidModifier or "ALT"
    local btn = p.bidClick    or "LeftButton"
    if not addon.ModifierMatches(mod) then return end
    if not addon.ButtonMatches(btn)    then return end

    -- Permission/session gates — fully bypassed in dev mode for testing.
    if not devActive then
        if not (addon.CanRunBidSession and addon.CanRunBidSession()) then
            return  -- silent: avoid spam on innocuous alt-clicks by non-officers
        end
        if not (addon.RaidSession and addon.RaidSession:IsActive()) then
            flashBlocked("ElitismEPGP: Start the raid first — /ee start or use the Raid Manager.")
            return
        end
    end

    if self.session then
        -- Session already in progress. Re-show the existing panel (re-
        -- anchoring + clamping so an off-screen frame self-corrects),
        -- and if the new click is for a different item, flash a clear
        -- "still in progress" notice so the officer doesn't think the
        -- new click failed silently.
        if addon.UI and addon.UI.BidFrame and addon.UI.BidFrame.Reopen then
            addon.UI.BidFrame:Reopen()
        end
        if self.session.link and link ~= self.session.link then
            flashBlocked("ElitismEPGP: bid for " .. self.session.link
                .. " still in progress — Award or Cancel it first.")
        end
        return
    end

    local ok, err = self:OpenSession(link, { opener = UnitName("player") })
    if not ok then
        flashBlocked("ElitismEPGP: bid open failed — " .. tostring(err))
    end
end

------------------------------------------------------------
-- AceComm: incoming OPEN_BID / BID / CLOSE_BID dispatch.
-- Self-sent messages are filtered out so the officer doesn't get their
-- own raider popup. Trust model: OPEN_BID and CLOSE_BID are accepted
-- from anyone in the raid (AceComm RAID distribution already restricts
-- senders to actual raid members). BID is accepted by whichever client
-- is currently running the matching session.
------------------------------------------------------------

function Loot:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= addon.COMM_PREFIX then return end
    if not message or message == "" then return end
    if sender == UnitName("player") then return end

    local fields = packetSplit(message)
    local cmd = fields[1]

    if cmd == "OPEN_BID" then
        local gp       = tonumber(fields[2]) or 0
        local timeout  = tonumber(fields[3]) or 60
        local itemLink = fields[4]
        if not itemLink or itemLink == "" then return end
        if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.Show then
            addon.UI.RaiderBid:Show(itemLink, gp, timeout, sender)
        end

    elseif cmd == "BID" then
        if not self.session then return end
        local itemID = tonumber(fields[2])
        local choice = fields[3]
        if itemID ~= self.session.itemID then return end
        if choice == "ms" or choice == "os" or choice == "pass" then
            -- Passes are recorded too so the officer sees who opted out; the
            -- bid list groups them below the bid tiers (sort) and excludes
            -- them from the bidding count / leader (TopBidder skips them).
            self:AddBid(sender, choice, "addon")
        end

    elseif cmd == "BID_LEAD" then
        local itemID = tonumber(fields[2])
        local name   = fields[3] or ""
        if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.SetLeader then
            addon.UI.RaiderBid:SetLeader(itemID, name)
        end

    elseif cmd == "CLOSE_BID" then
        local itemID = tonumber(fields[2])
        if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.HideForItem then
            addon.UI.RaiderBid:HideForItem(itemID)
        end

    elseif cmd == "EXTEND_BID" then
        local itemID = tonumber(fields[2])
        local add    = tonumber(fields[3])
        if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.Extend then
            addon.UI.RaiderBid:Extend(itemID, add)
        end
    end
end

function Loot:RegisterCommHandler()
    if self._commRegistered then return end
    self:RegisterComm(addon.COMM_PREFIX)
    self._commRegistered = true
end

function Loot:SendBidResponse(itemID, choice, opener)
    if not opener or opener == "" then return end
    local me = UnitName("player")
    -- If the officer is bidding on their own loot, apply directly. No point
    -- whispering yourself, and the local update is instant in BidFrame.
    if opener == me then
        if not self.session or self.session.itemID ~= itemID then return end
        if choice == "ms" or choice == "os" or choice == "pass" then
            self:AddBid(me, choice, "self")
        end
        return
    end
    self:SendCommMessage(addon.COMM_PREFIX,
        packetJoin("BID", tostring(itemID), choice),
        "WHISPER", opener)
end

function Loot:InstallClickHook()
    if self._clickHooked then return end

    -- Hook 1: bag/loot/equipment modified clicks (Blizzard default UI funnels
    -- through here). Some custom bag addons intercept alt-click for their own
    -- features (mark-as-junk, stack split) and never call this — fallback to
    -- a different modifier (Ctrl) or the /ee bid slash for those addons.
    if type(HandleModifiedItemClick) == "function" then
        hooksecurefunc("HandleModifiedItemClick", function(link)
            Loot:OnModifiedItemClick(link)
        end)
    end

    -- Hook 2: chat hyperlink clicks. SetItemRef fires for any click on an item
    -- link in chat regardless of modifier; in 3.3.5a it does NOT route through
    -- HandleModifiedItemClick, so we need a separate hook to catch chat-link
    -- alt-clicks. We only act on item refs.
    if type(SetItemRef) == "function" then
        hooksecurefunc("SetItemRef", function(link, text)
            if link and string.sub(link, 1, 5) == "item:" then
                Loot:OnModifiedItemClick(text or link)
            end
        end)
    end

    self._clickHooked = true
end

------------------------------------------------------------
-- Whisper bid fallback for raiders without the addon.
-- Active only on the opener while a session is in progress so unrelated
-- whispers and other officers' clients don't get involved.
--   +  / +ms / need / ms     → mainspec
--   -  / +os / greed / os    → offspec
-- Silence is treated as a pass — no whisper command for it.
------------------------------------------------------------

local function parseWhisperBid(msg)
    if not msg then return nil end
    local tok = msg:match("^%s*([%+%-]?%a*)")
    if not tok or tok == "" then
        tok = msg:match("^%s*(%S+)") or ""
    end
    tok = tok:lower()
    if tok == "+" or tok == "+ms" or tok == "ms" or tok == "need" then return "ms" end
    if tok == "-" or tok == "+os" or tok == "os" or tok == "greed" then return "os" end
    return nil
end

local function titleCase(name)
    if not name or name == "" then return name end
    name = name:match("^([^-]+)") or name  -- strip realm if present
    return name:sub(1, 1):upper() .. name:sub(2):lower()
end

local whisperFrame = CreateFrame("Frame")
whisperFrame:Hide()
whisperFrame:SetScript("OnEvent", function(_, event, msg, sender)
    if event ~= "CHAT_MSG_WHISPER" then return end
    if not Loot.session then return end
    local choice = parseWhisperBid(msg)
    if not choice then return end  -- ignore unrelated whispers silently

    local who = titleCase(sender)
    local s = Loot.session
    local item = s.link or s.name or "?"

    local ok, err = Loot:AddBid(who, choice, "whisper")
    if ok then
        local label = (choice == "ms") and "Need (Mainspec)" or "Greed (Offspec)"
        local cost  = Loot:CostForChoice(choice)
        SendChatMessage(string.format(
            "[ElitismEPGP] %s bid recorded for %s (%d GP if won).",
            label, item, cost),
            "WHISPER", nil, who)
    elseif err then
        SendChatMessage("[ElitismEPGP] Bid failed: " .. tostring(err),
            "WHISPER", nil, who)
    end
end)

startWhisperListener = function()
    whisperFrame:RegisterEvent("CHAT_MSG_WHISPER")
end

stopWhisperListener = function()
    whisperFrame:UnregisterEvent("CHAT_MSG_WHISPER")
end

------------------------------------------------------------
-- Periodic tick frame (drives countdown UI + chat callouts)
--
-- Runs only on the bid-opener (the only client with Loot.session). Emits:
--   * 4-3-2-1 raid-chat countdown in the final 4 seconds.
--   * A one-shot "Top bids: …" raid-chat summary when the timer expires —
--     visibility for non-addon raiders. NOT the official award announcement;
--     the winner is only declared when an officer clicks Award.
------------------------------------------------------------

-- Build the end-of-bid raid-chat announcement from a session and broadcast
-- it. Reads the session's own bidders[] (NOT Loot:GetBidders, which routes
-- through Loot.session and would return {} if a listener cleared it during
-- the TIMEOUT notify). Player names are sent plain — the chat parser drops
-- the message if a standalone colour escape sits alongside the item link.
--
-- Output shape (Option A semantics):
--   * No bids at all:   "no bids for <item>."
--   * Single winner:    "<name> wins <item> (MS, PR 1.40)."
--   * Tie at the top:   "tie for <item> (MS, PR 1.40) — <a>, <b>: please /roll."
--
-- A "tie" is bidders in the highest-priority tier (MS > OS > BANK) whose
-- (PR, GP) tuple matches the leader's. Same PR but higher GP is NOT a tie
-- under Option A — the higher-GP player sorts below the leader and is
-- excluded from the roll. Pass bids are never announced as winners.
local function announceTopBids(s)
    if not s or not s.bidders then return end

    -- Resolve each non-PASS bidder to a live (ep, gp, pr) snapshot. Bids
    -- are stored on the session with just (name, choice), so we recompute
    -- PR off the roster here — same code path as GetBidders.
    local function snapshot(b)
        local source
        if addon.Roster and addon.Roster.ResolveMain then
            source = (addon.Roster:ResolveMain(b.name))
        end
        source = source or (addon.Roster and addon.Roster:Get(b.name))
        local ep = source and source.ep or 0
        local gp = source and source.gp or 0
        local pr = (addon.Roster and addon.Roster.PR
                    and addon.Roster:PR(ep, gp)) or 0
        return ep, gp, pr
    end

    -- Bucket bidders by tier and resolve their PR/GP.
    local tiers = { [CHOICE_MS] = {}, [CHOICE_OS] = {}, [CHOICE_BANK] = {} }
    for _, b in ipairs(s.bidders) do
        if tiers[b.choice] then
            local ep, gp, pr = snapshot(b)
            tiers[b.choice][#tiers[b.choice] + 1] = {
                name = b.name, choice = b.choice, ep = ep, gp = gp, pr = pr,
            }
        end
    end

    -- Highest-occupied tier wins (MS > OS > BANK). PASS never qualifies.
    local TIER_ORDER = { CHOICE_MS, CHOICE_OS, CHOICE_BANK }
    local pickedTier, pool
    for _, t in ipairs(TIER_ORDER) do
        if #tiers[t] > 0 then
            pickedTier, pool = t, tiers[t]
            break
        end
    end

    local item = s.link or s.name or "item"
    local msg

    if not pool then
        msg = string.format("ElitismEPGP: no bids for %s.", item)
    else
        -- Sort by PR desc, GP asc (Option A). Tied set = bidders matching
        -- the leader's (PR, GP) tuple exactly. Higher-GP players are
        -- excluded by virtue of sorting below the leader.
        table.sort(pool, function(a, b)
            if a.pr ~= b.pr then return a.pr > b.pr end
            if (a.gp or 0) ~= (b.gp or 0) then return (a.gp or 0) < (b.gp or 0) end
            return a.name < b.name
        end)
        local leader = pool[1]
        local tied = { leader.name }
        for i = 2, #pool do
            if pool[i].pr == leader.pr and (pool[i].gp or 0) == (leader.gp or 0) then
                tied[#tied + 1] = pool[i].name
            else
                break
            end
        end

        local tag = (pickedTier == CHOICE_MS and "MS")
                 or (pickedTier == CHOICE_OS and "OS")
                 or (CHOICE_LABEL[pickedTier] or pickedTier)
        if #tied == 1 then
            msg = string.format("ElitismEPGP: %s wins %s (%s, PR %.2f).",
                leader.name, item, tag, leader.pr)
        else
            msg = string.format(
                "ElitismEPGP: tie for %s (%s, PR %.2f) — %s: please /roll.",
                item, tag, leader.pr, table.concat(tied, ", "))
        end
    end

    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        SendChatMessage(msg, "RAID")
    elseif addon.Print then
        -- Solo / not in a raid: still surface it locally.
        addon.Print(msg)
    end
end

local tickFrame = CreateFrame("Frame")
local lastTick = 0
tickFrame:SetScript("OnUpdate", function(_, dt)
    lastTick = lastTick + dt
    if lastTick < 0.5 then return end
    lastTick = 0
    local s = Loot.session
    if not s then return end
    notify("TICK", s)

    -- 4-3-2-1 raid-chat callout. Only sent once per integer second, and only
    -- while a raid is around to hear it.
    local remaining = (s.timeoutAt or 0) - GetTime()
    local secsCeil  = math.ceil(remaining)
    if secsCeil > 0 and secsCeil <= 4 and secsCeil ~= (s._lastCountdown or 0)
        and (GetNumRaidMembers and GetNumRaidMembers() > 0) then
        SendChatMessage(secsCeil .. " sec", "RAID")
        s._lastCountdown = secsCeil
    end

    if remaining <= 0 then
        -- Fire the top-bids callout BEFORE notify("TIMEOUT", ...) so listener
        -- side-effects (e.g. UI handlers that touch the session) can't have
        -- nilled state out from under us. Mark _timedOut only on successful
        -- completion so a transient error doesn't permanently silence it.
        if not s._timedOut then
            local ok, err = pcall(announceTopBids, s)
            if not ok and addon.Print then
                addon.Print("|cFFFF6060Top-bids announce failed:|r " .. tostring(err))
            end
            s._timedOut = true
        end
        notify("TIMEOUT", s)
    end
end)
