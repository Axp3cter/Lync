--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("f16", function (): ()
    it ("0", function (): ()
        expect (roundTrip (Lync.f16, 0)):toBe (0)
    end)
    it ("1", function (): ()
        expect (roundTrip (Lync.f16, 1)):toBeCloseTo (1, 0.01)
    end)
    it ("-1", function (): ()
        expect (roundTrip (Lync.f16, -1)):toBeCloseTo (-1, 0.01)
    end)
    it ("0.5", function (): ()
        expect (roundTrip (Lync.f16, 0.5)):toBeCloseTo (0.5, 0.01)
    end)
    it ("2 bytes", function (): ()
        local _, w = roundTrip (Lync.f16, 1)
        expect (w):toBe (2)
    end)
end)

describe ("f16 edge cases", function (): ()
    it ("large clamps to max representable", function (): ()
        local v = roundTrip (Lync.f16, 100000) :: number
        expect (v > 60000):toBe (true)
    end)
    it ("very small positive", function (): ()
        local v = roundTrip (Lync.f16, 0.001) :: number
        expect (v):toBeCloseTo (0.001, 0.001)
    end)
    it ("negative zero becomes zero", function (): ()
        local v = roundTrip (Lync.f16, -0.0) :: number
        expect (v):toBe (0)
    end)
    it ("1024 exact", function (): ()
        expect (roundTrip (Lync.f16, 1024)):toBeCloseTo (1024, 1)
    end)
    it ("0.1 approximate", function (): ()
        local v = roundTrip (Lync.f16, 0.1) :: number
        expect (math.abs (v - 0.1)):toBeLessThan (0.001)
    end)
    it ("negative large", function (): ()
        local v = roundTrip (Lync.f16, -65000) :: number
        expect (v < -60000):toBe (true)
    end)
    it ("subnormal near zero", function (): ()
        local v = roundTrip (Lync.f16, 0.00001) :: number
        expect (math.abs (v)):toBeLessThan (0.001)
    end)
end)

return nil
