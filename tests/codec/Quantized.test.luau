--!strict
--!optimize 2
-- Quantized.test.luau — Round-trip tests for fixed-point quantized codecs.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Quantized.float", function (): ()
    local codec = Lync.quantizedFloat (0, 100, 0.1)

    it ("round-trips midpoint within precision", function (): ()
        expect (roundTrip (codec, 50)):toBeCloseTo (50, 0.1)
    end)
    it ("round-trips min boundary", function (): ()
        expect (roundTrip (codec, 0)):toBeCloseTo (0, 0.1)
    end)
    it ("round-trips max boundary", function (): ()
        expect (roundTrip (codec, 100)):toBeCloseTo (100, 0.1)
    end)
    it ("clamps below min", function (): ()
        expect (roundTrip (codec, -50)):toBeCloseTo (0, 0.1)
    end)
    it ("clamps above max", function (): ()
        expect (roundTrip (codec, 200)):toBeCloseTo (100, 0.1)
    end)
    it ("uses 2 bytes for range 0-100 at 0.1 precision", function (): ()
        local _, written, _ = roundTrip (codec, 50)
        expect (written):toBe (2)
    end)
end)

describe ("Quantized.float zero-delta", function (): ()
    local codec = Lync.quantizedFloat (42, 42, 0.1)

    it ("always returns the constant value", function (): ()
        expect (roundTrip (codec, 999)):toBe (42)
    end)
end)

describe ("Quantized.vec3", function (): ()
    local codec = Lync.quantizedVec3 (-500, 500, 0.1)

    it ("round-trips origin within precision", function (): ()
        local result = roundTrip (codec, Vector3.new (0, 0, 0))
        expect (result.X):toBeCloseTo (0, 0.1)
        expect (result.Y):toBeCloseTo (0, 0.1)
        expect (result.Z):toBeCloseTo (0, 0.1)
    end)
    it ("round-trips positive values", function (): ()
        local result = roundTrip (codec, Vector3.new (100, 200, 300))
        expect (result.X):toBeCloseTo (100, 0.1)
        expect (result.Y):toBeCloseTo (200, 0.1)
        expect (result.Z):toBeCloseTo (300, 0.1)
    end)
    it ("round-trips negative values", function (): ()
        local result = roundTrip (codec, Vector3.new (-100, -200, -300))
        expect (result.X):toBeCloseTo (-100, 0.1)
        expect (result.Y):toBeCloseTo (-200, 0.1)
        expect (result.Z):toBeCloseTo (-300, 0.1)
    end)
end)

describe ("Quantized validation", function (): ()
    it ("throws when min > max", function (): ()
        expect (function (): ()
            Lync.quantizedFloat (100, 0, 0.1)
        end):toThrow ("min")
    end)
    it ("throws when precision is zero", function (): ()
        expect (function (): ()
            Lync.quantizedFloat (0, 100, 0)
        end):toThrow ("precision")
    end)
end)

return nil
