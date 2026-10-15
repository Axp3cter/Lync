--!strict
--!optimize 2
-- What a constructor will take: the tests every one of them makes of a parameter or a child.

local Base = require("@src/codec/Base")
local Legality = require("@src/codec/Legality")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local KIND = "array"
local AT = "its element"
local LOW = 0
local HIGH = 4

-- Numbers on the line, and the four readings that are no place on one at all.
local ON_THE_LINE = table.freeze({ 0, 1, -1, 0.5, -0.5, 2 ^ 52, -(2 ^ 52) })
local NOWHERE = table.freeze({ 0 / 0, 1 / 0, -1 / 0, -(0 / 0) })

-- The words a refusal gave, or nothing where the call came back.
local function refused(call: () -> ()): string?
    local ok, thrown = pcall(call)
    return if ok then nil else tostring(thrown)
end

local function said(call: () -> (), part: string, why: string)
    local words = refused(call)
    Expect.holds(words ~= nil, why)
    Expect.holds(string.find(words :: string, part, 1, true) ~= nil, `it said "{words}"`)
end

return {
    -- A numeric string is the one thing a checker cannot stop and the arithmetic would take.
    Harness.case("legality.finite", function()
        for _, value in ON_THE_LINE do
            Expect.holds(Legality.finite(value), `{value} is a number and was refused`)
        end
        for _, value in NOWHERE do
            Expect.equal(Legality.finite(value), false)
        end
        for _, value in { "1", true, {}, nil } do
            Expect.equal(Legality.finite(value :: any), false)
        end
    end),

    Harness.case("legality.whole", function()
        for _, value in { 0, 1, -1, 2 ^ 52, -(2 ^ 52) } do
            Expect.holds(Legality.whole(value), `{value} is whole and was refused`)
        end
        for _, value in { 0.5, -0.5, 1e-9 } do
            Expect.equal(Legality.whole(value), false)
        end
        for _, value in NOWHERE do
            Expect.equal(Legality.whole(value), false)
        end
        Expect.equal(Legality.whole("2" :: any), false)
    end),

    -- A ceiling of none, a floor of none, and bounds that meet are all legal ranges.
    Harness.case("legality.counts", function()
        Legality.counts(KIND, 0, 0)
        Legality.counts(KIND, 0, HIGH)
        Legality.counts(KIND, HIGH, HIGH)
        Legality.counts(KIND, 0, 2 ^ 40)
        Legality.counts(KIND, 2 ^ 40, 2 ^ 40)
    end),

    -- Each of the three ways a range is wrong has words that name which.
    Harness.case("legality.counts-refuses", function()
        said(function()
            Legality.counts(KIND, 0, 1.5)
        end, "whole bounds", "a fractional bound was taken")
        said(function()
            Legality.counts(KIND, -1, HIGH)
        end, "from zero up", "a bound below zero was taken")
        said(function()
            Legality.counts(KIND, HIGH, LOW)
        end, "in order", "bounds the wrong way round were taken")
    end),

    -- A child has to be a codec, and the refusal names the place and what arrived.
    Harness.case("legality.codec", function()
        Legality.codec(KIND, AT, Base.make("bool"))
        Legality.codec(KIND, AT, Base.make("int", { min = LOW, max = HIGH }))

        for _, value in { 1, "bool", true, {} } do
            local words = refused(function()
                Legality.codec(KIND, AT, value :: any)
            end)
            Expect.holds(words ~= nil, `{typeof(value)} was taken as a codec`)
            Expect.holds(string.find(words :: string, AT, 1, true) ~= nil, "it named no place")
            Expect.holds(string.find(words :: string, typeof(value), 1, true) ~= nil, "nor what")
        end

        said(function()
            Legality.codec(KIND, AT, Base.make("empty"))
        end, "no empty", "an empty was taken as a part")
    end),

    -- A bare child is a codec first, and never an optional.
    Harness.case("legality.bare", function()
        Legality.bare(KIND, AT, Base.make("bool"))
        Legality.bare(KIND, AT, Base.make("struct", nil, { a = Base.make("bool") }))

        local maybe = Base.make("optional", nil, { inner = Base.make("bool") })
        said(function()
            Legality.bare(KIND, AT, maybe)
        end, "no optional", "an optional was taken where a slot is already absent")
        said(function()
            Legality.bare(KIND, AT, 1 :: any)
        end, "takes a codec", "a number was taken as a bare child")
    end),
}
