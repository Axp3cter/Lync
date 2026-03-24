--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("float quantized", function(): ()
    it("u8 for 200 steps", function(): () expect((Lync.float(0, 100, 0.5) :: any)._size):toBe(1) end)
    it("u16 for 10000 steps", function(): () expect((Lync.float(0, 100, 0.01) :: any)._size):toBe(2) end)
    it("u32 for 100000+ steps", function(): () expect((Lync.float(0, 1000, 0.001) :: any)._size):toBe(4) end)
    it("round-trips midpoint", function(): () expect(roundTrip(Lync.float(0, 100, 0.5), 50)):toBeCloseTo(50, 0.5) end)
    it("round-trips min", function(): () expect(roundTrip(Lync.float(0, 100, 0.5), 0)):toBeCloseTo(0, 0.5) end)
    it("round-trips max", function(): () expect(roundTrip(Lync.float(0, 100, 0.5), 100)):toBeCloseTo(100, 0.5) end)
    it("clamps above max", function(): () expect(roundTrip(Lync.float(0, 100, 0.5), 200)):toBeCloseTo(100, 0.5) end)
    it("clamps below min", function(): () expect(roundTrip(Lync.float(0, 100, 0.5), -50)):toBeCloseTo(0, 0.5) end)
    it("negative range", function(): ()
        local c = Lync.float(-50, 50, 1)
        expect(roundTrip(c, -50)):toBeCloseTo(-50, 1)
        expect(roundTrip(c, 0)):toBeCloseTo(0, 1)
        expect(roundTrip(c, 50)):toBeCloseTo(50, 1)
    end)
    it("fine precision", function(): ()
        local c = Lync.float(0, 10, 0.001)
        expect(roundTrip(c, 5.555)):toBeCloseTo(5.555, 0.001)
    end)
    it("_min and _max metadata", function(): ()
        local c = Lync.float(-10, 10, 0.1) :: any
        expect(c._min):toBe(-10); expect(c._max):toBe(10)
    end)
    it("rejects min > max", function(): () expect(function(): () Lync.float(10, 5, 1) end):toThrow("min") end)
    it("rejects precision <= 0", function(): () expect(function(): () Lync.float(0, 100, 0) end):toThrow("precision") end)
    it("rejects negative precision", function(): () expect(function(): () Lync.float(0, 100, -1) end):toThrow("precision") end)
end)

return nil
