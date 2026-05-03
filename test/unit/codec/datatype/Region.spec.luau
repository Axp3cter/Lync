--!strict
--!optimize 2
-- Lync.region3 (24B f32) and Lync.region3int16 (12B i16).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Region", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("region3 metadata", function(): ()
        it("_size = 24", function(): ()
            expect((Lync.region3 :: any)._size):toBe(24)
        end)
        it("_typeCheck = Region3", function(): ()
            expect((Lync.region3 :: any)._typeCheck):toBe("Region3")
        end)
        it("codec is frozen", function(): ()
            expect(Lync.region3):toBeFrozen()
        end)
    end)

    describe("region3 round-trip", function(): ()
        it("symmetric region preserves bounds", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.new(-10, -10, -10), Vector3.new(10, 10, 10))
            )
            expect(r.Size.X):toBeCloseTo(20, 1e-2)
            expect(r.Size.Y):toBeCloseTo(20, 1e-2)
            expect(r.Size.Z):toBeCloseTo(20, 1e-2)
        end)
        it("preserves CFrame center for offset region", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.new(0, 0, 0), Vector3.new(50, 50, 50))
            )
            expect(r.CFrame.Position.X):toBeCloseTo(25, 1e-2)
            expect(r.CFrame.Position.Y):toBeCloseTo(25, 1e-2)
        end)
        it("non-cubic region (different X/Y/Z extents)", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.new(0, 0, 0), Vector3.new(10, 20, 30))
            )
            expect(r.Size.X):toBeCloseTo(10, 1e-2)
            expect(r.Size.Y):toBeCloseTo(20, 1e-2)
            expect(r.Size.Z):toBeCloseTo(30, 1e-2)
        end)
        it("zero-volume region (Min == Max)", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.new(5, 5, 5), Vector3.new(5, 5, 5))
            )
            expect(r.Size.X):toBe(0)
        end)
        it("very large region (1e6 extent)", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.new(-1e6, 0, 0), Vector3.new(1e6, 0, 0))
            )
            expect(r.Size.X):toBeCloseTo(2e6, 1)
        end)
        it("wire = 24 bytes", function(): ()
            local _, w = Channel.roundTripStrict(
                Lync.region3,
                Region3.new(Vector3.zero, Vector3.new(1, 1, 1))
            )
            expect(w):toBe(24)
        end)
    end)

    describe("region3int16 metadata", function(): ()
        it("_size = 12", function(): ()
            expect((Lync.region3int16 :: any)._size):toBe(12)
        end)
        it("_typeCheck = Region3int16", function(): ()
            expect((Lync.region3int16 :: any)._typeCheck):toBe("Region3int16")
        end)
        it("codec is frozen", function(): ()
            expect(Lync.region3int16):toBeFrozen()
        end)
    end)

    describe("region3int16 round-trip", function(): ()
        it("typical positive bounds", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3int16,
                Region3int16.new(Vector3int16.new(-10, -20, -30), Vector3int16.new(10, 20, 30))
            )
            expect(r.Min.X):toBe(-10)
            expect(r.Max.Z):toBe(30)
        end)
        it("i16 boundary saturation", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3int16,
                Region3int16.new(Vector3int16.new(-32768, 0, 0), Vector3int16.new(32767, 0, 0))
            )
            expect(r.Min.X):toBe(-32768)
            expect(r.Max.X):toBe(32767)
        end)
        it("zero region", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3int16,
                Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(0, 0, 0))
            )
            expect(r.Min.X):toBe(0)
            expect(r.Max.Z):toBe(0)
        end)
        it("negative-only region", function(): ()
            local r = Channel.roundTripStrict(
                Lync.region3int16,
                Region3int16.new(
                    Vector3int16.new(-100, -100, -100),
                    Vector3int16.new(-50, -50, -50)
                )
            )
            expect(r.Min.X):toBe(-100)
            expect(r.Max.X):toBe(-50)
        end)
        it("wire = 12 bytes", function(): ()
            local _, w = Channel.roundTripStrict(
                Lync.region3int16,
                Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(1, 1, 1))
            )
            expect(w):toBe(12)
        end)
        it("each i16 component is exactly 2 bytes", function(): ()
            local r = Channel.encode(
                Lync.region3int16,
                Region3int16.new(Vector3int16.new(0, 0, 0), Vector3int16.new(1, 0, 0))
            )
            -- Min.X at offset 0 = 0; Max.X at offset 6 = 1.
            expect(buffer.readi16(r.buffer, 0)):toBe(0)
            expect(buffer.readi16(r.buffer, 6)):toBe(1)
        end)
    end)
end)

return nil
