--!strict
--!optimize 2
--[[
    The canonical ordering alone: what order names go in, and which declarations vary in size.
]]

local Base = require ("@src/codec/Base")
local Lync = require ("@src")
local Order = require ("@src/shape/Order")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- A bound small enough that nothing here is ever about the number, only about the kind.
const SMALL = 15
const NAMES = table.freeze ({ "one", "two" })

-- Private -------------------------------------------------------------

-- A declaration as the cell the ordering reads, which is one call and never a compile.
local function cell (of: any): Base.Cell return Base.cell (of) end

-- A table of the named keys, so a case says which names it means and nothing about their values.
local function keyed (names: { string }): { [string]: boolean }
    local out = {}
    for _, name in names do
        out[name] = true
    end
    return out
end

-- Public --------------------------------------------------------------

return {
    --[[
        Ascending, and ascending by the bytes rather than by anything a reader would call
        alphabetical. The language's own comparison of two strings is a byte at a time, so the sort
        is the rule and there is no comparison written anywhere for the two ends to disagree about.
    ]]
    Harness.case ("order.ascending", function ()
        local held = Order.names (keyed ({ "beta", "alpha", "gamma" }))
        Expect.equal (table.concat (held, " "), "alpha beta gamma")

        -- Upper case is below lower in UTF-8, so it leads, which locale ordering does not promise.
        local mixed = Order.names (keyed ({ "b", "A", "a", "B" }))
        Expect.equal (table.concat (mixed, " "), "A B a b")

        -- And the marks a name may carry sort where their bytes are and nowhere else.
        local marked = Order.names (keyed ({ "a_b", "a-b", "a1b", "ab" }))
        Expect.equal (table.concat (marked, " "), "a-b a1b a_b ab")
    end),

    --[[
        A prefix comes before what extends it, which is the one comparison a byte walk decides by
        running out. A field named `hp` and one named `hpMax` are a pair a caller writes without
        thinking about it, and the two ends have to put them in the same order.
    ]]
    Harness.case ("order.prefixes", function ()
        local held = Order.names (keyed ({ "hpMax", "hp", "hpRegen", "h" }))
        Expect.equal (table.concat (held, " "), "h hp hpMax hpRegen")
    end),

    --[[
        The order the caller wrote is nothing to do with it. A table of fields has no order of its
        own to begin with, so what is asked here is that two tables holding the same names answer
        the same list however each was filled.
    ]]
    Harness.case ("order.independent", function ()
        local first: { [string]: number } = {}
        first.zulu, first.alpha, first.mike = 1, 2, 3

        local second: { [string]: number } = {}
        second.mike, second.zulu, second.alpha = 3, 1, 2

        Expect.equal (table.concat (Order.names (first), " "), "alpha mike zulu")
        Expect.equal (table.concat (Order.names (second), " "), "alpha mike zulu")
    end),

    --[[
        The two ends of a table. None is an empty list rather than a raise, because a record with no
        fields is a legal declaration and so is a namespace nobody has added to yet, and one name is
        the list holding it.
    ]]
    Harness.case ("order.ends", function ()
        Expect.equal (#Order.names ({}), 0)

        local one = Order.names (keyed ({ "only" }))
        Expect.equal (#one, 1)
        Expect.equal (one[1], "only")
    end),

    --[[
        What the table holds is nothing to do with it, which is why it is a parameter. A record's
        fields, a tagged field's variants and a namespace's definitions are three tables of three
        different things under one rule, and a walk typed to one of them would be a second place the
        order is decided.
    ]]
    Harness.case ("order.any-value", function ()
        local codecs = { beta = Lync.bool (), alpha = Lync.int (0, SMALL) }
        Expect.equal (table.concat (Order.names (codecs), " "), "alpha beta")

        local mixed: { [string]: any } = { two = 2, one = "one", three = false }
        Expect.equal (table.concat (Order.names (mixed), " "), "one three two")
    end),

    --[[
        The kinds that vary whatever they are made of. A varint is variable by construction, a
        tagged field writes the layout its tag chose, an optional writes nothing when it is absent,
        and a reference writes a slot as a varint. None of them has a fixed width to fall back to.
    ]]
    Harness.case ("order.varies-always", function ()
        local always = {
            Lync.vlq (),
            Lync.vli (),
            Lync.optional (Lync.bool ()),
            Lync.inst ("Part"),
            Lync.tagged ("kind", {
                [NAMES[1]] = Lync.struct ({ a = Lync.bool () }),
                [NAMES[2]] = Lync.struct ({ b = Lync.bool () }),
            }),
        }

        for _, of in always do
            Expect.equal (Order.varies (cell (of)), true)
        end
    end),

    --[[
        The four counted kinds, each asked twice: once with its bounds meeting and once with them
        apart. Twice because either reading alone is satisfied by an answer that never looks at the
        bounds, and the pair is what says the count is what decided it.
    ]]
    Harness.case ("order.varies-counted", function ()
        local held = {
            { fixed = Lync.str (4, 4), loose = Lync.str (0, 4) },
            { fixed = Lync.buffer (8, 8), loose = Lync.buffer (1, 8) },
            { fixed = Lync.array (Lync.bool (), 3, 3), loose = Lync.array (Lync.bool (), 0, 3) },
            {
                fixed = Lync.map (Lync.enum (NAMES), Lync.bool (), 2, 2),
                loose = Lync.map (Lync.enum (NAMES), Lync.bool (), 0, 2),
            },
        }

        for _, pair in held do
            Expect.equal (Order.varies (cell (pair.fixed)), false)
            Expect.equal (Order.varies (cell (pair.loose)), true)
        end
    end),

    --[[
        Kinds a fixed width can be written in, which is what a layout is planned from. One of them
        reading as variable would be written where a size has to be stated instead.
    ]]
    Harness.case ("order.varies-never", function ()
        local fixed = {
            Lync.bool (),
            Lync.int (0, SMALL),
            Lync.f32 (),
            Lync.enum (NAMES),
            Lync.bitfield (NAMES),
            Lync.struct ({ a = Lync.bool (), b = Lync.int (0, SMALL) }),
            Lync.vec3 (Lync.f32 ()),
            Lync.color3 (),
        }

        for _, of in fixed do
            Expect.equal (Order.varies (cell (of)), false)
        end
    end),

    --[[
        A composite varies when what it holds does. The children are walked rather than named,
        because every kind that has any varies exactly when one of them does, and naming each would
        be a place per kind to keep in step with a constructor that already records what it holds.
    ]]
    Harness.case ("order.varies-through-children", function ()
        local loose = Lync.str (0, SMALL)

        Expect.equal (Order.varies (cell (Lync.struct ({ a = Lync.bool (), b = loose }))), true)
        Expect.equal (Order.varies (cell (Lync.array (loose, 2, 2))), true)
        Expect.equal (Order.varies (cell (Lync.map (Lync.enum (NAMES), loose, 1, 1))), true)
        Expect.equal (Order.varies (cell (Lync.vec2 (Lync.vlq ()))), true)
    end),

    --[[
        A varying field buried under fixed ones, which is the case a walk that stopped at the first
        level would answer wrongly. Three deep, because two would be answered by a walk that looked
        at its children and not at theirs.
    ]]
    Harness.case ("order.varies-nested", function ()
        local deep = Lync.struct ({
            here = Lync.int (0, SMALL),
            under = Lync.struct ({
                also = Lync.bool (),
                below = Lync.struct ({ far = Lync.optional (Lync.bool ()) }),
            }),
        })
        Expect.equal (Order.varies (cell (deep)), true)

        local same = Lync.struct ({
            here = Lync.int (0, SMALL),
            under = Lync.struct ({
                also = Lync.bool (),
                below = Lync.struct ({ far = Lync.int (0, SMALL) }),
            }),
        })
        Expect.equal (Order.varies (cell (same)), false)
    end),

    --[[
        A modifier changes nothing about whether a field varies. An `as` is a pair of functions over
        the value and a `validate` is a person turning one away, and neither writes a byte, so a
        declaration wearing either is written in the region the one under it belongs to.
    ]]
    Harness.case ("order.varies-under-modifiers", function ()
        local plain = Lync.int (0, SMALL)
        local loose = Lync.str (0, SMALL)

        local lifted = plain:as (
            function (value: number): number return value end,
            function (value: number): number return value end
        )
        Expect.equal (Order.varies (cell (lifted)), false)

        Expect.equal (Order.varies (cell (plain:validate (function () return nil end))), false)
        Expect.equal (Order.varies (cell (loose:validate (function () return nil end))), true)
    end),
}
