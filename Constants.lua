local _, addon = ...

addon.ADDON_NAME    = "ElitismEPGP"
addon.ADDON_DISPLAY = "Elitism EPGP"
-- Source of truth is the TOC's ## Version line — bumping it there
-- automatically updates the Options page, minimap tooltip, and the
-- version-broadcast Sync message.
addon.VERSION       = (GetAddOnMetadata and GetAddOnMetadata("ElitismEPGP", "Version")) or "0.1.0"
addon.COMM_PREFIX   = "EEPGP"

addon.VARS = {
    basegp                = 100,
    minep                 = 0,
    decay                 = 0.8,
    baseAwardEP           = 10,
    officerWeeklyEP       = 25,
    maxAward              = 1000,
    bidTimeout            = 60,
    maxLogLines           = 500,
    osMultiplier          = 0.10,
    gpFormulaBase         = 1,
    gpFormulaStandardIlvl = 65,   -- Ascension is level-60 capped; vanilla raid gear sits in the 65–92 range.
    gpFormulaDoublingIlvl = 26,   -- Internal storage. Exposed in the UI as "Price ramp = 26 / doubling".
    epHeroicMult          = 1.5,
    epMythicMult          = 2.0,
    epAscendedMult        = 3.0,
    reservesChannel       = "Reserves",
    reservesPattern       = "^([%+%-])(%a*)$",
    bidWhisperPattern     = "^([%+%-])$",
}

-- Default slot multipliers (mirrors the EPGPLootmaster / Sinensis convention).
-- Trinkets cost more, finger/neck/wrist/cloak less, 2H weapons substantially more
-- because they replace both main + offhand. Officers can override per-slot via
-- the options panel; missing entries fall back to 1.0 (treated as "torso-tier").
addon.DEFAULT_SLOT_MULTIPLIERS = {
    INVTYPE_HEAD            = 1.0,
    INVTYPE_CHEST           = 1.0,
    INVTYPE_ROBE            = 1.0,
    INVTYPE_LEGS            = 1.0,
    INVTYPE_SHOULDER        = 0.75,
    INVTYPE_HAND            = 0.75,
    INVTYPE_FEET            = 0.75,
    INVTYPE_WAIST           = 0.75,
    INVTYPE_WRIST           = 0.55,
    INVTYPE_NECK            = 0.55,
    INVTYPE_FINGER          = 0.55,
    INVTYPE_CLOAK           = 0.55,
    INVTYPE_TRINKET         = 1.25,
    INVTYPE_2HWEAPON        = 1.5,
    INVTYPE_WEAPON          = 1.0,
    INVTYPE_WEAPONMAINHAND  = 1.0,
    INVTYPE_WEAPONOFFHAND   = 1.0,
    INVTYPE_HOLDABLE        = 0.55,
    INVTYPE_SHIELD          = 0.75,
    INVTYPE_RANGED          = 1.0,
    INVTYPE_RANGEDRIGHT     = 0.75,
    INVTYPE_THROWN          = 0.5,
    INVTYPE_RELIC           = 1.0,
}

-- ---------------------------------------------------------------------------
-- EP awards: per-raid × per-preset table holding the Normal-difficulty
-- amounts. Heroic / Mythic / Ascended awards are derived at award-time by
-- multiplying the Normal value by epHeroicMult / epMythicMult / epAscendedMult.
-- Cells that aren't set fall back to PRESET_DEFAULTS so officers can leave
-- a preset blank and still get a sensible award.
-- ---------------------------------------------------------------------------
addon.RAIDS = {
    { key = "ZG",     name = "Zul'Gurub"     },
    { key = "MC",     name = "Molten Core"   },
    { key = "Onyxia", name = "Onyxia"        },
    { key = "BWL",    name = "Blackwing Lair" },
}

addon.DIFFICULTIES = { "Normal", "Heroic", "Mythic", "Ascended" }

-- EP preset keys (matches the Awards.Kind.EP_* presets used by Raid Manager).
addon.EP_PRESETS = {
    { key = "ON_TIME",     name = "On Time",     desc = "Awarded when the raid starts." },
    { key = "END_OF_RAID", name = "End of Raid", desc = "Awarded at the end of the raid." },
    { key = "FIRST_KILL",  name = "First Kill",  desc = "First-time progression boss kill." },
    { key = "BOSS_KILL",   name = "Boss Kill",   desc = "Repeated / farm boss kill." },
}

-- Hardcoded per-preset fallback used when an officer leaves a cell blank
-- in an active raid. Not stored in DB or synced — same value on every client.
addon.PRESET_DEFAULTS = {
    ON_TIME     = 10,
    END_OF_RAID = 10,
    FIRST_KILL  = 10,
    BOSS_KILL   = 10,
}

-- Friendly labels for the slot keys, used by the options editor.
addon.SLOT_LABELS = {
    INVTYPE_HEAD            = "Head",
    INVTYPE_CHEST           = "Chest",
    INVTYPE_ROBE            = "Chest (cloth)",
    INVTYPE_LEGS            = "Legs",
    INVTYPE_SHOULDER        = "Shoulder",
    INVTYPE_HAND            = "Hands",
    INVTYPE_FEET            = "Feet",
    INVTYPE_WAIST           = "Waist",
    INVTYPE_WRIST           = "Wrist",
    INVTYPE_NECK            = "Neck",
    INVTYPE_FINGER          = "Finger",
    INVTYPE_CLOAK           = "Cloak",
    INVTYPE_TRINKET         = "Trinket",
    INVTYPE_2HWEAPON        = "Two-Hand",
    INVTYPE_WEAPON          = "One-Hand",
    INVTYPE_WEAPONMAINHAND  = "Main Hand",
    INVTYPE_WEAPONOFFHAND   = "Off-Hand (weapon)",
    INVTYPE_HOLDABLE        = "Held In Off-Hand",
    INVTYPE_SHIELD          = "Shield",
    INVTYPE_RANGED          = "Ranged",
    INVTYPE_RANGEDRIGHT     = "Ranged (wand)",
    INVTYPE_THROWN          = "Thrown",
    INVTYPE_RELIC           = "Relic",
}

addon.DB_DEFAULTS = {
    global = {
        basegp                = addon.VARS.basegp,
        minep                 = addon.VARS.minep,
        decay                 = addon.VARS.decay,
        baseAwardEP           = addon.VARS.baseAwardEP,
        officerWeeklyEP       = addon.VARS.officerWeeklyEP,
        maxAward              = addon.VARS.maxAward,
        bidTimeout            = addon.VARS.bidTimeout,
        osMultiplier          = addon.VARS.osMultiplier,
        gpFormulaBase         = addon.VARS.gpFormulaBase,
        gpFormulaStandardIlvl = addon.VARS.gpFormulaStandardIlvl,
        gpFormulaDoublingIlvl = addon.VARS.gpFormulaDoublingIlvl,
        prices                = {},
        standby               = {},
        history               = {},
        lastDecay             = nil,
        -- Difficulty multipliers applied to the Normal award at award-time:
        -- Heroic = Normal × epHeroicMult, etc. Officers tune these in Options.
        epHeroicMult          = addon.VARS.epHeroicMult,
        epMythicMult          = addon.VARS.epMythicMult,
        epAscendedMult        = addon.VARS.epAscendedMult,
        slotMultipliers       = {},  -- empty = use DEFAULT_SLOT_MULTIPLIERS; per-key entries override
        -- Per-raid × per-preset EP amounts (Normal difficulty). Heroic/
        -- Mythic/Ascended are derived via the multipliers above. Missing
        -- cells fall back to addon.PRESET_DEFAULTS. Shape:
        -- epAwards[RAID_KEY][PRESET_KEY] = N.
        epAwards              = {},
        -- Auto-snapshot ring buffer (see Backup.lua). Destructive ops
        -- push a snapshot here before mutating; oldest entries fall off
        -- once the buffer reaches its cap (see Backup.MAX_AUTO_SNAPSHOTS).
        autoSnapshots         = {},
    },
    profile = {
        windowPos             = nil,
        debug                 = false,
        -- Highest version this character has already been notified about
        -- via the Sync version-broadcast. Keeps the "newer version
        -- available" message from firing again on every login once the
        -- user has seen it.
        versionWarned         = nil,
        minimap               = { hide = false },
        dev                   = false,
        mockRaid              = {},
        -- Award automation mode: "manual" (no auto EP — RL clicks Award),
        -- "suggest" (confirmation modal on start/end raid + boss kill
        -- banner), "auto" (everything fires without prompts). Default
        -- is "suggest" so a fresh install surfaces every grant for
        -- review before committing. Replaces the legacy `bossKillMode`
        -- field — old profiles are migrated in Core.lua's OnInitialize.
        awardsMode            = "suggest",
        raidManagerPos        = nil,
        mockEntries           = {},
        showSelfStar          = true,
        classColorsInStandings = true,
        selfRowHighlight      = true,
        bidFramePos           = nil,
        lootQueuePos          = nil,
        raidActive            = false,
        activeController      = nil,
        raidSessionStartedAt  = nil,
        currentRaid           = nil,  -- selected raid key (e.g. "MC") for the active session
        currentDifficulty     = nil,  -- selected difficulty (e.g. "Normal")
        bidModifier           = "ALT",
        bidClick              = "LeftButton",
        -- Legacy enable toggle. Kept for back-compat with stored profiles;
        -- no UI references it now — the modifier+click selects are the
        -- sole trigger configuration.
        bidEnableClick        = true,
        tooltipShowGP         = true,
        tooltipMinQuality     = 4,  -- 4 = Epic+
        tooltipShowPR         = true,
        bgOpacity             = 89,  -- main window backdrop opacity, percent
        colorNameByClass      = false,  -- when true, Name and Rank columns use class color
        -- confirmRaidStartEnd retired in v0.1.1 — the unified `awardsMode`
        -- field above now controls confirmation behavior (manual / suggest
        -- / auto). Legacy profiles' stored value is ignored.
    },
}

addon.CLASS_COLORS = {
    DEATHKNIGHT = "C41F3B", DRUID       = "FF7D0A", HUNTER  = "ABD473",
    MAGE        = "69CCF0", PALADIN     = "F58CBA", PRIEST  = "FFFFFF",
    ROGUE       = "FFF569", SHAMAN      = "0070DE", WARLOCK = "9482C9",
    WARRIOR     = "C79C6E",
}

-- Wrap a player name in its class colour. Returns a Blizzard-standard
-- clickable player link (`|cffXXXXXX|Hplayer:Name|hName|h|r`) — the same
-- format LFG / LFR / whisper announcements use. The hyperlink wrapping is
-- the part that matters for raid CHAT: WoW 3.3.5a's chat parser accepts a
-- second `|c…|r` after an item link only when it's inside a recognised
-- `|H…|h…|h` hyperlink, otherwise the message is silently dropped. Plain
-- chat-frame output (`addon.Print`) handles the link form too.
--
-- Falls back to the bare name when the roster hasn't loaded the class yet
-- or the player isn't in the guild roster. Accepts an explicit classFile
-- override so callers that already have it (bidder rows) don't re-lookup.
function addon.ColorName(name, classFile)
    if not name or name == "" then return name or "" end
    if not classFile and addon.Roster and addon.Roster.Get then
        local entry = addon.Roster:Get(name)
        classFile = entry and entry.classFile
    end
    local hex = classFile and addon.CLASS_COLORS and addon.CLASS_COLORS[classFile]
    if not hex then
        return string.format("|Hplayer:%s|h%s|h", name, name)
    end
    return string.format("|cff%s|Hplayer:%s|h%s|h|r", hex:lower(), name, name)
end

-- ---------------------------------------------------------------------------
-- Permission helpers (3.3.5a APIs return 1/nil, never compare with == true).
-- IsOfficer:        guild rank with Edit Officer Note permission
-- InRaid:           player is in a raid group (not a 5-man party)
-- IsRaidLeaderHere: player is the actual raid leader RIGHT NOW
-- IsMasterLooterHere: master loot is set AND player is the master looter
-- CanAwardEP:       officer + raid leader (gates Start/End + manual EP awards)
-- CanRunBidSession: officer + (raid leader OR master looter)
-- ---------------------------------------------------------------------------

function addon.IsOfficer()
    return CanEditOfficerNote and CanEditOfficerNote() and true or false
end

function addon.InRaid()
    return GetNumRaidMembers and GetNumRaidMembers() > 0 and true or false
end

function addon.IsRaidLeaderHere()
    if not addon.InRaid() then return false end
    return IsPartyLeader and IsPartyLeader() and true or false
end

function addon.IsMasterLooterHere()
    if not GetLootMethod then return false end
    local method, masterPartyID, masterRaidID = GetLootMethod()
    if method ~= "master" then return false end
    -- masterRaidID == 0 (or masterPartyID == 0 in party) means the player is the ML.
    if addon.InRaid() then
        return (masterRaidID or 0) == 0
    end
    return (masterPartyID or 0) == 0
end

function addon.CanAwardEP()
    return addon.IsOfficer() and addon.IsRaidLeaderHere()
end

function addon.CanRunBidSession()
    return addon.IsOfficer() and (addon.IsRaidLeaderHere() or addon.IsMasterLooterHere())
end

-- ---------------------------------------------------------------------------
-- Modifier-key matcher used by Loot.lua's bid trigger. Combos are exclusive
-- — "ALT" requires alt down AND ctrl/shift up — so unrelated alt+click
-- handlers can't accidentally fire on the same click.
-- ---------------------------------------------------------------------------

function addon.ModifierMatches(mod)
    local alt   = IsAltKeyDown     and IsAltKeyDown()     and true or false
    local ctrl  = IsControlKeyDown and IsControlKeyDown() and true or false
    local shift = IsShiftKeyDown   and IsShiftKeyDown()   and true or false
    if mod == "NONE"      then return not alt and not ctrl and not shift end
    if mod == "ALT"       then return alt   and not ctrl and not shift end
    if mod == "CTRL"      then return ctrl  and not alt  and not shift end
    if mod == "SHIFT"     then return shift and not alt  and not ctrl  end
    if mod == "ALT_CTRL"  then return alt   and ctrl     and not shift end
    if mod == "SHIFT_ALT" then return shift and alt      and not ctrl  end
    if mod == "SHIFT_CTRL" then return shift and ctrl    and not alt   end
    return false
end

-- Returns true when the user's currently-clicked mouse button matches the
-- requested binding (e.g. "LeftButton"). Only valid inside an OnClick /
-- HandleModifiedItemClick context — outside, GetMouseButtonClicked() may
-- return nil. For paths where the button is unknown (e.g., SetItemRef on
-- chat hyperlinks in 3.3.5a) we fall through to LeftButton, the common case.
function addon.ButtonMatches(btn)
    if not btn or btn == "" then return false end
    local actual = GetMouseButtonClicked and GetMouseButtonClicked() or nil
    if not actual then return btn == "LeftButton" end
    return actual == btn
end
