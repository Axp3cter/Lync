--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("ray", function (): ()
    it ("origin + direction", function (): ()
        local r = roundTrip (Lync.ray, Ray.new (Vector3.new (1, 2, 3), Vector3.new (0, 1, 0)))
        expect (r.Origin.X):toBeCloseTo (1)
        expect (r.Origin.Y):toBeCloseTo (2)
        expect (r.Origin.Z):toBeCloseTo (3)
        expect (r.Direction.Y):toBeCloseTo (1)
    end)
    it ("negative dir", function (): ()
        local r = roundTrip (Lync.ray, Ray.new (Vector3.zero, Vector3.new (-1, -1, -1)))
        expect (r.Direction.X):toBeCloseTo (-1)
    end)
    it ("24 bytes", function (): ()
        local _, w = roundTrip (Lync.ray, Ray.new (Vector3.zero, Vector3.yAxis))
        expect (w):toBe (24)
    end)
end)

return nil
