--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("region3", function(): ()
    it("_size = 24", function(): () expect((Lync.region3 :: any)._size):toBe(24) end)
    it("basic round-trip preserves bounds", function(): ()
        local r = roundTrip(Lync.region3, Region3.new(Vector3.new(-10, -10, -10), Vector3.new(10, 10, 10)))
        expect(r.Size.X):toBeCloseTo(20, 0.01)
    end)
    it("_typeCheck = Region3", function(): () expect((Lync.region3 :: any)._typeCheck):toBe("Region3") end)
end)

describe("region3int16", function(): ()
    it("_size = 12", function(): () expect((Lync.region3int16 :: any)._size):toBe(12) end)
    it("basic", function(): ()
        local r = roundTrip(Lync.region3int16, Region3int16.new(Vector3int16.new(-10, -20, -30), Vector3int16.new(10, 20, 30)))
        expect(r.Min.X):toBe(-10); expect(r.Max.Z):toBe(30)
    end)
    it("negative values", function(): ()
        local r = roundTrip(Lync.region3int16, Region3int16.new(Vector3int16.new(-32768, 0, 0), Vector3int16.new(32767, 0, 0)))
        expect(r.Min.X):toBe(-32768); expect(r.Max.X):toBe(32767)
    end)
    it("_typeCheck = Region3int16", function(): () expect((Lync.region3int16 :: any)._typeCheck):toBe("Region3int16") end)
end)

return nil
