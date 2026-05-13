local _, addon = ...

local Prices = {}
addon.Prices = Prices

-- Sinensis-style formula: GP = base × slotMult × 2^((ilvl − standard) / 26).
-- Per-item override (DB.global.prices[itemID]) wins over the formula.

local function dbGlobal()
    return addon.DB and addon.DB.global
end

local function ensurePrices()
    local g = dbGlobal()
    if g and not g.prices then g.prices = {} end
    return g and g.prices
end

------------------------------------------------------------------------
-- Item identity helpers
------------------------------------------------------------------------

-- Extracts itemID from an item link or a plain numeric string.
function Prices:ItemIDFromLink(linkOrID)
    if not linkOrID then return nil end
    if type(linkOrID) == "number" then return linkOrID end
    local n = tonumber(linkOrID)
    if n then return n end
    local id = tostring(linkOrID):match("item:(%d+)")
    return id and tonumber(id) or nil
end

-- Returns { itemID, name, link, ilvl, quality, icon, equipLoc } from any
-- item link/ID, or nil if the client doesn't have the item info cached yet.
-- equipLoc is the slot key like "INVTYPE_HEAD" used to look up the slot
-- multiplier; "" for non-equippable items.
function Prices:Describe(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    if not id then return nil end
    local name, link, quality, ilvl, _, _, _, _, equipLoc, icon = GetItemInfo(id)
    if not name then return nil end
    return {
        itemID   = id,
        name     = name,
        link     = link or linkOrID,
        ilvl     = ilvl or 0,
        quality  = quality or 0,
        icon     = icon,
        equipLoc = equipLoc or "",
    }
end

------------------------------------------------------------------------
-- Formula
------------------------------------------------------------------------

-- SlotMultiplier: returns the configured multiplier for a slot key, or the
-- default if the officer hasn't customized it. Unknown slots → 1.0 (treated
-- as torso-tier; safer than 0).
function Prices:SlotMultiplier(equipLoc)
    if not equipLoc or equipLoc == "" then return 1.0 end
    local g = dbGlobal()
    local override = g and g.slotMultipliers and g.slotMultipliers[equipLoc]
    if override ~= nil then return override end
    local default = addon.DEFAULT_SLOT_MULTIPLIERS and addon.DEFAULT_SLOT_MULTIPLIERS[equipLoc]
    return default or 1.0
end

function Prices:Compute(ilvl, equipLoc)
    local g = dbGlobal() or {}
    local base     = g.basegp                or addon.VARS.basegp                or 100
    local standard = g.gpFormulaStandardIlvl or addon.VARS.gpFormulaStandardIlvl or 264
    local doubling = g.gpFormulaDoublingIlvl or addon.VARS.gpFormulaDoublingIlvl or 26
    local ilvlNum  = tonumber(ilvl) or standard
    local mult     = self:SlotMultiplier(equipLoc)
    local gp = base * mult * (2 ^ ((ilvlNum - standard) / doubling))
    return math.max(1, math.floor(gp + 0.5))
end

function Prices:OffSpecGP(mainspecGP)
    local g = dbGlobal() or {}
    local m = g.osMultiplier or addon.VARS.osMultiplier or 0.10
    return math.max(0, math.floor((tonumber(mainspecGP) or 0) * m + 0.5))
end

------------------------------------------------------------------------
-- Per-item overrides
------------------------------------------------------------------------

-- Each override entry is one of two mutually exclusive shapes:
--   { gp = N, ts, by [, scaleAsItemID] }      — direct GP override
--   { linkedItemID = X, ts, by [, scaleAsItemID] }  — price-as-this-other-item
-- HasOverride returns true if either field is set; GetOverrideKind tells
-- callers which mode applies.
--
-- scaleAsItemID is an optional "scale this item as if it had THAT item's
-- ilvl". Used for tier tokens — the token itself shares one ilvl across
-- difficulty variants, but the tier piece it converts to differs per
-- difficulty. Storing the tier piece's id here makes the linked-variant
-- ilvl scaling produce the right number for each token difficulty.
-- Regular items leave scaleAsItemID nil and use their own ilvl.

function Prices:HasOverride(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p or not p[id] then return false end
    return p[id].gp ~= nil or p[id].linkedItemID ~= nil
end

function Prices:GetOverrideKind(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p or not p[id] then return nil end
    if p[id].gp           ~= nil then return "gp"     end
    if p[id].linkedItemID ~= nil then return "linked" end
    return nil
end

-- Returns the direct GP override for an item, or nil if it's not in
-- "gp" mode. (Linked overrides return nil here — use GetGP to resolve.)
function Prices:GetOverride(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p or not p[id] or p[id].gp == nil then return nil end
    return p[id].gp, p[id].ts, p[id].by
end

function Prices:GetLinkedOverride(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p or not p[id] or p[id].linkedItemID == nil then return nil end
    return p[id].linkedItemID, p[id].ts, p[id].by
end

-- Returns the item whose ilvl should be used for scaling this entry, if
-- one was set (typically the tier piece a token converts to). nil means
-- "use this item's own ilvl".
function Prices:GetScaleAsItemID(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p or not p[id] then return nil end
    return p[id].scaleAsItemID
end

local function effectiveIlvl(self, id)
    local scaleAs = self:GetScaleAsItemID(id)
    if scaleAs then
        local desc = self:Describe(scaleAs)
        if desc and desc.ilvl and desc.ilvl > 0 then return desc.ilvl end
    end
    local desc = self:Describe(id)
    return desc and desc.ilvl or nil
end

function Prices:SetOverride(linkOrID, gp, by, scaleAsItemID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p then return false, "DB not ready" end
    gp = tonumber(gp)
    if not gp or gp < 0 then return false, "invalid gp" end
    -- Preserve existing scaleAsItemID when caller passes nil (so a manual
    -- price edit doesn't accidentally drop a token's tier-piece reference).
    if scaleAsItemID == nil and p[id] then scaleAsItemID = p[id].scaleAsItemID end
    p[id] = {
        gp            = gp,
        scaleAsItemID = scaleAsItemID or nil,
        ts            = time(),
        by            = by or UnitName("player"),
    }
    if addon.Sync then addon.Sync:Notify("prices", id) end
    return true
end

function Prices:SetLinkedOverride(linkOrID, linkedItemID, by, scaleAsItemID)
    local id     = self:ItemIDFromLink(linkOrID)
    local linkID = self:ItemIDFromLink(linkedItemID)
    local p  = ensurePrices()
    if not id or not p then return false, "DB not ready" end
    if not linkID then return false, "invalid linked item" end
    if id == linkID then return false, "cannot link an item to itself" end
    if scaleAsItemID == nil and p[id] then scaleAsItemID = p[id].scaleAsItemID end
    p[id] = {
        linkedItemID  = linkID,
        scaleAsItemID = scaleAsItemID or nil,
        ts            = time(),
        by            = by or UnitName("player"),
    }
    if addon.Sync then addon.Sync:Notify("prices", id) end
    return true
end

function Prices:ClearOverride(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    local p  = ensurePrices()
    if not id or not p then return false end
    p[id] = nil
    if addon.Sync then addon.Sync:Notify("prices", id) end
    return true
end

-- Difficulties we fan out to: 1=Bloodforged, 2=Heroic Bloodforged,
-- 4=Heroic, 5=Mythic, 6=Ascended. 3=Normal is the base (skip).
local TIER_DIFFICULTIES = { 1, 2, 4, 5, 6 }

-- Sets a direct GP override on the Normal-difficulty itemID and creates
-- linked overrides on each variant difficulty pointing back to it. The
-- Linked path applies ilvl scaling at lookup time, so officers only need
-- to set one price per item-group; Heroic/Mythic/Ascended/Bloodforged
-- variants auto-derive.
--
-- scaleAsNormalItemID (optional): for tier tokens — the Normal-difficulty
-- itemID of the converted tier piece. The fan-out then expands this per
-- difficulty so each token variant scales as its corresponding tier piece
-- ilvl rather than the token's own (flat) ilvl.
function Prices:SetTierBaseOverride(normalItemID, gp, by, scaleAsNormalItemID)
    local id = self:ItemIDFromLink(normalItemID)
    if not id then return false, "invalid item" end
    gp = tonumber(gp)
    if not gp or gp < 0 then return false, "invalid gp" end
    local scaleNormal = self:ItemIDFromLink(scaleAsNormalItemID)

    -- If caller passed nil and we already had a scaleAs ref, preserve it.
    if scaleNormal == nil then
        local p = ensurePrices()
        scaleNormal = p and p[id] and p[id].scaleAsItemID or nil
    end

    local ok, err = self:SetOverride(id, gp, by, scaleNormal)
    if not ok then return ok, err end

    if type(GetItemDifficultyID) == "function" then
        for _, dif in ipairs(TIER_DIFFICULTIES) do
            local variantID = GetItemDifficultyID(id, dif)
            if variantID and variantID ~= 0 and variantID ~= id then
                local variantScaleAs = nil
                if scaleNormal then
                    local v = GetItemDifficultyID(scaleNormal, dif)
                    variantScaleAs = (v and v ~= 0) and v or scaleNormal
                end
                self:SetLinkedOverride(variantID, id, by, variantScaleAs)
            end
        end
    end
    return true
end

-- Removes the direct override on the Normal id AND every linked variant
-- created by SetTierBaseOverride. Safe to call even if no overrides exist.
function Prices:ClearTierOverrides(normalItemID)
    local id = self:ItemIDFromLink(normalItemID)
    if not id then return false end
    self:ClearOverride(id)
    if type(GetItemDifficultyID) == "function" then
        for _, dif in ipairs(TIER_DIFFICULTIES) do
            local variantID = GetItemDifficultyID(id, dif)
            if variantID and variantID ~= 0 and variantID ~= id then
                self:ClearOverride(variantID)
            end
        end
    end
    return true
end

------------------------------------------------------------------------
-- Token resolvers (external integrations, e.g. AtlasLoot)
------------------------------------------------------------------------
-- An item with no explicit override but recognized as a token (tier set
-- tokens that convert to a class-specific piece) can be auto-priced via
-- a resolver: given a token itemID, the resolver returns the converted
-- piece's itemID; GetGP then prices the token by the piece's formula GP
-- (its real ilvl + equipLoc, including slot multiplier). Keeps Prices
-- decoupled from AtlasLoot internals — any module can register a resolver.

local tokenResolvers = {}

function Prices:RegisterTokenResolver(fn)
    if type(fn) == "function" then
        table.insert(tokenResolvers, fn)
    end
end

-- Returns the converted piece itemID for a token, or nil. Walks all
-- registered resolvers until one returns a hit.
function Prices:ResolveToken(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    if not id then return nil end
    for _, fn in ipairs(tokenResolvers) do
        local ok, piece = pcall(fn, id)
        if ok and piece then return piece end
    end
    return nil
end

-- True if this item resolves to a price: explicit override OR auto-token.
-- Tooltip gating uses this so tokens (empty equipLoc) still render a GP
-- line when a resolver knows the converted piece.
function Prices:HasResolution(linkOrID)
    if self:HasOverride(linkOrID) then return true end
    return self:ResolveToken(linkOrID) ~= nil
end

------------------------------------------------------------------------
-- Public API: GetGP returns the canonical mainspec cost for an item,
-- preferring override > linked > token-auto > formula. Returns
-- (gp, source) where source is one of:
--   "override" | "linked" | "auto" | "formula" | "unknown"
------------------------------------------------------------------------

-- Resolves the canonical mainspec GP for an item. Walks linked overrides
-- transitively (max 5 hops) and applies ilvl scaling at each hop:
-- a Heroic variant linked to its Normal sibling returns the Normal price
-- scaled up by the ilvl ratio, so tier variants auto-derive without the
-- officer setting six prices per item. Tokens fall back to a registered
-- resolver (typically AtlasLoot → tier piece) for zero-config pricing.
function Prices:GetGP(linkOrID)
    local id = self:ItemIDFromLink(linkOrID)
    if not id then return 0, "unknown" end

    local kind = self:GetOverrideKind(id)
    if kind == "gp" then
        return self:GetOverride(id), "override"
    end

    -- Walk the link chain, then evaluate the tail item's GP and scale it
    -- back to the original by the ilvl difference.
    if kind == "linked" then
        local visited = { [id] = true }
        local cur = id
        for hop = 1, 5 do
            local linked = self:GetLinkedOverride(cur)
            if not linked or visited[linked] then break end
            visited[linked] = true
            cur = linked
            if self:GetOverrideKind(cur) ~= "linked" then break end
        end
        local tailDesc = self:Describe(cur)
        if not tailDesc then return 0, "unknown" end
        local tailGP
        if self:GetOverrideKind(cur) == "gp" then
            tailGP = self:GetOverride(cur)
        else
            tailGP = self:Compute(tailDesc.ilvl, tailDesc.equipLoc)
        end
        -- Use the per-entry scaleAsItemID if set (tier tokens point at
        -- their tier piece, which has the proper per-difficulty ilvl).
        -- Falls back to the entry's own ilvl when scaleAsItemID is nil.
        local thisIlvl = effectiveIlvl(self, id)
        local tailIlvl = effectiveIlvl(self, cur)
        if not thisIlvl or not tailIlvl or thisIlvl == tailIlvl then
            return tailGP, "linked"
        end
        local g        = dbGlobal() or {}
        local doubling = g.gpFormulaDoublingIlvl or addon.VARS.gpFormulaDoublingIlvl or 26
        local scaled   = tailGP * (2 ^ ((thisIlvl - tailIlvl) / doubling))
        return math.max(1, math.floor(scaled + 0.5)), "linked"
    end

    -- Token auto-resolve: no override, but a registered resolver maps
    -- this item to a piece (e.g., tier token → tier piece). Price by the
    -- piece's formula GP using the piece's real ilvl + equipLoc, so the
    -- token inherits the right slot multiplier and per-difficulty ilvl.
    local pieceID = self:ResolveToken(id)
    if pieceID then
        local pieceDesc = self:Describe(pieceID)
        if pieceDesc and pieceDesc.equipLoc and pieceDesc.equipLoc ~= "" then
            return self:Compute(pieceDesc.ilvl, pieceDesc.equipLoc), "auto"
        end
    end

    -- No override — formula on this item.
    local desc = self:Describe(id)
    if not desc then return 0, "unknown" end
    return self:Compute(desc.ilvl, desc.equipLoc), "formula"
end

------------------------------------------------------------------------
-- Sync integration: register the "prices" domain with addon.Sync so
-- overrides replicate across the guild via per-key LWW. Called once
-- from Core.OnEnable. Existing entries (from before sync) are stamped
-- into Sync's metadata table so they participate in REQ/FULL exchanges.
------------------------------------------------------------------------

function Prices:RegisterSyncDomain()
    if not (addon.Sync and addon.Sync.RegisterDomain) then return end
    addon.Sync:RegisterDomain("prices", {
        get = function(key)
            local id = tonumber(key)
            local p = ensurePrices()
            return id and p and p[id] or nil
        end,
        set = function(key, value)
            local id = tonumber(key)
            local p = ensurePrices()
            if not id or not p then return end
            if value == nil or type(value) ~= "table" then
                p[id] = nil
            else
                p[id] = value
            end
        end,
        iter = function()
            local p = ensurePrices()
            if not p then return function() return nil end end
            local key
            return function()
                key = next(p, key)
                return key and tostring(key) or nil
            end
        end,
    })

    -- One-time migration: stamp existing entries so they're included in
    -- bootstrap exchanges (idempotent — never overwrites a newer ts).
    local g = dbGlobal()
    if not g or not g.prices then return end
    g._sync = g._sync or { ts = {}, bootstrapped = false }
    g._sync.ts = g._sync.ts or {}
    for id, entry in pairs(g.prices) do
        if type(entry) == "table" and entry.ts then
            local path = "prices:" .. tostring(id)
            local existing = g._sync.ts[path]
            if not existing or (existing.ts or 0) < entry.ts then
                g._sync.ts[path] = { ts = entry.ts, by = entry.by or "?" }
            end
        end
    end
end
