--!strict
--!optimize 2
-- Float16.test.luau — Round-trip tests for half-precision float codec.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Float16", function (): ()
    it ("round-trips 0", function (): ()
        expect (roundTrip (Lync.f16, 0)):toBe (0)
    end)
    it ("round-trips 1.0 exactly", function (): ()
        expect (roundTrip (Lync.f16, 1)):toBe (1)
    end)
    it ("round-trips -1.0 exactly", function (): ()
        expect (roundTrip (Lync.f16, -1)):toBe (-1)
    end)
    it ("round-trips 0.5 exactly", function (): ()
        expect (roundTrip (Lync.f16, 0.5)):toBe (0.5)
    end)
    it ("round-trips 65504 (max half)", function (): ()
        expect (roundTrip (Lync.f16, 65504)):toBe (65504)
    end)
    it ("clamps overflow to inf", function (): ()
        expect (roundTrip (Lync.f16, 100000)):toBe (math.huge)
    end)
    it ("preserves negative zero sign", function (): ()
        local result = roundTrip (Lync.f16, -0.0)
        expect (1 / result):toBe (-math.huge)
    end)
    it ("round-trips small value within half precision", function (): ()
        expect (roundTrip (Lync.f16, 3.14)):toBeCloseTo (3.14, 0.01)
    end)
    it ("uses exactly 2 bytes", function (): ()
        local _, written, _ = roundTrip (Lync.f16, 1)
        expect (written):toBe (2)
    end)
end)

return nil
