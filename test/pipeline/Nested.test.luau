--!strict
--!optimize 2
local Lync = require(script.Parent.Parent.Parent)
local Runner = require(script.Parent.Parent.Runner)
local describe, it, expect, roundTrip = Runner.describe, Runner.it, Runner.expect, Runner.roundTrip

describe("nested: struct in array", function(): ()
    it("round-trips", function(): ()
        local c = Lync.array(Lync.struct({ x = Lync.f32, y = Lync.f32 }))
        local r = roundTrip(c, { { x = 1, y = 2 }, { x = 3, y = 4 } })
        expect(#r):toBe(2)
        expect(r[1].x):toBeCloseTo(1)
        expect(r[2].y):toBeCloseTo(4)
    end)
end)

describe("nested: array in struct", function(): ()
    it("round-trips", function(): ()
        local c = Lync.struct({ ids = Lync.array(Lync.u8), name = Lync.string })
        local r = roundTrip(c, { ids = { 1, 2, 3 }, name = "test" })
        expect(#r.ids):toBe(3)
        expect(r.ids[2]):toBe(2)
        expect(r.name):toBe("test")
    end)
end)

describe("nested: map in struct", function(): ()
    it("round-trips", function(): ()
        local c = Lync.struct({ scores = Lync.map(Lync.string, Lync.u16), label = Lync.string })
        local r = roundTrip(c, { scores = { alice = 100, bob = 200 }, label = "round1" })
        expect(r.scores.alice):toBe(100)
        expect(r.scores.bob):toBe(200)
        expect(r.label):toBe("round1")
    end)
end)

describe("nested: optional struct", function(): ()
    it("present", function(): ()
        local c = Lync.optional(Lync.struct({ hp = Lync.u8 }))
        local r = roundTrip(c, { hp = 42 })
        expect(r.hp):toBe(42)
    end)
    it("nil", function(): ()
        local c = Lync.optional(Lync.struct({ hp = Lync.u8 }))
        expect(roundTrip(c, nil)):toBeNil()
    end)
end)

describe("nested: tuple of mixed codecs", function(): ()
    it("round-trips", function(): ()
        local c = Lync.tuple(Lync.u8, Lync.string, Lync.vec3, Lync.optional(Lync.bool))
        local r = roundTrip(c, { 42, "test", Vector3.new(1, 2, 3), true })
        expect(r[1]):toBe(42)
        expect(r[2]):toBe("test")
        expect(r[3].X):toBeCloseTo(1)
        expect(r[4]):toBe(true)
    end)
end)

describe("nested: tagged with arrays", function(): ()
    it("round-trips", function(): ()
        local c = Lync.tagged("type", {
            List = Lync.struct({ items = Lync.array(Lync.u8) }),
            Single = Lync.struct({ value = Lync.u8 }),
        })
        local r = roundTrip(c, { type = "List", items = { 1, 2, 3 } })
        expect(r.type):toBe("List")
        expect(#r.items):toBe(3)
    end)
end)

describe("nested: 4 levels deep", function(): ()
    it("round-trips", function(): ()
        local l4 = Lync.struct({ val = Lync.u8 })
        local l3 = Lync.struct({ inner = l4, tag = Lync.string })
        local l2 = Lync.array(l3)
        local l1 = Lync.struct({ items = l2, count = Lync.u16 })
        local data = {
            items = {
                { inner = { val = 10 }, tag = "a" },
                { inner = { val = 20 }, tag = "b" },
            },
            count = 2,
        }
        local r = roundTrip(l1, data)
        expect(r.count):toBe(2)
        expect(#r.items):toBe(2)
        expect(r.items[1].inner.val):toBe(10)
        expect(r.items[2].tag):toBe("b")
    end)
end)

return nil
