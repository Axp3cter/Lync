--!strict
--!optimize 2
local Lync = require (script.Parent.Parent.Parent)
local Runner = require (script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe ("Sequence.numberSequence", function (): ()
    it ("round-trips two keypoints", function (): ()
        local original = NumberSequence.new (0, 1)
        local r = roundTrip (Lync.numberSequence, original)
        local kps = r.Keypoints
        expect (#kps):toBe (2)
        expect (kps[1].Time):toBeCloseTo (0)
        expect (kps[1].Value):toBeCloseTo (0)
        expect (kps[2].Time):toBeCloseTo (1)
        expect (kps[2].Value):toBeCloseTo (1)
    end)
    it ("round-trips multi-keypoint with envelope", function (): ()
        local original = NumberSequence.new ({
            NumberSequenceKeypoint.new (0, 10, 2),
            NumberSequenceKeypoint.new (0.5, 20, 5),
            NumberSequenceKeypoint.new (1, 30, 0),
        })
        local r = roundTrip (Lync.numberSequence, original)
        local kps = r.Keypoints
        expect (#kps):toBe (3)
        expect (kps[1].Value):toBeCloseTo (10)
        expect (kps[1].Envelope):toBeCloseTo (2)
        expect (kps[2].Time):toBeCloseTo (0.5)
        expect (kps[2].Value):toBeCloseTo (20)
        expect (kps[2].Envelope):toBeCloseTo (5)
        expect (kps[3].Value):toBeCloseTo (30)
        expect (kps[3].Envelope):toBeCloseTo (0)
    end)
    it ("round-trips constant value", function (): ()
        local original = NumberSequence.new (42)
        local r = roundTrip (Lync.numberSequence, original)
        local kps = r.Keypoints
        expect (#kps):toBe (2)
        expect (kps[1].Value):toBeCloseTo (42)
        expect (kps[2].Value):toBeCloseTo (42)
    end)
    it ("no _size (variable length)", function (): ()
        expect ((Lync.numberSequence :: any)._size):toBe (nil)
    end)
    it ("uses varint + N*12 bytes", function (): ()
        local _, w = roundTrip (Lync.numberSequence, NumberSequence.new (0, 1))
        expect (w):toBe (25) -- varint(2) = 1 byte + 2 * 12 = 25
    end)
    it ("uses correct size for 3 keypoints", function (): ()
        local _, w = roundTrip (
            Lync.numberSequence,
            NumberSequence.new ({
                NumberSequenceKeypoint.new (0, 0, 0),
                NumberSequenceKeypoint.new (0.5, 1, 0),
                NumberSequenceKeypoint.new (1, 0, 0),
            })
        )
        expect (w):toBe (37) -- varint(3) = 1 byte + 3 * 12 = 37
    end)
end)

describe ("Sequence.colorSequence", function (): ()
    it ("round-trips two keypoints", function (): ()
        local original = ColorSequence.new (Color3.new (0, 0, 0), Color3.new (1, 1, 1))
        local r = roundTrip (Lync.colorSequence, original)
        local kps = r.Keypoints
        expect (#kps):toBe (2)
        expect (kps[1].Time):toBeCloseTo (0)
        expect (kps[2].Time):toBeCloseTo (1)
    end)
    it ("round-trips multi-keypoint", function (): ()
        local original = ColorSequence.new ({
            ColorSequenceKeypoint.new (0, Color3.fromRGB (255, 0, 0)),
            ColorSequenceKeypoint.new (0.5, Color3.fromRGB (0, 255, 0)),
            ColorSequenceKeypoint.new (1, Color3.fromRGB (0, 0, 255)),
        })
        local r = roundTrip (Lync.colorSequence, original)
        local kps = r.Keypoints
        expect (#kps):toBe (3)
        expect (kps[1].Time):toBeCloseTo (0)
        expect (kps[2].Time):toBeCloseTo (0.5)
        expect (kps[3].Time):toBeCloseTo (1)
    end)
    it ("preserves color channels via u8 round-trip", function (): ()
        local original = ColorSequence.new ({
            ColorSequenceKeypoint.new (0, Color3.fromRGB (128, 64, 32)),
            ColorSequenceKeypoint.new (1, Color3.fromRGB (0, 255, 127)),
        })
        local r = roundTrip (Lync.colorSequence, original)
        local kps = r.Keypoints
        local c1 = kps[1].Value
        local c2 = kps[2].Value
        expect (math.round (c1.R * 255)):toBe (128)
        expect (math.round (c1.G * 255)):toBe (64)
        expect (math.round (c1.B * 255)):toBe (32)
        expect (math.round (c2.R * 255)):toBe (0)
        expect (math.round (c2.G * 255)):toBe (255)
        expect (math.round (c2.B * 255)):toBe (127)
    end)
    it ("no _size (variable length)", function (): ()
        expect ((Lync.colorSequence :: any)._size):toBe (nil)
    end)
    it ("uses varint + N*7 bytes", function (): ()
        local _, w =
            roundTrip (Lync.colorSequence, ColorSequence.new (Color3.new (), Color3.new (1, 1, 1)))
        expect (w):toBe (15) -- varint(2) = 1 byte + 2 * 7 = 15
    end)
    it ("uses correct size for 3 keypoints", function (): ()
        local _, w = roundTrip (
            Lync.colorSequence,
            ColorSequence.new ({
                ColorSequenceKeypoint.new (0, Color3.new ()),
                ColorSequenceKeypoint.new (0.5, Color3.new (1, 0, 0)),
                ColorSequenceKeypoint.new (1, Color3.new (1, 1, 1)),
            })
        )
        expect (w):toBe (22) -- varint(3) = 1 byte + 3 * 7 = 22
    end)
end)

return nil
