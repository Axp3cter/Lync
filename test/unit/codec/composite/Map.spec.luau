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

    describe("deltaMap metadata", function(): ()
        it("flags _isDelta", function(): ()
            expect((Lync.deltaMap(Lync.string, Lync.int(0, 255)) :: any)._isDelta):toBe(true)
        end)
        it("flags _isMap", function(): ()
            expect((Lync.deltaMap(Lync.string, Lync.int(0, 255)) :: any)._isMap):toBe(true)
        end)
        it("records key/value codecs and maxCount", function(): ()
            local k = Lync.string
            local v = Lync.int(0, 255)
            local c = Lync.deltaMap(k, v, 50) :: any
            expect(c._keyCodec):toBe(k)
            expect(c._valueCodec):toBe(v)
            expect(c._maxCount):toBe(50)
        end)
    end)

    describe("deltaMap UNCHANGED", function(): ()
        local function newCh(): any
            return Env.Internal.Channel.create()
        end

        it("identical second write = 1 byte", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 100 })
            expect(ch.cursor):toBe(1)
        end)
        it("identical empty maps = 1 byte each frame", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, {})
            ch.cursor = 0
            c.write(ch, {})
            expect(ch.cursor):toBe(1)
        end)
        it("repeated identical writes stay at 1 byte", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 65535))
            local ch = newCh()
            c.write(ch, { a = 1, b = 2, c = 3 })
            for _ = 1, 10 do
                ch.cursor = 0
                c.write(ch, { a = 1, b = 2, c = 3 })
                expect(ch.cursor):toBe(1)
            end
        end)
    end)

    describe("deltaMap DIFF", function(): ()
        local function newCh(): any
            return Env.Internal.Channel.create()
        end

        it("single value change emits DIFF with 0 removed + 1 changed", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 80 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("removed key emits DIFF with 1 removed + 0 changed", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { a = 1, b = 2 })
            ch.cursor = 0
            c.write(ch, { a = 1 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("added key emits DIFF with 0 removed + 1 changed", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = newCh()
            c.write(ch, { a = 1 })
            ch.cursor = 0
            c.write(ch, { a = 1, b = 2 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
    end)

    describe("deltaMap round-trip via Baseline", function(): ()
        local function decode(c: any, ch: any, startCursor: number): any
            local payload = buffer.create(ch.cursor - startCursor)
            buffer.copy(payload, 0, ch.buff, startCursor, ch.cursor - startCursor)
            return c.read(payload, 0, nil)
        end

        it("FULL → DIFF → UNCHANGED sequence decodes correctly", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { hp = 100, mp = 50 })
            local v1 = decode(c, ch, s1)
            expect(v1.hp):toBe(100)
            expect(v1.mp):toBe(50)

            local s2 = ch.cursor
            c.write(ch, { hp = 80, mp = 50 })
            local v2 = decode(c, ch, s2)
            expect(v2.hp):toBe(80)
            expect(v2.mp):toBe(50)

            local s3 = ch.cursor
            c.write(ch, { hp = 80, mp = 50 })
            local v3 = decode(c, ch, s3)
            expect(v3.hp):toBe(80)
            expect(v3.mp):toBe(50)
        end)
        it("removed-key DIFF drops the entry on the read side", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { a = 1, b = 2, c = 3 })
            decode(c, ch, s1)

            local s2 = ch.cursor
            c.write(ch, { a = 1, c = 3 })
            local v2 = decode(c, ch, s2)
            expect(v2.a):toBe(1)
            expect(v2.b):toBeNil()
            expect(v2.c):toBe(3)
        end)
        it("added-key DIFF adds the entry on the read side", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { a = 1 })
            decode(c, ch, s1)

            local s2 = ch.cursor
            c.write(ch, { a = 1, b = 2 })
            local v2 = decode(c, ch, s2)
            expect(v2.a):toBe(1)
            expect(v2.b):toBe(2)
        end)
        it("mixed add/remove/change in one DIFF decodes correctly", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255))
            local ch = Env.Internal.Channel.create()

            local s1 = ch.cursor
            c.write(ch, { a = 1, b = 2, c = 3 })
            decode(c, ch, s1)

            local s2 = ch.cursor
            c.write(ch, { a = 99, c = 3, d = 4 })
            local v2 = decode(c, ch, s2)
            expect(v2.a):toBe(99)
            expect(v2.b):toBeNil()
            expect(v2.c):toBe(3)
            expect(v2.d):toBe(4)
        end)
    end)

    describe("deltaMap maxCount enforcement", function(): ()
        it("read of an over-limit FULL throws", function(): ()
            local c = Lync.deltaMap(Lync.int(0, 255), Lync.int(0, 255), 2)
            local ch = Env.Internal.Channel.create()
            -- Forge a FULL-flag payload directly with count = 3.
            local big = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r = Channel.encode(big, { [1] = 10, [2] = 20, [3] = 30 })
            local payload = buffer.create(1 + r.length)
            buffer.writeu8(payload, 0, 1) -- DM_FULL
            buffer.copy(payload, 1, r.buffer, 0, r.length)
            expect(function(): ()
                c.read(payload, 0, nil)
            end):toThrow("exceeds max")
        end)
    end)

    describe("deltaMap rejects delta-bearing key/value at define time", function(): ()
        it("deltaMap key with delta errors", function(): ()
            expect(function(): ()
                Lync.deltaMap(Lync.deltaInt(0, 100), Lync.int(0, 255))
            end):toThrow("delta")
        end)
        it("deltaMap value with delta errors", function(): ()
            expect(function(): ()
                Lync.deltaMap(Lync.string, Lync.deltaInt(0, 100))
            end):toThrow("delta")
        end)
        it("deltaMap nested-delta value errors via _hasDelta", function(): ()
            expect(function(): ()
                Lync.deltaMap(Lync.string, Lync.struct({ x = Lync.deltaInt(0, 100) }))
            end):toThrow("delta")
        end)
    end)

    describe("deltaMap DIFF read rejects malformed wire", function(): ()
        it("removeCount exceeding maxCount throws", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255), 5)
            local ch = Env.Internal.Channel.create()
            -- Seed FULL frame so DIFF has a baseline.
            c.write(ch, { a = 1 })
            local fullPayload = buffer.create(ch.cursor)
            buffer.copy(fullPayload, 0, ch.buff, 0, ch.cursor)
            c.read(fullPayload, 0, nil)

            local b = buffer.create(2)
            buffer.writeu8(b, 0, 2) -- DM_DIFF
            buffer.writeu8(b, 1, 99) -- removeCount > maxCount=5
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("exceeds max")
        end)
        it("changeCount exceeding maxCount throws", function(): ()
            local c = Lync.deltaMap(Lync.string, Lync.int(0, 255), 5)
            local ch = Env.Internal.Channel.create()
            c.write(ch, { a = 1 })
            local fullPayload = buffer.create(ch.cursor)
            buffer.copy(fullPayload, 0, ch.buff, 0, ch.cursor)
            c.read(fullPayload, 0, nil)

            -- DIFF flag, removeCount=0, changeCount=99 (forged).
            local b = buffer.create(3)
            buffer.writeu8(b, 0, 2)
            buffer.writeu8(b, 1, 0)
            buffer.writeu8(b, 2, 99)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("exceeds max")
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
            for _ in v do
                n += 1
            end
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

    describe("scratch keys reuse correctness across writes", function(): ()
        -- Pre-fix the cleanup loop used `#keys` which is undefined after
        -- partial overwrite, so a subsequent smaller map could carry stale
        -- entries into its sort + emit.
        it("large-then-small write produces correct second wire layout", function(): ()
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r1 = Channel.encode(c, { [1] = 1, [2] = 2, [3] = 3, [4] = 4, [5] = 5 })
            local r2 = Channel.encode(c, { [1] = 10 })
            -- Second write: 1-byte count + 1 entry (1 key + 1 value) = 3 bytes.
            expect(r2.length):toBe(1 + 2)
            expect(r2.length):toBeLessThan(r1.length)
            local back = Channel.roundTripStrict(c, { [1] = 10 })
            expect(back[1]):toBe(10)
            expect(back[2]):toBeNil()
        end)
        it("shrink-then-grow reuse keeps key sort stable", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            -- Drive the same scratch slot through three sizes back-to-back.
            local _ = Channel.roundTripStrict(c, { a = 1, b = 2, c = 3, d = 4 })
            local _ = Channel.roundTripStrict(c, { z = 9 })
            local r = Channel.roundTripStrict(c, { a = 1, b = 2, c = 3 })
            expect(r.a):toBe(1)
            expect(r.b):toBe(2)
            expect(r.c):toBe(3)
            expect(r.d):toBeNil()
            expect(r.z):toBeNil()
        end)
        it("count=1 byte layout matches what a sorted single-entry produces", function(): ()
            -- count=1 paths skip table.sort entirely (qsort-on-1-elem avoidance).
            -- Wire shape must still be identical to a multi-entry write of size 1.
            local c = Lync.map(Lync.int(0, 255), Lync.int(0, 255))
            local r1 = Channel.encode(c, { [42] = 7 })
            -- 1 byte count + 1 byte key + 1 byte value = 3 bytes.
            expect(r1.length):toBe(3)
            local back = Channel.roundTripStrict(c, { [42] = 7 })
            expect(back[42]):toBe(7)
        end)
        it("empty map = 1 byte and decoded result is empty", function(): ()
            local c = Lync.map(Lync.string, Lync.int(0, 255))
            local r = Channel.encode(c, {})
            expect(r.length):toBe(1)
            local v = Channel.roundTripStrict(c, {})
            local n = 0
            for _ in v do
                n += 1
            end
            expect(n):toBe(0)
        end)
    end)

    describe(
        "OOM defense: variable-size key/value map bounds-checks count before alloc",
        function(): ()
            -- Each pair is at least 2 bytes (key + value). A wire count whose
            -- minimum byte cost exceeds the remaining buffer is corrupt.
            it("count exceeding remaining buffer bytes throws", function(): ()
                local c = Lync.map(Lync.string, Lync.string) -- variable-size both
                local b = buffer.create(1)
                buffer.writeu8(b, 0, 50) -- claims 50 pairs; 0 payload bytes
                expect(function(): ()
                    c.read(b, 0, nil)
                end):toThrow("exceeds remaining")
            end)
        end
    )

    describe("deltaMap DIFF joint bounds defense", function(): ()
        -- removeCount + changeCount must respect the cached size and maxCount.
        it("removeCount exceeding cached size throws", function(): ()
            local c = Lync.deltaMap(Lync.int(0, 255), Lync.int(0, 255), 100)
            local ch = Env.Internal.Channel.create()
            -- Seed FULL frame with 3 entries so cachedSize = 3.
            c.write(ch, { [1] = 10, [2] = 20, [3] = 30 })
            local fullPayload = buffer.create(ch.cursor)
            buffer.copy(fullPayload, 0, ch.buff, 0, ch.cursor)
            c.read(fullPayload, 0, nil)

            -- DIFF flag, removeCount=99 > cachedSize=3.
            local b = buffer.create(2)
            buffer.writeu8(b, 0, 2) -- DM_DIFF
            buffer.writeu8(b, 1, 99) -- removeCount
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("exceeds cached size")
        end)
        it("removeCount + changeCount growing past maxCount throws", function(): ()
            local c = Lync.deltaMap(Lync.int(0, 255), Lync.int(0, 255), 5)
            local ch = Env.Internal.Channel.create()
            -- Cached size = 4 entries.
            c.write(ch, { [1] = 1, [2] = 2, [3] = 3, [4] = 4 })
            local fullPayload = buffer.create(ch.cursor)
            buffer.copy(fullPayload, 0, ch.buff, 0, ch.cursor)
            c.read(fullPayload, 0, nil)

            -- removeCount=0, changeCount=5 → post-DIFF size = 4 + 5 = 9 > maxCount=5.
            local b = buffer.create(3)
            buffer.writeu8(b, 0, 2)
            buffer.writeu8(b, 1, 0)
            buffer.writeu8(b, 2, 5)
            expect(function(): ()
                c.read(b, 0, nil)
            end):toThrow("grow map past maxCount")
        end)
    end)

    describe("nested map scratch isolation", function(): ()
        it("Map<string, Map<string, u8>> with nested resize round-trips", function(): ()
            local inner = Lync.map(Lync.string, Lync.int(0, 255))
            local outer = Lync.map(Lync.string, inner)
            local r = Channel.roundTripStrict(outer, {
                a = { x = 1, y = 2, z = 3 },
                b = { p = 4 },
                c = {},
            })
            expect(r.a.x):toBe(1)
            expect(r.a.y):toBe(2)
            expect(r.a.z):toBe(3)
            expect(r.b.p):toBe(4)
            local cn = 0
            for _ in r.c do
                cn += 1
            end
            expect(cn):toBe(0)
        end)
    end)
end)

return nil
