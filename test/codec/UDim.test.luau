--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("udim", function(): ()
    it("_size = 8", function(): () expect((Lync.udim :: any)._size):toBe(8) end)
    it("zero", function(): () local r = roundTrip(Lync.udim, UDim.new(0, 0)); expect(r.Scale):toBe(0); expect(r.Offset):toBe(0) end)
    it("positive", function(): () local r = roundTrip(Lync.udim, UDim.new(0.5, 100)); expect(r.Scale):toBeCloseTo(0.5); expect(r.Offset):toBe(100) end)
    it("negative offset", function(): () local r = roundTrip(Lync.udim, UDim.new(1, -50)); expect(r.Offset):toBe(-50) end)
    it("large offset", function(): () local r = roundTrip(Lync.udim, UDim.new(0, 100000)); expect(r.Offset):toBe(100000) end)
    it("_typeCheck = UDim", function(): () expect((Lync.udim :: any)._typeCheck):toBe("UDim") end)
end)

describe("udim2", function(): ()
    it("_size = 16", function(): () expect((Lync.udim2 :: any)._size):toBe(16) end)
    it("zero", function(): ()
        local r = roundTrip(Lync.udim2, UDim2.new(UDim.new(0, 0), UDim.new(0, 0)))
        expect(r.X.Scale):toBe(0); expect(r.Y.Scale):toBe(0)
    end)
    it("positive values", function(): ()
        local r = roundTrip(Lync.udim2, UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)))
        expect(r.X.Scale):toBeCloseTo(0.5); expect(r.X.Offset):toBe(10); expect(r.Y.Offset):toBe(20)
    end)
    it("negative offsets", function(): ()
        local r = roundTrip(Lync.udim2, UDim2.new(UDim.new(0, -100), UDim.new(0, -200)))
        expect(r.X.Offset):toBe(-100); expect(r.Y.Offset):toBe(-200)
    end)
    it("_typeCheck = UDim2", function(): () expect((Lync.udim2 :: any)._typeCheck):toBe("UDim2") end)
end)

return nil
