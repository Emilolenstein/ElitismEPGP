local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local RaidManager = {}
UI.RaidManager = RaidManager

-- TODO: When standby management lands (Phase 5 area), expose an "Include standby"
-- checkbox in the panel. Today targetMode is locked to "raid_standby" because
-- StandbyNames() is empty in practice; RaidPlusStandby() degenerates to raid-only.
local targetMode = "raid_standby"

local function CurrentTargets()
    if targetMode == "raid_standby" then
        return addon.Awards:RaidPlusStandby()
    elseif targetMode == "raid" then
        return addon.Awards:CurrentRaidNames()
    elseif targetMode == "standby" then
        return addon.Awards:StandbyNames()
    end
    return {}
end

function RaidManager:GetTargets()      return CurrentTargets() end
function RaidManager:GetTargetMode()   return targetMode end
function RaidManager:SetTargetMode(m)  targetMode = m; self:Refresh() end

local function TrimNote(text)
    if not text then return nil end
    local s = text:match("^%s*(.-)%s*$")
    if s == "" then return nil end
    return s
end

-- Player name wrapped in its class color, if we know the class; plain otherwise.
local function ColoredPlayerName(name)
    if not name then return name end
    local entry = addon.Roster and addon.Roster:Get(name)
    local hex = entry and entry.classFile and addon.CLASS_COLORS and addon.CLASS_COLORS[entry.classFile]
    if hex then return "|cFF" .. hex .. name .. "|r" end
    return name
end

local function ReportResult(label, ok, fails)
    addon.Print(string.format("%s: awarded %d player%s%s",
        label, ok, ok == 1 and "" or "s",
        (#fails > 0) and string.format(" (|cFFFF6060%d failed|r)", #fails) or ""))
    for _, f in ipairs(fails) do
        addon.Print(string.format("  |cFFFF6060- %s: %s|r", addon.ColorName(f.name), f.err))
    end
end

local PRESET_LABELS = {
    ON_TIME     = "On-time",
    END_OF_RAID = "End of raid",
    FIRST_KILL  = "First kill",
    BOSS_KILL   = "Boss kill",
}

local PRESET_KIND = {
    ON_TIME     = "EP_ON_TIME",
    END_OF_RAID = "EP_END_RAID",
    FIRST_KILL  = "EP_FIRST_KILL",
    BOSS_KILL   = "EP_BOSS_KILL",
}

function RaidManager:DoPreset(presetKey, recipients, noteOverride)
    recipients = recipients or CurrentTargets()
    if #recipients == 0 then
        addon.Print("|cFFFF6060No recipients (raid + standby empty).|r")
        return
    end
    local raid, dif
    if addon.RaidSession then raid, dif = addon.RaidSession:GetContext() end
    local amount = addon.Awards:GetAmountForPreset(presetKey, raid, dif)
    local kind = addon.Awards.Kind[PRESET_KIND[presetKey]]
    local ok, fails = addon.Awards:GiveEPBulk(recipients, amount, kind, noteOverride)
    ReportResult(string.format("%s (+%d EP)", PRESET_LABELS[presetKey], amount), ok, fails)
    addon.Awards:AnnounceAwarded(PRESET_LABELS[presetKey], amount, "EP", recipients, noteOverride)
    self:Refresh()
    return ok, fails
end

-- `recipient` (a name) scopes the dialog to one player; nil = current targets
-- (whole raid + standby). When scoped, the title reads "Award {Player}".
function RaidManager:OpenCustomDialog(recipient)
    local f = ElitismEPGPCustomAwardFrame
    if not f then return end
    f.eepgpRecipient = recipient
    if f.title then
        f.title:SetText(recipient and ("Award " .. ColoredPlayerName(recipient)) or "Custom Award")
    end
    f.amountEdit:SetText("")
    f.noteEdit:SetText("")
    f:Show()
    f.amountEdit:SetFocus()
end

function RaidManager:ApplyCustom(which)
    local f = ElitismEPGPCustomAwardFrame
    if not f then return end
    local amount = tonumber(f.amountEdit:GetText())
    if not amount or amount == 0 then
        addon.Print("|cFFFF6060Invalid amount.|r")
        return
    end
    local recipient = f.eepgpRecipient
    local targets = recipient and { recipient } or CurrentTargets()
    if #targets == 0 then
        addon.Print("|cFFFF6060No recipients.|r")
        return
    end
    local note = TrimNote(f.noteEdit:GetText())
    local kind = (which == "ep") and addon.Awards.Kind.EP_CUSTOM or addon.Awards.Kind.GP_CUSTOM
    local fn   = (which == "ep") and addon.Awards.GiveEP        or addon.Awards.GiveGP
    local ok, fails = 0, {}
    for _, name in ipairs(targets) do
        local success, err = fn(addon.Awards, name, amount, kind, note)
        if success then ok = ok + 1
        else fails[#fails + 1] = { name = name, err = err } end
    end
    ReportResult(string.format("Custom %s %+d%s", which:upper(), amount,
        recipient and (" -> " .. recipient) or ""), ok, fails)
    addon.Awards:AnnounceAwarded("Custom", amount, which:upper(), targets, note)
    f.eepgpRecipient = nil
    f:Hide()
    self:Refresh()
end

function RaidManager:GetMode()
    return (addon.DB and addon.DB.profile.awardsMode) or "manual"
end

function RaidManager:SetMode(mode)
    if not addon.DB then return end
    if mode ~= "manual" and mode ~= "suggest" and mode ~= "auto" then return end
    addon.DB.profile.awardsMode = mode
    self:RefreshModeLabel()
    self:RefreshSettingsRadios()
end

-- Display labels for the mode keys. The internal key controls behaviour
-- (manual = no auto EP; suggest = confirmation modals; auto = full auto)
-- while these strings show in the Raid Manager mode row + cog popup.
local MODE_DISPLAY = {
    manual  = "Manual",
    suggest = "Suggest",
    auto    = "Auto",
}

function RaidManager:RefreshModeLabel()
    if not self.frame then return end
    local mode = self:GetMode()
    local detection = (addon.Encounter and addon.Encounter.GetDetectionMode and addon.Encounter:GetDetectionMode()) or "?"
    local hasDBM = (detection == "DBM")
    local active = (addon.RaidSession and addon.RaidSession:IsActive()) or false
    -- Minimized active view intentionally drops the cog (the minimized bar
    -- is just clock+timer+close); without this guard, SetMode → here would
    -- re-Show the cog mid-minimized after the user picks a mode from the
    -- dropdown's Change Mode submenu.
    local minimized = active and self.minimized or false

    -- Status icon: green ReadyCheck (10×10) when DBM is up; the disabled
    -- atlas at 2× size (20×20) when it isn't, so the missing-DBM warning
    -- reads as a more prominent state. We reset texcoords when swapping
    -- back to the file-based texture, since SetAtlas may have set
    -- non-default UVs.
    if self.frame.modeCheck then
        if hasDBM then
            self.frame.modeCheck:SetTexture("Interface\\RAIDFRAME\\ReadyCheck-Ready")
            self.frame.modeCheck:SetTexCoord(0, 1, 0, 1)
            self.frame.modeCheck:SetSize(10, 10)
        elseif self.frame.modeCheck.SetAtlas then
            self.frame.modeCheck:SetAtlas("islands-questdisable")
            self.frame.modeCheck:SetSize(20, 20)
        end
    end

    -- Status label text — short colored "DBM" when up, "DBM not detected"
    -- in light gray when it isn't.
    if self.frame.modeLabel then
        if hasDBM then
            self.frame.modeLabel:SetText("|cFF55FF55DBM|r")
        else
            self.frame.modeLabel:SetText("|cFFAAAAAADBM not detected|r")
        end
    end

    -- Cog: shown in both views when DBM is up; hidden otherwise.
    -- Stash the current-mode pretty name on the button so the OnEnter
    -- tooltip can read it without re-resolving MODE_DISPLAY.
    if self.frame.cogButton then
        self.frame.cogButton.eepgpModeText = hasDBM and (MODE_DISPLAY[mode] or mode) or nil
        if hasDBM and not minimized then
            self.frame.cogButton:Show()
        else
            self.frame.cogButton:Hide()
        end
    end

    -- Two layouts:
    --
    --   Pre-raid (active=false): full mode row at y=-172 — modeCheck +
    --   modeLabel on the left, modeOption + cog on the right. Pre-raid
    --   is when the user is picking a mode, so the label + option text
    --   carry the value.
    --
    --   Active (active=true): only the cog survives. It moves up to
    --   the same vertical band as the raid title (y≈-35 → cog center
    --   y=-42) and pulls flush to the right edge (RIGHT TOPRIGHT -8).
    --   The mode value is now surfaced via the tooltip on hover, since
    --   it's reference info rather than a live picker once the raid
    --   has started.
    if self.frame.cogButton then
        self.frame.cogButton:ClearAllPoints()
        if active then
            self.frame.cogButton:SetPoint("RIGHT", self.frame, "TOPRIGHT", -8, -42)
        else
            self.frame.cogButton:SetPoint("RIGHT", self.frame, "TOPRIGHT", -10, -172)
        end
    end

    if self.frame.modeOption then
        self.frame.modeOption:ClearAllPoints()
        if active then
            self.frame.modeOption:Hide()
        else
            self.frame.modeOption:SetPoint("RIGHT", self.frame, "TOPRIGHT", -32, -172)
            if hasDBM then
                -- SetText was dropped during the active/pre-raid layout
                -- refactor — the FontString anchored but the value was
                -- never written, so the slot looked empty.
                self.frame.modeOption:SetText(MODE_DISPLAY[mode] or mode)
                self.frame.modeOption:Show()
            else
                self.frame.modeOption:Hide()
            end
        end
    end

    if self.frame.modeLabel then
        self.frame.modeLabel:ClearAllPoints()
        if active then
            self.frame.modeLabel:Hide()
        else
            -- Anchor x slides right when the bigger disabled icon takes
            -- more horizontal space (10×10 → label x=26; 20×20 → x=32).
            self.frame.modeLabel:SetPoint("LEFT", self.frame, "TOPLEFT",
                hasDBM and 26 or 32, -172)
            self.frame.modeLabel:Show()
        end
    end

    if self.frame.modeCheck then
        self.frame.modeCheck:ClearAllPoints()
        if active then
            self.frame.modeCheck:Hide()
        else
            self.frame.modeCheck:SetPoint("LEFT", self.frame, "TOPLEFT", 10, -172)
            self.frame.modeCheck:Show()
        end
    end

    -- Tooltip group is only interactive in the no-DBM state — there's
    -- nothing useful to say when the green checkmark is up.
    if self.frame.modeStatusGroup then
        self.frame.modeStatusGroup:EnableMouse(not hasDBM)
    end
end

------------------------------------------------------------
-- Active session state — drives Start/End button text + label
------------------------------------------------------------

-- Minimize / Expand the active-view panel. Only meaningful during an
-- active session; pre-raid clicks on the close button still hide the
-- frame. State is in-memory (not persisted across /reload).
function RaidManager:Minimize()
    self.minimized = true
    self:RefreshActiveState()
end

function RaidManager:Expand()
    self.minimized = false
    self:RefreshActiveState()
end

function RaidManager:RefreshActiveState()
    if not self.frame then return end
    local active     = addon.RaidSession and addon.RaidSession:IsActive() or false
    local controller = (addon.RaidSession and addon.RaidSession:Controller()) or nil
    local mineNow    = (addon.RaidSession and addon.RaidSession:IsControlledByMe()) or false
    local raid, dif
    if addon.RaidSession then raid, dif = addon.RaidSession:GetContext() end

    -- Minimized only matters while a session is active. Auto-reset on
    -- end-of-raid so the next session starts expanded and the close
    -- button reverts to its hide-frame default.
    if not active then self.minimized = false end
    local minimized = active and self.minimized or false

    -- Bid panel toggle button: lives under End Raid in the active expanded
    -- view while a bid session is in progress (the frame grows to fit it).
    -- In the minimized view it's a dropdown entry instead, not a button.
    local bidActive   = (addon.Loot and addon.Loot:GetSession()) and true or false
    local bidPanelBtn = active and (not minimized) and bidActive

    -- Re-run the mode-row layout so the DBM icon/label/option/cog
    -- migrate to the top row when active and back to y=-172 when not.
    self:RefreshModeLabel()

    -- Pre-raid: title at top (y=-13), subtitle hidden, clock+timer
    -- hidden. Active: clock+timer take the top row, title slides down
    -- to y=-35, difficulty subtitle below at y=-52 (XML default).
    -- Minimized active hides the title/subtitle so the row is just
    -- clock+timer+close.
    if self.frame.title then
        local raidName = raid
        for _, r in ipairs(addon.RAIDS or {}) do
            if r.key == raid then raidName = r.name; break end
        end
        self.frame.title:ClearAllPoints()
        if active then
            self.frame.title:SetText(raidName or "Raid")
            self.frame.title:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 13, -35)
            if minimized then self.frame.title:Hide() else self.frame.title:Show() end
        else
            self.frame.title:SetText("Select raid setup")
            self.frame.title:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 13, -13)
            self.frame.title:Show()
        end
    end
    if self.frame.subtitle then
        if active and dif and not minimized then
            self.frame.subtitle:SetText(dif)  -- white via inherits=GameFontHighlightSmall
            self.frame.subtitle:Show()
        else
            self.frame.subtitle:Hide()
        end
    end
    if self.frame.clockIcon then
        if active then
            -- Reposition for the minimized branch only: nudged right
            -- and down by 3 so the icon sits inside the new placeholder
            -- border. Expanded view keeps the default (6, -4) anchor.
            self.frame.clockIcon:ClearAllPoints()
            if minimized then
                self.frame.clockIcon:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 8, -10)
            else
                self.frame.clockIcon:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 6, -4)
            end
            self.frame.clockIcon:Show()
        else
            self.frame.clockIcon:Hide()
        end
    end
    if self.frame.topDivider then
        -- Divider sits under the title row; hide it in minimized so the
        -- top bar reads as a single clean band.
        if active and not minimized then self.frame.topDivider:Show() else self.frame.topDivider:Hide() end
    end
    -- Footer band (auctionhouse-ui-dropdown-middle tile at y=-158) sits
    -- above the bottom-row mode controls in pre-raid view. In active
    -- view the mode row is gone, so the band has nothing to frame —
    -- hide it for a cleaner bottom edge.
    if self.frame.headerRowTiles then
        for _, t in ipairs(self.frame.headerRowTiles) do
            if active then t:Hide() else t:Show() end
        end
    end

    -- Cog hides when minimized — its post-raid position is on the top
    -- row, but the minimized layout intentionally keeps only the
    -- close-as-minimize button + timer.
    if self.frame.cogButton and minimized then
        self.frame.cogButton:Hide()
    end

    -- Frame size. Pre-raid: XML default (163 × 186) fits the bottom
    -- mode row + footer band. Active expanded: same width, height 170
    -- (tight margin under End Raid) — or 198 when the bid-panel toggle
    -- button is showing under End Raid. Active minimized: 102 × 32 —
    -- just the top row of clock + time + close button, with the new
    -- portrait-ring border supplying its own bg. SimpleMetal border +
    -- backdrop bg resize automatically since they're anchored to the frame.
    if minimized then
        self.frame:SetWidth(102)
        self.frame:SetHeight(32)
    elseif active then
        self.frame:SetWidth(163)
        self.frame:SetHeight(bidPanelBtn and 198 or 170)
    else
        self.frame:SetWidth(163)
        self.frame:SetHeight(186)
    end

    -- Minimized chrome swap: hide the SimpleMetal corners/edges and the
    -- decorative filigree, then show a GarrMission portrait-ring border
    -- (70×24) as a placeholder. Position is provisional — user will
    -- arrange it once it's visible. Other states restore the metal
    -- border + filigree as they were.
    local metal = self.frame.eepgpSimpleMetalBorder
    if metal then
        for _, set in ipairs({ metal.corners, metal.edges }) do
            if set then
                for _, t in pairs(set) do
                    if minimized then t:Hide() else t:Show() end
                end
            end
        end
    end
    if self.frame.closeFiligree then
        if minimized then self.frame.closeFiligree:Hide() else self.frame.closeFiligree:Show() end
    end

    if minimized and not self.frame.minimizedBorder then
        -- BACKGROUND layer: above the (hidden) dark Backdrop bg, below the
        -- BORDER-layer hover highlight, and well below the ARTWORK-layer
        -- clock icon + elapsed-time text and the close button (child frame).
        local b = self.frame:CreateTexture(nil, "BACKGROUND")
        if b.SetAtlas then b:SetAtlas("GarrMission_PortraitRing_iLvlBorder") end
        -- Scaled from the source 70×24 → 110 wide, height proportional
        -- (110/70 * 24 ≈ 37.71) so aspect ratio is preserved.
        b:SetSize(110, 24 * 110 / 70)
        -- Anchored to the frame's top-left (i.e. top-left of the bg
        -- rect, since the Backdrop fills the frame), nudged 4 px left
        -- and 3 px up so it overhangs the frame edge.
        b:SetPoint("TOPLEFT", self.frame, "TOPLEFT", -4, 3)
        self.frame.minimizedBorder = b
    end
    if self.frame.minimizedBorder then
        if minimized then self.frame.minimizedBorder:Show() else self.frame.minimizedBorder:Hide() end
    end
    if self.frame.minimizedHotspot then
        if minimized then self.frame.minimizedHotspot:Show() else self.frame.minimizedHotspot:Hide() end
    end

    -- Hover highlight over the duration group. BORDER layer puts it above
    -- the portrait-ring bg (BACKGROUND layer) but below the ARTWORK-layer
    -- clock + elapsed text and the close button (child frame). Hidden by
    -- default; the minimizedHotspot's OnEnter/OnLeave reveal it on hover.
    if minimized and not self.frame.minimizedHighlight then
        local h = self.frame:CreateTexture(nil, "BORDER")
        if h.SetAtlas then h:SetAtlas("pta-tab-checked") end
        -- Stretched (aspect intentionally broken) to fit the duration row.
        h:SetSize(93.5, 20)
        h:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 5, -6)
        h:SetAlpha(0.6)
        h:Hide()
        self.frame.minimizedHighlight = h
    end
    if self.frame.minimizedHighlight then
        self.frame.minimizedHighlight:Hide()
    end

    -- Backdrop bg: hidden in minimized (new texture brings its own
    -- background art) and restored to the profile's bgOpacity setting
    -- otherwise. SetBackdropColor with alpha 0 is the cheapest way to
    -- hide the bg without re-issuing SetBackdrop (which would also
    -- nuke the edge file).
    if self.frame.SetBackdropColor then
        if minimized then
            self.frame:SetBackdropColor(1, 1, 1, 0)
        else
            local pct = (addon.DB and addon.DB.profile and addon.DB.profile.bgOpacity) or 89
            self.frame:SetBackdropColor(1, 1, 1, pct / 100)
        end
    end

    -- Close button: position + size + texture all swap by state.
    -- Pre-raid stays the stock 32×32 UIPanelCloseButton. Active uses
    -- the smaller 24×24 red-refresh button; offsets compensate for
    -- the size delta (+4, -4) so the visual center stays where the
    -- 32×32 button was previously anchored.
    if self.frame.closeButton then
        local cb = self.frame.closeButton
        local nt = cb:GetNormalTexture()
        local pt = cb:GetPushedTexture()
        if nt and not self._closeOrigNormal then
            self._closeOrigNormal = nt:GetTexture()
        end
        if pt and not self._closeOrigPushed then
            self._closeOrigPushed = pt:GetTexture()
        end

        cb:ClearAllPoints()
        if active then
            -- Texture swap
            if nt and nt.SetAtlas then nt:SetAtlas("128-redbutton-refresh") end
            if pt and pt.SetAtlas then pt:SetAtlas("128-redbutton-refresh-pressed") end
            cb:SetSize(20, 20)
            -- Position. Both offsets shift by (+6, -6) from the
            -- 32×32-era anchor so the new 20×20 button keeps the same
            -- visual center as the original close button.
            if minimized then
                cb:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 77, -5)
            else
                cb:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 141.5, -1)
            end
        else
            -- Restore stock close button
            if nt and self._closeOrigNormal then
                nt:SetTexture(self._closeOrigNormal)
                nt:SetTexCoord(0, 1, 0, 1)
            end
            if pt and self._closeOrigPushed then
                pt:SetTexture(self._closeOrigPushed)
                pt:SetTexCoord(0, 1, 0, 1)
            end
            cb:SetSize(32, 32)
            cb:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 137, 5)
        end
    end
    if self.frame.elapsedText then
        if active then
            local elapsed = addon.RaidSession:ElapsedString() or "0:00"
            self.frame.elapsedText:SetText(elapsed)
            self.frame.elapsedText:Show()
        else
            self.frame.elapsedText:Hide()
        end
    end

    -- Start/End button text + state. Position differs per view —
    -- active = x=11, y=-131 (shifted right + down to balance the
    -- shrunk frame); pre-raid = x=11, y=-111. Hidden while minimized.
    local btn = self.frame.btnRaidSession
    if btn then
        btn:ClearAllPoints()
        if minimized then
            btn:Hide()
        elseif active then
            btn:Show()
            btn:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 11, -131)
            btn:SetText("|cFFFFFFFFEnd Raid|r")
            -- Only the controller (or dev) can end.
            if mineNow or (addon.Dev and addon.Dev:IsActive()) then btn:Enable() else btn:Disable() end
        else
            btn:Show()
            btn:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 11, -111)
            btn:SetText("Start Raid")
            -- Only RL+officer can start (or dev mode bypass), AND raid +
            -- difficulty must be picked so EP awards key off the matrix.
            local hasContext = addon.RaidSession and addon.RaidSession:HasContext()
            local devActive  = addon.Dev and addon.Dev:IsActive()
            local hasAuth    = (addon.CanAwardEP and addon.CanAwardEP()) or devActive
            local inRaid     = addon.InRaid and addon.InRaid()
            local isLeader   = addon.IsRaidLeaderHere and addon.IsRaidLeaderHere()

            if hasAuth and hasContext then
                btn:Enable()
                btn:SetAlpha(1.0)
                btn.eepgpDisabledTip = nil
            else
                btn:Disable()
                if not hasAuth then
                    -- Auth-missing: button is dimmed to 40% so it reads
                    -- as a stronger "you can't act here" state, with a
                    -- tooltip explaining what's needed. Two flavors:
                    -- not in a raid at all, vs in the raid but not RL.
                    btn:SetAlpha(0.4)
                    if not inRaid then
                        btn.eepgpDisabledTip = {
                            title = "Not in a raid",
                            body  = "Join a raid as the Raid Leader to start an EP session.",
                        }
                    elseif not isLeader then
                        btn.eepgpDisabledTip = {
                            title = "Raid Leader only",
                            body  = "Only the current Raid Leader can start an EP session.",
                        }
                    else
                        -- Officer permission missing (rare edge case).
                        btn.eepgpDisabledTip = {
                            title = "Officer rank required",
                            body  = "Only ranks with Edit Officer Note permission can start an EP session.",
                        }
                    end
                else
                    -- Has auth but no raid/difficulty picked yet —
                    -- standard disabled look, no tooltip.
                    btn:SetAlpha(1.0)
                    btn.eepgpDisabledTip = nil
                end
            end
            -- Tooltip overlay: shown only when there's something to say.
            -- Disabled WoW Buttons don't fire OnEnter, so we float a
            -- transparent Frame above the button to catch hover.
            if btn.eepgpHoverOverlay then
                if btn.eepgpDisabledTip then
                    btn.eepgpHoverOverlay:Show()
                else
                    btn.eepgpHoverOverlay:Hide()
                end
            end
        end
    end

    -- (Old "ACTIVE" row was here; replaced by the inline clock + timer
    -- in the subtitle row above.)

    -- Award / Players / Logs are only relevant once a raid is running — keep
    -- the pre-raid view focused on raid + difficulty selection. Reveal them
    -- as soon as the session starts. Hidden in the minimized active state.
    for _, btn in ipairs({ self.frame.btnAward, self.frame.raidInfoButton, self.frame.btnLogs }) do
        if btn then
            if active and not minimized then btn:Show() else btn:Hide() end
        end
    end

    -- Conversely, the raid + difficulty pickers are pre-raid only — once
    -- the session is running, both values are locked in so the pickers
    -- have nothing to do and just take up space.
    for _, btn in ipairs({ self.frame.btnRaidPicker, self.frame.btnDifficultyPicker }) do
        if btn then
            if active then btn:Hide() else btn:Show() end
        end
    end

    -- Award button is officer + RL only (manual EP awards still gate on RL).
    if self.frame.btnAward then
        if (addon.CanAwardEP and addon.CanAwardEP()) or (addon.Dev and addon.Dev:IsActive()) then
            self.frame.btnAward:Enable()
        else
            self.frame.btnAward:Disable()
        end
    end

    -- Bid panel toggle button — active expanded view only, while a bid
    -- session is in progress. Sits directly under End Raid (which is at
    -- y=-131, h=26 → bottom at -157); 2 px gap puts this at y=-159, and
    -- the frame was grown to 198 above so it has room. Minimized view
    -- surfaces the same action as a dropdown entry instead (see
    -- InitMinimizedMenu); pre-raid never shows it.
    if self.frame.btnBidShow then
        if bidPanelBtn then
            self.frame.btnBidShow:ClearAllPoints()
            self.frame.btnBidShow:SetPoint("TOPLEFT", self.frame, "TOPLEFT", 11, -159)
            self.frame.btnBidShow:Show()
            self:RefreshBidToggle()
        else
            self.frame.btnBidShow:Hide()
        end
    end
end

-- Keep the bid-toggle button's label in sync with whether the officer
-- BidFrame is currently visible: "Hide Bids" when it's up, "View Bids"
-- when it's been dismissed.
function RaidManager:RefreshBidToggle()
    if not self.frame or not self.frame.btnBidShow then return end
    self.frame.btnBidShow:SetText(self:IsBidPanelShown() and "Hide Bids" or "View Bids")
end

function RaidManager:IsBidPanelShown()
    local bf = addon.UI and addon.UI.BidFrame and addon.UI.BidFrame.frame
    return bf and bf:IsShown() and true or false
end

-- Shared by the expanded-view button (btnBidShow) and the minimized
-- dropdown entry: flip the officer BidFrame on/off.
function RaidManager:ToggleBidPanel()
    local BF = addon.UI and addon.UI.BidFrame
    if not BF then return end
    if BF.frame and BF.frame:IsShown() then
        if BF.Close then BF:Close() end
    else
        if BF.Reopen then BF:Reopen() elseif BF.Open then BF:Open() end
    end
    self:RefreshBidToggle()
end

function RaidManager:RefreshSettingsRadios()
    local s = ElitismEPGPRaidManagerSettingsFrame
    if not s then return end
    local mode = self:GetMode()
    s.radioManual:SetChecked(mode == "manual")
    s.radioQuick:SetChecked(mode == "suggest")  -- radio var name kept for back-compat
    s.radioAuto:SetChecked(mode == "auto")
end

-- Click-outside-to-dismiss eater for the settings popup. The whole
-- addon lives on MEDIUM strata to avoid interleaving with bag/vendor
-- frames at HIGH; internal z-ordering uses frame levels:
--   RaidManagerFrame body  ~ level 1
--   metal border overlay   ~ level 11   (parent + 10)
--   cog button             ~ level 16   (parent + 15)
--   settingsEater          ~ level 30   ← here
--   settings popup         ~ level 40   (set when shown)
local settingsEater
local function ensureSettingsEater()
    if settingsEater then return settingsEater end
    settingsEater = CreateFrame("Button", nil, UIParent)
    settingsEater:SetAllPoints(UIParent)
    settingsEater:SetFrameStrata("MEDIUM")
    settingsEater:SetFrameLevel(30)
    settingsEater:RegisterForClicks("AnyUp")
    settingsEater:Hide()
    settingsEater:SetScript("OnClick", function()
        local s = ElitismEPGPRaidManagerSettingsFrame
        if s then s:Hide() end
    end)
    return settingsEater
end

function RaidManager:OpenSettings()
    local s = ElitismEPGPRaidManagerSettingsFrame
    if not s then return end
    if s:IsShown() then
        s:Hide()
        return
    end
    -- Both the popup and its eater live on MEDIUM strata; the popup
    -- needs to draw above the eater (level 30), so we pin it to 40.
    -- Setting it every show keeps it correct after a /reload that
    -- might've reset the level back to the XML inheritance default.
    s:SetFrameLevel(40)

    -- Anchor follows the visible trigger element:
    --   * Active minimized → directly under the minimized hotspot
    --     (same anchor the minimized action dropdown uses, so all
    --     dropdowns from the collapsed bar fan out from one spot).
    --   * Active expanded → just below the cog, which moved up to the
    --     title row (cog bottom y≈-52; +8 px breathing room → y=-55,
    --     right-aligned with the cog at -8).
    --   * Pre-raid → below the bottom-row cog at (-10, -194).
    local active    = (addon.RaidSession and addon.RaidSession:IsActive()) or false
    local minimized = active and self.minimized or false
    s:ClearAllPoints()
    if minimized and self.frame.minimizedHotspot then
        s:SetPoint("TOPLEFT", self.frame.minimizedHotspot, "BOTTOMLEFT", 0, 0)
    elseif active then
        s:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -8, -55)
    else
        s:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -10, -194)
    end

    self:RefreshSettingsRadios()
    s:Show()
    ensureSettingsEater():Show()
end

------------------------------------------------------------
-- Banner (separate floating frame anchored above RaidManager)
------------------------------------------------------------

local BANNER_AUTO_HIDE_AFTER = 5

function RaidManager:HideBanner()
    local b = ElitismEPGPRaidManagerBannerFrame
    if not b then return end
    b:Hide()
    self._activeBoss = nil
    self._bannerExpiry = nil
end

function RaidManager:ShowBanner(bossName, kind, info)
    local b = ElitismEPGPRaidManagerBannerFrame
    if not b then return end
    self._activeBoss = bossName
    self._bannerExpiry = nil

    -- Same modal in both modes: "{Boss} killed" up top. Suggest mode shows
    -- the Award/Cancel button group below; auto mode (the award already
    -- happened) swaps that for an "+N EP awarded to N players" line and
    -- self-hides after a few seconds.
    b.text:SetText(string.format("|cFFFFCC00%s|r killed", bossName))
    b:SetHeight(56)

    if kind == "auto" then
        local amount = (info and info.amount) or 0
        local n      = (info and info.ok) or 0
        if b.awardLine then
            b.awardLine:SetText(string.format("|cFF55FF55+%d EP|r awarded to %d player%s",
                amount, n, n == 1 and "" or "s"))
            b.awardLine:Show()
        end
        b.bannerAccept:Hide()
        b.bannerDismiss:Hide()
        self._bannerExpiry = GetTime() + BANNER_AUTO_HIDE_AFTER
        if not self._bannerTicker then
            self._bannerTicker = CreateFrame("Frame")
            self._bannerTicker:SetScript("OnUpdate", function()
                if self._bannerExpiry and GetTime() >= self._bannerExpiry then
                    self:HideBanner()
                end
            end)
        end
    else
        if b.awardLine then b.awardLine:Hide() end
        b.bannerAccept:Show()
        b.bannerDismiss:Show()
    end
    b:Show()
end

function RaidManager:HandleBossKill(bossName, force)
    if not bossName or bossName == "" then return end
    local mode = self:GetMode()
    if mode == "manual" then
        if not force then return end
        mode = "suggest"
    end

    self:Open()
    if mode == "auto" then
        local recipients = addon.Awards:RaidPlusStandby()
        local raid, dif
    if addon.RaidSession then raid, dif = addon.RaidSession:GetContext() end
        local amount = addon.Awards:GetAmountForPreset("BOSS_KILL", raid, dif)
        if #recipients == 0 then
            addon.Print(string.format("|cFFFFCC00Auto: %s killed but no recipients.|r", bossName))
            self:ShowBanner(bossName, "suggest")
            return
        end
        local ok, fails = addon.Awards:GiveEPBulk(recipients, amount, addon.Awards.Kind.EP_BOSS_KILL, "Killed: " .. bossName)
        ReportResult(string.format("Auto Boss kill (+%d EP, %s)", amount, bossName), ok, fails)
        addon.Awards:AnnounceAwarded(
            string.format("Boss kill — %s", bossName), amount, "EP", recipients)
        self:ShowBanner(bossName, "auto", { ok = ok, amount = amount })
    else
        self:ShowBanner(bossName, "suggest")
    end
    self:Refresh()
end

function RaidManager:Refresh()
    if not self.frame then return end
    self:RefreshModeLabel()
    self:RefreshActiveState()
    if UI.RaidInfo and UI.RaidInfo.frame and UI.RaidInfo.frame:IsShown() and UI.RaidInfo.Refresh then
        UI.RaidInfo:Refresh()
    end
end

function RaidManager:SavePos()
    if not self.frame or not addon.DB then return end
    local point, _, relPoint, x, y = self.frame:GetPoint()
    addon.DB.profile.raidManagerPos = { point = point, relPoint = relPoint, x = x, y = y }
end

function RaidManager:RestorePos()
    if not self.frame or not addon.DB then return end
    local pos = addon.DB.profile.raidManagerPos
    if not pos then return end
    self.frame:ClearAllPoints()
    self.frame:SetPoint(pos.point or "CENTER", UIParent, pos.relPoint or pos.point or "CENTER", pos.x or 0, pos.y or 0)
end

function RaidManager:Open()
    if not self.frame then self:Init() end
    if not self.frame then return end
    if not (CanEditOfficerNote and CanEditOfficerNote()) then
        addon.Print("|cFFAAAAAARaid Manager is officer-only.|r")
        return
    end
    self.frame:Show()
    self:Refresh()
end

function RaidManager:Close()
    if self.frame then self.frame:Hide() end
end

function RaidManager:Toggle()
    if not self.frame then self:Init() end
    if not self.frame then return end
    if self.frame:IsShown() then self.frame:Hide() else self:Open() end
end

function RaidManager:ToggleRaidInfo()
    if not UI.RaidInfo or not UI.RaidInfo.Toggle then return end
    UI.RaidInfo:Toggle(self.frame)
end

------------------------------------------------------------
-- Side-panel layout: Players + Session Logs share the side of RM.
-- Players is anchored directly to RM; Logs sits beyond Players if
-- both are open (or directly next to RM if Players is closed).
------------------------------------------------------------

function RaidManager:LayoutSidePanels()
    local rm = self.frame
    if not rm then return end

    local players   = ElitismEPGPRaidInfoFrame
    local logs      = ElitismEPGPSessionLogsFrame
    local logDetail = ElitismEPGPSessionLogDetailFrame

    local screenWidth = UIParent:GetWidth()
    local rmCenterX   = (rm:GetLeft() or 0) + (rm:GetWidth() or 0) / 2
    local openLeft    = rmCenterX > screenWidth / 2  -- panels open to the LEFT of RM

    local function anchor(panel, parent)
        panel:ClearAllPoints()
        if openLeft then
            panel:SetPoint("TOPRIGHT", parent, "TOPLEFT", -4, 0)
        else
            panel:SetPoint("TOPLEFT",  parent, "TOPRIGHT", 4, 0)
        end
    end

    local playersShown = players and players:IsShown()
    local logsShown    = logs and logs:IsShown()

    if playersShown then anchor(players, rm) end
    if logsShown then
        anchor(logs, playersShown and players or rm)
    end
    -- Session-log detail popup sits one step further out on the same side,
    -- beside the Session Log it belongs to.
    if logDetail and logDetail:IsShown() then
        anchor(logDetail, logsShown and logs or (playersShown and players or rm))
    end
end

function RaidManager:OpenLogs()
    if not UI.SessionLogs or not UI.SessionLogs.Toggle then return end
    UI.SessionLogs:Toggle(self.frame)
end

------------------------------------------------------------
-- Award dropdown
------------------------------------------------------------

local awardMenuFrame
local AWARD_OPTIONS = {
    { text = "Boss Kill",       preset = "BOSS_KILL"   },
    { text = "On Time",         preset = "ON_TIME"     },
    { text = "End of Raid",     preset = "END_OF_RAID" },
    { text = "First Kill",      preset = "FIRST_KILL"  },
    { text = "Custom +/-...",   custom = true          },
}

local function InitAwardMenu(_, level)
    if not level then return end

    -- When opened from a Players-list row, awardMenuFrame.eepgpRecipient holds
    -- that player's name and every option applies to just them; otherwise nil
    -- and options apply to the current targets (whole raid + standby).
    local recipient = awardMenuFrame and awardMenuFrame.eepgpRecipient

    -- Header row mirrors the title used in other dropdown menus —
    -- isTitle=1 renders as a non-clickable colored label across the
    -- top of the menu so the user knows what they're picking from.
    local title = UIDropDownMenu_CreateInfo()
    title.isTitle      = 1
    title.text         = recipient and ("Award " .. ColoredPlayerName(recipient)) or "Award"
    title.notCheckable = 1
    UIDropDownMenu_AddButton(title, level)

    for _, opt in ipairs(AWARD_OPTIONS) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = opt.text
        info.notCheckable = true
        if opt.custom then
            info.func = function() RaidManager:OpenCustomDialog(recipient) end
        else
            local key = opt.preset
            info.func = function() RaidManager:DoPreset(key, recipient and { recipient } or nil) end
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

------------------------------------------------------------
-- Minimized-view action menu. The duration row in the collapsed bar
-- acts as a hotspot — clicking it opens this dropdown so the RL can
-- still reach Award / Players / Log / Change Mode without expanding.
------------------------------------------------------------

-- Forward declaration so InitMinimizedMenu's closure binds to the
-- local instead of a nil global. The actual assignment happens at
-- `local function ToggleAwardMenu() ... end` below.
local ToggleAwardMenu

local minimizedMenuFrame
local function InitMinimizedMenu(_, level)
    if not level then return end

    local title = UIDropDownMenu_CreateInfo()
    title.isTitle      = 1
    title.text         = "Raid Manager"
    title.notCheckable = 1
    UIDropDownMenu_AddButton(title, level)

    local function add(text, fn)
        local info = UIDropDownMenu_CreateInfo()
        info.text         = text
        info.notCheckable = true
        info.func         = fn
        UIDropDownMenu_AddButton(info, level)
    end

    -- Award goes through the existing ToggleAwardMenu so users get the
    -- same preset list (On Time / End of Raid / First Kill / Boss
    -- Kill / Custom). ToggleDropDownMenu will close the parent menu
    -- before opening the Award one, which is the desired UX.
    add("Award",       function() ToggleAwardMenu() end)
    add("Players",     function() RaidManager:ToggleRaidInfo() end)
    add("Log",         function() RaidManager:OpenLogs() end)
    add("Change Mode", function() RaidManager:OpenSettings() end)

    -- Bid panel toggle — only while a bid session is live. The expanded
    -- view shows this as a button under End Raid; collapsed, it's here.
    if addon.Loot and addon.Loot:GetSession() then
        add(RaidManager:IsBidPanelShown() and "Hide Bids" or "View Bids",
            function() RaidManager:ToggleBidPanel() end)
    end
end

local function ToggleMinimizedMenu()
    if not minimizedMenuFrame then
        minimizedMenuFrame = CreateFrame("Frame", "ElitismEPGPMinimizedMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(minimizedMenuFrame, InitMinimizedMenu, "MENU")
    end
    -- Anchor under the duration hotspot when it's available, falling
    -- back to the frame's bottom-left (the bar itself) otherwise.
    local f = RaidManager.frame
    local anchor = (f and f.minimizedHotspot) or f
    if anchor then
        ToggleDropDownMenu(1, nil, minimizedMenuFrame, anchor, 0, 0)
    else
        ToggleDropDownMenu(1, nil, minimizedMenuFrame, "cursor", 0, 0)
    end
end

-- Assigns into the forward-declared local above (not a new local) so
-- callers like InitMinimizedMenu, defined earlier, can invoke it.
--   recipient       — name string to scope every option to one player (or nil
--                     for the usual whole-raid behavior).
--   anchorOverride  — frame or "cursor" to anchor the menu under (e.g. a
--                     clicked Players-list row); nil = the usual placement.
ToggleAwardMenu = function(recipient, anchorOverride)
    if not awardMenuFrame then
        awardMenuFrame = CreateFrame("Frame", "ElitismEPGPAwardMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(awardMenuFrame, InitAwardMenu, "MENU")
    end
    awardMenuFrame.eepgpRecipient = recipient   -- read by InitAwardMenu
    if anchorOverride then
        ToggleDropDownMenu(1, nil, awardMenuFrame, anchorOverride, 0, 0)
        return
    end
    -- Anchor depends on view state:
    --   * Active minimized → drop under the duration hotspot, matching
    --     the minimized action menu's anchor exactly.
    --   * Otherwise (pre-raid or active expanded) → left-aligned under
    --     the Award circle button. y=+2 matches the hover tooltip so
    --     the dropdown reads as a peer of it.
    local f = RaidManager.frame
    local active    = (addon.RaidSession and addon.RaidSession:IsActive()) or false
    local minimized = active and RaidManager.minimized or false
    local anchor, xOff, yOff
    if minimized and f and f.minimizedHotspot then
        anchor, xOff, yOff = f.minimizedHotspot, 0, 0
    elseif f and f.btnAward then
        anchor, xOff, yOff = f.btnAward, 0, 2
    end
    if anchor then
        ToggleDropDownMenu(1, nil, awardMenuFrame, anchor, xOff, yOff)
    else
        ToggleDropDownMenu(1, nil, awardMenuFrame, "cursor", 0, 0)
    end
end

-- Open the Award dropdown scoped to a single player (used by the Players list:
-- click a row → award options apply only to that player). Pops at the cursor.
function RaidManager:OpenPlayerAwardMenu(name)
    if not name or name == "" then return end
    ToggleAwardMenu(name, "cursor")
end

------------------------------------------------------------
-- Raid + Difficulty pickers
------------------------------------------------------------
-- Two dropdown buttons at the top of the panel. The current selection
-- is shown as the button text; clicking opens a UIDropDownMenu. Until
-- both are set, Start Raid stays disabled and EP awards fall back to
-- the legacy flat scalars (so nothing breaks for guilds mid-migration).

local raidMenuFrame, difMenuFrame

local function InitRaidPickerMenu(_, level)
    if not level then return end
    -- "None" clears the raid selection — the picker label reverts to its
    -- "Raid" placeholder via RefreshContextLabels when the value is nil.
    -- Rendered in white at ~70% alpha (|cB3FFFFFF) so it reads as a
    -- secondary "reset" entry rather than a real raid choice.
    local noneInfo = UIDropDownMenu_CreateInfo()
    noneInfo.text = "|cFFB3B3B3None|r"
    noneInfo.notCheckable = true
    noneInfo.func = function()
        local _, curDif = addon.RaidSession:GetContext()
        addon.RaidSession:SetContext(nil, curDif)
    end
    UIDropDownMenu_AddButton(noneInfo, level)
    for _, raid in ipairs(addon.RAIDS or {}) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = raid.name
        info.notCheckable = true
        info.func = function()
            local _, curDif = addon.RaidSession:GetContext()
            addon.RaidSession:SetContext(raid.key, curDif)
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

local function InitDifficultyPickerMenu(_, level)
    if not level then return end
    -- "None" clears the difficulty selection — picker label reverts to
    -- "Difficulty" placeholder when nil. White at ~70% alpha so it reads
    -- as a secondary "reset" entry, matching the raid picker's None.
    local noneInfo = UIDropDownMenu_CreateInfo()
    noneInfo.text = "|cFFB3B3B3None|r"
    noneInfo.notCheckable = true
    noneInfo.func = function()
        local curRaid = addon.RaidSession:GetContext()
        addon.RaidSession:SetContext(curRaid, nil)
    end
    UIDropDownMenu_AddButton(noneInfo, level)
    for _, dif in ipairs(addon.DIFFICULTIES or {}) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = dif
        info.notCheckable = true
        info.func = function()
            local curRaid = addon.RaidSession:GetContext()
            addon.RaidSession:SetContext(curRaid, dif)
        end
        UIDropDownMenu_AddButton(info, level)
    end
end

-- Tracks the picker buttons we've skinned so we can sync their visual
-- open/close state when DropDownList1 hides (e.g. user clicks elsewhere
-- to dismiss the menu, instead of clicking the picker button again).
-- Uses a getter closure for the menu frame because raidMenuFrame and
-- difMenuFrame are created lazily on first toggle — capturing them by
-- value at registration time would store nil forever.
local skinnedPickers = {}

local function syncPickerVisuals()
    for _, info in ipairs(skinnedPickers) do
        local menu   = info.getMenu and info.getMenu()
        local isOpen = menu and DropDownList1 and DropDownList1:IsShown()
                       and UIDROPDOWNMENU_OPEN_MENU == menu
        if info.button.eepgpSetDropdownOpen then
            info.button.eepgpSetDropdownOpen(isOpen and true or false)
        end
    end
end

local function ensureDropDownHook()
    if DropDownList1 and not DropDownList1.eepgpPickerHook then
        DropDownList1:HookScript("OnHide", syncPickerVisuals)
        DropDownList1.eepgpPickerHook = true
    end
end

local function ToggleRaidPickerMenu(anchor)
    if not raidMenuFrame then
        raidMenuFrame = CreateFrame("Frame", "ElitismEPGPRaidPickerMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(raidMenuFrame, InitRaidPickerMenu, "MENU")
    end
    ToggleDropDownMenu(1, nil, raidMenuFrame, anchor or "cursor", 0, 0)
    ensureDropDownHook()
    syncPickerVisuals()
end

local function ToggleDifficultyPickerMenu(anchor)
    if not difMenuFrame then
        difMenuFrame = CreateFrame("Frame", "ElitismEPGPDifficultyPickerMenu", UIParent, "UIDropDownMenuTemplate")
        UIDropDownMenu_Initialize(difMenuFrame, InitDifficultyPickerMenu, "MENU")
    end
    ToggleDropDownMenu(1, nil, difMenuFrame, anchor or "cursor", 0, 0)
    ensureDropDownHook()
    syncPickerVisuals()
end

local function registerPicker(button, menuGetter)
    skinnedPickers[#skinnedPickers + 1] = { button = button, getMenu = menuGetter }
end

local function raidDisplayName(raidKey)
    if not raidKey then return nil end
    for _, r in ipairs(addon.RAIDS or {}) do
        if r.key == raidKey then return r.name end
    end
    return raidKey
end

function RaidManager:RefreshContextLabels()
    if not self.frame then return end
    local raid, dif
    if addon.RaidSession then raid, dif = addon.RaidSession:GetContext() end
    if self.frame.btnRaidPicker then
        self.frame.btnRaidPicker:SetText(raidDisplayName(raid) or "Raid")
        local fs = self.frame.btnRaidPicker:GetFontString()
        if fs then fs:SetAlpha(raid and 1.0 or 0.6) end
    end
    if self.frame.btnDifficultyPicker then
        self.frame.btnDifficultyPicker:SetText(dif or "Difficulty")
        local fs = self.frame.btnDifficultyPicker:GetFontString()
        if fs then fs:SetAlpha(dif and 1.0 or 0.6) end
    end
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------

-- Build a row-spanning hover button for a radio option. The radio itself
-- becomes a pure visual indicator (mouse disabled), and the row button
-- captures hover + click across the entire row so the highlight reads
-- as a dropdown-style item, not just a click on the tiny circle.
local function makeRadioRow(s, radioKey, mode, topY)
    local radio = s[radioKey]
    if not radio then return end
    radio:EnableMouse(false)

    local row = CreateFrame("Button", nil, s)
    row:SetPoint("TOPLEFT",  s, "TOPLEFT",  6, topY)
    row:SetPoint("TOPRIGHT", s, "TOPRIGHT", -6, topY)
    row:SetHeight(20)

    local hl = row:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(row)
    hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    hl:SetBlendMode("ADD")

    row:SetScript("OnClick", function()
        RaidManager:SetMode(mode)
        RaidManager:RefreshSettingsRadios()
        s:Hide()
    end)
end

local function WireSettingsFrame()
    local s = ElitismEPGPRaidManagerSettingsFrame
    if not s then return end
    -- Each radio gets a row button that spans the popup width with a
    -- hover highlight; clicking anywhere on the row selects that mode.
    -- Top-Y values match the radios' anchored positions (~radio.top - 1).
    makeRadioRow(s, "radioManual", "manual",  -29)
    makeRadioRow(s, "radioQuick",  "suggest", -53)
    makeRadioRow(s, "radioAuto",   "auto",    -77)
    -- Hide the click-outside eater whenever the settings frame closes,
    -- regardless of who triggered the close (eater click, cog re-click,
    -- RM hide via X, /reload, etc.).
    s:HookScript("OnHide", function()
        if settingsEater then settingsEater:Hide() end
    end)
end

local function WireBannerFrame()
    local b = ElitismEPGPRaidManagerBannerFrame
    if not b then return end

    -- Same SimpleMetal outline as the Raid Manager (same scale); the
    -- top-right corner uses the plain corner (bottom-right rotated 90° CCW)
    -- since the banner has no close button up there.
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(b, { plainTopRight = true })
    end

    -- Decorative top-cap filigree: horizontally centered on the modal, anchored
    -- by its BOTTOM-center to the modal's TOP-center then pushed down 10px so it
    -- overlaps the modal's top edge a bit and overhangs upward. Width 156; height
    -- derived from the atlas's native 176×74 so the artwork isn't squished. Lives
    -- on its own frame one level above the SimpleMetal borderFrame so it draws ON
    -- TOP of the metal outline trim. SetAtlas locks UVs on this client, so probe
    -- → SetTexture → SetTexCoord with explicit coords from the atlas registry
    -- ({w, h, leftU, rightU, topV, bottomV, flipX, flipY}).
    local bf = b.eepgpSimpleMetalBorder and b.eepgpSimpleMetalBorder.borderFrame
    if bf and not b.topFiligree then
        local capFrame = CreateFrame("Frame", nil, b)
        capFrame:SetAllPoints(b)
        capFrame:SetFrameLevel(bf:GetFrameLevel() + 1)
        local fil = capFrame:CreateTexture(nil, "OVERLAY")
        local FIL_W = 156
        fil:SetSize(FIL_W, FIL_W * 74 / 176)
        fil:SetPoint("BOTTOM", b, "TOP", 0, -10)
        if fil.SetAtlas then fil:SetAtlas("BossBanner-TopFillagree") end
        local file = fil:GetTexture()
        if file then
            fil:SetTexture(file)
            fil:SetTexCoord(0.244141, 0.587891, 0.576172, 0.720703)
        end
        b.topFiligreeFrame = capFrame
        b.topFiligree = fil
    end

    b.bannerAccept:SetScript("OnClick", function()
        if RaidManager._activeBoss then
            RaidManager:DoPreset("BOSS_KILL", addon.Awards:RaidPlusStandby(), "Killed: " .. RaidManager._activeBoss)
        end
        RaidManager:HideBanner()
    end)
    b.bannerDismiss:SetScript("OnClick", function() RaidManager:HideBanner() end)
end

local function WireCustomAwardFrame()
    local f = ElitismEPGPCustomAwardFrame
    if not f then return end
    -- Same chrome as the Raid Manager / side panels: SimpleMetal border,
    -- close-button corner pocket, filigree, bgOpacity-driven dark bg.
    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
        if UI.Skin.AddCloseFiligree then UI.Skin:AddCloseFiligree(f) end
    end
    f.btnEP:SetScript("OnClick",     function() RaidManager:ApplyCustom("ep") end)
    f.btnGP:SetScript("OnClick",     function() RaidManager:ApplyCustom("gp") end)
    f.btnCancel:SetScript("OnClick", function() f:Hide() end)
    f.amountEdit:SetScript("OnEnterPressed", function() f.btnEP:Click() end)
    f.noteEdit:SetScript("OnEnterPressed",   function() f.btnEP:Click() end)
    if UISpecialFrames then
        for _, name in ipairs(UISpecialFrames) do
            if name == "ElitismEPGPCustomAwardFrame" then return end
        end
        table.insert(UISpecialFrames, "ElitismEPGPCustomAwardFrame")
    end
end

-- Render an atlas slice as a horizontal row across the full panel width.
-- tileCount=1 stretches the slice once; higher values split the row into
-- N equal tiles so the same slice repeats as a pattern (each tile renders
-- panelWidth / tileCount px wide). Re-callable: clears prior tiles before
-- rebuilding. Parented to the main frame on the BORDER layer so it draws
-- above the dark Backdrop bg but below the metal border (which lives on
-- a child frame at level+10).
local function applyHeaderRow(f, y, height, tileCount)
    tileCount = tileCount or 1
    if f.headerRowTiles then
        for _, t in ipairs(f.headerRowTiles) do
            t:Hide(); t:SetTexture(nil); t:ClearAllPoints()
        end
    end
    local panelW = f:GetWidth()
    local tileW  = panelW / tileCount
    local tiles = {}
    for i = 1, tileCount do
        local tex = f:CreateTexture(nil, "BORDER")
        tex:SetSize(tileW, height)
        tex:SetPoint("TOPLEFT", f, "TOPLEFT", (i - 1) * tileW, y)
        if tex.SetAtlas then tex:SetAtlas("auctionhouse-ui-dropdown-middle") end
        tiles[#tiles + 1] = tex
    end
    f.headerRowTiles = tiles
end

function RaidManager:Init()
    if self.frame then return end
    local f = ElitismEPGPRaidManagerFrame
    if not f then return end
    self.frame = f

    if UI.Skin and UI.Skin.ApplySimpleMetalBorder then
        UI.Skin:ApplySimpleMetalBorder(f)
        -- Border frame sits at frame:GetFrameLevel()+10. Close button
        -- stays at the parent frame level so the corner pocket art
        -- draws OVER it (the X icon shows through the pocket's
        -- transparent center, giving the recessed-button look).
    end

    -- Top-row clock + elapsed time. Sits flush in the upper-left
    -- corner; the title slides down to make room when active (handled
    -- in RefreshActiveState). SetAtlas (Lua-only, not XML) handles the
    -- chromietime-32x32 texcoords reliably.
    if not f.clockIcon then
        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetSize(12, 12)
        icon:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -4)
        if icon.SetAtlas then icon:SetAtlas("chromietime-32x32") end
        icon:Hide()
        f.clockIcon = icon
    end
    if f.clockIcon and not f.elapsedText then
        local txt = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        txt:SetPoint("LEFT", f.clockIcon, "RIGHT", 2, 0)
        txt:SetTextColor(0.333, 1.0, 0.333)  -- green to match the bullet style
        txt:SetJustifyH("LEFT")
        txt:Hide()
        f.elapsedText = txt
    end

    -- Horizontal divider beneath the top row, spanning the full panel
    -- width. Uses the SimpleMetal top-edge atlas so the silver line
    -- matches the existing border art. Parented to the main frame on
    -- ARTWORK sublayer -1: above the dark Backdrop bg (BACKGROUND
    -- layer), below the title/subtitle FontStrings (ARTWORK sublayer
    -- 0), and below the metal border art (OVERLAY of the +10-level
    -- borderFrame), exactly the stack the user asked for.
    if not f.topDivider then
        local div = f:CreateTexture(nil, "ARTWORK", nil, -1)
        div:SetPoint("TOPLEFT",  f, "TOPLEFT",  0, -17)
        div:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, -17)
        div:SetHeight(60)
        if div.SetAtlas then div:SetAtlas("_UI-Frame-SimpleMetal-EdgeTop") end
        div:Hide()
        f.topDivider = div
    end

    -- Decorative filigree next to the close button. Always visible
    -- (both pre- and post-raid views). Source is 50×71; we render it
    -- rotated 90° CCW and horizontally flipped, then halved — so the
    -- rendered quad is 36×25 (rotated dims 71×50 ÷ 2 ≈ 36×25).
    -- Pinned to the FRAME's top-right corner (-20, +1) — NOT to the close
    -- button — because RefreshActiveState moves the close button between
    -- states (32×32 stock pre-raid vs 20×20 red-refresh active), which
    -- would otherwise drag the filigree along with it. (-20, +1) is the
    -- exact spot Skin:AddCloseFiligree lands on the other panels, where
    -- the close button never moves. Parented to the main frame on ARTWORK
    -- sublayer -1 so it draws above the bg texture but below the metal
    -- border outline (which lives on borderFrame). SetAtlas locks UVs, so
    -- we probe the file path and apply explicit 8-arg SetTexCoord.
    if f.closeButton and not f.closeFiligree then
        local fil = f:CreateTexture(nil, "ARTWORK", nil, -1)
        fil:SetSize(34, 23)
        fil:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, 1)
        if fil.SetAtlas then fil:SetAtlas("draft-filigree") end
        local file = fil:GetTexture()
        if file then
            fil:SetTexture(file)
            -- 90° CCW: UL←(R,T) LL←(L,T) UR←(R,B) LR←(L,B)
            -- Horizontal flip on top: UL↔UR, LL↔LR
            -- Combined: UL=(R,B) LL=(L,B) UR=(R,T) LR=(L,T)
            local L = 0.07373046875
            local R = 0.09814453125
            local T = 0.0849609375
            local B = 0.154296875
            fil:SetTexCoord(R, B, L, B, R, T, L, T)
        end
        f.closeFiligree = fil
    end

    -- Mode-picker opener: same spin-ring glow skin used by the main
    -- window's menuButton, anchored to the DBM/mode row instead of the
    -- corner. Icon swapped to mechagon-projects (cog/gear glyph). Frame
    -- level bumped above the metal border so the icon isn't clipped by
    -- the corner trim it overlaps with.
    if f.cogButton then
        local mb = f.cogButton
        if not mb.eepgpIcon then
            local glow = mb:CreateTexture(nil, "BACKGROUND")
            glow:SetPoint("CENTER", mb, "CENTER", 0, 0)
            glow:SetSize(mb:GetWidth() + 6, mb:GetHeight() + 6)
            if glow.SetAtlas then glow:SetAtlas("services-ring-large-glowspin") end
            glow:SetAlpha(0.5)
            glow:Hide()
            mb.eepgpGlow = glow

            local icon = mb:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("CENTER", mb, "CENTER")
            icon:SetSize(16, 16)
            if icon.SetAtlas then icon:SetAtlas("mechagon-projects") end
            mb.eepgpIcon = icon
        end
        mb:SetFrameLevel(f:GetFrameLevel() + 15)
        mb:SetScript("OnEnter", function(self) self.eepgpGlow:Show() end)
        mb:SetScript("OnLeave", function(self) self.eepgpGlow:Hide() end)
    end

    -- Header row using the auctionhouse dropdown-middle atlas, rendered
    -- on the metal border's child frame at OVERLAY sublayer 1 so it
    -- draws above the bg AND the border art. tileCount=1 stretches a
    -- single slice across the full panel width; raise it later to repeat
    -- the slice as a pattern (each tile renders panelW / tileCount wide).
    if not f.headerRowTiles then
        applyHeaderRow(f, -158, 34, 1)
    end

    self:RestorePos()
    self:HideBanner()

    -- Picker selection is transient: closing the panel before clicking
    -- Start Raid wipes the raid/difficulty pick so the next open starts
    -- from placeholders. Active sessions keep their values so end-of-raid
    -- awards still know what to pay out.
    f:HookScript("OnHide", function()
        if addon.RaidSession and addon.RaidSession:IsActive() then return end
        local p = addon.DB and addon.DB.profile
        if p then
            p.currentRaid       = nil
            p.currentDifficulty = nil
        end
    end)

    -- Skin the action row as circle icon buttons. Icon atlas is the same
    -- placeholder (ExperienceIconVeteran) on all three until the user
    -- specifies per-button glyphs; the bg/hover/selected states already
    -- give each button distinct visual feedback.
    if UI.Skin and UI.Skin.SkinCircleButton then
        UI.Skin:SkinCircleButton(f.btnAward, {
            iconAtlas = "ExperienceIconVeteran",
            iconSize = 40, iconOffsetY = 2,
            tooltipText = "Award",
        })
        UI.Skin:SkinCircleButton(f.raidInfoButton, {
            iconAtlas = { atlas = "ExperienceIconTmogEnabled",
                          L = 0, R = 0.21484375, T = 0.4296875, B = 0.64453125 },
            iconSize = 40, iconOffsetY = -1,
            tooltipText = "Players",
        })
        UI.Skin:SkinCircleButton(f.btnLogs, {
            iconAtlas = { atlas = "ExperienceIconFreepick",
                          L = 0.4296875, R = 0.64453125, T = 0.21484375, B = 0.4296875 },
            iconSize = 40, iconOffsetY = 2,
            tooltipText = "Log",
        })
    end

    f.btnAward:SetScript("OnClick",       function() ToggleAwardMenu() end)
    f.raidInfoButton:SetScript("OnClick", function() RaidManager:ToggleRaidInfo() end)
    f.btnLogs:SetScript("OnClick",        function() RaidManager:OpenLogs() end)

    if f.btnRaidPicker then
        if UI.Skin and UI.Skin.SkinDropdownButton then
            UI.Skin:SkinDropdownButton(f.btnRaidPicker, { overlayLeftInset = 5 })
            registerPicker(f.btnRaidPicker, function() return raidMenuFrame end)
        end
        f.btnRaidPicker:SetScript("OnClick", function(self) ToggleRaidPickerMenu(self) end)
    end
    if f.btnDifficultyPicker then
        if UI.Skin and UI.Skin.SkinDropdownButton then
            UI.Skin:SkinDropdownButton(f.btnDifficultyPicker, { overlayLeftInset = 5 })
            registerPicker(f.btnDifficultyPicker, function() return difMenuFrame end)
        end
        f.btnDifficultyPicker:SetScript("OnClick", function(self) ToggleDifficultyPickerMenu(self) end)
    end
    self:RefreshContextLabels()

    if UI.Skin and UI.Skin.SkinStartRaidButton then
        UI.Skin:SkinStartRaidButton(f.btnRaidSession)
    end
    f.btnRaidSession:SetScript("OnClick", function() RaidManager:OnRaidSessionClick() end)

    -- Tooltip explaining why Start Raid is unavailable in the auth-
    -- missing state. In 3.3.5a, disabled Buttons don't fire OnEnter/
    -- OnLeave, so a transparent mouse-enabled Frame overlay sits above
    -- the button when we want the tooltip. RefreshActiveState shows/
    -- hides this overlay alongside the disabledTip data.
    local hoverOverlay = CreateFrame("Frame", nil, f)
    hoverOverlay:SetAllPoints(f.btnRaidSession)
    hoverOverlay:SetFrameLevel(f.btnRaidSession:GetFrameLevel() + 1)
    hoverOverlay:EnableMouse(true)
    hoverOverlay:Hide()
    hoverOverlay:SetScript("OnEnter", function(self)
        local tip = f.btnRaidSession.eepgpDisabledTip
        if tip then
            -- Anchor BOTTOM→TOP so the tooltip is horizontally centered
            -- on the button and grows upward, keeping a 2 px gap. Width
            -- is whatever GameTooltip auto-sizes to (longer than the
            -- button is fine — it stays centered).
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("BOTTOM", self, "TOP", 0, 2)
            GameTooltip:SetText(tip.title, 1, 1, 1)
            GameTooltip:AddLine(tip.body, 1, 0.82, 0, true)
            GameTooltip:Show()
        end
    end)
    hoverOverlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.btnRaidSession.eepgpHoverOverlay = hoverOverlay

    if f.btnBidShow then
        -- Toggle the officer BidFrame: it's shown by default while a bid
        -- session is live, so this button hides it (label "Hide Bids") and
        -- brings it back (label "View Bids").
        f.btnBidShow:SetScript("OnClick", function() RaidManager:ToggleBidPanel() end)
    end

    -- Minimized-view hotspot: invisible Button that covers the whole
    -- collapsed bar. Click → opens the action menu (Award / Players /
    -- Log / Change Mode); hover → shows the highlight. Its frame level
    -- is pinned to the parent's so every real child (in particular the
    -- close button, which has its own action) sits above it and keeps
    -- input priority. Visibility is toggled by RefreshActiveState.
    if f.clockIcon and not f.minimizedHotspot then
        local hot = CreateFrame("Button", nil, f)
        hot:SetAllPoints(f)
        -- One level above the frame (so it receives the bar's clicks &
        -- hovers); the close button is raised higher still, below.
        hot:SetFrameLevel(f:GetFrameLevel() + 1)
        hot:EnableMouse(true)
        hot:Hide()
        -- Left-press drags the bar (mirroring the frame's own move
        -- handlers, which the hotspot would otherwise swallow); a press
        -- that didn't move opens the action menu. Right-click opens it
        -- straight away.
        hot:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                local x, y = GetCursorPosition()
                self.pressX, self.pressY = x, y
                f:StartMoving()
            end
        end)
        hot:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then
                f:StopMovingOrSizing()
                if RaidManager.SavePos then RaidManager:SavePos() end
                local x, y = GetCursorPosition()
                local moved = self.pressX and (math.abs((x or 0) - self.pressX) > 4
                                            or math.abs((y or 0) - self.pressY) > 4)
                if not moved then ToggleMinimizedMenu() end
            elseif button == "RightButton" then
                ToggleMinimizedMenu()
            end
        end)
        hot:SetScript("OnEnter", function()
            if f.minimizedHighlight then f.minimizedHighlight:Show() end
        end)
        hot:SetScript("OnLeave", function()
            if f.minimizedHighlight then f.minimizedHighlight:Hide() end
        end)
        f.minimizedHotspot = hot
    end

    -- Close button override. UIPanelCloseButton's default OnClick is
    -- HideParentPanel(self). We replace it so that:
    --   * Pre-raid → hide the frame (close, as expected).
    --   * Active (expanded)  → minimize to top-bar.
    --   * Active (minimized) → expand back to full active layout.
    -- The button stays the red X visual — once the raid ends and the
    -- session goes back to pre-raid, normal close behavior resumes.
    if f.closeButton then
        -- Stay above the minimized-bar hotspot so the X keeps its own
        -- click (expand/minimize) instead of being swallowed by it.
        f.closeButton:SetFrameLevel(f:GetFrameLevel() + 5)
        f.closeButton:SetScript("OnClick", function()
            if addon.RaidSession and addon.RaidSession:IsActive() then
                if RaidManager.minimized then
                    RaidManager:Expand()
                else
                    RaidManager:Minimize()
                end
            else
                f:Hide()
            end
        end)
    end

    f.cogButton:SetScript("OnClick", function() RaidManager:OpenSettings() end)

    -- Tooltip on the cog: shows the current detection mode (Manual /
    -- Suggest / Auto). RefreshModeLabel stashes the pretty name on
    -- self.eepgpModeText each time the mode changes, so the hover
    -- handler stays cheap. We always show the title; the mode line is
    -- skipped if DBM isn't detected (no meaningful mode value).
    f.cogButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT", 0, -2)
        GameTooltip:SetText("Boss-kill Detection", 1, 1, 1)
        if self.eepgpModeText then
            GameTooltip:AddLine(string.format("Mode: |cFFFFD200%s|r", self.eepgpModeText),
                1, 0.82, 0, true)
        end
        GameTooltip:AddLine("|cFFAAAAAAClick to change.|r", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    f.cogButton:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- Shrink the DBM/mode label one pt below GameFontDisableSmall so it
    -- reads as secondary info next to the divider artwork (and matches
    -- the reduced checkmark beside it). Same treatment for the mode
    -- option on the right so the two halves stay visually balanced.
    for _, fs in ipairs({ f.modeLabel, f.modeOption }) do
        if fs then
            local font, size, flags = fs:GetFont()
            if font and size then fs:SetFont(font, size - 1, flags) end
        end
    end

    -- Hover region grouping the disabled icon + the "DBM not detected"
    -- text. Tooltip explains why Suggest/Auto modes are unavailable
    -- without DBM. Mouse is enabled only when DBM is missing — when
    -- DBM is up, the green checkmark + "DBM" word need no explanation.
    if f.modeCheck and f.modeLabel and not f.modeStatusGroup then
        local g = CreateFrame("Frame", nil, f)
        g:SetPoint("TOPLEFT",     f.modeCheck, "TOPLEFT",     -2, 2)
        g:SetPoint("BOTTOMRIGHT", f.modeLabel, "BOTTOMRIGHT", 2, -2)
        g:EnableMouse(false)
        g:SetScript("OnEnter", function(self)
            -- Manual anchor so the tooltip's left edge lines up with the
            -- icon's left edge (instead of jumping to the side via the
            -- preset ANCHOR_RIGHT). Sits just below the group.
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -2)
            GameTooltip:SetText("Deadly Boss Mods not detected", 1, 1, 1)
            GameTooltip:AddLine(
                "Install and enable DBM to use the Suggest or Auto award modes on boss kills.",
                1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        g:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.modeStatusGroup = g
    end

    WireSettingsFrame()
    WireBannerFrame()
    WireCustomAwardFrame()
    self:RefreshModeLabel()
    self:RefreshSettingsRadios()
    self:RefreshActiveState()

    -- React to bid session lifecycle so the "View Active Bid" button
    -- appears/disappears live without needing the user to re-open RM.
    if addon.Loot and addon.Loot.Subscribe then
        addon.Loot:Subscribe(function(event)
            if event == "OPEN" or event == "AWARD" or event == "CANCEL" or event == "PASS" then
                RaidManager:RefreshActiveState()
            end
        end)
    end
end

function RaidManager:OnRaidSessionClick()
    if not addon.RaidSession then return end
    -- Awards-mode gating (replaces the old confirmRaidStartEnd toggle):
    --   manual  -> Start/End flip raidActive but skip auto-EP. The RL
    --              hands out On-Time / End-of-Raid via the preset
    --              buttons in the Raid Manager when they're ready.
    --   suggest -> show a confirmation modal pre-action; on accept,
    --              auto-award like the old "confirm = on" path.
    --   auto    -> Start/End fires immediately with EP, no prompt.
    local mode  = self:GetMode()
    local raid, dif = addon.RaidSession:GetContext()
    local count = (addon.Awards and addon.Awards.RaidPlusStandby)
        and #addon.Awards:RaidPlusStandby() or 0
    local plural = (count == 1) and "" or "s"

    if addon.RaidSession:IsActive() then
        if mode == "manual" then
            addon.RaidSession:End(false)
            return
        end
        if mode == "auto" then
            addon.RaidSession:End(true)
            return
        end
        local amount = (addon.Awards and addon.Awards.GetAmountForPreset)
            and addon.Awards:GetAmountForPreset("END_OF_RAID", raid, dif) or 10
        addon.Dialog:Confirm({
            title  = "End Raid",
            text   = string.format(
                "End the raid session and award |cFF55FF55+%d EP|r to %d player%s?",
                amount, count, plural),
            accept = "End",
            OnAccept = function() addon.RaidSession:End(true) end,
        })
    else
        if mode == "manual" then
            addon.RaidSession:Start(false)
            return
        end
        if mode == "auto" then
            addon.RaidSession:Start(true)
            return
        end
        local amount = (addon.Awards and addon.Awards.GetAmountForPreset)
            and addon.Awards:GetAmountForPreset("ON_TIME", raid, dif) or 10
        local raidName = raid
        for _, r in ipairs(addon.RAIDS or {}) do
            if r.key == raid then raidName = r.name; break end
        end
        addon.Dialog:Confirm({
            title  = "Start Raid",
            text   = string.format(
                "Start a %s (%s) raid session and award |cFF55FF55+%d EP|r on-time to %d player%s?",
                raidName or "?", dif or "?", amount, count, plural),
            accept = "Start",
            OnAccept = function() addon.RaidSession:Start(true) end,
        })
    end
end

-- Raid Manager only opens explicitly: minimap right-click and the
-- main window's officer dropdown ("Manage Raid"). No auto-open on
-- joining a raid or becoming raid leader.

function RaidManager:RegisterEvents()
    -- Intentionally empty. Kept as a stub so external callers don't break.
end

-- Lightweight per-tick update: only refreshes the elapsed-time text.
-- Deliberately does NOT call RefreshActiveState -- that re-runs the full
-- layout pass (SetPoint/Show/Hide on dozens of regions), which, fired
-- every second, was stealing mouse focus from the minimized-bar hotspot
-- and hiding the hover highlight mid-hover.
function RaidManager:UpdateElapsed()
    if self.frame and self.frame.elapsedText and addon.RaidSession and addon.RaidSession:IsActive() then
        self.frame.elapsedText:SetText(addon.RaidSession:ElapsedString() or "0:00")
    end
end

-- 1-second ticker so the elapsed time advances live while the panel is open.
-- Cheap: no-ops when the frame is hidden or no session is active.
local activeTicker = CreateFrame("Frame")
local tickAcc = 0
activeTicker:SetScript("OnUpdate", function(_, dt)
    tickAcc = tickAcc + dt
    if tickAcc < 1 then return end
    tickAcc = 0
    if not RaidManager.frame or not RaidManager.frame:IsShown() then return end
    if not (addon.RaidSession and addon.RaidSession:IsActive()) then return end
    RaidManager:UpdateElapsed()
end)

ElitismEPGP_RaidManager = RaidManager
