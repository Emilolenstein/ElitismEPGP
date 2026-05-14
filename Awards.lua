local _, addon = ...

local Awards = {}
addon.Awards = Awards

Awards.Kind = {
    EP_ON_TIME    = "EP:OnTime",
    EP_END_RAID   = "EP:EndOfRaid",
    EP_FIRST_KILL = "EP:FirstKill",
    EP_BOSS_KILL  = "EP:BossKill",
    EP_OFFICER    = "EP:OfficerWeekly",
    EP_CUSTOM     = "EP:Custom",
    GP_AWARD      = "GP:Award",
    GP_REFUND     = "GP:Refund",
    GP_CUSTOM     = "GP:Custom",
    DECAY         = "Decay",
    RESET         = "Reset",
}

local KIND_VISIBILITY = {
    ["EP:OfficerWeekly"] = "officer",
    ["AltMark"]          = "officer",
    ["AltUnmark"]        = "officer",
    ["Reset"]            = "officer",
}

-- Difficulty multipliers applied to the per-raid Normal value at award
-- time. Normal = ×1.0; Heroic/Mythic/Ascended scale via the configurable
-- multipliers stored in DB.global. Officers tune these on the EP Awards
-- options page.
local function diffMult(difficulty)
    local db = (addon.DB and addon.DB.global) or {}
    if difficulty == "Heroic"   then return db.epHeroicMult   or addon.VARS.epHeroicMult   or 1.5 end
    if difficulty == "Mythic"   then return db.epMythicMult   or addon.VARS.epMythicMult   or 2.0 end
    if difficulty == "Ascended" then return db.epAscendedMult or addon.VARS.epAscendedMult or 3.0 end
    return 1.0
end

-- Looks up the EP amount for a preset. Indexes the per-raid Normal cell
-- (epAwards[raid][preset]) and scales by the difficulty multiplier. Cells
-- the officer has left blank fall back to addon.PRESET_DEFAULTS so an
-- active raid still emits a sensible number for un-customized presets.
function Awards:GetAmountForPreset(presetKey, raid, difficulty)
    local db   = (addon.DB and addon.DB.global) or {}
    local cell = db.epAwards and db.epAwards[raid] and db.epAwards[raid][presetKey]
    local base = cell or (addon.PRESET_DEFAULTS and addon.PRESET_DEFAULTS[presetKey])
                      or db.baseAwardEP or addon.VARS.baseAwardEP or 10
    return math.floor(base * diffMult(difficulty) + 0.5)
end

-- Read/write the matrix cell directly (Normal value only — diff is derived
-- via the multipliers). Intentionally separate from the lookup path so the
-- editor UI and sync layer can target a specific cell without going
-- through the fallback chain.
function Awards:GetMatrixAmount(raid, presetKey)
    local db = (addon.DB and addon.DB.global) or {}
    return db.epAwards and db.epAwards[raid] and db.epAwards[raid][presetKey] or nil
end

function Awards:SetMatrixAmount(raid, presetKey, amount)
    local db = addon.DB and addon.DB.global
    if not db then return false end
    db.epAwards = db.epAwards or {}
    db.epAwards[raid] = db.epAwards[raid] or {}
    db.epAwards[raid][presetKey] = amount
    return true
end

local currentGroupId = nil

local function MintGroupId(tag)
    return string.format("%d-%d-%s", time(), math.random(100000, 999999), tag or "g")
end

local function CanWrite()
    return CanEditOfficerNote and CanEditOfficerNote()
end

-- Strip realm suffix ("Bob-Realm" -> "Bob") so roster names line up across
-- the cross-realm clients that sometimes show up.
local function shortName(n)
    if not n then return nil end
    return n:match("^([^-]+)") or n
end

-- Centralized officer-note write. Verifies the cached entry.index still
-- maps to the player we think it does before calling the API — otherwise
-- a player who gquit between roster pulls would silently corrupt whichever
-- guild slot now occupies that index. Mocks short-circuit (no API call,
-- caller still updates the local cache).
--
-- Exposed as a method on Awards so other modules (Backup.lua restore path)
-- can reuse it; also kept as a local alias for the same-file callers.
function Awards:SafeSetOfficerNote(entry, expectedName, encoded)
    if not entry then return false end
    if entry.isMock then return true end       -- caller still mutates cache
    if not entry.index then return false end
    if GetGuildRosterInfo then
        local rosterName = GetGuildRosterInfo(entry.index)
        if shortName(rosterName) ~= shortName(expectedName) then
            return false  -- stale index — drop the write
        end
    end
    GuildRosterSetOfficerNote(entry.index, encoded)
    return true
end
local function safeSetOfficerNote(entry, expectedName, encoded)
    return Awards:SafeSetOfficerNote(entry, expectedName, encoded)
end

local function ApplyDelta(target, dEP, dGP, kind, note)
    if not CanWrite() then
        return false, "no permission to edit officer notes"
    end

    local lookup = addon.Roster:Get(target)
    if not lookup then
        return false, "unknown player: " .. tostring(target)
    end
    local entry, resolvedName
    if lookup.kind == "alt" then
        if not lookup.altOf then
            return false, target .. " has malformed alt note"
        end
        entry = addon.Roster:Get(lookup.altOf)
        if not entry then
            return false, target .. " is alt of " .. lookup.altOf .. ", but main is not in roster"
        end
        resolvedName = lookup.altOf
    else
        entry = lookup
        resolvedName = target
    end

    local maxAward = (addon.DB and addon.DB.global.maxAward) or addon.VARS.maxAward
    if math.abs(dEP or 0) > maxAward or math.abs(dGP or 0) > maxAward then
        return false, "exceeds per-award cap (" .. maxAward .. ")"
    end

    local oldEP, oldGP = entry.ep or 0, entry.gp or 0
    local newEP = math.max(0, oldEP + (dEP or 0))
    local newGP = math.max(0, oldGP + (dGP or 0))

    local encoded = addon.Storage:Encode(newEP, newGP)
    if not entry.isMock then
        if not addon.Storage:WillFit(newEP, newGP) then
            return false, "officer note overflow (>" .. addon.Storage:NoteLimit() .. " chars)"
        end
        if not safeSetOfficerNote(entry, resolvedName, encoded) then
            return false, "roster index out of sync — please /reload"
        end
    end

    entry.ep, entry.gp, entry.officerNote = newEP, newGP, encoded

    Awards:Log({
        ts          = time(),
        actor       = UnitName("player"),
        target      = target,
        resolvedTo  = (resolvedName ~= target) and resolvedName or nil,
        kind        = kind,
        dEP         = dEP or 0,
        dGP         = dGP or 0,
        before      = { ep = oldEP, gp = oldGP },
        after       = { ep = newEP, gp = newGP },
        note        = note,
    })
    return true
end

function Awards:GiveEP(target, amount, kind, note)
    return ApplyDelta(target, tonumber(amount) or 0, 0, kind or self.Kind.EP_CUSTOM, note)
end

function Awards:GiveGP(target, amount, kind, note)
    return ApplyDelta(target, 0, tonumber(amount) or 0, kind or self.Kind.GP_CUSTOM, note)
end

------------------------------------------------------------
-- Raid-chat broadcasts
--
-- One-liners sent to the RAID channel so non-addon raiders can see when
-- points have been awarded (start raid, end raid, boss kills, customs,
-- per-player tweaks). Names go out plain — Ascension's chat parser drops
-- messages with a standalone colour escape.
------------------------------------------------------------

function Awards:Announce(text)
    if not text or text == "" then return end
    if not (GetNumRaidMembers and GetNumRaidMembers() > 0) then return end
    SendChatMessage("ElitismEPGP: " .. text, "RAID")
end

-- Build + send a "<Label> <±N> <EP|GP> awarded to <who>(+ note)" line.
-- For a single recipient the name is shown inline; for a group the count is
-- used instead. `note` is appended in parens when present.
function Awards:AnnounceAwarded(label, amount, currency, recipients, note)
    local count = (recipients and #recipients) or 0
    if count == 0 then return end
    local who = (count == 1) and recipients[1] or string.format("%d players", count)
    local sign = (tonumber(amount) or 0) >= 0 and "+" or ""
    local body = string.format("%s %s%d %s awarded to %s",
        label, sign, amount, currency, who)
    if note and note ~= "" then body = body .. " (" .. note .. ")" end
    self:Announce(body .. ".")
end

function Awards:DedupeRecipients(names)
    local present = {}
    for _, name in ipairs(names or {}) do present[name] = true end

    local seen, out = {}, {}
    for _, name in ipairs(names or {}) do
        local entry = addon.Roster:Get(name)
        local effective = name

        if entry and entry.kind == "alt" and entry.altOf then
            local mainEntry = addon.Roster:Get(entry.altOf)
            if mainEntry then
                if present[entry.altOf] then
                    effective = nil
                else
                    effective = entry.altOf
                end
            end
        end

        if effective and not seen[effective] then
            seen[effective] = true
            out[#out + 1] = effective
        end
    end
    return out
end

function Awards:GiveEPBulk(targets, amount, kind, note)
    local deduped = self:DedupeRecipients(targets)
    local groupId = MintGroupId("bulk")
    currentGroupId = groupId
    local ok, fails = 0, {}
    for _, name in ipairs(deduped) do
        local success, err = self:GiveEP(name, amount, kind, note)
        if success then
            ok = ok + 1
        else
            fails[#fails + 1] = { name = name, err = err }
        end
    end
    currentGroupId = nil
    return ok, fails, groupId
end

function Awards:MarkAlt(altName, mainName)
    if not CanWrite() then return false, "no permission to edit officer notes" end
    if not altName or altName == "" then return false, "missing alt name" end
    if not mainName or mainName == "" then return false, "missing main name" end
    if altName == mainName then return false, "alt and main must differ" end

    local altEntry = addon.Roster:Get(altName)
    if not altEntry then return false, "alt not in roster: " .. altName end
    local mainEntry = addon.Roster:Get(mainName)
    if not mainEntry then return false, "main not in roster: " .. mainName end
    if mainEntry.kind == "alt" then
        return false, mainName .. " is itself an alt — chains not allowed"
    end
    if not addon.Storage:WillFitAlt(mainName) then
        return false, "main name too long for officer note"
    end

    local lostEP, lostGP = altEntry.ep or 0, altEntry.gp or 0
    local encoded = addon.Storage:EncodeAlt(mainName)
    if not safeSetOfficerNote(altEntry, altName, encoded) then
        return false, "roster index out of sync — please /reload"
    end
    altEntry.officerNote = encoded
    altEntry.kind        = "alt"
    altEntry.altOf       = mainName
    altEntry.ep          = mainEntry.ep
    altEntry.gp          = mainEntry.gp

    self:Log({
        ts     = time(),
        actor  = UnitName("player"),
        target = altName,
        kind   = "AltMark",
        dEP    = 0, dGP = 0,
        note   = string.format("marked as alt of %s (lost %d EP / %d GP)", mainName, lostEP, lostGP),
    })
    return true, { lostEP = lostEP, lostGP = lostGP }
end

function Awards:ResetEPGP(target)
    if not CanWrite() then return false, "no permission to edit officer notes" end
    if not target or target == "" then return false, "missing player name" end
    local entry = addon.Roster:Get(target)
    if not entry then return false, "unknown player: " .. tostring(target) end
    if entry.kind == "alt" then return false, target .. " is an alt; reset their main instead" end

    local oldEP, oldGP = entry.ep or 0, entry.gp or 0
    local encoded = addon.Storage:Encode(0, 0)
    if not safeSetOfficerNote(entry, target, encoded) then
        return false, "roster index out of sync — please /reload"
    end
    entry.ep, entry.gp, entry.officerNote = 0, 0, encoded

    self:Log({
        ts     = time(),
        actor  = UnitName("player"),
        target = target,
        kind   = self.Kind.RESET,
        dEP    = -oldEP,
        dGP    = -oldGP,
        before = { ep = oldEP, gp = oldGP },
        after  = { ep = 0,     gp = 0     },
        note   = "EP/GP reset",
    })
    return true, { oldEP = oldEP, oldGP = oldGP }
end

function Awards:UnmarkAlt(altName)
    if not CanWrite() then return false, "no permission to edit officer notes" end
    local entry = addon.Roster:Get(altName)
    if not entry then return false, "unknown player: " .. altName end
    if entry.kind ~= "alt" then return false, altName .. " is not currently marked as an alt" end

    local previousMain = entry.altOf
    local encoded = addon.Storage:Encode(0, 0)
    if not safeSetOfficerNote(entry, altName, encoded) then
        return false, "roster index out of sync — please /reload"
    end
    entry.officerNote = encoded
    entry.kind        = "self"
    entry.altOf       = nil
    entry.ep, entry.gp = 0, 0
    entry.resolvedFromMain = nil
    entry.altOrphan = nil

    self:Log({
        ts     = time(),
        actor  = UnitName("player"),
        target = altName,
        kind   = "AltUnmark",
        dEP    = 0, dGP = 0,
        note   = string.format("unmarked as alt (was alt of %s); reset to 0:0", tostring(previousMain)),
    })
    return true
end

function Awards:CurrentRaidNames()
    if addon.Dev and addon.Dev:IsActive() then
        local mock = addon.Dev:GetMockRaid()
        if mock and #mock > 0 then
            local copy = {}
            for i = 1, #mock do copy[i] = mock[i] end
            return copy
        end
    end
    local names = {}
    if GetNumRaidMembers and GetNumRaidMembers() > 0 then
        for i = 1, GetNumRaidMembers() do
            local n = GetRaidRosterInfo(i)
            if n then names[#names + 1] = n end
        end
    elseif GetNumPartyMembers and GetNumPartyMembers() > 0 then
        names[#names + 1] = UnitName("player")
        for i = 1, GetNumPartyMembers() do
            local n = UnitName("party" .. i)
            if n then names[#names + 1] = n end
        end
    else
        names[#names + 1] = UnitName("player")
    end
    return names
end

function Awards:StandbyNames()
    local names = {}
    local sb = addon.DB and addon.DB.global.standby
    if sb then
        for name, on in pairs(sb) do
            if on then names[#names + 1] = name end
        end
    end
    return names
end

function Awards:RaidPlusStandby()
    local seen, list = {}, {}
    for _, n in ipairs(self:CurrentRaidNames()) do
        if not seen[n] then seen[n] = true; list[#list + 1] = n end
    end
    for _, n in ipairs(self:StandbyNames()) do
        if not seen[n] then seen[n] = true; list[#list + 1] = n end
    end
    return list
end

local logListeners = {}

function Awards:OnLogAppend(fn)
    logListeners[fn] = true
end

function Awards:OffLogAppend(fn)
    logListeners[fn] = nil
end

-- History is stored as a map keyed by a stable per-entry id so each row
-- can be synced individually (per-key LWW via the "history" Sync domain).
-- Listeners and UI consume a sorted list via GetHistory(); the map shape
-- is internal. Migration from the old list shape happens lazily on first
-- load (see MigrateHistoryShape below — called from RegisterSyncDomain).

local function mintEntryId(entry)
    -- actor + ts gives near-uniqueness; the random suffix avoids
    -- collisions when two entries from the same actor share a second
    -- (e.g. bulk EP awards looping over the raid).
    return string.format("%s@%d#%d",
        entry.actor or "?", entry.ts or time(), math.random(100000, 999999))
end

local function trimHistory(h, maxLines)
    -- Map shape — count entries, drop the oldest if over the cap.
    local count, sorted = 0, {}
    for id, e in pairs(h) do
        count = count + 1
        sorted[#sorted + 1] = { id = id, ts = e.ts or 0 }
    end
    if count <= maxLines then return end
    table.sort(sorted, function(a, b) return a.ts < b.ts end)
    for i = 1, count - maxLines do
        h[sorted[i].id] = nil
    end
end

function Awards:Log(entry)
    if not addon.DB then return end
    if entry.visibility == nil then
        entry.visibility = KIND_VISIBILITY[entry.kind] or "all"
    end
    if entry.group_id == nil and currentGroupId ~= nil then
        entry.group_id = currentGroupId
    end
    if not entry.id then
        entry.id = mintEntryId(entry)
    end
    addon.DB.global.history = addon.DB.global.history or {}
    local h = addon.DB.global.history
    h[entry.id] = entry
    trimHistory(h, addon.DB.global.maxLogLines or addon.VARS.maxLogLines)
    if addon.Sync and addon.Sync.Notify then
        addon.Sync:Notify("history", entry.id)
    end
    for fn in pairs(logListeners) do
        local ok, err = pcall(fn, entry)
        if not ok and addon.Print then
            addon.Print("|cFFFF6060Awards log listener error:|r " .. tostring(err))
        end
    end
end

-- Returns history entries as a list sorted oldest → newest. With map
-- storage we sort on read; the cost is fine at maxLogLines (default 500).
function Awards:GetHistory(filter)
    local h = (addon.DB and addon.DB.global.history) or {}
    local out = {}
    for _, e in pairs(h) do
        if type(e) == "table" then
            local keep = true
            if filter then
                if filter.target and e.target ~= filter.target then keep = false end
                if filter.kind   and e.kind   ~= filter.kind   then keep = false end
                if filter.since  and (e.ts or 0) < filter.since then keep = false end
            end
            if keep then out[#out + 1] = e end
        end
    end
    table.sort(out, function(a, b) return (a.ts or 0) < (b.ts or 0) end)
    return out
end

function Awards:ClearHistory()
    if addon.DB then addon.DB.global.history = {} end
end

-- Nuke EVERY piece of EPGP state addon-side: history, per-member EP/GP
-- (officer notes zeroed for non-alt members, alt-marker notes preserved),
-- price overrides, standby list, and all officer-tunable global settings
-- back to their compiled-in defaults. Strictly for end-of-season / test
-- runs — there's no undo.
--
-- Returns true + the number of officer-note rows that were touched.
function Awards:ResetAll()
    if not CanWrite() then return false, "no permission to edit officer notes" end
    if not (addon.DB and addon.DB.global) then return false, "DB not loaded" end

    -- Auto-snapshot first so /ee reset all is undoable from the Backup
    -- dialog if it was a mistake.
    if addon.Backup and addon.Backup.RecordAuto then
        addon.Backup:RecordAuto("Before /ee reset all")
    end

    -- 1) Per-member EP/GP: write 0:0 to each non-alt officer note. Alts have
    --    their main's name in the note (not EPGP values), so we leave those
    --    intact per the user requirement.
    local touched = 0
    local encodedZero = addon.Storage:Encode(0, 0)
    if addon.Roster and addon.Roster.cache then
        for name, entry in pairs(addon.Roster.cache) do
            if entry and entry.kind ~= "alt" then
                -- safeSetOfficerNote drops the write if the index no longer
                -- matches this player (e.g. they gquit between roster pulls).
                -- We still zero the local cache either way so the standings
                -- view doesn't show stale numbers for the now-gone player.
                safeSetOfficerNote(entry, name, encodedZero)
                entry.ep, entry.gp, entry.officerNote = 0, 0, encodedZero
                touched = touched + 1
            end
        end
    end

    -- 2) History + price overrides + standby.
    local g = addon.DB.global
    g.history   = {}
    g.prices    = {}
    g.standby   = {}
    g.lastDecay = nil

    -- 3) Settings — every other key in the global defaults gets re-applied,
    --    so anything the officers tuned in the Options panel snaps back.
    local defaults = addon.DB_DEFAULTS and addon.DB_DEFAULTS.global
    if defaults then
        local function deepCopy(src)
            if type(src) ~= "table" then return src end
            local dst = {}
            for k, v in pairs(src) do dst[k] = deepCopy(v) end
            return dst
        end
        for k, v in pairs(defaults) do
            if k ~= "history" and k ~= "prices" and k ~= "standby" then
                if type(v) == "table" then g[k] = deepCopy(v) else g[k] = v end
            end
        end
    end

    return true, touched
end

function Awards:OfficerRanks()
    -- Auto-detect from the "Edit Officer Note" rank flag. There's no manual
    -- override anymore — the privilege itself is the authority on this server.
    -- Note: GuildControlGetRankFlags is reliable only on clients that have
    -- officer-note permission; non-officers may see partial data and get
    -- only the GM rank back. Sync.senderRankIsOfficer accounts for that.
    local ranks = {}
    if GuildControlGetNumRanks and GuildControlSetRank and GuildControlGetRankFlags then
        local n = GuildControlGetNumRanks()
        for i = 0, n - 1 do
            GuildControlSetRank(i)
            local _, _, _, canEditOfficerNote = GuildControlGetRankFlags()
            if canEditOfficerNote then ranks[i] = true end
        end
    end
    return ranks
end

function Awards:OfficerRankNames(ranks)
    local names = {}
    if GuildControlGetNumRanks and GuildControlGetRankName then
        local n = GuildControlGetNumRanks()
        for i = 0, n - 1 do
            if ranks[i] then names[#names + 1] = GuildControlGetRankName(i) or ("Rank " .. i) end
        end
    end
    return names
end

function Awards:OfficerNamesPreview()
    local officerRanks = self:OfficerRanks()
    local names = {}
    if not addon.Roster.cache then return names end
    for name, entry in pairs(addon.Roster.cache) do
        if entry.kind ~= "alt" and officerRanks[entry.rankIndex] then
            names[#names + 1] = name
        end
    end
    return names
end

function Awards:WeeklyMaintenance(decayMult)
    if not CanWrite() then
        return false, "no permission to edit officer notes"
    end
    decayMult = decayMult or (addon.DB and addon.DB.global.decay) or addon.VARS.decay
    if decayMult <= 0 or decayMult > 1 then
        return false, "decay multiplier must be in (0, 1]"
    end

    -- Auto-snapshot before mass-mutating the roster — weekly maintenance
    -- decays every member's EP/GP and pays officer weeklies, so a bad run
    -- here is the textbook scenario the snapshot buffer is for.
    if addon.Backup and addon.Backup.RecordAuto then
        local pct = math.floor(((1 - decayMult) * 100) + 0.5)
        addon.Backup:RecordAuto(string.format("Before weekly maintenance (%d%% decay)", pct))
    end

    local officerRanks = self:OfficerRanks()
    local officerCount, officerFails = 0, {}
    local memberCount, memberFails = 0, {}

    local payoutGroupId = MintGroupId("officer-weekly")
    currentGroupId = payoutGroupId
    local officerEP = (addon.DB and addon.DB.global.officerWeeklyEP)
                       or addon.VARS.officerWeeklyEP or 25
    for name, entry in pairs(addon.Roster.cache) do
        if entry.kind ~= "alt" and officerRanks[entry.rankIndex] then
            local ok, err = self:GiveEP(name, officerEP, self.Kind.EP_OFFICER, "Weekly")
            if ok then officerCount = officerCount + 1
            else officerFails[#officerFails + 1] = { name = name, err = err } end
        end
    end
    currentGroupId = nil

    for name, entry in pairs(addon.Roster.cache) do
        if entry.kind ~= "alt" then
            local oldEP, oldGP = entry.ep or 0, entry.gp or 0
            local newEP = math.floor(oldEP * decayMult)
            local newGP = math.floor(oldGP * decayMult)
            if newEP ~= oldEP or newGP ~= oldGP then
                if addon.Storage:WillFit(newEP, newGP) then
                    local encoded = addon.Storage:Encode(newEP, newGP)
                    if safeSetOfficerNote(entry, name, encoded) then
                        entry.ep, entry.gp, entry.officerNote = newEP, newGP, encoded
                        memberCount = memberCount + 1
                    else
                        memberFails[#memberFails + 1] = { name = name, err = "roster index out of sync" }
                    end
                else
                    memberFails[#memberFails + 1] = { name = name, err = "officer note overflow" }
                end
            end
        end
    end

    addon.Roster:Rebuild()

    local pctInt = math.floor((1 - decayMult) * 100 + 0.5)
    self:Log({
        ts     = time(),
        actor  = UnitName("player"),
        target = "<all>",
        kind   = self.Kind.DECAY,
        dEP    = 0, dGP = 0,
        note   = string.format("decay %d%% applied to %d members; %d officers received +%d EP",
            pctInt, memberCount, officerCount, officerEP),
    })

    if addon.DB then addon.DB.global.lastDecay = time() end

    local syncOk, syncErr
    if addon.GuildSync then syncOk, syncErr = addon.GuildSync:Write() end

    -- Broadcast to the guild so members know decay just ran (and why
    -- their numbers moved). The officer-stipend grant goes to the
    -- officer channel only — non-officers don't need to hear about the
    -- weekly EP officers pay themselves.
    if IsInGuild and IsInGuild() and SendChatMessage then
        SendChatMessage(string.format(
            "ElitismEPGP: Weekly maintenance — %d%% decay applied to %d player%s.",
            pctInt, memberCount, memberCount == 1 and "" or "s"),
            "GUILD")
        if officerCount > 0 then
            -- Officer chat requires Edit Officer Note rank to write —
            -- WeeklyMaintenance is already gated on CanWrite() so the
            -- sender has the rank. Wrapped in pcall as belt-and-suspenders
            -- against weird server behaviour on guilds without an
            -- officer-note rank configured at all.
            pcall(SendChatMessage, string.format(
                "ElitismEPGP: Weekly officer stipend — +%d EP to %d officer%s.",
                officerEP, officerCount, officerCount == 1 and "" or "s"),
                "OFFICER")
        end
    end

    return true, {
        officerCount = officerCount, officerFails = officerFails,
        memberCount  = memberCount,  memberFails  = memberFails,
        decayPct     = pctInt,
        syncOk       = syncOk, syncErr = syncErr,
    }
end

-- ----------------------------------------------------------------------
-- Sync integration
-- ----------------------------------------------------------------------
-- History is the only Awards data that needs guild-wide replication —
-- EP/GP balances themselves live in officer notes (already shared via
-- the guild roster). The history domain is conceptually append-only:
-- each entry has a stable id; once a peer has it, further SETs with
-- the same id are no-ops because the per-key ts won't advance.

-- Lazy migration from the legacy list shape (numeric keys, no ids) to
-- the map shape (id keys). Idempotent — bails out as soon as no numeric
-- keys remain. Only called at sync registration time, so the upgrade
-- runs once per officer/raider on first load with the new code.
local function migrateHistoryShape()
    local g = addon.DB and addon.DB.global
    if not g or not g.history then return end
    local h = g.history
    local hasNumericKey = false
    for k in pairs(h) do
        if type(k) == "number" then hasNumericKey = true; break end
    end
    if not hasNumericKey then return end
    local newMap = {}
    for k, entry in pairs(h) do
        if type(entry) == "table" then
            if not entry.id then
                entry.id = string.format("%s@%d#legacy%d",
                    entry.actor or "?", entry.ts or 0, k)
            end
            newMap[entry.id] = entry
        end
    end
    g.history = newMap
end

function Awards:RegisterSyncDomain()
    if not (addon.Sync and addon.Sync.RegisterDomain) then return end
    migrateHistoryShape()

    addon.Sync:RegisterDomain("history", {
        get = function(key)
            local g = addon.DB and addon.DB.global
            return g and g.history and g.history[key] or nil
        end,
        set = function(key, value)
            local g = addon.DB and addon.DB.global
            if not g then return end
            g.history = g.history or {}
            if value == nil or type(value) ~= "table" then
                g.history[key] = nil
            else
                value.id = value.id or key
                g.history[key] = value
                trimHistory(g.history,
                    g.maxLogLines or addon.VARS.maxLogLines)
            end
        end,
        iter = function()
            local g = addon.DB and addon.DB.global
            local h = g and g.history or {}
            local key
            return function()
                key = next(h, key)
                return key
            end
        end,
    })

    -- Stamp existing entries into Sync's metadata so they're included in
    -- REQ/FULL exchanges. Each entry's own ts is used (real edit time),
    -- so an officer who awarded EP yesterday correctly outranks a fresh
    -- alt's empty history during bootstrap LWW.
    local g = addon.DB and addon.DB.global
    if not g or not g.history then return end
    g._sync = g._sync or { ts = {}, bootstrapped = false }
    g._sync.ts = g._sync.ts or {}
    for id, entry in pairs(g.history) do
        if type(entry) == "table" and entry.ts then
            local path = "history:" .. id
            local existing = g._sync.ts[path]
            if not existing or (existing.ts or 0) < entry.ts then
                g._sync.ts[path] = { ts = entry.ts, by = entry.actor or "?" }
            end
        end
    end
end

function Awards:WeeklyMaintenancePreview(decayMult)
    decayMult = decayMult or (addon.DB and addon.DB.global.decay) or addon.VARS.decay
    local officerRanks = self:OfficerRanks()
    local officers, members = 0, 0
    for _, entry in pairs(addon.Roster.cache or {}) do
        if entry.kind ~= "alt" then
            members = members + 1
            if officerRanks[entry.rankIndex] then
                officers = officers + 1
            end
        end
    end
    return {
        rankNames    = self:OfficerRankNames(officerRanks),
        officerCount = officers,
        memberCount  = members,
        decayPct     = math.floor((1 - decayMult) * 100 + 0.5),
        decayMult    = decayMult,
    }
end
