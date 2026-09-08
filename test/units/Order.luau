--!strict
--!optimize 2
-- The canonical ordering alone: what order names go in, and which declarations vary in size.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Order = require("@src/shape/Order")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local SMALL = 15
local NAMES = table.freeze({ "one", "two" })

local function cell(of: any): Base.Cell
    return Base.cell(of)
end

local function keyed(names: { string }): { [string]: boolean }
    local out = {}
    for _, name in names do
        out[name] = true
    end
    return out
end

local function joined(names: { string }): string
    return table.concat(names, " ")
end

return {
    -- Ascending by the bytes: upper case leads lower, and marks sort where their bytes are.
    Harness.case("order.ascending", function()
        Expect.equal(joined(Order.names(keyed({ "beta", "alpha", "gamma" }))), "alpha beta gamma")
        Expect.equal(joined(Order.names(keyed({ "b", "A", "a", "B" }))), "A B a b")
        Expect.equal(joined(Order.names(keyed({ "a_b", "a-b", "a1b", "ab" }))), "a-b a1b a_b ab")
    end),

    -- A prefix comes before what extends it.
    Harness.case("order.prefixes", function()
        Expect.equal(
            joined(Order.names(keyed({ "hpMax", "hp", "hpRegen", "h" }))),
            "h hp hpMax hpRegen"
        )
    end),

    -- Two tables holding the same names answer the same list however each was filled.
    Harness.case("order.independent", function()
        local first: { [string]: number } = {}
        first.zulu, first.alpha, first.mike = 1, 2, 3
        local second: { [string]: number } = {}
        second.mike, second.zulu, second.alpha = 3, 1, 2
        Expect.equal(joined(Order.names(first)), "alpha mike zulu")
        Expect.equal(joined(Order.names(second)), "alpha mike zulu")
    end),

    Harness.case("order.ends", function()
        Expect.equal(#Order.names({}), 0)
        Expect.equal(Order.names(keyed({ "only" })), { "only" })
    end),

    Harness.case("order.any-value", function()
        local codecs = { beta = Codecs.bool(), alpha = Codecs.int(0, SMALL) }
        Expect.equal(joined(Order.names(codecs)), "alpha beta")
        local mixed: { [string]: any } = { two = 2, one = "one", three = false }
        Expect.equal(joined(Order.names(mixed)), "one three two")
    end),

    -- A varint, a tagged, an optional and a reference have no fixed width to fall back to.
    Harness.case("order.varies-always", function()
        local always = {
            Codecs.vlq(),
            Codecs.vli(),
            Codecs.optional(Codecs.bool()),
            Codecs.inst("Part"),
            Codecs.tagged("kind", {
                [NAMES[1]] = Codecs.struct({ a = Codecs.bool() }),
                [NAMES[2]] = Codecs.struct({ b = Codecs.bool() }),
            }),
        }
        for _, of in always do
            Expect.equal(Order.varies(cell(of)), true)
        end
    end),

    -- Each counted kind asked with its bounds meeting and apart, so the count is what decided.
    Harness.case("order.varies-counted", function()
        local held = {
            { fixed = Codecs.str(4, 4), loose = Codecs.str(0, 4) },
            { fixed = Codecs.buffer(8, 8), loose = Codecs.buffer(1, 8) },
            {
                fixed = Codecs.array(Codecs.bool(), 3, 3),
                loose = Codecs.array(Codecs.bool(), 0, 3),
            },
            {
                fixed = Codecs.map(Codecs.enum(NAMES), Codecs.bool(), 2, 2),
                loose = Codecs.map(Codecs.enum(NAMES), Codecs.bool(), 0, 2),
            },
        }
        for _, pair in held do
            Expect.equal(Order.varies(cell(pair.fixed)), false)
            Expect.equal(Order.varies(cell(pair.loose)), true)
        end
    end),

    Harness.case("order.varies-never", function()
        local fixed = {
            Codecs.bool(),
            Codecs.int(0, SMALL),
            Codecs.f32(),
            Codecs.enum(NAMES),
            Codecs.bitfield(NAMES),
            Codecs.struct({ a = Codecs.bool(), b = Codecs.int(0, SMALL) }),
            Codecs.vec3(Codecs.f32()),
            Codecs.color3(),
        }
        for _, of in fixed do
            Expect.equal(Order.varies(cell(of)), false)
        end
    end),

    Harness.case("order.varies-through-children", function()
        local loose = Codecs.str(0, SMALL)
        Expect.equal(Order.varies(cell(Codecs.struct({ a = Codecs.bool(), b = loose }))), true)
        Expect.equal(Order.varies(cell(Codecs.array(loose, 2, 2))), true)
        Expect.equal(Order.varies(cell(Codecs.map(Codecs.enum(NAMES), loose, 1, 1))), true)
        Expect.equal(Order.varies(cell(Codecs.vec2(Codecs.vlq()))), true)
    end),

    -- Three deep, since two would be answered by a walk that looked at its children and not theirs.
    Harness.case("order.varies-nested", function()
        local deep = Codecs.struct({
            here = Codecs.int(0, SMALL),
            under = Codecs.struct({
                also = Codecs.bool(),
                below = Codecs.struct({ far = Codecs.optional(Codecs.bool()) }),
            }),
        })
        Expect.equal(Order.varies(cell(deep)), true)

        local same = Codecs.struct({
            here = Codecs.int(0, SMALL),
            under = Codecs.struct({
                also = Codecs.bool(),
                below = Codecs.struct({ far = Codecs.int(0, SMALL) }),
            }),
        })
        Expect.equal(Order.varies(cell(same)), false)
    end),

    -- A modifier writes no byte, so it changes nothing about whether a field varies.
    Harness.case("order.varies-under-modifiers", function()
        local plain = Codecs.int(0, SMALL)
        local loose = Codecs.str(0, SMALL)
        local lifted = plain:as(function(value: number): number
            return value
        end, function(value: number): number
            return value
        end)
        Expect.equal(Order.varies(cell(lifted)), false)
        Expect.equal(
            Order.varies(cell(plain:validate(function()
                return nil
            end))),
            false
        )
        Expect.equal(
            Order.varies(cell(loose:validate(function()
                return nil
            end))),
            true
        )
    end),
}
