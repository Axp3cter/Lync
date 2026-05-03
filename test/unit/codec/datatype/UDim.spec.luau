--!strict
--!optimize 2
-- Lync.udim (8B: Scale f32 + Offset i32) and Lync.udim2 (16B: two UDim).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.UDim", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("udim", function(): ()
        it("_size = 8", function(): ()
            expect((Lync.udim :: any)._size):toBe(8)
        end)
        it("_typeCheck = UDim", function(): ()
            expect((Lync.udim :: any)._typeCheck):toBe("UDim")
        end)
        it("zero", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0, 0))
            expect(r.Scale):toBe(0)
            expect(r.Offset):toBe(0)
        end)
        it("positive scale + offset", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0.5, 100))
            expect(r.Scale):toBeCloseTo(0.5)
            expect(r.Offset):toBe(100)
        end)
        it("negative offset", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(1, -50))
            expect(r.Offset):toBe(-50)
        end)
        it("large offset", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0, 100000))
            expect(r.Offset):toBe(100000)
        end)
    end)

    describe("udim2", function(): ()
        it("_size = 16", function(): ()
            expect((Lync.udim2 :: any)._size):toBe(16)
        end)
        it("_typeCheck = UDim2", function(): ()
            expect((Lync.udim2 :: any)._typeCheck):toBe("UDim2")
        end)
        it("zero", function(): ()
            local r = Channel.roundTripStrict(Lync.udim2, UDim2.new())
            expect(r.X.Scale):toBe(0)
            expect(r.Y.Scale):toBe(0)
        end)
        it("positive components", function(): ()
            local r =
                Channel.roundTripStrict(Lync.udim2, UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)))
            expect(r.X.Scale):toBeCloseTo(0.5)
            expect(r.X.Offset):toBe(10)
            expect(r.Y.Offset):toBe(20)
        end)
        it("negative offsets", function(): ()
            local r =
                Channel.roundTripStrict(Lync.udim2, UDim2.new(UDim.new(0, -100), UDim.new(0, -200)))
            expect(r.X.Offset):toBe(-100)
            expect(r.Y.Offset):toBe(-200)
        end)
    end)

    describe("udim edge values", function(): ()
        it("scale = 1.0 (full)", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(1, 0))
            expect(r.Scale):toBeCloseTo(1)
        end)
        it("scale = -0.5 (negative)", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(-0.5, 0))
            expect(r.Scale):toBeCloseTo(-0.5)
        end)
        it("scale = 0.0001 (subpixel scale)", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0.0001, 0))
            expect(r.Scale):toBeCloseTo(0.0001, 1e-7)
        end)
        it("offset = i32 max (2^31 - 1)", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0, 0x7FFFFFFF))
            expect(r.Offset):toBe(0x7FFFFFFF)
        end)
        it("offset = i32 min (-2^31)", function(): ()
            local r = Channel.roundTripStrict(Lync.udim, UDim.new(0, -0x80000000))
            expect(r.Offset):toBe(-0x80000000)
        end)
        it("wire = 8 bytes for any UDim", function(): ()
            local _, w = Channel.roundTripStrict(Lync.udim, UDim.new(0, 0))
            expect(w):toBe(8)
        end)
    end)

    describe("udim2 edge values", function(): ()
        it("mixed sign offsets", function(): ()
            local r = Channel.roundTripStrict(
                Lync.udim2,
                UDim2.new(UDim.new(0.5, 100), UDim.new(-0.5, -100))
            )
            expect(r.X.Offset):toBe(100)
            expect(r.Y.Offset):toBe(-100)
        end)
        it("max offsets in both axes", function(): ()
            local r = Channel.roundTripStrict(
                Lync.udim2,
                UDim2.new(UDim.new(0, 0x7FFFFFFF), UDim.new(0, 0x7FFFFFFF))
            )
            expect(r.X.Offset):toBe(0x7FFFFFFF)
            expect(r.Y.Offset):toBe(0x7FFFFFFF)
        end)
        it("wire = 16 bytes", function(): ()
            local _, w = Channel.roundTripStrict(Lync.udim2, UDim2.new())
            expect(w):toBe(16)
        end)
    end)
end)

return nil
