--!strict
--!optimize 2
-- Color.test.luau — Round-trip tests for 3-byte Color3 codec.

local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)

local describe = Runner.describe
local it = Runner.it
local expect = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe ("Color3", function (): ()
    it ("round-trips black", function (): ()
        local result = roundTrip (Lync.color3, Color3.new (0, 0, 0))
        expect (result.R):toBeCloseTo (0, 0.01)
        expect (result.G):toBeCloseTo (0, 0.01)
        expect (result.B):toBeCloseTo (0, 0.01)
    end)
    it ("round-trips white", function (): ()
        local result = roundTrip (Lync.color3, Color3.new (1, 1, 1))
        expect (result.R):toBeCloseTo (1, 0.01)
        expect (result.G):toBeCloseTo (1, 0.01)
        expect (result.B):toBeCloseTo (1, 0.01)
    end)
    it ("round-trips pure red", function (): ()
        local result = roundTrip (Lync.color3, Color3.fromRGB (255, 0, 0))
        expect (result.R):toBeCloseTo (1, 0.01)
        expect (result.G):toBeCloseTo (0, 0.01)
        expect (result.B):toBeCloseTo (0, 0.01)
    end)
    it ("round-trips mid-value color within 1/255 tolerance", function (): ()
        local original = Color3.fromRGB (128, 64, 200)
        local result = roundTrip (Lync.color3, original)
        expect (result.R):toBeCloseTo (original.R, 1 / 255)
        expect (result.G):toBeCloseTo (original.G, 1 / 255)
        expect (result.B):toBeCloseTo (original.B, 1 / 255)
    end)
    it ("uses exactly 3 bytes", function (): ()
        local _, written, _ = roundTrip (Lync.color3, Color3.new ())
        expect (written):toBe (3)
    end)
end)

return nil
