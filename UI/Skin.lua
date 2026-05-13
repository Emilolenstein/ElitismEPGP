local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local Skin = {}
UI.Skin = Skin

-- ---------------------------------------------------------------------------
-- 9-slice metal border using Ascension's GenericMetal2 atlas pieces. Applied
-- as overlay textures on top of the frame; the existing Backdrop is replaced
-- with a bgFile-only variant (no edge, no insets) so the dark interior fills
-- right under the metal border with no light gap.
--
-- Atlas registry data, for reference (note the leading-symbol prefixes are
-- part of the actual atlas keys — Ascension uses _ for horizontal edges
-- and ! for vertical edges):
--   _GenericMetal2-NineSlice-EdgeTop          1024x128
--   _GenericMetal2-NineSlice-EdgeBottom       1024x128
--   !GenericMetal2-NineSlice-EdgeLeft          128x1024
--   !GenericMetal2-NineSlice-EdgeRight         128x1024
--   GenericMetal2-NineSlice-CornerTopLeft      128x128
--   GenericMetal2-NineSlice-CornerTopRight     128x128
--   GenericMetal2-NineSlice-CornerBottomLeft   128x128
--   GenericMetal2-NineSlice-CornerBottomRight  128x128
-- ---------------------------------------------------------------------------

local DEFAULT_THICKNESS = 36

-- How far the metal corners extend OUTSIDE the frame's outer rect.
-- A small overhang covers the bg's outer corners (so they don't peek
-- past the metal) while the bulk of the texture stays on the frame's
-- hit area. SetHitRectInsets below stretches the drag region to match.
local OUTSIDE_EXTENSION = 14

local ATLAS = {
    cornerTL  = "GenericMetal2-NineSlice-CornerTopLeft",
    cornerTR  = "GenericMetal2-NineSlice-CornerTopRight",
    cornerBL  = "GenericMetal2-NineSlice-CornerBottomLeft",
    cornerBR  = "GenericMetal2-NineSlice-CornerBottomRight",
    edgeTop   = "_GenericMetal2-NineSlice-EdgeTop",
    edgeBot   = "_GenericMetal2-NineSlice-EdgeBottom",
    edgeLeft  = "!GenericMetal2-NineSlice-EdgeLeft",
    edgeRight = "!GenericMetal2-NineSlice-EdgeRight",
}

local function applyAtlas(tex, name)
    if not tex.SetAtlas then return false end
    tex:SetAtlas(name)
    return true
end

-- Track every frame we've skinned so we can re-apply opacity in bulk
-- when the user drags the Display slider.
local skinned = {}

local function readOpacity()
    local pct = addon.DB and addon.DB.profile and addon.DB.profile.bgOpacity
    if type(pct) ~= "number" then pct = 89 end
    if pct < 0   then pct = 0   end
    if pct > 100 then pct = 100 end
    return pct / 100
end

local function applyOpacity(frame)
    if not frame.SetBackdropColor then return end
    -- White tint preserves the bgFile's natural color; only alpha varies.
    frame:SetBackdropColor(1, 1, 1, readOpacity())
end

function Skin:RefreshOpacity()
    for f in pairs(skinned) do
        applyOpacity(f)
    end
end

-- ---------------------------------------------------------------------------
-- Tab button skin: 3-piece (left cap / tileable middle / right cap) for both
-- normal and pressed states, plus a single hover overlay. Source atlases are
-- designed for tabs sitting BELOW a view; we flip 180° so they read as tabs
-- ABOVE the main window. SetAtlas locks UVs, so we probe the texture file
-- once and apply raw SetTexture + flipped SetTexCoord.
-- ---------------------------------------------------------------------------

local TAB_ATLAS = {
    leftN  = { atlas = "wow-tab-left",            L = 0.03125,  R = 0.5,      T = 0.294921875, B = 0.353515625 },
    midN   = { atlas = "_wow-tab-center",         L = 0,        R = 1,        T = 0.35546875,  B = 0.4140625   },
    rightN = { atlas = "wow-tab-right",           L = 0.5,      R = 0.96875,  T = 0.294921875, B = 0.353515625 },
    leftP  = { atlas = "wow-tab-left-pressed",    L = 0.03125,  R = 0.5,      T = 0.537109375, B = 0.595703125 },
    midP   = { atlas = "_wow-tab-center-pressed", L = 0,        R = 1,        T = 0.59765625,  B = 0.65625     },
    rightP = { atlas = "wow-tab-right-pressed",   L = 0.5,      R = 0.96875,  T = 0.537109375, B = 0.595703125 },
    -- Active (selected) tab. Source art is 30x37 / 64x37 — 7 px taller than
    -- the resting/pressed pieces — so we render it proportionally taller
    -- and anchor to the button's bottom so it grows upward.
    leftA  = { atlas = "wow-tab-left-checked",    L = 0.03125,  R = 0.5,      T = 0.146484375, B = 0.21875     },
    midA   = { atlas = "_wow-tab-center-checked", L = 0,        R = 1,        T = 0.220703125, B = 0.29296875  },
    rightA = { atlas = "wow-tab-right-checked",   L = 0.5,      R = 0.96875,  T = 0.146484375, B = 0.21875     },
    hover  = { atlas = "wow-tab-highlight",       L = 0.046875, R = 0.953125, T = 0.6640625,   B = 0.6796875   },
}

local atlasFileCache = {}
local function probeAtlasFile(parent, atlasName)
    if atlasFileCache[atlasName] ~= nil then return atlasFileCache[atlasName] or nil end
    local probe = parent:CreateTexture(nil, "BACKGROUND")
    probe:Hide()
    if not probe.SetAtlas then
        atlasFileCache[atlasName] = false
        return nil
    end
    probe:SetAtlas(atlasName)
    atlasFileCache[atlasName] = probe:GetTexture() or false
    return atlasFileCache[atlasName] or nil
end

-- Probe an atlas to its underlying file then paint a slice with raw UVs.
-- Hoisted up here (next to probeAtlasFile) so every skinning function below
-- can reference it; locals are resolved lexically at parse time, so a
-- function defined further down would fall through to a nil global.
local function applyFlatSlice(tex, parent, slice)
    local file = probeAtlasFile(parent, slice.atlas)
    if not file then return false end
    tex:SetTexture(file)
    tex:SetTexCoord(slice.L, slice.R, slice.T, slice.B)
    return true
end

-- Public wrapper: paint an atlas slice ({ atlas, L, R, T, B }) onto a texture
-- using the probe-file + raw-UV path. Resets vertex colour to white so a
-- prior tint doesn't darken the art. Returns true if the atlas resolved.
function Skin:PaintAtlasSlice(tex, slice)
    if not tex or not slice then return false end
    if tex.SetVertexColor then tex:SetVertexColor(1, 1, 1, 1) end
    return applyFlatSlice(tex, tex:GetParent() or UIParent, slice)
end

-- Decorate a search EditBox: leading magnifying-glass icon and a trailing
-- clear button that appears only while the field has text. Text insets are
-- adjusted so typing never overlaps either icon. The consumer's own
-- OnTextChanged handler is preserved — this hooks on top via HookScript, so
-- call this AFTER any SetScript("OnTextChanged", ...) the consumer needs.
function Skin:DecorateSearchBox(eb)
    if not eb or eb.eepgpSearchDecorated then return end
    eb.eepgpSearchDecorated = true

    -- Leading magnifying glass — 12x12, 6 px in from the box's left edge.
    local mag = eb:CreateTexture(nil, "ARTWORK")
    mag:SetSize(12, 12)
    mag:SetPoint("LEFT", eb, "LEFT", 6, 0)
    self:PaintAtlasSlice(mag, {
        atlas = "common-search-magnifyingglass",
        L = 0.0742188, R = 0.167969, T = 0.335938, B = 0.523438,
    })
    eb.eepgpSearchIcon = mag

    -- Trailing clear button — 10x10, 4 px in from the right edge. Hidden
    -- until the EditBox has text; clicking wipes the field and drops focus.
    local clr = CreateFrame("Button", nil, eb)
    clr:SetSize(10, 10)
    clr:SetPoint("RIGHT", eb, "RIGHT", -4, 0)
    clr:Hide()

    local clrTex = clr:CreateTexture(nil, "ARTWORK")
    clrTex:SetAllPoints(clr)
    self:PaintAtlasSlice(clrTex, {
        atlas = "common-search-clearbutton",
        L = 0.0742188, R = 0.152344, T = 0.539062, B = 0.695312,
    })
    clr:SetScript("OnEnter", function() clrTex:SetVertexColor(1, 0.9, 0.4, 1) end)
    clr:SetScript("OnLeave", function() clrTex:SetVertexColor(1, 1, 1, 1) end)
    clr:SetScript("OnClick", function()
        eb:SetText("")
        eb:ClearFocus()
    end)
    eb.eepgpSearchClear = clr

    -- Reserve room for both icons:
    --   left  = 6 (icon left padding) + 12 (icon w) + 4 (gap) = 22
    --   right = 4 (icon right padding) + 10 (icon w) + 4 (gap) = 18
    eb:SetTextInsets(22, 18, 0, 0)

    local function refreshClear(self)
        local txt = self:GetText() or ""
        if txt == "" then clr:Hide() else clr:Show() end
    end
    eb:HookScript("OnTextChanged", refreshClear)
    refreshClear(eb)
end

local function applyTabSlice(tex, parent, slice)
    local file = probeAtlasFile(parent, slice.atlas)
    if not file then return false end
    tex:SetTexture(file)
    -- Vertical flip only (T↔B). The atlases are drawn for tabs BELOW a
    -- view; flipping T↔B reorients them for ABOVE-the-view use while
    -- preserving the LEFT cap on the left and RIGHT cap on the right.
    -- A full 180° rotation would also swap L↔R, putting each cap's curve
    -- on the wrong side.
    tex:SetTexCoord(slice.L, slice.R, slice.B, slice.T)
    return true
end

function Skin:SkinTabButton(btn, opts)
    if not btn or btn.eepgpTabSkinned then return end
    btn.eepgpTabSkinned = true
    opts = opts or {}

    local h = btn:GetHeight()
    if not h or h == 0 then h = 22 end
    local capW             = opts.capW             or h    -- square caps proportional to height
    local hoverInsetX      = opts.hoverInsetX      or 3    -- horizontal inset (off the curved cap edges)
    local hoverInsetTop    = opts.hoverInsetTop    or 8    -- vertical inset from the top
    local hoverInsetBottom = opts.hoverInsetBottom or 4    -- vertical inset from the bottom (smaller — hover extends down)
    -- All tabs render at the button's full height. The active art is
    -- 37 px tall natively (vs 30 for resting/pressed); the resting/pressed
    -- pieces stretch slightly to match. We don't scale the active tab
    -- larger than the others — same height across all states.
    local activeH    = h

    -- UIPanelButtonTemplate ships gold Normal/Pushed/Highlight/Disabled
    -- textures. Empty strings clear them so they don't show through.
    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")
    btn:SetHighlightTexture("")

    local function makeTex(layer) return btn:CreateTexture(nil, layer or "BORDER") end

    -- Layer plan (bottom → top):
    --   BORDER   — tab background pieces (normal + pressed slices)
    --   ARTWORK  — hover overlay (sits above bg, below text)
    --   OVERLAY  — button label FontString (set below)
    --   HIGHLIGHT layer is left empty so nothing draws above the text.

    -- Normal-state pieces (visible by default).
    local nL = makeTex(); nL:SetSize(capW, h); nL:SetPoint("LEFT",  btn, "LEFT")
    applyTabSlice(nL, btn, TAB_ATLAS.leftN)
    local nR = makeTex(); nR:SetSize(capW, h); nR:SetPoint("RIGHT", btn, "RIGHT")
    applyTabSlice(nR, btn, TAB_ATLAS.rightN)
    local nC = makeTex(); nC:SetHeight(h)
    nC:SetPoint("LEFT",  nL, "RIGHT")
    nC:SetPoint("RIGHT", nR, "LEFT")
    applyTabSlice(nC, btn, TAB_ATLAS.midN)

    -- Pressed-state pieces (briefly visible while held during a click).
    local pL = makeTex(); pL:SetSize(capW, h); pL:SetPoint("LEFT",  btn, "LEFT");  pL:Hide()
    applyTabSlice(pL, btn, TAB_ATLAS.leftP)
    local pR = makeTex(); pR:SetSize(capW, h); pR:SetPoint("RIGHT", btn, "RIGHT"); pR:Hide()
    applyTabSlice(pR, btn, TAB_ATLAS.rightP)
    local pC = makeTex(); pC:SetHeight(h); pC:Hide()
    pC:SetPoint("LEFT",  pL, "RIGHT")
    pC:SetPoint("RIGHT", pR, "LEFT")
    applyTabSlice(pC, btn, TAB_ATLAS.midP)

    -- Active-state pieces. Anchored BOTTOM so the taller (37px source)
    -- art grows UPWARD past the button's top, giving the selected tab
    -- a visual "pop" while keeping its bottom edge on the border line.
    local aL = makeTex(); aL:SetSize(capW, activeH)
    aL:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT");  aL:Hide()
    applyTabSlice(aL, btn, TAB_ATLAS.leftA)
    local aR = makeTex(); aR:SetSize(capW, activeH)
    aR:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT"); aR:Hide()
    applyTabSlice(aR, btn, TAB_ATLAS.rightA)
    local aC = makeTex()
    aC:SetPoint("TOPLEFT",     aL, "TOPRIGHT")
    aC:SetPoint("BOTTOMRIGHT", aR, "BOTTOMLEFT")
    aC:Hide()
    applyTabSlice(aC, btn, TAB_ATLAS.midA)

    -- Hover overlay above bg, below text. Inset so the button outline
    -- stays un-tinted (per the user's note).
    local hover = makeTex("ARTWORK")
    hover:SetPoint("TOPLEFT",     btn, "TOPLEFT",      hoverInsetX, -hoverInsetTop)
    hover:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -hoverInsetX,  hoverInsetBottom)
    hover:Hide()
    applyTabSlice(hover, btn, TAB_ATLAS.hover)

    -- Lift the button label above ARTWORK so it draws over the atlas.
    -- Inactive tabs sit at level+1 (under the metal border) so the
    -- BOTTOM of their art gets clipped by the trim — the text needs to
    -- ride higher to stay visually centered in the un-clipped portion.
    -- Active tabs (level+12, above the border) use the lower offset so
    -- the text centers within the metal frame's natural inked area.
    local fs = btn.GetFontString and btn:GetFontString()
    if fs then
        fs:SetDrawLayer("OVERLAY")
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", btn, "CENTER", 0, 1)
    end

    btn.eepgpTab = {
        normal  = { L = nL, M = nC, R = nR },
        pressed = { L = pL, M = pC, R = pR },
        active  = { L = aL, M = aC, R = aR },
        hover   = hover,
    }

    -- Visual state arbitration: pressed (transient) > active > normal.
    -- Called by OnMouseDown/Up/Leave and by SetTabActive.
    local function applyVisual()
        nL:Hide(); nC:Hide(); nR:Hide()
        pL:Hide(); pC:Hide(); pR:Hide()
        aL:Hide(); aC:Hide(); aR:Hide()
        if btn.eepgpPressed then
            pL:Show(); pC:Show(); pR:Show()
        elseif btn.eepgpActive then
            aL:Show(); aC:Show(); aR:Show()
        else
            nL:Show(); nC:Show(); nR:Show()
        end
    end
    btn.eepgpApplyVisual = applyVisual

    -- Pressed pieces appear only while the mouse is held down on the
    -- button (matches Blizzard's native button feel). OnLeave reverts in
    -- case the user drags off without releasing.
    local oldDown = btn:GetScript("OnMouseDown")
    btn:SetScript("OnMouseDown", function(self, ...)
        self.eepgpPressed = true
        applyVisual()
        if oldDown then oldDown(self, ...) end
    end)
    local oldUp = btn:GetScript("OnMouseUp")
    btn:SetScript("OnMouseUp", function(self, ...)
        self.eepgpPressed = false
        applyVisual()
        if oldUp then oldUp(self, ...) end
    end)

    -- Hover suppressed when the tab is active (the active state itself
    -- already gives strong visual feedback; an extra glow is noise).
    local oldEnter = btn:GetScript("OnEnter")
    btn:SetScript("OnEnter", function(self, ...)
        if not self.eepgpActive then hover:Show() end
        if oldEnter then oldEnter(self, ...) end
    end)
    local oldLeave = btn:GetScript("OnLeave")
    btn:SetScript("OnLeave", function(self, ...)
        hover:Hide()
        self.eepgpPressed = false  -- revert mid-drag-off
        applyVisual()
        if oldLeave then oldLeave(self, ...) end
    end)
end

-- Toggle the active state on a skinned tab. Active = swap to the taller
-- "checked" atlas, recolor label white, suppress hover. Inactive = back
-- to the resting texture with default (yellow) label color.
function Skin:SetTabActive(btn, active)
    if not btn or not btn.eepgpTab then return end
    btn.eepgpActive = active and true or false
    if btn.eepgpApplyVisual then btn.eepgpApplyVisual() end
    if btn.eepgpActive and btn.eepgpTab.hover then
        btn.eepgpTab.hover:Hide()
    end
    local fs = btn.GetFontString and btn:GetFontString()
    if fs then
        fs:ClearAllPoints()
        fs:SetPoint("CENTER", btn, "CENTER", 0, btn.eepgpActive and -2 or 1)
        if btn.eepgpActive then
            fs:SetTextColor(1, 1, 1)  -- white for selected tab
        elseif NORMAL_FONT_COLOR then
            fs:SetTextColor(NORMAL_FONT_COLOR.r, NORMAL_FONT_COLOR.g, NORMAL_FONT_COLOR.b)
        else
            fs:SetTextColor(1, 0.82, 0)  -- Blizzard yellow fallback
        end
    end
end

-- ---------------------------------------------------------------------------
-- Icon button skin: replaces a button's entire visual with three atlas
-- textures (normal / pressed / highlight). Used for the rightmost "menu"
-- tab, which is styled as a red close-X but actually opens the dropdown
-- (officers) or the settings panel (members) — see MainFrame:ShowMenu /
-- the OnClick wiring there.
-- ---------------------------------------------------------------------------
function Skin:SkinIconButton(btn, atlases)
    if not btn or btn.eepgpIconSkinned then return end
    btn.eepgpIconSkinned = true
    atlases = atlases or {}

    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")
    btn:SetHighlightTexture("")

    local function makeTex(layer)
        local t = btn:CreateTexture(nil, layer or "ARTWORK")
        t:SetAllPoints(btn)
        return t
    end

    local normal = makeTex("ARTWORK")
    if atlases.normal and normal.SetAtlas then normal:SetAtlas(atlases.normal) end

    local pressed = makeTex("ARTWORK")
    if atlases.pressed and pressed.SetAtlas then pressed:SetAtlas(atlases.pressed) end
    pressed:Hide()

    -- Hover overlay sits ABOVE the bg sprite (HIGHLIGHT layer), unlike the
    -- tab skin where hover is below the text. Here there is no text, so
    -- the highlight glow can render fullscreen on top. 50% alpha so the
    -- glow reads as a soft tint over the underlying close-X, not a wash.
    local hover = makeTex("HIGHLIGHT")
    if atlases.hover and hover.SetAtlas then hover:SetAtlas(atlases.hover) end
    hover:SetAlpha(0.5)
    hover:Hide()

    btn.eepgpIcon = { normal = normal, pressed = pressed, hover = hover }

    local oldDown = btn:GetScript("OnMouseDown")
    btn:SetScript("OnMouseDown", function(self, ...)
        normal:Hide(); pressed:Show()
        if oldDown then oldDown(self, ...) end
    end)
    local oldUp = btn:GetScript("OnMouseUp")
    btn:SetScript("OnMouseUp", function(self, ...)
        pressed:Hide(); normal:Show()
        if oldUp then oldUp(self, ...) end
    end)
    local oldEnter = btn:GetScript("OnEnter")
    btn:SetScript("OnEnter", function(self, ...)
        hover:Show()
        if oldEnter then oldEnter(self, ...) end
    end)
    local oldLeave = btn:GetScript("OnLeave")
    btn:SetScript("OnLeave", function(self, ...)
        hover:Hide()
        pressed:Hide(); normal:Show()
        if oldLeave then oldLeave(self, ...) end
    end)
end

-- ---------------------------------------------------------------------------
-- Circle action button skin: stack of round atlas slices used for the
-- Award / Players / Logs row. Layers (bottom → top):
--
--   BORDER   bg circle (always visible)
--   ARTWORK  icon glyph centered in the circle
--   OVERLAY  hover ring (mouseover only, suppressed while selected)
--   OVERLAY  selected ring (toggled by btn.eepgpSetCircleSelected)
--
-- The bg / hover / selected slices come from a single 4-cell sheet so we
-- probe the file path once and apply explicit UVs instead of trusting
-- SetAtlas. Caller passes opts.iconAtlas (atlas name or a {atlas, L, R, T, B}
-- slice table) + an optional opts.iconScale (defaults to 0.55, fraction of
-- the button size).
-- ---------------------------------------------------------------------------

local CIRCLE_BTN = {
    bg       = { atlas = "draft-ring",
                 L = 0.0048828125, R = 0.0439453125, T = 0.0869140625, B = 0.1650390625 },
    hover    = { atlas = "ExperienceIconHighlight",
                 L = 0.64453125, R = 0.859375,   T = 0.4296875,  B = 0.64453125 },
    selected = { atlas = "ExperienceIconChecked",
                 L = 0.4296875,  R = 0.64453125, T = 0.4296875,  B = 0.64453125 },
}

function Skin:SkinCircleButton(btn, opts)
    if not btn or btn.eepgpCircleSkinned then return end
    btn.eepgpCircleSkinned = true
    opts = opts or {}

    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")
    btn:SetHighlightTexture("")

    local function makeTex(layer) return btn:CreateTexture(nil, layer or "BORDER") end

    -- BG / hover / selected paint at a fixed 48×48 centered on the
    -- button, independent of the button's hit-area size. Caller can
    -- pass opts.bgSize to override (e.g. 32 for a denser row).
    local bgSize = opts.bgSize or 48

    -- Shrink the button's hit rect to match the visible bg footprint
    -- so OnEnter / OnLeave (and clicks) only fire when the cursor is
    -- actually over the painted 48×48 circle. Without this the empty
    -- corners of the 56×56 button quad would still trigger hover.
    local btnW = btn:GetWidth()  or bgSize
    local btnH = btn:GetHeight() or bgSize
    if btn.SetHitRectInsets and btnW > bgSize and btnH > bgSize then
        local dx = (btnW - bgSize) / 2
        local dy = (btnH - bgSize) / 2
        btn:SetHitRectInsets(dx, dx, dy, dy)
    end

    local bg = makeTex("BORDER")
    bg:SetSize(bgSize, bgSize)
    bg:SetPoint("CENTER", btn, "CENTER")
    applyFlatSlice(bg, btn, CIRCLE_BTN.bg)

    -- Centered icon. Explicit opts.iconSize wins; otherwise we fall
    -- back to opts.iconScale (fraction of the button's footprint,
    -- default 0.55). Lets callers either pin a pixel size directly or
    -- have the icon track the button's size.
    local iconW, iconH
    if opts.iconSize then
        iconW, iconH = opts.iconSize, opts.iconSize
    else
        local iconScale = opts.iconScale or 0.55
        local w = btn:GetWidth()  or 32
        local h = btn:GetHeight() or 32
        iconW, iconH = w * iconScale, h * iconScale
    end
    -- opts.iconOffsetX / iconOffsetY shift the icon away from dead
    -- center; default 0 keeps it centered on the button. Positive y is
    -- up in WoW's coord space.
    local icon = makeTex("ARTWORK")
    icon:SetSize(iconW, iconH)
    icon:SetPoint("CENTER", btn, "CENTER", opts.iconOffsetX or 0, opts.iconOffsetY or 0)
    if opts.iconAtlas then
        local sl = opts.iconAtlas
        if type(sl) == "table" then
            applyFlatSlice(icon, btn, sl)
        elseif type(sl) == "string" and icon.SetAtlas then
            icon:SetAtlas(sl)
        end
    end

    -- Hover ring sits BELOW the icon (BORDER sublayer 1, above the bg
    -- on BORDER sublayer 0) so the icon glyph reads cleanly on top
    -- when the cursor enters. 50% alpha so it tints rather than washes
    -- out the bg circle.
    local hover = btn:CreateTexture(nil, "BORDER", nil, 1)
    hover:SetSize(bgSize, bgSize)
    hover:SetPoint("CENTER", btn, "CENTER")
    hover:SetAlpha(0.5)
    hover:Hide()
    applyFlatSlice(hover, btn, CIRCLE_BTN.hover)

    -- Selected ring stays on OVERLAY (above the icon) so the active
    -- state remains visually dominant.
    local selected = makeTex("OVERLAY")
    selected:SetSize(bgSize, bgSize)
    selected:SetPoint("CENTER", btn, "CENTER")
    selected:Hide()
    applyFlatSlice(selected, btn, CIRCLE_BTN.selected)

    btn.eepgpCircle = { bg = bg, icon = icon, hover = hover, selected = selected }

    -- opts.tooltipText, when set, surfaces a centered GameTooltip
    -- BELOW the button on hover (e.g. "Award", "Players", "Log").
    -- We anchor manually (ANCHOR_NONE) so the tip's TOP centers on the
    -- button's BOTTOM rather than offsetting to the right like the
    -- default anchors. The Hide on OnLeave is unconditional so the tip
    -- never lingers if the button gets disabled mid-hover.
    btn:HookScript("OnEnter", function(self)
        if not self.eepgpCircleSelected and self:GetButtonState() ~= "DISABLED" then
            hover:Show()
        end
        if opts.tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_NONE")
            GameTooltip:ClearAllPoints()
            GameTooltip:SetPoint("BOTTOM", self, "TOP", 0, -2)
            GameTooltip:SetText(opts.tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    btn:HookScript("OnLeave", function()
        hover:Hide()
        if opts.tooltipText then GameTooltip:Hide() end
    end)

    -- Caller flips this when the button represents the currently-open panel
    -- (Award menu visible, Players panel visible, Logs visible). Selected
    -- ring takes precedence over hover.
    btn.eepgpSetCircleSelected = function(sel)
        btn.eepgpCircleSelected = sel and true or false
        if sel then
            selected:Show(); hover:Hide()
        else
            selected:Hide()
        end
    end

    -- Disabled = dim the whole stack via SetAlpha. We don't have a
    -- dedicated disabled atlas, so 40% mirrors the Start-Raid button's
    -- auth-missing state for visual consistency.
    local origEnable = btn.Enable
    btn.Enable = function(self, ...)
        origEnable(self, ...)
        self:SetAlpha(1.0)
    end
    local origDisable = btn.Disable
    btn.Disable = function(self, ...)
        origDisable(self, ...)
        self:SetAlpha(0.4)
        hover:Hide()
    end
end

-- Replace the original Backdrop with a bgFile-only variant: no edge file
-- (so the gold dialog border doesn't show through), no insets (so the
-- dark interior fills right up to the frame's outer rect, where the
-- metal border sits as an OVERLAY on top).
local function stripOriginalEdge(frame)
    if not (frame.GetBackdrop and frame.SetBackdrop) then return end
    local bd = frame:GetBackdrop()
    if not bd or not bd.bgFile then return end
    local tileSize = bd.tileSize
    if type(tileSize) == "table" then tileSize = tileSize.val end
    frame:SetBackdrop(nil)
    frame:SetBackdrop({
        bgFile   = bd.bgFile,
        tile     = bd.tile and true or false,
        tileSize = tileSize or 32,
        insets   = { left = 0, right = 0, top = 0, bottom = 0 },
    })
end

function Skin:ApplyMetalBorder(frame, thickness)
    if not frame or frame.eepgpMetalBorder then return end
    thickness = thickness or DEFAULT_THICKNESS

    -- Border textures live on a dedicated child frame whose level is bumped
    -- above the tab row. This way the metal corners/edges draw IN FRONT of
    -- the tab buttons, so the tab tops slip behind the frame trim instead
    -- of floating above it.
    local borderFrame = CreateFrame("Frame", nil, frame)
    borderFrame:SetAllPoints(frame)
    borderFrame:SetFrameLevel(frame:GetFrameLevel() + 10)

    local function makeTex()
        return borderFrame:CreateTexture(nil, "OVERLAY")
    end

    -- Corners straddle the frame edge: OUTSIDE_EXTENSION px outside, the
    -- rest inside. Anchor the corner's CENTER to the frame's outer corner
    -- with an inward offset so most of the texture quad lands on the
    -- frame's hit area.
    local inset = thickness / 2 - OUTSIDE_EXTENSION

    local tl = makeTex(); tl:SetSize(thickness, thickness)
    tl:SetPoint("CENTER", frame, "TOPLEFT",      inset, -inset)
    applyAtlas(tl, ATLAS.cornerTL)

    local tr = makeTex(); tr:SetSize(thickness, thickness)
    tr:SetPoint("CENTER", frame, "TOPRIGHT",    -inset, -inset)
    applyAtlas(tr, ATLAS.cornerTR)

    local bl = makeTex(); bl:SetSize(thickness, thickness)
    bl:SetPoint("CENTER", frame, "BOTTOMLEFT",   inset,  inset)
    applyAtlas(bl, ATLAS.cornerBL)

    local br = makeTex(); br:SetSize(thickness, thickness)
    br:SetPoint("CENTER", frame, "BOTTOMRIGHT", -inset,  inset)
    applyAtlas(br, ATLAS.cornerBR)

    -- Each edge fills the rectangle between the two adjacent corners.
    -- All four edges have a dedicated atlas slice now, so SetAtlas works
    -- as-is — no rotation, no probe, no manual UV math.
    local et = makeTex()
    et:SetPoint("TOPLEFT",     tl, "TOPRIGHT")
    et:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
    applyAtlas(et, ATLAS.edgeTop)

    local eb = makeTex()
    eb:SetPoint("TOPLEFT",     bl, "TOPRIGHT")
    eb:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    applyAtlas(eb, ATLAS.edgeBot)

    local el = makeTex()
    el:SetPoint("TOPLEFT",     tl, "BOTTOMLEFT")
    el:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
    applyAtlas(el, ATLAS.edgeLeft)

    local er = makeTex()
    er:SetPoint("TOPLEFT",     tr, "BOTTOMLEFT")
    er:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    applyAtlas(er, ATLAS.edgeRight)

    stripOriginalEdge(frame)
    applyOpacity(frame)
    skinned[frame] = true

    -- Negative hit rect insets expand the frame's clickable area outward,
    -- so the OUTSIDE_EXTENSION overhang of the metal border is part of the
    -- drag region rather than dead space.
    if frame.SetHitRectInsets then
        frame:SetHitRectInsets(-OUTSIDE_EXTENSION, -OUTSIDE_EXTENSION,
                               -OUTSIDE_EXTENSION, -OUTSIDE_EXTENSION)
    end

    frame.eepgpMetalBorder = {
        corners = { tl = tl, tr = tr, bl = bl, br = br },
        edges   = { top = et, bottom = eb, left = el, right = er },
    }
end

-- ---------------------------------------------------------------------------
-- SimpleMetal border (used on the Raid Manager). Same 9-slice idea as
-- ApplyMetalBorder, but the source atlas only ships 1 edge slice and 1
-- generic corner slice, so we rotate them for the other sides/corners.
-- Top-right uses a special variant with a recessed pocket for the close
-- button; the close button is bumped above the border frame so it sits
-- visually inside the pocket.
--
-- Atlas registry data:
--   _UI-Frame-SimpleMetal-EdgeTop                64x64  (tile-able, '_' prefix)
--   UI-Frame-SimpleMetal-CornerTopLeft           64x64
--   UI-Frame-SimpleMetal-CornerTopRightButton    64x64  (with close-btn pocket)
-- ---------------------------------------------------------------------------

local SIMPLE_METAL = {
    edge        = { atlas = "_UI-Frame-SimpleMetal-EdgeTop",
                    L = 0,         R = 0.5,      T = 0.00390625, B = 0.253906 },
    cornerTL    = { atlas = "UI-Frame-SimpleMetal-CornerTopLeft",
                    L = 0.0078125, R = 0.507812, T = 0.261719,   B = 0.511719 },
    cornerTRBtn = { atlas = "UI-Frame-SimpleMetal-CornerTopRightButton",
                    L = 0.0078125, R = 0.507812, T = 0.519531,   B = 0.769531 },
}

-- Apply a slice's UVs at the given rotation (degrees CCW: 0, 90, 180, 270).
-- 8-arg SetTexCoord order is ULx,ULy, LLx,LLy, URx,URy, LRx,LRy.
local function applyRotatedSlice(tex, file, slice, rotation)
    if not (file and tex) then return false end
    tex:SetTexture(file)
    local L, R, T, B = slice.L, slice.R, slice.T, slice.B
    if rotation == 90 then          -- 90° CCW
        tex:SetTexCoord(R, T, L, T, R, B, L, B)
    elseif rotation == 180 then     -- 180°
        tex:SetTexCoord(R, B, R, T, L, B, L, T)
    elseif rotation == 270 then     -- 270° CCW (= 90° CW)
        tex:SetTexCoord(L, B, R, B, L, T, R, T)
    else                            -- 0° (no rotation)
        tex:SetTexCoord(L, R, T, B)
    end
    return true
end

local SIMPLE_METAL_THICKNESS = 60
local SIMPLE_METAL_OUTSIDE   = 5

function Skin:ApplySimpleMetalBorder(frame, opts)
    if not frame or frame.eepgpSimpleMetalBorder then return end
    opts = opts or {}
    local thickness = opts.thickness       or SIMPLE_METAL_THICKNESS
    local outside   = opts.outsideExtension or SIMPLE_METAL_OUTSIDE
    -- plainTopRight: use the generic corner (CornerTopLeft @270°, i.e. the
    -- bottom-right corner rotated another 90° CCW) for the top-right rather
    -- than the close-button-pocket variant — for frames that have no close
    -- button in that corner.
    local plainTR   = opts.plainTopRight or false

    -- Probe the underlying file paths once for each unique atlas. Both
    -- corners share the same sheet on Ascension's atlas, so two probes
    -- (corner sheet + edge sheet) cover all four corner textures.
    local edgeFile     = probeAtlasFile(frame, SIMPLE_METAL.edge.atlas)
    local cornerFile   = probeAtlasFile(frame, SIMPLE_METAL.cornerTL.atlas)
    local cornerTRFile = (not plainTR) and probeAtlasFile(frame, SIMPLE_METAL.cornerTRBtn.atlas) or nil
    if not (edgeFile and cornerFile) then return end
    if not plainTR and not cornerTRFile then return end

    local borderFrame = CreateFrame("Frame", nil, frame)
    borderFrame:SetAllPoints(frame)
    borderFrame:SetFrameLevel(frame:GetFrameLevel() + 10)

    local function makeTex() return borderFrame:CreateTexture(nil, "OVERLAY") end

    local inset = thickness / 2 - outside

    -- Corners. CCW rotation order from TL: BL → BR → (TR is special).
    local tl = makeTex(); tl:SetSize(thickness, thickness)
    tl:SetPoint("CENTER", frame, "TOPLEFT",      inset, -inset)
    applyRotatedSlice(tl, cornerFile, SIMPLE_METAL.cornerTL, 0)

    local bl = makeTex(); bl:SetSize(thickness, thickness)
    bl:SetPoint("CENTER", frame, "BOTTOMLEFT",   inset,  inset)
    applyRotatedSlice(bl, cornerFile, SIMPLE_METAL.cornerTL, 90)

    local br = makeTex(); br:SetSize(thickness, thickness)
    br:SetPoint("CENTER", frame, "BOTTOMRIGHT", -inset,  inset)
    applyRotatedSlice(br, cornerFile, SIMPLE_METAL.cornerTL, 180)

    local tr = makeTex(); tr:SetSize(thickness, thickness)
    tr:SetPoint("CENTER", frame, "TOPRIGHT",    -inset, -inset)
    if plainTR then
        applyRotatedSlice(tr, cornerFile, SIMPLE_METAL.cornerTL, 270)
    else
        applyRotatedSlice(tr, cornerTRFile, SIMPLE_METAL.cornerTRBtn, 0)
    end

    -- Edges. EdgeTop atlas rotated CCW for left, bottom, right.
    local et = makeTex()
    et:SetPoint("TOPLEFT",     tl, "TOPRIGHT")
    et:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
    applyRotatedSlice(et, edgeFile, SIMPLE_METAL.edge, 0)

    local el = makeTex()
    el:SetPoint("TOPLEFT",     tl, "BOTTOMLEFT")
    el:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
    applyRotatedSlice(el, edgeFile, SIMPLE_METAL.edge, 90)

    local eb = makeTex()
    eb:SetPoint("TOPLEFT",     bl, "TOPRIGHT")
    eb:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
    applyRotatedSlice(eb, edgeFile, SIMPLE_METAL.edge, 180)

    local er = makeTex()
    er:SetPoint("TOPLEFT",     tr, "BOTTOMLEFT")
    er:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")
    applyRotatedSlice(er, edgeFile, SIMPLE_METAL.edge, 270)

    stripOriginalEdge(frame)
    applyOpacity(frame)
    skinned[frame] = true

    if frame.SetHitRectInsets then
        frame:SetHitRectInsets(-outside, -outside, -outside, -outside)
    end

    frame.eepgpSimpleMetalBorder = {
        borderFrame = borderFrame,
        corners     = { tl = tl, tr = tr, bl = bl, br = br },
        edges       = { top = et, bottom = eb, left = el, right = er },
    }
end

-- Decorative filigree next to a frame's close button. Mirrors the Raid
-- Manager's: 50x71 source rendered 90 CCW + horizontally flipped, then
-- halved -> ~34x23 quad. Anchored TOPRIGHT to closeButton's TOPLEFT, on
-- the frame's ARTWORK sublayer -1 (above the bg, below the metal border,
-- which lives on the +10 borderFrame, so it stays pinned to the corner
-- and tucks behind the trim). SetAtlas locks UVs, so we probe the file
-- and apply the explicit 8-arg rotation/flip texcoords.
function Skin:AddCloseFiligree(frame)
    if not frame or frame.closeFiligree or not frame.closeButton then return end
    local fil = frame:CreateTexture(nil, "ARTWORK", nil, -1)
    fil:SetSize(34, 23)
    fil:SetPoint("TOPRIGHT", frame.closeButton, "TOPLEFT", 6, -4)
    if fil.SetAtlas then fil:SetAtlas("draft-filigree") end
    local file = fil:GetTexture()
    if file then
        fil:SetTexture(file)
        local L, R, T, B = 0.07373046875, 0.09814453125, 0.0849609375, 0.154296875
        fil:SetTexCoord(R, B, L, B, R, T, L, T)
    end
    frame.closeFiligree = fil
end

-- ---------------------------------------------------------------------------
-- Fancy multi-piece progress bar (Ascension "ui-frame-bar-*" atlas). Built
-- for the bid-popup countdown but reusable. Z-order, low → high (3.3.5a
-- ignores the CreateTexture sublevel arg, and ADD-blended textures can batch
-- oddly within a layer, so this leans on distinct draw layers):
--   BACKGROUND  bg channel (left/right caps + stretched centre)
--   BORDER      fill (cropped left→right; texture swaps "start" blue → "mid"
--               yellow → "end" red as the value crosses 66% / 33%)
--   ARTWORK     border trim caps + stretched centre (a whole layer above the
--               fill, so all three pieces frame it identically), then the
--               spark (ADD, created after the trim → above it)
--   OVERLAY     handle / tick (the divider riding the fill's right edge —
--               above the spark and the trim)
-- Returns a Frame with :SetValue(0..1) and :SetBarWidth(px). Height is fixed
-- at creation (the textures' native 31 px, scalable via opts.height).
-- ---------------------------------------------------------------------------

-- {atlasName, L, R, T, B, native w, native h}. All slices live on one sheet,
-- so probing any one of them yields the file path for the lot.
local BAR_ATLAS = {
    bgLeft       = { atlas = "ui-frame-bar-bgleft",       L = 0.367188,   R = 0.480469, T = 0.710938,   B = 0.78125,   w = 29,  h = 18 },
    bgRight      = { atlas = "ui-frame-bar-bgright",      L = 0.367188,   R = 0.480469, T = 0.789062,   B = 0.859375,  w = 29,  h = 18 },
    bgCenter     = { atlas = "ui-frame-bar-bgcenter",     L = 0,          R = 0.25,     T = 0.261719,   B = 0.332031,  w = 64,  h = 18 },
    fillStart    = { atlas = "ui-frame-bar-fill-blue",    L = 0,          R = 1,        T = 0.339844,   B = 0.40625,   w = 256, h = 17 },
    fillMid      = { atlas = "ui-frame-bar-fill-yellow",  L = 0,          R = 1,        T = 0.5625,     B = 0.628906,  w = 256, h = 17 },
    fillEnd      = { atlas = "ui-frame-bar-fill-red",     L = 0,          R = 1,        T = 0.488281,   B = 0.554688,  w = 256, h = 17 },
    handle       = { atlas = "ui-frame-bar-bordertick",   L = 0.292969,   R = 0.359375, T = 0.710938,   B = 0.832031,  w = 17,  h = 31 },
    spark        = { atlas = "ui-frame-bar-spark",        L = 0.292969,   R = 0.324219, T = 0.839844,   B = 0.964844,  w = 8,   h = 32 },
    borderLeft   = { atlas = "ui-frame-bar-borderleft",   L = 0.00390625, R = 0.140625, T = 0.710938,   B = 0.832031,  w = 35,  h = 31 },
    borderRight  = { atlas = "ui-frame-bar-borderright",  L = 0.00390625, R = 0.140625, T = 0.839844,   B = 0.960938,  w = 35,  h = 31 },
    borderCenter = { atlas = "ui-frame-bar-bordercenter", L = 0,          R = 0.25,     T = 0.00390625, B = 0.125,     w = 64,  h = 31 },
}
local BAR_NATIVE_H = 31

function Skin:CreateProgressBar(parent, opts)
    if not parent then return nil end
    opts = opts or {}
    local file = probeAtlasFile(parent, BAR_ATLAS.borderCenter.atlas)
    if not file then return nil end

    local height = opts.height or BAR_NATIVE_H
    local sc     = height / BAR_NATIVE_H
    local width  = opts.width or 200
    local function S(n) return n * sc end

    local bar = CreateFrame("Frame", nil, parent)
    bar:SetSize(width, height)

    local function tex(layer) return bar:CreateTexture(nil, layer) end
    local function slice(t, a) t:SetTexture(file); t:SetTexCoord(a.L, a.R, a.T, a.B) end

    -- Background channel: end caps anchored to the bar's edges, centre
    -- stretched between. Vertically centred via the LEFT/RIGHT anchors.
    local bgL = tex("BACKGROUND"); bgL:SetSize(S(BAR_ATLAS.bgLeft.w),  S(BAR_ATLAS.bgLeft.h));  bgL:SetPoint("LEFT",  bar, "LEFT");  slice(bgL, BAR_ATLAS.bgLeft)
    local bgR = tex("BACKGROUND"); bgR:SetSize(S(BAR_ATLAS.bgRight.w), S(BAR_ATLAS.bgRight.h)); bgR:SetPoint("RIGHT", bar, "RIGHT"); slice(bgR, BAR_ATLAS.bgRight)
    local bgC = tex("BACKGROUND"); bgC:SetHeight(S(BAR_ATLAS.bgCenter.h)); bgC:SetPoint("LEFT", bgL, "RIGHT"); bgC:SetPoint("RIGHT", bgR, "LEFT"); slice(bgC, BAR_ATLAS.bgCenter)

    -- Border caps poke `capOut` px past the bar's edges so they fully cover
    -- the bg channel (which sits flush to the edges).
    local capOut    = opts.borderOutset or 3
    -- Fill: on the BORDER draw layer — strictly above the BACKGROUND-layer bg
    -- channel, strictly below the ARTWORK-layer border trim (so all three trim
    -- pieces sit above it consistently — they're on a separate, higher layer,
    -- not just created-after on the same layer). Anchored to the channel's
    -- left, a touch in from the cap. Width + texcoord are driven by SetValue
    -- (cropped left→right, not stretched).
    local fillInset = opts.fillInset or S(4)
    local fill = tex("BORDER"); fill:SetHeight(S(BAR_ATLAS.fillStart.h)); fill:SetPoint("LEFT", bgL, "LEFT", fillInset, 0)

    -- Border trim (ARTWORK layer — strictly above the BORDER-layer fill, so
    -- left cap / centre / right cap all frame the fill identically). End caps +
    -- a stretched centre between them.
    local bL = tex("ARTWORK"); bL:SetSize(S(BAR_ATLAS.borderLeft.w),  S(BAR_ATLAS.borderLeft.h));  bL:SetPoint("LEFT",  bar, "LEFT",  -capOut, 0); slice(bL, BAR_ATLAS.borderLeft)
    local bR = tex("ARTWORK"); bR:SetSize(S(BAR_ATLAS.borderRight.w), S(BAR_ATLAS.borderRight.h)); bR:SetPoint("RIGHT", bar, "RIGHT",  capOut, 0); slice(bR, BAR_ATLAS.borderRight)
    local bC = tex("ARTWORK"); bC:SetHeight(S(BAR_ATLAS.borderCenter.h)); bC:SetPoint("LEFT", bL, "RIGHT"); bC:SetPoint("RIGHT", bR, "LEFT"); slice(bC, BAR_ATLAS.borderCenter)

    -- Tick + spark sit ABOVE the border trim. The handle/tick rides the
    -- fill's right edge on OVERLAY; the spark is pinned to it on ARTWORK,
    -- created after the trim pieces (so it's above the trim) and ADD-blended;
    -- the OVERLAY handle is above the spark. Both get a bump over the base
    -- scale — at the bar's scaled-down size they're otherwise barely
    -- noticeable, and they run a bit past the bar's edges, which reads fine for
    -- a divider/spark. The spark gets a bigger bump so it reads as a glow.
    local hSc = opts.handleScale or 1.4
    local sSc = opts.sparkScale  or 1.6
    local handle = tex("OVERLAY"); handle:SetSize(S(BAR_ATLAS.handle.w) * hSc, S(BAR_ATLAS.handle.h) * hSc); slice(handle, BAR_ATLAS.handle)
    handle:SetPoint("CENTER", fill, "RIGHT", 0, 0)
    local spark = tex("ARTWORK"); spark:SetSize(S(BAR_ATLAS.spark.w) * sSc, S(BAR_ATLAS.spark.h) * sSc); slice(spark, BAR_ATLAS.spark); spark:SetBlendMode("ADD")
    spark:SetPoint("CENTER", handle, "CENTER", 0, 0)

    bar.eepgpFile      = file
    bar.eepgpFill      = fill
    bar.eepgpHandle    = handle
    bar.eepgpSpark     = spark
    bar.eepgpFillInset = fillInset
    -- opts.solidColor: skip the blue→yellow→red ramp, always use the blue fill.
    bar.eepgpSolidFill = opts.solidColor and BAR_ATLAS.fillStart or nil

    function bar:SetBarWidth(w)
        self:SetWidth(w)
        self:SetValue(self.eepgpValue or 1)
    end

    function bar:SetValue(v)
        v = math.max(0, math.min(1, tonumber(v) or 0))
        self.eepgpValue = v
        -- Fill colour: solidColor bars stay blue; otherwise ramp blue ≥66%,
        -- yellow ≥33%, red below.
        local a = self.eepgpSolidFill
               or (v >= 0.66) and BAR_ATLAS.fillStart
               or (v >= 0.33) and BAR_ATLAS.fillMid
               or BAR_ATLAS.fillEnd
        local channel = self:GetWidth() - 2 * self.eepgpFillInset
        if channel < 1 then channel = 1 end
        local fw = channel * v
        if fw < 0.5 then fw = 0.5 end
        self.eepgpFill:SetWidth(fw)
        self.eepgpFill:SetTexture(self.eepgpFile)
        self.eepgpFill:SetTexCoord(a.L, a.L + (a.R - a.L) * v, a.T, a.B)
        if v <= 0 then self.eepgpHandle:Hide(); self.eepgpSpark:Hide()
        else self.eepgpHandle:Show(); self.eepgpSpark:Show() end
    end

    bar:SetValue(opts.value or 1)
    return bar
end

-- ---------------------------------------------------------------------------
-- Sortable column-header helpers — same look as the main window's Standings
-- and History tabs: a small atlas-glyph arrow tucked next to the active
-- header's label (up = ascending, flipped = descending) plus a gold tint
-- on hover. Header buttons themselves are plain <Button>s with a NormalFont
-- and ButtonText defined in XML; the owning module calls these on Refresh.
-- ---------------------------------------------------------------------------

local SORT_ARROW_ATLAS = "rotating-minimapguidearrow"
local SORT_ARROW_UV    = { L = 0.541992, R = 0.573242, T = 0.936523, B = 0.967773 }

-- Lazily create (and cache on the button) the arrow texture, anchored just
-- past the button's label FontString so it follows LEFT/RIGHT justification.
function Skin:GetSortArrow(btn)
    if not btn then return nil end
    if btn.eepgpSortArrow then return btn.eepgpSortArrow end
    local tex = btn:CreateTexture(nil, "OVERLAY")
    tex:SetSize(20, 20)
    local fs = btn.GetFontString and btn:GetFontString()
    if fs then
        tex:SetPoint("LEFT", fs, "RIGHT", -4, 0)
    else
        tex:SetPoint("RIGHT", btn, "RIGHT", -2, 0)
    end
    tex:Hide()
    btn.eepgpSortArrow = tex
    return tex
end

-- Show/hide + orient the arrow on a header button. `active` = this column is
-- the current sort key; `dir` = "asc" or "desc".
function Skin:UpdateSortArrow(btn, active, dir)
    local tex = self:GetSortArrow(btn)
    if not tex then return end
    if not active then tex:Hide(); return end
    local file = probeAtlasFile(btn, SORT_ARROW_ATLAS)
    if not file then tex:Hide(); return end
    tex:SetTexture(file)
    if dir == "desc" then
        tex:SetTexCoord(SORT_ARROW_UV.R, SORT_ARROW_UV.L, SORT_ARROW_UV.B, SORT_ARROW_UV.T)
    else
        tex:SetTexCoord(SORT_ARROW_UV.L, SORT_ARROW_UV.R, SORT_ARROW_UV.T, SORT_ARROW_UV.B)
    end
    tex:Show()
end

-- Gold-on-hover affordance for a sortable header button (idempotent).
function Skin:WireSortHeader(btn)
    if not btn or btn.eepgpSortHeaderWired then return end
    btn.eepgpSortHeaderWired = true
    btn:HookScript("OnEnter", function(self)
        local fs = self:GetFontString(); if fs then fs:SetTextColor(1, 0.82, 0) end
    end)
    btn:HookScript("OnLeave", function(self)
        local fs = self:GetFontString(); if fs then fs:SetTextColor(1, 1, 1) end
    end)
end

-- ---------------------------------------------------------------------------
-- Dropdown-style button skin (auctionhouse-nav-button-secondary atlases).
-- Three bg states (normal / hover / select-when-open) plus a small arrow
-- on the right that flips between up (closed) and down (open). Caller is
-- responsible for toggling the visual state via btn.eepgpSetDropdownOpen.
-- ---------------------------------------------------------------------------

local DROPDOWN_BTN = {
    normal = { atlas = "auctionhouse-nav-button-secondary",
               L = 0.635742, R = 0.895508, T = 0.287109, B = 0.412109 },
    hover  = { atlas = "auctionhouse-nav-button-secondary-highlight",
               L = 0.69043,  R = 0.928711, T = 0.591797, B = 0.673828 },
    select = { atlas = "auctionhouse-nav-button-secondary-select",
               L = 0.69043,  R = 0.928711, T = 0.677734, B = 0.759766 },
    arrowUp   = { atlas = "auctionhouse-ui-dropdown-arrow-up",
                  L = 0.950195, R = 0.976562, T = 0.505859, B = 0.556641 },
    arrowDown = { atlas = "auctionhouse-ui-dropdown-arrow-down",
                  L = 0.950195, R = 0.976562, T = 0.419922, B = 0.470703 },
}

function Skin:SkinDropdownButton(btn, opts)
    if not btn or btn.eepgpDropdownSkinned then return end
    btn.eepgpDropdownSkinned = true
    opts = opts or {}
    -- noArrow: skip the dropdown chevron and centre the label — for plain
    -- action buttons (e.g. Need/Greed/Pass) that want the picker's look but
    -- aren't menus. They also get a pressed state (the "select" overlay
    -- shown on mouse-down) since eepgpSetDropdownOpen is never called.
    local noArrow = opts.noArrow and true or false

    -- Wipe the UIPanelButtonTemplate gold textures.
    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")
    btn:SetHighlightTexture("")

    local function makeTex(layer) return btn:CreateTexture(nil, layer or "BORDER") end

    -- Background ships with dropshadow padding around the actual button
    -- face, so we render it 12 px wider + taller than the button's hit
    -- area (6 px overhang per side) and center it on the button. The
    -- button's logical width is whatever the XML defined; the bg paints
    -- under it. This keeps the dropshadow bleed on the bg's bottom-left.
    local btnW = btn:GetWidth() or 128
    local btnH = btn:GetHeight() or 22

    local bgN = makeTex("BORDER")
    bgN:SetSize(btnW + 12, btnH + 12)
    bgN:SetPoint("CENTER", btn, "CENTER")
    applyFlatSlice(bgN, btn, DROPDOWN_BTN.normal)

    -- Hover and select overlays cover the button-face portion of the bg
    -- (its native size minus the dropshadow padding), anchored to the bg's
    -- TOPRIGHT so the dropshadow bleed lives on the bg's bottom-left. The
    -- face sits ~4 px in from bgN's left edge once the padding's accounted
    -- for, so widen these by 3 px (TOPRIGHT-anchored → grows leftward) to
    -- close most of that gap without spilling onto the dropshadow.
    local OVERLAY_W = btnW + 3
    local bgH = makeTex("ARTWORK")
    bgH:SetSize(OVERLAY_W, btnH)
    bgH:SetPoint("TOPRIGHT", bgN, "TOPRIGHT", -2, 0)
    bgH:SetAlpha(0.3)
    applyFlatSlice(bgH, btn, DROPDOWN_BTN.hover)
    bgH:Hide()

    local bgS = makeTex("ARTWORK")
    bgS:SetSize(OVERLAY_W, btnH)
    bgS:SetPoint("TOPRIGHT", bgN, "TOPRIGHT", -2, 0)
    bgS:SetAlpha(0.3)
    applyFlatSlice(bgS, btn, DROPDOWN_BTN.select)
    bgS:Hide()

    -- Arrow icon on the right side of the button-face area. Anchored
    -- to bgN (always visible) instead of bgH because anchor chains
    -- through hidden textures don't always resolve until the hidden
    -- object is shown — that caused the arrow to sit at a fallback
    -- spot on first render and "snap" into place on first hover.
    -- Position recreates where the arrow would sit relative to bgH:
    --   bgH right    = bgN.right - 2 → arrow right    = bgN.right - 6
    --                                  (4 px in from bgH's right edge)
    --   bgH centerY  = bgN.top - btnH/2 - 6 → wait no, bgH is anchored
    --   to bgN.TOPRIGHT with no y offset, so bgH spans bgN.top..bgN.top-btnH
    --   bgH centerY  = bgN.top - btnH/2 → arrow centerY = same
    local arrow
    if not noArrow then
        arrow = makeTex("OVERLAY")
        arrow:SetSize(14, 14)
        arrow:SetPoint("RIGHT", bgN, "TOPRIGHT", -6, -(btnH / 2))
        applyFlatSlice(arrow, btn, DROPDOWN_BTN.arrowUp)
    end

    -- Anchor the label to bgN (always visible) instead of bgH for the
    -- same reason as the arrow — chains through hidden textures snap
    -- into place on first hover otherwise. Offsets recreate where the
    -- label would sit relative to bgH (centered vertically on bgH,
    -- 10 px from bgH's left, 22 px from bgH's right):
    --   bgH.left   = bgN.right - (btnW + 2) → label.left  = bgH.left + 10
    --   bgH.right  = bgN.right - 2          → label.right = bgH.right - 22
    --   bgH.center = bgN.top - btnH/2       → label center = same
    -- Override the button's per-state font objects (not just the
    -- current FontString) — UIPanelButtonTemplate swaps to its
    -- HighlightFont on hover and would otherwise revert our smaller
    -- size to the default 12pt. White text (GameFontHighlightSmall) on
    -- both normal and hover states; the bg highlight overlay already
    -- carries the hover feedback so we don't restyle the label.
    if btn.SetNormalFontObject and GameFontHighlightSmall then
        btn:SetNormalFontObject(GameFontHighlightSmall)
    end
    if btn.SetHighlightFontObject and GameFontHighlightSmall then
        btn:SetHighlightFontObject(GameFontHighlightSmall)
    end
    if btn.SetDisabledFontObject and GameFontDisableSmall then
        btn:SetDisabledFontObject(GameFontDisableSmall)
    end

    -- Geometry of the visible "face" (the lit art portion of bgN; the
    -- dropshadow padding lives on bgN's bottom-left — see bgH's anchor):
    -- as offsets from bgN.TOPRIGHT, the face spans x −(btnW+2)..−2, the
    -- centre x is −2 − btnW/2, and the centre y is −btnH/2 (label nudged
    -- 1 px up to sit true on the art).
    local FACE_CX = -2 - btnW / 2
    local FACE_CY = -(btnH / 2) + 1

    local label = btn:GetFontString()
    if label then label:ClearAllPoints() end

    if opts.icon then
        -- Left icon + label as one group, gap GAP between them, the whole
        -- group centred on the face: groupW = icon + GAP + rendered text
        -- width; the icon's left edge sits at FACE_CX − groupW/2, and the
        -- label hangs off the icon's right. (StringWidth is valid here —
        -- text + font object are already set above.) opts.groupNudgeX
        -- shifts the whole group (the label rides the icon).
        local isz   = opts.iconSize or 16
        local GAP   = 5
        local nudge = opts.groupNudgeX or 0
        local ico   = makeTex("OVERLAY")
        ico:SetSize(isz, isz)
        applyFlatSlice(ico, btn, opts.icon)
        if label then
            local lblW   = label:GetStringWidth() or 0
            local groupW = isz + GAP + lblW
            ico:SetPoint("LEFT", bgN, "TOPRIGHT", FACE_CX - groupW / 2 + nudge, FACE_CY)
            label:SetPoint("LEFT", ico, "RIGHT", GAP, 0)
            label:SetJustifyH("LEFT")
        else
            ico:SetPoint("CENTER", bgN, "TOPRIGHT", FACE_CX + nudge, FACE_CY)
        end
    elseif label then
        if noArrow then
            -- No arrow gutter on the right; just centre the label on the face.
            label:SetPoint("LEFT",  bgN, "TOPRIGHT", -(btnW - 6), FACE_CY)
            label:SetPoint("RIGHT", bgN, "TOPRIGHT", -10,         FACE_CY)
            label:SetJustifyH("CENTER")
        else
            label:SetPoint("LEFT",  bgN, "TOPRIGHT", -(btnW - 8), -(btnH / 2))
            label:SetPoint("RIGHT", bgN, "TOPRIGHT", -24,         -(btnH / 2))
            label:SetJustifyH("LEFT")
        end
    end

    -- Hover overlay — suppressed while the dropdown is open or the button is
    -- "checked" (a checked button no longer reacts to hover).
    btn:HookScript("OnEnter", function()
        if not btn.eepgpDropdownOpen and not btn.eepgpChecked then bgH:Show() end
    end)
    btn:HookScript("OnLeave", function() bgH:Hide() end)

    -- Caller flips this when the dropdown opens / closes.
    btn.eepgpSetDropdownOpen = function(open)
        btn.eepgpDropdownOpen = open and true or false
        if open then
            bgH:Hide()
            bgS:Show()
            if arrow then applyFlatSlice(arrow, btn, DROPDOWN_BTN.arrowDown) end
        else
            bgS:Hide()
            if arrow then applyFlatSlice(arrow, btn, DROPDOWN_BTN.arrowUp) end
        end
    end

    -- Persistent "checked"/selected state — shows the select overlay (the
    -- other secondary-nav highlight, distinct from the hover one) and
    -- suppresses hover until unchecked. Radio-button style: the caller is
    -- responsible for unchecking siblings in the group. Independent of the
    -- dropdown-open state above; a given button uses one or the other.
    btn.eepgpSetChecked = function(checked)
        btn.eepgpChecked = checked and true or false
        if checked then
            bgH:Hide()
            bgS:SetAlpha(0.6)   -- punchier than the 0.3 hover/dropdown-open overlay
            bgS:Show()
        else
            bgS:Hide()
        end
    end

    return btn
end

-- ---------------------------------------------------------------------------
-- Start Raid button skin: 3-piece (left cap / tileable middle / right cap)
-- using the 128-goldredbutton atlases. Three states (normal / pressed /
-- disabled) plus a hover overlay. The right cap is ~2.5× the width of the
-- left cap in source art (292 vs 114 px), so we keep that proportion when
-- sizing the rendered slices — the middle stretches to fill the gap.
-- The pressed and disabled cap atlases are the same texture (only the
-- middle differs); we still attach them as separate textures so visibility
-- gating stays simple.
-- ---------------------------------------------------------------------------

local START_RAID = {
    leftN  = { atlas = "128-goldredbutton-left",
               L = 0.576172,    R = 0.798828, T = 0.508789,    B = 0.633789 },
    leftP  = { atlas = "128-goldredbutton-left-pressed",
               L = 0.576172,    R = 0.798828, T = 0.762695,    B = 0.887695 },
    leftD  = { atlas = "128-goldredbutton-left-disabled",
               L = 0.576172,    R = 0.798828, T = 0.635742,    B = 0.760742 },
    rightN = { atlas = "128-goldredbutton-right",
               L = 0.00195312,  R = 0.572266, T = 0.508789,    B = 0.633789 },
    rightP = { atlas = "128-goldredbutton-right-pressed",
               L = 0.00195312,  R = 0.572266, T = 0.762695,    B = 0.887695 },
    rightD = { atlas = "128-goldredbutton-right-disabled",
               L = 0.00195312,  R = 0.572266, T = 0.635742,    B = 0.760742 },
    midN   = { atlas = "_128-goldredbutton-center",
               L = 0,           R = 0.125,    T = 0.000976562, B = 0.125977 },
    midP   = { atlas = "_128-goldredbutton-center-pressed",
               L = 0,           R = 0.125,    T = 0.254883,    B = 0.379883 },
    midD   = { atlas = "_128-goldredbutton-center-disabled",
               L = 0,           R = 0.125,    T = 0.12793,     B = 0.25293  },
    hover  = { atlas = "128-goldredbutton-highlight",
               L = 0.00195312,  R = 0.863281, T = 0.381836,    B = 0.506836 },
}

-- Source pixel dimensions of the cap art (widthN, height = 128). Used to
-- preserve the cap-width proportion when the button is rendered at a
-- different height than 128.
local START_RAID_LEFT_W   = 114
local START_RAID_RIGHT_W  = 292
local START_RAID_SOURCE_H = 128

function Skin:SkinStartRaidButton(btn)
    if not btn or btn.eepgpStartRaidSkinned then return end
    btn.eepgpStartRaidSkinned = true

    -- Wipe stock UIPanelButtonTemplate textures so they don't show through.
    btn:SetNormalTexture("")
    btn:SetPushedTexture("")
    btn:SetDisabledTexture("")
    btn:SetHighlightTexture("")

    local h = btn:GetHeight()
    if not h or h == 0 then h = 26 end
    local scale     = h / START_RAID_SOURCE_H
    local leftCapW  = math.floor(START_RAID_LEFT_W  * scale + 0.5)
    local rightCapW = math.floor(START_RAID_RIGHT_W * scale + 0.5)

    local function makeTex(layer) return btn:CreateTexture(nil, layer or "BORDER") end

    -- Normal-state pieces (visible by default).
    local nL = makeTex(); nL:SetSize(leftCapW,  h); nL:SetPoint("LEFT",  btn, "LEFT")
    applyFlatSlice(nL, btn, START_RAID.leftN)
    local nR = makeTex(); nR:SetSize(rightCapW, h); nR:SetPoint("RIGHT", btn, "RIGHT")
    applyFlatSlice(nR, btn, START_RAID.rightN)
    local nC = makeTex(); nC:SetHeight(h)
    nC:SetPoint("LEFT",  nL, "RIGHT")
    nC:SetPoint("RIGHT", nR, "LEFT")
    applyFlatSlice(nC, btn, START_RAID.midN)

    -- Pressed-state pieces (visible while held on an enabled button).
    local pL = makeTex(); pL:SetSize(leftCapW,  h); pL:SetPoint("LEFT",  btn, "LEFT");  pL:Hide()
    applyFlatSlice(pL, btn, START_RAID.leftP)
    local pR = makeTex(); pR:SetSize(rightCapW, h); pR:SetPoint("RIGHT", btn, "RIGHT"); pR:Hide()
    applyFlatSlice(pR, btn, START_RAID.rightP)
    local pC = makeTex(); pC:SetHeight(h); pC:Hide()
    pC:SetPoint("LEFT",  pL, "RIGHT")
    pC:SetPoint("RIGHT", pR, "LEFT")
    applyFlatSlice(pC, btn, START_RAID.midP)

    -- Disabled-state pieces (visible whenever the button is disabled).
    local dL = makeTex(); dL:SetSize(leftCapW,  h); dL:SetPoint("LEFT",  btn, "LEFT");  dL:Hide()
    applyFlatSlice(dL, btn, START_RAID.leftD)
    local dR = makeTex(); dR:SetSize(rightCapW, h); dR:SetPoint("RIGHT", btn, "RIGHT"); dR:Hide()
    applyFlatSlice(dR, btn, START_RAID.rightD)
    local dC = makeTex(); dC:SetHeight(h); dC:Hide()
    dC:SetPoint("LEFT",  dL, "RIGHT")
    dC:SetPoint("RIGHT", dR, "LEFT")
    applyFlatSlice(dC, btn, START_RAID.midD)

    -- Hover overlay (above bg, below text). Spans the full button.
    local hover = makeTex("ARTWORK")
    hover:SetPoint("LEFT",  btn, "LEFT")
    hover:SetPoint("RIGHT", btn, "RIGHT")
    hover:SetHeight(h)
    hover:Hide()
    applyFlatSlice(hover, btn, START_RAID.hover)

    -- Lift the button label above ARTWORK so it draws over the bg + hover.
    local fs = btn.GetFontString and btn:GetFontString()
    if fs then
        fs:SetDrawLayer("OVERLAY")
    end

    -- State arbitration: disabled > pressed > normal. We read state via
    -- GetButtonState() because Button:IsEnabled() returns 0 (not nil) for
    -- disabled in 3.3.5a, and 0 is truthy in Lua — so `not btn:IsEnabled()`
    -- never fires.
    local function applyVisual()
        nL:Hide(); nC:Hide(); nR:Hide()
        pL:Hide(); pC:Hide(); pR:Hide()
        dL:Hide(); dC:Hide(); dR:Hide()
        if btn:GetButtonState() == "DISABLED" then
            dL:Show(); dC:Show(); dR:Show()
            hover:Hide()
        elseif btn.eepgpPressed then
            pL:Show(); pC:Show(); pR:Show()
        else
            nL:Show(); nC:Show(); nR:Show()
        end
    end
    btn.eepgpApplyVisual = applyVisual

    -- Mouse events. OnLeave reverts the pressed flag in case the user
    -- drags off the button while still holding the mouse button.
    btn:HookScript("OnMouseDown", function(self) self.eepgpPressed = true;  applyVisual() end)
    btn:HookScript("OnMouseUp",   function(self) self.eepgpPressed = false; applyVisual() end)
    btn:HookScript("OnEnter", function()
        if btn:GetButtonState() ~= "DISABLED" then hover:Show() end
    end)
    btn:HookScript("OnLeave", function()
        hover:Hide()
        btn.eepgpPressed = false
        applyVisual()
    end)

    -- Wrap Enable/Disable so applyVisual fires when callers toggle the
    -- button (RefreshActiveState flips it based on raid context + auth).
    -- 3.3.5a buttons don't fire OnEnable/OnDisable scripts reliably, so
    -- we intercept the methods themselves.
    local origEnable = btn.Enable
    btn.Enable = function(self, ...)
        origEnable(self, ...)
        applyVisual()
    end
    local origDisable = btn.Disable
    btn.Disable = function(self, ...)
        origDisable(self, ...)
        applyVisual()
    end

    applyVisual()
end

-- ---------------------------------------------------------------------------
-- Side popup border (3-sided frame trim using the services-popup atlas).
-- The popup attaches to the MainFrame on one side; that attached side stays
-- seamless (no trim) so the popup reads as an extension of the main window.
--
--   attachedSide = "left"  → popup sits to the RIGHT of main; trim runs
--                            top + right + bottom (left edge open)
--   attachedSide = "right" → popup sits to the LEFT of main; trim runs
--                            top + left + bottom (right edge open)
--
-- Calling this on the same frame again rebuilds the trim — it's safe to
-- swap orientations when the main window moves between sides of the screen.
-- ---------------------------------------------------------------------------

local POPUP = {
    top    = "services-popup-top",
    bot    = "services-popup-bot",
    right  = "services-popup-right",
    left   = "services-popup-left",
    tr     = "services-popup-topright",
    br     = "services-popup-botright",
    tl     = "services-popup-topleft",
    bl     = "services-popup-botleft",
}

-- Render thicknesses. Side edge sized to match the corner's vertical leg
-- (≈ POPUP_TOP_H) — keeping it from being scaled wider than the corner.
local POPUP_TOP_H      = 30   -- top edge / top corner height
local POPUP_BOT_H      = 22   -- bottom edge / bottom corner height
local POPUP_SIDE_W     = 30   -- side edge width (capped by top corner thickness)
local POPUP_TCORNER_W  = 53   -- top corner width  (≈106/2 source)
local POPUP_BCORNER_W  = 52   -- bottom corner width (≈104/2 source)

function Skin:ApplySidePopupBorder(frame, attachedSide)
    if not frame then return end

    -- Tear down any previous trim first so swapping orientations doesn't
    -- leave stale textures lying around.
    if frame.eepgpSidePopupBorder then
        for _, t in pairs(frame.eepgpSidePopupBorder.textures) do
            if t then t:Hide(); t:SetTexture(nil); t:ClearAllPoints() end
        end
        frame.eepgpSidePopupBorder = nil
    end

    stripOriginalEdge(frame)

    -- The trim atlases have transparent padding around their visible art,
    -- so the dark bg leaks past the trim's visible edge if its insets are
    -- 0. Reset the Backdrop with insets pulled inward on the trimmed sides
    -- (the seamless side stays 0 so the dark fill runs flush against the
    -- main view). Top has more transparent padding than bottom/sides so it
    -- needs a larger inset.
    local PAD_TOP    = 14
    local PAD_BOTTOM = 6
    local PAD_SIDE   = 6
    if frame.GetBackdrop and frame.SetBackdrop then
        local bd = frame:GetBackdrop()
        if bd and bd.bgFile then
            local tileSize = bd.tileSize
            if type(tileSize) == "table" then tileSize = tileSize.val end
            local L = (attachedSide == "left")  and 0 or PAD_SIDE
            local R = (attachedSide == "right") and 0 or PAD_SIDE
            frame:SetBackdrop(nil)
            frame:SetBackdrop({
                bgFile   = bd.bgFile,
                tile     = bd.tile and true or false,
                tileSize = tileSize or 32,
                insets   = { left = L, right = R, top = PAD_TOP, bottom = PAD_BOTTOM },
            })
        end
    end

    applyOpacity(frame)
    skinned[frame] = true

    -- BORDER layer: above bg, BELOW the title/text on ARTWORK so the
    -- popup's title remains readable through the trim's edge area.
    local function makeTex() return frame:CreateTexture(nil, "BORDER") end
    local function setAtlas(tex, name)
        if tex.SetAtlas then tex:SetAtlas(name) end
    end

    local textures = {}

    if attachedSide == "left" then
        -- Popup attaches to main via its LEFT edge (popup is on the RIGHT
        -- side of the main window). Trim: top, right, bottom.
        local tr = makeTex(); tr:SetSize(POPUP_TCORNER_W, POPUP_TOP_H)
        tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        setAtlas(tr, POPUP.tr)
        textures.tr = tr

        local br = makeTex(); br:SetSize(POPUP_BCORNER_W, POPUP_BOT_H)
        br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        setAtlas(br, POPUP.br)
        textures.br = br

        local top = makeTex(); top:SetHeight(POPUP_TOP_H)
        top:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        top:SetPoint("TOPRIGHT", tr,    "TOPLEFT",  0, 0)
        setAtlas(top, POPUP.top)
        textures.top = top

        local bot = makeTex(); bot:SetHeight(POPUP_BOT_H)
        bot:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",  0, 0)
        bot:SetPoint("BOTTOMRIGHT", br,    "BOTTOMLEFT",  0, 0)
        setAtlas(bot, POPUP.bot)
        textures.bot = bot

        local right = makeTex(); right:SetWidth(POPUP_SIDE_W)
        right:SetPoint("TOPRIGHT",    tr, "BOTTOMRIGHT", -0.5, 0)
        right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT",    -0.5, 0)
        setAtlas(right, POPUP.right)
        textures.right = right
    else
        -- attachedSide == "right" — popup attaches to main via its RIGHT
        -- edge (popup is on the LEFT side of main). Trim: top, left, bottom.
        local tl = makeTex(); tl:SetSize(POPUP_TCORNER_W, POPUP_TOP_H)
        tl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        setAtlas(tl, POPUP.tl)
        textures.tl = tl

        local bl = makeTex(); bl:SetSize(POPUP_BCORNER_W, POPUP_BOT_H)
        bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        setAtlas(bl, POPUP.bl)
        textures.bl = bl

        local top = makeTex(); top:SetHeight(POPUP_TOP_H)
        top:SetPoint("TOPLEFT",  tl,    "TOPRIGHT", 0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        setAtlas(top, POPUP.top)
        textures.top = top

        local bot = makeTex(); bot:SetHeight(POPUP_BOT_H)
        bot:SetPoint("BOTTOMLEFT",  bl,    "BOTTOMRIGHT", 0, 0)
        bot:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        setAtlas(bot, POPUP.bot)
        textures.bot = bot

        local left = makeTex(); left:SetWidth(POPUP_SIDE_W)
        left:SetPoint("TOPLEFT",    tl, "BOTTOMLEFT", 0.5, 0)
        left:SetPoint("BOTTOMLEFT", bl, "TOPLEFT",    0.5, 0)
        setAtlas(left, POPUP.left)
        textures.left = left
    end

    frame.eepgpSidePopupBorder = {
        attachedSide = attachedSide,
        textures     = textures,
    }
end
