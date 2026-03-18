--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("numberRange", function(): ()
    it("0-1", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(0, 1))
        expect(r.Min):toBeCloseTo(0)
        expect(r.Max):toBeCloseTo(1)
    end)
    it("negative", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(-100, -50))
        expect(r.Min):toBeCloseTo(-100)
        expect(r.Max):toBeCloseTo(-50)
    end)
    it("single value", function(): ()
        local r = roundTrip(Lync.numberRange, NumberRange.new(42))
        expect(r.Min):toBeCloseTo(42)
        expect(r.Max):toBeCloseTo(42)
    end)
    it("8 bytes", function(): ()
        local _, w = roundTrip(Lync.numberRange, NumberRange.new(0))
        expect(w):toBe(8)
    end)
end)

return nil
