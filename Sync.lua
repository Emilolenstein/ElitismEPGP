local _, addon = ...

local Sync = {}
addon.Sync = Sync

local AceComm       = LibStub("AceComm-3.0")
local AceSerializer = LibStub("AceSerializer-3.0")
AceComm:Embed(Sync)
AceSerializer:Embed(Sync)

------------------------------------------------------------------------
-- Per-key last-write-wins sync of guild-shared state.
--
-- Architecture:
--   * AceComm prefix "EEPGPS" (separate from "EEPGP" used by Loot.lua).
--   * Distribution: GUILD channel — every addon user holds the data
--     (passive replication), so a fresh-install / post-crash officer
--     can pull from any guild member who was online recently.
--   * Authority: only officers (CanEditOfficerNote rank) author SET
--     messages; receivers verify the sender's rank against the locally
--     computed officer-ranks set before applying.
--   * Conflict resolution: per-key timestamps in DB.global._sync.ts.
--     Higher ts wins; ties (same ts) keep current value.
--   * Debounce: every Notify() call schedules a flush 1.5s later;
--     subsequent calls within the window batch together. This keeps
--     slider drags from flooding the network.
------------------------------------------------------------------------

local SYNC_PREFIX      = "EEPGPS"
local SEP              = "\1"
local DEBOUNCE_SECONDS = 1.5
local BOOTSTRAP_DELAY  = 5

-- Message types (first byte of payload).
local MSG_SET  = "S"
local MSG_REQ  = "R"
local MSG_FULL = "F"
local MSG_VER  = "V"  -- "V\1<version-string>" — guild-wide one-shot ping
local MSG_BAT  = "B"  -- "B\1<serialized array of {path,value,ts,by} tuples>"

-- Hardening constants.
local MAX_VER_LEN          = 64    -- cap MSG_VER payload to defang oversized peer pings
local FULL_REPLY_THROTTLE  = 30    -- seconds between MSG_REQ replies to the same sender
local FULL_GLOBAL_COOLDOWN = 5     -- min seconds between any two _SendFull calls (anti-flood)

------------------------------------------------------------------------
-- Domain registry. A "domain" is a logical bucket of synced data; its
-- handlers know how to read, write, and enumerate the underlying table.
------------------------------------------------------------------------

local domains = {}

-- handlers = { get(key) -> value, set(key, value), iter() -> stateless iterator over keys }
function Sync:RegisterDomain(name, handlers)
    if type(name) ~= "string" or type(handlers) ~= "table" then return end
    domains[name] = handlers
end

local function pathFor(domain, key)
    return domain .. ":" .. tostring(key or "")
end

local function parsePath(path)
    return path:match("^([^:]+):(.*)$")
end

------------------------------------------------------------------------
-- Metadata storage (DB.global._sync.ts[path] = { ts, by }).
------------------------------------------------------------------------

local function syncMeta()
    if not addon.DB then return nil end
    local g = addon.DB.global
    g._sync = g._sync or { ts = {}, bootstrapped = false }
    g._sync.ts = g._sync.ts or {}
    return g._sync
end

local function getLocalTs(path)
    local m = syncMeta()
    return (m and m.ts[path] and m.ts[path].ts) or 0
end

local function setLocalTs(path, ts, by)
    local m = syncMeta()
    if not m then return end
    m.ts[path] = { ts = ts, by = by }
end

------------------------------------------------------------------------
-- Officer authority
------------------------------------------------------------------------

local function localIsOfficer()
    return (addon.IsOfficer and addon.IsOfficer()) and true or false
end

-- Strips realm suffix ("Bob-Realm" -> "Bob") so AceComm sender names
-- match guild roster names, which are typically realm-less in 3.3.5a.
local function shortName(name)
    if not name then return nil end
    return name:match("^([^-]+)") or name
end

local function senderRankIsOfficer(senderName)
    if not senderName or senderName == "" then return false end
    if not (addon.Awards and addon.Awards.OfficerRanks) then return true end
    if not (GetNumGuildMembers and GetGuildRosterInfo) then return true end
    -- OfficerRanks calls GuildControlGetRankFlags. In 3.3.5a that
    -- returns full / accurate data only when the calling player has
    -- officer-note permission themselves; for raiders/alts it often
    -- returns partial data (just the GM rank), so the resulting set
    -- omits real officer ranks and we'd reject every legitimate SET.
    -- When our own introspection can't be trusted, fall through
    -- permissively — the send-side gate (only officers call Notify)
    -- is the primary trust boundary; receive-side strictness is
    -- defense-in-depth and shouldn't deadlock the data plane.
    local canSelfDetect = CanEditOfficerNote and CanEditOfficerNote()
    local officerRanks = addon.Awards:OfficerRanks()
    if not next(officerRanks) then return true end
    local target = shortName(senderName)
    local n = GetNumGuildMembers() or 0
    for i = 1, n do
        local name, _, rankIndex = GetGuildRosterInfo(i)
        if shortName(name) == target then
            local inSet = officerRanks[rankIndex] and true or false
            if inSet then return true end
            -- Our local rank-flag map is unreliable on this client.
            -- Trust the broadcast rather than silently drop it.
            if not canSelfDetect then return true end
            return false
        end
    end
    -- Sender not in roster (likely a roster-load race) — permit.
    return true
end

------------------------------------------------------------------------
-- Wire format
------------------------------------------------------------------------

local function encodeSet(path, value, ts, by)
    -- Serialize value as a 1-element table to keep AceSerializer happy
    -- with nil values (a nil-only payload would be ambiguous).
    local serialized = Sync:Serialize({ value })
    return MSG_SET .. SEP .. path .. SEP .. tostring(ts) .. SEP
        .. (by or "?") .. SEP .. serialized
end

local function decodeSet(payload)
    local rest = payload:sub(3)
    local path, ts, by, serialized = rest:match("^([^\1]*)\1([^\1]*)\1([^\1]*)\1(.*)$")
    if not path then return nil end
    local ok, decoded = Sync:Deserialize(serialized)
    if not ok or type(decoded) ~= "table" then return nil end
    return path, decoded[1], tonumber(ts) or 0, by
end

------------------------------------------------------------------------
-- Debounced broadcaster
------------------------------------------------------------------------

local dirty = {}
local debounceFrame
local debounceFireAt = 0

local function ensureDebounceFrame()
    if debounceFrame then return debounceFrame end
    debounceFrame = CreateFrame("Frame")
    debounceFrame:Hide()
    debounceFrame:SetScript("OnUpdate", function(self)
        if GetTime() < debounceFireAt then return end
        self:Hide()
        Sync:_FlushDirty()
    end)
    return debounceFrame
end

local function scheduleFlush()
    debounceFireAt = GetTime() + DEBOUNCE_SECONDS
    ensureDebounceFrame():Show()
end

-- Public API: data layers call this AFTER they mutate a value locally.
-- We stamp the local timestamp regardless of officer status (so the
-- envelope stays consistent) but only officers actually broadcast.
function Sync:Notify(domain, key)
    if not domains[domain] then return end
    local path = pathFor(domain, key)
    local ts, by = time(), UnitName("player") or "?"
    setLocalTs(path, ts, by)
    if not localIsOfficer() then return end
    dirty[path] = true
    scheduleFlush()
end

-- Collects each dirty path into a single batched envelope and ships it
-- with one SendCommMessage call. A 25-man bulk award (25 history rows
-- dirty in the same debounce window) used to fan out into 25 separate
-- GUILD messages; now it's a single packet. AceComm/ChatThrottleLib still
-- splits oversized payloads transparently, so there's no upper bound to
-- worry about at this layer.
function Sync:_FlushDirty()
    if not next(dirty) then return end
    if not localIsOfficer() then wipe(dirty); return end
    if not (IsInGuild and IsInGuild()) then wipe(dirty); return end

    local tuples = {}
    for path in pairs(dirty) do
        local domain, key = parsePath(path)
        local handlers = domain and domains[domain]
        local m = syncMeta()
        local meta = m and m.ts[path]
        if handlers and handlers.get and meta then
            tuples[#tuples + 1] = {
                p = path, v = handlers.get(key), t = meta.ts, b = meta.by,
            }
        end
    end
    wipe(dirty)

    if #tuples == 0 then return end
    if #tuples == 1 then
        -- Single key: keep wire-format compatible with peers that don't
        -- speak MSG_BAT yet (any older clients in the guild).
        local t = tuples[1]
        self:SendCommMessage(SYNC_PREFIX, encodeSet(t.p, t.v, t.t, t.b), "GUILD")
    else
        local serialized = self:Serialize(tuples)
        self:SendCommMessage(SYNC_PREFIX, MSG_BAT .. SEP .. serialized, "GUILD")
    end
end

------------------------------------------------------------------------
-- Receive
------------------------------------------------------------------------

local function applyEnvelope(path, value, ts, by)
    if ts <= getLocalTs(path) then return false end
    local domain, key = parsePath(path)
    local handlers = domain and domains[domain]
    if not handlers or not handlers.set then return false end
    handlers.set(key, value)
    setLocalTs(path, ts, by)
    return true
end

-- Per-sender throttle for MSG_REQ → MSG_FULL replies. A misbehaving peer
-- spamming REQ from an alt would otherwise force every officer to whisper
-- the entire state on every request. Keyed by sender shortname.
local lastFullToSender = {}
local lastFullAny      = 0

function Sync:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= SYNC_PREFIX or not message or message == "" then return end
    -- Ignore our own broadcasts (AceComm GUILD messages echo back).
    if shortName(sender) == shortName(UnitName("player")) then return end
    local mtype = message:sub(1, 1)
    if mtype == MSG_SET then
        if not senderRankIsOfficer(sender) then return end
        local path, value, ts, by = decodeSet(message)
        if path then applyEnvelope(path, value, ts, by) end
    elseif mtype == MSG_BAT then
        if not senderRankIsOfficer(sender) then return end
        local serialized = message:sub(3)
        local ok, list = self:Deserialize(serialized)
        if not ok or type(list) ~= "table" then return end
        for i = 1, #list do
            local t = list[i]
            if type(t) == "table" and type(t.p) == "string" and type(t.t) == "number" then
                applyEnvelope(t.p, t.v, t.t, t.b)
            end
        end
    elseif mtype == MSG_REQ then
        -- Rate-limit: anyone can ask, but we reply at most every
        -- FULL_REPLY_THROTTLE seconds per sender, and never more often
        -- than FULL_GLOBAL_COOLDOWN across the whole guild. The bootstrap
        -- exchange happens once per session per peer, so honest clients
        -- will never trip these.
        local now = GetTime()
        local key = shortName(sender) or "?"
        if now - lastFullAny < FULL_GLOBAL_COOLDOWN then return end
        if (lastFullToSender[key] or 0) + FULL_REPLY_THROTTLE > now then return end
        lastFullToSender[key] = now
        lastFullAny = now
        self:_SendFull(sender)
    elseif mtype == MSG_FULL then
        self:_ApplyFull(message, sender)
    elseif mtype == MSG_VER then
        -- Cap the captured string so a malicious peer can't force a
        -- large allocation. Capture group is .- so the match is lazy.
        local capped = message:sub(1, 2 + MAX_VER_LEN)
        local their  = capped:match("^V\1(.-)$")
        if their and their ~= "" then self:_HandleVersion(their, sender) end
    end
end

------------------------------------------------------------------------
-- Version broadcast — one-shot per session GUILD ping. Receivers compare
-- against their own addon.VERSION and print a one-time "newer available"
-- notice if outclassed. The highest version a character has already been
-- warned about is stored in DB.profile.versionWarned so the same nag
-- doesn't repeat every login.
------------------------------------------------------------------------

-- Permissive semver parser. Accepts:
--   "1"           -> 1, 0, 0
--   "1.2"         -> 1, 2, 0
--   "1.2.3"       -> 1, 2, 3
--   "1.2.3-beta"  -> 1, 2, 3  (suffix ignored)
-- Anything that doesn't start with a digit returns nil so compareVersions
-- can fall through to "unparseable -> 0".
local function parseVersion(v)
    if type(v) ~= "string" then return nil end
    local a, b, c = v:match("^(%d+)%.(%d+)%.(%d+)")
    if a then return tonumber(a), tonumber(b), tonumber(c) end
    local a2, b2 = v:match("^(%d+)%.(%d+)")
    if a2 then return tonumber(a2), tonumber(b2), 0 end
    local a1 = v:match("^(%d+)")
    if a1 then return tonumber(a1), 0, 0 end
    return nil
end

-- Returns +1 if a > b, -1 if a < b, 0 if equal/unparseable.
local function compareVersions(a, b)
    local a1, a2, a3 = parseVersion(a)
    local b1, b2, b3 = parseVersion(b)
    if not a1 or not b1 then return 0 end
    if a1 ~= b1 then return a1 > b1 and 1 or -1 end
    if a2 ~= b2 then return a2 > b2 and 1 or -1 end
    if a3 ~= b3 then return a3 > b3 and 1 or -1 end
    return 0
end

function Sync:_HandleVersion(theirs, sender)
    if not addon.VERSION or theirs == addon.VERSION then return end
    if compareVersions(theirs, addon.VERSION) ~= 1 then return end
    local p = addon.DB and addon.DB.profile
    if p and p.versionWarned and compareVersions(theirs, p.versionWarned) ~= 1 then
        return  -- already warned about this version (or newer)
    end
    if p then p.versionWarned = theirs end
    if addon.Print then
        addon.Print(string.format(
            "|cFFFFD200v%s|r is available (you have |cFFFFD200v%s|r).",
            theirs, addon.VERSION or "?"))
    end
end

function Sync:_SendVersion()
    if self._versionSent then return end
    if not (IsInGuild and IsInGuild()) then return end
    if not addon.VERSION then return end
    self._versionSent = true
    self:SendCommMessage(SYNC_PREFIX, MSG_VER .. SEP .. addon.VERSION, "GUILD")
end

------------------------------------------------------------------------
-- Bootstrap (full-state exchange)
------------------------------------------------------------------------

function Sync:_BuildFull()
    local out = {}
    for domainName, handlers in pairs(domains) do
        if handlers.iter and handlers.get then
            for key in handlers.iter() do
                local path = pathFor(domainName, key)
                local m = syncMeta()
                local meta = m and m.ts[path]
                if meta then
                    out[path] = { v = handlers.get(key), t = meta.ts, b = meta.by }
                end
            end
        end
    end
    return out
end

function Sync:_SendFull(target)
    if not target or target == "" then return end
    local serialized = self:Serialize(self:_BuildFull())
    self:SendCommMessage(SYNC_PREFIX, MSG_FULL .. SEP .. serialized,
        "WHISPER", target)
end

-- Domains whose values must originate from an officer. Non-officer peers
-- can still passively replicate config scalars (a fresh-install non-officer
-- needs to learn the guild's bidTimeout etc. from whoever's online), but
-- the history ledger cannot be seeded from raiders even on fresh installs
-- — otherwise a malicious peer could plant audit-log entries before any
-- officer is around to overwrite them.
local OFFICER_ONLY_DOMAINS = { history = true }

function Sync:_ApplyFull(message, sender)
    local serialized = message:sub(3)
    local ok, state = self:Deserialize(serialized)
    if not ok or type(state) ~= "table" then return end
    local senderIsOfc = senderRankIsOfficer(sender)
    for path, env in pairs(state) do
        if type(env) == "table" and env.t and env.t > getLocalTs(path) then
            local domain, key = parsePath(path)
            local handlers = domain and domains[domain]
            -- Officers carry full authority. Raiders are allowed to seed
            -- empty slots (getLocalTs == 0) for non-officer-only domains
            -- only — config scalars, yes; history rows, never.
            local allow = senderIsOfc
                or (getLocalTs(path) == 0 and not OFFICER_ONLY_DOMAINS[domain])
            if allow and handlers and handlers.set then
                handlers.set(key, env.v)
                setLocalTs(path, env.t, env.b)
            end
        end
    end
    local m = syncMeta()
    if m then m.bootstrapped = true end
end

function Sync:Bootstrap()
    if not (IsInGuild and IsInGuild()) then return end
    self:SendCommMessage(SYNC_PREFIX, MSG_REQ, "GUILD")
end

------------------------------------------------------------------------
-- Built-in domains: shared config scalars + per-slot multipliers
------------------------------------------------------------------------
-- Centralized so every officer's calibration (base GP, standard ilvl,
-- decay %, EP awards, etc.) propagates to all guild members. Stored
-- value shapes are opaque to Sync — when the awards schema changes from
-- flat to per-raid×difficulty, only the editor and Awards reader need
-- to adapt; sync continues to ship whatever value lives at the path.

-- Keys that still ride AceComm. The "guild-shared config" half (basegp,
-- gpFormula*, decay, EP awards setup, slot multipliers, EP awards matrix)
-- now lives in the Guild Information text via GuildSync.lua, so those keys
-- are intentionally NOT in this list — Guild Info is their single source
-- of truth. What stays here are the lower-stakes operational knobs.
local CONFIG_KEYS = {
    "gpFormulaBase",  -- legacy unused, kept for back-compat
    "minep",
    "maxAward", "bidTimeout",
}
local CONFIG_KEY_SET = {}
for _, k in ipairs(CONFIG_KEYS) do CONFIG_KEY_SET[k] = true end

function Sync:RegisterBuiltinDomains()
    if not addon.DB then return end

    -- Scalars / small tables stored at DB.global[key].
    self:RegisterDomain("config", {
        get = function(key)
            if not CONFIG_KEY_SET[key] then return nil end
            return addon.DB.global[key]
        end,
        set = function(key, value)
            if not CONFIG_KEY_SET[key] then return end
            addon.DB.global[key] = value
        end,
        iter = function()
            local i = 0
            return function()
                i = i + 1
                return CONFIG_KEYS[i]
            end
        end,
    })

    -- The "epaward" and "slotmult" domains used to live here. They were
    -- moved to GuildSync.lua (Guild Information text) so the per-raid×
    -- difficulty matrix and per-slot multipliers have a single
    -- server-authoritative source. Domain registration is intentionally
    -- omitted now — peers no longer accept SETs for these via AceComm.

    -- Migration: stamp existing CUSTOMIZED values (those that differ
    -- from the bundled default) with a "weak" timestamp so they ship
    -- in REQ/FULL exchanges. Skipping defaults is critical — otherwise
    -- a fresh-install alt's default 264 would migrate with a newer ts
    -- than an earlier-loaded officer's customized 65, and clobber it.
    -- Subsequent explicit edits via Options use current time() which
    -- always trumps these migration stamps.
    local g = addon.DB.global
    g._sync = g._sync or { ts = {}, bootstrapped = false }
    g._sync.ts = g._sync.ts or {}
    local weak = time() - 86400
    local vars = addon.VARS or {}
    for _, key in ipairs(CONFIG_KEYS) do
        local val = g[key]
        local def = vars[key]
        local path = "config:" .. key
        local existing = g._sync.ts[path]
        if val == def then
            -- Value matches default. If a previous (overly-eager)
            -- migration stamped a baseline envelope here, clean it up
            -- so this client doesn't claim authority over peers who
            -- have customized the value. Only clears synthetic stamps
            -- (by="?") — never touches stamps from real edits.
            if existing and existing.by == "?" then
                g._sync.ts[path] = nil
            end
        elseif val ~= nil and not existing then
            g._sync.ts[path] = { ts = weak, by = "?" }
        end
    end
    -- Bootstrap stamping for slotMultipliers and epAwards used to happen
    -- here; both moved to GuildSync.lua and no longer use the per-key ts
    -- envelope mechanism, so we drop those stamps. Old envelopes left in
    -- _sync.ts are harmless — their domains aren't registered anymore so
    -- they'll never SET / FULL out.
end

------------------------------------------------------------------------
-- Status (for /ee sync slash command)
------------------------------------------------------------------------

function Sync:Status()
    local m = syncMeta()
    local total = 0
    if m and m.ts then for _ in pairs(m.ts) do total = total + 1 end end
    local domainList = {}
    for name in pairs(domains) do domainList[#domainList + 1] = name end
    table.sort(domainList)
    return {
        bootstrapped = m and m.bootstrapped or false,
        envelopeCount = total,
        domains = domainList,
        isOfficer = localIsOfficer(),
        inGuild = IsInGuild and IsInGuild() and true or false,
    }
end

-- Diagnostic: returns the envelope and live value for a specific path.
-- Useful for verifying whether a SET / FULL actually applied a value to
-- the DB (vs just stamping the timestamp but no-op'ing on set).
function Sync:Probe(path)
    local m = syncMeta()
    local meta = m and m.ts[path]
    local domain, key = parsePath(path)
    local handlers = domain and domains[domain]
    local liveValue = handlers and handlers.get and handlers.get(key) or nil
    return {
        path = path,
        hasEnvelope = meta ~= nil,
        ts = meta and meta.ts or 0,
        by = meta and meta.by or "?",
        liveValue = liveValue,
        domainKnown = handlers ~= nil,
    }
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------

function Sync:Init()
    if self._initialized then return end
    syncMeta()  -- ensure DB shape exists
    self:RegisterComm(SYNC_PREFIX)
    self._initialized = true

    -- Schedule bootstrap after a short delay to let the guild roster
    -- populate (CanEditOfficerNote, GetGuildRosterInfo etc. need it).
    local f = CreateFrame("Frame")
    local elapsed = 0
    f:SetScript("OnUpdate", function(self, dt)
        elapsed = elapsed + dt
        if elapsed >= BOOTSTRAP_DELAY then
            self:Hide()
            Sync:Bootstrap()
        end
    end)

    -- Version-broadcast: fire once per session, 30 s after login + a
    -- random 0–30 s jitter so a whole raid's worth of clients logging in
    -- together don't all transmit in the same tick. Single ~12 byte
    -- GUILD message; no repeats, no whisper amplification.
    local vf = CreateFrame("Frame")
    local vElapsed = 0
    local vAt = 30 + math.random() * 30
    vf:SetScript("OnUpdate", function(self, dt)
        vElapsed = vElapsed + dt
        if vElapsed >= vAt then
            self:Hide()
            Sync:_SendVersion()
        end
    end)
end
