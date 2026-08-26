--!strict
--!optimize 2
--[[
    The platform's own answers, which shipped code rests on everywhere and checks nowhere.
]]

local Protocol = require ("@src/wire/Protocol")
local Wide = require ("@src/kernel/Wide")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Public --------------------------------------------------------------

return {
    --[[
        Whether this run has a sixty-four bit integer library, which is the one platform answer the
        library branches its whole arithmetic on. Roblox has none and a standalone run has one, so
        the two carriers are not a spare and a fallback: they are two builds, and which of them a
        place is running is this reading and nothing else.
    ]]
    Harness.case ("platform.integers", function ()
        local held: any = integer

        Expect.equal (Wide.native, held ~= nil)
        Expect.equal (Wide.carriers.own ~= nil, held ~= nil)
        Expect.holds (Wide.carriers.halves ~= nil, "this build has no pair of halves")
    end),

    --[[
        A remainder takes the sign of what it divides by, which brings a negative count round the
        top of a wrapping space rather than off the bottom. A stamp behind its epoch, a sequence
        across the wrap and an angle below zero all rest on it, and truncation would say nothing.
    ]]
    Harness.case ("platform.remainder", function ()
        Expect.equal (-1 % 256, 255)
        Expect.equal (-256 % 256, 0)
        Expect.equal (-7 % 3, 2)
        Expect.equal (7 % -3, -2)
        Expect.equal (1 % -256, -255)
        Expect.equal (-0.5 % 1, 0.5)
    end),

    --[[
        A half rounds away from zero. The stamp reconstruction splits its one tie on this and the
        quantization grid splits every midpoint on it, so two machines rounding halves differently
        disagree about bytes.
    ]]
    Harness.case ("platform.halves", function ()
        Expect.equal (math.round (0.5), 1)
        Expect.equal (math.round (-0.5), -1)
        Expect.equal (math.round (1.5), 2)
        Expect.equal (math.round (-1.5), -2)
        Expect.equal (math.round (2.5), 3)
        Expect.equal (math.round (0.4999999999999999), 0)
    end),

    --[[
        A double counts to the ceiling the protocol names and no further. The first line is the one
        worth having, since it holds the wire's ceiling and the platform's against each other rather
        than assuming they are one number.
    ]]
    Harness.case ("platform.exact", function ()
        Expect.equal (Protocol.EXACT, 2 ^ 53)

        Expect.holds (Protocol.EXACT + 1 == Protocol.EXACT, "a double counted past the ceiling")
        Expect.holds (Protocol.EXACT + 2 ~= Protocol.EXACT, "a double stopped counting entirely")
        Expect.holds (
            Protocol.EXACT - 1 + 1 == Protocol.EXACT,
            "the step below the ceiling was lost"
        )
    end),

    --[[
        A string compares as unsigned bytes, stopping at neither a zero nor the end of what a text
        is. No shipped line rests on this and a suite does: the order read off a run of bytes is
        measured against this comparison, so a platform ordering strings any other way would leave
        that suite passing and proving nothing.
    ]]
    Harness.case ("platform.strings", function ()
        Expect.holds ("\1" < "\255", "a high byte did not compare above a low one")
        Expect.holds (not ("\255" < "\1"), "a high byte compared below a low one")
        Expect.holds ("\0\2" < "\0\3", "a comparison stopped at a byte of none")
        Expect.holds ("" < "\0", "an empty string did not come first")
        Expect.holds ("ab" < "abc", "a prefix did not come first")
    end),
}
