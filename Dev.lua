local _, addon = ...

local Dev = {}
addon.Dev = Dev

local function RefreshUI()
    if addon.UI and addon.UI.MainFrame and addon.UI.MainFrame.RefreshDevState then
        addon.UI.MainFrame:RefreshDevState()
    end
end

function Dev:IsActive()
    return addon.DB and addon.DB.profile.dev == true
end

function Dev:SetActive(on)
    if not addon.DB then return end
    addon.DB.profile.dev = on and true or false
    if not addon.DB.profile.dev then
        addon.DB.profile.mockRaid    = {}
        addon.DB.profile.mockEntries = {}
    end
    RefreshUI()
end

function Dev:GetMockRaid()
    if not addon.DB then return {} end
    return addon.DB.profile.mockRaid or {}
end

local CLASS_LIST = {
    { "Warrior",      "WARRIOR"     },
    { "Paladin",      "PALADIN"     },
    { "Hunter",       "HUNTER"      },
    { "Rogue",        "ROGUE"       },
    { "Priest",       "PRIEST"      },
    { "Shaman",       "SHAMAN"      },
    { "Mage",         "MAGE"        },
    { "Warlock",      "WARLOCK"     },
    { "Druid",        "DRUID"       },
    { "Death Knight", "DEATHKNIGHT" },
}

local function PickClassFor(name)
    local seed = string.byte(name or "X", 1) or 65
    local idx = (seed % #CLASS_LIST) + 1
    return CLASS_LIST[idx]
end

function Dev:SetMockRaid(names)
    if not self:IsActive() then return false, "dev mode not active" end
    if not addon.DB then return false, "DB not initialized" end
    local list = {}
    for _, n in ipairs(names or {}) do
        if n and n ~= "" then list[#list + 1] = n end
    end
    addon.DB.profile.mockRaid = list

    addon.DB.profile.mockEntries = addon.DB.profile.mockEntries or {}
    local entries = addon.DB.profile.mockEntries
    local keep = {}
    for _, n in ipairs(list) do keep[n] = true end
    for n in pairs(entries) do
        if not keep[n] then entries[n] = nil end
    end
    for _, n in ipairs(list) do
        if not entries[n] then
            local cls = PickClassFor(n)
            entries[n] = {
                name        = n,
                ep          = 0,
                gp          = 0,
                officerNote = "0:0",
                kind        = "self",
                class       = cls[1],
                classFile   = cls[2],
                level       = 80,
                online      = true,
                rankIndex   = 99,
                index       = -1,
                isMock      = true,
            }
        end
    end
    RefreshUI()
    return true
end

function Dev:ClearMockRaid()
    if not addon.DB then return end
    addon.DB.profile.mockRaid    = {}
    addon.DB.profile.mockEntries = {}
    RefreshUI()
end

function Dev:FireBoss(bossName)
    if not self:IsActive() then return false, "dev mode not active" end
    addon.Print(string.format("|cFFFF6060[DEV]|r Simulated BOSS_KILL: \"%s\"", bossName))
    if addon.Encounter and addon.Encounter.OnBossKill then
        addon.Encounter:OnBossKill(bossName, true)
    else
        addon.Print("|cFFFFCC00  (Encounter module not loaded)|r")
    end
    return true
end
