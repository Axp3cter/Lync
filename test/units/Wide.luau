--!strict
--!optimize 2
--[[
    Every carrier this build has for sixty-four bit data, held to arithmetic worked out in pieces.
]]

local Wide = require ("@src/kernel/Wide")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Limbs = require ("@test/harness/Limbs")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

-- The pieces a wide value is written in, four hex digits each, and how far one counts.
const PIECES = 4
const PLACE = 65536

-- Bits in a piece, and in a whole word, which is what a place is counted against.
const SPAN = 16
const WIDEST = PIECES * SPAN

-- A whole word of nothing, spelled the way a reading of one spells it.
const NONE = "0000000000000000"

-- Whole values worth asking outright, which is where a wide answer turns over.
const NOTABLE = table.freeze ({
    NONE,
    "0000000000000001",
    "00000000FFFFFFFF",
    "0000000100000000",
    "7FFFFFFFFFFFFFFF",
    "8000000000000000",
    "FFFFFFFFFFFFFFFF",
    "0123456789ABCDEF",
})

--[[
    Four places spread over the whole width, low half and high half alike, no two of them together.
    A list built from these is one no fold over it can drop a member of without saying so.
]]
const APART = table.freeze ({
    "0000000000000001",
    "0000000000020000",
    "0000000100000000",
    "8000000000000000",
})

-- What the four come to, what a word without any of them is, and what the last three come to.
const WHOLE = "FFFFFFFFFFFFFFFF"
const APIECE = "8000000100020001"
const OTHERWISE = "7FFFFFFEFFFDFFFE"
const TRAILING = "8000000100020000"
const REMAINING = "7FFFFFFEFFFDFFFF"

-- The two constants the hash is folded with, spelled here because this file multiplies them.
const BASIS = "CBF29CE484222325"
const PRIME = "00000100000001B3"

-- Private -------------------------------------------------------------

-- Every case here, run once for each carrier this build has.
local function each (run: (Wide.Carrier, string) -> ())
    for name, of in Wide.carriers do
        run (of, name)
    end
end

-- An answer held against what it should be, with the carrier that gave it named.
local function same (from: string, held: unknown, wanted: unknown)
    Expect.holds (held == wanted, `{from}: {tostring (held)} is not {tostring (wanted)}`)
end

-- Sixteen hex digits, landing where a wide answer turns over as often as anywhere.
local function drawn (rng: Rng.Rng): string
    if Rng.bool (rng) then return Rng.pick (rng, NOTABLE) end

    local out = table.create (PIECES) :: { string }
    for _ = 1, PIECES do
        table.insert (out, string.format ("%04X", Rng.int (rng, 0, PLACE - 1)))
    end
    return table.concat (out)
end

--[[
    One value on both sides: the carrier's word, and the pieces this file works answers out in.

    Handed over together because every check below wants the same value twice and reading them from
    one spelling is what keeps the two from being two different values.
]]
local function both (of: Wide.Carrier, text: string): (Wide.Word, Limbs.Limbs)
    return of.parse (text), Limbs.of (text)
end

-- Two sets of pieces, folded one against the other, which is every bitwise operation there is.
local function folded (a: Limbs.Limbs, b: Limbs.Limbs, by: (number, number) -> number): string
    local out = table.create (PIECES) :: Limbs.Limbs
    for place = 1, PIECES do
        out[place] = by (a[place], b[place])
    end
    return Limbs.hex (out)
end

--[[
    Where the lowest bit of a value is, and what a value of no bits answers. The second is the one
    a walk over a mask stops on, so it is asked of both carriers rather than of whichever this
    build got.
]]
local function lowest (of: Limbs.Limbs): number
    for place = 1, PIECES do
        local piece = of[place]
        if piece == 0 then continue end

        for bit = 0, SPAN - 1 do
            if bit32.btest (piece, bit32.lshift (1, bit)) then
                return (place - 1) * SPAN + bit + 1
            end
        end
    end
    return WIDEST + 1
end

-- The same value with its lowest bit taken out, which is one step of every walk over a mask.
local function without (of: Limbs.Limbs): string
    local out = table.clone (of)
    local at = lowest (of)
    if at > WIDEST then return Limbs.hex (out) end

    local place = (at - 1) // SPAN + 1
    out[place] = bit32.band (out[place], bit32.bnot (bit32.lshift (1, (at - 1) % SPAN)))
    return Limbs.hex (out)
end

-- Whether one value is under another, read a piece at a time from the top down.
local function below (a: Limbs.Limbs, b: Limbs.Limbs): boolean
    for place = PIECES, 1, -1 do
        if a[place] ~= b[place] then return a[place] < b[place] end
    end
    return false
end

-- FNV-1a over a text, through one carrier.
local function hashed (of: Wide.Carrier, text: string): string
    local held = of.parse (BASIS)
    local prime = of.parse (PRIME)

    for index = 1, #text do
        local byte = string.byte (text, index)
        held = of.mul (of.bxor (held, of.of (byte)), prime)
    end
    return of.text (held)
end

-- Public --------------------------------------------------------------

return {
    -- Which carriers this build has, which is what every case below is multiplied by.
    Harness.case ("wide.carriers", function ()
        local held = 0
        for name, of in Wide.carriers do
            held += 1
            Expect.holds (of.parse (NONE) ~= nil, `{name} answered nothing for a word of no bits`)
        end

        Expect.holds (held > 0, "this build has no carrier at all")
        Expect.holds (Wide.carriers.halves ~= nil, "the pair of halves is not among them")
    end),

    -- A word read from its digits and written back as them.
    Harness.case ("wide.text", function ()
        each (function (of: Wide.Carrier, from: string)
            for _, digits in NOTABLE do
                same (from, of.text (of.parse (digits)), digits)
            end

            same (from, of.text (of.NONE), NONE)
            same (from, of.text (of.of (0)), NONE)
            same (from, of.text (of.of (1)), "0000000000000001")
            same (from, of.text (of.of (PLACE * PLACE - 1)), "00000000FFFFFFFF")
        end)
    end),

    -- Every place a bit can be asked for, from the first to the sixty fourth.
    Harness.case ("wide.bit", function ()
        each (function (of: Wide.Carrier, from: string)
            for place = 1, WIDEST do
                local out = { 0, 0, 0, 0 }
                out[(place - 1) // SPAN + 1] = bit32.lshift (1, (place - 1) % SPAN)

                same (from, of.text (of.bit (place)), Limbs.hex (out))
            end
        end)
    end),

    -- The same place asked twice, through the door that keeps what it has answered.
    Harness.case ("wide.bit-is-kept", function ()
        Expect.equal (Wide.text (Wide.bit (1)), "0000000000000001")
        Expect.equal (Wide.text (Wide.bit (1)), "0000000000000001")
        Expect.equal (Wide.text (Wide.bit (WIDEST)), "8000000000000000")
    end),

    -- The two ways two words are folded together, and what testing one against the other answers.
    Harness.case ("wide.folds", function ()
        each (function (of: Wide.Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    local a, one = both (of, left)
                    local b, two = both (of, right)

                    same (from, of.text (of.union (a, b)), folded (one, two, bit32.bor))
                    same (from, of.text (of.bxor (a, b)), folded (one, two, bit32.bxor))
                    same (from, of.text (of.both (a, b)), folded (one, two, bit32.band))
                    same (from, of.meets (a, b), folded (one, two, bit32.band) ~= NONE)
                end
            end
        end)
    end),

    --[[
        The two folds a list is taken by. Each word below holds a place no other does and lacks a
        place every other has, so dropping any one of them out of either answer shows, which is
        what a list fold has to be held to and a pair fold cannot say.
    ]]
    Harness.case ("wide.folds-a-list", function ()
        each (function (of: Wide.Carrier, from: string)
            local singles = table.create (#APART) :: { Wide.Word }
            local holed = table.create (#APART) :: { Wide.Word }

            for at, one in APART do
                singles[at] = of.parse (one)
                holed[at] = of.bxor (of.parse (WHOLE), singles[at])
            end

            local held = #APART

            same (from, of.text (of.gathered (of.NONE, singles, 1, held)), APIECE)
            same (from, of.text (of.shared (holed[1], holed, 1, held)), OTHERWISE)

            --[[
                A fold starting past the front of the list, which is what a section speaking for
                part of a partition asks for: the words before its own belong to another section.
            ]]
            same (from, of.text (of.gathered (of.NONE, singles, 2, held - 1)), TRAILING)
            same (from, of.text (of.shared (holed[2], holed, 2, held - 1)), REMAINING)
        end)
    end),

    -- Whether a word holds anything at all, which is what ends a walk over a mask before it starts.
    Harness.case ("wide.any", function ()
        each (function (of: Wide.Carrier, from: string)
            same (from, of.any (of.NONE), false)

            for _, digits in NOTABLE do
                same (from, of.any (of.parse (digits)), digits ~= NONE)
            end
        end)
    end),

    --[[
        The lowest bit a word holds, and the word with that bit taken out, which are the two halves
        of one step of every walk over a dirty mask.
    ]]
    Harness.case ("wide.lowest", function ()
        each (function (of: Wide.Carrier, from: string)
            for _, digits in NOTABLE do
                local held, pieces = both (of, digits)

                while of.any (held) do
                    same (from, of.lowest (held), lowest (pieces))
                    same (from, of.text (of.without (held)), without (pieces))

                    held = of.without (held)
                    pieces = Limbs.of (of.text (held))
                end
                same (from, of.text (held), NONE)
            end
        end)
    end),

    -- Two words compared, as the same word and as the lesser of two.
    Harness.case ("wide.order", function ()
        each (function (of: Wide.Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    local a, one = both (of, left)
                    local b, two = both (of, right)

                    same (from, of.same (a, b), left == right)
                    same (from, of.below (a, b), below (one, two))
                end
            end
        end)
    end),

    --[[
        A product, which wraps at sixty-four bits and is the one place in the library that leans on
        the wrap.
    ]]
    Harness.case ("wide.mul", function ()
        each (function (of: Wide.Carrier, from: string)
            for _, left in NOTABLE do
                for _, right in NOTABLE do
                    local a, one = both (of, left)
                    local b, two = both (of, right)

                    same (from, of.text (of.mul (a, b)), Limbs.hex (Limbs.times (one, two)))
                end
            end

            local turn = of.parse ("0000000100000000")
            same (from, of.text (of.mul (turn, turn)), NONE)

            local widest = of.parse ("FFFFFFFFFFFFFFFF")
            same (from, of.text (of.mul (widest, widest)), "0000000000000001")
        end)
    end),

    -- A word laid into a buffer and read back out, and the byte it answers.
    Harness.case ("wide.bytes", function ()
        each (function (of: Wide.Carrier, from: string)
            local out = buffer.create (8)

            for _, digits in NOTABLE do
                same (from, of.write (out, 0, of.parse (digits)), 8)
                same (from, of.text (of.read (out, 0)), digits)
            end

            of.write (out, 0, of.parse ("0102030405060708"))
            same (from, buffer.readu8 (out, 0), 0x08)
            same (from, buffer.readu8 (out, 7), 0x01)
        end)
    end),

    -- The reading a sort compares, which is the bytes as they lie rather than as a word holds them.
    Harness.case ("wide.ordered", function ()
        each (function (of: Wide.Carrier, from: string)
            local one = buffer.create (8)
            local two = buffer.create (8)

            for at = 0, 7 do
                buffer.writeu8 (one, at, at + 1)
                buffer.writeu8 (two, at, at + 1)
            end

            same (from, of.text (of.ordered (one, 0)), "0102030405060708")

            for lead = 0, 255 do
                buffer.writeu8 (one, 0, lead)
                for other = 0, 255, 17 do
                    buffer.writeu8 (two, 0, other)

                    local held = of.below (of.ordered (one, 0), of.ordered (two, 0))
                    same (from, held, buffer.tostring (one) < buffer.tostring (two))
                end
            end
        end)
    end),

    --[[
        The hash both machines require, folded through each carrier and held to the vectors the
        algorithm publishes.
    ]]
    Harness.case ("wide.hash", function ()
        each (function (of: Wide.Carrier, from: string)
            same (from, hashed (of, ""), BASIS)
            same (from, hashed (of, "a"), "AF63DC4C8601EC8C")
            same (from, hashed (of, "foobar"), "85944171F73967E8")
        end)
    end),

    -- Every operation over drawn words, against the same answer worked out a piece at a time.
    Harness.property ("wide.agrees", "leaves", function (rng: Rng.Rng)
        local left, right = drawn (rng), drawn (rng)

        each (function (of: Wide.Carrier, from: string)
            local a, one = both (of, left)
            local b, two = both (of, right)

            same (from, of.text (a), left)
            same (from, of.text (of.union (a, b)), folded (one, two, bit32.bor))
            same (from, of.text (of.bxor (a, b)), folded (one, two, bit32.bxor))
            same (from, of.text (of.mul (a, b)), Limbs.hex (Limbs.times (one, two)))
            same (from, of.text (of.without (a)), without (one))

            same (from, of.meets (a, b), folded (one, two, bit32.band) ~= NONE)
            same (from, of.below (a, b), below (one, two))
            same (from, of.same (a, b), left == right)
            same (from, of.any (a), left ~= NONE)
            same (from, of.lowest (a), lowest (one))
        end)
    end),
}
