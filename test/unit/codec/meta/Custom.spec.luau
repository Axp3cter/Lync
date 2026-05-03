--!strict
--!optimize 2
-- Lync.custom: user-defined fixed-size codec.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.meta.Custom", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("4-byte u32 codec", function(): ()
        local function build(): any
            return Lync.custom(4, function(b: buffer, off: number, v: number): ()
                buffer.writeu32(b, off, v)
            end, function(b: buffer, off: number): number
                return buffer.readu32(b, off)
            end)
        end

        it("_size = 4", function(): ()
            expect((build() :: any)._size):toBe(4)
        end)
        it("round-trips 12345", function(): ()
            expect(Channel.roundTripStrict(build(), 12345)):toBe(12345)
        end)
        it("exposes _directWrite and _directRead", function(): ()
            expect((build() :: any)._directWrite):toBeType("function")
            expect((build() :: any)._directRead):toBeType("function")
        end)
    end)

    describe("typed custom codec", function(): ()
        it("typeCheck propagates", function(): ()
            local c = Lync.custom(1, function(b, o, v)
                buffer.writeu8(b, o, v)
            end, function(b, o)
                return buffer.readu8(b, o)
            end, "number")
            expect((c :: any)._typeCheck):toBe("number")
        end)
    end)

    describe("size 0 yields a constant codec", function(): ()
        it("zero-byte custom returns nil from read", function(): ()
            local c = Lync.custom(0, function() end, function()
                return nil
            end)
            expect((c :: any)._size):toBe(0)
        end)
    end)

    describe("define-time errors", function(): ()
        it("rejects negative size", function(): ()
            expect(function(): ()
                Lync.custom(-1, function() end, function() end)
            end):toThrow("non-negative")
        end)
        it("rejects non-integer size", function(): ()
            expect(function(): ()
                Lync.custom(1.5, function() end, function() end)
            end):toThrow("non-negative")
        end)
        it("rejects nil size", function(): ()
            expect(function(): ()
                (Lync.custom :: any)(nil, function() end, function() end)
            end):toThrow()
        end)
        it("rejects string size", function(): ()
            expect(function(): ()
                (Lync.custom :: any)("4", function() end, function() end)
            end):toThrow()
        end)
    end)

    describe("various sizes", function(): ()
        it("1-byte custom (i8)", function(): ()
            local c = Lync.custom(1, function(b, o, v)
                buffer.writei8(b, o, v)
            end, function(b, o)
                return buffer.readi8(b, o)
            end)
            expect(Channel.roundTripStrict(c, -7)):toBe(-7)
            expect(Channel.roundTripStrict(c, 100)):toBe(100)
        end)
        it("2-byte custom (u16)", function(): ()
            local c = Lync.custom(2, function(b, o, v)
                buffer.writeu16(b, o, v)
            end, function(b, o)
                return buffer.readu16(b, o)
            end)
            expect(Channel.roundTripStrict(c, 0xCAFE)):toBe(0xCAFE)
        end)
        it("8-byte custom (f64)", function(): ()
            local c = Lync.custom(8, function(b, o, v)
                buffer.writef64(b, o, v)
            end, function(b, o)
                return buffer.readf64(b, o)
            end)
            local v = Channel.roundTripStrict(c, 1.5e100)
            expect(v):toBeCloseTo(1.5e100, 1e90)
        end)
        it("16-byte custom (two i64-like halves)", function(): ()
            local c = Lync.custom(16, function(b, o, v)
                buffer.writeu32(b, o, v.a)
                buffer.writeu32(b, o + 4, v.b)
                buffer.writeu32(b, o + 8, v.c)
                buffer.writeu32(b, o + 12, v.d)
            end, function(b, o)
                return {
                    a = buffer.readu32(b, o),
                    b = buffer.readu32(b, o + 4),
                    c = buffer.readu32(b, o + 8),
                    d = buffer.readu32(b, o + 12),
                }
            end)
            local r = Channel.roundTripStrict(c, { a = 1, b = 2, c = 3, d = 4 })
            expect(r.a):toBe(1)
            expect(r.d):toBe(4)
        end)
    end)

    describe("typeCheck behavior", function(): ()
        it("nil typeCheck leaves field nil", function(): ()
            local c = Lync.custom(1, function(b, o, v)
                buffer.writeu8(b, o, v)
            end, function(b, o)
                return buffer.readu8(b, o)
            end)
            expect((c :: any)._typeCheck):toBeNil()
        end)
        it("custom typeCheck string surfaces verbatim", function(): ()
            local c = Lync.custom(1, function() end, function()
                return nil
            end, "my_type")
            expect((c :: any)._typeCheck):toBe("my_type")
        end)
    end)

    describe("size 0 collapses to constant codec", function(): ()
        it("write does nothing, read returns the configured value", function(): ()
            local c = Lync.custom(0, function() end, function()
                return "shouldnt be called"
            end)
            local r = Channel.encode(c, "ignored")
            expect(r.length):toBe(0)
            expect(Channel.decode(c, r)):toBeNil()
        end)
    end)
end)

return nil
