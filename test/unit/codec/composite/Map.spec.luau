--!strict
--!optimize 2
-- Lync.map and Lync.deltaMap: varint count plus key/value entries.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Map", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("metadata", function(): ()
        it("flags _isMap", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            expect((c :: any)._isMap):toBe(true)
        end)
        it("records key and value codecs", function(): ()
            local k = Lync.string
            local v = Lync.int(0, 255)
            local c = Lync.map(k, v)
            expect((c :: any)._keyCodec):toBe(k)
            expect((c :: any)._valueCodec):toBe(v)
        end)
        it("records maxCount", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255), 100)
            expect((c :: any)._maxCount):toBe(100)
        end)
    end)

    describe("round-trip", function(): ()
        it("empty map = 1 byte", function(): ()
            local _, w = Channel.roundTripStrict(Lync.map(Lync.string, Lync.int(0, 255)), {})
            expect(w):toBe(1)
        end)
        it("string -> u8 entries", function(): ()
            local r = Channel.roundTripStrict(
                Lync.map(Lync.string, Lync.int(0, 255)),
                { hp = 100, mp = 50 }
            )
            expect(r.hp):toBe(100)
            expect(r.mp):toBe(50)
        end)
        it("u8 -> string entries", function(): ()
            local r = Channel.roundTripStrict(
                Lync.map(Lync.int(0, 255), Lync.string),
                { [1] = "one", [2] = "two" }
            )
            expect(r[1]):toBe("one")
            expect(r[2]):toBe("two")
        end)
        it("10 entries", function(): ()
            local data: any = {}
            for i = 1, 10 do
                data[`k{i}`] = i
            end
            local r = Channel.roundTripStrict(Lync.map(Lync.string, Lync.int(0, 255)), data)
            expect(r.k1):toBe(1)
            expect(r.k10):toBe(10)
        end)
        it("nested map", function(): ()
            local inner = Lync.map(Lync.string, Lync.int(0, 255))
            local outer = Lync.map(Lync.string, inner)
            local r = Channel.roundTripStrict(outer, { a = { x = 1 }, b = { y = 2 } })
            expect(r.a.x):toBe(1)
            expect(r.b.y):toBe(2)
        end)
    end)

    describe("maxCount enforcement", function(): ()
        it("read of an over-limit map throws", function(): ()
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r = Channel.encode(c, { [1] = 10, [2] = 20, [3] = 30 })
            local bounded = Lync.map(Lync.int(0, 255), Lync.int(0, 255), 2)
            expect(function(): ()
                bounded.read(r.buffer, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("deltaMap", function(): ()
        it("flags _isDelta", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            expect((c :: any)._isDelta):toBe(true)
        end)
        it("identical second write = exactly 1 byte", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 100 })
            expect(ch.cursor):toBe(1)
        end)
        it("changed write produces > 1 byte", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 80 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
    end)

    describe("deterministic key sort", function(): ()
        it("string keys produce identical bytes regardless of insert order", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            local r1 = Channel.encode(c, { a = 1, b = 2, c = 3 })
            local r2 = Channel.encode(c, { c = 3, a = 1, b = 2 })
            expect(r1.length):toBe(r2.length)
            for i = 0, r1.length - 1 do
                expect(buffer.readu8(r1.buffer, i)):toBe(buffer.readu8(r2.buffer, i))
            end
        end)
        it("number keys sort directly via <", function(): ()
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r1 = Channel.encode(c, { [3] = 30, [1] = 10, [2] = 20 })
            local r2 = Channel.encode(c, { [1] = 10, [2] = 20, [3] = 30 })
            expect(r1.length):toBe(r2.length)
        end)
    end)

    describe("write-side validation", function(): ()
        it("non-table value throws", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            expect(function(): ()
                Channel.encode(c, "not a map" :: any)
            end):toThrow("expected table")
        end)
        it("number-typed value throws", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            expect(function(): ()
                Channel.encode(c, 42 :: any)
            end):toThrow("expected table")
        end)
    end)

    describe("fixed-size key + value fast path", function(): ()
        it("u8 -> u8 has fixed entry size of 2 bytes per pair", function(): ()
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r = Channel.encode(c, { [1] = 10, [2] = 20, [3] = 30 })
            -- 1 byte count + 3 entries * 2 bytes = 7
            expect(r.length):toBe(7)
        end)
        it("u8 -> u16 entry size = 3 bytes", function(): ()
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 65535))
            local r = Channel.encode(c, { [1] = 1000, [2] = 2000 })
            expect(r.length):toBe(1 + 2 * 3)
        end)
    end)

    describe("empty map round-trips", function(): ()
        it("empty -> 1-byte count -> empty decoded table", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            local v = Channel.roundTripStrict(c, {})
            local n = 0
            for _ in v do n += 1 end
            expect(n):toBe(0)
        end)
    end)

    describe("read truncation", function(): ()
        it("truncated key payload throws", function(): ()
            -- Manually write count = 1, but no key/value bytes follow.
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            local b = buffer.create(1)
            buffer.writeu8(b, 0, 1)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow()
        end)
    end)
end)

return nil
