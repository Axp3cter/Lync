--!strict
--!optimize 2
-- Sixty-four bit words as the module carries them, held to arithmetic worked out in pieces.

local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Limbs = require("@test/harness/Limbs")
local Rng = require("@test/harness/Rng")

local PIECES = 4
local PLACE = 65536
local SPAN = 16
local WIDEST = PIECES * SPAN

local NONE = "0000000000000000"

-- Whole values worth asking outright, which is where a wide answer turns over.
local NOTABLE = table.freeze({
    NONE,
    "0000000000000001",
    "00000000FFFFFFFF",
    "0000000100000000",
    "7FFFFFFFFFFFFFFF",
    "8000000000000000",
    "FFFFFFFFFFFFFFFF",
    "0123456789ABCDEF",
})

-- Four places spread over the whole width, no two together, so a fold cannot drop one unseen.
local APART = table.freeze({
    "0000000000000001",
    "0000000000020000",
    "0000000100000000",
    "8000000000000000",
})

local WHOLE = "FFFFFFFFFFFFFFFF"
local APIECE = "8000000100020001"
local OTHERWISE = "7FFFFFFEFFFDFFFE"
local TRAILING = "8000000100020000"
local REMAINING = "7FFFFFFEFFFDFFFF"

-- The two constants the schema hash is folded with.
local BASIS = "CBF29CE484222325"
local PRIME = "00000100000001B3"

type Carrier = typeof(Wide)

-- Every case here, run against the one carrier under its name, so a line names where it failed.
local function each(run: (Carrier, string) -> ())
    run(Wide, "halves")
end

local function same(from: string, held: unknown, wanted: unknown)
    Expect.holds(held == wanted, `{from}: {tostring(held)} is not {tostring(wanted)}`)
end

-- Sixteen hex digits, landing where a wide answer turns over as often as anywhere.
local function drawn(rng: Rng.Rng): string
    if rng:bool() then return rng:pick(NOTABLE) end
    local out = table.create(PIECES) :: { string }
    for _ = 1, PIECES do
        table.insert(out, string.format("%04X", rng:int(0, PLACE - 1)))
    end
    return table.concat(out)
end

-- One value on both sides: the carrier's word, and the pieces answers are worked out in.
local function both(of: Carrier, text: string): (Wide.Word, Limbs.Limbs)
    return of.fromHex(text), Limbs.of(text)
end

local function folded(a: Limbs.Limbs, b: Limbs.Limbs, by: (number, number) -> number): string
    local out = table.create(PIECES) :: Limbs.Limbs
    for place = 1, PIECES do
        out[place] = by(a[place], b[place])
    end
    return Limbs.hex(out)
end

local function lowest(of: Limbs.Limbs): number
    for place = 1, PIECES do
        local piece = of[place]
        if piece == 0 then continue end
        for bit = 0, SPAN - 1 do
            if bit32.btest(piece, bit32.lshift(1, bit)) then return (place - 1) * SPAN + bit + 1 end
        end
    end
    return WIDEST + 1
end

local function clearLowest(of: Limbs.Limbs): string
    local out = table.clone(of)
    local at = lowest(of)
    if at > WIDEST then return Limbs.hex(out) end
    local place = (at - 1) // SPAN + 1
    out[place] = bit32.band(out[place], bit32.bnot(bit32.lshift(1, (at - 1) % SPAN)))
    return Limbs.hex(out)
end

-- FNV-1a over a text, through one carrier.
local function hashed(of: Carrier, text: string): string
    local held = of.fromHex(BASIS)
    local prime = of.fromHex(PRIME)
    for index = 1, #text do
        held = of.mul(of.bxor(held, of.fromNumber((string.byte(text, index)))), prime)
    end
    return of.toHex(held)
end

return {
    Harness.case("wide.hex", function()
        each(function(of: Carrier, from: string)
            for _, digits in NOTABLE do
                same(from, of.toHex(of.fromHex(digits)), digits)
            end
            same(from, of.toHex(of.NONE), NONE)
            same(from, of.toHex(of.fromNumber(0)), NONE)
            same(from, of.toHex(of.fromNumber(1)), "0000000000000001")
            same(from, of.toHex(of.fromNumber(PLACE * PLACE - 1)), "00000000FFFFFFFF")
        end)
    end),

    Harness.case("wide.bit", function()
        each(function(of: Carrier, from: string)
            for place = 1, WIDEST do
                local out = { 0, 0, 0, 0 }
                out[(place - 1) // SPAN + 1] = bit32.lshift(1, (place - 1) % SPAN)
                same(from, of.toHex(of.bit(place)), Limbs.hex(out))
            end
        end)
    end),

    Harness.case("wide.bit-is-kept", function()
        Expect.equal(Wide.toHex(Wide.bit(1)), "0000000000000001")
        Expect.equal(Wide.toHex(Wide.bit(1)), "0000000000000001")
        Expect.equal(Wide.toHex(Wide.bit(WIDEST)), "8000000000000000")
    end),

    Harness.case("wide.folds", function()
        each(function(of: Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    local a, one = both(of, left)
                    local b, two = both(of, right)
                    same(from, of.toHex(of.bor(a, b)), folded(one, two, bit32.bor))
                    same(from, of.toHex(of.bxor(a, b)), folded(one, two, bit32.bxor))
                    same(from, of.btest(a, b), folded(one, two, bit32.band) ~= NONE)
                end
            end
        end)
    end),

    -- Each word below holds a place no other does and lacks a place every other has, so dropping
    -- any one out of either fold shows.
    Harness.case("wide.folds-a-list", function()
        each(function(of: Carrier, from: string)
            local singles = table.create(#APART) :: { Wide.Word }
            local holed = table.create(#APART) :: { Wide.Word }
            for at, one in APART do
                singles[at] = of.fromHex(one)
                holed[at] = of.bxor(of.fromHex(WHOLE), singles[at])
            end

            local held = #APART
            same(from, of.toHex(of.borAll(of.NONE, singles, 1, held)), APIECE)
            same(from, of.toHex(of.bandAll(holed[1], holed, 1, held)), OTHERWISE)

            -- A fold starting past the front of the list, as a section speaking for part of a
            -- partition asks for.
            same(from, of.toHex(of.borAll(of.NONE, singles, 2, held - 1)), TRAILING)
            same(from, of.toHex(of.bandAll(holed[2], holed, 2, held - 1)), REMAINING)
        end)
    end),

    Harness.case("wide.any", function()
        each(function(of: Carrier, from: string)
            same(from, of.any(of.NONE), false)
            for _, digits in NOTABLE do
                same(from, of.any(of.fromHex(digits)), digits ~= NONE)
            end
        end)
    end),

    -- The lowest bit and the word without it, the two halves of one step of every mask walk.
    Harness.case("wide.lowest", function()
        each(function(of: Carrier, from: string)
            for _, digits in NOTABLE do
                local held, pieces = both(of, digits)
                while of.any(held) do
                    same(from, of.lowest(held), lowest(pieces))
                    same(from, of.toHex(of.clearLowest(held)), clearLowest(pieces))
                    held = of.clearLowest(held)
                    pieces = Limbs.of(of.toHex(held))
                end
                same(from, of.toHex(held), NONE)
            end
        end)
    end),

    Harness.case("wide.equal", function()
        each(function(of: Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    same(from, of.eq(of.fromHex(left), of.fromHex(right)), left == right)
                end
            end
        end)
    end),

    -- A product wraps at sixty-four bits, the one place the library leans on the wrap.
    Harness.case("wide.mul", function()
        each(function(of: Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    local a, one = both(of, left)
                    local b, two = both(of, right)
                    same(from, of.toHex(of.mul(a, b)), Limbs.hex(Limbs.times(one, two)))
                end
            end

            local turn = of.fromHex("0000000100000000")
            same(from, of.toHex(of.mul(turn, turn)), NONE)

            local widest = of.fromHex("FFFFFFFFFFFFFFFF")
            same(from, of.toHex(of.mul(widest, widest)), "0000000000000001")
        end)
    end),

    Harness.case("wide.bytes", function()
        each(function(of: Carrier, from: string)
            local out = buffer.create(8)
            for _, digits in NOTABLE do
                same(from, of.write(out, 0, of.fromHex(digits)), 8)
                same(from, of.toHex(of.read(out, 0)), digits)
            end

            of.write(out, 0, of.fromHex("0102030405060708"))
            same(from, buffer.readu8(out, 0), 0x08)
            same(from, buffer.readu8(out, 7), 0x01)
        end)
    end),

    -- The comparison a sort asks for, which is the bytes as they lie rather than as a word holds
    -- them.
    Harness.case("wide.big-endian", function()
        each(function(of: Carrier, from: string)
            local one = buffer.create(8)
            local two = buffer.create(8)
            for at = 0, 7 do
                buffer.writeu8(one, at, at + 1)
                buffer.writeu8(two, at, at + 1)
            end

            for lead = 0, 255 do
                buffer.writeu8(one, 0, lead)
                for other = 0, 255, 17 do
                    buffer.writeu8(two, 0, other)
                    local joined = buffer.create(16)
                    buffer.copy(joined, 0, one)
                    buffer.copy(joined, 8, two)
                    local equal, less = of.compareBig(joined, 0, 8)
                    same(from, equal, lead == other)
                    same(from, less, buffer.tostring(one) < buffer.tostring(two))
                end
            end
        end)
    end),

    -- The hash both machines require, held to the vectors the algorithm publishes.
    Harness.case("wide.hash", function()
        each(function(of: Carrier, from: string)
            same(from, hashed(of, ""), BASIS)
            same(from, hashed(of, "a"), "AF63DC4C8601EC8C")
            same(from, hashed(of, "foobar"), "85944171F73967E8")
        end)
    end),

    Harness.property("wide.agrees", "leaves", function(rng: Rng.Rng)
        local left, right = drawn(rng), drawn(rng)
        each(function(of: Carrier, from: string)
            local a, one = both(of, left)
            local b, two = both(of, right)
            same(from, of.toHex(a), left)
            same(from, of.toHex(of.bor(a, b)), folded(one, two, bit32.bor))
            same(from, of.toHex(of.bxor(a, b)), folded(one, two, bit32.bxor))
            same(from, of.toHex(of.mul(a, b)), Limbs.hex(Limbs.times(one, two)))
            same(from, of.toHex(of.clearLowest(a)), clearLowest(one))
            same(from, of.btest(a, b), folded(one, two, bit32.band) ~= NONE)
            same(from, of.eq(a, b), left == right)
            same(from, of.any(a), left ~= NONE)
            same(from, of.lowest(a), lowest(one))
        end)
    end),
}
