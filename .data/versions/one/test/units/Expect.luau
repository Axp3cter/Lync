--!strict
--!optimize 2
-- The expectation surface held to raising, asked through pcall since it cannot report through
-- itself.

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LOW = 1
local HIGH = 2
local SLACK = 0.5
local BYTES = 8
local AT = 3

local function is(held: boolean, why: string)
    if not held then error(`the expectation surface {why}`, 0) end
end

local function raised(call: () -> ()): boolean
    return not pcall(call)
end

local function bytes(): buffer
    local out = buffer.create(BYTES)
    for at = 0, BYTES - 1 do
        buffer.writeu8(out, at, at + 1)
    end
    return out
end

return {
    Harness.case("expect.equal-raises", function()
        is(
            raised(function()
                Expect.equal(LOW, HIGH)
            end),
            "took two numbers that differ"
        )
        is(not raised(function()
            Expect.equal(LOW, LOW)
        end), "refused two numbers that agree")
    end),

    Harness.case("expect.holds-raises", function()
        is(
            raised(function()
                Expect.holds(false, "why")
            end),
            "took a claim that is false"
        )
        is(not raised(function()
            Expect.holds(true, "why")
        end), "refused one that is true")
    end),

    Harness.case("expect.near-raises", function()
        is(
            raised(function()
                Expect.near(LOW, HIGH, SLACK)
            end),
            "took a gap past its slack"
        )
        is(not raised(function()
            Expect.near(LOW, LOW + SLACK, SLACK)
        end), "refused a gap under")
    end),

    Harness.case("expect.throws-raises", function()
        is(
            raised(function()
                Expect.throws(function() end)
            end),
            "took a call that returned"
        )
        is(not raised(function()
            Expect.throws(function()
                error("gone", 0)
            end)
        end), "refused a call that threw")
        is(
            raised(function()
                Expect.throws(function()
                    error("gone", 0)
                end, "elsewhere")
            end),
            "took a throw without the phrase asked for"
        )
    end),

    Harness.case("expect.alike-answers", function()
        is(Expect.alike(LOW, LOW), "says two numbers that agree do not")
        is(not Expect.alike(LOW, HIGH), "says two numbers that differ agree")
        is(not raised(function()
            Expect.alike(LOW, HIGH)
        end), "raises where it should answer")
    end),

    -- A failure wears a mark telling it from a crash, which is how the runner tells the two apart.
    Harness.case("expect.failed-marks", function()
        local ok, caught = pcall(function()
            Expect.holds(false, "why")
        end)
        is(not ok, "did not raise where a claim is false")
        is(Expect.failed(caught) ~= nil, "raised something it does not recognise as its own")

        local plain = select(
            2,
            pcall(function()
                error("an ordinary crash", 0)
            end)
        )
        is(Expect.failed(plain) == nil, "takes an ordinary crash for one of its own failures")
    end),

    Harness.case("expect.walks-nested", function()
        local deep = { one = { two = { three = LOW } } }
        local apart = { one = { two = { three = HIGH } } }
        is(
            raised(function()
                Expect.equal(deep, apart)
            end),
            "does not walk a nested table"
        )
        is(not raised(function()
            Expect.equal(deep, deep)
        end), "refuses a table for itself")
    end),

    Harness.case("expect.walks-absent-keys", function()
        is(
            raised(function()
                Expect.equal({ a = LOW, b = LOW }, { a = LOW })
            end),
            "does not notice a key the expected side has not got"
        )
        is(
            raised(function()
                Expect.equal({ a = LOW }, { a = LOW, b = LOW })
            end),
            "does not notice a key the actual side has not got"
        )
    end),

    Harness.case("expect.walks-a-cycle", function()
        local ring: { [string]: any } = {}
        ring.self = ring
        local other: { [string]: any } = {}
        other.self = other
        is(not raised(function()
            Expect.equal(ring, other)
        end), "cannot walk a table cycle")
    end),

    Harness.case("expect.walks-bytes", function()
        local one, two = bytes(), bytes()
        is(not raised(function()
            Expect.equal(one, two)
        end), "takes equal buffers as apart")

        buffer.writeu8(two, AT, 0)
        is(
            raised(function()
                Expect.equal(one, two)
            end),
            "takes buffers that differ as one"
        )

        local short = buffer.create(BYTES - 1)
        is(
            raised(function()
                Expect.equal(one, short)
            end),
            "does not compare buffer lengths"
        )
    end),

    -- NaN equals nothing under `==` and a signed zero equals its opposite, and the walk fixes both.
    Harness.case("expect.exact-numbers", function()
        local nan = 0 / 0
        is(not raised(function()
            Expect.equal(nan, nan)
        end), "cannot compare nan with itself")
        is(
            raised(function()
                Expect.equal(nan, LOW)
            end),
            "takes nan for a number"
        )
        is(
            raised(function()
                Expect.equal(0, -0)
            end),
            "takes a signed zero for its opposite"
        )
    end),

    Harness.case("expect.kinds-apart", function()
        is(
            raised(function()
                Expect.equal(LOW, tostring(LOW))
            end),
            "takes a number for a string"
        )
        is(
            raised(function()
                Expect.equal(nil, LOW)
            end),
            "takes nothing for a number"
        )
        is(
            raised(function()
                Expect.equal({}, LOW)
            end),
            "takes a table for a number"
        )
    end),

    Harness.case("expect.tolerance-is-nears-alone", function()
        is(
            raised(function()
                Expect.equal(LOW, LOW + SLACK)
            end),
            "lets a gap through equal"
        )
        is(
            raised(function()
                Expect.near(LOW, LOW + SLACK + SLACK, SLACK)
            end),
            "lets a gap past the slack through near"
        )
    end),
}
