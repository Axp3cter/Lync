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
    The width a run of numbers packs at, or nothing where packing would not pay for itself. A
    varint cannot spend under the byte it is, so anything narrower wins and anything wider is
    left to varints. Both sides are told the width rather than work it out, since only a writer
    ever sees every value of a run at once.
]]
function Slots.width (run: { number }, count: number): number
    local widest = 0
    for index = 1, count do
        local value = run[index]
        if value > widest then widest = value end
    end

    local width = Bits.width (widest)
    if width > NARROW or Bytes.whole (count * width) >= count then return 0 end

    return width
end

-- A run of numbers at the width its writer chose, or the varints it fell back to.
function Slots.laid (b: buffer, at: number, run: { number }, count: number, width: number): number
    if width ~= 0 then return Leaf.packed (b, at, width, count, run) end

    local held = at
    for index = 1, count do
        held = Varint.write (b, held, run[index])
    end
    return held
end

-- The same run back, and whether what the packing left over was the zero it has to be.
function Slots.taken (
    b: buffer,
    at: number,
    run: { number },
    count: number,
    width: number
): (number, boolean)
    if width ~= 0 then return Leaf.unpacked (b, at, width, count, run) end

    local held = at
    for index = 1, count do
        run[index], held = Varint.read (b, held)
    end
    return held, true
end

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
    for index = 2, count do
        steps[index - 1] = slots[index] - slots[index - 1]
    end

    local width = Slots.width (steps, count - 1)
    local held = Varint.write (b, at, count * SPANS + width)
    if count == 0 then return held end

    held = Varint.write (b, held, slots[1])
    return Slots.laid (b, held, steps, count - 1, width)
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

    local clean
    held, clean = Slots.taken (b, held, steps, count - 1, width)
    if not clean then Fieldset.broken (said.pad) end

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
