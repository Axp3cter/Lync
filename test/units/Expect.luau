--!strict
--!optimize 2
--[[
    The expectation surface held to raising, which is the one thing nothing else here can check.
]]

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- Two numbers a tolerance can sit either side of, and the tolerance that does.
const LOW = 1
const HIGH = 2
const SLACK = 0.5

-- A run of bytes, and the one byte a copy of it differs in.
const BYTES = 8
const AT = 3

-- Private -------------------------------------------------------------

--[[
    A claim raised through Luau rather than through `Expect`, because a suite about the expectation
    surface cannot report through the thing it is asking about. `Cases` in `verify` is written this
    way for the same reason, one layer up.
]]
local function is (held: boolean, why: string)
    if held then return end
    error (`the expectation surface {why}`, 0)
end

-- Whether a call raised at all, read without `Expect.throws`, which is itself under test here.
local function raised (call: () -> ()): boolean
    local ok = pcall (call)
    return not ok
end

-- A buffer of a known run, so two of them differ only where a check puts the difference.
local function bytes (): buffer
    local out = buffer.create (BYTES)
    for at = 0, BYTES - 1 do
        buffer.writeu8 (out, at, at + 1)
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        The claim the whole repository rests on: a difference raises. Asked through `pcall` rather
        than through `throws`, so a `throws` that stopped working could not answer for `equal`.
    ]]
    Harness.case ("expect.equal-raises", function ()
        is (raised (function () Expect.equal (LOW, HIGH) end), "took two numbers that differ")
        is (not raised (function () Expect.equal (LOW, LOW) end), "refused two numbers that agree")
    end),

    -- The other three that raise, each asked the same way and none through another.
    Harness.case ("expect.holds-raises", function ()
        is (raised (function () Expect.holds (false, "why") end), "took a claim that is false")
        is (not raised (function () Expect.holds (true, "why") end), "refused one that is true")
    end),

    Harness.case ("expect.near-raises", function ()
        is (raised (function () Expect.near (LOW, HIGH, SLACK) end), "took a gap past its slack")
        is (
            not raised (function () Expect.near (LOW, LOW + SLACK, SLACK) end),
            "refused a gap under"
        )
    end),

    --[[
        `throws` is the one call nothing else can hold, since holding it needs it. So it is asked
        of both answers directly: a call that raises, and a call that does not.
    ]]
    Harness.case ("expect.throws-raises", function ()
        is (
            raised (function ()
                Expect.throws (function () end)
            end),
            "took a call that returned where a throw was wanted"
        )
        is (not raised (function ()
            Expect.throws (function () error ("gone", 0) end)
        end), "refused a call that threw")
        is (
            raised (function ()
                Expect.throws (function () error ("gone", 0) end, "elsewhere")
            end),
            "took a throw that does not carry the phrase asked for"
        )
    end),

    --[[
        The two that answer rather than raise. A caller reads what they say, so what is asked of
        them is the answer and not a raise.
    ]]
    Harness.case ("expect.alike-answers", function ()
        is (Expect.alike (LOW, LOW), "says two numbers that agree do not")
        is (not Expect.alike (LOW, HIGH), "says two numbers that differ agree")
        is (not raised (function () Expect.alike (LOW, HIGH) end), "raises where it should answer")
    end),

    --[[
        A failure wears a mark telling it from a crash, which is how a runner reports a claim that
        did not hold apart from code that fell over.
    ]]
    Harness.case ("expect.failed-marks", function ()
        local ok, caught = pcall (function () Expect.holds (false, "why") end)

        is (not ok, "did not raise where a claim is false")
        is (Expect.failed (caught) ~= nil, "raised something it does not recognise as its own")

        local plain = select (2, pcall (function () error ("an ordinary crash", 0) end))
        is (Expect.failed (plain) == nil, "takes an ordinary crash for one of its own failures")
    end),

    --[[
        A walk that stopped at the top would pass every nested difference in the repository, and
        every record this library replicates is a table inside a table.
    ]]
    Harness.case ("expect.walks-nested", function ()
        local deep = { one = { two = { three = LOW } } }
        local apart = { one = { two = { three = HIGH } } }

        is (raised (function () Expect.equal (deep, apart) end), "does not walk a nested table")
        is (not raised (function () Expect.equal (deep, deep) end), "refuses a table for itself")
    end),

    -- A key one side holds and the other does not, which a walk comparing only shared keys misses.
    Harness.case ("expect.walks-absent-keys", function ()
        is (
            raised (function () Expect.equal ({ a = LOW, b = LOW }, { a = LOW }) end),
            "does not notice a key the expected side has not got"
        )
        is (
            raised (function () Expect.equal ({ a = LOW }, { a = LOW, b = LOW }) end),
            "does not notice a key the actual side has not got"
        )
    end),

    --[[
        A table holding itself. The walk marks what it has seen, and a walk that did not would run
        the stack out rather than answer, which reads as a crash and not as a difference.
    ]]
    Harness.case ("expect.walks-a-cycle", function ()
        local ring: { [string]: any } = {}
        ring.self = ring

        local other: { [string]: any } = {}
        other.self = other

        is (not raised (function () Expect.equal (ring, other) end), "cannot walk a table cycle")
    end),

    --[[
        Bytes, which are compared by their contents rather than by being the same buffer. A frame is
        a buffer and every claim about what went on the wire is one of these.
    ]]
    Harness.case ("expect.walks-bytes", function ()
        local one, two = bytes (), bytes ()
        is (not raised (function () Expect.equal (one, two) end), "takes equal buffers as apart")

        buffer.writeu8 (two, AT, 0)
        is (raised (function () Expect.equal (one, two) end), "takes buffers that differ as one")

        local short = buffer.create (BYTES - 1)
        is (raised (function () Expect.equal (one, short) end), "does not compare buffer lengths")
    end),

    --[[
        The two numbers Luau will not answer for. NaN is equal to nothing including itself, so a
        walk using `==` calls two of them apart, and a signed zero compares equal to its opposite.
    ]]
    Harness.case ("expect.exact-numbers", function ()
        local nan = 0 / 0
        is (not raised (function () Expect.equal (nan, nan) end), "cannot compare nan with itself")
        is (raised (function () Expect.equal (nan, LOW) end), "takes nan for a number")
        is (raised (function () Expect.equal (0, -0) end), "takes a signed zero for its opposite")
    end),

    -- A value of one kind against a value of another, which is a difference before any comparing.
    Harness.case ("expect.kinds-apart", function ()
        is (
            raised (function () Expect.equal (LOW, tostring (LOW)) end),
            "takes a number for a string"
        )
        is (raised (function () Expect.equal (nil, LOW) end), "takes nothing for a number")
        is (raised (function () Expect.equal ({}, LOW) end), "takes a table for a number")
    end),

    --[[
        The slack `near` is for, and the exactness `equal` is for, held apart. A tolerance leaking
        into `equal` would take every rounding this library refuses to make.
    ]]
    Harness.case ("expect.tolerance-is-nears-alone", function ()
        is (
            raised (function () Expect.equal (LOW, LOW + SLACK) end),
            "lets a gap through the check that is meant to be exact"
        )
        is (
            raised (function () Expect.near (LOW, LOW + SLACK + SLACK, SLACK) end),
            "lets a gap past the slack through the check that is meant to allow one"
        )
    end),
}
