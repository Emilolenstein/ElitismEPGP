local _, addon = ...

local Roster = {}
addon.Roster = Roster

Roster.cache = {}

local LOCALIZED_TO_FILE
local function BuildClassMap()
    if LOCALIZED_TO_FILE then return end
    LOCALIZED_TO_FILE = {}
    for token, localized in pairs(LOCALIZED_CLASS_NAMES_MALE or {}) do
        LOCALIZED_TO_FILE[localized] = token
    end
    for token, localized in pairs(LOCALIZED_CLASS_NAMES_FEMALE or {}) do
        LOCALIZED_TO_FILE[localized] = token
    end
end

function Roster:ClassFile(localizedClass)
    BuildClassMap()
    return LOCALIZED_TO_FILE[localizedClass]
end

-- The addon needs offline members in GetGuildRosterInfo's results, but
-- SetGuildRosterShowOffline is a global Blizzard UI toggle — flipping it
-- on permanently leaks into the player's guild panel ("O" key). To avoid
-- that, snapshot the user's current setting on the first Request, force
-- it on while we read, then restore from Core's GUILD_ROSTER_UPDATE
-- handler after Rebuild has consumed the data.
local savedShowOffline

function Roster:Request()
    if not IsInGuild() then return end
    if SetGuildRosterShowOffline then
        if savedShowOffline == nil and GetGuildRosterShowOffline then
            savedShowOffline = GetGuildRosterShowOffline() and true or false
        end
        SetGuildRosterShowOffline(true)
    end
    GuildRoster()
end

function Roster:RestoreShowOffline()
    if savedShowOffline ~= nil and SetGuildRosterShowOffline then
        SetGuildRosterShowOffline(savedShowOffline)
        savedShowOffline = nil
    end
end

function Roster:Rebuild()
    if not IsInGuild() then return end

    local n = GetNumGuildMembers()
    local seen = {}

    for i = 1, n do
        local name, _, rankIndex, level, class, _, _, officerNote, online = GetGuildRosterInfo(i)
        if name then
            seen[name] = true
            local ep, gp, kind, main = addon.Storage:Decode(officerNote or "")
            self.cache[name] = {
                index       = i,
                class       = class,
                classFile   = self:ClassFile(class),
                level       = level,
                rankIndex   = rankIndex,
                online      = online,
                officerNote = officerNote or "",
                ep          = ep,
                gp          = gp,
                kind        = kind,
                altOf       = main,
            }
        end
    end

    for name, entry in pairs(self.cache) do
        if not seen[name] then
            entry.online = false
            entry.stale  = true
        else
            entry.stale = nil
        end
    end

    for _, entry in pairs(self.cache) do
        if entry.kind == "alt" and entry.altOf then
            local mainEntry = self.cache[entry.altOf]
            if mainEntry and mainEntry.kind == "self" then
                entry.ep = mainEntry.ep
                entry.gp = mainEntry.gp
                entry.resolvedFromMain = true
            else
                entry.altOrphan = true
            end
        end
    end
end

function Roster:Get(name)
    local real = self.cache[name]
    if real then return real end
    if addon.Dev and addon.Dev:IsActive() then
        local entries = addon.DB and addon.DB.profile and addon.DB.profile.mockEntries
        if entries and entries[name] then return entries[name] end
    end
    return nil
end

function Roster:GetEPGP(name)
    local r = self.cache[name]
    if not r then return 0, 0 end
    return r.ep, r.gp
end

function Roster:PR(ep, gp)
    local base = (addon.DB and addon.DB.global.basegp) or addon.VARS.basegp
    local divisor = math.max(gp or 0, base)
    if divisor <= 0 then return 0 end
    return (ep or 0) / divisor
end

function Roster:All()
    local list = {}
    for name, r in pairs(self.cache) do
        list[#list + 1] = {
            name      = name,
            class     = r.class,
            classFile = r.classFile,
            level     = r.level,
            online    = r.online,
            ep        = r.ep,
            gp        = r.gp,
            pr        = self:PR(r.ep, r.gp),
            kind      = r.kind,
            altOf     = r.altOf,
            altOrphan = r.altOrphan,
        }
    end
    if addon.Dev and addon.Dev:IsActive() then
        local entries = addon.DB and addon.DB.profile and addon.DB.profile.mockEntries
        if entries then
            for name, m in pairs(entries) do
                list[#list + 1] = {
                    name      = name,
                    class     = m.class,
                    classFile = m.classFile,
                    level     = m.level,
                    online    = m.online,
                    ep        = m.ep,
                    gp        = m.gp,
                    pr        = self:PR(m.ep, m.gp),
                    kind      = m.kind,
                    isMock    = true,
                }
            end
        end
    end
    return list
end

function Roster:ResolveMain(name)
    local entry = self.cache[name]
    if not entry then return nil end
    if entry.kind == "alt" and entry.altOf then
        return self.cache[entry.altOf], entry.altOf
    end
    return entry, name
end

local SORTERS = {
    name  = function(a, b) return a.name < b.name end,
    -- Group by class first, alphabetical name as tiebreaker. The reverse-
    -- whole-list flip in StandingsTab handles descending direction.
    class = function(a, b)
        local ca, cb = a.class or "", b.class or ""
        if ca ~= cb then return ca < cb end
        return (a.name or "") < (b.name or "")
    end,
    level = function(a, b) return (a.level or 0) > (b.level or 0) end,
    ep    = function(a, b) return a.ep > b.ep end,
    gp    = function(a, b) return a.gp > b.gp end,
    -- Option A tiebreaker: when PRs match (typical when both players sit
    -- below the basegp floor and their PR is just ep/basegp), the player
    -- with LESS actual GP sorts first. Receiving an item nudges their GP
    -- up, which moves them below their tied peers immediately — no
    -- "winner stays at the top" surprise after an award.
    pr = function(a, b)
        if a.pr ~= b.pr then return a.pr > b.pr end
        if (a.gp or 0) ~= (b.gp or 0) then return (a.gp or 0) < (b.gp or 0) end
        return (a.name or "") < (b.name or "")
    end,
}

function Roster:Sorted(key)
    local list = self:All()
    table.sort(list, SORTERS[key] or SORTERS.pr)
    return list
end
