local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local MainFrame = {}
UI.MainFrame = MainFrame

ElitismEPGP_MainFrame = MainFrame

local TABS = {
    { key = "standings", label = "Standings", visibleAlways = true,
      module = function() return UI.StandingsTab end },
    { key = "history",   label = "History",   visibleAlways = true,
      module = function() return UI.HistoryTab end },
    { key = "prices",    label = "Prices",    officersOnly = true,
      module = function() return UI.PricesTab end },
    -- Close "tab" — rightmost in the row. Doesn't switch view; clicking
    -- closes the main window. The dropdown / settings opener now lives at
    -- the top-right corner of the frame as a separate icon button.
    { key = "menu", isMenu = true,
      iconAtlases = {
          normal  = "128-redbutton-exit",
          pressed = "128-redbutton-exit-pressed",
          hover   = "128-redbutton-refresh-highlight",
      },
      visibleAlways = true, module = function() return nil end },
}

local function IsOfficer()
    return CanEditOfficerNote and CanEditOfficerNote()
end

local function TabIsVisible(tab)
    if tab.visibleAlways then return true end
    if tab.officersOnly then return IsOfficer() end
    return true
end

function MainFrame:Init()
    if self.frame then return end
    local frame = ElitismEPGPMainFrame
    if not frame then return end
    self.frame = frame

    if UI.Skin and UI.Skin.ApplyMetalBorder then
        UI.Skin:ApplyMetalBorder(frame)
    end

    -- Title banner: 3-piece stretched texture (left cap + tileable middle +
    -- right cap) wrapping the title FontString (which now carries only the
    -- dev indicator, or nothing in normal play). The middle is anchored
    -- CENTER-on-title so the whole banner follows the title text; caps
    -- extend out from the middle's ends and draw on top of it.
    if not frame.titleBanner and frame.title then
        local h    = 30                        -- compact height
        local capW = math.floor(h * 202 / 85)  -- preserve cap aspect ratio
        local midW = 60                        -- visible middle bar width

        local bgM = frame:CreateTexture(nil, "BACKGROUND")
        bgM:SetSize(midW, h)
        bgM:SetPoint("CENTER", frame.title, "CENTER", 0, 0)
        if bgM.SetAtlas then bgM:SetAtlas("_UI-Frame-Mechagon-TitleMiddle") end

        local bgL = frame:CreateTexture(nil, "BACKGROUND")
        bgL:SetSize(capW, h)
        bgL:SetPoint("CENTER", bgM, "LEFT", 0, 0)
        if bgL.SetAtlas then bgL:SetAtlas("UI-Frame-Mechagon-TitleLeft") end

        local bgR = frame:CreateTexture(nil, "BACKGROUND")
        bgR:SetSize(capW, h)
        bgR:SetPoint("CENTER", bgM, "RIGHT", 0, 0)
        if bgR.SetAtlas then bgR:SetAtlas("UI-Frame-Mechagon-TitleRight") end

        frame.titleBanner = { left = bgL, mid = bgM, right = bgR }
    end

    -- Dev-mode corner badge (store-corner-hot). Pinned to the TOP-RIGHT of
    -- the title-banner plate so it reads as a "stuck-on" corner ribbon on
    -- that little plate (and tracks it). ARTWORK sublayer -1 puts it below
    -- the title text (ARTWORK 0) but above the banner artwork (BACKGROUND).
    -- SetAtlas locks UVs, so we probe the file and re-apply the explicit
    -- texcoords from the registry entry. Visibility toggled by RefreshDevState.
    if not frame.devCorner and frame.titleBanner then
        local dc = frame:CreateTexture(nil, "ARTWORK", nil, -1)
        dc:SetSize(24 * 39 / 44, 24)   -- 39x44 source scaled to 24 tall, aspect kept
        dc:SetPoint("TOPRIGHT", frame.titleBanner.right, "TOPRIGHT", 0, 1)
        if dc.SetAtlas then dc:SetAtlas("store-corner-hot") end
        local file = dc:GetTexture()
        if file then
            dc:SetTexture(file)
            dc:SetTexCoord(0.32910156, 0.3671875, 0.64550781, 0.68847656)
        end
        dc:Hide()
        frame.devCorner = dc
    end

    -- Top-right menu icon (helpicon-stuck). Always visible across tabs.
    -- Officers: opens the dropdown of officer actions. Members: jumps
    -- straight to the settings panel. Frame level bumped above the metal
    -- border (which sits at frame level + 10) so the icon isn't obscured
    -- by the corner trim it overlaps.
    if frame.menuButton then
        local mb = frame.menuButton
        if not mb.eepgpIcon then
            -- Glow sits on BACKGROUND so it draws behind the icon (ARTWORK).
            -- Sized a few px larger than the button on each axis so the ring's
            -- soft outer falloff sticks past the button silhouette but stays
            -- subtle.
            local glow = mb:CreateTexture(nil, "BACKGROUND")
            glow:SetPoint("CENTER", mb, "CENTER", 0, 0)
            glow:SetSize(mb:GetWidth() + 6, mb:GetHeight() + 6)
            if glow.SetAtlas then glow:SetAtlas("services-ring-large-glowspin") end
            glow:Hide()
            mb.eepgpGlow = glow

            local icon = mb:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints(mb)
            if icon.SetAtlas then icon:SetAtlas("helpicon-stuck") end
            mb.eepgpIcon = icon
        end
        mb:SetFrameLevel(frame:GetFrameLevel() + 15)
        mb:SetScript("OnEnter", function(self) self.eepgpGlow:Show() end)
        mb:SetScript("OnLeave", function(self) self.eepgpGlow:Hide() end)
        mb:SetScript("OnClick", function()
            if IsOfficer() then
                MainFrame:ShowMenu(mb)
            elseif addon.Options and addon.Options.Open then
                addon.Options:Open()
            end
        end)
    end

    for _, tab in ipairs(TABS) do
        local mod = tab.module()
        if mod and mod.Init then mod:Init(frame.tabContent) end
    end

    -- Each tab's filter row sits ABOVE the tab frame top (in the gap below
    -- the tab buttons) and would otherwise be obscured by the metal border
    -- which renders at frame level + 10. Lift each tab frame above the
    -- border so its content — including the filter row at y=22 — draws on
    -- top. The tab BUTTONS stay at their default level (frame + 1) so they
    -- still slip under the border lip per the previous user request.
    local contentLevel = frame:GetFrameLevel() + 11
    for _, name in ipairs({ "ElitismEPGPStandingsTab", "ElitismEPGPHistoryTab", "ElitismEPGPPricesTab" }) do
        local f = _G[name]
        if f and f.SetFrameLevel then f:SetFrameLevel(contentLevel) end
    end

    -- Header BG bands live on a separate child frame whose level is BELOW
    -- the metal border (which sits at frame level + 10), so the metal trim
    -- renders ON TOP of the dark band where they overlap on the sides. The
    -- band itself oversizes by 14 px past the tab frame on each side so it
    -- runs flush into the metal's visible inner edge.
    local bgFrame = CreateFrame("Frame", nil, frame)
    bgFrame:SetAllPoints(frame)
    bgFrame:SetFrameLevel(frame:GetFrameLevel() + 5)
    self.bgFrame = bgFrame

    local function makeBG(tabFrame, yOffset, height)
        local t = bgFrame:CreateTexture(nil, "BACKGROUND")
        t:SetTexture(0, 0, 0, 0.4)
        t:SetPoint("TOPLEFT",     tabFrame, "TOPLEFT",     -14, yOffset)
        t:SetPoint("BOTTOMRIGHT", tabFrame, "TOPRIGHT",     14, yOffset - height)
        t:Hide()
        return t
    end

    self.headerBGs = {}
    if ElitismEPGPStandingsTab then self.headerBGs.standings = makeBG(ElitismEPGPStandingsTab, 0,    22) end
    if ElitismEPGPHistoryTab   then self.headerBGs.history   = makeBG(ElitismEPGPHistoryTab,   0,    22) end
    if ElitismEPGPPricesTab    then self.headerBGs.prices    = makeBG(ElitismEPGPPricesTab,    0,    22) end

    for _, tab in ipairs(TABS) do
        local btn = frame["tab_" .. tab.key]
        if btn then
            if tab.isMenu then
                -- Icon-only tab styled as a standalone close-button (no
                -- metal tab background underneath). The atlases ARE the
                -- whole button; SkinIconButton handles state swaps.
                btn:SetText("")
                btn:SetScript("OnClick", function() MainFrame:Hide() end)
                if UI.Skin and UI.Skin.SkinIconButton then
                    UI.Skin:SkinIconButton(btn, tab.iconAtlases)
                end
            else
                btn:SetText(tab.label)
                btn:SetScript("OnClick", function() MainFrame:SelectTab(tab.key) end)
                if UI.Skin and UI.Skin.SkinTabButton then
                    UI.Skin:SkinTabButton(btn)
                end
            end
        end
    end

    self:LayoutTabs()
    self:RefreshDevState()
    self:SelectTab("standings")
end

function MainFrame:LayoutTabs()
    -- Right-aligned tab row: the rightmost visible tab anchors to the
    -- frame's top-right (with space reserved for the inline title), and
    -- earlier tabs chain leftward with their right edge butted against
    -- the previous tab's left edge. Adding more tabs grows the row to
    -- the left rather than to the right.
    local prev
    for i = #TABS, 1, -1 do
        local tab = TABS[i]
        local btn = self.frame["tab_" .. tab.key]
        if btn then
            if TabIsVisible(tab) then
                btn:Show()
                btn:ClearAllPoints()
                if prev then
                    btn:SetPoint("RIGHT", prev, "LEFT", 0, 0)
                else
                    -- Rightmost tab anchors past the frame's right edge so
                    -- the row sits clear of the metal corner trim. Pushed
                    -- down (y=4) so the active tab's lower edge overlaps
                    -- the border's top highlight, hiding the trim behind
                    -- the active tab's dark backplate.
                    btn:SetPoint("BOTTOMRIGHT", self.frame, "TOPRIGHT", 4, 3)
                end
                prev = btn
            else
                btn:Hide()
            end
        end
    end
end

function MainFrame:SelectTab(key)
    self.activeTab = key
    if self.headerBGs then
        for k, t in pairs(self.headerBGs) do
            if k == key then t:Show() else t:Hide() end
        end
    end
    -- Border lives at frame level + 10; lift the active tab above it so it
    -- sits ON TOP of the metal trim, while inactive tabs stay at default
    -- (level + 1) and continue to slip behind the border lip.
    local baseLevel   = self.frame:GetFrameLevel()
    local activeLevel = baseLevel + 12

    for _, tab in ipairs(TABS) do
        if not tab.isMenu then
            local btn = self.frame["tab_" .. tab.key]
            local mod = tab.module()
            local active = (tab.key == key)
            if btn then
                if UI.Skin and UI.Skin.SetTabActive and btn.eepgpTab then
                    UI.Skin:SetTabActive(btn, active)
                elseif active then
                    btn:SetButtonState("PUSHED", true)
                else
                    btn:SetButtonState("NORMAL", false)
                end
                btn:SetFrameLevel(active and activeLevel or (baseLevel + 1))
            end
            if mod and mod.frame then
                if active then mod.frame:Show() else mod.frame:Hide() end
            end
        end
    end
    -- Clear the status row before delegating to the tab's refresh. Each
    -- tab that wants its own info there (Standings, History) sets it via
    -- SetStatus during refresh; Prices doesn't, so it lands on a blank.
    self:SetStatus("")
    if key == "standings" and UI.StandingsTab and UI.StandingsTab.Reload then
        UI.StandingsTab:Reload()
    elseif key == "history" and UI.HistoryTab and UI.HistoryTab.Refresh then
        UI.HistoryTab:Refresh()
    elseif key == "prices" and UI.PricesTab and UI.PricesTab.Refresh then
        UI.PricesTab:Refresh()
    end
end

-- Dropdown shown when the menu icon button is clicked. Hosts officer-only
-- shortcuts that used to live in the standings tab footer (Weekly
-- Maintenance, Manage Raid). Uses EasyMenu for the same look as the
-- standard right-click menu on minimap addon buttons.
--
-- Click-eater: a fullscreen invisible Button at FULLSCREEN strata, sitting
-- BELOW DropDownList1 (FULLSCREEN_DIALOG). While the dropdown is open the
-- eater catches every click that misses the menu items and closes the
-- dropdown — including clicks on the opener button itself, so re-clicking
-- the opener while the menu is open dismisses it.
local menuFrame
local clickEater
local function ensureClickEater()
    if clickEater then return clickEater end
    clickEater = CreateFrame("Button", "ElitismEPGPMenuClickEater", UIParent)
    clickEater:SetAllPoints(UIParent)
    -- Whole addon lives on MEDIUM so it doesn't interleave with bag /
    -- vendor frames at HIGH. The eater sits at frame level 30 within
    -- MEDIUM — above the main frame's content (level ~16) but below
    -- any popups that should remain interactive.
    clickEater:SetFrameStrata("MEDIUM")
    clickEater:SetFrameLevel(30)
    clickEater:RegisterForClicks("AnyUp")
    clickEater:Hide()
    clickEater:SetScript("OnClick", function() CloseDropDownMenus() end)
    return clickEater
end

-- Officer-menu items factory. Pulled out so the minimap-button right-click
-- can surface the exact same dropdown without duplicating the entries.
function MainFrame:BuildOfficerMenuItems()
    return {
        { text = "Officer Actions", isTitle = true, notCheckable = true },
        { text = "Weekly Maintenance", notCheckable = true,
          func = function()
              if UI.StandingsTab and UI.StandingsTab.OpenWeeklyMaintenanceDialog then
                  UI.StandingsTab:OpenWeeklyMaintenanceDialog()
              end
          end },
        { text = "Manage Raid", notCheckable = true,
          func = function()
              if UI.RaidManager and UI.RaidManager.Toggle then
                  UI.RaidManager:Toggle()
              end
          end },
        { text = "Backup & Restore...", notCheckable = true,
          func = function()
              if UI.BackupFrame and UI.BackupFrame.Open then
                  UI.BackupFrame:Open()
              end
          end },
        { text = "Open Settings", notCheckable = true,
          func = function()
              if addon.Options and addon.Options.Open then
                  addon.Options:Open()
              end
          end },
    }
end

function MainFrame:ShowMenu(anchorBtn)
    -- Toggle: re-clicking the opener (when the eater isn't intercepting)
    -- still closes the dropdown.
    if DropDownList1 and DropDownList1:IsShown() then
        CloseDropDownMenus()
        return
    end
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "ElitismEPGPTabMenuFrame", UIParent, "UIDropDownMenuTemplate")
    end
    EasyMenu(self:BuildOfficerMenuItems(), menuFrame, anchorBtn or "cursor", 0, 0, "MENU")
    -- EasyMenu anchors the dropdown TOPLEFT→BOTTOMLEFT of the button.
    -- Override to right-align (TOPRIGHT→BOTTOMRIGHT) so the menu grows
    -- leftward and stays inside the frame when the icon-tab is at the
    -- far-right of the row.
    if anchorBtn and DropDownList1 and DropDownList1:IsShown() then
        DropDownList1:ClearAllPoints()
        DropDownList1:SetPoint("TOPRIGHT", anchorBtn, "BOTTOMRIGHT", 0, 0)
    end

    local eater = ensureClickEater()
    eater:Show()
    if DropDownList1 and not DropDownList1.eepgpEaterHooked then
        DropDownList1:HookScript("OnHide", function()
            if clickEater then clickEater:Hide() end
        end)
        DropDownList1.eepgpEaterHooked = true
    end
end

-- Open a "side popup" (a secondary window that visually extends the main
-- view from one side, e.g. History detail panel, Add-override form). The
-- popup is anchored on the OPPOSITE side from where the main window sits
-- on the screen, and any other registered side popup is dismissed first
-- so only one is ever visible at a time.
function MainFrame:OpenSidePopup(popup)
    if not popup or not self.frame then return end

    self.sidePopups = self.sidePopups or {}
    -- Hide any other side popup that's currently open.
    for _, other in ipairs(self.sidePopups) do
        if other ~= popup and other.IsShown and other:IsShown() then
            other:Hide()
        end
    end
    -- Register this popup so future calls know to close it.
    local known = false
    for _, p in ipairs(self.sidePopups) do
        if p == popup then known = true; break end
    end
    if not known then self.sidePopups[#self.sidePopups + 1] = popup end

    -- Pick which side the popup opens on based on where the main window
    -- sits — keep the popup on whichever half of the screen has more room.
    local cx = self.frame:GetCenter()
    local screenW = UIParent and UIParent:GetWidth() or 0
    local mainOnRightHalf = cx and screenW > 0 and (cx > screenW / 2)

    -- One-shot: re-skin the popup's stock UIPanelCloseButton with the
    -- red exit atlas so it matches the tab-row close button.
    if popup.closeButton and UI.Skin and UI.Skin.SkinIconButton
       and not popup.closeButton.eepgpIconSkinned then
        UI.Skin:SkinIconButton(popup.closeButton, {
            normal  = "128-button-exit",
            pressed = "128-button-exit-pressed",
            hover   = "128-button-refresh-highlight",
        })
    end

    popup:ClearAllPoints()
    if mainOnRightHalf then
        -- Main is on the right half → popup goes on the LEFT, attaching
        -- via its RIGHT edge (so the right side stays seamless).
        popup:SetPoint("TOPRIGHT", self.frame, "TOPLEFT", 0, 0)
        if UI.Skin and UI.Skin.ApplySidePopupBorder then
            UI.Skin:ApplySidePopupBorder(popup, "right")
        end
    else
        -- Main is on the left half → popup goes on the RIGHT, attaching
        -- via its LEFT edge (left side stays seamless).
        popup:SetPoint("TOPLEFT", self.frame, "TOPRIGHT", 0, 0)
        if UI.Skin and UI.Skin.ApplySidePopupBorder then
            UI.Skin:ApplySidePopupBorder(popup, "left")
        end
    end

    popup:Show()
end

-- `owner` (optional) is the tab key that wants to update the row. When set,
-- the write is dropped unless that tab is the active one — keeps Standings'
-- async refresh from clobbering the status row while another tab is showing.
function MainFrame:SetStatus(text, owner)
    if owner and owner ~= self.activeTab then return end
    if self.frame and self.frame.status then
        self.frame.status:SetText(text or "")
    end
end

function MainFrame:RefreshDevState()
    if not self.frame or not self.frame.title then return end
    -- Three label states, all centered on the same fixed banner anchor:
    --   * normal play          → yellow "ElitismEPGP" logo
    --   * dev on, no mock raid → blue "DEV"
    --   * dev + mock raid      → blue "[DEV mock: N]"
    local active = addon.Dev and addon.Dev:IsActive()
    local title
    if active then
        local n = #addon.Dev:GetMockRaid()
        if n > 0 then
            title = string.format("|cFF55AAFF[DEV mock: %d]|r", n)
        else
            title = "|cFF55AAFFDEV|r"
        end
    else
        title = "|cFFFFD200ElitismEPGP|r"
    end
    self.frame.title:SetText(title)
    if self.frame.devCorner then
        if active then self.frame.devCorner:Show() else self.frame.devCorner:Hide() end
    end
end

function MainFrame:Toggle()
    if not self.frame then self:Init() end
    if not self.frame then return end
    if self.frame:IsShown() then self.frame:Hide() else self.frame:Show() end
end

function MainFrame:Show()
    if not self.frame then self:Init() end
    if self.frame then self.frame:Show() end
end

function MainFrame:Hide()
    if self.frame then self.frame:Hide() end
end

function MainFrame:SetSort(key)
    if UI.StandingsTab and UI.StandingsTab.SetSort then UI.StandingsTab:SetSort(key) end
end

function MainFrame:Reload()
    if not self.frame then self:Init() end
    if not self.frame then return end
    self:LayoutTabs()
    if self.activeTab == "history" then
        if UI.HistoryTab and UI.HistoryTab.Refresh then UI.HistoryTab:Refresh() end
    else
        if UI.StandingsTab and UI.StandingsTab.Reload then UI.StandingsTab:Reload() end
    end
end

function MainFrame:Refresh()
    if self.activeTab == "history" then
        if UI.HistoryTab and UI.HistoryTab.Refresh then UI.HistoryTab:Refresh() end
    else
        if UI.StandingsTab and UI.StandingsTab.Refresh then UI.StandingsTab:Refresh() end
    end
end
