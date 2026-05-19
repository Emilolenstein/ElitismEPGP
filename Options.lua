local _, addon = ...

local Options = {}
addon.Options = Options

local AceConfig         = LibStub("AceConfig-3.0")
local AceConfigDialog   = LibStub("AceConfigDialog-3.0")

local APP_KEY            = "ElitismEPGP"
local APP_KEY_GUILD      = "ElitismEPGP_GuildMgmt"
local APP_KEY_EP_AWARDS  = "ElitismEPGP_EPAwards"
local APP_KEY_GEAR_POINTS = "ElitismEPGP_GearPoints"
local APP_KEY_BACKUP     = "ElitismEPGP_Backup"
local APP_KEY_DISPLAY    = "ElitismEPGP_Display"
local DISPLAY_NAME       = "Elitism EPGP"

local function G() return addon.DB and addon.DB.global  end
local function P() return addon.DB and addon.DB.profile end

-- Sync helpers: each guild-shared config edit broadcasts a per-key LWW
-- envelope so peers converge automatically. Profile-scope (P) values
-- stay local — they're per-character preferences. Slider drag-fires are
-- absorbed by Sync's debounce window, so only the final value ships.
-- Keys that now live in Guild Info via GuildSync (single source of truth).
-- A change to any of these triggers a debounced rewrite of the Guild Info
-- block; it does NOT fire AceComm config-domain notify, since that domain
-- no longer carries them.
local GUILDINFO_KEYS = {
    basegp = true, gpFormulaStandardIlvl = true, gpFormulaDoublingIlvl = true,
    osMultiplier = true,
    decay = true,
    officerWeeklyEP = true, baseAwardEP = true,
    epHeroicMult = true, epMythicMult = true, epAscendedMult = true,
}

local function notifyConfig(key)
    if GUILDINFO_KEYS[key] then
        if addon.GuildSync and addon.GuildSync.WriteDebounced then
            addon.GuildSync:WriteDebounced()
        end
        return
    end
    if addon.Sync and addon.Sync.Notify then addon.Sync:Notify("config", key) end
end
local function notifySlotMult(_)
    -- Slot multipliers also live in Guild Info now; one debounced write
    -- ships the full table regardless of which slot changed.
    if addon.GuildSync and addon.GuildSync.WriteDebounced then
        addon.GuildSync:WriteDebounced()
    end
end
local function notifyEPAward(_, _)
    -- Same story for the per-raid×preset EP awards matrix (Normal values).
    if addon.GuildSync and addon.GuildSync.WriteDebounced then
        addon.GuildSync:WriteDebounced()
    end
end

-- Modifier + click choices for the bid shortcut selects. Display order
-- mirrors the dropdown order; "None" first since it's the simplest combo
-- (no modifier required).
local MOD_CHOICES = {
    NONE       = "None",
    ALT        = "Alt",
    CTRL       = "Ctrl",
    SHIFT      = "Shift (chat conflict)",
    ALT_CTRL   = "Alt + Ctrl",
    SHIFT_ALT  = "Shift + Alt",
    SHIFT_CTRL = "Shift + Ctrl",
}
local CLICK_CHOICES = {
    LeftButton   = "Left Click",
    RightButton  = "Right Click",
    MiddleButton = "Middle Click",
}


local function refreshRaidManager()
    if addon.UI and addon.UI.RaidManager then
        if addon.UI.RaidManager.RefreshModeLabel     then addon.UI.RaidManager:RefreshModeLabel()     end
        if addon.UI.RaidManager.RefreshSettingsRadios then addon.UI.RaidManager:RefreshSettingsRadios() end
    end
end

-- Decay is stored internally as a multiplier (0.8 = 20% decay).
-- The user-facing field is the decay percent (20 means 20%).
local function decayPct()
    local m = (G() and G().decay) or addon.VARS.decay
    return math.floor(((1 - m) * 100) + 0.5)
end
local function setDecayPct(v)
    v = tonumber(v) or 20
    if v < 0  then v = 0  end
    if v > 99 then v = 99 end
    G().decay = 1 - (v / 100)
    notifyConfig("decay")
end

-- osMultiplier shown to user as percent (10 means 10%).
local function osPct()
    local m = (G() and G().osMultiplier) or addon.VARS.osMultiplier
    return math.floor(((m or 0) * 100) + 0.5)
end
local function setOsPct(v)
    v = tonumber(v) or 10
    if v < 0   then v = 0   end
    if v > 100 then v = 100 end
    G().osMultiplier = v / 100
    notifyConfig("osMultiplier")
end

local function isOfficer()
    if not CanEditOfficerNote then return false end
    return CanEditOfficerNote() and true or false
end

-- Slot category map: Armor = wearables (incl. shield + held off-hand,
-- since they sit in armor slots and follow the defensive scaling pattern).
-- Accessories = neck / rings / trinkets / relics. Weapons = anything that
-- swings or shoots, plus thrown.
local SLOT_CATEGORY = {
    INVTYPE_HEAD          = "armor",
    INVTYPE_CHEST         = "armor",
    INVTYPE_ROBE          = "armor",
    INVTYPE_LEGS          = "armor",
    INVTYPE_SHOULDER      = "armor",
    INVTYPE_HAND          = "armor",
    INVTYPE_FEET          = "armor",
    INVTYPE_WAIST         = "armor",
    INVTYPE_WRIST         = "armor",
    INVTYPE_CLOAK         = "armor",
    INVTYPE_SHIELD        = "armor",
    INVTYPE_HOLDABLE      = "armor",
    INVTYPE_NECK          = "accessory",
    INVTYPE_FINGER        = "accessory",
    INVTYPE_TRINKET       = "accessory",
    INVTYPE_RELIC         = "accessory",
    INVTYPE_2HWEAPON      = "weapon",
    INVTYPE_WEAPON        = "weapon",
    INVTYPE_WEAPONMAINHAND = "weapon",
    INVTYPE_WEAPONOFFHAND  = "weapon",
    INVTYPE_RANGED        = "weapon",
    INVTYPE_RANGEDRIGHT   = "weapon",
    INVTYPE_THROWN        = "weapon",
}

-- Forward declaration: the reset closure inside makeSlotMultiplierArgs
-- (below) references resetSlotMultipliers, but the function body lives
-- further down in this file. Without this `local` at the top of the
-- scope block, the closure resolves to a nil global at click time.
local resetSlotMultipliers

-- Returns AceConfig args of range sliders for every slot in `category`
-- ("armor", "accessory", or "weapon"), sorted alphabetically by display
-- label. Includes a per-category "Reset to defaults" button at the bottom.
local function makeSlotMultiplierArgs(category)
    local args = {}
    local keys = {}
    for k in pairs(addon.DEFAULT_SLOT_MULTIPLIERS or {}) do
        if SLOT_CATEGORY[k] == category then keys[#keys + 1] = k end
    end
    table.sort(keys, function(a, b)
        return (addon.SLOT_LABELS[a] or a) < (addon.SLOT_LABELS[b] or b)
    end)
    for i, key in ipairs(keys) do
        local label = addon.SLOT_LABELS[key] or key
        args[key] = {
            type = "range", order = i,
            name = label,
            desc = string.format("Multiplier for %s. Default: %.2f.",
                label, addon.DEFAULT_SLOT_MULTIPLIERS[key] or 1.0),
            min = 0, max = 3, step = 0.05,
            get = function()
                local g = G()
                local v = g and g.slotMultipliers and g.slotMultipliers[key]
                if v ~= nil then return v end
                return addon.DEFAULT_SLOT_MULTIPLIERS[key] or 1.0
            end,
            set = function(_, v)
                if not G() then return end
                G().slotMultipliers = G().slotMultipliers or {}
                G().slotMultipliers[key] = v
                notifySlotMult(key)
            end,
        }
    end
    args._resetSpacer = {
        type = "description", order = 998, name = "",
    }
    args._reset = {
        type = "execute", order = 999, name = "Reset to Defaults",
        desc = string.format("Clear all %s slot overrides and fall back to the bundled defaults.", category),
        func = function() resetSlotMultipliers(category) end,
    }
    return args
end

-- Reset helpers (per section, per category). Each clears the relevant
-- DB keys back to defaults and triggers a single debounced Guild Info
-- write — debounce coalesces the burst of notifications into one block.

-- Per-category slot reset. With no category, clears every slot override.
-- Assigned (not declared) so the forward-declared local above is bound
-- — otherwise the closure that captures it earlier would see nil.
function resetSlotMultipliers(category)
    local g = G()
    if not g or not g.slotMultipliers then return end
    local toClear = {}
    for slot in pairs(g.slotMultipliers) do
        if not category or SLOT_CATEGORY[slot] == category then
            toClear[#toClear + 1] = slot
        end
    end
    for _, slot in ipairs(toClear) do
        g.slotMultipliers[slot] = nil
    end
    if #toClear > 0 then notifySlotMult(nil) end
end

local function resetWeeklyMaintenance()
    local g = G()
    if not g then return end
    g.decay           = addon.VARS.decay
    g.officerWeeklyEP = addon.VARS.officerWeeklyEP
    notifyConfig("decay")
    notifyConfig("officerWeeklyEP")
end

local function resetDifficultyMults()
    local g = G()
    if not g then return end
    g.epHeroicMult   = addon.VARS.epHeroicMult
    g.epMythicMult   = addon.VARS.epMythicMult
    g.epAscendedMult = addon.VARS.epAscendedMult
    notifyConfig("epHeroicMult")
    notifyConfig("epMythicMult")
    notifyConfig("epAscendedMult")
end

local function resetRaidAwards(raidKey)
    local g = G()
    if not g or not g.epAwards then return end
    if g.epAwards[raidKey] then
        g.epAwards[raidKey] = nil
        notifyEPAward(raidKey, nil)
    end
end

local function resetGPFormula()
    local g = G()
    if not g then return end
    g.basegp                = addon.VARS.basegp
    g.gpFormulaStandardIlvl = addon.VARS.gpFormulaStandardIlvl
    g.gpFormulaDoublingIlvl = addon.VARS.gpFormulaDoublingIlvl
    g.osMultiplier          = addon.VARS.osMultiplier
    notifyConfig("basegp")
    notifyConfig("gpFormulaStandardIlvl")
    notifyConfig("gpFormulaDoublingIlvl")
    notifyConfig("osMultiplier")
end

-- Per-raid difficulty-scaling preview. Each value cell is its own
-- description widget with a fixed width so the rendered grid lines up as
-- a proper table. The `name` field is a function so AceConfig re-evaluates
-- it on every page render — slider drags refresh the preview live.

local DIFF_MULT_FIELD = {
    Heroic   = "epHeroicMult",
    Mythic   = "epMythicMult",
    Ascended = "epAscendedMult",
}
local DIFF_DEFAULT_MULT = {
    Heroic   = 1.5,
    Mythic   = 2.0,
    Ascended = 3.0,
}
local DIFF_LIST = { "Heroic", "Mythic", "Ascended" }

local function diffMultFor(difficulty)
    local g     = G() or {}
    local field = DIFF_MULT_FIELD[difficulty]
    return g[field] or (addon.VARS and addon.VARS[field]) or DIFF_DEFAULT_MULT[difficulty] or 1.0
end

local function presetCellFor(raidKey, presetKey)
    local g = G() or {}
    return (g.epAwards and g.epAwards[raidKey] and g.epAwards[raidKey][presetKey])
        or (addon.PRESET_DEFAULTS and addon.PRESET_DEFAULTS[presetKey]) or 10
end

local function formatCellValue(raidKey, presetKey, difficulty)
    local cell   = presetCellFor(raidKey, presetKey)
    local scaled = math.floor(cell * diffMultFor(difficulty) + 0.5)
    return "|cFFFFFFFF" .. tostring(scaled) .. "|r"
end

-- Builds the args table for the inline "Higher Difficulty Preview" group:
-- 4-column table at "half" width each (4 × 0.5 = 2.0 = exactly the panel's
-- usable width, so columns tile cleanly without wrapping).
--   Row 0: header  — Raid | Heroic | Mythic | Ascended
--   Row 1: mults   — Multiplier | <h-mult> | <m-mult> | <a-mult>
--   Rows 2-5:      — <preset name> | <scaled> | <scaled> | <scaled>
local function buildDifficultyPreviewArgs(raidKey)
    local args = {}

    args.h_label = {
        type = "description", order = 1, fontSize = "medium",
        name = "|cFFFFCC00Raid|r", width = "half",
    }
    for di, dif in ipairs(DIFF_LIST) do
        args["h_" .. dif] = {
            type = "description", order = 1 + di, fontSize = "medium",
            name = "|cFFFFCC00" .. dif .. "|r", width = "half",
        }
    end

    args.mult_label = {
        type = "description", order = 10, fontSize = "medium",
        name = "|cFFCCCCCCMultiplier|r", width = "half",
    }
    for di, dif in ipairs(DIFF_LIST) do
        args["mult_" .. dif] = {
            type = "description", order = 10 + di, fontSize = "medium",
            name = function()
                return string.format("|cFFFFFFFF%g|r", diffMultFor(dif))
            end,
            width = "half",
        }
    end

    for pi, preset in ipairs(addon.EP_PRESETS or {}) do
        local presetKey = preset.key
        local rowOrder  = 20 + 10 * pi

        args["row_" .. pi .. "_label"] = {
            type = "description", order = rowOrder, fontSize = "medium",
            name = "|cFFCCCCCC" .. preset.name .. "|r", width = "half",
        }
        for di, dif in ipairs(DIFF_LIST) do
            args["row_" .. pi .. "_" .. dif] = {
                type = "description", order = rowOrder + di, fontSize = "medium",
                name = function() return formatCellValue(raidKey, presetKey, dif) end,
                width = "half",
            }
        end
    end

    return args
end

local function refreshStandings()
    if addon.UI and addon.UI.StandingsTab and addon.UI.StandingsTab.Refresh
       and ElitismEPGPMainFrame and ElitismEPGPMainFrame:IsShown() then
        addon.UI.StandingsTab:Refresh()
    end
end

local function resetMainFramePos()
    P().windowPos = nil
    if ElitismEPGPMainFrame then
        ElitismEPGPMainFrame:ClearAllPoints()
        ElitismEPGPMainFrame:SetPoint("CENTER")
    end
    addon.Print("Main window position reset.")
end

local function resetRaidManagerPos()
    P().raidManagerPos = nil
    if ElitismEPGPRaidManagerFrame then
        ElitismEPGPRaidManagerFrame:ClearAllPoints()
        ElitismEPGPRaidManagerFrame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    end
    addon.Print("Raid Manager position reset.")
end

local function resetMinimapPos()
    if P().minimap then P().minimap.minimapPos = nil end
    if addon.Minimap and addon.Minimap.RefreshPosition then addon.Minimap:RefreshPosition() end
    addon.Print("Minimap button position reset.")
end

-- ---------------------------------------------------------------------------
-- Officer & RL — separate sidebar page (officer/GM only by hidden gate
-- on the inner group; the sidebar entry itself is always present so
-- promoting a player mid-session reveals the controls without /reload).
-- ---------------------------------------------------------------------------
local function guildManagementGroup()
    return {
        type = "group", name = "Officer & RL",
        args = {
            memberNotice = {
                type = "description", order = 1, fontSize = "medium",
                hidden = function() return isOfficer() end,
                name = "|cFFAAAAAAThese settings can only be changed by officers and the Guild Master. Your team has access to them.|r",
            },
            officerOnly = {
                type = "group", order = 10, name = "", inline = true,
                hidden = function() return not isOfficer() end,
                args = {

            header_awards = {
                type = "header", order = 20, name = "Awards Points",
            },
            awardsDesc = {
                type = "description", order = 21, fontSize = "small",
                name = "Controls how much the addon does automatically when you Start / End a raid and when a boss dies. Lower = fewer surprises; higher = less clicking.",
            },
            awardsMode = {
                type = "select", order = 22, name = "Mode",
                desc = "Manual: nothing fires automatically — you award EP with the preset buttons in the Raid Manager.\n"
                    .. "Suggest: a confirmation modal appears on Start / End raid + on boss kill so you can review before granting.\n"
                    .. "Auto: Start / End raid and boss kills auto-grant EP immediately with no prompts.",
                values = {
                    manual  = "Manual (you click Award for everything)",
                    suggest = "Suggest (confirmation modal on each event)",
                    auto    = "Auto (everything fires immediately)",
                },
                get = function() return P().awardsMode or "manual" end,
                set = function(_, v) P().awardsMode = v; refreshRaidManager() end,
            },

            header_decay = {
                type = "header", order = 30, name = "Weekly Maintenance",
            },
            decay = {
                type = "range", order = 31, name = "Decay %",
                desc = "Percent decayed from EP and GP each weekly maintenance run. Stored internally as a multiplier (0.8 = 20%).",
                min = 0, max = 99, step = 1,
                get = decayPct, set = function(_, v) setDecayPct(v) end,
            },
            officerWeeklyEP = {
                type = "range", order = 32, name = "Officer/GM weekly EP",
                desc = "EP awarded to each guild member whose rank has the \"Edit Officer Note\" permission, on weekly maintenance.",
                min = 0, max = 200, step = 1,
                get = function() return G().officerWeeklyEP or addon.VARS.officerWeeklyEP end,
                set = function(_, v) G().officerWeeklyEP = v; notifyConfig("officerWeeklyEP") end,
            },
            weeklyResetSpacer = {
                type = "description", order = 33, name = "",
            },
            weeklyReset = {
                type = "execute", order = 34, name = "Reset to Defaults",
                desc = "Reset Weekly Maintenance values (decay percent, officer/GM weekly EP) to the bundled defaults.",
                func = resetWeeklyMaintenance,
            },

            -- GP Formula (Base GP, Base ilvl, Price ramp, Off-spec %, Slot Multipliers)
            -- now lives in its own |cFFFFCC00Gear Points|r sidebar entry. Keeping
            -- it out of Officer & RL lets us scope formula tunables next
            -- to the related Effort Points page and reduces the sprawl here.

            header_loot = {
                type = "header", order = 70, name = "Loot Bidding",
            },
            bidModifier = {
                type = "select", order = 71, name = "Bid modifier",
                desc = "Modifier held while clicking to open a bid session.",
                values = MOD_CHOICES,
                get = function() return P().bidModifier or "ALT" end,
                set = function(_, v) P().bidModifier = v end,
            },
            bidClick = {
                type = "select", order = 72, name = "Bid click",
                desc = "Mouse button used (with the modifier above) to open a bid session.",
                values = CLICK_CHOICES,
                get = function() return P().bidClick or "LeftButton" end,
                set = function(_, v) P().bidClick = v end,
            },
            bidTimeout = {
                type = "range", order = 73, name = "Bid timeout (seconds)",
                desc = "How long bid sessions stay open before timing out.",
                min = 15, max = 180, step = 5,
                get = function() return G().bidTimeout or addon.VARS.bidTimeout end,
                set = function(_, v) G().bidTimeout = v; notifyConfig("bidTimeout") end,
            },

            header_raidManager = {
                type = "header", order = 80, name = "Raid Manager",
            },
            resetRaidManager = {
                type = "execute", order = 81, name = "Reset Raid Manager",
                desc = "Restore the Raid Manager window's default screen position.",
                func = resetRaidManagerPos,
            },
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Backup — officer-only sidebar page. Hosts a description of where the
-- raw SavedVariables file lives + a button that opens the same dialog the
-- cog menu / minimap right-click surfaces. The actual UI is the custom
-- BackupFrame; this page is just an entry point so officers who live in
-- the Interface > AddOns panel have a reachable surface for it.
-- ---------------------------------------------------------------------------
local function backupGroup()
    return {
        type = "group", name = "Backups",
        args = {
            intro = {
                type = "description", order = 1, fontSize = "medium",
                name = "Snapshot the addon's state to a copy-pasteable blob and restore from one when something goes sideways. Auto-snapshots are taken before destructive ops (reset, weekly maintenance) so they're recoverable.",
            },
            sep1 = { type = "header", order = 5, name = "" },

            btnOpen = {
                type = "execute", order = 10, name = "Open Backup window",
                desc = "Open the full Backup & Restore window (same surface the cog menu and minimap right-click open).",
                width = "double",
                func = function()
                    InterfaceOptionsFrame:Hide()  -- so the dialog isn't hidden behind the panel
                    if addon.UI and addon.UI.BackupFrame and addon.UI.BackupFrame.Open then
                        addon.UI.BackupFrame:Open()
                    end
                end,
            },

            sep2 = { type = "header", order = 20, name = "Off-site (filesystem) backups" },

            fileNote = {
                type = "description", order = 21, fontSize = "medium",
                name = "All of Elitism EPGP's saved state lives in a single SavedVariables file. Copy this file elsewhere (USB stick, cloud drive, Discord upload) for a full off-site backup. To restore, exit WoW, drop the copy back in place, log in.",
            },
            filePath = {
                type = "description", order = 22, fontSize = "medium",
                name = "|cFFFFD200File path:|r\n|cFFAAAAAA…\\WTF\\Account\\<ACCOUNT_NAME>\\SavedVariables\\ElitismEPGP.lua|r\n\n<ACCOUNT_NAME> is the ALL-CAPS account folder for your Ascension login, not your character's name.",
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Display — separate sidebar page, visible to everyone.
-- ---------------------------------------------------------------------------
local function displayGroup()
    return {
        type = "group", name = "Display",
        args = {
            header_appearance = {
                type = "header", order = 5, name = "Appearance",
            },
            bgOpacity = {
                type = "range", order = 6, name = "Background opacity",
                desc = "Transparency of the main window's dark background. Lower values let the world behind the window show through.",
                min = 0, max = 100, step = 1,
                get = function() return P().bgOpacity or 89 end,
                set = function(_, v)
                    P().bgOpacity = v
                    if addon.UI and addon.UI.Skin and addon.UI.Skin.RefreshOpacity then
                        addon.UI.Skin:RefreshOpacity()
                    end
                end,
                width = "double",
            },

            header_standings = {
                type = "header", order = 10, name = "Standings list",
            },
            showSelfStar = {
                type = "toggle", order = 11, name = "Highlight my row with a star",
                desc = "Show a gold ★ next to your character's name in the standings list.",
                get = function() return P().showSelfStar ~= false end,
                set = function(_, v) P().showSelfStar = v and true or false; refreshStandings() end,
                width = "double",
            },
            classColorsInStandings = {
                type = "toggle", order = 12, name = "Color the Class column by class",
                desc = "Color class names using their class color (Mage = blue, Druid = orange, etc.). Disable for a flatter look.",
                get = function() return P().classColorsInStandings ~= false end,
                set = function(_, v) P().classColorsInStandings = v and true or false; refreshStandings() end,
                width = "double",
            },
            colorNameByClass = {
                type = "toggle", order = 13, name = "Color Name (and Rank) by class",
                desc = "Tint the Name and Rank columns with the player's class color. Off by default — names stay yellow and the rank number matches.",
                get = function() return P().colorNameByClass and true or false end,
                set = function(_, v) P().colorNameByClass = v and true or false; refreshStandings() end,
                width = "double",
            },
            selfRowHighlight = {
                type = "toggle", order = 14, name = "Highlight my row in the standings",
                desc = "Always show a soft highlight band on your character's row in the standings list. The hover highlight still takes over while the cursor is on the row.",
                get = function() return P().selfRowHighlight ~= false end,
                set = function(_, v) P().selfRowHighlight = v and true or false; refreshStandings() end,
                width = "double",
            },

            header_tooltip = {
                type = "header", order = 15, name = "Item tooltip",
            },
            tooltipShowGP = {
                type = "toggle", order = 16, name = "Show item GP in tooltip",
                desc = "Append the mainspec / offspec GP cost to item tooltips at or above the quality threshold.",
                get = function() return P().tooltipShowGP ~= false end,
                set = function(_, v) P().tooltipShowGP = v and true or false end,
                width = "double",
            },
            tooltipShowPR = {
                type = "toggle", order = 17, name = "Show projected PR in tooltip",
                desc = "Show what your PR (Priority = EP/GP) would be if you took the item as Need.",
                get = function() return P().tooltipShowPR ~= false end,
                set = function(_, v) P().tooltipShowPR = v and true or false end,
                width = "double",
            },
            tooltipMinQuality = {
                type = "select", order = 18, name = "Quality threshold",
                desc = "Lowest item quality that adds the GP/PR lines. Lower thresholds add noise to commons.",
                values = { [2] = "Uncommon (green)", [3] = "Rare (blue)", [4] = "Epic (purple)", [5] = "Legendary (orange)" },
                get = function() return P().tooltipMinQuality or 4 end,
                set = function(_, v) P().tooltipMinQuality = v end,
            },

            header_minimap = {
                type = "header", order = 20, name = "Minimap button",
            },
            showMinimap = {
                type = "toggle", order = 21, name = "Show minimap button",
                desc = "Toggle the Elitism EPGP minimap button on or off.",
                get = function()
                    return not (P().minimap and P().minimap.hide)
                end,
                set = function(_, v)
                    if not P().minimap then P().minimap = { hide = false } end
                    P().minimap.hide = not v
                    if addon.Minimap then
                        if v and addon.Minimap.Show then addon.Minimap:Show()
                        elseif not v and addon.Minimap.Hide then addon.Minimap:Hide() end
                    end
                end,
                width = "double",
            },

            header_positions = {
                type = "header", order = 30, name = "Reset window positions",
            },
            positionsDesc = {
                type = "description", order = 31, fontSize = "small",
                name = "Restore the default screen position for each window.",
            },
            resetMain = {
                type = "execute", order = 32, name = "Reset Main Window",
                func = resetMainFramePos,
            },
            resetMM = {
                type = "execute", order = 34, name = "Reset Minimap Button",
                func = resetMinimapPos,
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- EP Award Amounts — its own sidebar page. Side tree branches:
--   * "Difficulty Multipliers" — three sliders (Heroic/Mythic/Ascended) that
--     scale the raid's Normal value at award time.
--   * One branch per raid in addon.RAIDS, each showing the 4 preset sliders
--     for the Normal-difficulty award. Officers leaving a slider at the
--     hardcoded preset default (addon.PRESET_DEFAULTS) means "use default";
--     anything else gets stored as an explicit cell.
-- ---------------------------------------------------------------------------
local function epAwardsGroup()
    local raidArgs = {}

    raidArgs.multipliers = {
        type = "group", order = 0, name = "Difficulty Multipliers",
        args = {
            desc = {
                type = "description", order = 1, fontSize = "small",
                name = "Multiplier applied to each raid's Normal-difficulty award when "
                    .. "the raid leader picks Heroic, Mythic, or Ascended on the Raid "
                    .. "Manager. Normal awards stay at ×1.0.",
            },
            spacer = { type = "description", order = 2, name = "\n" },
            epHeroicMult = {
                type = "range", order = 10, name = "Heroic ×",
                desc = "Multiplier applied to Normal awards on Heroic difficulty.",
                min = 1.0, max = 10.0, step = 0.1, isPercent = false,
                get = function() return G().epHeroicMult or addon.VARS.epHeroicMult end,
                set = function(_, v) G().epHeroicMult = v; notifyConfig("epHeroicMult") end,
            },
            epMythicMult = {
                type = "range", order = 11, name = "Mythic ×",
                desc = "Multiplier applied to Normal awards on Mythic difficulty.",
                min = 1.0, max = 10.0, step = 0.1, isPercent = false,
                get = function() return G().epMythicMult or addon.VARS.epMythicMult end,
                set = function(_, v) G().epMythicMult = v; notifyConfig("epMythicMult") end,
            },
            epAscendedMult = {
                type = "range", order = 12, name = "Ascended ×",
                desc = "Multiplier applied to Normal awards on Ascended difficulty.",
                min = 1.0, max = 10.0, step = 0.1, isPercent = false,
                get = function() return G().epAscendedMult or addon.VARS.epAscendedMult end,
                set = function(_, v) G().epAscendedMult = v; notifyConfig("epAscendedMult") end,
            },
            multResetSpacer = {
                type = "description", order = 99, name = "",
            },
            multReset = {
                type = "execute", order = 100, name = "Reset to Defaults",
                desc = "Reset all 3 difficulty multipliers to the bundled defaults (1.5 / 2.0 / 3.0).",
                func = resetDifficultyMults,
            },
        },
    }

    for ri, raid in ipairs(addon.RAIDS or {}) do
        local raidKey = raid.key
        local presetSliders = {
            desc = {
                type = "description", order = 0, fontSize = "small",
                name = "Normal-difficulty EP awarded for each preset. Heroic / Mythic / "
                    .. "Ascended runs scale these via the multipliers tab.",
            },
            spacer = { type = "description", order = 1, name = "\n" },
        }
        for pi, preset in ipairs(addon.EP_PRESETS or {}) do
            local presetKey = preset.key
            presetSliders[presetKey] = {
                type = "range", order = 10 + pi,
                name = preset.name, desc = preset.desc,
                min = 0, max = 200, step = 1,
                get = function()
                    local v = addon.Awards
                        and addon.Awards.GetMatrixAmount
                        and addon.Awards:GetMatrixAmount(raidKey, presetKey)
                    if v ~= nil then return v end
                    return (addon.PRESET_DEFAULTS and addon.PRESET_DEFAULTS[presetKey]) or 10
                end,
                set = function(_, v)
                    if addon.Awards and addon.Awards.SetMatrixAmount then
                        addon.Awards:SetMatrixAmount(raidKey, presetKey, v)
                        notifyEPAward(raidKey, presetKey)
                    end
                end,
            }
        end
        presetSliders.previewSpacer = {
            type = "description", order = 50, name = "\n",
        }
        presetSliders.preview = {
            type = "group", inline = true, order = 51,
            name = "Higher Difficulty Preview",
            args = buildDifficultyPreviewArgs(raidKey),
        }
        presetSliders.resetSpacer = {
            type = "description", order = 99, name = "",
        }
        presetSliders.reset = {
            type = "execute", order = 100, name = "Reset to Defaults",
            desc = "Clear this raid's customized preset values; presets fall back to the hardcoded defaults of 10 each.",
            func = function() resetRaidAwards(raidKey) end,
        }
        raidArgs[raidKey] = {
            type = "group", order = ri, name = raid.name,
            args = presetSliders,
        }
    end

    return {
        type = "group", name = "Effort Points",
        childGroups = "tree",  -- multipliers + raids as a side tree
        args = raidArgs,
    }
end

-- ---------------------------------------------------------------------------
-- Gear Points — its own sidebar page. Houses the GP formula tunables
-- (base GP, standard ilvl, off-spec %, and the per-slot multipliers).
-- Officer-only by hidden gate; sits next to Effort Points so EP/GP
-- calibration lives side-by-side instead of buried in Officer & RL.
-- ---------------------------------------------------------------------------
local function gearPointsGroup()
    return {
        type = "group", name = "Gear Points",
        args = {
            memberNotice = {
                type = "description", order = 1, fontSize = "medium",
                hidden = function() return isOfficer() end,
                name = "|cFFAAAAAAOfficers and the Guild Master configure these values; they sync to your client automatically.|r",
            },
            officerOnly = {
                type = "group", order = 10, name = "", inline = true,
                hidden = function() return not isOfficer() end,
                args = {
                    header_gp = {
                        type = "header", order = 1, name = "GP Formula",
                    },
                    basegp = {
                        type = "range", order = 2, name = "Base GP",
                        desc = "GP that an item at Base ilvl costs (before slot multiplier). The Price ramp below pulls higher-ilvl items above this value.",
                        min = 1, max = 999, step = 1,
                        get = function() return G().basegp or addon.VARS.basegp end,
                        set = function(_, v) G().basegp = v; notifyConfig("basegp") end,
                    },
                    gpFormulaStandardIlvl = {
                        type = "range", order = 3, name = "Base ilvl",
                        desc = "Reference ilvl that costs exactly Base GP. Items above pay more, items below pay less, and the steepness of that curve is set by Price ramp. Recommended for Ascension: 65 (vanilla raid tier on a level-60 server).",
                        min = 1, max = 100, step = 1,
                        get = function() return G().gpFormulaStandardIlvl or addon.VARS.gpFormulaStandardIlvl end,
                        set = function(_, v) G().gpFormulaStandardIlvl = v; notifyConfig("gpFormulaStandardIlvl") end,
                    },
                    gpFormulaDoublingIlvl = {
                        -- Exposed to the user as "Price ramp" (1..10); stored
                        -- internally as the existing gpFormulaDoublingIlvl
                        -- field (= 26 / ramp) so Prices:Compute and the
                        -- Guild Info sync don't need changes.
                        type = "range", order = 4, name = "Price ramp",
                        desc = "How steeply the price climbs above Base ilvl. 1 = the default curve (items at Base ilvl +26 cost 2× Base GP). 2 = roughly twice as steep. 10 = max steepness, very expensive Heroics. If your EP awards differ a lot between Normal and Heroic, raise this so the GP costs scale alongside.",
                        min = 1, max = 10, step = 0.1, isPercent = false,
                        get = function()
                            local d = G().gpFormulaDoublingIlvl or addon.VARS.gpFormulaDoublingIlvl or 26
                            if d <= 0 then return 1 end
                            local ramp = 26 / d
                            if ramp < 1  then ramp = 1  end
                            if ramp > 10 then ramp = 10 end
                            return ramp
                        end,
                        set = function(_, ramp)
                            if not ramp or ramp < 1 then ramp = 1  end
                            if ramp > 10            then ramp = 10 end
                            G().gpFormulaDoublingIlvl = 26 / ramp
                            notifyConfig("gpFormulaDoublingIlvl")
                        end,
                    },
                    osMultiplier = {
                        type = "range", order = 5, name = "Off-spec %",
                        desc = "Off-spec items cost this percent of main-spec GP.",
                        min = 0, max = 100, step = 1,
                        get = osPct, set = function(_, v) setOsPct(v) end,
                    },
                    gpFormulaResetSpacer = {
                        type = "description", order = 6, name = "",
                    },
                    gpFormulaReset = {
                        type = "execute", order = 7, name = "Reset to Defaults",
                        desc = "Reset Base GP, Base ilvl, Price ramp, and Off-spec % to the bundled defaults.",
                        func = resetGPFormula,
                    },
                    header_slots = {
                        type = "header", order = 8, name = "Slot Multipliers",
                    },
                    slotMultipliersDesc = {
                        type = "description", order = 9, fontSize = "small",
                        name = "Multiplier per equipment slot, applied on top of the GP formula above. Set 0 to make a slot effectively free; values above 1.0 scale GP up. Each section has its own reset.",
                    },
                    slotMultipliersArmor = {
                        type = "group", inline = true, order = 10,
                        name = "Armor",
                        args = makeSlotMultiplierArgs("armor"),
                    },
                    slotMultipliersAccessories = {
                        type = "group", inline = true, order = 11,
                        name = "Accessories",
                        args = makeSlotMultiplierArgs("accessory"),
                    },
                    slotMultipliersWeapons = {
                        type = "group", inline = true, order = 12,
                        name = "Weapons",
                        args = makeSlotMultiplierArgs("weapon"),
                    },
                },
            },
        },
    }
end

-- ---------------------------------------------------------------------------
-- Root sidebar entry — landing page. The page name "Elitism EPGP" is shown
-- by Bliz/AceConfig as the page header automatically. Below it: version +
-- author, a separator, then two action buttons.
-- ---------------------------------------------------------------------------
local function rootGroup()
    return {
        type = "group",
        name = DISPLAY_NAME,
        args = {
            version = {
                type = "description", order = 1, fontSize = "small",
                name = "Version " .. (addon.VERSION or "?"),
            },
            author = {
                type = "description", order = 2, fontSize = "small",
                name = "Author: Emilol",
            },
            -- AceConfig "input" rendered read-only as a copy-paste-friendly
            -- field. dialogControl="" + a no-op set keeps the widget inert
            -- while still letting the user select + Ctrl+C the URL.
            repo = {
                type = "input", order = 3, width = "full",
                name = "GitHub",
                get  = function() return "https://github.com/Emilolenstein/ElitismEPGP" end,
                set  = function() end,
            },

            sep1 = { type = "header", order = 10, name = "" },

            btnHelp = {
                type = "execute", order = 20, name = "List Help Commands",
                desc = "Print the command reference to chat (same as typing /ee help).",
                width = "double",
                func = function()
                    if addon.Core and addon.Core.ShowHelp then
                        addon.Core:ShowHelp()
                    end
                end,
            },
            btnMainWindow = {
                type = "execute", order = 21, name = "Open Main Window",
                desc = "Open (or close) the Elitism EPGP main window.",
                width = "double",
                func = function()
                    if addon.UI and addon.UI.MainFrame and addon.UI.MainFrame.Toggle then
                        addon.UI.MainFrame:Toggle()
                    end
                end,
            },
            btnReload = {
                type = "execute", order = 22, name = "Reload UI",
                desc = "Reload the interface (same as /reload). Useful after a rank change to refresh which settings tabs are visible.",
                width = "double",
                func = function() ReloadUI() end,
                confirm = function() return "Reload the UI now?" end,
            },
        },
    }
end

function Options:Init()
    if self.registered then return end
    if not (G() and P()) then return end

    -- Always-visible pages — registered unconditionally on first init.
    AceConfig:RegisterOptionsTable(APP_KEY,         rootGroup)
    AceConfig:RegisterOptionsTable(APP_KEY_DISPLAY, displayGroup)

    -- Sidebar order is the registration order in 3.3.5a (Blizzard's
    -- InterfaceCategoryList doesn't re-sort). Display first since it's
    -- the page everyone uses.
    self.blizFrame    = AceConfigDialog:AddToBlizOptions(APP_KEY,         DISPLAY_NAME)
    self.displayFrame = AceConfigDialog:AddToBlizOptions(APP_KEY_DISPLAY, "Display", DISPLAY_NAME)

    -- Officer pages register lazily — at PLAYER_LOGIN, guild data isn't
    -- always loaded, so isOfficer() returns false and we'd silently skip
    -- the officer-only tabs. EnsureOfficerPages() is also called from
    -- Core:OnGuildRosterUpdate so the pages appear once the player's
    -- permissions arrive without needing a /reload.
    self:EnsureOfficerPages()
    self.registered = true
end

-- Idempotent: registers the three officer-only pages the first time the
-- player's "Edit Officer Note" permission flips on. Safe to call repeatedly
-- — bails as soon as the pages exist or when permission isn't granted.
function Options:EnsureOfficerPages()
    if self.officerPagesRegistered then return end
    if not isOfficer() then return end
    if not (G() and P()) then return end

    AceConfig:RegisterOptionsTable(APP_KEY_GUILD,       guildManagementGroup)
    AceConfig:RegisterOptionsTable(APP_KEY_EP_AWARDS,   epAwardsGroup)
    AceConfig:RegisterOptionsTable(APP_KEY_GEAR_POINTS, gearPointsGroup)
    AceConfig:RegisterOptionsTable(APP_KEY_BACKUP,      backupGroup)

    self.guildFrame      = AceConfigDialog:AddToBlizOptions(APP_KEY_GUILD,       "Officer & RL",  DISPLAY_NAME)
    self.epAwardsFrame   = AceConfigDialog:AddToBlizOptions(APP_KEY_EP_AWARDS,   "Effort Points", DISPLAY_NAME)
    self.gearPointsFrame = AceConfigDialog:AddToBlizOptions(APP_KEY_GEAR_POINTS, "Gear Points",   DISPLAY_NAME)
    self.backupFrame     = AceConfigDialog:AddToBlizOptions(APP_KEY_BACKUP,      "Backups",       DISPLAY_NAME)

    self.officerPagesRegistered = true
end

function Options:Open()
    if not self.registered then self:Init() end
    if not self.blizFrame then return end
    -- 3.3.5a: opening twice is the documented workaround when the panel hasn't been shown yet.
    InterfaceOptionsFrame_OpenToCategory(self.blizFrame)
    InterfaceOptionsFrame_OpenToCategory(self.blizFrame)
end

addon.Options = Options
