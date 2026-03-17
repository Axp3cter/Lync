--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("color3", function (): ()
    it ("black", function (): ()
        local r = roundTrip (Lync.color3, Color3.new (0, 0, 0))
        expect (r.R):toBeCloseTo (0)
        expect (r.G):toBeCloseTo (0)
        expect (r.B):toBeCloseTo (0)
    end)
    it ("white", function (): ()
        local r = roundTrip (Lync.color3, Color3.new (1, 1, 1))
        expect (r.R):toBeCloseTo (1)
        expect (r.G):toBeCloseTo (1)
        expect (r.B):toBeCloseTo (1)
    end)
    it ("fromRGB", function (): ()
        local r = roundTrip (Lync.color3, Color3.fromRGB (128, 64, 255))
        expect (r.R):toBeCloseTo (128 / 255, 0.01)
    end)
    it ("3 bytes", function (): ()
        local _, w = roundTrip (Lync.color3, Color3.new ())
        expect (w):toBe (3)
    end)
    it ("_size = 3", function (): ()
        expect ((Lync.color3 :: any)._size):toBe (3)
    end)
end)

return nil
