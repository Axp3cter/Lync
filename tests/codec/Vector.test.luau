--!strict
--!optimize 2
-- Vector.test.luau — Round-trip tests for Vector2 and Vector3 codecs.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Vector.vec2", function (): ()
    it ("round-trips origin", function (): ()
        local result = roundTrip (Lync.vec2, Vector2.new (0, 0))
        expect (result.X):toBe (0)
        expect (result.Y):toBe (0)
    end)
    it ("round-trips positive values", function (): ()
        local result = roundTrip (Lync.vec2, Vector2.new (1.5, 2.5))
        expect (result.X):toBeCloseTo (1.5)
        expect (result.Y):toBeCloseTo (2.5)
    end)
    it ("round-trips negative values", function (): ()
        local result = roundTrip (Lync.vec2, Vector2.new (-100, -200))
        expect (result.X):toBeCloseTo (-100)
        expect (result.Y):toBeCloseTo (-200)
    end)
    it ("uses exactly 8 bytes", function (): ()
        local _, written, _ = roundTrip (Lync.vec2, Vector2.new (1, 2))
        expect (written):toBe (8)
    end)
end)

describe ("Vector.vec3", function (): ()
    it ("round-trips origin", function (): ()
        local result = roundTrip (Lync.vec3, Vector3.new (0, 0, 0))
        expect (result.X):toBe (0)
        expect (result.Y):toBe (0)
        expect (result.Z):toBe (0)
    end)
    it ("round-trips positive values", function (): ()
        local result = roundTrip (Lync.vec3, Vector3.new (10, 20, 30))
        expect (result.X):toBeCloseTo (10)
        expect (result.Y):toBeCloseTo (20)
        expect (result.Z):toBeCloseTo (30)
    end)
    it ("round-trips negative values", function (): ()
        local result = roundTrip (Lync.vec3, Vector3.new (-1.5, -2.5, -3.5))
        expect (result.X):toBeCloseTo (-1.5)
        expect (result.Y):toBeCloseTo (-2.5)
        expect (result.Z):toBeCloseTo (-3.5)
    end)
    it ("uses exactly 12 bytes", function (): ()
        local _, written, _ = roundTrip (Lync.vec3, Vector3.new (1, 2, 3))
        expect (written):toBe (12)
    end)
end)

return nil
