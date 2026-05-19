local _, addon = ...

local GuildSync = {}
addon.GuildSync = GuildSync

-- Guild Information text is the SINGLE SOURCE OF TRUTH for guild-shared
-- configuration: weekly maintenance, EP setup, GP setup, slot multipliers,
-- per-raid Normal awards, and the 3 difficulty multipliers. Officers Write
-- the encoded block; everyone Reads it on guild roster updates and applies
-- it to DB.
--
-- AceComm sync (Sync.lua) is still used for high-volume per-cell domains
-- (history, item-price overrides) that don't fit Guild Info's size limit.
--
-- Wire format (v=1, no envelope — the addon owns the entire Guild Info text):
--
--   v1<scalars>;<slots>;<awards>
--
-- Each section is letter-delimited: a key is a run of letters (%a+), a
-- value is everything after up to the next letter or the section's `;`.
-- Empty sections are valid (`v1;;` = no overrides anywhere).
--
-- Skip-defaults: encoder omits any field that equals its default. Decoder
-- resets scalars not present in the block back to their defaults so that
-- removing a customization on the officer side propagates correctly.

local SCHEMA_VERSION = 1
local MAX_BLOCK_LEN  = 500   -- Blizzard server cap on Guild Info text
local DEBOUNCE_SECS  = 1.5

-- One-letter scalar codes. The 4 legacy per-preset fields (epOnTime/etc)
-- are gone — Normal awards now live per-raid in section 3 and difficulty
-- variants are derived via epHeroicMult/MythicMult/AscendedMult.
local SCALAR_CODES = {
    L = "lastDecay",
    B = "basegp",
    I = "gpFormulaStandardIlvl",
    D = "gpFormulaDoublingIlvl",
    M = "osMultiplier",
    C = "decay",
    W = "officerWeeklyEP",
    A = "baseAwardEP",
}
local SCALAR_FIELDS = {}  -- reverse: field name -> letter code
for letter, field in pairs(SCALAR_CODES) do SCALAR_FIELDS[field] = letter end

-- One-letter slot codes (23 slots, 26 uppercase letters available).
-- INVTYPE_ prefix is dropped on the wire; the section's position in the
-- block disambiguates from any other letter-coded data.
local SLOT_CODES = {
    H  = "INVTYPE_HEAD",
    C  = "INVTYPE_CHEST",
    E  = "INVTYPE_ROBE",
    L  = "INVTYPE_LEGS",
    P  = "INVTYPE_SHOULDER",
    G  = "INVTYPE_HAND",
    B  = "INVTYPE_FEET",
    Z  = "INVTYPE_WAIST",
    A  = "INVTYPE_WRIST",
    N  = "INVTYPE_NECK",
    F  = "INVTYPE_FINGER",
    K  = "INVTYPE_CLOAK",
    T  = "INVTYPE_TRINKET",
    X  = "INVTYPE_2HWEAPON",
    W  = "INVTYPE_WEAPON",
    I  = "INVTYPE_WEAPONMAINHAND",
    O  = "INVTYPE_WEAPONOFFHAND",
    D  = "INVTYPE_HOLDABLE",
    S  = "INVTYPE_SHIELD",
    R  = "INVTYPE_RANGED",
    Q  = "INVTYPE_RANGEDRIGHT",
    J  = "INVTYPE_THROWN",
    U  = "INVTYPE_RELIC",
}
local SLOT_LETTERS = {}  -- reverse: INVTYPE_* -> letter
for letter, slot in pairs(SLOT_CODES) do SLOT_LETTERS[slot] = letter end

-- Awards section: 3 single-letter mult codes + compound 2-letter cell codes.
-- Greedy %a+ matching reads the full compound as one key (e.g., `ZT15` →
-- key=ZT, value=15). Mults H/M/A never collide with compound codes because
-- no raid letter is H/M/A.
local MULT_CODES = {
    H = "epHeroicMult",
    M = "epMythicMult",
    A = "epAscendedMult",
}
local RAID_CODES = {
    Z = "ZG",
    C = "MC",
    O = "Onyxia",
    B = "BWL",
    Q = "AQ40",
    N = "Naxx",
}
local RAID_LETTERS = {}  -- reverse: raid key -> letter
for letter, key in pairs(RAID_CODES) do RAID_LETTERS[key] = letter end

local PRESET_CODES = {
    T = "ON_TIME",
    R = "END_OF_RAID",
    F = "FIRST_KILL",
    K = "BOSS_KILL",
}
local PRESET_LETTERS = {}  -- reverse: preset key -> letter
for letter, preset in pairs(PRESET_CODES) do PRESET_LETTERS[preset] = letter end

------------------------------------------------------------------------
-- Number formatting
------------------------------------------------------------------------

-- Letter-delimited parsing relies on values containing only [0-9.\-].
-- string.format("%g", v) can produce scientific notation (e.g. "1e-07")
-- for tiny floats — the `e` would break parsing — so we use %.6f and
-- trim trailing zeros instead.
local function fmtNum(v)
    if type(v) ~= "number" then return tostring(v) end
    if v % 1 == 0 then return tostring(math.floor(v)) end
    local s = string.format("%.6f", v)
    s = s:gsub("0+$", "")
    s = s:gsub("%.$", "")
    return s
end

local function approxEq(a, b)
    if a == b then return true end
    if type(a) ~= "number" or type(b) ~= "number" then return false end
    return math.abs(a - b) < 1e-9
end

------------------------------------------------------------------------
-- Encode
------------------------------------------------------------------------

local function encodeScalars(g)
    local parts = { "v" .. SCHEMA_VERSION }
    -- Iterate in stable order so the block byte-stably reflects state.
    -- Order doesn't matter to the decoder, but it makes diffs and debugging
    -- nicer when the same DB always produces the same block.
    local letters = {}
    for letter in pairs(SCALAR_CODES) do letters[#letters + 1] = letter end
    table.sort(letters)
    for _, letter in ipairs(letters) do
        local field = SCALAR_CODES[letter]
        local v     = g[field]
        local def   = addon.DB_DEFAULTS and addon.DB_DEFAULTS.global
                                        and addon.DB_DEFAULTS.global[field]
        if v ~= nil and not approxEq(v, def) then
            parts[#parts + 1] = letter .. fmtNum(v)
        end
    end
    return table.concat(parts)
end

local function encodeSlots(g)
    if not g.slotMultipliers then return "" end
    local letters = {}
    for letter in pairs(SLOT_CODES) do letters[#letters + 1] = letter end
    table.sort(letters)
    local parts = {}
    for _, letter in ipairs(letters) do
        local slot = SLOT_CODES[letter]
        local v    = g.slotMultipliers[slot]
        local def  = (addon.DEFAULT_SLOT_MULTIPLIERS and
                      addon.DEFAULT_SLOT_MULTIPLIERS[slot]) or 1.0
        if v ~= nil and not approxEq(v, def) then
            parts[#parts + 1] = letter .. fmtNum(v)
        end
    end
    return table.concat(parts)
end

local function encodeAwards(g)
    local parts = {}

    -- Difficulty multipliers (skip if matching VARS default).
    local mults = { "H", "M", "A" }
    for _, letter in ipairs(mults) do
        local field = MULT_CODES[letter]
        local v     = g[field]
        local def   = addon.VARS and addon.VARS[field]
        if v ~= nil and not approxEq(v, def) then
            parts[#parts + 1] = letter .. fmtNum(v)
        end
    end

    -- Per-(raid, preset) cells. Skip cells whose value equals the hardcoded
    -- per-preset default — those reconstruct on the reader side.
    if g.epAwards then
        local raidKeys = {}
        for raid in pairs(g.epAwards) do raidKeys[#raidKeys + 1] = raid end
        table.sort(raidKeys)
        for _, raid in ipairs(raidKeys) do
            local rl = RAID_LETTERS[raid]
            if rl then
                local presetKeys = {}
                for preset in pairs(g.epAwards[raid]) do
                    presetKeys[#presetKeys + 1] = preset
                end
                table.sort(presetKeys)
                for _, preset in ipairs(presetKeys) do
                    local pl  = PRESET_LETTERS[preset]
                    local v   = g.epAwards[raid][preset]
                    local def = addon.PRESET_DEFAULTS
                                and addon.PRESET_DEFAULTS[preset]
                    if pl and v ~= nil and not approxEq(v, def) then
                        parts[#parts + 1] = rl .. pl .. fmtNum(v)
                    end
                end
            end
        end
    end

    return table.concat(parts)
end

function GuildSync:Encode()
    local g = addon.DB and addon.DB.global
    if not g then return "" end
    return encodeScalars(g) .. ";" .. encodeSlots(g) .. ";" .. encodeAwards(g)
end

------------------------------------------------------------------------
-- Decode
------------------------------------------------------------------------

local function parseLetterDelimited(section)
    -- Returns iterator over (key, value) pairs where key is %a+ and value
    -- is the run of non-letter chars that follow it. Empty section yields
    -- no pairs.
    return string.gmatch(section or "", "(%a+)([^%a]*)")
end

local function decodeScalars(section, out)
    -- The version prefix is the first key — `v` followed by digits. Pull
    -- it off and validate; bail cleanly on unknown versions.
    local ver, rest = section:match("^v(%d+)(.*)$")
    if not ver then
        return nil, "no schema version"
    end
    if tonumber(ver) ~= SCHEMA_VERSION then
        return nil, "unsupported schema version: v=" .. ver
    end
    for letter, val in parseLetterDelimited(rest) do
        local field = SCALAR_CODES[letter]
        if field then
            local n = tonumber(val)
            if n then out[field] = n end
        end
    end
    return true
end

local function decodeSlots(section, out)
    out.slotMultipliers = {}
    for letter, val in parseLetterDelimited(section) do
        local slot = SLOT_CODES[letter]
        local n    = tonumber(val)
        if slot and n then out.slotMultipliers[slot] = n end
    end
end

local function decodeAwards(section, out)
    out.epAwards = {}
    for code, val in parseLetterDelimited(section) do
        local n = tonumber(val)
        if n then
            if #code == 1 then
                local field = MULT_CODES[code]
                if field then out[field] = n end
            elseif #code == 2 then
                local raid   = RAID_CODES[code:sub(1, 1)]
                local preset = PRESET_CODES[code:sub(2, 2)]
                if raid and preset then
                    out.epAwards[raid] = out.epAwards[raid] or {}
                    out.epAwards[raid][preset] = n
                end
            end
            -- Unknown code lengths/letters are silently ignored so future
            -- schema additions don't break older clients.
        end
    end
end

function GuildSync:Decode(text)
    if not text or text == "" then return nil end
    local scalars, slots, awards = text:match("^([^;]*);([^;]*);(.*)$")
    if not scalars then return nil end

    local out = {}
    local ok, err = decodeScalars(scalars, out)
    if not ok then return nil, err end

    decodeSlots(slots, out)
    decodeAwards(awards, out)
    return out
end

------------------------------------------------------------------------
-- Read: pull Guild Info → DB.global
------------------------------------------------------------------------

-- Guard against the slider-revert race: when the officer just edited a
-- value, `set` updates DB.global and schedules a debounced Write. If a
-- GUILD_ROSTER_UPDATE fires during that window (which happens on every
-- login/logout/ping in a populated guild), Read would otherwise decode
-- the stale Guild Info text and clobber the in-flight edit. Set to a
-- GetTime() value in WriteDebounced; Reads inside the window no-op.
local readSuppressedUntil = 0

function GuildSync:Read()
    if not GetGuildInfoText then return end
    if not addon.DB then return end
    if GetTime() < readSuppressedUntil then return end
    local data, err = self:Decode(GetGuildInfoText())
    if not data then
        -- Silent on "no schema version" / empty / pre-addon text — that's
        -- the normal case for a guild that hasn't installed yet. Surface
        -- the wrong-version case so an out-of-date client knows to update.
        if err and err:find("unsupported", 1, true) and addon.Print then
            addon.Print("|cFFFF6060Guild Info: " .. err
                .. ". Please update Elitism EPGP.|r")
        end
        return
    end

    local g    = addon.DB.global
    local defs = (addon.DB_DEFAULTS and addon.DB_DEFAULTS.global) or {}

    -- Scalars: missing codes reset to default so removing a customization
    -- on the officer side propagates correctly.
    for _, field in pairs(SCALAR_CODES) do
        if data[field] ~= nil then
            g[field] = data[field]
        else
            g[field] = defs[field]
        end
    end

    -- Difficulty mults: same reset-to-default pattern.
    for _, field in pairs(MULT_CODES) do
        if data[field] ~= nil then
            g[field] = data[field]
        else
            g[field] = (addon.VARS and addon.VARS[field])
        end
    end

    -- Replace whole tables (not merge) so officer-side clears propagate.
    g.slotMultipliers = data.slotMultipliers or {}
    g.epAwards        = data.epAwards        or {}
end

------------------------------------------------------------------------
-- Write (officer-gated). The addon owns the Guild Information text fully —
-- we replace it wholesale rather than merging with non-EEPGP content. This
-- is communicated to officers as a setup caveat in the addon docs.
------------------------------------------------------------------------

function GuildSync:Write()
    if not (CanEditGuildInfo and CanEditGuildInfo()) then
        return false, "no permission to edit Guild Information"
    end
    if not SetGuildInfoText then
        return false, "guild-info API unavailable"
    end

    local block = self:Encode()
    if #block > MAX_BLOCK_LEN then
        return false, string.format(
            "encoded block too large for Guild Information (%d chars; max %d). " ..
            "Reduce per-slot or per-raid overrides.",
            #block, MAX_BLOCK_LEN)
    end

    SetGuildInfoText(block)
    return true
end

------------------------------------------------------------------------
-- WriteDebounced: collapse a burst of officer setting changes (slider
-- drags, multi-cell edits) into a single Guild Info text write 1.5s
-- after the last change. Hidden OnUpdate frame mirrors Sync.lua's
-- pattern to avoid pulling in AceTimer just for this.
------------------------------------------------------------------------

local fireAt   = 0
local pumpFrame

local function ensurePump()
    if pumpFrame then return pumpFrame end
    pumpFrame = CreateFrame("Frame")
    pumpFrame:Hide()
    pumpFrame:SetScript("OnUpdate", function(self)
        if GetTime() < fireAt then return end
        self:Hide()
        local ok, err = GuildSync:Write()
        if not ok and err and addon.Print then
            addon.Print("|cFFFF6060Guild Info sync failed:|r " .. tostring(err))
        end
    end)
    return pumpFrame
end

function GuildSync:WriteDebounced()
    if not (CanEditGuildInfo and CanEditGuildInfo()) then return end
    fireAt = GetTime() + DEBOUNCE_SECS
    -- Suppress incoming Reads until our write fires + a 2s settle window
    -- (covers the moment between SetGuildInfoText running locally and
    -- the server reflecting it back in GetGuildInfoText).
    readSuppressedUntil = fireAt + 2
    ensurePump():Show()
end
