--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("numberSequence", function(): ()
    it("two keypoints", function(): ()
        local seq = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        local r = roundTrip(Lync.numberSequence, seq)
        expect(#r.Keypoints):toBe(2)
        expect(r.Keypoints[1].Time):toBeCloseTo(0)
        expect(r.Keypoints[1].Value):toBeCloseTo(0)
        expect(r.Keypoints[2].Time):toBeCloseTo(1)
        expect(r.Keypoints[2].Value):toBeCloseTo(1)
    end)
    it("three keypoints with envelope", function(): ()
        local seq = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 5, 1),
            NumberSequenceKeypoint.new(0.5, 10, 2),
            NumberSequenceKeypoint.new(1, 0, 0),
        })
        local r = roundTrip(Lync.numberSequence, seq)
        expect(#r.Keypoints):toBe(3)
        expect(r.Keypoints[2].Envelope):toBeCloseTo(2)
    end)
end)

describe("colorSequence", function(): ()
    it("two keypoints", function(): ()
        local seq = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.new(1, 0, 0)),
            ColorSequenceKeypoint.new(1, Color3.new(0, 0, 1)),
        })
        local r = roundTrip(Lync.colorSequence, seq)
        expect(#r.Keypoints):toBe(2)
        expect(r.Keypoints[1].Value.R):toBeCloseTo(1, 0.01)
        expect(r.Keypoints[2].Value.B):toBeCloseTo(1, 0.01)
    end)
end)

return nil
