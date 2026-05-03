--!strict
--!optimize 2
-- Lync.float: range-quantized fixed-point codec, picks u8 / u16 / u32.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Float", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("wire-type selection", function(): ()
        it("u8 when 200 steps fit in 256", function(): ()
            expect((Lync.float(0, 100, 0.5) :: any)._size):toBe(1)
        end)
        it("u16 when 10000 steps need 16 bits", function(): ()
            expect((Lync.float(0, 100, 0.01) :: any)._size):toBe(2)
        end)
        it("u24 when steps fit in 17-24 bits", function(): ()
            expect((Lync.float(0, 1000, 0.001) :: any)._size):toBe(3)
        end)
        it("u32 when steps exceed 24 bits", function(): ()
            expect((Lync.float(0, 1e9, 0.01) :: any)._size):toBe(4)
        end)
    end)

    describe("metadata", function(): ()
        it("_typeCheck = number", function(): ()
            expect((Lync.float(0, 1, 0.1) :: any)._typeCheck):toBe("number")
        end)
        it("_min and _max set", function(): ()
            local c = Lync.float(-10, 10, 0.1) :: any
            expect(c._min):toBe(-10)
            expect(c._max):toBe(10)
        end)
    end)

    describe("round-trip with quantization", function(): ()
        it("midpoint", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 100, 0.5), 50)):toBeCloseTo(50, 0.5)
        end)
        it("min boundary", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 100, 0.5), 0)):toBeCloseTo(0, 0.5)
        end)
        it("max boundary", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 100, 0.5), 100)):toBeCloseTo(100, 0.5)
        end)
        it("clamps above max", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 100, 0.5), 200)):toBeCloseTo(100, 0.5)
        end)
        it("clamps below min", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 100, 0.5), -50)):toBeCloseTo(0, 0.5)
        end)
        it("negative range", function(): ()
            local c = Lync.float(-50, 50, 1)
            expect(Channel.roundTripStrict(c, -50)):toBeCloseTo(-50, 1)
            expect(Channel.roundTripStrict(c, 0)):toBeCloseTo(0, 1)
            expect(Channel.roundTripStrict(c, 50)):toBeCloseTo(50, 1)
        end)
        it("fine precision", function(): ()
            expect(Channel.roundTripStrict(Lync.float(0, 10, 0.001), 5.555)):toBeCloseTo(
                5.555,
                1e-3
            )
        end)
    end)

    describe("min == max yields a constant codec", function(): ()
        it("zero bytes", function(): ()
            local c = Lync.float(5, 5, 1)
            local _, w = Channel.roundTripStrict(c, 999)
            expect(w):toBe(0)
        end)
        it("read returns the constant", function(): ()
            local c = Lync.float(5, 5, 1)
            local v = Channel.roundTripStrict(c, 999)
            expect(v):toBe(5)
        end)
    end)

    describe("define-time errors", function(): ()
        it("min > max throws", function(): ()
            expect(function(): ()
                Lync.float(10, 5, 1)
            end):toThrow("min")
        end)
        it("zero precision throws", function(): ()
            expect(function(): ()
                Lync.float(0, 100, 0)
            end):toThrow("precision")
        end)
        it("negative precision throws", function(): ()
            expect(function(): ()
                Lync.float(0, 100, -1)
            end):toThrow("precision")
        end)
    end)
end)

return nil
