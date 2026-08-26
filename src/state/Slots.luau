--!strict
--!optimize 2
-- A run of ascending slots: the count, the width its steps take, and the steps themselves.

local Bits = require ("@src/kernel/Bits")
local Bytes = require ("@src/wire/Bytes")
local Fieldset = require ("@src/state/Fieldset")
local Leaf = require ("@src/shape/emit/Leaf")
local Protocol = require ("@src/wire/Protocol")
local Varint = require ("@src/wire/Varint")

local Slots = {}

-- Constants -----------------------------------------------------------

-- Bits in a byte, which a bound counted in one is measured against.
const BYTE = Protocol.BYTE_BITS

-- How many widths the count shares its number with, and the widest of them worth packing at.
const SPANS = 8
const NARROW = SPANS - 1

-- Types ---------------------------------------------------------------

-- What a run refuses under, which the lane that carries one words for itself.
export type Said = {
    read many: string,
    read order: string,
    read pad: string,
}

-- Public --------------------------------------------------------------

--[[
    A count and the slots under it. The first slot as it stands and the rest as the step from the
    one before, packed at the width the widest of them needs, since a partition moving together
    steps by one and that is a bit a record where a varint could not have spent under a byte. A
    list too spread out to gain by it falls back to varints, under a width of nothing.
]]
function Slots.wrote (
    b: buffer,
    at: number,
    slots: { number },
    steps: { number },
    count: number
): number
    local widest = 0
    for index = 2, count do
        local step = slots[index] - slots[index - 1]

        steps[index - 1] = step
        if step > widest then widest = step end
    end

    local width = Bits.width (widest)
    if width > NARROW or Bytes.whole ((count - 1) * width) >= count - 1 then width = 0 end

    local held = Varint.write (b, at, count * SPANS + width)
    if count == 0 then return held end

    held = Varint.write (b, held, slots[1])
    if width ~= 0 then return Leaf.packed (b, held, width, count - 1, steps) end

    for index = 1, count - 1 do
        held = Varint.write (b, held, steps[index])
    end
    return held
end

--[[
    The same run, read back, and the count it came under.

    `least` is what the caller carries beside each slot in bits, so that a count claiming more
    records than the bytes left could hold is refused before anything is read for it.
]]
function Slots.read (
    b: buffer,
    at: number,
    slots: { number },
    steps: { number },
    least: number,
    said: Said
): (number, number)
    local carried, after = Varint.read (b, at)

    local width = carried % SPANS
    local count = (carried - width) // SPANS

    local spent = if width == 0 then count * BYTE else BYTE + (count - 1) * width
    local bits = count * least + (if count == 0 then 0 else spent)
    if bits > (buffer.len (b) - after) * BYTE then Fieldset.broken (said.many) end

    if count == 0 then return count, after end

    local first, held = Varint.read (b, after)
    if width == 0 then
        for index = 1, count - 1 do
            steps[index], held = Varint.read (b, held)
        end
    else
        local clean
        held, clean = Leaf.unpacked (b, held, width, count - 1, steps)
        if not clean then Fieldset.broken (said.pad) end
    end

    if first == 0 then Fieldset.broken (said.order) end
    slots[1] = first

    local last = first
    for index = 2, count do
        local step = steps[index - 1]
        if step == 0 then Fieldset.broken (said.order) end

        last += step
        slots[index] = last
    end

    return count, held
end

return table.freeze (Slots)
