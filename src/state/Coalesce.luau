--!strict
--!optimize 2
-- One record's mutations across a flush: the net effect that ships, and the fields it named.

local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Coalesce = {}

-- State ---------------------------------------------------------------

--[[
    The two word operations a mask asks for, under their own names. `Wide` picks its carrier once
    when it loads, so both are the same function for the life of the place and naming them here
    is a lookup every field of every write would otherwise make.
]]
const MEETS = Wide.meets
const UNION = Wide.union

--[[
    Every field's own bit, worked out once for the whole run of the library. A field's bit is a
    constant of its place and nothing else, and the one home for what that constant is answers a
    call and a lookup deep, which is a price a mask pays on every field of every write.
]]
local BITS: { Wide.Word } = table.create (Protocol.MAX_FIELDS)
for field = 1, Protocol.MAX_FIELDS do
    BITS[field] = Wide.bit (field)
end

table.freeze (BITS)

-- Types ---------------------------------------------------------------

--[[
    What an entry has pending. `replace` is produced and never taken: an add onto a removal is a new
    record under an old id, and a receiver has to be told the one it holds is gone before it is
    handed another.
]]
export type Kind = "add" | "update" | "remove" | "replace"

-- Public --------------------------------------------------------------

--[[
    Nothing pending takes whatever came. An update never changes what an entry is, since a keyframe
    already states every field and a delta is still a delta. An add can only follow a removal, which
    is a replace. A remove ends the entry, and ends it as nothing where the add it cancels never
    reached anybody.
]]
function Coalesce.merge (was: Kind?, took: Kind): Kind?
    if was == nil then return took end
    if took == "update" then return was end
    if took == "add" then return "replace" end
    return if was == "add" then nil else "remove"
end

function Coalesce.touched (mask: Wide.Word, field: number): Wide.Word
    return UNION (mask, BITS[field])
end

-- Tested bit by bit and never read as a number, because the widest field is the sign.
function Coalesce.migrates (mask: Wide.Word, key: number?): boolean
    if key == nil then return false end

    return MEETS (mask, BITS[key])
end

return table.freeze (Coalesce)
