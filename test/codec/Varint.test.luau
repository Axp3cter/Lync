--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Runner = require(script.Parent.Parent.Runner)
local Varint = require(script.Parent.Parent.Parent.codec.primitive.Varint)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Varint round-trip at every tier boundary", function(): ()
    for _, n in
        {
            0,
            1,
            63,
            127,
            128,
            190,
            191,
            192,
            193,
            255,
            256,
            1000,
            8382,
            8383,
            8384,
            8385,
            16383,
            16384,
            65535,
            65536,
            100000,
            1056958,
            1056959,
            1056960,
            1056961,
            0x7FFFFFFF,
            0xFFFFFFFF,
        }
    do
        it(`{n}`, function(): ()
            local ch = Channel.create()
            Varint.write(ch, n)
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local val, bytes = Varint.read(buf, 0)
            expect(val):toBe(n)
            expect(bytes):toBe(ch.cursor)
        end)
    end
end)

describe("Varint wire sizes", function(): ()
    it("0 = 1 byte", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 0)
        expect(ch.cursor):toBe(1)
    end)
    it("127 = 1 byte", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 127)
        expect(ch.cursor):toBe(1)
    end)
    it("128 = 1 byte (beats LEB128)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 128)
        expect(ch.cursor):toBe(1)
    end)
    it("191 = 1 byte (max inline)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 191)
        expect(ch.cursor):toBe(1)
    end)
    it("192 = 2 bytes (tier 2 start)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 192)
        expect(ch.cursor):toBe(2)
    end)
    it("8383 = 2 bytes (tier 2 end)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 8383)
        expect(ch.cursor):toBe(2)
    end)
    it("8384 = 3 bytes (tier 3 start)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 8384)
        expect(ch.cursor):toBe(3)
    end)
    it("65535 = 3 bytes", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 65535)
        expect(ch.cursor):toBe(3)
    end)
    it("1056959 = 3 bytes (tier 3 end)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 1056959)
        expect(ch.cursor):toBe(3)
    end)
    it("1056960 = 5 bytes (tier 4 start)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 1056960)
        expect(ch.cursor):toBe(5)
    end)
    it("0xFFFFFFFF = 5 bytes (u32 max)", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 0xFFFFFFFF)
        expect(ch.cursor):toBe(5)
    end)
end)

describe("Varint INLINE_MAX", function(): ()
    it("is 191 (0xBF)", function(): ()
        expect(Varint.INLINE_MAX):toBe(191)
    end)
end)

describe("Varint writeInline", function(): ()
    it("writes single byte without range check", function(): ()
        local ch = Channel.create()
        Varint.writeInline(ch, 42)
        expect(ch.cursor):toBe(1)
        expect(buffer.readu8(ch.buff, 0)):toBe(42)
    end)
    it("writes 0", function(): ()
        local ch = Channel.create()
        Varint.writeInline(ch, 0)
        expect(buffer.readu8(ch.buff, 0)):toBe(0)
    end)
end)

describe("Varint consecutive writes", function(): ()
    it("two varints back-to-back decode independently", function(): ()
        local ch = Channel.create()
        Varint.write(ch, 300)
        Varint.write(ch, 5)
        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        local v1, b1 = Varint.read(buf, 0)
        local v2, b2 = Varint.read(buf, b1)
        expect(v1):toBe(300)
        expect(v2):toBe(5)
    end)
end)

describe("Varint read at non-zero offset", function(): ()
    it("reads correctly with offset", function(): ()
        local ch = Channel.create()
        buffer.writeu8(ch.buff, 0, 0xFF) -- garbage byte
        ch.cursor = 1
        Varint.write(ch, 1000)
        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        local val, bytes = Varint.read(buf, 1)
        expect(val):toBe(1000)
    end)
end)

describe("Varint rejects invalid input", function(): ()
    it("negative", function(): ()
        expect(function(): ()
            Varint.write(Channel.create(), -1)
        end):toThrow("Varint")
    end)
    it("non-integer", function(): ()
        expect(function(): ()
            Varint.write(Channel.create(), 1.5)
        end):toThrow("Varint")
    end)
    it("exceeds u32", function(): ()
        expect(function(): ()
            Varint.write(Channel.create(), 0x100000000)
        end):toThrow("Varint")
    end)
    it("NaN", function(): ()
        expect(function(): ()
            Varint.write(Channel.create(), 0 / 0)
        end):toThrow("Varint")
    end)
end)

return nil
