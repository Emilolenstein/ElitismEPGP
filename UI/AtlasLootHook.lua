local _, addon = ...

local UI = addon.UI or {}
addon.UI = UI

local AtlasLootHook = {}
UI.AtlasLootHook = AtlasLootHook

------------------------------------------------------------
-- AtlasLoot integration: injects "Set GP override / Clear GP override"
-- entries into the right-click context menu on item rows. Officer-only.
--
-- Implementation:
--  1) Hook GetItemConditionals so each item table preserves its source
--     (Normal-difficulty) itemID before AtlasLoot's CloneTable overwrites
--     it with the resolved difficulty variant.
--  2) Wrap ItemContextMenu — temporarily swap OpenDewdropMenu so we can
--     mutate the menuList table just before the dewdrop renders.
--  3) Saving a GP fans out to all difficulty variants via Prices'
--     SetTierBaseOverride helper.
------------------------------------------------------------

local function getAtlasLoot()
    if not LibStub then return nil end
    local lib = LibStub("AceAddon-3.0", true)
    if not lib then return nil end
    local ok, atl = pcall(function() return lib:GetAddon("AtlasLoot", true) end)
    return ok and atl or nil
end

local function isOfficer()
    return addon.IsOfficer and addon.IsOfficer() or false
end

------------------------------------------------------------
-- Token detection: a token's data table carries a `sourcePage` field of
-- the form { parentDataID, "Token" }. parentDataID looks like "T1WRIST",
-- "T2HEAD", etc. Stripping the slot suffix gives the aggregate dataID
-- ("T1") whose AtlasLoot_Data table holds the actual tier pieces.
--
-- We only need ONE tier piece's itemID — they're all the same slot at
-- the same difficulty, so any of them works as the ilvl reference.
------------------------------------------------------------

local SLOT_SUFFIX = {
    -- Order matters: longer suffixes first so e.g. "SHOULDER" is matched
    -- before any shorter substring overlap. (None overlap currently, but
    -- being explicit guards against future additions.)
    "SHOULDER", "FINGER", "WRIST", "CHEST", "WAIST",
    "LEGS", "FEET", "HAND", "BACK", "NECK", "HEAD",
}

local SUFFIX_TO_EQUIPLOC = {
    HEAD     = "INVTYPE_HEAD",
    SHOULDER = "INVTYPE_SHOULDER",
    CHEST    = "INVTYPE_CHEST",
    WRIST    = "INVTYPE_WRIST",
    HAND     = "INVTYPE_HAND",
    WAIST    = "INVTYPE_WAIST",
    LEGS     = "INVTYPE_LEGS",
    FEET     = "INVTYPE_FEET",
    FINGER   = "INVTYPE_FINGER",
    BACK     = "INVTYPE_CLOAK",
    NECK     = "INVTYPE_NECK",
}

local SUFFIX_ALT_EQUIPLOC = {
    -- Cloth chest items report INVTYPE_ROBE, not INVTYPE_CHEST.
    CHEST = "INVTYPE_ROBE",
}

local function findFirstConvertedItem(tokenDataID)
    if not AtlasLoot_Data or type(tokenDataID) ~= "string" then return nil end
    local parentID, slotKey
    for _, k in ipairs(SLOT_SUFFIX) do
        if tokenDataID:sub(-#k) == k then
            parentID = tokenDataID:sub(1, -#k - 1)
            slotKey  = k
            break
        end
    end
    if not parentID or not slotKey then return nil end

    local data = AtlasLoot_Data[parentID]
    if not data then return nil end

    local desired = SUFFIX_TO_EQUIPLOC[slotKey]
    local alt     = SUFFIX_ALT_EQUIPLOC[slotKey]

    -- AtlasLoot_Data["T1"] is an array of class tables; each class table
    -- holds one or more arrays of items keyed by numeric index. We only
    -- need the first item whose equipLoc matches.
    for _, classTable in ipairs(data) do
        for _, itemArray in ipairs(classTable) do
            for _, v in ipairs(itemArray) do
                if type(v) == "table" and v.itemID then
                    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(v.itemID)
                    if equipLoc == desired or (alt and equipLoc == alt) then
                        return v.itemID
                    end
                end
            end
        end
    end
    return nil
end

-- Returns every convertible piece itemID (all classes for that slot) in
-- the parent dataID — used when the officer overrides a token price so
-- we can propagate it to every class's tier piece for that slot.
local function findAllConvertedItems(tokenDataID)
    if not AtlasLoot_Data or type(tokenDataID) ~= "string" then return {} end
    local parentID, slotKey
    for _, k in ipairs(SLOT_SUFFIX) do
        if tokenDataID:sub(-#k) == k then
            parentID = tokenDataID:sub(1, -#k - 1)
            slotKey  = k
            break
        end
    end
    if not parentID or not slotKey then return {} end
    local data = AtlasLoot_Data[parentID]
    if not data then return {} end
    local desired = SUFFIX_TO_EQUIPLOC[slotKey]
    local alt     = SUFFIX_ALT_EQUIPLOC[slotKey]
    local seen, out = {}, {}
    for _, classTable in ipairs(data) do
        for _, itemArray in ipairs(classTable) do
            for _, v in ipairs(itemArray) do
                if type(v) == "table" and v.itemID and not seen[v.itemID] then
                    local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(v.itemID)
                    if equipLoc == desired or (alt and equipLoc == alt) then
                        seen[v.itemID] = true
                        table.insert(out, v.itemID)
                    end
                end
            end
        end
    end
    return out
end

local function detectScaleRef(data)
    -- data is the AtlasLoot item button. data.sourcePage was set in
    -- AtlasLoot's SetupButton from itemNumber.lootTable.
    local sp = data and data.sourcePage
    if type(sp) ~= "table" or sp[2] ~= "Token" then return nil end
    return findFirstConvertedItem(sp[1])
end

------------------------------------------------------------
-- Token resolver: maps tokenItemID → parent tier dataID (e.g. "T1WRIST")
-- by walking AtlasLoot_Data for items with lootTable[2] == "Token".
--
-- Lazy build: AtlasLoot_OriginalWoW (and other sibling AtlasLoot_* data
-- addons) may load AFTER our OnEnable, so an eager walk at Init can run
-- against an empty AtlasLoot_Data. Defer the walk to the first resolver
-- call instead — by then the player has hovered an item, so all addons
-- have settled. Walk once and cache.
--
-- Piece resolution (parent → concrete tier piece itemID) is also lazy
-- per-token because GetItemInfo can be cold at login. Failures don't
-- cache so subsequent hovers retry once the client fetches item data.
------------------------------------------------------------

-- Difficulty IDs we fan out to (3 = Normal is the base/source ID).
-- 1 = Bloodforged, 2 = Heroic Bloodforged, 4 = Heroic, 5 = Mythic, 6 = Ascended.
local TOKEN_VARIANT_DIFS = { 1, 2, 4, 5, 6 }
local TOKEN_NORMAL_DIF   = 3

-- Each map entry: { parent = "T1WRIST", dif = 3 }
-- We add the Normal token AND every variant difficulty so the resolver
-- can match whichever itemID AtlasLoot rendered. The dif is stored so
-- the resolver knows to translate the piece itemID into the matching
-- difficulty (heroic token → heroic tier piece, etc.).
local tokenSourceMap  = {}
local tokenPieceCache = {}  -- tokenItemID → resolved piece itemID (per-difficulty)
local tokenMapBuilt   = false
local tokenMapCount   = 0

local function addTokenEntry(itemID, parent, dif)
    if not itemID or itemID == 0 or tokenSourceMap[itemID] then return end
    tokenSourceMap[itemID] = { parent = parent, dif = dif }
    tokenMapCount = tokenMapCount + 1
end

local function buildTokenSourceMap()
    if not AtlasLoot_Data then return false end
    local hasGetDif = type(GetItemDifficultyID) == "function"
    for _, data in pairs(AtlasLoot_Data) do
        if type(data) == "table" then
            for _, classTable in ipairs(data) do
                if type(classTable) == "table" then
                    for _, itemArray in ipairs(classTable) do
                        if type(itemArray) == "table" then
                            for _, v in ipairs(itemArray) do
                                if type(v) == "table" and v.itemID
                                   and type(v.lootTable) == "table"
                                   and v.lootTable[2] == "Token" then
                                    local parent = v.lootTable[1]
                                    addTokenEntry(v.itemID, parent, TOKEN_NORMAL_DIF)
                                    if hasGetDif then
                                        for _, dif in ipairs(TOKEN_VARIANT_DIFS) do
                                            local variantID = GetItemDifficultyID(v.itemID, dif)
                                            if variantID and variantID ~= 0 and variantID ~= v.itemID then
                                                addTokenEntry(variantID, parent, dif)
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if tokenMapCount > 0 then tokenMapBuilt = true end
    return tokenMapBuilt
end

local function resolveTokenPiece(itemID)
    if not itemID then return nil end
    local cached = tokenPieceCache[itemID]
    if cached then return cached end
    if not tokenMapBuilt then buildTokenSourceMap() end
    local entry = tokenSourceMap[itemID]
    if not entry then return nil end
    local normalPieceID = findFirstConvertedItem(entry.parent)
    if not normalPieceID then return nil end
    -- Translate the piece into the same difficulty as the token. The
    -- piece's own variants carry the right per-difficulty ilvl, which
    -- is what makes Heroic/Mythic tokens price differently from Normal.
    local pieceID = normalPieceID
    if entry.dif ~= TOKEN_NORMAL_DIF and type(GetItemDifficultyID) == "function" then
        local variantPiece = GetItemDifficultyID(normalPieceID, entry.dif)
        if variantPiece and variantPiece ~= 0 then
            pieceID = variantPiece
        end
    end
    tokenPieceCache[itemID] = pieceID
    return pieceID
end

-- Resolves a token itemID to its parent dataID (e.g. "T1WRIST") via the
-- resolver map. Works for any difficulty variant since the map carries
-- all of them. Returns nil for non-tokens.
local function getTokenDataIDFromItem(itemID)
    if not itemID then return nil end
    if not tokenMapBuilt then buildTokenSourceMap() end
    local entry = tokenSourceMap[itemID]
    return entry and entry.parent or nil
end

------------------------------------------------------------
-- Token → piece price propagation
------------------------------------------------------------
-- When an officer overrides a token's GP, mirror the override onto every
-- class's tier piece for that slot (and all difficulty variants of each
-- piece) by linking them to the Normal token. Pieces inherit the token's
-- price; their own ilvl drives the per-difficulty scaling. Clearing the
-- token override removes these links so pieces fall back to formula GP.

local function fanOutTokenToPieces(normalTokenID, tokenDataID, by)
    if not addon.Prices or not normalTokenID or not tokenDataID then return end
    local pieces = findAllConvertedItems(tokenDataID)
    local hasGetDif = type(GetItemDifficultyID) == "function"
    for _, pieceID in ipairs(pieces) do
        addon.Prices:SetLinkedOverride(pieceID, normalTokenID, by, nil)
        if hasGetDif then
            for _, dif in ipairs(TOKEN_VARIANT_DIFS) do
                local variant = GetItemDifficultyID(pieceID, dif)
                if variant and variant ~= 0 and variant ~= pieceID then
                    addon.Prices:SetLinkedOverride(variant, normalTokenID, by, nil)
                end
            end
        end
    end
end

local function clearTokenPieceFanOut(tokenDataID)
    if not addon.Prices or not tokenDataID then return end
    local pieces = findAllConvertedItems(tokenDataID)
    local hasGetDif = type(GetItemDifficultyID) == "function"
    for _, pieceID in ipairs(pieces) do
        addon.Prices:ClearOverride(pieceID)
        if hasGetDif then
            for _, dif in ipairs(TOKEN_VARIANT_DIFS) do
                local variant = GetItemDifficultyID(pieceID, dif)
                if variant and variant ~= 0 and variant ~= pieceID then
                    addon.Prices:ClearOverride(variant)
                end
            end
        end
    end
end

------------------------------------------------------------
-- Set GP popup
------------------------------------------------------------

local function openSetGPPopup(normalID, itemLink, scaleAsItemID, tokenDataID)
    local current
    if addon.Prices:GetOverrideKind(normalID) == "gp" then
        current = addon.Prices:GetOverride(normalID) or 0
    else
        -- Tokens have no equipLoc and a shared flat ilvl, so computing GP
        -- from the token itself returns base-only (no slot multiplier).
        -- If we detected a tier piece reference, use its ilvl + equipLoc so
        -- the prefilled default is meaningful and usually save-as-is.
        local refID = scaleAsItemID or normalID
        local desc = addon.Prices:Describe(refID)
        current = (desc and addon.Prices:Compute(desc.ilvl, desc.equipLoc)) or 0
    end
    local scaleNote = ""
    if scaleAsItemID then
        local scaleDesc = addon.Prices:Describe(scaleAsItemID)
        local label = (scaleDesc and scaleDesc.link) or ("item:" .. scaleAsItemID)
        scaleNote = string.format("\n|cFF66CCFFToken detected:|r variants will scale by %s's ilvl.", label)
    end
    addon.Dialog:Prompt({
        title   = "Set GP Override",
        text    = string.format(
            "Set base GP for %s.\nApplies to all difficulty variants — Heroic / Mythic / Ascended / Bloodforged auto-scale by ilvl.\nFormula default: %d%s",
            itemLink or ("item:" .. normalID), current, scaleNote),
        default = tostring(current),
        letters = 6,
        accept  = "Save",
        OnAccept = function(text)
            local gp = tonumber(text)
            if not (gp and gp >= 0) then return end
            addon.Prices:SetTierBaseOverride(normalID, gp, nil, scaleAsItemID)
            if tokenDataID then
                fanOutTokenToPieces(normalID, tokenDataID)
            end
            if addon.Print then
                addon.Print(string.format("Set GP override: %s = %d (variants & class pieces auto-scaled).",
                    itemLink or ("item:" .. normalID), gp))
            end
        end,
    })
end

------------------------------------------------------------
-- Menu injection
------------------------------------------------------------

local function resolveItemLink(itemID)
    local _, link = GetItemInfo(itemID)
    return link or ("item:" .. tostring(itemID))
end

local function injectMenuEntries(menuList, data)
    if not data or not data.itemID then return end
    if not isOfficer() then return end
    if not addon.Prices then return end

    -- _eepgpSourceID was stashed by our hook on GetItemConditionals; if
    -- absent (e.g. items reached via a code path we didn't hook), fall
    -- back to data.itemID — works correctly when the user is on Normal
    -- difficulty, slightly off otherwise.
    -- _eepgpSourceID is on the cloned data item; data is the AtlasLoot
    -- button frame, which has the cloned item exposed as data.item.
    local normalID = data._eepgpSourceID
        or (data.item and data.item._eepgpSourceID)
        or data.itemID
    local hasOverride = addon.Prices:HasOverride(normalID)
    local link = resolveItemLink(normalID)
    -- tokenDataID works for any difficulty (sourcePage is only set on the
    -- displayed Normal item; the resolver map carries every variant).
    local tokenDataID = getTokenDataIDFromItem(normalID)
        or getTokenDataIDFromItem(data.itemID)
    local scaleRef = (tokenDataID and findFirstConvertedItem(tokenDataID))
        or detectScaleRef(data)

    menuList[1] = menuList[1] or {}
    table.insert(menuList[1], {
        text = "|cFF66CCFFElitism EPGP|r",
        isTitle = true,
        divider = true,
    })
    table.insert(menuList[1], {
        text = hasOverride and "Edit GP override..." or "Set GP override...",
        func = function() openSetGPPopup(normalID, link, scaleRef, tokenDataID) end,
    })
    if hasOverride then
        local kind = addon.Prices:GetOverrideKind(normalID)
        local valueText = ""
        if kind == "gp" then
            valueText = string.format(" |cFFAAAAAA(%d GP)|r",
                addon.Prices:GetOverride(normalID) or 0)
        end
        table.insert(menuList[1], {
            text = "Clear GP override" .. valueText,
            func = function()
                addon.Prices:ClearTierOverrides(normalID)
                if tokenDataID then
                    clearTokenPieceFanOut(tokenDataID)
                end
                if addon.Print then
                    addon.Print(string.format("Cleared GP override: %s", link))
                end
            end,
        })
    end
end

------------------------------------------------------------
-- Init: wire the hooks once AtlasLoot is loaded
------------------------------------------------------------

function AtlasLootHook:Init()
    if self._hooked then return end
    local atl = getAtlasLoot()
    if not atl then return end

    -- 1) Preserve source itemID before AtlasLoot's CloneTable overwrites it.
    if type(atl.GetItemConditionals) == "function" then
        hooksecurefunc(atl, "GetItemConditionals", function(self, item)
            if item and item.itemID then
                item._eepgpSourceID = item.itemID
            end
        end)
    end

    -- 2) Wrap ItemContextMenu so we can inject menu entries before the
    --    dewdrop is rendered. Restore the original OpenDewdropMenu in a
    --    finally-style block so partial failure doesn't leave the wrapper
    --    permanently installed.
    if type(atl.ItemContextMenu) == "function" then
        local origItemContextMenu = atl.ItemContextMenu
        atl.ItemContextMenu = function(self, data, Type, recipeData)
            local origOpen = self.OpenDewdropMenu
            self.OpenDewdropMenu = function(s, frame, menuList, ...)
                injectMenuEntries(menuList, data)
                s.OpenDewdropMenu = origOpen
                return origOpen(s, frame, menuList, ...)
            end
            local ok, err = pcall(origItemContextMenu, self, data, Type, recipeData)
            self.OpenDewdropMenu = origOpen
            if not ok and addon.Print then
                addon.Print("|cFFFF6060AtlasLoot menu hook error:|r " .. tostring(err))
            end
        end
    end

    -- 3) Register the token resolver with Prices so tokens without an
    --    explicit override auto-price from the tier piece's formula GP.
    --    The token map is built lazily on first lookup (sibling AtlasLoot
    --    data addons may not have loaded yet at this point).
    if addon.Prices and addon.Prices.RegisterTokenResolver then
        addon.Prices:RegisterTokenResolver(resolveTokenPiece)
    end

    self._hooked = true
end
