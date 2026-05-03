--!strict
--!optimize 2
-- Lync.rect: 16 bytes (Min.X, Min.Y, Max.X, Max.Y as f32).

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Rect", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 16", function(): ()
            expect((Lync.rect :: any)._size):toBe(16)
        end)
        it("_typeCheck = Rect", function(): ()
            expect((Lync.rect :: any)._typeCheck):toBe("Rect")
        end)
        it("_directWrite is a function", function(): ()
            expect((Lync.rect :: any)._directWrite):toBeType("function")
        end)
        it("codec is frozen", function(): ()
            expect(Lync.rect):toBeFrozen()
        end)
    end)

    describe("round-trip: typical rects", function(): ()
        it("zero rect", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(0, 0, 0, 0))
            expect(r.Min.X):toBe(0)
            expect(r.Max.Y):toBe(0)
        end)
        it("positive corners", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(10, 20, 100, 200))
            expect(r.Min.X):toBeCloseTo(10)
            expect(r.Min.Y):toBeCloseTo(20)
            expect(r.Max.X):toBeCloseTo(100)
            expect(r.Max.Y):toBeCloseTo(200)
        end)
        it("negative corners", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(-50, -50, 50, 50))
            expect(r.Min.X):toBeCloseTo(-50)
            expect(r.Max.X):toBeCloseTo(50)
        end)
    end)

    describe("round-trip: degenerate / extreme", function(): ()
        it("degenerate rect (Min == Max) preserves both points", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(5, 5, 5, 5))
            expect(r.Min.X):toBeCloseTo(5)
            expect(r.Max.X):toBeCloseTo(5)
        end)
        it("zero area rect (line segment)", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(0, 10, 0, 20))
            expect(r.Min.X):toBeCloseTo(0)
            expect(r.Max.X):toBeCloseTo(0)
            expect(r.Min.Y):toBeCloseTo(10)
            expect(r.Max.Y):toBeCloseTo(20)
        end)
        it("very large rect (near f32 max)", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(-1e6, -1e6, 1e6, 1e6))
            expect(r.Min.X):toBeCloseTo(-1e6, 1)
            expect(r.Max.X):toBeCloseTo(1e6, 1)
        end)
        it("subpixel rect (sub-1 dimensions)", function(): ()
            local r = Channel.roundTripStrict(Lync.rect, Rect.new(0.1, 0.2, 0.3, 0.4))
            expect(r.Min.X):toBeCloseTo(0.1, 1e-6)
            expect(r.Max.Y):toBeCloseTo(0.4, 1e-6)
        end)
    end)

    describe("wire shape", function(): ()
        it("wire = 16 bytes", function(): ()
            local _, w = Channel.roundTripStrict(Lync.rect, Rect.new(0, 0, 1, 1))
            expect(w):toBe(16)
        end)
        --[[
            Roblox Rect.new(minX, minY, maxX, maxY) normalizes so Min uses
            componentwise min and Max uses componentwise max. Use values that
            are already correctly ordered so the wire reflects the inputs.
        ]]
        it("Min.X is the first f32", function(): ()
            local r = Channel.encode(Lync.rect, Rect.new(7, 0, 100, 0))
            expect(buffer.readf32(r.buffer, 0)):toBeCloseTo(7)
        end)
        it("Max.Y is the last f32 (offset 12)", function(): ()
            local r = Channel.encode(Lync.rect, Rect.new(0, 0, 0, 9))
            expect(buffer.readf32(r.buffer, 12)):toBeCloseTo(9)
        end)
        it("field order: Min.X, Min.Y, Max.X, Max.Y", function(): ()
            local r = Channel.encode(Lync.rect, Rect.new(1, 2, 3, 4))
            expect(buffer.readf32(r.buffer, 0)):toBeCloseTo(1)
            expect(buffer.readf32(r.buffer, 4)):toBeCloseTo(2)
            expect(buffer.readf32(r.buffer, 8)):toBeCloseTo(3)
            expect(buffer.readf32(r.buffer, 12)):toBeCloseTo(4)
        end)
    end)
end)

return nil
