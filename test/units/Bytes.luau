--!strict
--!optimize 2
--[[
    The byte leaves alone: the order two ranges compare in, and what a sealed block keeps.
]]

local Bytes = require ("@src/wire/Bytes")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Protocol = require ("@src/wire/Protocol")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

-- The bytes one word of the compare covers, which is where its edges are.
const STRIDE = 8

-- The longest range a case lays down or a draw asks for: two words and a tail.
const MOST = 20

--[[
    Bits in a byte, and the widest field a draw asks for.

    The second is the run ceiling, which is a wire fact and is read from the module that owns it
    rather than written again here. Eight is not: it is what a byte is, everywhere.
]]
const BYTE = 8
const WIDEST = Protocol.BIT_CEILING

--[[
    The stride a filled range walks its bytes by. Odd, so multiplying by it modulo 256 is a
    permutation and the longest range a case lays down holds no byte twice. Large, so a range
    crosses 0x80 every few bytes.
]]
const APART = 61

-- Bytes the edges are made of, drawn far more often than chance would offer them.
const NOTABLE = table.freeze ({ 0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF })

-- What sits either side of a range in the buffer a case lays it into.
const AHEAD = 0xA5
const PAST_FIRST = 0xFF
const PAST_SECOND = 0x00

-- Private -------------------------------------------------------------

--[[
    A range of the given length, no two of its bytes equal, which a case bends one byte of. Cutting
    a longer one shorter leaves a prefix of it, and no two lengths hold the same bytes, so a compare
    that stopped early, read a byte twice, or read a word in the wrong order lands somewhere other
    than it meant.
]]
local function cut (length: number): { number }
    local out = table.create (length) :: { number }
    for index = 1, length do
        table.insert (out, (index * APART) % 256)
    end
    return out
end

local function spelled (bytes: { number }): string
    local parts = table.create (#bytes)
    for _, byte in bytes do
        table.insert (parts, string.format ("%02X", byte))
    end
    return table.concat (parts, " ")
end

--[[
    Both ranges laid into one buffer, each behind a byte of padding. The padding puts every range
    at an offset no stride can assume. The trailing bytes differ so that a compare reading past a
    range's length answers wrongly rather than agreeing by luck.
]]
local function laid (a: { number }, b: { number }): (buffer, number, number, number, number)
    local out = buffer.create (#a + #b + 4)
    local atB = #a + 3

    buffer.writeu8 (out, 0, AHEAD)
    for index, byte in a do
        buffer.writeu8 (out, index, byte)
    end
    buffer.writeu8 (out, #a + 1, PAST_FIRST)

    buffer.writeu8 (out, #a + 2, AHEAD)
    for index, byte in b do
        buffer.writeu8 (out, atB + index - 1, byte)
    end
    buffer.writeu8 (out, atB + #b, PAST_SECOND)

    return out, 1, #a, atB, #b
end

local function less (a: { number }, b: { number }): boolean
    local out, atA, lenA, atB, lenB = laid (a, b)
    return Bytes.rangeLess (out, atA, lenA, atB, lenB)
end

--[[
    The answer and the answer wanted, the second read off Luau's own string order, an unsigned
    byte-for-byte compare in C, which is the definition of the order rather than a second copy of
    the algorithm under test.
]]
local function ordered (
    out: buffer,
    atA: number,
    lenA: number,
    atB: number,
    lenB: number
): (boolean, boolean)
    local got = Bytes.rangeLess (out, atA, lenA, atB, lenB)
    return got, buffer.readstring (out, atA, lenA) < buffer.readstring (out, atB, lenB)
end

--[[
    Both ways round, because an order that answers true in both directions is not an order and a
    sort handed one walks off its array.
]]
local function agrees (a: { number }, b: { number })
    local out, atA, lenA, atB, lenB = laid (a, b)

    local first, wanted = ordered (out, atA, lenA, atB, lenB)
    if first ~= wanted then
        Expect.holds (false, `[{spelled (a)}] < [{spelled (b)}] answered {first}`)
    end

    local second, back = ordered (out, atB, lenB, atA, lenA)
    if second ~= back then
        Expect.holds (false, `[{spelled (b)}] < [{spelled (a)}] answered {second}`)
    end
end

local function byte (rng: Rng.Rng): number
    if Rng.bool (rng) then return Rng.pick (rng, NOTABLE) end
    return Rng.int (rng, 0, 0xFF)
end

--[[
    Two ranges that agree for a while and then do not, which is the only shape a compare has
    anything to do. Two drawn independently differ in their first byte almost always, and a stride
    whose second word and tail are never reached is a stride nothing has tested.
]]
local function pairing (rng: Rng.Rng): ({ number }, { number })
    local shared = Rng.int (rng, 0, MOST)

    local a = table.create (MOST) :: { number }
    for _ = 1, shared do
        table.insert (a, byte (rng))
    end

    local b = table.clone (a)
    for _ = 1, Rng.int (rng, 0, MOST - shared) do
        table.insert (a, byte (rng))
    end
    for _ = 1, Rng.int (rng, 0, MOST - shared) do
        table.insert (b, byte (rng))
    end
    return a, b
end

-- Public --------------------------------------------------------------

return {
    --[[
        A range of nothing. It comes before every range with a byte in it, nothing comes before it,
        and it does not come before itself. That last one also says the compare reads no byte it was
        not given, since a range of zero has none to read.
    ]]
    Harness.case ("bytes.empty", function ()
        Expect.equal (less ({}, {}), false)
        Expect.equal (less ({}, { 0x00 }), true)
        Expect.equal (less ({ 0x00 }, {}), false)
    end),

    --[[
        Bytes are magnitudes. A stride compared as a signed value reads a leading byte of 0x80 or
        above as negative and puts it first, and that byte is common: a `vlq` key carries the
        continuation bit in its first group, so every key of 128 or more begins above 0x7F.
    ]]
    Harness.case ("bytes.unsigned", function ()
        Expect.equal (less ({ 0x7F }, { 0x80 }), true)
        Expect.equal (less ({ 0x80 }, { 0x7F }), false)
        Expect.equal (less ({ 0x80 }, { 0xFF }), true)

        local low = table.create (STRIDE, 0)
        local high = table.create (STRIDE, 0)
        low[1] = 0x7F
        high[1] = 0x80

        Expect.equal (less (low, high), true)
        Expect.equal (less (high, low), false)
    end),

    --[[
        A value wider than the field laid for it, held to that field rather than let past its end.
        Bits are laid where the last one left off, so anything over the width would land on
        whatever comes next, and what comes next is somebody else's field.
    ]]
    Harness.case ("bytes.holds-a-value-to-its-width", function ()
        for width = 1, BYTE + 1 do
            for at = 0, BYTE do
                local b = buffer.create (STRIDE)
                local over = bit32.lshift (1, width + 2) - 1

                Expect.equal (Bytes.put (b, at, width, over), at + width)

                local got, after = Bytes.take (b, at, width)
                Expect.equal (got, bit32.extract (over, 0, width))
                Expect.equal (after, at + width)

                -- What lies past the field, which nothing has laid anything into yet.
                Expect.equal ((Bytes.take (b, at + width, BYTE)), 0)
            end
        end
    end),

    --[[
        Inside one word. One difference cannot show a reversed order, the other seven bytes
        agreeing so either reading decides on the same byte. Two can, and this pair is the
        smallest that does. The sweep is the other half: a difference at each of the eight.
    ]]
    Harness.case ("bytes.stride", function ()
        local front = table.create (STRIDE, 0)
        local back = table.create (STRIDE, 0)
        front[1] = 0x01
        back[2] = 0x01

        Expect.equal (less (front, back), false)
        Expect.equal (less (back, front), true)

        for position = 1, STRIDE do
            local low = cut (STRIDE)
            local high = cut (STRIDE)
            low[position] = 0x00
            high[position] = 0xFF

            Expect.equal (less (low, high), true)
            Expect.equal (less (high, low), false)
        end
    end),

    --[[
        Past the last whole word. Twelve bytes is one stride and a four-byte tail, so a compare that
        stops when the words run out calls every pair here equal, and a map of keys that long
        accepts any order of them.
    ]]
    Harness.case ("bytes.tail", function ()
        for position = STRIDE + 1, STRIDE + 4 do
            local low = cut (STRIDE + 4)
            local high = cut (STRIDE + 4)
            low[position] = 0x00
            high[position] = 0xFF

            Expect.equal (less (low, high), true)
            Expect.equal (less (high, low), false)
        end
    end),

    --[[
        A range that runs out first loses. The pairs cross the word boundary from both sides,
        because a compare that walks the shorter of the two and then forgets the lengths calls a
        prefix equal to what extends it, and two map keys that compare equal is a frame the decoder
        rejects.
    ]]
    Harness.case ("bytes.prefix", function ()
        local crossings = {
            { STRIDE - 1, STRIDE },
            { STRIDE, STRIDE + 1 },
            { STRIDE, STRIDE * 2 },
            { STRIDE * 2 - 1, STRIDE * 2 + 1 },
        }
        for _, lengths in crossings do
            Expect.equal (less (cut (lengths[1]), cut (lengths[2])), true)
            Expect.equal (less (cut (lengths[2]), cut (lengths[1])), false)
        end
    end),

    --[[
        Equal bytes do not come before each other either way round, at every length across both
        words. The decoder's ascending check rests on it: one comparison convicts a repeated key
        and a misordered one alike, and a true here would accept a map that repeats itself.
    ]]
    Harness.case ("bytes.equal", function ()
        for length = 0, MOST do
            Expect.equal (less (cut (length), cut (length)), false)
        end

        -- And one range against itself, which is what a sort hands its comparator.
        local out, at, len = laid (cut (MOST), {})
        Expect.equal (Bytes.rangeLess (out, at, len, at, len), false)
    end),

    --[[
        A range ending on the last byte of its buffer. Nine bytes is one stride and a one-byte tail,
        so a compare reaching for a second whole word runs off the end and raises instead of
        answering. A decoder compares keys wherever the frame put them, and a map's last pair sits
        against the end of what arrived.
    ]]
    Harness.case ("bytes.flush", function ()
        local length = STRIDE + 1
        local out = buffer.create (length * 2)
        for index, value in cut (length) do
            buffer.writeu8 (out, index - 1, value)
            buffer.writeu8 (out, length + index - 1, value)
        end
        buffer.writeu8 (out, length * 2 - 1, 0xFF)

        Expect.equal (Bytes.rangeLess (out, 0, length, length, length), true)
        Expect.equal (Bytes.rangeLess (out, length, length, 0, length), false)
    end),

    --[[
        Two patterns a compare reading doubles gets wrong. Zero against negative zero is different
        bytes and equal doubles, so nothing separates them. A NaN payload is identical bytes and
        unequal doubles, so the tail that differs is never reached. Either way two distinct keys
        come out unordered, and a map sorted on that order is one the decoder rejects.
    ]]
    Harness.case ("bytes.float-patterns", function ()
        local plus = table.create (STRIDE, 0)
        local minus = table.create (STRIDE, 0)
        minus[STRIDE] = 0x80

        Expect.equal (less (plus, minus), true)
        Expect.equal (less (minus, plus), false)

        local low = table.create (STRIDE, 0xFF)
        local high = table.create (STRIDE, 0xFF)
        table.insert (low, 0x00)
        table.insert (high, 0x01)

        Expect.equal (less (low, high), true)
        Expect.equal (less (high, low), false)
    end),

    --[[
        What a sealed block holds. A producer writes into scratch sized for the worst case and the
        block keeps the prefix it wrote, which is the length asked for and nothing of the scratch
        behind it. The scratch is the caller's and comes back as it went in, because the next block
        encodes into it.
    ]]
    Harness.case ("bytes.seal", function ()
        local size = 16
        local scratch = buffer.create (size)
        for offset = 0, size - 1 do
            buffer.writeu8 (scratch, offset, offset + 1)
        end
        local before = buffer.readstring (scratch, 0, size)

        local sealed = Bytes.seal (scratch, 5)
        Expect.equal (buffer.len (sealed), 5)
        for offset = 0, 4 do
            Expect.equal (buffer.readu8 (sealed, offset), offset + 1)
        end

        -- Nothing written is nothing held, and it is still a buffer.
        Expect.equal (buffer.len (Bytes.seal (scratch, 0)), 0)

        -- A length the scratch cannot answer for raises rather than padding.
        Expect.throws (function () Bytes.seal (scratch, size + 1) end)

        Expect.equal (buffer.readstring (scratch, 0, size), before)
    end),

    --[[
        A seal is a copy, and it is still a copy at the scratch's full length. That length is the
        case that matters: handing back the scratch itself passes every length and content check
        above, and then gives the block a buffer the next producer overwrites, so a frame would
        carry whatever the flush after it encoded.
    ]]
    Harness.case ("bytes.seal-copies", function ()
        local scratch = buffer.create (4)
        buffer.writeu8 (scratch, 0, 0x11)

        local sealed = Bytes.seal (scratch, 4)
        Expect.equal (buffer.len (sealed), 4)

        buffer.writeu8 (scratch, 0, 0x22)
        Expect.equal (buffer.readu8 (sealed, 0), 0x11)

        buffer.writeu8 (sealed, 1, 0x33)
        Expect.equal (buffer.readu8 (scratch, 1), 0x00)
    end),

    --[[
        One field, at every offset inside a byte and at every width up to a byte, against the
        addressing said the other way round: bit `k` is bit `k % 8` of byte `k // 8`, least
        significant first. The byte behind the field is ones, so a read taking more than its width
        takes them.
    ]]
    Harness.case ("bytes.bit-field", function ()
        for width = 1, BYTE do
            local span = 2 ^ width - 1

            for lead = 0, BYTE - 1 do
                local b = buffer.create (4)
                local at = Bytes.put (b, Bytes.put (b, 0, lead, 0), width, span)
                Bytes.put (b, at, BYTE, 0xFF)

                Expect.equal (at, lead + width)
                Expect.equal (Bytes.take (b, lead, width), span)
                if lead == 0 then continue end
                Expect.equal (bit32.extract (buffer.readu8 (b, 0), 0, lead), 0)
            end
        end
    end),

    --[[
        A field wider than the byte it starts in. Its low bits go in the byte it starts in and the
        rest carry on into the next, so a write that laid a whole word down at once or stopped at
        one byte loses the far end of it.
    ]]
    Harness.case ("bytes.bit-spans", function ()
        local b = buffer.create (4)
        Bytes.put (b, Bytes.put (b, 0, 5, 0x1F), 12, 0xABC)

        Expect.equal (buffer.readu8 (b, 0), 0x9F)
        Expect.equal (buffer.readu8 (b, 1), 0x57)
        Expect.equal (buffer.readu8 (b, 2), 0x01)
        Expect.equal (Bytes.take (b, 5, 12), 0xABC)
    end),

    --[[
        The run this exists for: the fieldset a delta section opens with, which is a mode bit, a
        count over the field count, and that many field indices. A one-bit field and four six-bit
        ones, ending part way through a byte.
    ]]
    Harness.case ("bytes.bit-run", function ()
        local b = buffer.create (16)
        local at = 0

        at = Bytes.put (b, at, 1, 0)
        at = Bytes.put (b, at, 6, 3)
        for _, field in { 9, 40, 63 } do
            at = Bytes.put (b, at, 6, field)
        end
        Expect.equal (at, 25)

        local mode, count
        local cursor = 0
        mode, cursor = Bytes.take (b, cursor, 1)
        count, cursor = Bytes.take (b, cursor, 6)

        Expect.equal (mode, 0)
        Expect.equal (count, 3)
        for _, field in { 9, 40, 63 } do
            local one
            one, cursor = Bytes.take (b, cursor, 6)
            Expect.equal (one, field)
        end
        Expect.equal (cursor, at)
    end),

    --[[
        A run owns every byte it reaches from the byte it starts on, so the bits above its last
        field are the zeros an align is made of without anything having zeroed the buffer first. The
        buffer is ones underneath, which is what makes a byte merged into rather than cleared
        observable at all.
    ]]
    Harness.case ("bytes.bit-pad", function ()
        local b = buffer.create (4)
        buffer.fill (b, 0, 0xFF)

        local at = Bytes.put (b, Bytes.put (b, 0, 3, 5), 7, 0x2A)
        Expect.equal (at, 10)
        Expect.equal (bit32.rshift (buffer.readu8 (b, 1), 2), 0)
        Expect.equal (buffer.readu8 (b, 2), 0xFF)
    end),

    --[[
        Asked at an offset part way through a byte and at one already on a byte, which are the
        two shapes an align meets. The second has nothing above it to be wrong about.
    ]]
    Harness.case ("bytes.bit-align", function ()
        local b = buffer.create (4)
        buffer.fill (b, 0, 0xFF)

        local at = Bytes.put (b, 0, 5, 0x1F)
        local byte, clean = Bytes.aligned (b, at)
        Expect.equal (byte, 1)
        Expect.equal (clean, true)

        buffer.writeu8 (b, 0, bit32.bor (buffer.readu8 (b, 0), 0x80))
        local _, dirty = Bytes.aligned (b, at)
        Expect.equal (dirty, false)

        local whole, over = Bytes.aligned (b, 16)
        Expect.equal (whole, 2)
        Expect.equal (over, true)
    end),

    --[[
        A field of no bits: nothing is written, nothing is read, and the cursor is where it was.
        The buffer either side is held to being untouched, since a zero-width write is easiest to
        get wrong by writing a zero.
    ]]
    Harness.case ("bytes.bit-none", function ()
        local b = buffer.create (2)
        buffer.fill (b, 0, 0xFF)

        Expect.equal (Bytes.put (b, 3, 0, 0), 3)
        Expect.equal (buffer.readu8 (b, 0), 0xFF)

        local value, after = Bytes.take (b, 3, 0)
        Expect.equal (value, 0)
        Expect.equal (after, 3)
    end),

    --[[
        Every width and offset a field can take, out and back, with ones packed in behind it so a
        read reaching past its width reads them.
    ]]
    Harness.property ("bytes.bits", "leaves", function (rng: Rng.Rng)
        local b = buffer.create (12)
        buffer.fill (b, 0, 0xFF)

        local lead = Rng.int (rng, 0, 2 * BYTE)
        local width = Rng.int (rng, 0, WIDEST)
        local value = Rng.int (rng, 0, 2 ^ width - 1)

        local at = Bytes.put (b, Bytes.put (b, 0, lead, 0), width, value)
        Bytes.put (b, at, BYTE, 0xFF)

        Expect.equal (at, lead + width)
        Expect.equal (Bytes.take (b, lead, width), value)
    end),

    -- Every pair of ranges that shares a prefix, against the order in C.
    Harness.property ("bytes.orders", "leaves", function (rng: Rng.Rng) agrees (pairing (rng)) end),

    --[[
        Every length a scratch can be sealed at, its bytes drawn rather than patterned so a copy
        reaching for the wrong offset lands somewhere other than where it wanted.
    ]]
    Harness.property ("bytes.seals", "leaves", function (rng: Rng.Rng)
        local size = Rng.int (rng, 0, MOST)
        local scratch = Rng.bytes (rng, size)
        local before = buffer.readstring (scratch, 0, size)

        local length = Rng.int (rng, 0, size)
        local sealed = Bytes.seal (scratch, length)

        Expect.equal (buffer.len (sealed), length)
        Expect.equal (buffer.readstring (sealed, 0, length), string.sub (before, 1, length))
        Expect.equal (buffer.readstring (scratch, 0, size), before)
    end),
}
