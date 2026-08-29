--!strict
--!optimize 2
--[[
    A declaration as the field it becomes: the grids it indexes through, and the pair over them.
]]

local Base = require ("@src/codec/Base")
local Ir = require ("@src/shape/Ir")
local Joins = require ("@src/shape/Joins")
local Lync = require ("@src")
local Scalars = require ("@src/codec/Scalars")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- The names a bitfield is declared over, and the one no declaration here carries.
const FLAGS = table.freeze ({ "dead", "airborne", "shielded" })
const ABSENT = "swimming"

-- The range a grid is laid over here, wide enough that a width is worth reading and no wider.
const LOW = 0
const HIGH = 15
const STEP = 0.25

-- What an angle closes on, which is the number this file measures a span of one against.
const TURN = Scalars.TURN

-- Where a field sits in the run, and where a case writes its truths from, which are not the same.
const AT = 3
const FROM = 5

-- Types ---------------------------------------------------------------

type Field = Joins.Field

-- Private -------------------------------------------------------------

--[[
    A tag, which is what a refusal inside the field would be spelled at.

    The numbers are indices into tables this unit does not build, so what they are does not matter.
    What matters is that the field carries the one it was given rather than making its own.
]]
local function tagged (): Ir.Tag return { pathId = 1, expectId = 2 } end

-- A declaration as the field it becomes, at the place and under the name a case names.
local function field (of: any, key: string?, nest: number?): Field
    local held = Joins.of (Base.cell (of), tagged (), AT, key, nest)
    Expect.holds (held ~= nil, "a declaration that should be a field is none")
    return held :: Field
end

-- The names a bitfield records, which is the order its leaves are in and not the declared one.
local function named (of: any): { string } return Base.cell (of).params.names :: { string } end

-- The widths of a declaration's leaves, joined, which is what a region reads them for.
local function widths (of: any): string
    local held = Joins.leaves (Base.cell (of))
    if held == nil then return "none" end

    local out = {}
    for _, grid in held do
        table.insert (out, tostring (grid.width))
    end
    return table.concat (out, " ")
end

-- Public --------------------------------------------------------------

return {
    --[[
        The kinds whose value the language carries, each with the one grid it indexes through. Every
        other kind has none: a record, a list and a string are not one point on a line, and a float
        is a byte field wherever it appears rather than a reading off a grid.
    ]]
    Harness.case ("joins.grid-kinds", function ()
        local held = {
            Lync.bool (),
            Lync.int (LOW, HIGH),
            Lync.quant (LOW, 1, STEP),
            Lync.angle (HIGH),
            Lync.enum (FLAGS),
        }

        for _, of in held do
            Expect.holds (Joins.grid (Base.cell (of)) ~= nil, "a scalar carried no grid")
        end

        local none = {
            Lync.f32 (),
            Lync.str (LOW, HIGH),
            Lync.struct ({ a = Lync.bool () }),
            Lync.array (Lync.bool (), 1, 1),
            Lync.bitfield (FLAGS),
        }

        for _, of in none do
            Expect.equal (Joins.grid (Base.cell (of)), nil)
        end
    end),

    --[[
        What each grid is, read as the width the wire plans from. A truth is one bit, a bounded
        integer is as many as its range needs, a quantized number is as many as its steps need, and
        a name out of a list is as many as the list needs.
    ]]
    Harness.case ("joins.grid-widths", function ()
        Expect.equal (widths (Lync.bool ()), "1")
        Expect.equal (widths (Lync.int (LOW, HIGH)), "4")
        Expect.equal (widths (Lync.quant (LOW, 1, STEP)), "3")
        Expect.equal (widths (Lync.enum (FLAGS)), "2")
    end),

    --[[
        A bitfield is as many one-bit leaves as it has names. That is what keeps it out of the
        packed runs its columns become: a record of truths is a record, and the run it flows in is
        made of the leaves rather than of the field.
    ]]
    Harness.case ("joins.leaves-bitfield", function ()
        Expect.equal (widths (Lync.bitfield (FLAGS)), "1 1 1")
        Expect.equal (widths (Lync.bitfield ({ FLAGS[1] })), "1")
    end),

    --[[
        Everything with no leaves at all, which is what says a declaration is no region field. The
        answer is nothing rather than an empty list, because a field of no leaves and a declaration
        that is not a field are different things and only one of them has a place in a region.
    ]]
    Harness.case ("joins.leaves-none", function ()
        Expect.equal (widths (Lync.str (LOW, HIGH)), "none")
        Expect.equal (widths (Lync.struct ({ a = Lync.bool () })), "none")
        Expect.equal (widths (Lync.map (Lync.enum (FLAGS), Lync.bool (), 1, 1)), "none")
        Expect.equal (Joins.of (Base.cell (Lync.str (LOW, HIGH)), tagged (), AT, nil, nil), nil)
    end),

    --[[
        A kind with a grid, held to answering one leaf and no pair. A pair on a plain field is a
        call the emitter would make and nobody wrote.
    ]]
    Harness.case ("joins.plain-carries-no-pair", function ()
        local held = field (Lync.int (LOW, HIGH))

        Expect.equal (#held.leaves, 1)
        Expect.equal (held.join.count, 1)
        Expect.equal (held.join.at, AT)
        Expect.equal (held.join.pull, nil)
        Expect.equal (held.join.push, nil)
    end),

    --[[
        The one kind that carries a pair, held to the three things a field made of several leaves
        owes: as many leaves as names, a count saying how many places it takes, and both halves of
        the pair present. The pair is there because one value spread over several leaves needs a
        way down into them and a way back.
    ]]
    Harness.case ("joins.bitfield-carries-a-pair", function ()
        local held = field (Lync.bitfield (FLAGS))

        Expect.equal (#held.leaves, #FLAGS)
        Expect.equal (held.join.count, #FLAGS)
        Expect.holds (held.join.pull ~= nil, "a bitfield carried no way down")
        Expect.holds (held.join.push ~= nil, "a bitfield carried no way back")
    end),

    --[[
        Both facts ride on the join and neither is derived at the call. Asked of a dissolved
        record as well as a plain one, since those are the two places they can differ.
    ]]
    Harness.case ("joins.key-and-nest", function ()
        local plain = field (Lync.bool ())
        Expect.equal (plain.join.key, nil)
        Expect.equal (plain.join.nest, nil)

        local held = field (Lync.bool (), FLAGS[1], AT)
        Expect.equal (held.join.key, FLAGS[1])
        Expect.equal (held.join.nest, AT)
        Expect.equal (held.join.tag.pathId, tagged ().pathId)
    end),

    --[[
        Two records holding the same truths under the same names come to the same bits, whatever
        order each was written in. Reading the pair by name rather than by insertion is the whole
        of what makes that hold.
    ]]
    Harness.case ("joins.pull-by-name", function ()
        local held = field (Lync.bitfield (FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean

        local first: { [string]: boolean } = {}
        first.shielded, first.dead, first.airborne = true, true, false

        local second: { [string]: boolean } = {}
        second.airborne, second.shielded, second.dead = false, true, true

        local one, two = {}, {}
        Expect.equal (pull (first, one, 1), true)
        Expect.equal (pull (second, two, 1), true)
        Expect.equal (table.concat (one, " "), table.concat (two, " "))
    end),

    --[[
        A name a record leaves out reads as false, so a caller writing two of three flags gets the
        third off. Asked at every position, since a missing name is easiest to get wrong last.
    ]]
    Harness.case ("joins.pull-missing-is-false", function ()
        local of = Lync.bitfield (FLAGS)
        local held = field (of)
        local pull = held.join.pull :: (any, { number }, number) -> boolean

        local names = named (of)
        Expect.equal (table.concat (names, " "), "airborne dead shielded")

        for place, name in names do
            local into = {}
            Expect.equal (pull ({ [name] = true }, into, 1), true)

            local wanted = { 0, 0, 0 }
            wanted[place] = 1
            Expect.equal (table.concat (into, " "), table.concat (wanted, " "))
        end

        -- And a name the declaration has not got is nothing to it, since it reads its own names.
        local other = {}
        Expect.equal (pull ({ [ABSENT] = true }, other, 1), true)
        Expect.equal (table.concat (other, " "), "0 0 0")
    end),

    --[[
        A name it does carry has to carry a truth. Asked with a string, which is the value a
        truthiness test would take for true and write as the flag being set.
    ]]
    Harness.case ("joins.pull-refuses-a-non-truth", function ()
        local held = field (Lync.bitfield (FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean

        Expect.equal (pull ({ [FLAGS[1]] = "no" }, {}, 1), false)
        Expect.equal (pull ({ [FLAGS[1]] = 0 }, {}, 1), false)
        Expect.equal (pull ({ [FLAGS[1]] = true, [FLAGS[2]] = 1 }, {}, 1), false)
    end),

    --[[
        A value that is not a record has no name to read, and what the refusal names is the field
        rather than the bit it stopped at. A caller greps their schema for the name they wrote.
    ]]
    Harness.case ("joins.pull-refuses-a-non-record", function ()
        local held = field (Lync.bitfield (FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean

        for _, value in { true, 0, "dead" } do
            Expect.equal (pull (value, {}, 1), false)
        end
    end),

    --[[
        The way back, and the offset it reads from. A field's truths sit at its own place in the
        run rather than at the front of it, so both halves of the pair take where to start and a
        pair that assumed the front would read the field before it.
    ]]
    Harness.case ("joins.round-trip", function ()
        local held = field (Lync.bitfield (FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean
        local push = held.join.push :: ({ number }, number) -> any

        local was = { [FLAGS[1]] = true, [FLAGS[2]] = false, [FLAGS[3]] = true }

        local run = { 9, 9, 9, 9 }
        Expect.equal (pull (was, run, FROM), true)
        Expect.equal (table.concat (run, " ", 1, 4), "9 9 9 9")

        local back = push (run, FROM)
        for _, name in FLAGS do
            Expect.equal (back[name], was[name])
        end
        Expect.equal (back[ABSENT], nil)
    end),

    --[[
        The grid an angle lands on, which closes a step short of a whole turn and wraps there. A
        turn brings a direction back to where it started, so a grid holding both ends holds one
        direction twice and spends a point saying the same thing, and one that does not wrap turns
        away every reading past its top rather than folding it round.
    ]]
    Harness.case ("joins.an-angle-wraps-a-step-short", function ()
        const HALF = 0.5

        local of = Joins.grid (Base.cell (Lync.angle (HALF)))
        Expect.holds (of ~= nil, "an angle carried no grid")

        local held = of :: any
        Expect.equal (held.span, TURN / HALF - 1)
        Expect.equal (held.wrap, true)

        -- A whole turn is the first point again, which is what wrapping there means.
        Expect.equal (held.toIndex (TURN), held.toIndex (0))
        Expect.equal (held.toIndex (TURN + HALF), held.toIndex (HALF))
    end),
}
