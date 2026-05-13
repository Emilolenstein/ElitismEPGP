local _, addon = ...

local Storage = {}
addon.Storage = Storage

local FORMAT      = "%d:%d"
local PATTERN     = "^(%d+):(%d+)$"
local ALT_PATTERN = "^=(%S+)$"
local NOTE_LIMIT  = 31

function Storage:Encode(ep, gp)
    ep = math.max(0, math.floor(tonumber(ep) or 0))
    gp = math.max(0, math.floor(tonumber(gp) or 0))
    return string.format(FORMAT, ep, gp)
end

function Storage:EncodeAlt(mainName)
    return "=" .. mainName
end

function Storage:Decode(note)
    if type(note) ~= "string" or note == "" then return 0, 0, "self" end
    local ep, gp = note:match(PATTERN)
    if ep then return tonumber(ep), tonumber(gp), "self" end
    local main = note:match(ALT_PATTERN)
    if main then return 0, 0, "alt", main end
    return 0, 0, "self"
end

function Storage:WillFit(ep, gp)
    return #self:Encode(ep, gp) <= NOTE_LIMIT
end

function Storage:WillFitAlt(mainName)
    return #self:EncodeAlt(mainName) <= NOTE_LIMIT
end

function Storage:NoteLimit()
    return NOTE_LIMIT
end
