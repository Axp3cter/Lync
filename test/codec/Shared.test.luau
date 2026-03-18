--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Runner = require(script.Parent.Parent.Runner)
local Shared = require(script.Parent.Parent.Parent.codec.composite.Shared)
local describe, it, expect = Runner.describe, Runner.it, Runner.expect

describe("Shared.allocDeltaId", function(): ()
    it("returns incrementing ids", function(): ()
        local a = Shared.allocDeltaId()
        local b = Shared.allocDeltaId()
        expect(b):toBe(a + 1)
    end)
    it("returns numbers", function(): ()
        expect(typeof(Shared.allocDeltaId())):toBe("number")
    end)
end)

describe("Shared.acquireScratch / releaseScratch", function(): ()
    it("returns a channel", function(): ()
        local ch = Shared.acquireScratch()
        expect(ch.cursor):toBe(0)
        Shared.releaseScratch()
    end)
    it("resets on release + reacquire", function(): ()
        local ch = Shared.acquireScratch()
        ch.cursor = 500
        Shared.releaseScratch()
        local ch2 = Shared.acquireScratch()
        expect(ch2.cursor):toBe(0)
        Shared.releaseScratch()
    end)
end)

describe("Shared.rangeEqual", function(): ()
    it("equal ranges", function(): ()
        local a = buffer.create(8)
        local b = buffer.create(8)
        buffer.writef64(a, 0, math.pi)
        buffer.writef64(b, 0, math.pi)
        expect(Shared.rangeEqual(a, 0, b, 0, 8)):toBe(true)
    end)
    it("different ranges", function(): ()
        local a = buffer.create(4)
        local b = buffer.create(4)
        buffer.writeu32(a, 0, 1)
        buffer.writeu32(b, 0, 2)
        expect(Shared.rangeEqual(a, 0, b, 0, 4)):toBe(false)
    end)
    it("zero length always true", function(): ()
        local a = buffer.create(4)
        local b = buffer.create(4)
        buffer.writeu32(a, 0, 1)
        buffer.writeu32(b, 0, 2)
        expect(Shared.rangeEqual(a, 0, b, 0, 0)):toBe(true)
    end)
    it("offset comparison", function(): ()
        local a = buffer.create(8)
        local b = buffer.create(8)
        buffer.writeu32(a, 4, 42)
        buffer.writeu32(b, 0, 42)
        expect(Shared.rangeEqual(a, 4, b, 0, 4)):toBe(true)
    end)
end)

describe("Shared.extractFields", function(): ()
    local Lync = require(script.Parent.Parent.Parent)

    it("separates bools from data fields", function(): ()
        local dataKeys, dataCodecs, boolKeys = Shared.extractFields({
            hp = Lync.u8,
            alive = Lync.bool,
            name = Lync.string,
            shield = Lync.bool,
        })
        expect(#boolKeys):toBe(2)
        expect(#dataKeys):toBeGreaterThan(0)
        expect(#dataCodecs):toBe(#dataKeys)
    end)
    it("all bools = empty data keys", function(): ()
        local dataKeys, dataCodecs, boolKeys = Shared.extractFields({
            a = Lync.bool,
            b = Lync.bool,
        })
        expect(#dataKeys):toBe(0)
        expect(#boolKeys):toBe(2)
    end)
    it("no bools = empty bool keys", function(): ()
        local dataKeys, dataCodecs, boolKeys = Shared.extractFields({
            x = Lync.u8,
            y = Lync.f32,
        })
        expect(#boolKeys):toBe(0)
        expect(#dataKeys):toBe(2)
    end)
    it("keys are sorted", function(): ()
        local dataKeys, _, _ = Shared.extractFields({
            z = Lync.u8,
            a = Lync.u8,
            m = Lync.u8,
        })
        expect(dataKeys[1]):toBe("a")
        expect(dataKeys[2]):toBe("m")
        expect(dataKeys[3]):toBe("z")
    end)
end)

describe("Shared.packBools / unpackBools", function(): ()
    it("pack + unpack round-trip", function(): ()
        local ch = Channel.create()
        local keys = { "a", "b", "c" }
        Shared.packBools(ch, keys, 3, { a = true, b = false, c = true })

        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)

        local result = {}
        local consumed = Shared.unpackBools(buf, 0, keys, 3, result)
        expect(result.a):toBe(true)
        expect(result.b):toBe(false)
        expect(result.c):toBe(true)
        expect(consumed):toBe(ch.cursor)
    end)
    it("8 bools in 1 byte", function(): ()
        local ch = Channel.create()
        local keys = {}
        local data = {}
        for i = 1, 8 do
            keys[i] = "b" .. i
            data["b" .. i] = i % 2 == 0
        end
        Shared.packBools(ch, keys, 8, data)
        expect(ch.cursor):toBe(1)
    end)
    it("9 bools in 2 bytes", function(): ()
        local ch = Channel.create()
        local keys = {}
        local data = {}
        for i = 1, 9 do
            keys[i] = "b" .. i
            data["b" .. i] = true
        end
        Shared.packBools(ch, keys, 9, data)
        expect(ch.cursor):toBe(2)
    end)
end)

return nil
