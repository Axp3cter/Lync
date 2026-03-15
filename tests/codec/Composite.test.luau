--!strict
--!optimize 2
-- Composite.test.luau — Round-trip tests for struct, array, map, optional.

local Runner = require(script.Parent.Parent.Runner)
local Lync   = require(script.Parent.Parent.Parent)

local describe  = Runner.describe
local it        = Runner.it
local expect    = Runner.expect
local roundTrip = Runner.roundTrip

-- Tests ------------------------------------------------------------------

describe("Composite.struct", function(): ()
    local codec = Lync.struct({
        health = Lync.u16,
        name   = Lync.string,
        alive  = Lync.bool,
    })

    it("round-trips a flat struct", function(): ()
        local input  = { health = 100, name = "Alice", alive = true }
        local result = roundTrip(codec, input)
        expect(result.health):toBe(100)
        expect(result.name):toBe("Alice")
        expect(result.alive):toBe(true)
    end)
    it("round-trips with zero values", function(): ()
        local input  = { health = 0, name = "", alive = false }
        local result = roundTrip(codec, input)
        expect(result.health):toBe(0)
        expect(result.name):toBe("")
        expect(result.alive):toBe(false)
    end)
end)

describe("Composite.struct nested", function(): ()
    local inner = Lync.struct({ x = Lync.f32, y = Lync.f32 })
    local outer = Lync.struct({ position = inner, label = Lync.string })

    it("round-trips nested struct", function(): ()
        local input  = { position = { x = 1.5, y = 2.5 }, label = "spawn" }
        local result = roundTrip(outer, input)
        expect(result.position.x):toBeCloseTo(1.5)
        expect(result.position.y):toBeCloseTo(2.5)
        expect(result.label):toBe("spawn")
    end)
end)

describe("Composite.array", function(): ()
    local codec = Lync.array(Lync.u16)

    it("round-trips empty array", function(): ()
        local result = roundTrip(codec, {})
        expect(#result):toBe(0)
    end)
    it("round-trips populated array", function(): ()
        local input  = { 10, 20, 30, 40, 50 }
        local result = roundTrip(codec, input)
        expect(#result):toBe(5)
        expect(result[1]):toBe(10)
        expect(result[3]):toBe(30)
        expect(result[5]):toBe(50)
    end)
    it("round-trips single-element array", function(): ()
        local result = roundTrip(codec, { 999 })
        expect(#result):toBe(1)
        expect(result[1]):toBe(999)
    end)
end)

describe("Composite.array of structs", function(): ()
    local codec = Lync.array(Lync.struct({ id = Lync.u32, tag = Lync.string }))

    it("round-trips array of structs", function(): ()
        local input = {
            { id = 1, tag = "a" },
            { id = 2, tag = "b" },
        }
        local result = roundTrip(codec, input)
        expect(#result):toBe(2)
        expect(result[1].id):toBe(1)
        expect(result[1].tag):toBe("a")
        expect(result[2].id):toBe(2)
        expect(result[2].tag):toBe("b")
    end)
end)

describe("Composite.map", function(): ()
    local codec = Lync.map(Lync.string, Lync.u32)

    it("round-trips empty map", function(): ()
        local result = roundTrip(codec, {})
        local count  = 0
        for _ in result do count += 1 end
        expect(count):toBe(0)
    end)
    it("round-trips populated map", function(): ()
        local input  = { gold = 100, silver = 50 }
        local result = roundTrip(codec, input)
        expect(result.gold):toBe(100)
        expect(result.silver):toBe(50)
    end)
end)

describe("Composite.optional", function(): ()
    local codec = Lync.optional(Lync.u32)

    it("round-trips nil as nil", function(): ()
        local result = roundTrip(codec, nil)
        expect(result):toBeNil()
    end)
    it("round-trips present value", function(): ()
        expect(roundTrip(codec, 42)):toBe(42)
    end)
    it("nil uses exactly 1 byte", function(): ()
        local _, written, _ = roundTrip(codec, nil)
        expect(written):toBe(1)
    end)
    it("present uses 1 + inner bytes", function(): ()
        local _, written, _ = roundTrip(codec, 42)
        expect(written):toBe(5)
    end)
end)

describe("Composite.struct validation", function(): ()
    it("throws on empty schema", function(): ()
        expect(function(): ()
            Lync.struct({})
        end):toThrow("at least one field")
    end)
end)

return nil
