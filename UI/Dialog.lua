local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local Dialog = {}
addon.Dialog = Dialog
UI.Dialog     = Dialog

-- Singleton modal that mirrors ElitismEPGPCustomAwardFrame: SimpleMetal border,
-- close-button corner pocket, decorative filigree, anchored at the stock
-- confirmation-popup spot (StaticPopup1's TOP), draggable, ESC-closable. One
-- popup at a time — opening a new one replaces the visible one.
--
-- API (see the wrappers at the bottom):
--   Dialog:Confirm{title, text, accept, cancel, OnAccept, OnCancel}
--   Dialog:Prompt {title, text, default, letters, accept, cancel, OnAccept, OnCancel}
--   Dialog:Show   {title, text, input = nil|{default, letters},
--                  buttons = { {text, OnClick(inputText)}, ... up to 3 },
--                  OnCancel}
-- OnClick / OnAccept callbacks receive the trimmed input text when an input
-- field is configured (nil otherwise). The dialog hides itself before calling
-- the callback, so the callback can safely show another dialog.

local FRAME_W       = 360
local FRAME_MIN_H   = 140
local BODY_W        = 300
local BTN_W, BTN_H  = 90, 22
local BTN_PAD       = 12
local SIDE_PAD      = 18

local frame

local function build()
    if frame then return frame end

    local f = CreateFrame("Frame", "ElitismEPGPDialogFrame", UIParent)
    -- FULLSCREEN_DIALOG sits above the regular DIALOG strata used by the
    -- BidFrame / RaiderBid windows, so confirmation prompts always pop on top.
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetSize(FRAME_W, FRAME_MIN_H)
    f:Hide()

    f:SetBackdrop({
        bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })

    -- Same StaticPopup1-anchored position as CustomAwardFrame, with the same
    -- re-pin-on-show pattern so a drag doesn't stick a screen anchor on.
    f:SetPoint("TOP", StaticPopup1, "TOP", 0, 0)
    f:SetScript("OnShow", function(self)
        self:ClearAllPoints()
        if StaticPopup1 then
            self:SetPoint("TOP", StaticPopup1, "TOP", 0, 0)
        else
            self:SetPoint("TOP", UIParent, "TOP", 0, -135)
        end
    end)
    f:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self:StartMoving() end
    end)
    f:SetScript("OnMouseUp", function(self) self:StopMovingOrSizing() end)
    -- Fire OnCancel when the modal hides without an action button having
    -- claimed it (ESC, the X). Action-button OnClicks clear _onCancel first
    -- so they don't double-fire.
    f:SetScript("OnHide", function(self)
        local fn = self._onCancel
        self._onCancel = nil
        if fn then fn() end
    end)

    f.title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    f.title:SetPoint("TOP", f, "TOP", 0, -14)

    f.body = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    f.body:SetWidth(BODY_W)
    f.body:SetJustifyH("CENTER")
    f.body:SetJustifyV("TOP")
    f.body:SetPoint("TOP", f.title, "BOTTOM", 0, -10)

    f.input = CreateFrame("EditBox", nil, f)
    f.input:SetSize(BODY_W, 20)
    f.input:SetFontObject(ChatFontNormal)
    f.input:SetAutoFocus(false)
    f.input:SetTextInsets(6, 4, 0, 0)
    f.input:SetBackdrop({
        bgFile   = "Interface\\ChatFrame\\ChatFrameBackground",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    f.input:SetBackdropColor(0, 0, 0, 0.6)
    f.input:SetScript("OnEscapePressed", function() f:Hide() end)
    f.input:Hide()

    -- Up to 3 action buttons, configured + positioned per Show.
    f.buttons = {}
    for i = 1, 3 do
        local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
        b:SetSize(BTN_W, BTN_H)
        b:Hide()
        f.buttons[i] = b
    end

    -- Optional confirmation checkbox. When configured via opts.requireCheck,
    -- the primary action button starts disabled and only enables once this is
    -- ticked. Hidden by default.
    f.confirmCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    f.confirmCheck:SetSize(22, 22)
    f.confirmCheck:Hide()
    f.confirmCheckLabel = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    f.confirmCheckLabel:SetPoint("LEFT", f.confirmCheck, "RIGHT", 2, 1)
    f.confirmCheckLabel:Hide()

    local cb = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    cb:SetPoint("TOPRIGHT", f, "TOPRIGHT", 6, 5)
    cb:SetScript("OnClick", function() f:Hide() end)
    f.closeButton = cb

    if UI.Skin then
        if UI.Skin.ApplySimpleMetalBorder then UI.Skin:ApplySimpleMetalBorder(f) end
        if UI.Skin.AddCloseFiligree      then UI.Skin:AddCloseFiligree(f)      end
    end

    if UISpecialFrames then
        local already
        for _, n in ipairs(UISpecialFrames) do
            if n == "ElitismEPGPDialogFrame" then already = true; break end
        end
        if not already then table.insert(UISpecialFrames, "ElitismEPGPDialogFrame") end
    end

    frame = f
    return f
end

-- Anchor 1..n buttons along the frame's bottom edge. When alignRight is true
-- the buttons hug the right edge (leaving room on the left for the confirm
-- checkbox); otherwise they're centred.
local function layoutButtons(f, n, alignRight)
    if n <= 0 then return end
    if alignRight then
        local pad = BTN_PAD - 5
        for i = 1, n do
            local b = f.buttons[i]
            b:ClearAllPoints()
            b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT",
                       -(SIDE_PAD + (n - i) * (BTN_W + pad)), 14)
        end
    else
        local rowW = n * BTN_W + (n - 1) * BTN_PAD
        local x0   = -rowW / 2
        for i = 1, n do
            local b = f.buttons[i]
            b:ClearAllPoints()
            b:SetPoint("BOTTOMLEFT", f, "BOTTOM", x0 + (i - 1) * (BTN_W + BTN_PAD), 14)
        end
    end
end

local function trim(s) return (s and s:match("^%s*(.-)%s*$")) or "" end

function Dialog:Show(opts)
    opts = opts or {}
    local f = build()
    f:Hide()                 -- triggers OnHide -> any pending _onCancel fires
    f._onCancel = nil        -- clear so the OnHide above doesn't requeue it

    f.title:SetText(opts.title or "Confirm")
    f.body:SetJustifyH(opts.justify or "CENTER")
    f.body:SetText(opts.text or "")

    -- Input: { default, letters } table or nil/false.
    local inputCfg = opts.input
    if inputCfg then
        if type(inputCfg) ~= "table" then inputCfg = {} end
        f.input:Show()
        f.input:SetMaxLetters(inputCfg.letters or 100)
        f.input:SetText(inputCfg.default or "")
        f.input:ClearAllPoints()
        f.input:SetPoint("TOP", f.body, "BOTTOM", 0, -10)
        f.input:SetScript("OnEnterPressed", function()
            local b = f.buttons[1]
            if b and b:IsShown() and b:IsEnabled() then b:Click() end
        end)
    else
        f.input:Hide()
        f.input:SetText("")
        f.input:SetScript("OnEnterPressed", nil)
    end

    -- Confirmation checkbox sits on the same row as the action buttons —
    -- anchored to the bottom-left while the buttons hug the bottom-right.
    -- When set, the primary action button starts disabled and only re-enables
    -- once the box is ticked.
    local needCheck = opts.requireCheck
    if needCheck then
        f.confirmCheck:ClearAllPoints()
        f.confirmCheck:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", SIDE_PAD - 4, 14 + 2)
        f.confirmCheck:SetChecked(false)
        f.confirmCheck:Show()
        f.confirmCheckLabel:SetText(needCheck)
        f.confirmCheckLabel:Show()
    else
        f.confirmCheck:SetScript("OnClick", nil)
        f.confirmCheck:Hide()
        f.confirmCheckLabel:Hide()
    end

    local buttons = opts.buttons or { { text = "OK" } }
    local nBtn = math.min(#buttons, 3)
    for i = 1, 3 do
        local b = f.buttons[i]
        if i <= nBtn then
            local cfg = buttons[i]
            b:SetText(cfg.text or "OK")
            b:SetScript("OnClick", function()
                local text = inputCfg and trim(f.input:GetText()) or nil
                f._onCancel = nil    -- action claimed the close
                f:Hide()
                if cfg.OnClick then cfg.OnClick(text) end
            end)
            b:Show()
            if i == 1 and needCheck then b:Disable() else b:Enable() end
        else
            b:Hide()
            b:SetScript("OnClick", nil)
        end
    end
    layoutButtons(f, nBtn, needCheck and true or false)

    -- Wire the checkbox so toggling it flips the primary button's enabled
    -- state. Has to come AFTER the buttons are configured so f.buttons[1]
    -- exists with its new OnClick script.
    if needCheck then
        f.confirmCheck:SetScript("OnClick", function(self)
            if not f.buttons[1] then return end
            if self:GetChecked() then f.buttons[1]:Enable() else f.buttons[1]:Disable() end
        end)
    end

    -- Size to content. Title bar 28, body height (wrapped), optional input
    -- row 28, 14 px gap to footer, buttons row 36 (the confirmation checkbox
    -- shares this row), bottom padding 14.
    local bodyH = f.body:GetStringHeight() or 0
    local h = 28 + bodyH
        + (inputCfg and 28 or 0)
        + 14
        + 36 + 14
    f:SetHeight(math.max(FRAME_MIN_H, h))

    f._onCancel = opts.OnCancel
    f:Show()
    if inputCfg then f.input:SetFocus() end
end

function Dialog:Hide()
    if frame then frame:Hide() end
end

------------------------------------------------------------
-- Sugar wrappers
------------------------------------------------------------

-- Yes/no confirmation. opts: title, text, accept (button1 label, defaults
-- "OK"), cancel (button2 label, defaults "Cancel"; pass false to omit),
-- OnAccept, OnCancel, requireCheck (string label — when set, surfaces a
-- checkbox below the body and gates the Accept button on it being ticked).
function Dialog:Confirm(opts)
    local b = { { text = opts.accept or "OK", OnClick = opts.OnAccept } }
    if opts.cancel ~= false then
        b[#b + 1] = { text = opts.cancel or "Cancel", OnClick = opts.OnCancel }
    end
    self:Show({
        title        = opts.title,
        text         = opts.text,
        justify      = opts.justify,
        buttons      = b,
        OnCancel     = opts.OnCancel,
        requireCheck = opts.requireCheck,
    })
end

-- Single-input prompt. OnAccept receives the trimmed input text.
function Dialog:Prompt(opts)
    local b = { { text = opts.accept or "OK", OnClick = opts.OnAccept } }
    if opts.cancel ~= false then
        b[#b + 1] = { text = opts.cancel or "Cancel", OnClick = opts.OnCancel }
    end
    self:Show({
        title    = opts.title,
        text     = opts.text,
        input    = { default = opts.default, letters = opts.letters },
        buttons  = b,
        OnCancel = opts.OnCancel,
    })
end
