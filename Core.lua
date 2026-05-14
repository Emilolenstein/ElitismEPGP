local addonName, addon = ...

local Core = LibStub("AceAddon-3.0"):NewAddon(
    addonName, "AceEvent-3.0", "AceConsole-3.0"
)
addon.Core = Core

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cFF66CCFF[" .. addon.ADDON_DISPLAY .. "]|r " .. tostring(msg))
end
addon.Print = Print

function Core:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("ElitismEPGPDB", addon.DB_DEFAULTS, true)
    addon.DB = self.db

    -- Session-log window's "this session" marker. Persisted in the DB so a
    -- /reload keeps the session view intact (the underlying history is kept
    -- regardless); only the Session Log's "New Session" button rolls it.
    if not self.db.global.sessionStart then
        self.db.global.sessionStart = time()
    end

    -- v0.1.1 migration: bossKillMode -> awardsMode. The old field had a
    -- different scope (only gated boss-kill detection); the new field
    -- also covers raid start/end. We map conservatively:
    --   auto    -> auto     (full automation kept)
    --   quick   -> suggest  (the same "show me before doing it" UX)
    --   manual  -> suggest  (old "manual" meant no auto boss-kill, but
    --                        raid start/end still auto-awarded. Mapping
    --                        to suggest preserves the auto-EP grant via
    --                        the confirmation dialog rather than dropping
    --                        it entirely. Users who want zero automation
    --                        can switch to the new "manual" themselves.)
    local profile = self.db.profile
    if profile then
        if profile.awardsMode == nil and profile.bossKillMode ~= nil then
            local old = profile.bossKillMode
            if old == "auto" then
                profile.awardsMode = "auto"
            else
                profile.awardsMode = "suggest"
            end
        end
        if profile.awardsMode == nil then profile.awardsMode = "suggest" end
    end

    self:RegisterChatCommand("ee", "OnSlash")
    self:RegisterChatCommand("elitism", "OnSlash")

    if addon.UI and addon.UI.MainFrame then
        addon.UI.MainFrame:Init()
    end
    if addon.UI and addon.UI.BidFrame and addon.UI.BidFrame.Init then
        addon.UI.BidFrame:Init()
    end
    if addon.UI and addon.UI.RaiderBid and addon.UI.RaiderBid.Init then
        addon.UI.RaiderBid:Init()
    end
    if addon.UI and addon.UI.LootQueue and addon.UI.LootQueue.Init then
        addon.UI.LootQueue:Init()
    end
    if addon.Minimap then
        addon.Minimap:Init()
    end
    if addon.Options then
        addon.Options:Init()
    end
    if addon.Tooltip and addon.Tooltip.Init then
        addon.Tooltip:Init()
    end
end

function Core:OnEnable()
    self:RegisterEvent("GUILD_ROSTER_UPDATE", "OnGuildRosterUpdate")
    self:RegisterEvent("PLAYER_GUILD_UPDATE", "OnGuildRosterUpdate")
    addon.Roster:Request()
    if addon.Encounter and addon.Encounter.Init then
        addon.Encounter:Init()
    end
    if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.RegisterEvents then
        addon.UI.RaidManager:RegisterEvents()
    end
    if addon.RaidSession and addon.RaidSession.RegisterEvents then
        addon.RaidSession:RegisterEvents()
    end
    if addon.Loot and addon.Loot.InstallClickHook then
        addon.Loot:InstallClickHook()
    end
    if addon.Loot and addon.Loot.RegisterCommHandler then
        addon.Loot:RegisterCommHandler()
    end
    if addon.UI and addon.UI.AtlasLootHook and addon.UI.AtlasLootHook.Init then
        addon.UI.AtlasLootHook:Init()
    end
    if addon.Sync and addon.Sync.Init then
        if addon.Sync.RegisterBuiltinDomains then
            addon.Sync:RegisterBuiltinDomains()
        end
        if addon.Prices and addon.Prices.RegisterSyncDomain then
            addon.Prices:RegisterSyncDomain()
        end
        if addon.Awards and addon.Awards.RegisterSyncDomain then
            addon.Awards:RegisterSyncDomain()
        end
        addon.Sync:Init()
    end
end

function Core:OnGuildRosterUpdate()
    addon.Roster:Rebuild()
    -- Rebuild has consumed offline data; restore the user's Blizzard
    -- show-offline preference so the default guild panel ("O" key)
    -- isn't stuck displaying offline members against their wishes.
    if addon.Roster.RestoreShowOffline then
        addon.Roster:RestoreShowOffline()
    end
    if addon.GuildSync then addon.GuildSync:Read() end
    -- First guild update after PLAYER_LOGIN is when CanEditOfficerNote()
    -- finally returns truth; register the officer-only options pages now
    -- if we haven't yet (idempotent — bails out after the first run).
    if addon.Options and addon.Options.EnsureOfficerPages then
        addon.Options:EnsureOfficerPages()
    end
    if ElitismEPGPMainFrame and ElitismEPGPMainFrame:IsShown() then
        addon.UI.MainFrame:Refresh()
    end
end

-- Each entry is { officer = bool, text = "..." }. Player-facing entries
-- (officer = false) are visible to everyone; officer entries are hidden
-- from non-officers so they aren't notified about commands they can't run.
local HELP = {
    { officer = false, text = "|cFFFFFF00/ee|r                              toggle main window" },
    { officer = false, text = "|cFFFFFF00/ee standings|r                    print EP/GP/PR to chat" },
    { officer = true,  text = "|cFFFFFF00/ee ep <+/-N> <player> [reason]|r  award EP" },
    { officer = true,  text = "|cFFFFFF00/ee gp <+/-N> <player> [reason]|r  award GP" },
    { officer = false, text = "|cFFFFFF00/ee history [N]|r                  open History tab; with N, prints last N entries to chat" },
    { officer = true,  text = "|cFFFFFF00/ee decay [pct]|r                  open weekly maintenance dialog (default 20%)" },
    { officer = true,  text = "|cFFFFFF00/ee alt <alt> <main>|r             mark alt as belonging to main (writes =main to officer note)" },
    { officer = true,  text = "|cFFFFFF00/ee unalt <alt>|r                  unmark alt (resets to 0:0)" },
    { officer = false, text = "|cFFFFFF00/ee minimap|r                      toggle minimap button visibility" },
    { officer = true,  text = "|cFFFFFF00/ee dev on|off|status|r            enable/disable dev mode (gates dev subcommands)" },
    { officer = true,  text = "|cFFFFFF00/ee dev mockraid set <names>|clear|r override the raid roster (dev mode)" },
    { officer = true,  text = "|cFFFFFF00/ee dev fireboss <name>|r          simulate a BOSS_KILL event (dev mode)" },
    { officer = true,  text = "|cFFFFFF00/ee raid|r                         toggle Raid Manager floating panel" },
    { officer = true,  text = "|cFFFFFF00/ee mode manual|suggest|auto|r     set award automation level" },
    { officer = true,  text = "|cFFFFFF00/ee reset epgp <player>|r           reset one player's EP/GP to 0:0" },
    { officer = true,  text = "|cFFFFFF00/ee reset all|r                     WIPE everything (history, EP/GP, prices, settings)" },
    { officer = false, text = "|cFFFFFF00/ee config|r                       open the options panel (Interface > Addons)" },
    { officer = true,  text = "|cFFFFFF00/ee bid <itemLink>|r               open a bid session for an item" },
    { officer = true,  text = "|cFFFFFF00/ee bid show|r                     re-open the active bid panel after ESC" },
    { officer = true,  text = "|cFFFFFF00/ee bid cancel|r                   cancel the active bid session" },
    { officer = true,  text = "|cFFFFFF00/ee start|r                        start raid session (+On-Time EP, arms boss-kill)" },
    { officer = true,  text = "|cFFFFFF00/ee end|r                          end raid session (+End-of-Raid EP)" },
    { officer = false, text = "|cFFFFFF00/ee diag|r                         dump config + perms + raid state for triage" },
    { officer = false, text = "|cFFFFFF00/ee help|r                         this list" },
}

-- Commands restricted to officers (Edit Officer Note rank). When a
-- non-officer types one of these, we fall through to the "Unknown command"
-- branch so they aren't notified the command exists.
local OFFICER_ONLY_COMMANDS = {
    ep = true, gp = true,
    decay = true,
    alt = true, unalt = true,
    reset = true,
    raid = true, mode = true,
    bid = true,
    start = true, ["end"] = true,
}

-- /ee dev subcommands that don't need officer rights. Everything else under
-- /ee dev (mockraid, fireboss, testlootq, on, ...) still requires officer.
-- "off" is intentionally open so a non-officer can recover if dev mode was
-- left enabled on their character.
local DEV_PUBLIC_SUBCOMMANDS = {
    [""]       = true,
    ["status"] = true,
    ["off"]    = true,
}

function Core:ShowHelp()
    local isOfficer = addon.IsOfficer()
    Print("Commands:")
    for _, line in ipairs(HELP) do
        if isOfficer or not line.officer then
            Print("  " .. line.text)
        end
    end
end

local function ParseAward(rest)
    local amt, target, reason = rest:match("^(%S+)%s+(%S+)%s*(.*)$")
    if not amt then return nil end
    local n = tonumber(amt)
    if not n then return nil end
    return n, target, (reason ~= "" and reason or nil)
end

local function FormatHistoryLine(e)
    local d = date("%m-%d %H:%M", e.ts or 0)
    local delta
    if (e.dEP or 0) ~= 0 then delta = string.format("%+dEP", e.dEP)
    elseif (e.dGP or 0) ~= 0 then delta = string.format("%+dGP", e.dGP)
    else delta = "decay" end
    return string.format("%s  %s  %s  %s  (%s)%s",
        d, e.actor or "?", e.target or "?", delta, e.kind or "?",
        e.note and ("  — " .. e.note) or "")
end

function Core:OnSlash(input)
    input = (input or ""):match("^%s*(.-)%s*$")
    local cmd, rest = input:match("^(%S+)%s*(.*)$")
    cmd = cmd and cmd:lower() or ""

    -- Officer-only gate: hide the existence of restricted commands from
    -- non-officers by routing them to the same response as a typo.
    if OFFICER_ONLY_COMMANDS[cmd] and not addon.IsOfficer() then
        Print("Unknown command: " .. cmd .. ". Try /ee help")
        return
    end

    if cmd == "" then
        addon.UI.MainFrame:Toggle()
    elseif cmd == "help" or cmd == "?" then
        self:ShowHelp()
    elseif cmd == "standings" then
        addon.Roster:Rebuild()
        local list = addon.Roster:Sorted("pr")
        Print(string.format("Standings (%d members):", #list))
        for i = 1, math.min(#list, 20) do
            local e = list[i]
            Print(string.format("  %2d. %s  EP=%d  GP=%d  PR=%.2f",
                i, e.name, e.ep, e.gp, e.pr))
        end
        if #list > 20 then Print(string.format("  ... and %d more", #list - 20)) end
    elseif cmd == "show" then
        addon.UI.MainFrame:Show()
    elseif cmd == "hide" then
        addon.UI.MainFrame:Hide()
    elseif cmd == "ep" or cmd == "gp" then
        local amount, target, reason = ParseAward(rest)
        if not amount or not target then
            Print("Usage: /ee " .. cmd .. " <+/-N> <player> [reason]")
            return
        end
        local fn = (cmd == "ep") and addon.Awards.GiveEP or addon.Awards.GiveGP
        local kind = (cmd == "ep") and addon.Awards.Kind.EP_CUSTOM or addon.Awards.Kind.GP_CUSTOM
        local ok, err = fn(addon.Awards, target, amount, kind, reason)
        if ok then
            local ep, gp = addon.Roster:GetEPGP(target)
            Print(string.format("%s %+d %s to %s (now %d:%d)%s",
                cmd:upper(), amount, cmd:upper(), target, ep, gp,
                reason and ("  — " .. reason) or ""))
        else
            Print("|cFFFF6060Failed:|r " .. tostring(err))
        end
    elseif cmd == "history" then
        -- Bare "/ee history" opens the main window on the History tab — the
        -- full UI is more useful than a chat dump. A numeric arg ("/ee history 50")
        -- preserves the legacy chat list for quick console glances.
        local n = tonumber(rest)
        if not n then
            if addon.UI and addon.UI.MainFrame then
                addon.UI.MainFrame:Show()
                addon.UI.MainFrame:SelectTab("history")
            end
            return
        end
        local h = addon.Awards:GetHistory()
        Print(string.format("History (%d entries, showing last %d):", #h, math.min(#h, n)))
        -- Print oldest → newest. Chat scrolls downward, so the newest
        -- entry ends up at the bottom — the line a user sees right
        -- above the chat input — without requiring them to scroll up.
        for i = math.max(1, #h - n + 1), #h do
            Print("  " .. FormatHistoryLine(h[i]))
        end
    elseif cmd == "decay" then
        local mult
        if rest and rest ~= "" then
            local pct = tonumber(rest)
            if not pct or pct <= 0 or pct >= 100 then
                Print("Decay percent must be in (0, 100). Got: " .. tostring(rest))
                return
            end
            mult = 1 - (pct / 100)
        end
        if not (addon.UI and addon.UI.StandingsTab and addon.UI.StandingsTab.OpenWeeklyMaintenanceDialog) then
            Print("|cFFFF6060Standings tab not initialized — open /ee once first.|r")
            return
        end
        addon.UI.StandingsTab:OpenWeeklyMaintenanceDialog(mult)
    elseif cmd == "alt" then
        local altName, mainName = rest:match("^(%S+)%s+(%S+)$")
        if not altName or not mainName then
            Print("Usage: /ee alt <altName> <mainName>")
            return
        end
        local ok, info = addon.Awards:MarkAlt(altName, mainName)
        if ok then
            local lostMsg = ""
            if info and (info.lostEP > 0 or info.lostGP > 0) then
                lostMsg = string.format(" (replaced %d EP / %d GP)", info.lostEP, info.lostGP)
            end
            Print(string.format("Marked %s as alt of %s%s", altName, mainName, lostMsg))
            if addon.UI and addon.UI.MainFrame then addon.UI.MainFrame:Refresh() end
        else
            Print("|cFFFF6060Failed:|r " .. tostring(info))
        end
    elseif cmd == "unalt" then
        local altName = rest:match("^(%S+)$")
        if not altName then
            Print("Usage: /ee unalt <altName>")
            return
        end
        local ok, err = addon.Awards:UnmarkAlt(altName)
        if ok then
            Print(string.format("Unmarked %s as alt; reset to 0:0", altName))
            if addon.UI and addon.UI.MainFrame then addon.UI.MainFrame:Refresh() end
        else
            Print("|cFFFF6060Failed:|r " .. tostring(err))
        end
    elseif cmd == "dev" then
        -- All dev-mode tools are subcommands of /ee dev so the surface area
        -- of officer-only commands stays small and the gate is one keyword.
        local sub, devRest = rest:match("^(%S*)%s*(.*)$")
        sub = sub or ""
        if not DEV_PUBLIC_SUBCOMMANDS[sub] and not addon.IsOfficer() then
            Print("Unknown command: dev " .. sub .. ". Try /ee help")
            return
        end
        if sub == "on" then
            addon.Dev:SetActive(true)
            Print("|cFFFF6060[DEV]|r mode |cFF55FF55ENABLED|r")
        elseif sub == "off" then
            addon.Dev:SetActive(false)
            Print("Dev mode disabled. Mock raid cleared.")
        elseif sub == "" or sub == "status" then
            Print(string.format("Dev mode: %s. Mock raid size: %d.",
                addon.Dev:IsActive() and "|cFF55FF55ON|r" or "|cFFAAAAAAOFF|r",
                #addon.Dev:GetMockRaid()))
        elseif sub == "mockraid" then
            if not addon.Dev:IsActive() then
                Print("|cFFFF6060Enable dev mode first:|r /ee dev on")
                return
            end
            local mrSub, mrArgs = (devRest or ""):match("^(%S*)%s*(.*)$")
            mrSub = mrSub or ""
            if mrSub == "set" then
                local names = {}
                for n in (mrArgs or ""):gmatch("(%S+)") do names[#names + 1] = n end
                if #names == 0 then
                    Print("Usage: /ee dev mockraid set <name1> <name2> ...")
                    return
                end
                addon.Dev:SetMockRaid(names)
                Print(string.format("Mock raid set (%d): %s", #names, table.concat(names, ", ")))
            elseif mrSub == "clear" then
                addon.Dev:ClearMockRaid()
                Print("Mock raid cleared.")
            elseif mrSub == "" or mrSub == "show" then
                local m = addon.Dev:GetMockRaid()
                if #m == 0 then
                    Print("Mock raid: (none)")
                else
                    Print(string.format("Mock raid (%d): %s", #m, table.concat(m, ", ")))
                end
            else
                Print("Usage: /ee dev mockraid set <names> | clear | show")
            end
        elseif sub == "fireboss" then
            if not addon.Dev:IsActive() then
                Print("|cFFFF6060Enable dev mode first:|r /ee dev on")
                return
            end
            local boss = devRest and devRest:match("^%s*(.-)%s*$")
            if not boss or boss == "" then
                Print("Usage: /ee dev fireboss <BossName>")
                return
            end
            addon.Dev:FireBoss(boss)
        elseif sub == "testlootq" then
            if not addon.Dev:IsActive() then
                Print("|cFFFF6060Enable dev mode first:|r /ee dev on")
                return
            end
            if not (addon.UI and addon.UI.LootQueue and addon.UI.LootQueue.DevShow) then
                Print("|cFFFF6060LootQueue not loaded.|r")
                return
            end
            local links = {}
            for link in (devRest or ""):gmatch("(|c%x+|Hitem:[^|]+|h[^|]+|h|r)") do
                links[#links + 1] = link
            end
            if #links == 0 then
                Print("Usage: /ee dev testlootq <itemLink> [link2] ...  (shift-click items into chat)")
                return
            end
            addon.UI.LootQueue:DevShow(links)
        else
            Print("Usage: /ee dev on|off|status | mockraid | fireboss <name> | testlootq <items>")
        end
    elseif cmd == "reset" then
        local sub, args = rest:match("^(%S*)%s*(.*)$")
        if sub == "epgp" then
            local target = (args or ""):match("^(%S+)")
            if not target then
                Print("Usage: /ee reset epgp <player>")
                return
            end
            local entry = addon.Roster:Get(target)
            if not entry then
                Print("|cFFFF6060Unknown player: " .. target .. "|r")
                return
            end
            local who = target   -- pin for the closure
            addon.Dialog:Confirm({
                title  = "Reset EP/GP",
                text   = string.format(
                    "Reset %s's EP/GP from %d:%d to 0:0?\nThis writes to their officer note and is logged.",
                    who, entry.ep or 0, entry.gp or 0),
                accept = "Reset to 0:0",
                OnAccept = function()
                    local ok, info = addon.Awards:ResetEPGP(who)
                    if ok then
                        Print(string.format("Reset %s: was %d:%d, now 0:0", who, info.oldEP, info.oldGP))
                        if addon.UI and addon.UI.MainFrame then addon.UI.MainFrame:Refresh() end
                    else
                        Print("|cFFFF6060Failed:|r " .. tostring(info))
                    end
                end,
            })
        elseif sub == "all" then
            addon.Dialog:Confirm({
                title  = "Reset Everything",
                text   =
                    "This will WIPE the entire addon state:\n" ..
                    " • award + decay history\n" ..
                    " • EP/GP for every guild member (officer notes zeroed; alt-marker notes left intact)\n" ..
                    " • price overrides + standby list\n" ..
                    " • every tunable setting in the Options panel\n\n" ..
                    "This cannot be undone.",
                justify = "LEFT",
                accept = "Apply",
                cancel = "Cancel",
                requireCheck = "I, confirm",
                OnAccept = function()
                    local ok, info = addon.Awards:ResetAll()
                    if ok then
                        Print(string.format("Reset all — %d officer note%s zeroed.", info, info == 1 and "" or "s"))
                        if addon.UI and addon.UI.MainFrame and addon.UI.MainFrame.Refresh then
                            addon.UI.MainFrame:Refresh()
                        end
                        if addon.Options and addon.Options.Refresh then addon.Options:Refresh() end
                    else
                        Print("|cFFFF6060Reset failed:|r " .. tostring(info))
                    end
                end,
            })
        else
            Print("Usage: /ee reset epgp <player> | /ee reset all")
        end
    elseif cmd == "raid" then
        if not (addon.UI and addon.UI.RaidManager) then
            Print("|cFFFF6060Raid Manager not loaded.|r")
            return
        end
        addon.UI.RaidManager:Toggle()
    elseif cmd == "mode" then
        local sub = rest:match("^(%S*)") or ""
        -- "quick" is an alias for "suggest" — kept for muscle memory from
        -- v0.1.0 since the on-screen label has always been "Suggest".
        if sub == "quick" then sub = "suggest" end
        if not addon.DB then Print("|cFFFF6060DB not initialized.|r"); return end
        if sub == "manual" or sub == "suggest" or sub == "auto" then
            addon.DB.profile.awardsMode = sub
            if addon.UI and addon.UI.RaidManager and addon.UI.RaidManager.RefreshModeLabel then
                addon.UI.RaidManager:RefreshModeLabel()
                addon.UI.RaidManager:RefreshSettingsRadios()
            end
            Print("Awards mode: |cFF55FF55" .. sub .. "|r")
        elseif sub == "" or sub == "status" then
            local cur = addon.DB.profile.awardsMode or "manual"
            local detection = (addon.Encounter and addon.Encounter.GetDetectionMode and addon.Encounter:GetDetectionMode()) or "?"
            Print(string.format("Awards mode: |cFF55FF55%s|r  |  detection: %s",
                cur, detection))
        else
            Print("Usage: /ee mode manual|suggest|auto|status")
        end
    elseif cmd == "start" then
        if not addon.RaidSession then Print("|cFFFF6060RaidSession module not loaded.|r"); return end
        addon.RaidSession:Start()
    elseif cmd == "end" then
        if not addon.RaidSession then Print("|cFFFF6060RaidSession module not loaded.|r"); return end
        addon.RaidSession:End(true)
    elseif cmd == "bid" then
        if not addon.Loot then Print("|cFFFF6060Loot module not loaded.|r"); return end
        local sub = rest:match("^(%S*)")
        if sub == "cancel" then
            if addon.Loot:CancelSession("officer cancelled") then
                Print("Bid session cancelled.")
            else
                Print("No active bid session.")
            end
            return
        end
        if sub == "show" then
            if addon.UI and addon.UI.BidFrame and addon.UI.BidFrame.Reopen then
                addon.UI.BidFrame:Reopen()
            end
            return
        end
        local devActive = addon.Dev and addon.Dev:IsActive()
        if not devActive and not (CanEditOfficerNote and CanEditOfficerNote()) then
            Print("|cFFFF6060Bid sessions are officer-only.|r")
            return
        end
        local linkOrID = rest and rest:match("^%s*(.-)%s*$")
        if not linkOrID or linkOrID == "" then
            Print("Usage: /ee bid <itemLink|itemID>  (or  /ee bid show | cancel)")
            return
        end
        local ok, err = addon.Loot:OpenSession(linkOrID, { opener = UnitName("player") })
        if not ok then
            Print("|cFFFF6060Bid open failed:|r " .. tostring(err))
        end
    elseif cmd == "sync" then
        if not addon.Sync then
            Print("|cFFFF6060Sync module not loaded.|r")
            return
        end
        local sub, arg = (rest or ""):match("^(%S+)%s*(.*)$")
        if sub == "now" or sub == "resync" then
            addon.Sync:Bootstrap()
            Print("Sync request broadcast to guild.")
        elseif sub == "get" and arg and arg ~= "" then
            local p = addon.Sync:Probe(arg)
            Print(string.format("Probe %s: envelope=%s ts=%s by=%s domainKnown=%s",
                p.path, tostring(p.hasEnvelope), tostring(p.ts),
                tostring(p.by), tostring(p.domainKnown)))
            Print("  liveValue=" .. tostring(p.liveValue))
        else
            local s = addon.Sync:Status()
            Print(string.format("Sync: bootstrapped=%s envelopes=%d officer=%s inGuild=%s",
                tostring(s.bootstrapped), s.envelopeCount,
                tostring(s.isOfficer), tostring(s.inGuild)))
            Print("Domains: " .. table.concat(s.domains, ", "))
            local g = addon.DB and addon.DB.global or {}
            Print(string.format("  basegp=%s standardIlvl=%s decay=%s osMult=%s",
                tostring(g.basegp), tostring(g.gpFormulaStandardIlvl),
                tostring(g.decay), tostring(g.osMultiplier)))
            Print(string.format("  Diff mults: heroic=%s mythic=%s ascended=%s",
                tostring(g.epHeroicMult), tostring(g.epMythicMult),
                tostring(g.epAscendedMult)))
            -- Show every populated matrix cell so we can verify per-cell sync.
            local matrixCount = 0
            if g.epAwards then
                for raid, byPreset in pairs(g.epAwards) do
                    if type(byPreset) == "table" then
                        for preset, val in pairs(byPreset) do
                            matrixCount = matrixCount + 1
                            Print(string.format("  Matrix %s/%s = %s",
                                raid, preset, tostring(val)))
                        end
                    end
                end
            end
            if matrixCount == 0 then
                Print("  Matrix: |cFFAAAAAA(no per-cell values yet)|r")
            end
            local historyCount = 0
            if g.history then
                for _ in pairs(g.history) do historyCount = historyCount + 1 end
            end
            Print(string.format("  History: %d entries", historyCount))
            Print("Use |cFFFFFF00/ee sync now|r to manually re-request from peers.")
        end
    elseif cmd == "config" or cmd == "options" then
        if not addon.Options or not addon.Options.Open then
            Print("|cFFFF6060Options module not loaded.|r")
            return
        end
        addon.Options:Open()
    elseif cmd == "minimap" then
        if not addon.Minimap or not addon.Minimap.Toggle then
            Print("|cFFFF6060Minimap module not loaded.|r")
            return
        end
        local hidden = addon.Minimap:Toggle()
        Print("Minimap button " .. (hidden and "hidden" or "shown") .. ".")
    elseif cmd == "diag" then
        addon.Core:PrintDiag()
    else
        Print("Unknown command: " .. cmd .. ". Try /ee help")
    end
end

-- One-shot diagnostic dump for "is bidding wired up correctly?" triage.
-- Surfaces config, permissions, raid state, hook installation, and any
-- active session so an officer can paste the output back to a maintainer
-- without needing to know which Lua values to query.
function addon.Core:PrintDiag()
    local p = addon.DB and addon.DB.profile or {}
    local lootMethod, _, raidMLId = (GetLootMethod and GetLootMethod()) or "?", nil, nil
    -- Avoid local _ to keep this paste-safe even if the snippet is later
    -- shared somewhere that mangles underscores (Discord markdown).
    if GetLootMethod then
        local m, pml, rml = GetLootMethod()
        lootMethod, raidMLId = m, rml
    end
    local sess = addon.Loot and addon.Loot:GetSession()

    local function fmtBool(v)
        if v then return "|cFF55FF55yes|r" else return "|cFFFF6060no|r" end
    end

    Print("|cFFFFD200--- Elitism EPGP diag ---|r")
    Print(string.format("version: %s", tostring(addon.VERSION or "?")))
    Print(string.format("config:  modifier=%s click=%s mode=%s",
        tostring(p.bidModifier or "ALT"),
        tostring(p.bidClick    or "LeftButton"),
        tostring(p.awardsMode  or p.bossKillMode or "manual")))
    Print(string.format("perms:   officer=%s raidLeader=%s masterLooter=%s inRaid=%s",
        fmtBool(addon.IsOfficer and addon.IsOfficer()),
        fmtBool(addon.IsRaidLeaderHere and addon.IsRaidLeaderHere()),
        fmtBool(lootMethod == "master" and (raidMLId or -1) == 0),
        fmtBool(addon.InRaid and addon.InRaid())))
    Print(string.format("raid:    active=%s controller=%s currentRaid=%s currentDiff=%s",
        fmtBool(p.raidActive),
        tostring(p.activeController or "-"),
        tostring(p.currentRaid       or "-"),
        tostring(p.currentDifficulty or "-")))
    Print(string.format("hooks:   clickHookInstalled=%s",
        fmtBool(addon.Loot and addon.Loot._clickHooked)))
    if sess then
        Print(string.format("session: link=%s gp=%s remaining=%.1fs bidders=%d",
            tostring(sess.link),
            tostring(sess.gp),
            (addon.Loot.GetTimeRemaining and addon.Loot:GetTimeRemaining()) or 0,
            sess.bidders and #sess.bidders or 0))
    else
        Print("session: |cFFAAAAAAnone|r")
    end
    Print("|cFFFFD200--- end diag ---|r")
end
