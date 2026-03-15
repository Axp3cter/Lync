--!strict
--!optimize 2
-- Tuple.test.luau — Round-trip tests for positional ordered codec.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Tuple", function (): ()
    local codec = Lync.tuple (Lync.u8, Lync.string, Lync.bool)

    it ("round-trips a 3-element tuple", function (): ()
        local result = roundTrip (codec, { 42, "hello", true })
        expect (result[1]):toBe (42)
        expect (result[2]):toBe ("hello")
        expect (result[3]):toBe (true)
    end)
    it ("round-trips with edge values", function (): ()
        local result = roundTrip (codec, { 0, "", false })
        expect (result[1]):toBe (0)
        expect (result[2]):toBe ("")
        expect (result[3]):toBe (false)
    end)
    it ("wire size matches sum of inner codecs", function (): ()
        local _, written, _ = roundTrip (codec, { 1, "ab", true })
        expect (written):toBe (5)
    end)
end)

describe ("Tuple single-element", function (): ()
    local codec = Lync.tuple (Lync.f64)

    it ("round-trips single-element tuple", function (): ()
        local result = roundTrip (codec, { math.pi })
        expect (result[1]):toBe (math.pi)
    end)
end)

describe ("Tuple validation", function (): ()
    it ("throws on empty definition", function (): ()
        expect (function (): ()
            Lync.tuple ()
        end):toThrow ("at least one codec")
    end)
end)

return nil
