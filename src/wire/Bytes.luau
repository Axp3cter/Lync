--!strict
--!optimize 2
-- How a buffer holds things: a field at a bit, the order two ranges compare in, and a seal.

local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Bytes = {}

-- Constants -----------------------------------------------------------

-- Bytes in the wide word, whichever of its two carriers this build got.
const STRIDE = 8

const BYTE = Protocol.BYTE_BITS

-- Public --------------------------------------------------------------

-- A run of bits as the whole bytes that hold it, rounded up.
function Bytes.whole (bits: number): number return math.ceil (bits / BYTE) end

-- One value of `width` bits at a bit offset, and the offset past it.
function Bytes.put (b: buffer, at: number, width: number, value: number): number
    local held = at
    local left = width
    local of = value

    --[[
        A value that lands inside the byte it starts in, which most of them are: a flag is one bit
        and a small field a few, and a region lays them where the last one left off. The walk below
        carries what a value spilling over the end needs and none of it answers for one that does
        not spill.
    ]]
    local into = at % BYTE
    if width ~= 0 and into + width <= BYTE then
        local byte = at // BYTE
        local was = if into == 0 then 0 else buffer.readu8 (b, byte)

        buffer.writeu8 (
            b,
            byte,
            bit32.bor (was, bit32.lshift (bit32.extract (value, 0, width), into))
        )
        return at + width
    end

    while left > 0 do
        local byte = held // BYTE
        local shift = held % BYTE
        local room = BYTE - shift
        local step = if left < room then left else room

        local was = if shift == 0 then 0 else buffer.readu8 (b, byte)
        local piece = bit32.lshift (bit32.extract (of, 0, step), shift)
        buffer.writeu8 (b, byte, bit32.bor (was, piece))

        of = bit32.rshift (of, step)
        held += step
        left -= step
    end

    return at + width
end

--[[
    The same value back, and the offset past it. A width of nothing is a value of nothing, which is
    what a ranged int over one possibility is, and it reads no byte at all.
]]
function Bytes.take (b: buffer, at: number, width: number): (number, number)
    local of = 0
    local held = at
    local left = width
    local got = 0

    -- Read in one go where it lies inside one byte, for the reason the laying half takes it so.
    local from = at % BYTE
    if width ~= 0 and from + width <= BYTE then
        return bit32.extract (buffer.readu8 (b, at // BYTE), from, width), at + width
    end

    while left > 0 do
        local byte = held // BYTE
        local shift = held % BYTE
        local room = BYTE - shift
        local step = if left < room then left else room

        local piece = bit32.extract (buffer.readu8 (b, byte), shift, step)
        of = bit32.bor (of, bit32.lshift (piece, got))

        got += step
        held += step
        left -= step
    end

    return of, at + width
end

-- The byte a bit run ends on, and whether what it left above itself is zero.
function Bytes.aligned (b: buffer, at: number): (number, boolean)
    local over = at % BYTE
    if over == 0 then return at // BYTE, true end

    local pad = bit32.rshift (buffer.readu8 (b, at // BYTE), over)
    return at // BYTE + 1, pad == 0
end

--[[
    A run of bytes as the one number they order by, which is what they spell read first byte first.
    Narrow enough that a caller may carry something else under it and have every bit survive a
    double, since a rounded number answers something other than what the bytes would have.
]]
const RANKED = 4

-- Two, which is what a leading number reaches past the four a caller may ride under.
const PAIR = 2

-- How many bytes of a range one number holds, which is what a double spells without losing any.
const LEADING = RANKED + PAIR

function Bytes.ranks (len: number): boolean return len <= RANKED end

-- How wide a leading number reaches, for a caller holding two it has already found equal.
Bytes.LEADING = LEADING

--[[
    What a range shorter than the whole width is scaled by, so the bytes it does not have count as
    nothing under the ones it does. A width has only as many answers as it has bytes, so all of
    them are made once and a key asks for one.
]]
const SCALE = table.create (LEADING + 1) :: { number }
for step = 0, LEADING do
    SCALE[step + 1] = 2 ^ (step * BYTE)
end

table.freeze (SCALE)

--[[
    The first bytes of a range as one number, padded with nothing where the range holds fewer. Two
    of these order the ranges the way the ranges themselves order, as far as they reach, so a sort
    may ask them first and reach for the whole comparison only where a pair of them ties.
]]
@native
function Bytes.leading (b: buffer, at: number, len: number): number
    --[[
        A range wide enough to fill the width, spelled out. How many bytes go in is settled by the
        width and not by the range, so the walk that gathered them was counting to a number this
        already knows, and every step of it asked whether the range had reached its end.
    ]]
    if len >= LEADING then
        local sum = buffer.readu8 (b, at)
        sum = sum * 256 + buffer.readu8 (b, at + 1)
        sum = sum * 256 + buffer.readu8 (b, at + PAIR)
        sum = sum * 256 + buffer.readu8 (b, at + PAIR + 1)
        sum = sum * 256 + buffer.readu8 (b, at + RANKED)
        return sum * 256 + buffer.readu8 (b, at + RANKED + 1)
    end

    -- A shorter one, taken as it stands and put where its own bytes sit under a wider one's.
    local sum = 0
    for step = 0, len - 1 do
        sum = sum * 256 + buffer.readu8 (b, at + step)
    end

    return sum * SCALE[LEADING - len + 1]
end

@native
function Bytes.ranked (b: buffer, at: number, len: number): number
    local sum = 0
    for step = 0, len - 1 do
        sum = sum * 256 + buffer.readu8 (b, at + step)
    end

    return sum
end

--[[
    The swap makes the word compare a byte compare: a read takes the first byte as the least of the
    word, and reversing it spells the magnitude the bytes read as. A word is taken only where a
    whole one remains inside the shorter range, because the bytes past it are not ours. Never
    through a float, where plus and minus zero are equal and one NaN payload is unequal.
]]
@native
function Bytes.rangeLess (b: buffer, atA: number, lenA: number, atB: number, lenB: number): boolean
    local shared = math.min (lenA, lenB)
    local words = shared - shared % STRIDE
    local at = 0

    while at < words do
        local same, below = Wide.ordering (b, atA + at, atB + at)
        if not same then return below end
        at += STRIDE
    end

    while at < shared do
        local byteA = buffer.readu8 (b, atA + at)
        local byteB = buffer.readu8 (b, atB + at)
        if byteA ~= byteB then return byteA < byteB end
        at += 1
    end

    return lenA < lenB
end

-- A copy rather than the scratch, because the next block encodes into that same scratch.
function Bytes.seal (scratch: buffer, length: number): buffer
    local sealed = buffer.create (length)
    buffer.copy (sealed, 0, scratch, 0, length)
    return sealed
end

return table.freeze (Bytes)
