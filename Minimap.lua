local addonName, addon = ...

local Minimap = {}
addon.Minimap = Minimap

local LDB     = LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub("LibDBIcon-1.0", true)

local DATA_OBJECT_NAME = "ElitismEPGP"

local function MyEntryAndMain()
    local me = UnitName("player")
    local entry = addon.Roster and addon.Roster:Get(me)
    if not entry then return nil, me, nil end
    local resolved, mainName = addon.Roster:ResolveMain(me)
    return resolved or entry, me, (mainName ~= me) and mainName or nil
end

function Minimap:Init()
    if self.dataObject then return end
    if not LDB or not LDBIcon then
        addon.Print("|cFFFF6060Minimap libs unavailable; minimap button disabled.|r")
        return
    end

    local obj = LDB:NewDataObject(DATA_OBJECT_NAME, {
        type  = "launcher",
        text  = addon.ADDON_DISPLAY,
        icon  = "Interface\\AddOns\\" .. addon.ADDON_NAME .. "\\icon",
        OnClick        = function(self, button) Minimap:OnClick(button, self) end,
        OnTooltipShow  = function(tooltip)   Minimap:OnTooltipShow(tooltip) end,
    })
    self.dataObject = obj

    addon.DB.profile.minimap = addon.DB.profile.minimap or { hide = false }
    LDBIcon:Register(addonName, obj, addon.DB.profile.minimap)
end

-- Drop the officer dropdown next to the minimap. Mirrors what MainFrame's
-- cog button does, just anchored to the LibDBIcon button (LDB passes the
-- caller frame as the first arg to the OnClick callback). For non-officers
-- the right-click just opens Settings — same fallback as the cog button.
local minimapMenuFrame
local function openMinimapMenu(anchorFrame)
    if not addon.UI or not addon.UI.MainFrame then return end
    if not addon.UI.MainFrame.BuildOfficerMenuItems then return end
    if DropDownList1 and DropDownList1:IsShown() then
        CloseDropDownMenus()
        return
    end
    if not minimapMenuFrame then
        minimapMenuFrame = CreateFrame("Frame", "ElitismEPGPMinimapMenuFrame",
            UIParent, "UIDropDownMenuTemplate")
    end
    local items = addon.UI.MainFrame:BuildOfficerMenuItems()
    EasyMenu(items, minimapMenuFrame, anchorFrame or "cursor", 0, 0, "MENU")
end

function Minimap:OnClick(button, anchorFrame)
    if button == "LeftButton" then
        if addon.UI and addon.UI.MainFrame then
            addon.UI.MainFrame:Toggle()
        end
    elseif button == "RightButton" then
        -- Same routing the cog opener uses: officers get the dropdown,
        -- everyone else gets the Settings page.
        if addon.IsOfficer() then
            openMinimapMenu(anchorFrame)
        elseif addon.Options and addon.Options.Open then
            addon.Options:Open()
        end
    end
end

function Minimap:OnTooltipShow(tooltip)
    if not tooltip or not tooltip.AddLine then return end
    tooltip:AddLine(addon.ADDON_DISPLAY)

    local entry, me, mainName = MyEntryAndMain()
    if entry then
        local pr = addon.Roster:PR(entry.ep, entry.gp)
        local nameLine = mainName
            and string.format("%s |cFFAAAAAA(alt of %s)|r", me, mainName)
            or me
        tooltip:AddDoubleLine("Player", nameLine,                          1, 1, 1, 1, 1, 1)
        tooltip:AddDoubleLine("EP",     tostring(entry.ep or 0),           1, 1, 1, 0.6, 1, 0.6)
        tooltip:AddDoubleLine("GP",     tostring(entry.gp or 0),           1, 1, 1, 1, 0.8, 0.4)
        tooltip:AddDoubleLine("PR",     string.format("%.2f", pr),         1, 1, 1, 1, 1, 0.4)

        if addon.Roster.Sorted then
            local list = addon.Roster:Sorted("pr")
            local lookup = mainName or me
            for i = 1, #list do
                if list[i].name == lookup then
                    tooltip:AddDoubleLine("Rank", string.format("#%d of %d", i, #list),
                        1, 1, 1, 1, 1, 1)
                    break
                end
            end
        end
    else
        tooltip:AddLine("|cFFAAAAAANot in guild roster|r")
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cFFAAAAAALeft-click:|r toggle main window")
    if addon.IsOfficer() then
        tooltip:AddLine("|cFFAAAAAARight-click:|r officer menu")
    else
        tooltip:AddLine("|cFFAAAAAARight-click:|r open settings")
    end

    tooltip:AddLine(" ")
    tooltip:AddLine("|cFF888888v" .. (addon.VERSION or "?") .. "|r")
end

function Minimap:Toggle()
    if not addon.DB or not LDBIcon then return end
    addon.DB.profile.minimap = addon.DB.profile.minimap or { hide = false }
    addon.DB.profile.minimap.hide = not addon.DB.profile.minimap.hide
    if addon.DB.profile.minimap.hide then
        LDBIcon:Hide(addonName)
    else
        LDBIcon:Show(addonName)
    end
    return addon.DB.profile.minimap.hide
end

function Minimap:Show()
    if not addon.DB or not LDBIcon then return end
    addon.DB.profile.minimap = addon.DB.profile.minimap or { hide = false }
    addon.DB.profile.minimap.hide = false
    LDBIcon:Show(addonName)
end

function Minimap:Hide()
    if not addon.DB or not LDBIcon then return end
    addon.DB.profile.minimap = addon.DB.profile.minimap or { hide = false }
    addon.DB.profile.minimap.hide = true
    LDBIcon:Hide(addonName)
end

function Minimap:RefreshPosition()
    if not addon.DB or not LDBIcon then return end
    if LDBIcon.Refresh then LDBIcon:Refresh(addonName, addon.DB.profile.minimap) end
end
