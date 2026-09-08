--!strict
--!optimize 2
-- The ranged-int width alone: how many bits a span of values costs on the wire.

local Bits = require("@src/kernel/Bits")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- The width of every span from none to sixteen, counted out by hand. The nth entry is the width
-- of a span of n minus one.
local SMALL = table.freeze({ 0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5 })

-- The widest a logical value may be, which bounds the exponents drawn.
local WIDEST = 53

return {
    Harness.case("bits.negative", function()
        Expect.equal(Bits.width(-1), 0)
        Expect.equal(Bits.width(-255), 0)
    end),

    Harness.case("bits.small", function()
        for index, counted in SMALL do
            local span = index - 1
            Expect.holds(Bits.width(span) == counted, `a span of {span} is {Bits.width(span)} bits`)
        end
    end),

    -- A power of two is one past the widths below it: 2 needs two bits, not one.
    Harness.case("bits.powers", function()
        for exponent = 0, WIDEST do
            local span = 2 ^ exponent
            Expect.holds(
                Bits.width(span) == exponent + 1,
                `2^{exponent} is {Bits.width(span)} bits`
            )
        end
    end),

    Harness.case("bits.below-powers", function()
        for exponent = 1, WIDEST do
            local span = 2 ^ exponent - 1
            Expect.holds(
                Bits.width(span) == exponent,
                `2^{exponent} - 1 is {Bits.width(span)} bits`
            )
        end
    end),

    -- One past a power, where a width computed through a logarithm stops telling the truth.
    Harness.case("bits.above-powers", function()
        for exponent = 1, WIDEST do
            local span = 2 ^ exponent + 1
            Expect.holds(
                Bits.width(span) == exponent + 1,
                `2^{exponent} + 1 is {Bits.width(span)} bits`
            )
        end
    end),

    -- A span drawn inside a band of the powers of two answers that band, tight to an edge as often
    -- as anywhere between, since a rounding fault only ever shows within a step of an edge.
    Harness.property("bits.banded", "leaves", function(rng: Rng.Rng)
        if rng:bool() then
            Expect.equal(Bits.width(-rng:int(1, 2 ^ WIDEST - 1)), 0)
            return
        end

        local exponent = rng:int(0, WIDEST)
        if exponent == 0 then
            Expect.equal(Bits.width(0), 0)
            return
        end

        local floor = 2 ^ (exponent - 1)
        local ceiling = 2 ^ exponent - 1
        local reach = math.min(2, ceiling - floor)
        local edge = rng:int(0, 2)
        local span = if edge == 0
            then floor + rng:int(0, reach)
            elseif edge == 1 then ceiling - rng:int(0, reach)
            else rng:int(floor, ceiling)

        local width = Bits.width(span)
        Expect.equal(width, exponent)
        Expect.holds(2 ^ width > span, `{width} bits cannot address a span of {span}`)
        Expect.holds(2 ^ (width - 1) <= span, `{width} bits is wider than a span of {span} needs`)
    end),
}
