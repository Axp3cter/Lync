--!strict
--!optimize 2
-- Wire-type selection, boundaries, metadata, and define-time errors for Lync.int.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.primitive.Int", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("wire-type selection by range", function(): ()
        it("[0, 255] is u8 (1 byte)", function(): ()
            expect((Lync.int(0, 255) :: any)._size):toBe(1)
        end)
        it("[0, 100] still u8 (narrowest fit)", function(): ()
            expect((Lync.int(0, 100) :: any)._size):toBe(1)
        end)
        it("[0, 256] promotes to u16 (2 bytes)", function(): ()
            expect((Lync.int(0, 256) :: any)._size):toBe(2)
        end)
        it("[0, 65535] is u16", function(): ()
            expect((Lync.int(0, 65535) :: any)._size):toBe(2)
        end)
        it("[0, 65536] promotes to u32 (4 bytes)", function(): ()
            expect((Lync.int(0, 65536) :: any)._size):toBe(4)
        end)
        it("[0, 0xFFFFFFFF] is u32", function(): ()
            expect((Lync.int(0, 0xFFFFFFFF) :: any)._size):toBe(4)
        end)
        it("[-128, 127] is i8 (1 byte)", function(): ()
            expect((Lync.int(-128, 127) :: any)._size):toBe(1)
        end)
        it("[-10, 10] is i8 (still 1 byte)", function(): ()
            expect((Lync.int(-10, 10) :: any)._size):toBe(1)
        end)
        it("[-129, 127] promotes to i16", function(): ()
            expect((Lync.int(-129, 127) :: any)._size):toBe(2)
        end)
        it("[-32768, 32767] is i16", function(): ()
            expect((Lync.int(-32768, 32767) :: any)._size):toBe(2)
        end)
        it("[-32769, 32767] promotes to i32", function(): ()
            expect((Lync.int(-32769, 32767) :: any)._size):toBe(4)
        end)
        it("[-2147483648, 2147483647] is i32", function(): ()
            expect((Lync.int(-2147483648, 2147483647) :: any)._size):toBe(4)
        end)
    end)

    describe("metadata", function(): ()
        it("flags _isInteger", function(): ()
            expect((Lync.int(0, 100) :: any)._isInteger):toBe(true)
        end)
        it("declares _typeCheck = number", function(): ()
            expect((Lync.int(0, 100) :: any)._typeCheck):toBe("number")
        end)
        it("propagates _min and _max", function(): ()
            local c = Lync.int(-10, 50) :: any
            expect(c._min):toBe(-10)
            expect(c._max):toBe(50)
        end)
        it("has direct write and read", function(): ()
            expect((Lync.int(0, 255) :: any)._directWrite):toBeType("function")
            expect((Lync.int(0, 255) :: any)._directRead):toBeType("function")
        end)
    end)

    describe("round-trip at every wire-type boundary", function(): ()
        local cases = {
            { codec = Lync.int(0, 255), values = { 0, 1, 127, 128, 254, 255 } },
            { codec = Lync.int(0, 65535), values = { 0, 1, 256, 32767, 32768, 65534, 65535 } },
            { codec = Lync.int(0, 0xFFFFFFFF), values = { 0, 65536, 0x7FFFFFFF, 0xFFFFFFFF } },
            { codec = Lync.int(-128, 127), values = { -128, -1, 0, 1, 127 } },
            {
                codec = Lync.int(-32768, 32767),
                values = { -32768, -129, -1, 0, 1, 32767 },
            },
            {
                codec = Lync.int(-2147483648, 2147483647),
                values = { -2147483648, -1, 0, 1, 2147483647 },
            },
        }
        for _, case in cases do
            for _, v in case.values do
                it(`{tostring(v)} via {(case.codec :: any)._size}-byte codec`, function(): ()
                    local decoded, written = Channel.roundTripStrict(case.codec, v)
                    expect(decoded):toBe(v)
                    expect(written):toBe((case.codec :: any)._size)
                end)
            end
        end
    end)

    describe("define-time errors", function(): ()
        it("min > max throws", function(): ()
            expect(function(): ()
                Lync.int(10, 5)
            end):toThrow("min")
        end)
        it("non-integer min throws", function(): ()
            expect(function(): ()
                Lync.int(0.5, 10)
            end):toThrow("integer")
        end)
        it("non-integer max throws", function(): ()
            expect(function(): ()
                Lync.int(0, 10.5)
            end):toThrow("integer")
        end)
        it("range exceeding i32 throws", function(): ()
            expect(function(): ()
                Lync.int(-3000000000, 3000000000)
            end):toThrow("i32")
        end)
    end)
end)

return nil
