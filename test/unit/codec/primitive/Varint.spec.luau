--!strict
--!optimize 2
-- Dense prefix varint codec: tier boundaries, sizes, error paths.

local Env = require(script:FindFirstAncestor("test").Env)

local Sandbox = Env.Sandbox
local Varint = Env.Internal.Varint
local InternalChannel = Env.Internal.Channel

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

local function encode(value: number): (buffer, number)
    local ch = InternalChannel.create()
    Varint.write(ch, value)
    local len = ch.cursor
    local out = buffer.create(len)
    if len > 0 then
        buffer.copy(out, 0, ch.buff, 0, len)
    end
    return out, len
end

describe("codec.primitive.Varint", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("INLINE_MAX constant", function(): ()
        it("equals 0xBF (191)", function(): ()
            expect(Varint.INLINE_MAX):toBe(191)
        end)
    end)

    describe("tier 1 (1 byte): 0..191", function(): ()
        local values = { 0, 1, 63, 127, 128, 190, 191 }
        for _, v in values do
            it(`{v} round-trips in 1 byte`, function(): ()
                local buf, len = encode(v)
                expect(len):toBe(1)
                local r, bytes = Varint.read(buf, 0)
                expect(r):toBe(v)
                expect(bytes):toBe(1)
            end)
        end
    end)

    describe("tier 2 (2 bytes): 192..8383", function(): ()
        local values = { 192, 193, 255, 256, 1000, 8382, 8383 }
        for _, v in values do
            it(`{v} round-trips in 2 bytes`, function(): ()
                local buf, len = encode(v)
                expect(len):toBe(2)
                local r, bytes = Varint.read(buf, 0)
                expect(r):toBe(v)
                expect(bytes):toBe(2)
            end)
        end
    end)

    describe("tier 3 (3 bytes): 8384..1056959", function(): ()
        local values = { 8384, 8385, 16384, 65535, 65536, 100000, 1056958, 1056959 }
        for _, v in values do
            it(`{v} round-trips in 3 bytes`, function(): ()
                local buf, len = encode(v)
                expect(len):toBe(3)
                local r, bytes = Varint.read(buf, 0)
                expect(r):toBe(v)
                expect(bytes):toBe(3)
            end)
        end
    end)

    describe("tier 4 (5 bytes): 1056960..0xFFFFFFFF", function(): ()
        local values = { 1056960, 1056961, 0x01000000, 0x7FFFFFFF, 0xFFFFFFFF }
        for _, v in values do
            it(`{v} round-trips in 5 bytes`, function(): ()
                local buf, len = encode(v)
                expect(len):toBe(5)
                local r, bytes = Varint.read(buf, 0)
                expect(r):toBe(v)
                expect(bytes):toBe(5)
            end)
        end
    end)

    describe("writeInline path", function(): ()
        it("writes a single byte without range check", function(): ()
            local ch = InternalChannel.create()
            Varint.writeInline(ch, 42)
            expect(ch.cursor):toBe(1)
            expect(buffer.readu8(ch.buff, 0)):toBe(42)
        end)
        it("writes 0 as 0x00", function(): ()
            local ch = InternalChannel.create()
            Varint.writeInline(ch, 0)
            expect(buffer.readu8(ch.buff, 0)):toBe(0)
        end)
        it("writes 191 as 0xBF (the inline ceiling)", function(): ()
            local ch = InternalChannel.create()
            Varint.writeInline(ch, 191)
            expect(buffer.readu8(ch.buff, 0)):toBe(0xBF)
        end)
    end)

    describe("readLengthPrefix matches read for tier-1", function(): ()
        it("0 reads identically", function(): ()
            local buf = encode(0)
            local v1, b1 = Varint.read(buf, 0)
            local v2, b2 = Varint.readLengthPrefix(buf, 0)
            expect(v1):toBe(v2)
            expect(b1):toBe(b2)
        end)
        it("127 reads identically", function(): ()
            local buf = encode(127)
            local v1, b1 = Varint.read(buf, 0)
            local v2, b2 = Varint.readLengthPrefix(buf, 0)
            expect(v1):toBe(v2)
            expect(b1):toBe(b2)
        end)
        it("191 reads identically", function(): ()
            local buf = encode(191)
            local v1, b1 = Varint.read(buf, 0)
            local v2, b2 = Varint.readLengthPrefix(buf, 0)
            expect(v1):toBe(v2)
            expect(b1):toBe(b2)
        end)
    end)

    describe("readLengthPrefix delegates for higher tiers", function(): ()
        it("8000 reads as 2-byte tier", function(): ()
            local buf = encode(8000)
            local v, bytes = Varint.readLengthPrefix(buf, 0)
            expect(v):toBe(8000)
            expect(bytes):toBe(2)
        end)
        it("100000 reads as 3-byte tier", function(): ()
            local buf = encode(100000)
            local v, bytes = Varint.readLengthPrefix(buf, 0)
            expect(v):toBe(100000)
            expect(bytes):toBe(3)
        end)
        it("0xFFFFFFFF reads as 5-byte tier", function(): ()
            local buf = encode(0xFFFFFFFF)
            local v, bytes = Varint.readLengthPrefix(buf, 0)
            expect(v):toBe(0xFFFFFFFF)
            expect(bytes):toBe(5)
        end)
    end)

    describe("consecutive writes decode independently", function(): ()
        it("(300, 5)", function(): ()
            local ch = InternalChannel.create()
            Varint.write(ch, 300)
            Varint.write(ch, 5)
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local v1, b1 = Varint.read(buf, 0)
            local v2 = Varint.read(buf, b1)
            expect(v1):toBe(300)
            expect(v2):toBe(5)
        end)
        it("(0xFFFFFFFF, 0)", function(): ()
            local ch = InternalChannel.create()
            Varint.write(ch, 0xFFFFFFFF)
            Varint.write(ch, 0)
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local v1, b1 = Varint.read(buf, 0)
            local v2 = Varint.read(buf, b1)
            expect(v1):toBe(0xFFFFFFFF)
            expect(v2):toBe(0)
        end)
    end)

    describe("read at non-zero offset", function(): ()
        it("reads correctly past a leading garbage byte", function(): ()
            local ch = InternalChannel.create()
            buffer.writeu8(ch.buff, 0, 0xFF)
            ch.cursor = 1
            Varint.write(ch, 1000)
            local buf = buffer.create(ch.cursor)
            buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
            local v = Varint.read(buf, 1)
            expect(v):toBe(1000)
        end)
    end)

    describe("rejects invalid input on write", function(): ()
        it("negative", function(): ()
            expect(function(): ()
                Varint.write(InternalChannel.create(), -1)
            end):toThrow("Varint")
        end)
        it("non-integer", function(): ()
            expect(function(): ()
                Varint.write(InternalChannel.create(), 1.5)
            end):toThrow("Varint")
        end)
        it("exceeds u32", function(): ()
            expect(function(): ()
                Varint.write(InternalChannel.create(), 0x100000000)
            end):toThrow("Varint")
        end)
        it("NaN", function(): ()
            expect(function(): ()
                Varint.write(InternalChannel.create(), 0 / 0)
            end):toThrow("Varint")
        end)
    end)

    describe("wire encoding (canonical)", function(): ()
        it("0 -> 0x00", function(): ()
            local buf = encode(0)
            expect(buf):toMatchBuffer({ 0x00 })
        end)
        it("191 -> 0xBF", function(): ()
            local buf = encode(191)
            expect(buf):toMatchBuffer({ 0xBF })
        end)
        it("192 -> 0xC0 0x00 (tier 2 start)", function(): ()
            local buf = encode(192)
            expect(buf):toMatchBuffer({ 0xC0, 0x00 })
        end)
        it("0xFFFFFFFF -> 0xF0 0xFF 0xFF 0xFF 0xFF (tier 4)", function(): ()
            local buf = encode(0xFFFFFFFF)
            expect(buf):toMatchBuffer({ 0xF0, 0xFF, 0xFF, 0xFF, 0xFF })
        end)
    end)
end)

return nil
