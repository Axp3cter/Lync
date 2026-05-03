--!strict
--!optimize 2
-- Lync.numberSequence and Lync.colorSequence: keypoint arrays with varint count.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Sequence", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("numberSequence", function(): ()
        it("_typeCheck = NumberSequence", function(): ()
            expect((Lync.numberSequence :: any)._typeCheck):toBe("NumberSequence")
        end)
        it("single keypoint round-trips", function(): ()
            local ns = NumberSequence.new(0.5)
            local r = Channel.roundTripStrict(Lync.numberSequence, ns)
            expect(r.Keypoints[1].Value):toBeCloseTo(0.5)
        end)
        it("two keypoints preserve time and value", function(): ()
            local ns = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(1, 1),
            })
            local r = Channel.roundTripStrict(Lync.numberSequence, ns)
            expect(r.Keypoints[1].Time):toBeCloseTo(0)
            expect(r.Keypoints[2].Time):toBeCloseTo(1)
            expect(r.Keypoints[2].Value):toBeCloseTo(1)
        end)
        it("preserves envelope", function(): ()
            local ns = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 5, 2),
                NumberSequenceKeypoint.new(1, 10, 3),
            })
            local r = Channel.roundTripStrict(Lync.numberSequence, ns)
            expect(r.Keypoints[1].Envelope):toBeCloseTo(2)
            expect(r.Keypoints[2].Envelope):toBeCloseTo(3)
        end)
        it("rejects buffer claiming >20 keypoints (Roblox limit)", function(): ()
            -- Manually craft a buffer with varint(21) followed by enough bytes.
            local b = buffer.create(2 + 21 * 12)
            buffer.writeu8(b, 0, 21)
            expect(function(): ()
                Lync.numberSequence.read(b, 0, nil)
            end):toThrow("Roblox limit")
        end)
    end)

    describe("colorSequence", function(): ()
        it("_typeCheck = ColorSequence", function(): ()
            expect((Lync.colorSequence :: any)._typeCheck):toBe("ColorSequence")
        end)
        it("single color round-trips", function(): ()
            local cs = ColorSequence.new(Color3.fromRGB(255, 0, 0))
            local r = Channel.roundTripStrict(Lync.colorSequence, cs)
            expect(r.Keypoints[1].Value.R):toBeCloseTo(1, 0.01)
        end)
        it("two keypoints", function(): ()
            local cs = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
            })
            local r = Channel.roundTripStrict(Lync.colorSequence, cs)
            expect(r.Keypoints[1].Value.R):toBeCloseTo(1, 0.01)
            expect(r.Keypoints[2].Value.B):toBeCloseTo(1, 0.01)
        end)
        it("middle keypoint preserves time", function(): ()
            local cs = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.new()),
                ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
                ColorSequenceKeypoint.new(1, Color3.new()),
            })
            local r = Channel.roundTripStrict(Lync.colorSequence, cs)
            expect(r.Keypoints[2].Time):toBeCloseTo(0.5)
        end)
        it("rejects buffer claiming >20 keypoints", function(): ()
            local b = buffer.create(2 + 21 * 7)
            buffer.writeu8(b, 0, 21)
            expect(function(): ()
                Lync.colorSequence.read(b, 0, nil)
            end):toThrow("Roblox limit")
        end)
    end)

    describe("numberSequence edges", function(): ()
        it("max keypoints (20) round-trips", function(): ()
            local kp = table.create(20)
            for i = 1, 20 do
                kp[i] = NumberSequenceKeypoint.new((i - 1) / 19, i / 20)
            end
            local r = Channel.roundTripStrict(Lync.numberSequence, NumberSequence.new(kp))
            expect(#r.Keypoints):toBe(20)
        end)
        it("write of >20 keypoints throws", function(): ()
            -- Roblox itself caps NumberSequence.new at 20; we can't construct
            -- one with more in user code. Pin the read-side limit instead.
            local b = buffer.create(1 + 25 * 12)
            buffer.writeu8(b, 0, 25)
            expect(function(): ()
                Lync.numberSequence.read(b, 0, nil)
            end):toThrow()
        end)
        it("zero-keypoint encoding has only the count byte", function(): ()
            -- NumberSequence.new() requires at least one keypoint, so we test
            -- only the read-side: count=0 yields a degenerate sequence.
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 0)
            local v, c = Lync.numberSequence.read(b, 0, nil)
            expect(c):toBe(1)
            expect(v).never:toBe(nil)
        end)
        it("preserves Time precision (f32)", function(): ()
            local ns = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(0.123456, 0.5),
                NumberSequenceKeypoint.new(1, 1),
            })
            local r = Channel.roundTripStrict(Lync.numberSequence, ns)
            expect(r.Keypoints[2].Time):toBeCloseTo(0.123456, 1e-5)
        end)
    end)

    describe("colorSequence edges", function(): ()
        --[[
            Roblox's Color3 constructor rejects out-of-range components, so
            we can't even build a ColorSequence with HDR or negative values.
            The wire-side clamp is exercised at decode time when a crafted
            buffer carries a u8 byte (already in [0, 255]) — there's no way
            to encode out-of-range values from valid Roblox inputs.
        ]]
        it("encoded R component is a u8 (0-255 range)", function(): ()
            local cs = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 255, 0)),
            })
            local r = Channel.encode(Lync.colorSequence, cs)
            -- count(1) + kp[0].Time(4) + R(1) at offset 5
            expect(buffer.readu8(r.buffer, 5)):toBe(255)
        end)
        it("each ColorSequence keypoint is 7 bytes (4 + 3*1)", function(): ()
            -- 1 byte count + 2 keypoints * 7 = 15.
            local cs = ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 255)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 0)),
            })
            local r = Channel.encode(Lync.colorSequence, cs)
            expect(r.length):toBe(1 + 2 * 7)
        end)
        it("max keypoints (20) round-trips for colorSequence", function(): ()
            local kp = table.create(20)
            for i = 1, 20 do
                kp[i] = ColorSequenceKeypoint.new((i - 1) / 19, Color3.new(i / 20, 0, 0))
            end
            local r = Channel.roundTripStrict(Lync.colorSequence, ColorSequence.new(kp))
            expect(#r.Keypoints):toBe(20)
        end)
    end)

    describe("wire byte budget", function(): ()
        it("numberSequence: 12 bytes per keypoint + 1 count byte", function(): ()
            local ns = NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(0.5, 0.5),
                NumberSequenceKeypoint.new(1, 1),
            })
            local r = Channel.encode(Lync.numberSequence, ns)
            expect(r.length):toBe(1 + 3 * 12)
        end)
    end)
end)

return nil
