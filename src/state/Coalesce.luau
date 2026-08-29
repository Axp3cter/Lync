--!strict
--!optimize 2
-- One record's mutations across a flush: the net effect that ships, and the fields it named.

local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Coalesce = {}

-- Constants -----------------------------------------------------------

--[[
    The two word operations a mask asks for, under their own names. `Wide` settles its carrier when
    it loads, so both stay the same function for the life of the place, and naming them here spares
    a lookup on every field of every write.
]]
const MEETS = Wide.meets
const UNION = Wide.union

--[[
    Every field's own bit, worked out once for the run of the library. A field's bit never moves,
    and asking for it costs a call and a lookup that a mask would otherwise pay on every field of
    every write.
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
    Nothing pending takes whatever came. An update never changes what an entry is, a keyframe
    already stating every field and a delta still being a delta. An add can only follow a removal,
    so it replaces. A remove ends the entry, and ends it as nothing where the add it cancels never
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
