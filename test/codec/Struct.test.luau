--!strict
--!optimize 2
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("struct", function(): ()
    it("single field", function(): ()
        local c = Lync.struct({ hp = Lync.u8 })
        local r = roundTrip(c, { hp = 100 })
        expect(r.hp):toBe(100)
    end)
    it("multi field", function(): ()
        local c = Lync.struct({ x = Lync.f32, y = Lync.f32, name = Lync.string })
        local r = roundTrip(c, { x = 1.5, y = 2.5, name = "test" })
        expect(r.x):toBeCloseTo(1.5)
        expect(r.y):toBeCloseTo(2.5)
        expect(r.name):toBe("test")
    end)
    it("nested struct", function(): ()
        local inner = Lync.struct({ a = Lync.u8 })
        local outer = Lync.struct({ child = inner, val = Lync.u16 })
        local r = roundTrip(outer, { child = { a = 42 }, val = 1000 })
        expect(r.child.a):toBe(42)
        expect(r.val):toBe(1000)
    end)
end)

describe("struct bools packing", function(): ()
    it("single bool", function(): ()
        local c = Lync.struct({ alive = Lync.bool })
        local r = roundTrip(c, { alive = true })
        expect(r.alive):toBe(true)
    end)
    it("multi bools packed into 1 byte", function(): ()
        local c = Lync.struct({ a = Lync.bool, b = Lync.bool, c = Lync.bool, d = Lync.bool })
        local r, w = roundTrip(c, { a = true, b = false, c = true, d = false })
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
        expect(r.d):toBe(false)
        expect(w):toBe(1)
    end)
    it("9 bools = 2 bytes", function(): ()
        local fields = {}
        for i = 1, 9 do
            fields["b" .. i] = Lync.bool
        end
        local c = Lync.struct(fields)
        local data = {}
        for i = 1, 9 do
            data["b" .. i] = i % 2 == 0
        end
        local _, w = roundTrip(c, data)
        expect(w):toBe(2)
    end)
    it("mixed bool + number", function(): ()
        local c = Lync.struct({ alive = Lync.bool, hp = Lync.u8 })
        local r = roundTrip(c, { alive = false, hp = 50 })
        expect(r.alive):toBe(false)
        expect(r.hp):toBe(50)
    end)
end)

describe("struct _size", function(): ()
    it("all-fixed fields", function(): ()
        local c = Lync.struct({ a = Lync.u8, b = Lync.u16 })
        expect((c :: any)._size):toBe(3)
    end)
    it("nil when dynamic", function(): ()
        local c = Lync.struct({ name = Lync.string })
        expect((c :: any)._size):toBeNil()
    end)
end)

describe("struct validation", function(): ()
    it("throws on empty schema", function(): ()
        expect(function(): ()
            Lync.struct({})
        end):toThrow("at least one field")
    end)
end)

describe("deltaStruct", function(): ()
    it("first write is full", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaStruct({ hp = Lync.u8, mp = Lync.u8 })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        local w1 = ch.cursor
        expect(w1):toBeGreaterThan(0)
    end)
    it("identical write is smaller", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaStruct({ hp = Lync.u8, mp = Lync.u8 })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        local w1 = ch.cursor
        ch.cursor = 0
        c.write(ch, { hp = 100, mp = 50 })
        local w2 = ch.cursor
        expect(w2):toBeLessThan(w1)
    end)
    it("changed field appears in delta", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaStruct({ hp = Lync.u8, mp = Lync.u8 })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        ch.cursor = 0
        c.write(ch, { hp = 80, mp = 50 })
        local buf = buffer.create(ch.cursor)
        buffer.copy(buf, 0, ch.buff, 0, ch.cursor)
        local r, _ = c.read(buf, 0, nil)
        expect(r.hp):toBe(80)
    end)
end)

describe("deltaStruct round-trip", function(): ()
    it("full round-trip", function(): ()
        Baseline.setReadKey(false)
        local c = Lync.deltaStruct({ x = Lync.f32, y = Lync.f32, z = Lync.f32 })
        local r = roundTrip(c, { x = 1.5, y = 2.5, z = 3.5 })
        expect(r.x):toBeCloseTo(1.5)
        expect(r.y):toBeCloseTo(2.5)
        expect(r.z):toBeCloseTo(3.5)
    end)
end)

describe("struct all-bool schema", function(): ()
    it("3 bools only", function(): ()
        local c = Lync.struct({ a = Lync.bool, b = Lync.bool, c = Lync.bool })
        local r, w = roundTrip(c, { a = true, b = false, c = true })
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
        expect(w):toBe(1)
    end)
    it("16 bools", function(): ()
        local fields = {}
        local data = {}
        for i = 1, 16 do
            fields["b" .. string.format("%02d", i)] = Lync.bool
            data["b" .. string.format("%02d", i)] = i % 3 == 0
        end
        local c = Lync.struct(fields)
        local r, w = roundTrip(c, data)
        expect(w):toBe(2)
        expect(r.b03):toBe(true)
        expect(r.b04):toBe(false)
        expect(r.b06):toBe(true)
    end)
end)

describe("struct deeply nested", function(): ()
    it("3 levels deep", function(): ()
        local inner = Lync.struct({ v = Lync.u8 })
        local mid = Lync.struct({ child = inner, name = Lync.string })
        local outer = Lync.struct({ mid = mid, id = Lync.u16 })
        local r = roundTrip(outer, { mid = { child = { v = 42 }, name = "test" }, id = 1000 })
        expect(r.mid.child.v):toBe(42)
        expect(r.mid.name):toBe("test")
        expect(r.id):toBe(1000)
    end)
end)

describe("struct many fields", function(): ()
    it("20 fields", function(): ()
        local fields = {}
        local data = {}
        for i = 1, 20 do
            fields["f" .. string.format("%02d", i)] = Lync.u8
            data["f" .. string.format("%02d", i)] = i
        end
        local c = Lync.struct(fields)
        local r = roundTrip(c, data)
        expect(r.f01):toBe(1)
        expect(r.f10):toBe(10)
        expect(r.f20):toBe(20)
    end)
end)

return nil
