--!strict
--!optimize 2
-- Lync.ray: 24 bytes (Origin 3xf32 + Direction 3xf32).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Ray", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 24", function(): ()
            expect((Lync.ray :: any)._size):toBe(24)
        end)
        it("_typeCheck = Ray", function(): ()
            expect((Lync.ray :: any)._typeCheck):toBe("Ray")
        end)
        it("exposes _directWrite", function(): ()
            expect((Lync.ray :: any)._directWrite):toBeType("function")
        end)
        it("exposes _directRead", function(): ()
            expect((Lync.ray :: any)._directRead):toBeType("function")
        end)
        it("codec table is frozen", function(): ()
            expect(Lync.ray):toBeFrozen()
        end)
    end)

    describe("round-trip: typical rays", function(): ()
        it("origin + direction (1,2,3 / 0,1,0)", function(): ()
            local r = Channel.roundTripStrict(
                Lync.ray,
                Ray.new(Vector3.new(1, 2, 3), Vector3.new(0, 1, 0))
            )
            expect(r.Origin.X):toBeCloseTo(1)
            expect(r.Origin.Y):toBeCloseTo(2)
            expect(r.Origin.Z):toBeCloseTo(3)
            expect(r.Direction.X):toBeCloseTo(0)
            expect(r.Direction.Y):toBeCloseTo(1)
            expect(r.Direction.Z):toBeCloseTo(0)
        end)
        it("zero origin and yAxis direction", function(): ()
            local r = Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.zero, Vector3.yAxis))
            expect(r.Origin.X):toBe(0)
            expect(r.Direction.Y):toBeCloseTo(1)
        end)
        it("negative direction", function(): ()
            local r =
                Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.zero, Vector3.new(-1, -1, -1)))
            expect(r.Direction.X):toBeCloseTo(-1)
            expect(r.Direction.Z):toBeCloseTo(-1)
        end)
    end)

    describe("round-trip: edge values", function(): ()
        it("axis-aligned x", function(): ()
            local r = Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.zero, Vector3.xAxis))
            expect(r.Direction.X):toBeCloseTo(1)
            expect(r.Direction.Y):toBeCloseTo(0)
            expect(r.Direction.Z):toBeCloseTo(0)
        end)
        it("axis-aligned -y", function(): ()
            local r = Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.zero, -Vector3.yAxis))
            expect(r.Direction.Y):toBeCloseTo(-1)
        end)
        it("zero direction (degenerate but valid f32)", function(): ()
            local r = Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.new(5, 5, 5), Vector3.zero))
            expect(r.Origin.X):toBeCloseTo(5)
            expect(r.Direction.X):toBe(0)
        end)
        it("very large origin (f32 range)", function(): ()
            local r = Channel.roundTripStrict(
                Lync.ray,
                Ray.new(Vector3.new(1e6, 1e6, 1e6), Vector3.zAxis)
            )
            expect(r.Origin.X):toBeCloseTo(1e6, 1)
        end)
        it("very small (subnormal-adjacent) values", function(): ()
            local r =
                Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.new(1e-30, 0, 0), Vector3.zAxis))
            expect(r.Origin.X):toBeCloseTo(1e-30, 1e-30)
        end)
    end)

    describe("wire shape", function(): ()
        it("wire = 24 bytes", function(): ()
            local _, w = Channel.roundTripStrict(Lync.ray, Ray.new(Vector3.zero, Vector3.yAxis))
            expect(w):toBe(24)
        end)
        it("origin written before direction (first 12B = origin)", function(): ()
            local r = Channel.encode(Lync.ray, Ray.new(Vector3.new(1, 0, 0), Vector3.zero))
            -- f32 of 1.0 = 0x3F800000, little-endian: 00 00 80 3F
            expect(buffer.readf32(r.buffer, 0)):toBe(1)
            expect(buffer.readf32(r.buffer, 12)):toBe(0)
        end)
        it("direction comes after origin (bytes 12..23)", function(): ()
            local r = Channel.encode(Lync.ray, Ray.new(Vector3.zero, Vector3.new(7, 0, 0)))
            expect(buffer.readf32(r.buffer, 0)):toBe(0)
            expect(buffer.readf32(r.buffer, 12)):toBeCloseTo(7)
        end)
    end)
end)

return nil
