--!strict
--!optimize 2
-- Lync.string: unbounded plus __call factory for bounded variant.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.String", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("declares _typeCheck = string", function(): ()
            expect((Lync.string :: any)._typeCheck):toBe("string")
        end)
        it("__call returns a bounded codec", function(): ()
            local bounded = Lync.string(10) :: any
            expect(bounded._typeCheck):toBe("string")
        end)
    end)

    describe("round-trip unbounded", function(): ()
        it("empty string -> 1 byte length prefix", function(): ()
            local _, w = Channel.roundTripStrict(Lync.string, "")
            expect(w):toBe(1)
        end)
        it("'hello' round-trips with 6 bytes", function(): ()
            local r, w = Channel.roundTripStrict(Lync.string, "hello")
            expect(r):toBe("hello")
            expect(w):toBe(6)
        end)
        it("191 chars -> 192 bytes (1 prefix + 191 data)", function(): ()
            local s = string.rep("x", 191)
            local r, w = Channel.roundTripStrict(Lync.string, s)
            expect(r):toBe(s)
            expect(w):toBe(192)
        end)
        it("192 chars -> 194 bytes (2 prefix + 192 data)", function(): ()
            local s = string.rep("y", 192)
            local r, w = Channel.roundTripStrict(Lync.string, s)
            expect(r):toBe(s)
            expect(w):toBe(194)
        end)
        it("1000 chars round-trip exactly", function(): ()
            local s = string.rep("abcdefghij", 100)
            expect(Channel.roundTripStrict(Lync.string, s)):toBe(s)
        end)
        it("binary-safe (null bytes)", function(): ()
            local s = "abc\0def\0ghi"
            expect(Channel.roundTripStrict(Lync.string, s)):toBe(s)
        end)
        it("preserves all 256 byte values", function(): ()
            local parts = table.create(256)
            for i = 0, 255 do
                parts[i + 1] = string.char(i)
            end
            local s = table.concat(parts)
            expect(Channel.roundTripStrict(Lync.string, s)):toBe(s)
        end)
    end)

    describe("bounded factory accepts within limit", function(): ()
        it("'hello' under maxLength 10", function(): ()
            expect(Channel.roundTripStrict(Lync.string(10), "hello")):toBe("hello")
        end)
        it("empty under maxLength 5", function(): ()
            expect(Channel.roundTripStrict(Lync.string(5), "")):toBe("")
        end)
        it("exactly at maxLength", function(): ()
            expect(Channel.roundTripStrict(Lync.string(5), "abcde")):toBe("abcde")
        end)
    end)

    describe("bounded factory rejects exceeding length on read", function(): ()
        it("encoded 20-char string read as bounded(10) throws", function(): ()
            local r = Channel.encode(Lync.string, string.rep("x", 20))
            expect(function(): ()
                Lync.string(10).read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("define-time errors", function(): ()
        it("maxLength 0 throws", function(): ()
            expect(function(): ()
                Lync.string(0)
            end):toThrow("positive")
        end)
        it("maxLength -1 throws", function(): ()
            expect(function(): ()
                Lync.string(-1)
            end):toThrow("positive")
        end)
    end)
end)

return nil
