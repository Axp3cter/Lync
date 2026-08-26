--!strict
--!optimize 2
-- The windows a run of bit fields is cut into, and where each field sits in them.

local Protocol = require ("@src/wire/Protocol")

local Words = {}

-- Constants -----------------------------------------------------------

const BYTE = Protocol.BYTE_BITS

-- The windows a run is cut into, widest first, in bytes.
const WIDE = 4
const PAIR = 2
const ONE = 1

-- Types ---------------------------------------------------------------

--[[
    A part carries its shift, which is how far up its field it starts, because the emitter places
    each piece of a straddling field independently and deriving the shift would make every piece
    depend on the one before it.
]]
export type Part = {
    read field: number,
    read offset: number,
    read width: number,
    read shift: number,
}

export type Word = {
    read bytes: number,
    read at: number,
    read parts: { Part },
}

-- Public --------------------------------------------------------------

-- The same three widths, named for whoever else lays a run down.
Words.WIDE = WIDE
Words.PAIR = PAIR
Words.ONE = ONE

-- The widest window the bits still fill, then the next, and a single byte for the remainder.
function Words.plan (widths: { number }): { Word }
    local count = #widths

    local left = 0
    for _, width in widths do
        left += width
    end

    local plan: { Word } = {}
    local field, placed, at = 1, 0, 0

    while left > 0 do
        --[[
            The widest window the bytes still to come would fill, counted in whole bytes rather
            than in bits. Counting bits takes a narrower window than the same bytes would hold, so
            a field that fits one window is cut across two and neither half is the whole of it.
        ]]
        local whole = (left + BYTE - 1) // BYTE
        local bytes = if whole >= WIDE then WIDE elseif whole >= PAIR then PAIR else ONE
        local room = bytes * BYTE

        local parts: { Part } = {}
        local offset = 0

        while offset < room and field <= count do
            local rest = widths[field] - placed
            if rest == 0 then
                field, placed = field + 1, 0
                continue
            end

            local width = math.min (rest, room - offset)
            table.insert (parts, { field = field, offset = offset, width = width, shift = placed })

            offset += width
            placed += width
            if placed == widths[field] then
                field, placed = field + 1, 0
            end
        end

        table.insert (plan, { bytes = bytes, at = at, parts = parts })
        at += bytes
        left -= room
    end

    return plan
end

return table.freeze (Words)
