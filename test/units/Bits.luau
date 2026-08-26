--!strict
--!optimize 2
--[[
    The ranged-int width alone: how many bits a span of values costs on the wire.
]]

local Bits = require ("@src/kernel/Bits")
local Protocol = require ("@src/wire/Protocol")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    The width of every span from none to sixteen, counted out rather than computed: a table a reader
    can check against the definition by eye is the only oracle here that is not the code under test
    written twice. The nth entry is the width of a span of n minus one, because the list opens at a
    span of none.
]]
const SMALL = table.freeze ({ 0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5 })

-- The widest a logical value may be, which is what bounds the exponents drawn.
const WIDEST = 53

-- Public --------------------------------------------------------------

return {
    -- A span of none is one value, and one value says nothing on the wire.
    Harness.case ("bits.none", function () Expect.equal (Bits.width (0), 0) end),

    -- Below none is still none: the definition floors rather than reflecting.
    Harness.case ("bits.negative", function ()
        Expect.equal (Bits.width (-1), 0)
        Expect.equal (Bits.width (-255), 0)
    end),

    Harness.case ("bits.one", function () Expect.equal (Bits.width (1), 1) end),

    Harness.case ("bits.small", function ()
        for index, counted in SMALL do
            local span = index - 1
            Expect.holds (
                Bits.width (span) == counted,
                `a span of {span} is {Bits.width (span)} bits, counted as {counted}`
            )
        end
    end),

    -- A power of two is one past the widths below it: 2 needs two bits, not one.
    Harness.case ("bits.powers", function ()
        for exponent = 0, WIDEST do
            local span = 2 ^ exponent
            Expect.holds (
                Bits.width (span) == exponent + 1,
                `a span of 2^{exponent} is {Bits.width (span)} bits, wanted {exponent + 1}`
            )
        end
    end),

    -- And one below a power is the last span that fits in the narrower width.
    Harness.case ("bits.below-powers", function ()
        for exponent = 1, WIDEST do
            local span = 2 ^ exponent - 1
            Expect.holds (
                Bits.width (span) == exponent,
                `a span of 2^{exponent} - 1 is {Bits.width (span)} bits, wanted {exponent}`
            )
        end
    end),

    --[[
        One past a power, which is where a width computed through a logarithm stops telling the
        truth. From 2^49 upward the log of `span + 1` rounds back to the exponent and the width
        comes out one short, which is a shape that encodes fine and decodes as a different value.
    ]]
    Harness.case ("bits.above-powers", function ()
        for exponent = 1, WIDEST do
            local span = 2 ^ exponent + 1
            Expect.holds (
                Bits.width (span) == exponent + 1,
                `a span of 2^{exponent} + 1 is {Bits.width (span)} bits, wanted {exponent + 1}`
            )
        end
    end),

    -- Where the packed-run law falls: the widest element that still flows bit-continuously.
    Harness.case ("bits.ceiling", function ()
        local ceiling = Protocol.BIT_CEILING
        Expect.equal (Bits.width (2 ^ ceiling - 1), ceiling)
        Expect.equal (Bits.width (2 ^ ceiling), ceiling + 1)
    end),

    --[[
        The top of the domain. A logical value is at most 53 bits, so the width of the widest exact
        span is exactly that. One past it answers 54, which is arithmetic rather than a legal field,
        and what rejects it is compile.
    ]]
    Harness.case ("bits.widest", function ()
        Expect.equal (Bits.width (Protocol.EXACT - 1), WIDEST)
        Expect.equal (Bits.width (Protocol.EXACT), WIDEST + 1)
    end),

    --[[
        A span drawn inside a band of the powers of two answers that band. The two inequalities
        beside it are the definition restated, that the width holds every index in the span and no
        narrower width would, so a wrong answer fails as an off-by-one rather than as an unexplained
        mismatch.
    ]]
    Harness.property ("bits.banded", "leaves", function (rng: Rng.Rng)
        if Rng.bool (rng) then
            Expect.equal (Bits.width (-Rng.int (rng, 1, Protocol.EXACT - 1)), 0)
            return
        end

        local exponent = Rng.int (rng, 0, WIDEST)
        if exponent == 0 then
            Expect.equal (Bits.width (0), 0)
            return
        end

        --[[
            Tight to one edge of the band as often as anywhere between it. A width that rounds is
            only ever wrong within a step or two of an edge, and a uniform draw across a band of
            2^49 values never lands near one, so the case that finds a rounding fault never comes
            up.
        ]]
        local floor = 2 ^ (exponent - 1)
        local ceiling = 2 ^ exponent - 1
        local reach = math.min (2, ceiling - floor)

        local span
        local edge = Rng.int (rng, 0, 2)
        if edge == 0 then
            span = floor + Rng.int (rng, 0, reach)
        elseif edge == 1 then
            span = ceiling - Rng.int (rng, 0, reach)
        else
            span = Rng.int (rng, floor, ceiling)
        end

        local width = Bits.width (span)

        Expect.equal (width, exponent)
        Expect.holds (2 ^ width > span, `{width} bits cannot address a span of {span}`)
        Expect.holds (2 ^ (width - 1) <= span, `{width} bits is wider than a span of {span} needs`)
    end),
}
