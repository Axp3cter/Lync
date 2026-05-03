--!strict
--!optimize 2
-- Lync.numberRange: 8 bytes, two f32 components, throws on min > max.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.NumberRange", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("_size = 8", function(): ()
            expect((Lync.numberRange :: any)._size):toBe(8)
        end)
        it("_typeCheck = NumberRange", function(): ()
            expect((Lync.numberRange :: any)._typeCheck):toBe("NumberRange")
        end)
        it("exposes _directWrite", function(): ()
            expect((Lync.numberRange :: any)._directWrite):toBeType("function")
        end)
        it("codec is frozen", function(): ()
            expect(Lync.numberRange):toBeFrozen()
        end)
    end)

    describe("round-trip: typical", function(): ()
        it("(0, 100)", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(0, 100))
            expect(r.Min):toBeCloseTo(0)
            expect(r.Max):toBeCloseTo(100)
        end)
        it("(-50, 50)", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(-50, 50))
            expect(r.Min):toBeCloseTo(-50)
            expect(r.Max):toBeCloseTo(50)
        end)
        it("equal min and max (single-value range)", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(42, 42))
            expect(r.Min):toBeCloseTo(42)
            expect(r.Max):toBeCloseTo(42)
        end)
    end)

    describe("round-trip: extreme values", function(): ()
        it("very large range (1e6 spans)", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(-1e6, 1e6))
            expect(r.Min):toBeCloseTo(-1e6, 1)
            expect(r.Max):toBeCloseTo(1e6, 1)
        end)
        it("subpixel range", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(0.001, 0.002))
            expect(r.Min):toBeCloseTo(0.001, 1e-6)
            expect(r.Max):toBeCloseTo(0.002, 1e-6)
        end)
        it("zero-width at high value", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(100, 100))
            expect(r.Min):toBe(r.Max)
        end)
        it("zero-width at zero", function(): ()
            local r = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(0, 0))
            expect(r.Min):toBe(0)
            expect(r.Max):toBe(0)
        end)
    end)

    describe("wire shape", function(): ()
        it("wire = 8 bytes", function(): ()
            local _, w = Channel.roundTripStrict(Lync.numberRange, NumberRange.new(0, 1))
            expect(w):toBe(8)
        end)
        it("Min as first f32, Max as second", function(): ()
            local r = Channel.encode(Lync.numberRange, NumberRange.new(3, 7))
            expect(buffer.readf32(r.buffer, 0)):toBeCloseTo(3)
            expect(buffer.readf32(r.buffer, 4)):toBeCloseTo(7)
        end)
    end)

    describe("read rejects min > max corruption", function(): ()
        --[[
            min > max would let a crafted wire silently survive; rejecting
            forces the transport to abort and reset its baseline rather than
            decoding into a NumberRange that masks a desync.
        ]]
        it("buffer with min=10, max=5 throws", function(): ()
            local b = buffer.create(8)
            buffer.writef32(b, 0, 10)
            buffer.writef32(b, 4, 5)
            expect(function(): ()
                Lync.numberRange.read(b, 0, nil)
            end):toThrow("min")
        end)
        it("buffer with min=1, max=0 throws", function(): ()
            local b = buffer.create(8)
            buffer.writef32(b, 0, 1)
            buffer.writef32(b, 4, 0)
            expect(function(): ()
                Lync.numberRange.read(b, 0, nil)
            end):toThrow()
        end)
        it("min=max passes (boundary case)", function(): ()
            local b = buffer.create(8)
            buffer.writef32(b, 0, 5)
            buffer.writef32(b, 4, 5)
            expect(function(): ()
                Lync.numberRange.read(b, 0, nil)
            end).never:toThrow()
        end)
        it("rejection message names both bounds", function(): ()
            local b = buffer.create(8)
            buffer.writef32(b, 0, 99)
            buffer.writef32(b, 4, 1)
            local ok, err = pcall(function(): ()
                Lync.numberRange.read(b, 0, nil)
            end)
            expect(ok):toBe(false)
            expect((tostring(err)):find("99", 1, true) ~= nil):toBe(true)
        end)
    end)
end)

return nil
