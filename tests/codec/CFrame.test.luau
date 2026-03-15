--!strict
--!optimize 2
-- CFrame.test.luau — Round-trip tests for axis-angle CFrame codec.

local Runner = require(script.Parent.Parent.Runner)
local Lync   = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("CFrame", function(): ()
    it("round-trips identity CFrame", function(): ()
        local result = roundTrip(Lync.cframe, CFrame.new(0, 0, 0))
        expect(result.Position.X):toBeCloseTo(0)
        expect(result.Position.Y):toBeCloseTo(0)
        expect(result.Position.Z):toBeCloseTo(0)
    end)
    it("round-trips translation-only CFrame", function(): ()
        local result = roundTrip(Lync.cframe, CFrame.new(10, 20, 30))
        expect(result.Position.X):toBeCloseTo(10)
        expect(result.Position.Y):toBeCloseTo(20)
        expect(result.Position.Z):toBeCloseTo(30)
    end)
    it("round-trips rotated CFrame", function(): ()
        local original = CFrame.new(5, 10, 15) * CFrame.Angles(math.pi / 4, math.pi / 3, 0)
        local result   = roundTrip(Lync.cframe, original)
        expect(result.Position.X):toBeCloseTo(original.Position.X, 0.01)
        expect(result.Position.Y):toBeCloseTo(original.Position.Y, 0.01)
        expect(result.Position.Z):toBeCloseTo(original.Position.Z, 0.01)
    end)
    it("uses exactly 24 bytes", function(): ()
        local _, written, _ = roundTrip(Lync.cframe, CFrame.new())
        expect(written):toBe(24)
    end)
end)

return nil
