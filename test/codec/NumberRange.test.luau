--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("numberRange", function(): ()
    it("_size = 8", function(): ()
        expect((Lync.numberRange :: any)._size):toBe(8)
    end)
    it("basic", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(0, 100))
        expect(r.Min):toBeCloseTo(0)
        expect(r.Max):toBeCloseTo(100)
    end)
    it("negative", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(-50, 50))
        expect(r.Min):toBeCloseTo(-50)
        expect(r.Max):toBeCloseTo(50)
    end)
    it("equal min max", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(42, 42))
        expect(r.Min):toBeCloseTo(42)
        expect(r.Max):toBeCloseTo(42)
    end)
    it("_typeCheck = NumberRange", function(): ()
        expect((Lync.numberRange :: any)._typeCheck):toBe("NumberRange")
    end)
end)

return nil
