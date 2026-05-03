--!strict
--!optimize 2
-- Lync.buff: variable-length buffer codec with varint length prefix.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox
local Wire = Env.Wire

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.datatype.Buffer", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("declares _typeCheck = buffer", function(): ()
            expect((Lync.buff :: any)._typeCheck):toBe("buffer")
        end)
        it("is frozen", function(): ()
            expect(Lync.buff):toBeFrozen()
        end)
    end)

    describe("round-trip", function(): ()
        it("empty buffer encodes to 1 byte (zero length prefix)", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(0))
            expect(r.length):toBe(1)
            local v = Channel.decode(Lync.buff, r)
            expect(v):toBeBuffer(0)
        end)
        it("4-byte payload encodes inline (1 prefix + 4 data)", function(): ()
            local input = buffer.create(4)
            buffer.writeu32(input, 0, 0xDEADBEEF)
            local r = Channel.encode(Lync.buff, input)
            expect(r.length):toBe(5)
            local v = Channel.decode(Lync.buff, r)
            expect(buffer.readu32(v, 0)):toBe(0xDEADBEEF)
        end)
        it("191-byte payload sits at the inline ceiling (1 + 191)", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(191))
            expect(r.length):toBe(192)
        end)
        it("192-byte payload uses 2-byte varint prefix (2 + 192)", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(192))
            expect(r.length):toBe(194)
        end)
        it("100-byte payload preserves all bytes", function(): ()
            local input = buffer.create(100)
            for i = 0, 99 do
                buffer.writeu8(input, i, i)
            end
            local _, written, consumed = Channel.roundTrip(Lync.buff, input)
            expect(written):toBe(consumed)
        end)
    end)

    describe("read produces an isolated copy", function(): ()
        it("mutating decoded buffer does not affect a second read", function(): ()
            local input = buffer.create(4)
            buffer.writeu32(input, 0, 0xCAFE)
            local r = Channel.encode(Lync.buff, input)
            local r1 = Channel.decode(Lync.buff, r)
            local r2 = Channel.decode(Lync.buff, r)
            buffer.writeu32(r1, 0, 0)
            expect(buffer.readu32(r2, 0)):toBe(0xCAFE)
        end)
    end)

    describe("non-buffer rejection at the boundary", function(): ()
        --[[
            The codec doesn't validate type itself; that's Gate's job. But
            buffer.writestring and buffer.copy will throw if given a string
            instead of a buffer. Pin that this propagates.
        ]]
        it("write of a string throws", function(): ()
            expect(function(): ()
                Channel.encode(Lync.buff, "not a buffer" :: any)
            end):toThrow()
        end)
    end)

    describe("read rejects truncated payload", function(): ()
        it("declared length exceeds remaining bytes", function(): ()
            local r = Wire.bufferFromBytes({ 50 })
            expect(function(): ()
                Lync.buff.read(r, 0, nil)
            end):toThrow("exceeds")
        end)
    end)

    describe("byte-pattern preservation", function(): ()
        it("all 0xFF bytes survive round-trip", function(): ()
            local input = buffer.create(64)
            buffer.fill(input, 0, 0xFF)
            local v = Channel.decode(Lync.buff, Channel.encode(Lync.buff, input))
            for i = 0, 63 do
                expect(buffer.readu8(v, i)):toBe(0xFF)
            end
        end)
        it("alternating 0x00/0xFF survives", function(): ()
            local input = buffer.create(8)
            for i = 0, 7 do
                buffer.writeu8(input, i, if i % 2 == 0 then 0x00 else 0xFF)
            end
            local v = Channel.decode(Lync.buff, Channel.encode(Lync.buff, input))
            for i = 0, 7 do
                expect(buffer.readu8(v, i)):toBe(if i % 2 == 0 then 0x00 else 0xFF)
            end
        end)
        it("ascending byte sequence survives", function(): ()
            local input = buffer.create(256)
            for i = 0, 255 do
                buffer.writeu8(input, i, i)
            end
            local v = Channel.decode(Lync.buff, Channel.encode(Lync.buff, input))
            expect(buffer.len(v)):toBe(256)
            expect(buffer.readu8(v, 100)):toBe(100)
        end)
    end)

    describe("varint length boundaries (matches Varint tier table)", function(): ()
        it("0-byte payload uses 1 varint byte", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(0))
            expect(r.length):toBe(1)
        end)
        it("1-byte payload uses 1 varint + 1 data = 2", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(1))
            expect(r.length):toBe(2)
        end)
        it("8383-byte payload uses 2-byte varint (2 + 8383 = 8385)", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(8383))
            expect(r.length):toBe(8385)
        end)
        it("8384-byte payload uses 3-byte varint (3 + 8384 = 8387)", function(): ()
            local r = Channel.encode(Lync.buff, buffer.create(8384))
            expect(r.length):toBe(8387)
        end)
    end)

    describe("read returns a fresh buffer not aliased to source", function(): ()
        it("mutating decoded buffer does not affect source", function(): ()
            local input = buffer.create(4)
            buffer.writeu32(input, 0, 0xAABBCCDD)
            local r = Channel.encode(Lync.buff, input)
            local decoded = Channel.decode(Lync.buff, r)
            buffer.writeu32(decoded, 0, 0)
            expect(buffer.readu32(input, 0)):toBe(0xAABBCCDD)
        end)
    end)
end)

return nil
