--!strict
--!optimize 2
-- A declaration as the field it becomes: the grids it indexes through, and the pair over them.

local Base = require("@src/codec/Base")
local Codecs = require("@src/codec")
local Ir = require("@src/shape/Ir")
local Joins = require("@src/shape/Joins")
local Scalars = require("@src/codec/Scalars")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

-- The names a bitfield is declared over, and the one no declaration here carries.
local FLAGS = table.freeze({ "dead", "airborne", "shielded" })
local ABSENT = "swimming"

local LOW = 0
local HIGH = 15
local STEP = 0.25
local TURN = Scalars.TURN

-- Where a field sits in the run, and where a case writes its truths from.
local AT = 3
local FROM = 5

type Field = Joins.Field

local function tagged(): Ir.Tag
    return { pathId = 1, expectId = 2 }
end

local function field(of: any, key: string?, nest: number?): Field
    local held = Joins.of(Base.cell(of), tagged(), AT, key, nest)
    Expect.holds(held ~= nil, "a declaration that should be a field is none")
    return held :: Field
end

local function named(of: any): { string }
    return Base.cell(of).params.names :: { string }
end

-- The widths of a declaration's leaves, joined.
local function widths(of: any): string
    local held = Joins.leaves(Base.cell(of))
    if held == nil then return "none" end
    local out = {}
    for _, grid in held do
        table.insert(out, tostring(grid.width))
    end
    return table.concat(out, " ")
end

return {
    -- The kinds the language carries as one value each have one grid, and nothing else has.
    Harness.case("joins.grid-kinds", function()
        for _, of in
            {
                Codecs.bool(),
                Codecs.int(LOW, HIGH),
                Codecs.quant(LOW, 1, STEP),
                Codecs.angle(HIGH),
                Codecs.enum(FLAGS),
            }
        do
            Expect.holds(Joins.grid(Base.cell(of)) ~= nil, "a scalar carried no grid")
        end
        for _, of in
            {
                Codecs.f32(),
                Codecs.str(LOW, HIGH),
                Codecs.struct({ a = Codecs.bool() }),
                Codecs.array(Codecs.bool(), 1, 1),
                Codecs.bitfield(FLAGS),
            }
        do
            Expect.equal(Joins.grid(Base.cell(of)), nil)
        end
    end),

    Harness.case("joins.grid-widths", function()
        Expect.equal(widths(Codecs.bool()), "1")
        Expect.equal(widths(Codecs.int(LOW, HIGH)), "4")
        Expect.equal(widths(Codecs.quant(LOW, 1, STEP)), "3")
        Expect.equal(widths(Codecs.enum(FLAGS)), "2")
    end),

    -- A bitfield is as many one-bit leaves as it has names.
    Harness.case("joins.leaves-bitfield", function()
        Expect.equal(widths(Codecs.bitfield(FLAGS)), "1 1 1")
        Expect.equal(widths(Codecs.bitfield({ FLAGS[1] })), "1")
    end),

    -- No leaves at all is nothing rather than an empty list: the declaration is no region field.
    Harness.case("joins.leaves-none", function()
        Expect.equal(widths(Codecs.str(LOW, HIGH)), "none")
        Expect.equal(widths(Codecs.struct({ a = Codecs.bool() })), "none")
        Expect.equal(widths(Codecs.map(Codecs.enum(FLAGS), Codecs.bool(), 1, 1)), "none")
        Expect.equal(Joins.of(Base.cell(Codecs.str(LOW, HIGH)), tagged(), AT, nil, nil), nil)
    end),

    Harness.case("joins.plain-carries-no-pair", function()
        local held = field(Codecs.int(LOW, HIGH))
        Expect.equal(#held.leaves, 1)
        Expect.equal(held.join.count, 1)
        Expect.equal(held.join.at, AT)
        Expect.equal(held.join.pull, nil)
        Expect.equal(held.join.push, nil)
    end),

    Harness.case("joins.bitfield-carries-a-pair", function()
        local held = field(Codecs.bitfield(FLAGS))
        Expect.equal(#held.leaves, #FLAGS)
        Expect.equal(held.join.count, #FLAGS)
        Expect.holds(held.join.pull ~= nil, "a bitfield carried no way down")
        Expect.holds(held.join.push ~= nil, "a bitfield carried no way back")
    end),

    Harness.case("joins.key-and-nest", function()
        local plain = field(Codecs.bool())
        Expect.equal(plain.join.key, nil)
        Expect.equal(plain.join.nest, nil)

        local held = field(Codecs.bool(), FLAGS[1], AT)
        Expect.equal(held.join.key, FLAGS[1])
        Expect.equal(held.join.nest, AT)
        Expect.equal(held.join.tag.pathId, tagged().pathId)
    end),

    -- Two records holding the same truths under the same names come to the same bits.
    Harness.case("joins.pull-by-name", function()
        local held = field(Codecs.bitfield(FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean

        local first: { [string]: boolean } = {}
        first.shielded, first.dead, first.airborne = true, true, false
        local second: { [string]: boolean } = {}
        second.airborne, second.shielded, second.dead = false, true, true

        local one, two = {}, {}
        Expect.equal(pull(first, one, 1), true)
        Expect.equal(pull(second, two, 1), true)
        Expect.equal(table.concat(one, " "), table.concat(two, " "))
    end),

    -- A name a record leaves out reads as false, and a name the declaration lacks is nothing to it.
    Harness.case("joins.pull-missing-is-false", function()
        local of = Codecs.bitfield(FLAGS)
        local pull = field(of).join.pull :: (any, { number }, number) -> boolean

        local names = named(of)
        Expect.equal(table.concat(names, " "), "airborne dead shielded")
        for place, name in names do
            local into = {}
            Expect.equal(pull({ [name] = true }, into, 1), true)
            local wanted = { 0, 0, 0 }
            wanted[place] = 1
            Expect.equal(table.concat(into, " "), table.concat(wanted, " "))
        end

        local other = {}
        Expect.equal(pull({ [ABSENT] = true }, other, 1), true)
        Expect.equal(table.concat(other, " "), "0 0 0")
    end),

    -- A string is what a truthiness test would write as the flag being set.
    Harness.case("joins.pull-refuses-a-non-truth", function()
        local pull = field(Codecs.bitfield(FLAGS)).join.pull :: (any, { number }, number) -> boolean
        Expect.equal(pull({ [FLAGS[1]] = "no" }, {}, 1), false)
        Expect.equal(pull({ [FLAGS[1]] = 0 }, {}, 1), false)
        Expect.equal(pull({ [FLAGS[1]] = true, [FLAGS[2]] = 1 }, {}, 1), false)
    end),

    Harness.case("joins.pull-refuses-a-non-record", function()
        local pull = field(Codecs.bitfield(FLAGS)).join.pull :: (any, { number }, number) -> boolean
        for _, value in { true, 0, "dead" } do
            Expect.equal(pull(value, {}, 1), false)
        end
    end),

    -- Both halves of the pair take where to start, since a field sits at its own place in the run.
    Harness.case("joins.round-trip", function()
        local held = field(Codecs.bitfield(FLAGS))
        local pull = held.join.pull :: (any, { number }, number) -> boolean
        local push = held.join.push :: ({ number }, number) -> any

        local was = { [FLAGS[1]] = true, [FLAGS[2]] = false, [FLAGS[3]] = true }
        local run = { 9, 9, 9, 9 }
        Expect.equal(pull(was, run, FROM), true)
        Expect.equal(table.concat(run, " ", 1, 4), "9 9 9 9")

        local back = push(run, FROM)
        for _, name in FLAGS do
            Expect.equal(back[name], was[name])
        end
        Expect.equal(back[ABSENT], nil)
    end),

    -- An angle's grid closes a step short of a whole turn and wraps there.
    Harness.case("joins.an-angle-wraps-a-step-short", function()
        local half = 0.5
        local of = Joins.grid(Base.cell(Codecs.angle(half)))
        Expect.holds(of ~= nil, "an angle carried no grid")

        local held = of :: any
        Expect.equal(held.span, TURN / half - 1)
        Expect.equal(held.wrap, true)
        Expect.equal(held.toIndex(TURN), held.toIndex(0))
        Expect.equal(held.toIndex(TURN + half), held.toIndex(half))
    end),
}
