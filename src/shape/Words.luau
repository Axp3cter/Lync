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

-- How many bytes a plan comes to, which is what decides between two of them.
local function spent (plan: { Word }): number
    local bytes = 0
    for _, window in plan do
        bytes += window.bytes
    end
    return bytes
end

--[[
    A run laid out without cutting a field in two where a later one would have fitted in its place.
    A field in one piece is a field the emitter reads and writes whole, so this is the plan worth
    having wherever it costs nothing, and the bits it leaves behind are what can make it cost.
]]
local function fitted (widths: { number }): { Word }
    local count = #widths
    local placed = table.create (count, 0)

    local left = 0
    for _, width in widths do
        left += width
    end

    local plan: { Word } = {}
    local at = 0

    while left > 0 do
        local whole = (left + BYTE - 1) // BYTE
        local bytes = if whole >= WIDE then WIDE elseif whole >= PAIR then PAIR else ONE
        local room = bytes * BYTE

        local parts: { Part } = {}
        local offset = 0

        -- Whatever still fits whole, in the order it was declared, so nothing is cut that need not.
        for index = 1, count do
            local rest = widths[index] - placed[index]
            if rest == 0 or rest > room - offset then continue end

            table.insert (parts, {
                field = index,
                offset = offset,
                width = rest,
                shift = placed[index],
            })

            offset += rest
            placed[index] = widths[index]
            left -= rest
        end

        --[[
            Nothing fitting means what is left is wider than any room this window had, so it is cut
            after all. Without this the walk would open window after window and place nothing.
        ]]
        if #parts == 0 then
            for index = 1, count do
                local rest = widths[index] - placed[index]
                if rest == 0 then continue end

                local width = math.min (rest, room)
                table.insert (parts, {
                    field = index,
                    offset = 0,
                    width = width,
                    shift = placed[index],
                })

                placed[index] += width
                left -= width
                break
            end
        end

        table.insert (plan, { bytes = bytes, at = at, parts = parts })
        at += bytes
    end

    return plan
end

-- The widest window the bits still fill, then the next, and a single byte for the remainder.
local function cutting (widths: { number }): { Word }
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

--[[
    Whichever of the two spends fewer bytes, and the one that cuts nothing where they tie. Both are
    worked out here because which is smaller is a question about the widths and not about either
    rule, and a schema is laid out once where a frame is written for as long as it runs.
]]
function Words.plan (widths: { number }): { Word }
    local cut = cutting (widths)
    local whole = fitted (widths)

    return if spent (whole) <= spent (cut) then whole else cut
end

return table.freeze (Words)
