--!strict
--!optimize 2
-- Lync.struct and Lync.deltaStruct: alphabetized field codec with bool tail.

local Env = require(script:FindFirstAncestor("test").Env)

local Lync = Env.Lync
local Channel = Env.Channel
local Sandbox = Env.Sandbox

local describe = Env.describe
local it = Env.it
local expect = Env.expect
local beforeEach = Env.beforeEach

describe("codec.composite.Struct", function(): ()
    beforeEach(Sandbox.resetAll)

    describe("basic round-trip", function(): ()
        it("single u8 field", function(): ()
            local c = Lync.struct({ hp = Lync.int(0, 255) })
            local r = Channel.roundTripStrict(c, { hp = 100 })
            expect(r.hp):toBe(100)
        end)
        it("two fields with different sizes", function(): ()
            local c = Lync.struct({ a = Lync.int(0, 255), b = Lync.int(0, 65535) })
            local r = Channel.roundTripStrict(c, { a = 42, b = 1000 })
            expect(r.a):toBe(42)
            expect(r.b):toBe(1000)
        end)
        it("mixed scalar and string", function(): ()
            local c = Lync.struct({ x = Lync.f32, y = Lync.f32, name = Lync.string })
            local r = Channel.roundTripStrict(c, { x = 1.5, y = 2.5, name = "test" })
            expect(r.x):toBeCloseTo(1.5)
            expect(r.y):toBeCloseTo(2.5)
            expect(r.name):toBe("test")
        end)
        it("nested struct one level", function(): ()
            local inner = Lync.struct({ a = Lync.int(0, 255) })
            local outer = Lync.struct({ child = inner, val = Lync.int(0, 65535) })
            local r = Channel.roundTripStrict(outer, { child = { a = 42 }, val = 1000 })
            expect(r.child.a):toBe(42)
            expect(r.val):toBe(1000)
        end)
        it("3 levels deep", function(): ()
            local l3 = Lync.struct({ v = Lync.int(0, 255) })
            local l2 = Lync.struct({ child = l3, name = Lync.string })
            local l1 = Lync.struct({ mid = l2, id = Lync.int(0, 65535) })
            local r = Channel.roundTripStrict(l1, {
                mid = { child = { v = 42 }, name = "test" },
                id = 1000,
            })
            expect(r.mid.child.v):toBe(42)
            expect(r.mid.name):toBe("test")
            expect(r.id):toBe(1000)
        end)
        it("optional field present and absent", function(): ()
            local c = Lync.struct({ name = Lync.optional(Lync.string), hp = Lync.int(0, 255) })
            local r1 = Channel.roundTripStrict(c, { name = "Alice", hp = 100 })
            expect(r1.name):toBe("Alice")
            local r2 = Channel.roundTripStrict(c, { name = nil, hp = 50 })
            expect(r2.name):toBeNil()
        end)
    end)

    describe("bool bit-packing inside struct", function(): ()
        it("single bool = 1 byte", function(): ()
            local r = Channel.encode(Lync.struct({ alive = Lync.bool }), { alive = true })
            expect(r.length):toBe(1)
        end)
        it("8 bools = 1 byte", function(): ()
            local schema, data = {} :: any, {} :: any
            for i = 1, 8 do
                schema[`b{i}`] = Lync.bool
                data[`b{i}`] = i % 2 == 0
            end
            local r = Channel.encode(Lync.struct(schema), data)
            expect(r.length):toBe(1)
        end)
        it("9 bools = 2 bytes", function(): ()
            local schema, data = {} :: any, {} :: any
            for i = 1, 9 do
                schema[`b{i}`] = Lync.bool
                data[`b{i}`] = i % 3 == 0
            end
            local r = Channel.encode(Lync.struct(schema), data)
            expect(r.length):toBe(2)
        end)
        it("3 bools + 2 u8 = 3 bytes (data first, bool tail)", function(): ()
            local r = Channel.encode(
                Lync.struct({
                    a = Lync.bool,
                    b = Lync.bool,
                    c = Lync.bool,
                    x = Lync.int(0, 255),
                    y = Lync.int(0, 255),
                }),
                { a = true, b = false, c = true, x = 10, y = 20 }
            )
            expect(r.length):toBe(3)
        end)
    end)

    describe("metadata", function(): ()
        it("_size set when all fields are direct-write", function(): ()
            local c = Lync.struct({ a = Lync.int(0, 255), b = Lync.int(0, 65535) })
            expect((c :: any)._size):toBe(3)
        end)
        it("_size nil when a field is variable size", function(): ()
            local c = Lync.struct({ name = Lync.string })
            expect((c :: any)._size):toBeNil()
        end)
        it("_directWrite present for all-direct schemas", function(): ()
            local c = Lync.struct({ a = Lync.int(0, 255) })
            expect((c :: any)._directWrite):toBeType("function")
        end)
        it("_schema is a frozen table", function(): ()
            local c = Lync.struct({ x = Lync.int(0, 255) })
            expect((c :: any)._schema):toBeFrozen()
        end)
    end)

    describe("define-time errors", function(): ()
        it("empty schema throws", function(): ()
            expect(function(): ()
                Lync.struct({})
            end):toThrow("at least one")
        end)
    end)

    describe("deltaStruct wire", function(): ()
        it("flags _isDelta", function(): ()
            local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
            expect((c :: any)._isDelta):toBe(true)
        end)
        it("first write produces a real payload", function(): ()
            local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { x = 1 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("identical second write collapses to 1 byte", function(): ()
            local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { hp = 100, mp = 50 })
            ch.cursor = 0
            c.write(ch, { hp = 100, mp = 50 })
            expect(ch.cursor):toBe(1)
        end)
        it("third identical write still 1 byte", function(): ()
            local c = Lync.deltaStruct({ hp = Lync.int(0, 255) })
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 100 })
            ch.cursor = 0
            c.write(ch, { hp = 100 })
            expect(ch.cursor):toBe(1)
        end)
        it("changed value triggers larger write", function(): ()
            local c = Lync.deltaStruct({ hp = Lync.int(0, 255), mp = Lync.int(0, 255) })
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { hp = 100, mp = 50 })
            ch.cursor = 0
            c.write(ch, { hp = 80, mp = 50 })
            expect(ch.cursor):toBeGreaterThan(1)
        end)
        it("change then unchanged returns to 1 byte", function(): ()
            local c = Lync.deltaStruct({ x = Lync.int(0, 255) })
            local InternalChannel = Env.Internal.Channel
            local ch = InternalChannel.create()
            c.write(ch, { x = 1 })
            ch.cursor = 0
            c.write(ch, { x = 2 })
            ch.cursor = 0
            c.write(ch, { x = 2 })
            expect(ch.cursor):toBe(1)
        end)
        it("full round-trip preserves values", function(): ()
            local c = Lync.deltaStruct({ x = Lync.f32, y = Lync.f32, z = Lync.f32 })
            local r = Channel.roundTripStrict(c, { x = 1.5, y = 2.5, z = 3.5 })
            expect(r.x):toBeCloseTo(1.5)
            expect(r.y):toBeCloseTo(2.5)
            expect(r.z):toBeCloseTo(3.5)
        end)
    end)
end)

return nil
