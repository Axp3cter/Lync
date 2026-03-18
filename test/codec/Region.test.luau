--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("region3", function(): ()
    it("min + max", function(): ()
        local r = roundTrip(
            Lync.region3,
            Region3.new(Vector3.new(-10, -10, -10), Vector3.new(10, 10, 10))
        )
        expect(r.CFrame.Position.X):toBeCloseTo(0, 0.1)
        expect(r.Size.X):toBeCloseTo(20, 0.1)
    end)
    it("24 bytes", function(): ()
        local _, w = roundTrip(Lync.region3, Region3.new(Vector3.zero, Vector3.one))
        expect(w):toBe(24)
    end)
end)

describe("region3int16", function(): ()
    it("min + max", function(): ()
        local r = roundTrip(
            Lync.region3int16,
            Region3int16.new(Vector3int16.new(-10, -10, -10), Vector3int16.new(10, 10, 10))
        )
        expect(r.Min.X):toBe(-10)
        expect(r.Max.X):toBe(10)
    end)
    it("12 bytes", function(): ()
        local _, w = roundTrip(
            Lync.region3int16,
            Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(1, 1, 1))
        )
        expect(w):toBe(12)
    end)
end)

return nil
