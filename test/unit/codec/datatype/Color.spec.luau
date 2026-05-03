--!strict
--!optimize 2
-- Lync.color3: 3 bytes (R/G/B u8 each), clamped to [0, 1].

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Color", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 3", function(): ()
            expect((Lync.color3 :: any)._size):toBe(3)
        end)
        it("_typeCheck = Color3", function(): ()
            expect((Lync.color3 :: any)._typeCheck):toBe("Color3")
        end)
    end)

    describe("round-trip", function(): ()
        it("pure red", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.fromRGB(255, 0, 0))
            expect(r.R):toBeCloseTo(1, 0.01)
            expect(r.G):toBeCloseTo(0, 0.01)
            expect(r.B):toBeCloseTo(0, 0.01)
        end)
        it("pure green", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.fromRGB(0, 255, 0))
            expect(r.G):toBeCloseTo(1, 0.01)
        end)
        it("pure blue", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.fromRGB(0, 0, 255))
            expect(r.B):toBeCloseTo(1, 0.01)
        end)
        it("black", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.new(0, 0, 0))
            expect(r.R):toBe(0)
        end)
        it("white", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.new(1, 1, 1))
            expect(r.R):toBeCloseTo(1, 0.01)
        end)
        it("mid gray (128/255)", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.fromRGB(128, 128, 128))
            expect(r.R):toBeCloseTo(128 / 255, 0.01)
        end)
    end)

    describe("HDR clamp", function(): ()
        it("R > 1 clamps to 1", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.new(2.0, 0, 0))
            expect(r.R):toBeCloseTo(1, 0.01)
        end)
        it("negative clamps to 0", function(): ()
            local r = Channel.roundTripStrict(Lync.color3, Color3.new(-1, 0, 0))
            expect(r.R):toBeCloseTo(0, 0.01)
        end)
    end)

    describe("wire", function(): ()
        it("3 bytes", function(): ()
            local _, w = Channel.roundTripStrict(Lync.color3, Color3.new())
            expect(w):toBe(3)
        end)
        it("(255, 128, 64) RGB encodes to 0xFF 0x80 0x40", function(): ()
            local r = Channel.encode(Lync.color3, Color3.fromRGB(255, 128, 64))
            expect(r.buffer):toMatchBuffer({ 0xFF, 0x80, 0x40 })
        end)
    end)
end)

return nil
