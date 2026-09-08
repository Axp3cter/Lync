--!strict
--!optimize 2
-- The byte leaves alone: bit fields, the order two ranges compare in, and what a seal keeps.

local Bytes = require("@src/wire/Bytes")
local Protocol = require("@src/wire/Protocol")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- The bytes one word of the compare covers, which is where its edges are.
local STRIDE = 8

-- The longest range a case lays down: two words and a tail.
local MOST = 20

local BYTE = 8
local WIDEST = Protocol.BIT_CEILING

-- The stride a filled range walks its bytes by. Odd, so multiplying modulo 256 is a permutation
-- and no range holds a byte twice. Large, so a range crosses 0x80 every few bytes.
local APART = 61

local NOTABLE = table.freeze({ 0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF })

-- What sits either side of a range in the buffer a case lays it into.
local AHEAD = 0xA5
local PAST_FIRST = 0xFF
local PAST_SECOND = 0x00

-- A range of the given length with no two bytes equal, so a compare that stops early, reads a byte
-- twice, or reads a word backwards lands somewhere other than it meant.
local function cut(length: number): { number }
    local out = table.create(length) :: { number }
    for index = 1, length do
        table.insert(out, (index * APART) % 256)
    end
    return out
end

local function spelled(bytes: { number }): string
    local parts = table.create(#bytes)
    for _, byte in bytes do
        table.insert(parts, string.format("%02X", byte))
    end
    return table.concat(parts, " ")
end

-- Both ranges in one buffer, each behind a byte of padding and followed by bytes that differ, so
-- a compare reading past a length answers wrongly rather than agreeing by luck.
local function laid(a: { number }, b: { number }): (buffer, number, number, number, number)
    local out = buffer.create(#a + #b + 4)
    local atB = #a + 3

    buffer.writeu8(out, 0, AHEAD)
    for index, byte in a do
        buffer.writeu8(out, index, byte)
    end
    buffer.writeu8(out, #a + 1, PAST_FIRST)

    buffer.writeu8(out, #a + 2, AHEAD)
    for index, byte in b do
        buffer.writeu8(out, atB + index - 1, byte)
    end
    buffer.writeu8(out, atB + #b, PAST_SECOND)
    return out, 1, #a, atB, #b
end

local function less(a: { number }, b: { number }): boolean
    local out, atA, lenA, atB, lenB = laid(a, b)
    return Bytes.less(out, atA, lenA, atB, lenB)
end

-- The answer beside the one wanted, read off the string order, an unsigned byte compare in C.
local function ordered(
    out: buffer,
    atA: number,
    lenA: number,
    atB: number,
    lenB: number
): (boolean, boolean)
    local got = Bytes.less(out, atA, lenA, atB, lenB)
    return got, buffer.readstring(out, atA, lenA) < buffer.readstring(out, atB, lenB)
end

-- Both ways round, since an order true in both directions is not an order.
local function agrees(a: { number }, b: { number })
    local out, atA, lenA, atB, lenB = laid(a, b)
    local first, wanted = ordered(out, atA, lenA, atB, lenB)
    if first ~= wanted then
        Expect.holds(false, `[{spelled(a)}] < [{spelled(b)}] answered {first}`)
    end
    local second, back = ordered(out, atB, lenB, atA, lenA)
    if second ~= back then
        Expect.holds(false, `[{spelled(b)}] < [{spelled(a)}] answered {second}`)
    end
end

local function byte(rng: Rng.Rng): number
    if rng:bool() then return rng:pick(NOTABLE) end
    return rng:int(0, 0xFF)
end

-- Two ranges that agree for a while and then do not, the only shape a compare has anything to do.
local function pairing(rng: Rng.Rng): ({ number }, { number })
    local shared = rng:int(0, MOST)
    local a = table.create(MOST) :: { number }
    for _ = 1, shared do
        table.insert(a, byte(rng))
    end
    local b = table.clone(a)
    for _ = 1, rng:int(0, MOST - shared) do
        table.insert(a, byte(rng))
    end
    for _ = 1, rng:int(0, MOST - shared) do
        table.insert(b, byte(rng))
    end
    return a, b
end

return {
    -- A range of nothing comes before every range with a byte in it, and not before itself.
    Harness.case("bytes.empty", function()
        Expect.equal(less({}, {}), false)
        Expect.equal(less({}, { 0x00 }), true)
        Expect.equal(less({ 0x00 }, {}), false)
    end),

    -- Bytes are magnitudes: a vlq key of 128 or more begins above 0x7F.
    Harness.case("bytes.unsigned", function()
        Expect.equal(less({ 0x7F }, { 0x80 }), true)
        Expect.equal(less({ 0x80 }, { 0x7F }), false)
        Expect.equal(less({ 0x80 }, { 0xFF }), true)

        local low = table.create(STRIDE, 0)
        local high = table.create(STRIDE, 0)
        low[1] = 0x7F
        high[1] = 0x80
        Expect.equal(less(low, high), true)
        Expect.equal(less(high, low), false)
    end),

    -- A value wider than its field is held to the field, since what lies past it is another field.
    Harness.case("bytes.holds-a-value-to-its-width", function()
        for width = 1, BYTE + 1 do
            for at = 0, BYTE do
                local b = buffer.create(STRIDE)
                local over = bit32.lshift(1, width + 2) - 1
                Expect.equal(Bytes.put(b, at, width, over), at + width)

                local got, after = Bytes.take(b, at, width)
                Expect.equal(got, bit32.extract(over, 0, width))
                Expect.equal(after, at + width)
                Expect.equal((Bytes.take(b, at + width, BYTE)), 0)
            end
        end
    end),

    -- Inside one word: the smallest pair a reversed byte order gets wrong, then a difference at
    -- each of the eight.
    Harness.case("bytes.stride", function()
        local front = table.create(STRIDE, 0)
        local back = table.create(STRIDE, 0)
        front[1] = 0x01
        back[2] = 0x01
        Expect.equal(less(front, back), false)
        Expect.equal(less(back, front), true)

        for position = 1, STRIDE do
            local low = cut(STRIDE)
            local high = cut(STRIDE)
            low[position] = 0x00
            high[position] = 0xFF
            Expect.equal(less(low, high), true)
            Expect.equal(less(high, low), false)
        end
    end),

    -- Past the last whole word, where a compare that stops with the words calls every pair equal.
    Harness.case("bytes.tail", function()
        for position = STRIDE + 1, STRIDE + 4 do
            local low = cut(STRIDE + 4)
            local high = cut(STRIDE + 4)
            low[position] = 0x00
            high[position] = 0xFF
            Expect.equal(less(low, high), true)
            Expect.equal(less(high, low), false)
        end
    end),

    -- A range that runs out first loses, across the word boundary from both sides.
    Harness.case("bytes.prefix", function()
        for _, lengths in
            {
                { STRIDE - 1, STRIDE },
                { STRIDE, STRIDE + 1 },
                { STRIDE, STRIDE * 2 },
                { STRIDE * 2 - 1, STRIDE * 2 + 1 },
            }
        do
            Expect.equal(less(cut(lengths[1]), cut(lengths[2])), true)
            Expect.equal(less(cut(lengths[2]), cut(lengths[1])), false)
        end
    end),

    -- Equal bytes do not come before each other either way, which convicts a repeated map key.
    Harness.case("bytes.equal", function()
        for length = 0, MOST do
            Expect.equal(less(cut(length), cut(length)), false)
        end
        local out, at, len = laid(cut(MOST), {})
        Expect.equal(Bytes.less(out, at, len, at, len), false)
    end),

    -- A range ending on the last byte of its buffer: a compare reaching for a second whole word
    -- would run off the end.
    Harness.case("bytes.flush", function()
        local length = STRIDE + 1
        local out = buffer.create(length * 2)
        for index, value in cut(length) do
            buffer.writeu8(out, index - 1, value)
            buffer.writeu8(out, length + index - 1, value)
        end
        buffer.writeu8(out, length * 2 - 1, 0xFF)
        Expect.equal(Bytes.less(out, 0, length, length, length), true)
        Expect.equal(Bytes.less(out, length, length, 0, length), false)
    end),

    -- Zero against negative zero, and two NaN payloads: what a compare through doubles gets wrong.
    Harness.case("bytes.float-patterns", function()
        local plus = table.create(STRIDE, 0)
        local minus = table.create(STRIDE, 0)
        minus[STRIDE] = 0x80
        Expect.equal(less(plus, minus), true)
        Expect.equal(less(minus, plus), false)

        local low = table.create(STRIDE, 0xFF)
        local high = table.create(STRIDE, 0xFF)
        table.insert(low, 0x00)
        table.insert(high, 0x01)
        Expect.equal(less(low, high), true)
        Expect.equal(less(high, low), false)
    end),

    -- The leading number and the rank order as the ranges do, as far as each reaches.
    Harness.case("bytes.leading-and-rank", function()
        for lenA = 0, Bytes.LEADING do
            for lenB = 0, Bytes.LEADING do
                local out, atA, _, atB = laid(cut(lenA), cut(lenB))
                local a = Bytes.leading(out, atA, lenA)
                local b = Bytes.leading(out, atB, lenB)
                local wanted = Bytes.less(out, atA, lenA, atB, lenB)
                Expect.equal(a < b or (a == b and lenA < lenB), wanted)
                if Bytes.isRanked(lenA) and Bytes.isRanked(lenB) then
                    local ra, rb = Bytes.rank(out, atA, lenA), Bytes.rank(out, atB, lenB)
                    Expect.equal(ra < rb or (ra == rb and lenA < lenB), wanted)
                end
            end
        end

        local longer = cut(Bytes.LEADING + 3)
        local out, at = laid(longer, {})
        Expect.equal(Bytes.leading(out, at, #longer), Bytes.rank(out, at, Bytes.LEADING))
        Expect.equal(Bytes.isRanked(4), true)
        Expect.equal(Bytes.isRanked(5), false)
    end),

    -- A sealed block keeps the prefix it wrote and nothing of the scratch behind it.
    Harness.case("bytes.seal", function()
        local size = 16
        local scratch = buffer.create(size)
        for offset = 0, size - 1 do
            buffer.writeu8(scratch, offset, offset + 1)
        end
        local before = buffer.readstring(scratch, 0, size)

        local sealed = Bytes.seal(scratch, 5)
        Expect.equal(buffer.len(sealed), 5)
        for offset = 0, 4 do
            Expect.equal(buffer.readu8(sealed, offset), offset + 1)
        end
        Expect.equal(buffer.len(Bytes.seal(scratch, 0)), 0)
        Expect.throws(function()
            Bytes.seal(scratch, size + 1)
        end)
        Expect.equal(buffer.readstring(scratch, 0, size), before)
    end),

    -- A seal is a copy even at the scratch's full length, or the next flush overwrites the frame.
    Harness.case("bytes.seal-copies", function()
        local scratch = buffer.create(4)
        buffer.writeu8(scratch, 0, 0x11)
        local sealed = Bytes.seal(scratch, 4)
        Expect.equal(buffer.len(sealed), 4)

        buffer.writeu8(scratch, 0, 0x22)
        Expect.equal(buffer.readu8(sealed, 0), 0x11)
        buffer.writeu8(sealed, 1, 0x33)
        Expect.equal(buffer.readu8(scratch, 1), 0x00)
    end),

    -- Bit k is bit k % 8 of byte k // 8, least significant first, at every offset and width.
    Harness.case("bytes.bit-field", function()
        for width = 1, BYTE do
            local span = 2 ^ width - 1
            for lead = 0, BYTE - 1 do
                local b = buffer.create(4)
                local at = Bytes.put(b, Bytes.put(b, 0, lead, 0), width, span)
                Bytes.put(b, at, BYTE, 0xFF)
                Expect.equal(at, lead + width)
                Expect.equal(Bytes.take(b, lead, width), span)
                if lead == 0 then continue end
                Expect.equal(bit32.extract(buffer.readu8(b, 0), 0, lead), 0)
            end
        end
    end),

    -- A field wider than the byte it starts in carries on into the next.
    Harness.case("bytes.bit-spans", function()
        local b = buffer.create(4)
        Bytes.put(b, Bytes.put(b, 0, 5, 0x1F), 12, 0xABC)
        Expect.equal(buffer.readu8(b, 0), 0x9F)
        Expect.equal(buffer.readu8(b, 1), 0x57)
        Expect.equal(buffer.readu8(b, 2), 0x01)
        Expect.equal(Bytes.take(b, 5, 12), 0xABC)
    end),

    -- The fieldset a delta section opens with: a mode bit, a count, and that many field indices.
    Harness.case("bytes.bit-run", function()
        local b = buffer.create(16)
        local at = 0
        at = Bytes.put(b, at, 1, 0)
        at = Bytes.put(b, at, 6, 3)
        for _, field in { 9, 40, 63 } do
            at = Bytes.put(b, at, 6, field)
        end
        Expect.equal(at, 25)

        local mode, count
        local cursor = 0
        mode, cursor = Bytes.take(b, cursor, 1)
        count, cursor = Bytes.take(b, cursor, 6)
        Expect.equal(mode, 0)
        Expect.equal(count, 3)
        for _, field in { 9, 40, 63 } do
            local one
            one, cursor = Bytes.take(b, cursor, 6)
            Expect.equal(one, field)
        end
        Expect.equal(cursor, at)
    end),

    -- A run owns every byte it reaches, so the bits above its last field are zero without anything
    -- having cleared the buffer first.
    Harness.case("bytes.bit-pad", function()
        local b = buffer.create(4)
        buffer.fill(b, 0, 0xFF)
        local at = Bytes.put(b, Bytes.put(b, 0, 3, 5), 7, 0x2A)
        Expect.equal(at, 10)
        Expect.equal(bit32.rshift(buffer.readu8(b, 1), 2), 0)
        Expect.equal(buffer.readu8(b, 2), 0xFF)
    end),

    Harness.case("bytes.bit-align", function()
        local b = buffer.create(4)
        buffer.fill(b, 0, 0xFF)
        local at = Bytes.put(b, 0, 5, 0x1F)
        local byteAt, clean = Bytes.align(b, at)
        Expect.equal(byteAt, 1)
        Expect.equal(clean, true)

        buffer.writeu8(b, 0, bit32.bor(buffer.readu8(b, 0), 0x80))
        local _, dirty = Bytes.align(b, at)
        Expect.equal(dirty, false)

        local whole, over = Bytes.align(b, 16)
        Expect.equal(whole, 2)
        Expect.equal(over, true)
    end),

    -- A field of no bits writes nothing, reads nothing, and leaves the cursor where it was.
    Harness.case("bytes.bit-none", function()
        local b = buffer.create(2)
        buffer.fill(b, 0, 0xFF)
        Expect.equal(Bytes.put(b, 3, 0, 0), 3)
        Expect.equal(buffer.readu8(b, 0), 0xFF)
        local value, after = Bytes.take(b, 3, 0)
        Expect.equal(value, 0)
        Expect.equal(after, 3)
    end),

    Harness.property("bytes.bits", "leaves", function(rng: Rng.Rng)
        local b = buffer.create(12)
        buffer.fill(b, 0, 0xFF)
        local lead = rng:int(0, 2 * BYTE)
        local width = rng:int(0, WIDEST)
        local value = rng:int(0, 2 ^ width - 1)

        local at = Bytes.put(b, Bytes.put(b, 0, lead, 0), width, value)
        Bytes.put(b, at, BYTE, 0xFF)
        Expect.equal(at, lead + width)
        Expect.equal(Bytes.take(b, lead, width), value)
    end),

    Harness.property("bytes.orders", "leaves", function(rng: Rng.Rng)
        agrees(pairing(rng))
    end),

    Harness.property("bytes.seals", "leaves", function(rng: Rng.Rng)
        local size = rng:int(0, MOST)
        local scratch = rng:bytes(size)
        local before = buffer.readstring(scratch, 0, size)

        local length = rng:int(0, size)
        local sealed = Bytes.seal(scratch, length)
        Expect.equal(buffer.len(sealed), length)
        Expect.equal(buffer.readstring(sealed, 0, length), string.sub(before, 1, length))
        Expect.equal(buffer.readstring(scratch, 0, size), before)
    end),
}
