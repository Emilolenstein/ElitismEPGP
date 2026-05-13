local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local BackupFrame = {}
UI.BackupFrame = BackupFrame

------------------------------------------------------------
-- Officer-facing backup window.
--
-- Three vertically-stacked sections, each anchored absolutely to the
-- frame so the layout doesn't cascade when text wraps or fields resize:
--
--   1. Backup       — current snapshot rendered as a single-line blob
--                     the officer can copy off-site (Discord, gist, .txt).
--   2. Recent saves — auto-snapshots written by destructive ops + a
--                     manual save button; each row has its own Restore.
--   3. External     — paste a blob, pick which sections to apply.
--
-- The dialog matches the addon's other modals (SimpleMetal chrome,
-- FULLSCREEN_DIALOG strata, close-corner-pocket).
------------------------------------------------------------

local FRAME_W, FRAME_H = 540, 540
local PAD              = 18

-- Vertical layout constants — explicit so a tweak to one row doesn't
-- domino-shift everything below it.
local Y_TITLE         = -14
local Y_HEADER_EXPORT = -44
local Y_EXPORT_EDIT   = -64
local Y_EXPORT_META   = -90
local Y_EXPORT_TIP    = -106
local Y_EXPORT_BTN    = -126
local Y_DIVIDER_1     = -156

local Y_HEADER_LIST   = -168
local Y_LIST_FIRST    = -190
local LIST_ROW_H      = 22
local LIST_GAP        = 2
local LIST_ROWS       = 5
local Y_LIST_LAST     = Y_LIST_FIRST - (LIST_ROWS - 1) * (LIST_ROW_H + LIST_GAP)

local Y_DIVIDER_2     = Y_LIST_LAST - 28

local Y_HEADER_IMPORT = Y_DIVIDER_2 - 12
local Y_IMPORT_EDIT   = Y_HEADER_IMPORT - 20
local Y_IMPORT_PREV   = Y_IMPORT_EDIT - 26
local Y_SCOPE_ROW     = Y_IMPORT_PREV - 22
-- Restore button shares the checkbox row vertically; horizontal layout
-- below keeps the labels left and the button anchored to the right edge.
local Y_IMPORT_BTN    = Y_SCOPE_ROW

local frame
local function fmtTime(ts)
    if not ts then return "—" end
    return date("%Y-%m-%d %H:%M", ts)
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function makeEditBox(parent, w, h)
    local eb = CreateFrame("EditBox", nil, parent)
    eb:SetSize(w, h)
    eb:SetFontObject(ChatFontNormal)
    eb:SetAutoFocus(false)
    eb:SetTextInsets(6, 6, 0, 0)
    eb:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    eb:SetBackdropColor(0, 0, 0, 0.6)
    eb:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
    eb:SetScript("OnEscapePressed",   function(self) self:ClearFocus()    end)
    return eb
end

local function makeDivider(parent, y)
    local div = parent:CreateTexture(nil, "ARTWORK")
    div:SetHeight(8)
    div:SetPoint("LEFT",  parent, "TOPLEFT",  PAD, y)
    div:SetPoint("RIGHT", parent, "TOPRIGHT", -PAD, y)
    if div.SetAtlas then div:SetAtlas("_UI-Frame-SimpleMetal-EdgeTop") end
    return div
end

------------------------------------------------------------
-- Frame build
------------------------------------------------------------

local function buildFrame()
    if frame then return frame end

    local f = CreateFrame("Frame", "ElitismEPGPBackupFrame", UIParent)
    f:SetSize(FRAME_W, FRAME_H)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:Hide()
    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    f:SetScript("OnMouseDown", function(self, b) if b == "LeftButton" then self:StartMoving() end end)
    f:SetScript("OnMouseUp",   function(self) self:StopMovingOrSizing() end)

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, Y_TITLE)
    f.title:SetText("Backup & Restore")

    local cb = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", 6, 5)
    cb:SetSize(32, 32)
    cb:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = cb

    if UI.Skin then
        if UI.Skin.ApplySimpleMetalBorder then UI.Skin:ApplySimpleMetalBorder(f) end
        if UI.Skin.AddCloseFiligree      then UI.Skin:AddCloseFiligree(f)      end
    end

    if UISpecialFrames then
        local already
        for _, n in ipairs(UISpecialFrames) do
            if n == "ElitismEPGPBackupFrame" then already = true; break end
        end
        if not already then table.insert(UISpecialFrames, "ElitismEPGPBackupFrame") end
    end

    local innerW = FRAME_W - 2 * PAD

    ------------------------------------------------------------
    -- Section 1: Backup (export)
    ------------------------------------------------------------
    f.exportHeader = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.exportHeader:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_HEADER_EXPORT)
    f.exportHeader:SetText("|cFFFFD200Backup|r")

    f.exportEdit = makeEditBox(f, innerW, 22)
    f.exportEdit:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_EXPORT_EDIT)

    f.exportMeta = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    f.exportMeta:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_EXPORT_META)
    f.exportMeta:SetWidth(innerW)
    f.exportMeta:SetJustifyH("LEFT")

    f.exportTip = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.exportTip:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_EXPORT_TIP)
    f.exportTip:SetWidth(innerW)
    f.exportTip:SetJustifyH("LEFT")
    f.exportTip:SetText("|cFFAAAAAAClick the field, then Ctrl+A · Ctrl+C to copy the blob into the clipboard.|r")

    f.btnCopy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.btnCopy:SetSize(120, 22)
    f.btnCopy:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_EXPORT_BTN)
    f.btnCopy:SetText("Copy backup")
    f.btnCopy:SetScript("OnClick", function() BackupFrame:DoSnapshot() end)

    f.btnSaveSlot = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.btnSaveSlot:SetSize(140, 22)
    f.btnSaveSlot:SetPoint("TOPLEFT", f.btnCopy, "TOPRIGHT", 8, 0)
    f.btnSaveSlot:SetText("Save to slot below")
    f.btnSaveSlot:SetScript("OnClick", function() BackupFrame:DoManualSave() end)

    makeDivider(f, Y_DIVIDER_1)

    ------------------------------------------------------------
    -- Section 2: Recent backups (auto-snapshots + manual saves)
    ------------------------------------------------------------
    f.listHeader = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.listHeader:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_HEADER_LIST)
    f.listHeader:SetWidth(innerW)
    f.listHeader:SetJustifyH("LEFT")
    f.listHeader:SetText("|cFFFFD200Recent backups|r |cFFAAAAAA(auto-saved before risky ops; keeps last 5)|r")

    f.autoRows = {}
    for i = 1, LIST_ROWS do
        local row = CreateFrame("Frame", nil, f)
        row:SetSize(innerW, LIST_ROW_H)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD,
            Y_LIST_FIRST - (i - 1) * (LIST_ROW_H + LIST_GAP))

        -- Row background — subtle striping helps when many rows are listed.
        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints(row)
        if i % 2 == 0 then row.bg:SetTexture(1, 1, 1, 0.04)
        else               row.bg:SetTexture(1, 1, 1, 0)     end

        row.text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT",  row, "LEFT",  6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -140, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)

        row.loadBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.loadBtn:SetSize(60, 18)
        row.loadBtn:SetPoint("RIGHT", row, "RIGHT", -68, 0)
        row.loadBtn:SetText("Restore")

        row.delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.delBtn:SetSize(60, 18)
        row.delBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.delBtn:SetText("Delete")

        f.autoRows[i] = row
    end

    f.autoEmpty = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    f.autoEmpty:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_LIST_FIRST - 4)
    f.autoEmpty:SetText("|cFFAAAAAANo backups yet — click \"Save to slot below\" or run a destructive op to create one.|r")

    makeDivider(f, Y_DIVIDER_2)

    ------------------------------------------------------------
    -- Section 3: Restore from external blob
    ------------------------------------------------------------
    f.importHeader = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    f.importHeader:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_HEADER_IMPORT)
    f.importHeader:SetWidth(innerW)
    f.importHeader:SetJustifyH("LEFT")
    f.importHeader:SetText("|cFFFFD200Restore from external blob|r")

    f.importEdit = makeEditBox(f, innerW, 22)
    f.importEdit:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_IMPORT_EDIT)
    f.importEdit:SetScript("OnTextChanged", function() BackupFrame:RefreshPreview() end)

    f.importPreview = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.importPreview:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, Y_IMPORT_PREV)
    f.importPreview:SetWidth(innerW)
    f.importPreview:SetJustifyH("LEFT")

    -- Scope checkboxes — single horizontal row, left side; Restore button on
    -- the right end of the same row so the relationship is obvious.
    local function makeScope(parent, key, label, anchorX, y)
        local cbx = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
        cbx:SetSize(22, 22)
        cbx:SetPoint("TOPLEFT", parent, "TOPLEFT", anchorX, y)
        cbx:SetChecked(true)
        local lbl = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        lbl:SetPoint("LEFT", cbx, "RIGHT", 2, 1)
        lbl:SetText(label)
        cbx._scopeKey = key
        return cbx
    end
    f.scopeSettings = makeScope(f, "settings", "Settings + Prices", PAD,        Y_SCOPE_ROW)
    f.scopeHistory  = makeScope(f, "history",  "History",           PAD + 140,  Y_SCOPE_ROW)
    f.scopeRoster   = makeScope(f, "roster",   "Roster EP:GP",      PAD + 240,  Y_SCOPE_ROW)

    f.btnRestore = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.btnRestore:SetSize(110, 22)
    f.btnRestore:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, Y_IMPORT_BTN)
    f.btnRestore:SetText("Restore...")
    f.btnRestore:SetScript("OnClick", function() BackupFrame:DoRestore(BackupFrame._stagedSnap) end)
    f.btnRestore:Disable()

    frame = f
    return f
end

------------------------------------------------------------
-- Operations
------------------------------------------------------------

-- Populate the export field with a freshly-built snapshot blob and select
-- it so the user can immediately Ctrl+C. Doesn't write to disk — it's just
-- the in-memory render.
function BackupFrame:DoSnapshot()
    if not addon.Backup or not frame then return end
    local snap = addon.Backup:BuildSnapshot("Manual export")
    local blob = addon.Backup:Encode(snap)
    if not blob then
        if addon.Print then addon.Print("|cFFFF6060Backup failed to encode.|r") end
        return
    end
    frame.exportEdit:SetText(blob)
    frame.exportEdit:HighlightText()
    frame.exportEdit:SetFocus()
    local nS, nP, nH, nR = addon.Backup:Counts(snap)
    frame.exportMeta:SetText(string.format(
        "%s — %d settings · %d prices · %d history · %d roster",
        fmtTime(snap.ts), nS, nP, nH, nR))
end

-- Push the current state into the auto-snapshot ring buffer with a
-- "Manual save" label so it shows up in the Recent backups list.
function BackupFrame:DoManualSave()
    if not addon.Backup or not addon.Backup.RecordAuto then return end
    addon.Backup:RecordAuto("Manual save")
    self:RefreshAutoList()
    if addon.Print then addon.Print("Saved snapshot to Recent backups.") end
end

function BackupFrame:RefreshPreview()
    if not frame or not addon.Backup then return end
    local blob = frame.importEdit:GetText() or ""
    if blob:match("^%s*$") then
        frame.importPreview:SetText("|cFFAAAAAAPaste a snapshot blob to preview.|r")
        frame.btnRestore:Disable()
        self._stagedSnap = nil
        return
    end
    local snap, err = addon.Backup:Decode(blob)
    if not snap then
        frame.importPreview:SetText("|cFFFF6060" .. tostring(err) .. "|r")
        frame.btnRestore:Disable()
        self._stagedSnap = nil
        return
    end
    local nS, nP, nH, nR = addon.Backup:Counts(snap)
    local labelTxt = (snap.label and snap.label ~= "") and (" · " .. snap.label) or ""
    frame.importPreview:SetText(string.format(
        "|cFF55FF55Valid|r snapshot from %s%s · %d settings · %d prices · %d history · %d roster",
        fmtTime(snap.ts), labelTxt, nS, nP, nH, nR))
    frame.btnRestore:Enable()
    self._stagedSnap = snap
end

-- Confirm + apply a staged snapshot. `snap` is decoded already; scope is
-- read from the dialog's checkboxes. Used both by the bottom Restore...
-- button and the per-row Restore buttons on auto-snapshots.
function BackupFrame:DoRestore(snap)
    if not addon.Backup or not snap then return end
    local scope = {
        settings = frame.scopeSettings:GetChecked() and true or false,
        history  = frame.scopeHistory:GetChecked()  and true or false,
        roster   = frame.scopeRoster:GetChecked()   and true or false,
    }
    if not (scope.settings or scope.history or scope.roster) then
        if addon.Print then addon.Print("|cFFFFCC00Pick at least one section to restore.|r") end
        return
    end

    local parts = {}
    if scope.settings then parts[#parts + 1] = "Settings + Prices" end
    if scope.history  then parts[#parts + 1] = "History" end
    if scope.roster   then parts[#parts + 1] = "Roster EP:GP (re-writes officer notes)" end

    addon.Dialog:Confirm({
        title  = "Confirm Restore",
        text   = string.format(
            "Restore from snapshot %s%s?\n\nThis will overwrite the current data for:\n • %s",
            fmtTime(snap.ts),
            (snap.label and snap.label ~= "") and (" (" .. snap.label .. ")") or "",
            table.concat(parts, "\n • ")),
        accept = "Restore",
        cancel = "Cancel",
        requireCheck = "Yes, overwrite the selected sections.",
        OnAccept = function()
            -- Snapshot the current state first so the restore is itself undoable.
            if addon.Backup.RecordAuto then addon.Backup:RecordAuto("Before restore") end
            local ok, info = addon.Backup:Apply(snap, scope)
            if not ok then
                if addon.Print then addon.Print("|cFFFF6060Restore failed:|r " .. tostring(info)) end
                return
            end
            if addon.Print then
                addon.Print(string.format("Restore complete — %d settings, %d history, %d roster.",
                    info.settings, info.history, info.roster))
            end
            if addon.UI and addon.UI.MainFrame and addon.UI.MainFrame.Refresh then
                addon.UI.MainFrame:Refresh()
            end
            BackupFrame:RefreshAutoList()
        end,
    })
end

function BackupFrame:RefreshAutoList()
    if not frame then return end
    local list = (addon.Backup and addon.Backup:GetAutoSnapshots()) or {}
    if #list == 0 then
        frame.autoEmpty:Show()
        for i = 1, #frame.autoRows do frame.autoRows[i]:Hide() end
        return
    end
    frame.autoEmpty:Hide()
    for i, row in ipairs(frame.autoRows) do
        local entry = list[i]
        if entry then
            row.text:SetText(string.format("|cFFFFD200%s|r   %s",
                fmtTime(entry.ts), entry.label or "Snapshot"))
            row.loadBtn:SetScript("OnClick", function()
                local snap = addon.Backup:Decode(entry.blob or "")
                if not snap then
                    if addon.Print then addon.Print("|cFFFF6060Stored snapshot is corrupt.|r") end
                    return
                end
                BackupFrame:DoRestore(snap)
            end)
            row.delBtn:SetScript("OnClick", function()
                addon.Backup:DeleteAutoSnapshot(i)
                BackupFrame:RefreshAutoList()
            end)
            row:Show()
        else
            row:Hide()
        end
    end
end

------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------

function BackupFrame:Open()
    if not addon.IsOfficer or not addon.IsOfficer() then
        if addon.Print then addon.Print("|cFFFF6060Backup tools are officer-only.|r") end
        return
    end
    local f = buildFrame()
    self:DoSnapshot()           -- pre-fill the Backup field
    frame.importEdit:SetText("")
    self:RefreshPreview()
    self:RefreshAutoList()
    f:Show()
end

function BackupFrame:Close()
    if frame then frame:Hide() end
end
