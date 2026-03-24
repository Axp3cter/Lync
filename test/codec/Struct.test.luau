--!strict
--!optimize 2
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("struct basic", function(): ()
    it("single u8 field", function(): ()
        local r = roundTrip(Lync.struct({ hp = Lync.int(0, 255) }), { hp = 100 })
        expect(r.hp):toBe(100)
    end)
    it("two fields", function(): ()
        local c = Lync.struct({ a = Lync.int(0, 255), b = Lync.int(0, 65535) })
        local r = roundTrip(c, { a = 42, b = 1000 })
        expect(r.a):toBe(42)
        expect(r.b):toBe(1000)
    end)
    it("mixed types", function(): ()
        local c = Lync.struct({ x = Lync.f32, y = Lync.f32, name = Lync.string })
        local r = roundTrip(c, { x = 1.5, y = 2.5, name = "test" })
        expect(r.x):toBeCloseTo(1.5)
        expect(r.y):toBeCloseTo(2.5)
        expect(r.name):toBe("test")
    end)
    it("nested struct", function(): ()
        local inner = Lync.struct({ a = Lync.int(0, 255) })
        local outer = Lync.struct({ child = inner, val = Lync.int(0, 65535) })
        local r = roundTrip(outer, { child = { a = 42 }, val = 1000 })
        expect(r.child.a):toBe(42)
        expect(r.val):toBe(1000)
    end)
    it("3 levels deep", function(): ()
        local l3 = Lync.struct({ v = Lync.int(0, 255) })
        local l2 = Lync.struct({ child = l3, name = Lync.string })
        local l1 = Lync.struct({ mid = l2, id = Lync.int(0, 65535) })
        local r = roundTrip(l1, { mid = { child = { v = 42 }, name = "test" }, id = 1000 })
        expect(r.mid.child.v):toBe(42)
        expect(r.mid.name):toBe("test")
        expect(r.id):toBe(1000)
    end)
    it("20 fields", function(): ()
        local fields: any = {}
        local data: any = {}
        for i = 1, 20 do
            local k = "f" .. string.format("%02d", i)
            fields[k] = Lync.int(0, 255)
            data[k] = i
        end
        local r = roundTrip(Lync.struct(fields), data)
        expect(r.f01):toBe(1)
        expect(r.f10):toBe(10)
        expect(r.f20):toBe(20)
    end)
    it("field with string codec", function(): ()
        local c = Lync.struct({ msg = Lync.string, id = Lync.int(0, 255) })
        local r = roundTrip(c, { msg = "hello world", id = 7 })
        expect(r.msg):toBe("hello world")
        expect(r.id):toBe(7)
    end)
    it("field with optional codec", function(): ()
        local c = Lync.struct({ name = Lync.optional(Lync.string), hp = Lync.int(0, 255) })
        local r1 = roundTrip(c, { name = "Alice", hp = 100 })
        expect(r1.name):toBe("Alice")
        local r2 = roundTrip(c, { name = nil, hp = 50 })
        expect(r2.name):toBeNil()
    end)
end)

describe("struct bool bitpacking", function(): ()
    it("single bool = 1 byte", function(): ()
        local r, w = roundTrip(Lync.struct({ alive = Lync.bool }), { alive = true })
        expect(r.alive):toBe(true)
        expect(w):toBe(1)
    end)
    it("false bool", function(): ()
        expect(roundTrip(Lync.struct({ alive = Lync.bool }), { alive = false }).alive):toBe(false)
    end)
    it("4 bools = 1 byte", function(): ()
        local c = Lync.struct({ a = Lync.bool, b = Lync.bool, c = Lync.bool, d = Lync.bool })
        local r, w = roundTrip(c, { a = true, b = false, c = true, d = false })
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
        expect(r.d):toBe(false)
        expect(w):toBe(1)
    end)
    it("8 bools = 1 byte", function(): ()
        local fields: any = {}
        local data: any = {}
        for i = 1, 8 do
            fields["b" .. i] = Lync.bool
            data["b" .. i] = i % 2 == 0
        end
        local _, w = roundTrip(Lync.struct(fields), data)
        expect(w):toBe(1)
    end)
    it("9 bools = 2 bytes", function(): ()
        local fields: any = {}
        local data: any = {}
        for i = 1, 9 do
            fields["b" .. i] = Lync.bool
            data["b" .. i] = i % 2 == 0
        end
        local _, w = roundTrip(Lync.struct(fields), data)
        expect(w):toBe(2)
    end)
    it("16 bools = 2 bytes with correct values", function(): ()
        local fields: any = {}
        local data: any = {}
        for i = 1, 16 do
            local k = "b" .. string.format("%02d", i)
            fields[k] = Lync.bool
            data[k] = i % 3 == 0
        end
        local r, w = roundTrip(Lync.struct(fields), data)
        expect(w):toBe(2)
        expect(r.b03):toBe(true)
        expect(r.b04):toBe(false)
        expect(r.b06):toBe(true)
    end)
    it("mixed bool + number", function(): ()
        local c = Lync.struct({ alive = Lync.bool, hp = Lync.int(0, 255) })
        local r = roundTrip(c, { alive = false, hp = 50 })
        expect(r.alive):toBe(false)
        expect(r.hp):toBe(50)
    end)
    it("3 bools + 2 numbers", function(): ()
        local c = Lync.struct({
            a = Lync.bool,
            b = Lync.bool,
            c = Lync.bool,
            x = Lync.int(0, 255),
            y = Lync.int(0, 255),
        })
        local r, w = roundTrip(c, { a = true, b = false, c = true, x = 10, y = 20 })
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
        expect(r.x):toBe(10)
        expect(r.y):toBe(20)
        expect(w):toBe(3) -- 2 u8 + 1 bool byte
    end)
    it("all-bool only schema (3 bools)", function(): ()
        local c = Lync.struct({ a = Lync.bool, b = Lync.bool, c = Lync.bool })
        local r, w = roundTrip(c, { a = true, b = false, c = true })
        expect(w):toBe(1)
        expect(r.a):toBe(true)
        expect(r.b):toBe(false)
        expect(r.c):toBe(true)
    end)
end)

describe("struct _size metadata", function(): ()
    it("all-fixed = sum of sizes + bool bytes", function(): ()
        expect((Lync.struct({ a = Lync.int(0, 255), b = Lync.int(0, 65535) }) :: any)._size):toBe(3)
    end)
    it("nil when dynamic", function(): ()
        expect((Lync.struct({ name = Lync.string }) :: any)._size):toBeNil()
    end)
    it("_directWrite exists for all-fixed", function(): ()
        expect((Lync.struct({ a = Lync.int(0, 255) }) :: any)._directWrite):toBeTruthy()
    end)
    it("_directRead exists for all-fixed", function(): ()
        expect((Lync.struct({ a = Lync.int(0, 255) }) :: any)._directRead):toBeTruthy()
    end)
    it("_schema is frozen", function(): ()
        local c = Lync.struct({ x = Lync.int(0, 255) }) :: any
        expect(c._schema):toBeTruthy()
        expect(function(): ()
            c._schema.y = Lync.bool
        end):toThrow()
    end)
end)

describe("struct errors", function(): ()
    it("empty schema", function(): ()
        expect(function(): ()
            Lync.struct({})
        end):toThrow("at least one")
    end)
end)

describe("deltaStruct", function(): ()
    it("first write produces bytes", function(): ()
        local ch = Channel.create()
        Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
            .write(ch, { hp = 100, mp = 50 })
        expect(ch.cursor):toBeGreaterThan(0)
    end)
    it("identical second write = 1 byte (UNCHANGED)", function(): ()
        local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        ch.cursor = 0
        c.write(ch, { hp = 100, mp = 50 })
        expect(ch.cursor):toBe(1)
    end)
    it("third identical write = still 1 byte", function(): ()
        local c = Lync.deltaStruct({ hp = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { hp = 100 })
        ch.cursor = 0
        c.write(ch, { hp = 100 })
        expect(ch.cursor):toBe(1)
        ch.cursor = 0
        c.write(ch, { hp = 100 })
        expect(ch.cursor):toBe(1)
    end)
    it("changed value triggers larger write", function(): ()
        local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { hp = 100, mp = 50 })
        ch.cursor = 0
        c.write(ch, { hp = 80, mp = 50 })
        expect(ch.cursor):toBeGreaterThan(1)
    end)
    it("changed then unchanged = 1 byte again", function(): ()
        local c = Lync.deltaStruct({ hp = Lync.int(0, 255) })
        local ch = Channel.create()
        c.write(ch, { hp = 100 })
        ch.cursor = 0
        c.write(ch, { hp = 80 })
        ch.cursor = 0
        c.write(ch, { hp = 80 })
        expect(ch.cursor):toBe(1)
    end)
    it("full round-trip", function(): ()
        local c = Lync.deltaStruct({ x = Lync.f32, y = Lync.f32, z = Lync.f32 })
        local r = roundTrip(c, { x = 1.5, y = 2.5, z = 3.5 })
        expect(r.x):toBeCloseTo(1.5)
        expect(r.y):toBeCloseTo(2.5)
        expect(r.z):toBeCloseTo(3.5)
    end)
    it("_isDelta = true", function(): ()
        expect((Lync.deltaStruct({ x = Lync.int(0, 255) }) :: any)._isDelta):toBe(true)
    end)
    it("_schema is set", function(): ()
        expect((Lync.deltaStruct({ x = Lync.int(0, 255) }) :: any)._schema):toBeTruthy()
    end)
end)

return nil
