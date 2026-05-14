local _, addon = ...

local RaidSession = {}
addon.RaidSession = RaidSession

local function P() return addon.DB and addon.DB.profile end

------------------------------------------------------------
-- State queries
------------------------------------------------------------

function RaidSession:IsActive()
    local p = P()
    return p and p.raidActive == true or false
end

function RaidSession:Controller()
    local p = P()
    return p and p.activeController or nil
end

function RaidSession:IsControlledByMe()
    return self:Controller() == UnitName("player")
end

function RaidSession:StartedAt()
    local p = P()
    return p and p.raidSessionStartedAt or 0
end

function RaidSession:ElapsedMinutes()
    if not self:IsActive() then return 0 end
    local started = self:StartedAt()
    if not started or started == 0 then return 0 end
    return math.floor((time() - started) / 60)
end

function RaidSession:ElapsedSeconds()
    if not self:IsActive() then return 0 end
    local started = self:StartedAt()
    if not started or started == 0 then return 0 end
    return time() - started
end

-- Raid context (selected raid + difficulty for the current session). The
-- Raid Manager UI gates Start Raid on these being set. Once started, EP
-- awards key off the selected (raid, difficulty) cell of epAwards.
function RaidSession:GetContext()
    local p = P()
    if not p then return nil, nil end
    return p.currentRaid, p.currentDifficulty
end

function RaidSession:SetContext(raid, difficulty)
    local p = P()
    if not p then return end
    p.currentRaid       = raid       or nil
    p.currentDifficulty = difficulty or nil
    if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.RefreshContextLabels then
        addon.UI.RaidManager:RefreshContextLabels()
    end
    if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.RefreshActiveState then
        addon.UI.RaidManager:RefreshActiveState()
    end
end

function RaidSession:HasContext()
    local raid, dif = self:GetContext()
    return raid ~= nil and dif ~= nil
end

function RaidSession:ElapsedString()
    local total = self:ElapsedSeconds()
    local h = math.floor(total / 3600)
    local m = math.floor((total % 3600) / 60)
    local s = total % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%d:%02d", m, s)
end

------------------------------------------------------------
-- Start / End
------------------------------------------------------------

local function notifyUI()
    if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.RefreshActiveState then
        addon.UI.RaidManager:RefreshActiveState()
    end
end

local function bypassChecks()
    return addon.Dev and addon.Dev:IsActive()
end

-- awardEP defaults to true so existing callers (slash command, dev path)
-- keep their old behaviour. The Raid Manager passes false explicitly in
-- "manual" awards mode so the session flips active without auto-paying
-- the On-Time EP — the RL hands that out via the Award preset buttons.
function RaidSession:Start(awardEP)
    if awardEP == nil then awardEP = true end
    if not addon.IsOfficer() then
        addon.Print("|cFFFF6060Cannot start raid: you are not an officer.|r")
        return false, "not an officer"
    end
    if not bypassChecks() and not addon.IsRaidLeaderHere() then
        addon.Print("|cFFFF6060Cannot start raid: only the Raid Leader can start a session.|r")
        return false, "not raid leader"
    end
    if not self:HasContext() then
        addon.Print("|cFFFF6060Cannot start raid: pick a raid and difficulty first.|r")
        return false, "no context"
    end
    if self:IsActive() then
        local c = self:Controller()
        addon.Print(string.format("|cFFFFCC00Raid session already active (controller: %s).|r",
            (c and addon.ColorName(c)) or "?"))
        return false, "already active"
    end

    P().raidActive            = true
    P().activeController      = UnitName("player")
    P().raidSessionStartedAt  = time()

    local raid, dif = self:GetContext()

    if awardEP then
        -- On-Time EP for the current raid+standby
        local recipients = addon.Awards:RaidPlusStandby()
        local ok = 0
        if #recipients > 0 then
            local amount = addon.Awards:GetAmountForPreset("ON_TIME", raid, dif)
            local kind   = addon.Awards.Kind.EP_ON_TIME
            ok = addon.Awards:GiveEPBulk(recipients, amount, kind,
                string.format("Start of raid (%s / %s)", raid, dif))
            addon.Print(string.format("Raid started [%s / %s] — On-time +%d EP awarded to %d player%s.",
                raid, dif, amount, ok, ok == 1 and "" or "s"))
            addon.Awards:AnnounceAwarded(
                string.format("Raid started [%s / %s] — On-time", raid, dif),
                amount, "EP", recipients)
        else
            addon.Print(string.format("Raid started [%s / %s]. No recipients yet (raid + standby empty).",
                raid, dif))
            addon.Awards:Announce(string.format("Raid started [%s / %s].", raid, dif))
        end
    else
        addon.Print(string.format("Raid started [%s / %s] (Manual mode — use the Award buttons to hand out EP).",
            raid, dif))
        addon.Awards:Announce(string.format("Raid started [%s / %s].", raid, dif))
    end

    notifyUI()
    return true
end

function RaidSession:End(awardEP)
    if not self:IsActive() then
        addon.Print("|cFFFFCC00No active raid session.|r")
        return false, "not active"
    end
    if not self:IsControlledByMe() and not bypassChecks() then
        local c = self:Controller()
        addon.Print(string.format("|cFFFF6060Only the controller (%s) can end this session.|r",
            (c and addon.ColorName(c)) or "?"))
        return false, "not controller"
    end

    local raid, dif = self:GetContext()

    if awardEP then
        local recipients = addon.Awards:RaidPlusStandby()
        if #recipients > 0 then
            local amount = addon.Awards:GetAmountForPreset("END_OF_RAID", raid, dif)
            local kind   = addon.Awards.Kind.EP_END_RAID
            local ok     = addon.Awards:GiveEPBulk(recipients, amount, kind,
                string.format("End of raid (%s / %s)", raid or "?", dif or "?"))
            addon.Print(string.format("Raid ended — End-of-Raid +%d EP awarded to %d player%s.",
                amount, ok, ok == 1 and "" or "s"))
            addon.Awards:AnnounceAwarded(
                string.format("Raid ended [%s / %s] — End-of-Raid",
                    raid or "?", dif or "?"),
                amount, "EP", recipients)
        else
            addon.Print("Raid ended. No recipients to award.")
            addon.Awards:Announce(string.format("Raid ended [%s / %s].",
                raid or "?", dif or "?"))
        end
    else
        addon.Print("Raid session ended (no End-of-Raid EP awarded).")
        addon.Awards:Announce(string.format("Raid ended [%s / %s].",
            raid or "?", dif or "?"))
    end

    P().raidActive           = false
    P().activeController     = nil
    P().raidSessionStartedAt = nil

    notifyUI()
    return true
end

------------------------------------------------------------
-- Auto-end on raid disband — does NOT award End-of-Raid EP.
-- Per user spec: only manual End Raid pays out.
------------------------------------------------------------

local lastInRaid = false

function RaidSession:OnRosterUpdate()
    local inRaid = addon.InRaid()
    if lastInRaid and not inRaid and self:IsActive() and self:IsControlledByMe() then
        addon.Print("|cFFFFCC00Raid disbanded — session auto-ended (no End-of-Raid EP awarded).|r")
        P().raidActive           = false
        P().activeController     = nil
        P().raidSessionStartedAt = nil
    end
    lastInRaid = inRaid
    -- Always refresh the Raid Manager so its Start-Raid gating reacts
    -- live to the player joining/leaving a raid or having leadership
    -- handed to/from them, instead of needing a panel reopen.
    notifyUI()
end

------------------------------------------------------------
-- Crash recovery: if SavedVariables show an active session for us
-- and we're still RL in a raid, resume silently. If state is stale
-- (no longer RL or no longer in raid), prompt to clear or resume.
------------------------------------------------------------

function RaidSession:CheckRecovery()
    local p = P()
    if not p or not p.raidActive then return end
    if p.activeController ~= UnitName("player") then return end
    -- Dev mode often runs a forced "raidActive" session while solo (e.g.
    -- the bidding-UI dev hack in Core:OnEnable) — don't nag about it.
    if addon.Dev and addon.Dev:IsActive() then return end

    local inRaid   = addon.InRaid()
    local isLeader = addon.IsRaidLeaderHere()

    if inRaid and isLeader then
        addon.Print(string.format("|cFFFFCC00Resumed raid session (started %d min ago).|r",
            self:ElapsedMinutes()))
        notifyUI()
        return
    end

    -- Stale flag — ask the user. Don't auto-clear; could be mid-relog.
    local why
    if not inRaid       then why = "you are no longer in a raid"
    elseif not isLeader then why = "you are no longer the Raid Leader"
    else                    why = "state mismatch"
    end
    addon.Dialog:Confirm({
        title  = "Stale Raid Session",
        text   = string.format(
            "Elitism EPGP detected an active raid session, but %s.\n\n" ..
            "This usually means you crashed mid-raid. Clear the stale session?\n\n" ..
            "(Started %d min ago.)",
            why, self:ElapsedMinutes()),
        accept = "Clear", cancel = "Keep",
        OnAccept = function()
            local pp = P()
            if pp then
                pp.raidActive           = false
                pp.activeController     = nil
                pp.raidSessionStartedAt = nil
            end
            addon.Print("Stale raid session cleared.")
            notifyUI()
        end,
    })
end

------------------------------------------------------------
-- Event wiring (called from Core:OnEnable)
------------------------------------------------------------

function RaidSession:RegisterEvents()
    if self.eventFrame then return end
    local f = CreateFrame("Frame")
    f:RegisterEvent("RAID_ROSTER_UPDATE")
    f:RegisterEvent("PARTY_MEMBERS_CHANGED")
    f:RegisterEvent("PARTY_LEADER_CHANGED")
    f:RegisterEvent("PLAYER_ENTERING_WORLD")
    f:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            -- Picker selection is transient — it should only persist once
            -- a raid is actually started. If we're not in an active
            -- session, drop any leftover raid/difficulty pick from before
            -- the /reload so the panel reopens with empty placeholders.
            if not RaidSession:IsActive() then
                local p = P()
                if p then
                    p.currentRaid       = nil
                    p.currentDifficulty = nil
                end
            end
            -- Defer recovery check so guild data has time to load.
            local recovery = CreateFrame("Frame")
            local elapsed = 0
            recovery:SetScript("OnUpdate", function(self, dt)
                elapsed = elapsed + dt
                if elapsed >= 2 then
                    recovery:SetScript("OnUpdate", nil)
                    RaidSession:CheckRecovery()
                end
            end)
        else
            RaidSession:OnRosterUpdate()
        end
    end)
    self.eventFrame = f
end
