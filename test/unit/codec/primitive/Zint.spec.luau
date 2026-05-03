--!strict
--!optimize 2
-- Lync.zint: zigzag varint signed integer codec.

local Env = require(script:FindFirstAncestor("test").Env)

local Channel = Env.Channel
local Lync = Env.Lync
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Zint", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("flags _isInteger", function(): ()
            expect((Lync.zint() :: any)._isInteger):toBe(true)
        end)
        it("_typeCheck = number", function(): ()
            expect((Lync.zint() :: any)._typeCheck):toBe("number")
        end)
        it("records explicit min/max", function(): ()
            local c = Lync.zint(-100, 100) :: any
            expect(c._min):toBe(-100)
            expect(c._max):toBe(100)
        end)
        it("defaults to full i32 range", function(): ()
            local c = Lync.zint() :: any
            expect(c._min):toBe(-0x80000000)
            expect(c._max):toBe(0x7FFFFFFF)
        end)
    end)

    describe("tier 1 (1 byte): [-96, 95]", function(): ()
        local values = { 0, 1, -1, 50, -50, 95, -96 }
        for _, v in values do
            it(`{v} round-trips in 1 byte`, function(): ()
                local r, w = Channel.roundTripStrict(Lync.zint(), v)
                expect(r):toBe(v)
                expect(w):toBe(1)
            end)
        end
    end)

    describe("tier 2 (2 bytes): just past inline", function(): ()
        local values = { 96, -97, 1000, -1000, 4191, -4192 }
        for _, v in values do
            it(`{v} round-trips in 2 bytes`, function(): ()
                local r, w = Channel.roundTripStrict(Lync.zint(), v)
                expect(r):toBe(v)
                expect(w):toBe(2)
            end)
        end
    end)

    describe("tier 3 (3 bytes)", function(): ()
        local values = { 4192, -4193, 100000, -100000, 528479, -528480 }
        for _, v in values do
            it(`{v} round-trips in 3 bytes`, function(): ()
                local r, w = Channel.roundTripStrict(Lync.zint(), v)
                expect(r):toBe(v)
                expect(w):toBe(3)
            end)
        end
    end)

    describe("tier 4 (5 bytes): full i32 limits", function(): ()
        local values = { 0x7FFFFFFF, -0x80000000, 1056960, -1056961 }
        for _, v in values do
            it(`{v} round-trips in 5 bytes`, function(): ()
                local r, w = Channel.roundTripStrict(Lync.zint(), v)
                expect(r):toBe(v)
                expect(w):toBe(5)
            end)
        end
    end)

    describe("zigzag mapping (small magnitudes pack tight regardless of sign)", function(): ()
        it("+1 and -1 both fit in 1 byte", function(): ()
            local _, wp = Channel.roundTripStrict(Lync.zint(), 1)
            local _, wn = Channel.roundTripStrict(Lync.zint(), -1)
            expect(wp):toBe(1)
            expect(wn):toBe(1)
        end)
        it("+95 / -96 are tier-1 boundaries", function(): ()
            local _, wp = Channel.roundTripStrict(Lync.zint(), 95)
            local _, wn = Channel.roundTripStrict(Lync.zint(), -96)
            expect(wp):toBe(1)
            expect(wn):toBe(1)
        end)
        it("+96 crosses into tier 2", function(): ()
            local _, w = Channel.roundTripStrict(Lync.zint(), 96)
            expect(w):toBe(2)
        end)
    end)

    describe("bounded variant", function(): ()
        it("rejects values below min", function(): ()
            local c = Lync.zint(0, 100)
            expect(function(): ()
                Channel.encode(c, -1)
            end):toThrow("out of range")
        end)
        it("rejects values above max", function(): ()
            local c = Lync.zint(0, 100)
            expect(function(): ()
                Channel.encode(c, 101)
            end):toThrow("out of range")
        end)
        it("accepts values inside range", function(): ()
            local c = Lync.zint(0, 100)
            local r = Channel.roundTripStrict(c, 50)
            expect(r):toBe(50)
        end)
    end)

    describe("define-time errors", function(): ()
        it("min > max throws", function(): ()
            expect(function(): ()
                Lync.zint(10, 5)
            end):toThrow("must be <=")
        end)
        it("non-integer bounds throw", function(): ()
            expect(function(): ()
                Lync.zint(0.5, 10)
            end):toThrow("integers")
        end)
        it("range below i32 min throws", function(): ()
            expect(function(): ()
                Lync.zint(-0x80000001, 0)
            end):toThrow("exceeds i32")
        end)
        it("range above i32 max throws", function(): ()
            expect(function(): ()
                Lync.zint(0, 0x80000000)
            end):toThrow("exceeds i32")
        end)
    end)

    describe("write-side validation", function(): ()
        it("non-integer values throw", function(): ()
            expect(function(): ()
                Channel.encode(Lync.zint(), 3.5)
            end):toThrow("integer")
        end)
    end)

    describe("read truncation", function(): ()
        it("zero-length buffer throws", function(): ()
            local empty = buffer.create(0)
            expect(function(): ()
                Lync.zint().read(empty, 0, nil)
            end):toThrow("truncated")
        end)
    end)
end)

return nil
