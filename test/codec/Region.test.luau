--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("Region.region3", function (): ()
    it ("round-trips origin", function (): ()
        local r = roundTrip (Lync.region3, Region3.new (Vector3.zero, Vector3.zero))
        local cf = r.CFrame
        expect (cf.Position.X):toBeCloseTo (0)
        expect (cf.Position.Y):toBeCloseTo (0)
        expect (cf.Position.Z):toBeCloseTo (0)
    end)
    it ("round-trips unit cube", function (): ()
        local original = Region3.new (Vector3.new (-1, -1, -1), Vector3.new (1, 1, 1))
        local r = roundTrip (Lync.region3, original)
        local size = r.Size
        expect (size.X):toBeCloseTo (2)
        expect (size.Y):toBeCloseTo (2)
        expect (size.Z):toBeCloseTo (2)
    end)
    it ("round-trips asymmetric", function (): ()
        local original = Region3.new (Vector3.new (10, 20, 30), Vector3.new (40, 50, 60))
        local r = roundTrip (Lync.region3, original)
        local pos = r.CFrame.Position
        expect (pos.X):toBeCloseTo (25)
        expect (pos.Y):toBeCloseTo (35)
        expect (pos.Z):toBeCloseTo (45)
    end)
    it ("uses 24 bytes", function (): ()
        local _, w = roundTrip (Lync.region3, Region3.new (Vector3.zero, Vector3.one))
        expect (w):toBe (24)
    end)
    it ("_size is 24", function (): ()
        expect ((Lync.region3 :: any)._size):toBe (24)
    end)
end)

describe ("Region.region3int16", function (): ()
    it ("round-trips origin", function (): ()
        local r = roundTrip (
            Lync.region3int16,
            Region3int16.new (Vector3int16.new (0, 0, 0), Vector3int16.new (0, 0, 0))
        )
        expect (r.Min.X):toBe (0)
        expect (r.Min.Y):toBe (0)
        expect (r.Min.Z):toBe (0)
        expect (r.Max.X):toBe (0)
        expect (r.Max.Y):toBe (0)
        expect (r.Max.Z):toBe (0)
    end)
    it ("round-trips positive", function (): ()
        local r = roundTrip (
            Lync.region3int16,
            Region3int16.new (Vector3int16.new (1, 2, 3), Vector3int16.new (10, 20, 30))
        )
        expect (r.Min.X):toBe (1)
        expect (r.Max.Z):toBe (30)
    end)
    it ("round-trips i16 bounds", function (): ()
        local r = roundTrip (
            Lync.region3int16,
            Region3int16.new (
                Vector3int16.new (-32768, -32768, -32768),
                Vector3int16.new (32767, 32767, 32767)
            )
        )
        expect (r.Min.X):toBe (-32768)
        expect (r.Max.Z):toBe (32767)
    end)
    it ("uses 12 bytes", function (): ()
        local _, w = roundTrip (
            Lync.region3int16,
            Region3int16.new (Vector3int16.new (0, 0, 0), Vector3int16.new (1, 1, 1))
        )
        expect (w):toBe (12)
    end)
    it ("_size is 12", function (): ()
        expect ((Lync.region3int16 :: any)._size):toBe (12)
    end)
end)

return nil
