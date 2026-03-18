--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("rect", function(): ()
    it("zero", function(): ()
        local r = roundTrip(Lync.rect, Rect.new(0, 0, 0, 0))
        expect(r.Min.X):toBeCloseTo(0)
        expect(r.Max.X):toBeCloseTo(0)
    end)
    it("positive", function(): ()
        local r = roundTrip(Lync.rect, Rect.new(10, 20, 300, 400))
        expect(r.Min.X):toBeCloseTo(10)
        expect(r.Min.Y):toBeCloseTo(20)
        expect(r.Max.X):toBeCloseTo(300)
        expect(r.Max.Y):toBeCloseTo(400)
    end)
    it("16 bytes", function(): ()
        local _, w = roundTrip(Lync.rect, Rect.new(0, 0, 1, 1))
        expect(w):toBe(16)
    end)
end)

return nil
