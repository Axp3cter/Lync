--!strict
--!optimize 2
-- Internal composite-codec helpers: scratch stack, bool packing, range compare.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Sandbox = Env.Sandbox
local Shared = Env.Internal.Shared

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Shared", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("delta flag constants", function(): ()
        it("DELTA_UNCHANGED = 0", function(): ()
            expect(Shared.DELTA_UNCHANGED):toBe(0)
        end)
        it("DELTA_FULL_OFFSET = 1 (the FULL flag value)", function(): ()
            expect(Shared.DELTA_FULL_OFFSET):toBe(1)
        end)
        it("DELTA_MULTI_OFFSET = 2", function(): ()
            expect(Shared.DELTA_MULTI_OFFSET):toBe(2)
        end)
    end)

    describe("allocDeltaId is monotonic", function(): ()
        it("returns increasing IDs", function(): ()
            local a = Shared.allocDeltaId()
            local b = Shared.allocDeltaId()
            local c = Shared.allocDeltaId()
            expect(b):toBeGreaterThan(a)
            expect(c):toBeGreaterThan(b)
        end)
    end)

    describe("containsDelta", function(): ()
        it("plain int does NOT contain delta", function(): ()
            expect(Shared.containsDelta(Lync.int(0, 100))):toBe(false)
        end)
        it("deltaInt itself counts (via _isDelta)", function(): ()
            expect(Shared.containsDelta(Lync.deltaInt(0, 100))):toBe(true)
        end)
        it("struct containing deltaInt counts (via _hasDelta)", function(): ()
            expect(Shared.containsDelta(Lync.struct({ x = Lync.deltaInt(0, 100) }))):toBe(true)
        end)
    end)

    describe("enforceMaxCount", function(): ()
        it("nil max never throws", function(): ()
            expect(function(): ()
                Shared.enforceMaxCount(99999, nil)
            end).never:toThrow()
        end)
        it("len <= max never throws", function(): ()
            expect(function(): ()
                Shared.enforceMaxCount(5, 5)
            end).never:toThrow()
        end)
        it("len > max throws with the label", function(): ()
            expect(function(): ()
                Shared.enforceMaxCount(99, 10, "myLabel")
            end):toThrow("myLabel")
        end)
    end)

    describe("reset", function(): ()
        it("clears scratch depth so a leaked acquire doesn't carry forward", function(): ()
            -- Simulate a write that erred mid-encode and leaked the depth.
            Shared.acquireScratch()
            Shared.acquireScratch()
            -- Both acquires without releases would leak depth=2 forever.
            Shared.reset()
            -- After reset, fresh acquire should give the depth-1 slot.
            local ch = Shared.acquireScratch()
            expect(ch.cursor):toBe(0)
            Shared.releaseScratch()
        end)
    end)

    describe("scratch stack acquire/release", function(): ()
        it("acquire returns a fresh-cursored channel", function(): ()
            local ch = Shared.acquireScratch()
            expect(ch.cursor):toBe(0)
            expect(ch.refCount):toBe(0)
            Shared.releaseScratch()
        end)
        it("acquire scrubs framing state on reuse", function(): ()
            local ch = Shared.acquireScratch()
            ch.lastId = 42
            ch.singleMode = true
            ch.singlePos = 5
            ch.itemCount = 99
            ch.countPos = 7
            ch.currentPacket = "stale"
            ch.deltas[1] = { scalar = 100 } :: any
            Shared.releaseScratch()
            local ch2 = Shared.acquireScratch()
            expect(ch2):toBe(ch)
            expect(ch2.lastId):toBe(-1)
            expect(ch2.singleMode):toBe(false)
            expect(ch2.singlePos):toBe(0)
            expect(ch2.itemCount):toBe(0)
            expect(ch2.countPos):toBe(-1)
            expect(ch2.currentPacket):toBeNil()
            expect(next(ch2.deltas)):toBeNil()
            Shared.releaseScratch()
        end)
        it("nested acquire returns distinct channels", function(): ()
            local outer = Shared.acquireScratch()
            buffer.writeu8(outer.buff, 0, 0xAA)
            outer.cursor = 1
            local inner = Shared.acquireScratch()
            expect(inner).never:toBe(outer)
            Shared.releaseScratch()
            Shared.releaseScratch()
        end)
        it("release then re-acquire reuses the same channel cleared", function(): ()
            local ch1 = Shared.acquireScratch()
            ch1.cursor = 50
            ch1.refCount = 5
            Shared.releaseScratch()
            local ch2 = Shared.acquireScratch()
            expect(ch2):toBe(ch1)
            expect(ch2.cursor):toBe(0)
            expect(ch2.refCount):toBe(0)
            Shared.releaseScratch()
        end)
    end)

    describe("rangeEqual", function(): ()
        it("equal range = true", function(): ()
            local a = buffer.create(8)
            local b = buffer.create(8)
            for i = 0, 7 do
                buffer.writeu8(a, i, i)
                buffer.writeu8(b, i, i)
            end
            expect(Shared.rangeEqual(a, 0, b, 0, 8)):toBe(true)
        end)
        it("differing byte breaks equality", function(): ()
            local a = buffer.create(8)
            local b = buffer.create(8)
            for i = 0, 7 do
                buffer.writeu8(a, i, i)
                buffer.writeu8(b, i, i)
            end
            buffer.writeu8(b, 5, 0xFF)
            expect(Shared.rangeEqual(a, 0, b, 0, 8)):toBe(false)
        end)
        it("offset comparison works correctly", function(): ()
            local a = buffer.create(16)
            local b = buffer.create(16)
            for i = 0, 15 do
                buffer.writeu8(a, i, i)
                buffer.writeu8(b, i, 100 + i)
            end
            -- Compare a[4..7] against b[8..11] which differ.
            expect(Shared.rangeEqual(a, 4, b, 8, 4)):toBe(false)
        end)
        it("zero-length ranges always equal", function(): ()
            local a = buffer.create(4)
            local b = buffer.create(4)
            expect(Shared.rangeEqual(a, 0, b, 0, 0)):toBe(true)
        end)
    end)

    describe("snapshot copies bytes", function(): ()
        it("returns an independent buffer", function(): ()
            local src = buffer.create(8)
            buffer.writeu32(src, 0, 0xCAFEBABE)
            local copy = Shared.snapshot(src, 8)
            expect(buffer.readu32(copy, 0)):toBe(0xCAFEBABE)
            buffer.writeu32(src, 0, 0)
            expect(buffer.readu32(copy, 0)):toBe(0xCAFEBABE)
        end)
        it("zero length returns empty buffer", function(): ()
            local src = buffer.create(8)
            local copy = Shared.snapshot(src, 0)
            expect(buffer.len(copy)):toBe(0)
        end)
    end)

    describe("extractFields splits schema into data and bool keys", function(): ()
        it("two u8 + one bool", function(): ()
            local schema = {
                a = Lync.int(0, 255),
                b = Lync.int(0, 255),
                flag = Lync.bool,
            }
            local dataKeys, dataCodecs, boolKeys = Shared.extractFields(schema)
            expect(#dataKeys):toBe(2)
            expect(#dataCodecs):toBe(2)
            expect(#boolKeys):toBe(1)
            expect(boolKeys[1]):toBe("flag")
        end)
        it("empty schema throws", function(): ()
            expect(function(): ()
                Shared.extractFields({})
            end):toThrow("at least one")
        end)
        it("data keys are alphabetically sorted", function(): ()
            local schema = {
                z = Lync.int(0, 255),
                a = Lync.int(0, 255),
                m = Lync.int(0, 255),
            }
            local dataKeys = Shared.extractFields(schema)
            expect(dataKeys[1]):toBe("a")
            expect(dataKeys[2]):toBe("m")
            expect(dataKeys[3]):toBe("z")
        end)
        it("bool keys are alphabetically sorted", function(): ()
            local schema = { z = Lync.bool, a = Lync.bool, m = Lync.bool }
            local _, _, boolKeys = Shared.extractFields(schema)
            expect(boolKeys[1]):toBe("a")
            expect(boolKeys[3]):toBe("z")
        end)
    end)

    describe("packBools and unpackBools round-trip", function(): ()
        it("8 booleans pack into 1 byte", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            local boolKeys = { "a", "b", "c", "d", "e", "f", "g", "h" }
            local input = {
                a = true,
                b = false,
                c = true,
                d = true,
                e = false,
                f = false,
                g = true,
                h = false,
            }
            Shared.packBools(ch, input, boolKeys, 8)
            expect(ch.cursor):toBe(1)

            local result = {} :: any
            Shared.unpackBools(ch.buff, 0, boolKeys, 8, result)
            expect(result.a):toBe(true)
            expect(result.b):toBe(false)
            expect(result.c):toBe(true)
            expect(result.h):toBe(false)
        end)
        it("9 booleans pack into 2 bytes", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            local keys = {} :: { string }
            local input = {} :: any
            for i = 1, 9 do
                local k = `b{i}`
                keys[i] = k
                input[k] = i % 2 == 0
            end
            Shared.packBools(ch, input, keys, 9)
            expect(ch.cursor):toBe(2)
        end)
        it("zero booleans is a no-op", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            Shared.packBools(ch, {}, {}, 0)
            expect(ch.cursor):toBe(0)
        end)
    end)

    describe("packBools/unpackBools accept precomputed byteCount", function(): ()
        -- Struct callers cache `boolBytes(boolCount)` at codec construction
        -- and pass it through to skip a per-write IDIVK + ADDK.
        it("explicit byteCount yields the same wire bytes as nil", function(): ()
            local InternalChannel = Env.Internal.Channel
            local keys = { "a", "b", "c", "d", "e" }
            local input = { a = true, b = false, c = true, d = true, e = false } :: any

            local chA = InternalChannel.create()
            Shared.packBools(chA, input, keys, 5)

            local chB = InternalChannel.create()
            Shared.packBools(chB, input, keys, 5, 1)

            expect(chB.cursor):toBe(chA.cursor)
            expect(buffer.readu8(chB.buff, 0)):toBe(buffer.readu8(chA.buff, 0))
        end)
        it("unpackBools with explicit byteCount returns the same count", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            local keys = { "a", "b", "c", "d", "e", "f", "g", "h", "i" }
            local input = {} :: any
            for i = 1, 9 do
                input[keys[i]] = i % 2 == 0
            end
            Shared.packBools(ch, input, keys, 9, 2)

            local resultDefault = {} :: any
            local consumedDefault = Shared.unpackBools(ch.buff, 0, keys, 9, resultDefault)
            local resultExplicit = {} :: any
            local consumedExplicit = Shared.unpackBools(ch.buff, 0, keys, 9, resultExplicit, 2)

            expect(consumedExplicit):toBe(consumedDefault)
            for _, k in keys do
                expect(resultExplicit[k]):toBe(resultDefault[k])
            end
        end)
        it("packBoolArray accepts byteCount and matches the implicit form", function(): ()
            local InternalChannel = Env.Internal.Channel
            local arr: { boolean } = { true, false, true, true, false, true }

            local chA = InternalChannel.create()
            Shared.packBoolArray(chA, arr, #arr)

            local chB = InternalChannel.create()
            Shared.packBoolArray(chB, arr, #arr, 1)

            expect(chB.cursor):toBe(chA.cursor)
            expect(buffer.readu8(chB.buff, 0)):toBe(buffer.readu8(chA.buff, 0))
        end)
        it("unpackBoolArray accepts byteCount and matches the implicit form", function(): ()
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            Shared.packBoolArray(ch, { true, false, true }, 3, 1)

            local out1 = table.create(3, false)
            local out2 = table.create(3, false)
            Shared.unpackBoolArray(ch.buff, 0, 3, out1)
            Shared.unpackBoolArray(ch.buff, 0, 3, out2, 1)
            for i = 1, 3 do
                expect(out2[i]):toBe(out1[i])
            end
        end)
    end)
end)

return nil
