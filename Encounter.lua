local _, addon = ...

local Encounter = {}
addon.Encounter = Encounter

local THROTTLE_SECONDS  = 30
local nameLastPopupAt   = {}

local function HasFlag(flags, mask)
    if not flags or not mask then return false end
    return bit.band(flags, mask) ~= 0
end

function Encounter:OnBossKill(bossName, force)
    if not bossName or bossName == "" then return end
    if not addon.IsOfficer() then return end

    -- Three gates: dev-bypass, force-bypass, or normal gate.
    -- Normal gate requires: active session controlled by me AND I'm currently RL.
    -- The IsRaidLeaderHere check handles mid-raid leadership transfer — if I lose
    -- RL but the session is still flagged active locally, my addon stops firing.
    local devBypass   = addon.Dev and addon.Dev:IsActive()
    local activeHere  = addon.RaidSession and addon.RaidSession:IsActive()
                        and addon.RaidSession:IsControlledByMe()
                        and addon.IsRaidLeaderHere()
    if not (devBypass or force or activeHere) then return end

    -- Among multiple officers, only the controller (or whoever forced)
    -- ever reaches this point — no duplicate awards across the raid.

    if not force then
        local now = time()
        local last = nameLastPopupAt[bossName]
        if last and (now - last) < THROTTLE_SECONDS then return end
        nameLastPopupAt[bossName] = now
    end

    if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.HandleBossKill then
        addon.UI.RaidManager:HandleBossKill(bossName, force)
    end
end

function Encounter:OnEvent(event, ...)
    if event ~= "COMBAT_LOG_EVENT_UNFILTERED" then return end
    local _, subevent, _, _, _, _, destName, destFlags = ...
    if subevent ~= "UNIT_DIED" then return end
    if not destName then return end
    if IsInInstance() ~= "raid" then return end
    if not GetNumRaidMembers or GetNumRaidMembers() == 0 then return end
    local TYPE_NPC          = COMBATLOG_OBJECT_TYPE_NPC          or 0x00000800
    local REACTION_HOSTILE  = COMBATLOG_OBJECT_REACTION_HOSTILE  or 0x00000040
    if not HasFlag(destFlags, TYPE_NPC) then return end
    if not HasFlag(destFlags, REACTION_HOSTILE) then return end
    self:OnBossKill(destName, false)
end

local function ExtractBossName(mod)
    if not mod then return "Unknown boss" end
    if mod.combatInfo and mod.combatInfo.name then return mod.combatInfo.name end
    if mod.localization and mod.localization.general and mod.localization.general.name then
        return mod.localization.general.name
    end
    return tostring(mod.id or "Unknown boss")
end

function Encounter:Init()
    if self.detection then return end

    if DBM and type(DBM.RegisterCallback) == "function" then
        DBM:RegisterCallback("kill", function(_, mod)
            Encounter:OnBossKill(ExtractBossName(mod), false)
        end)
        self.detection = "DBM"
        return
    end

    local f = CreateFrame("Frame")
    f:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    f:SetScript("OnEvent", function(_, event, ...) Encounter:OnEvent(event, ...) end)
    self.frame = f
    self.detection = "combat-log"
end

function Encounter:GetDetectionMode()
    return self.detection or "uninitialized"
end
