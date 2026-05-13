local _, addon = ...

local Backup = {}
addon.Backup = Backup

local Serializer = LibStub("AceSerializer-3.0")

-- Snapshot envelope version. Bump when changing the shape so older blobs
-- decoded against newer code fail loudly instead of half-applying.
local SNAPSHOT_VERSION = 1

-- Ring-buffer size for auto-snapshots (DB.global.autoSnapshots).
local MAX_AUTO_SNAPSHOTS = 5

-- Global DB keys carried in the "settings" section of a snapshot. Excludes
-- data containers (history / prices / standby) — those live in their own
-- sections so import scope can restore them independently.
local SETTINGS_KEYS = {
    "basegp", "minep", "decay", "baseAwardEP", "officerWeeklyEP",
    "maxAward", "bidTimeout", "osMultiplier",
    "gpFormulaBase", "gpFormulaStandardIlvl", "gpFormulaDoublingIlvl",
    "epHeroicMult", "epMythicMult", "epAscendedMult",
    "slotMultipliers", "epAwards",
}

local function deepCopy(src)
    if type(src) ~= "table" then return src end
    local dst = {}
    for k, v in pairs(src) do dst[k] = deepCopy(v) end
    return dst
end

------------------------------------------------------------
-- Snapshot construction
------------------------------------------------------------

function Backup:BuildSnapshot(label)
    local g = addon.DB and addon.DB.global or {}
    local snap = {
        version  = SNAPSHOT_VERSION,
        ts       = time(),
        label    = label or "",
        settings = {},
        prices   = deepCopy(g.prices or {}),
        history  = deepCopy(g.history or {}),
        standby  = deepCopy(g.standby or {}),
        roster   = {},
    }
    for _, k in ipairs(SETTINGS_KEYS) do
        snap.settings[k] = deepCopy(g[k])
    end

    -- Roster section: name → {ep, gp}. Alts excluded — their officer note
    -- holds the main's name, not EPGP, and `Apply` won't touch them.
    if addon.Roster and addon.Roster.cache then
        for name, entry in pairs(addon.Roster.cache) do
            if entry and entry.kind ~= "alt" then
                snap.roster[name] = { ep = entry.ep or 0, gp = entry.gp or 0 }
            end
        end
    end
    return snap
end

function Backup:Counts(snap)
    if not snap then return 0, 0, 0, 0 end
    local nSettings = 0
    if snap.settings then for _ in pairs(snap.settings) do nSettings = nSettings + 1 end end
    local nPrices = 0
    if snap.prices then for _ in pairs(snap.prices) do nPrices = nPrices + 1 end end
    local nHistory = snap.history and #snap.history or 0
    local nRoster = 0
    if snap.roster then for _ in pairs(snap.roster) do nRoster = nRoster + 1 end end
    return nSettings, nPrices, nHistory, nRoster
end

------------------------------------------------------------
-- Encode / Decode
------------------------------------------------------------

function Backup:Encode(snap)
    if type(snap) ~= "table" then return nil, "snapshot is not a table" end
    local ok, blob = pcall(Serializer.Serialize, Serializer, snap)
    if not ok then return nil, tostring(blob) end
    return blob
end

function Backup:Decode(blob)
    if type(blob) ~= "string" or blob == "" then return nil, "empty blob" end
    blob = blob:match("^%s*(.-)%s*$")  -- trim
    local ok, snap = Serializer:Deserialize(blob)
    if not ok then return nil, "not a recognised snapshot blob" end
    if type(snap) ~= "table" or not snap.version then
        return nil, "snapshot envelope missing"
    end
    if snap.version > SNAPSHOT_VERSION then
        return nil, string.format("snapshot is from a newer format (v%d); update the addon", snap.version)
    end
    -- Type-check each section so a malformed paste (e.g. someone hand-edits
    -- the blob and breaks a table) is rejected up front instead of half-
    -- applying. Each section is optional; if present it must be a table.
    local function badType(field)
        return string.format("snapshot field '%s' is malformed", field)
    end
    if snap.settings ~= nil and type(snap.settings) ~= "table" then return nil, badType("settings") end
    if snap.prices   ~= nil and type(snap.prices)   ~= "table" then return nil, badType("prices")   end
    if snap.history  ~= nil and type(snap.history)  ~= "table" then return nil, badType("history")  end
    if snap.standby  ~= nil and type(snap.standby)  ~= "table" then return nil, badType("standby")  end
    if snap.roster   ~= nil and type(snap.roster)   ~= "table" then return nil, badType("roster")   end
    return snap
end

------------------------------------------------------------
-- Apply with selectable scope
--
-- scope = {
--     settings = bool,   -- restore Options-panel tunables (also restores prices)
--     history  = bool,   -- restore award + decay history log
--     roster   = bool,   -- re-write EP:GP officer notes for every main
-- }
--
-- Roster restore needs Edit-Officer-Note permission. Alt entries are
-- ignored on both sides — their notes carry "=Main" markers, not EPGP.
--
-- Returns (true, info) on success or (false, errString) on permission
-- failure. info = { settings, history, roster } with the row counts touched.
------------------------------------------------------------

function Backup:Apply(snap, scope)
    if not snap then return false, "no snapshot" end
    if not addon.DB or not addon.DB.global then return false, "DB not loaded" end
    scope = scope or {}

    -- Take an auto-snapshot first so a botched Apply is undoable. The
    -- existing destructive paths (ResetAll, WeeklyMaintenance) already
    -- record their own pre-snapshots; restore needs its own because the
    -- user is by definition making a destructive change here.
    if scope.settings or scope.history or scope.roster then
        local parts = {}
        if scope.settings then parts[#parts + 1] = "settings" end
        if scope.history  then parts[#parts + 1] = "history"  end
        if scope.roster   then parts[#parts + 1] = "roster"   end
        self:RecordAuto("Before restore (" .. table.concat(parts, "+") .. ")")
    end

    local g = addon.DB.global
    local touched = { settings = 0, history = 0, roster = 0 }

    if scope.settings then
        for _, k in ipairs(SETTINGS_KEYS) do
            local v = (snap.settings or {})[k]
            if v ~= nil then
                g[k] = type(v) == "table" and deepCopy(v) or v
                touched.settings = touched.settings + 1
            end
        end
        -- Prices ride alongside settings — they're operational config too.
        g.prices = deepCopy(snap.prices or {})
    end

    if scope.history then
        g.history = deepCopy(snap.history or {})
        touched.history = #g.history
    end

    if scope.roster then
        if not (addon.IsOfficer and addon.IsOfficer()) then
            return false, "no permission to edit officer notes"
        end
        if addon.Roster and addon.Roster.cache then
            for name, vals in pairs(snap.roster or {}) do
                if type(vals) == "table" then
                    local entry = addon.Roster:Get(name)
                    if entry and entry.kind ~= "alt" then
                        local ep      = tonumber(vals.ep) or 0
                        local gp      = tonumber(vals.gp) or 0
                        local encoded = addon.Storage:Encode(ep, gp)
                        -- Route through the centralized helper that verifies
                        -- the cached roster index still maps to this player.
                        if addon.Awards and addon.Awards.SafeSetOfficerNote then
                            addon.Awards:SafeSetOfficerNote(entry, name, encoded)
                        end
                        entry.ep, entry.gp, entry.officerNote = ep, gp, encoded
                        touched.roster = touched.roster + 1
                    end
                end
            end
        end
    end

    return true, touched
end

------------------------------------------------------------
-- Auto-snapshot ring buffer (DB.global.autoSnapshots)
--
-- Called from destructive code paths so the officer can roll back if a
-- decay / weekly maintenance / reset went sideways. Keeps the most recent
-- MAX_AUTO_SNAPSHOTS entries; oldest fall off the tail.
------------------------------------------------------------

function Backup:RecordAuto(label)
    if not addon.DB or not addon.DB.global then return end
    local g = addon.DB.global
    g.autoSnapshots = g.autoSnapshots or {}
    local snap = self:BuildSnapshot(label)
    local blob, err = self:Encode(snap)
    if not blob then return false, err end
    table.insert(g.autoSnapshots, 1, {
        ts    = snap.ts,
        label = label or "Snapshot",
        blob  = blob,
    })
    while #g.autoSnapshots > MAX_AUTO_SNAPSHOTS do
        table.remove(g.autoSnapshots)
    end
    return true
end

function Backup:GetAutoSnapshots()
    return (addon.DB and addon.DB.global and addon.DB.global.autoSnapshots) or {}
end

function Backup:DeleteAutoSnapshot(index)
    local list = self:GetAutoSnapshots()
    if list[index] then table.remove(list, index) end
end
