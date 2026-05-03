--!strict
--!optimize 2
-- f32 / f64 explicit-precision floats.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Number", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("f32 metadata", function(): ()
        it("_size = 4", function(): ()
            expect((Lync.f32 :: any)._size):toBe(4)
        end)
        it("_typeCheck = number", function(): ()
            expect((Lync.f32 :: any)._typeCheck):toBe("number")
        end)
        it("has direct write and read", function(): ()
            expect((Lync.f32 :: any)._directWrite):toBeType("function")
            expect((Lync.f32 :: any)._directRead):toBeType("function")
        end)
    end)

    describe("f32 round-trip", function(): ()
        it("0 exact", function(): ()
            expect(Channel.roundTripStrict(Lync.f32, 0)):toBe(0)
        end)
        it("1 exact", function(): ()
            expect(Channel.roundTripStrict(Lync.f32, 1)):toBe(1)
        end)
        it("-1 exact", function(): ()
            expect(Channel.roundTripStrict(Lync.f32, -1)):toBe(-1)
        end)
        it("1.5 exact", function(): ()
            expect(Channel.roundTripStrict(Lync.f32, 1.5)):toBe(1.5)
        end)
        it("loses precision on f64-only values", function(): ()
            local v = math.pi
            local r = Channel.roundTripStrict(Lync.f32, v)
            expect(r).never:toBe(v)
            expect(r):toBeCloseTo(v, 1e-6)
        end)
        it("clamps to inf on overflow", function(): ()
            local r = Channel.roundTripStrict(Lync.f32, 1e300)
            expect(r):toBe(math.huge)
        end)
        it("preserves NaN", function(): ()
            local r = Channel.roundTripStrict(Lync.f32, 0 / 0)
            expect(r):toBeNaN()
        end)
        it("wire = 4 bytes", function(): ()
            local _, written = Channel.roundTripStrict(Lync.f32, 0)
            expect(written):toBe(4)
        end)
    end)

    describe("f64 metadata", function(): ()
        it("_size = 8", function(): ()
            expect((Lync.f64 :: any)._size):toBe(8)
        end)
        it("_typeCheck = number", function(): ()
            expect((Lync.f64 :: any)._typeCheck):toBe("number")
        end)
    end)

    describe("f64 round-trip", function(): ()
        it("pi exact (within 1e-15)", function(): ()
            local r = Channel.roundTripStrict(Lync.f64, math.pi)
            expect(r):toBeCloseTo(math.pi, 1e-15)
        end)
        it("1e300 representable", function(): ()
            local r = Channel.roundTripStrict(Lync.f64, 1e300)
            expect(r):toBeCloseTo(1e300, 1e285)
        end)
        it("preserves -0", function(): ()
            local r = Channel.roundTripStrict(Lync.f64, -0)
            expect(r):toBe(0)
        end)
        it("wire = 8 bytes", function(): ()
            local _, written = Channel.roundTripStrict(Lync.f64, 0)
            expect(written):toBe(8)
        end)
    end)
end)

return nil
