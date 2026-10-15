--!strict
--!optimize 2
-- A transform or a check wherever it sits: under a record, in a run, behind a bit, in a map.

local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Shape = require("@src/shape")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local AT = "at"
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })

-- The value a check turns away above.
local CEILING = 5
local SAID = "no"

-- Text back to the number it spells, which every transform here round trips through.
local function fromText(text: string): number
    return tonumber(text) :: number
end

local function built(of: any): any
    return Shape.build(of, AT)
end

-- One value out and back, in a buffer of exactly the bound, the read ending where the write did.
local function through(of: any, value: any): any
    local b = buffer.create(of.maxBytes)
    local ends = of.write(b, 0, value)
    local at, back = of.read(b, 0, CTX)
    Expect.equal(at, ends)
    return back
end

-- The code a read turned a value away under, or nothing where it came back.
local function dropped(of: any, value: any): Catalog.Code?
    local b = buffer.create(of.maxBytes)
    of.write(b, 0, value)
    local ok, why = pcall(of.read, b, 0, CTX)
    return if ok then nil else (why :: any).code
end

local function refused(of: any, value: any): boolean
    local b = buffer.create(of.maxBytes)
    return not pcall(of.write, b, 0, value)
end

local function above(value: any): string?
    return if value > CEILING then SAID else nil
end

local function boxed(s: any): any
    return { s = s }
end

local function unboxed(t: any): any
    return t.s
end

local function count(n: number): number
    return n
end

return {
    -- A counted field whose count rides in the record's word is counted after it is lowered, since
    -- the lowered value is what the payload writes. The count still rides in the word.
    Harness.case("lifts.hoisted", function()
        local plain = built(Codecs.struct({
            name = Codecs.str(0, 10),
            list = Codecs.array(Codecs.int(0, 3), 0, 6),
            tail = Codecs.int(0, 255),
        }))
        local of = built(Codecs.struct({
            name = Codecs.str(0, 10):as(boxed, unboxed),
            list = Codecs.array(Codecs.int(0, 3), 0, 6):as(boxed, unboxed),
            tail = Codecs.int(0, 255),
        }))
        local value = { name = { s = "hello" }, list = { s = { 1, 2, 3 } }, tail = 7 }
        Expect.equal(through(of, value), value)
        Expect.equal(of.maxBytes, plain.maxBytes)
    end),

    -- A fixed record under another still dissolves, its transform undone before its fields are
    -- reached and its checks run on what it lifts to, at any depth.
    Harness.case("lifts.nested-record", function()
        local inner = Codecs.struct({ x = Codecs.int(0, 10):validate(above) })
        local lifted = inner:as(function(t: any)
            return t.x
        end, function(n: any)
            return { x = n }
        end)
        local plain = built(Codecs.struct({ a = inner, b = Codecs.bool() }))
        local of = built(Codecs.struct({ a = lifted, b = Codecs.bool() }))
        Expect.equal(through(of, { a = 4, b = true }), { a = 4, b = true })
        Expect.equal(of.maxBytes, plain.maxBytes)
        Expect.equal(dropped(of, { a = 9, b = true }), Catalog.VALIDATE)

        local deep = built(Codecs.struct({
            outer = Codecs.struct({ a = lifted, c = Codecs.int(0, 3) }):as(boxed, unboxed),
            b = Codecs.bool(),
        }))
        local value = { outer = { s = { a = 2, c = 3 } }, b = false }
        Expect.equal(through(deep, value), value)

        local checked = built(Codecs.struct({
            a = Codecs.struct({ x = Codecs.int(0, 10) }):validate(function(t: any): string?
                return above(t.x)
            end),
            b = Codecs.bool(),
        }))
        Expect.equal(through(checked, { a = { x = 3 }, b = false }), { a = { x = 3 }, b = false })
        Expect.equal(dropped(checked, { a = { x = 9 }, b = false }), Catalog.VALIDATE)
        Expect.equal(checked.maxBytes, plain.maxBytes)
    end),

    -- A field the bit region holds keeps its transform and its place, whatever leaves it takes.
    Harness.case("lifts.region-field", function()
        local bits = Codecs.bitfield({ "p", "q" })
        local plain = built(Codecs.struct({ a = Codecs.int(0, 10), b = Codecs.bool(), c = bits }))
        local of = built(Codecs.struct({
            a = Codecs.int(0, 10):as(tostring, fromText),
            b = Codecs.bool(),
            c = bits:as(function(t: any)
                return t.p
            end, function(p: any): { [string]: boolean }
                return { p = p, q = false }
            end),
        }))
        local value = { a = "3", b = true, c = true }
        Expect.equal(through(of, value), value)
        Expect.equal(of.maxBytes, plain.maxBytes)

        local checked = built(Codecs.struct({
            a = Codecs.int(0, 10):as(tostring, fromText):validate(function(s: any): string?
                return above(tonumber(s))
            end),
            b = Codecs.bool(),
        }))
        Expect.equal(dropped(checked, { a = "9", b = true }), Catalog.VALIDATE)
    end),

    -- A transformed element packs on its grid, and a checked one is a list of its own nodes.
    Harness.case("lifts.element", function()
        local lifted = built(Codecs.array(Codecs.int(0, 10):as(tostring, fromText), 0, 4))
        Expect.equal(through(lifted, { "3", "7" }), { "3", "7" })
        Expect.equal(lifted.maxBytes, built(Codecs.array(Codecs.int(0, 10), 0, 4)).maxBytes)

        local checked = built(Codecs.array(Codecs.int(0, 10):validate(above), 0, 4))
        Expect.equal(through(checked, { 1, 5 }), { 1, 5 })
        Expect.equal(dropped(checked, { 9 }), Catalog.VALIDATE)

        local tenths = Codecs.int(0, 10):as(function(n: any)
            return n / 10
        end, function(f: any)
            return math.round(f * 10)
        end)
        local turned = built(Codecs.vec3(tenths))
        Expect.equal(through(turned, Vector3.new(0.1, 0.2, 0.3)), Vector3.new(0.1, 0.2, 0.3))
        Expect.equal(turned.maxBytes, built(Codecs.vec3(Codecs.int(0, 10))).maxBytes)

        local component = built(Codecs.vec3(Codecs.int(0, 10):validate(above)))
        Expect.equal(through(component, Vector3.new(1, 2, 3)), Vector3.new(1, 2, 3))
        Expect.equal(dropped(component, Vector3.new(1, 9, 3)), Catalog.VALIDATE)
    end),

    -- The grid a build answers carries the transform, since a column of indices never reaches
    -- the node that would apply it.
    Harness.case("lifts.grid", function()
        local grid = built(Codecs.int(0, 255):as(tostring, fromText)).grid
        Expect.equal(grid.toIndex("128"), 128)
        Expect.equal(grid.fromIndex(128), "128")
        Expect.equal(grid.plain, false)
    end),

    -- An optional field's own transform runs on the value behind its bit, and an absent one is
    -- never handed to it.
    Harness.case("lifts.optional", function()
        local of = built(Codecs.struct({
            o = Codecs.optional(Codecs.int(0, 10)):as(tostring, fromText),
            b = Codecs.bool(),
        }))
        Expect.equal(through(of, { o = "4", b = true }), { o = "4", b = true })
        Expect.equal(through(of, { b = false }), { b = false })
        local plain = Codecs.struct({ o = Codecs.optional(Codecs.int(0, 10)), b = Codecs.bool() })
        Expect.equal(of.maxBytes, built(plain).maxBytes)
    end),

    -- Both halves of a map keep their checks and transforms where either would have packed.
    Harness.case("lifts.map", function()
        local values = built(Codecs.map(Codecs.str(1, 4), Codecs.int(0, 10):validate(above), 0, 4))
        Expect.equal(through(values, { a = 1 }), { a = 1 })
        Expect.equal(dropped(values, { a = 9 }), Catalog.VALIDATE)

        local keys = built(Codecs.map(Codecs.int(0, 10):validate(above), Codecs.bool(), 0, 4))
        Expect.equal(through(keys, { [1] = true }), { [1] = true })
        Expect.equal(dropped(keys, { [9] = true }), Catalog.VALIDATE)

        local both = built(Codecs.map(Codecs.int(0, 10):validate(above), Codecs.int(0, 3), 0, 4))
        Expect.equal(dropped(both, { [9] = 1 }), Catalog.VALIDATE)

        local lifted = built(
            Codecs.map(
                Codecs.int(0, 10):as(tostring, fromText),
                Codecs.int(0, 10):as(tostring, fromText),
                0,
                4
            )
        )
        Expect.equal(through(lifted, { ["2"] = "3", ["4"] = "5" }), { ["2"] = "3", ["4"] = "5" })
    end),

    -- A key the receiver may not see would come back as nothing, which no table holds.
    Harness.case("lifts.inst-key", function()
        Expect.throws(function()
            Codecs.map(Codecs.inst(), Codecs.bool(), 0, 4)
        end, "map takes no inst for key")
        Expect.throws(function()
            Codecs.map((Codecs.inst("Part") :: any):as(count, count), Codecs.bool(), 0, 4)
        end, "map takes no inst for key")
        Codecs.map(Codecs.bool(), Codecs.inst(), 0, 4)
    end),

    -- An int is whole: a fraction is refused as an out of range value is, wherever it is written.
    Harness.case("lifts.int-whole", function()
        local from = built(Codecs.int(0, 10))
        local signed = built(Codecs.int(-5, 5))
        local wide = built(Codecs.int(0, 2 ^ 40))
        local run = built(Codecs.array(Codecs.int(0, 10), 0, 4))
        local spread = built(Codecs.vec3(Codecs.int(0, 10)))
        Expect.equal(through(from, 3), 3)
        Expect.equal(through(signed, -3), -3)
        Expect.equal(through(wide, 2 ^ 39), 2 ^ 39)
        Expect.equal(through(run, { 0, 10 }), { 0, 10 })
        Expect.equal(refused(from, 2.5), true)
        Expect.equal(refused(from, 10.0000001), true)
        Expect.equal(refused(signed, -1.5), true)
        Expect.equal(refused(wide, 1.5), true)
        Expect.equal(refused(run, { 1, 1.5 }), true)
        Expect.equal(refused(spread, Vector3.new(1, 2.5, 3)), true)
        Expect.equal(refused(from, 0 / 0), true)

        -- A quant on the same grid is a measurement, and rounds.
        Expect.equal(through(built(Codecs.quant(0, 10, 1)), 2.4), 2)
    end),

    -- Plain codecs keep the layouts they had.
    Harness.case("lifts.plain-layout", function()
        local record = built(Codecs.struct({
            a = Codecs.int(0, 10),
            c = Codecs.struct({ x = Codecs.int(0, 3), y = Codecs.bool() }),
            d = Codecs.str(0, 10),
        }))
        Expect.equal(record.maxBytes, 12)
        Expect.equal(built(Codecs.array(Codecs.int(0, 10), 0, 4)).maxBytes, 3)
        Expect.equal(built(Codecs.map(Codecs.int(0, 10), Codecs.int(0, 10), 0, 4)).maxBytes, 5)
        Expect.equal(built(Codecs.vec3(Codecs.int(0, 100))).maxBytes, 3)
    end),
}
