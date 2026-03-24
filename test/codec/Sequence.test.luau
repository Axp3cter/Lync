--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("numberSequence", function(): ()
    it("single keypoint", function(): ()
        local ns = NumberSequence.new(0.5)
        local r = roundTrip(Lync.numberSequence, ns)
        expect(r.Keypoints[1].Value):toBeCloseTo(0.5)
    end)
    it("two keypoints", function(): ()
        local ns = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(1, 1),
        })
        local r = roundTrip(Lync.numberSequence, ns)
        expect(r.Keypoints[1].Time):toBeCloseTo(0)
        expect(r.Keypoints[1].Value):toBeCloseTo(0)
        expect(r.Keypoints[2].Time):toBeCloseTo(1)
        expect(r.Keypoints[2].Value):toBeCloseTo(1)
    end)
    it("preserves envelope", function(): ()
        local ns = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 5, 2),
            NumberSequenceKeypoint.new(1, 10, 3),
        })
        local r = roundTrip(Lync.numberSequence, ns)
        expect(r.Keypoints[1].Envelope):toBeCloseTo(2)
        expect(r.Keypoints[2].Envelope):toBeCloseTo(3)
    end)
    it("_typeCheck = NumberSequence", function(): ()
        expect((Lync.numberSequence :: any)._typeCheck):toBe("NumberSequence")
    end)
end)

describe("colorSequence", function(): ()
    it("single color", function(): ()
        local cs = ColorSequence.new(Color3.fromRGB(255, 0, 0))
        local r = roundTrip(Lync.colorSequence, cs)
        expect(r.Keypoints[1].Value.R):toBeCloseTo(1, 0.01)
    end)
    it("two keypoints", function(): ()
        local cs = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
        })
        local r = roundTrip(Lync.colorSequence, cs)
        expect(r.Keypoints[1].Value.R):toBeCloseTo(1, 0.01)
        expect(r.Keypoints[2].Value.B):toBeCloseTo(1, 0.01)
    end)
    it("preserves time", function(): ()
        local cs = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.new()),
            ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
            ColorSequenceKeypoint.new(1, Color3.new()),
        })
        local r = roundTrip(Lync.colorSequence, cs)
        expect(r.Keypoints[2].Time):toBeCloseTo(0.5)
    end)
    it("_typeCheck = ColorSequence", function(): ()
        expect((Lync.colorSequence :: any)._typeCheck):toBe("ColorSequence")
    end)
end)

return nil
