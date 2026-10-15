--!strict
--!optimize 2
-- The codec cell alone: what a constructor freezes into one, and what a modifier does to one.

local Base = require("@src/codec/Base")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LOW = 0
local HIGH = 10

-- The value a check turns away above, inside the bound so both answers are reachable.
local CEILING = 5

local FIRST = "the first check said no"
local SECOND = "the second check said no"

-- Readings a gate would never open at, or never close at.
local RATES = table.freeze({ 0, -1, -0.5, math.huge, -math.huge, 0 / 0 })

local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 0, last = nil })

type Check = (value: any, ctx: Types.ValidateContext) -> string?

local function int(): Types.Codec<number>
    return Base.make("int", { min = LOW, max = HIGH })
end

local function above(said: string): Check
    return function(value: any): string?
        return if value > CEILING then said else nil
    end
end

-- The words every check on a codec gives back for one value, in declaration order.
local function answers(of: Types.Codec<any>, value: any): { string }
    local out = {}
    for _, check in Base.cell(of).validates do
        table.insert(out, check(value, CTX) or "")
    end
    return out
end

local function up(n: number): string
    return tostring(n)
end

local function down(s: string): number
    return tonumber(s) :: number
end

return {
    -- A declaration is a value, so nothing can be written onto one after it is made.
    Harness.case("cell.frozen", function()
        local of = int()
        Expect.throws(function()
            (of :: any).kind = "bool"
        end)
        Expect.throws(function()
            (of :: any).marker = "newest"
        end)
        Expect.throws(function()
            (of :: any).mine = true
        end)
    end),

    -- The table a composite was handed may move afterwards, so the cell holds a frozen copy.
    Harness.case("cell.children-copied", function()
        local fields: { [string]: any } = { flag = Base.make("bool") }
        local of = Base.make("struct", nil, fields)

        fields.second = Base.make("bool")
        fields.flag = nil

        local held = Base.cell(of).children :: any
        Expect.holds(held ~= nil, "a struct recorded no children")
        Expect.holds(held.flag ~= nil, "the field the struct was declared with is gone")
        Expect.equal(held.second, nil)
        Expect.throws(function()
            held.third = true
        end)
    end),

    -- The same for a parameter that is a list, copied and frozen.
    Harness.case("cell.list-params-copied", function()
        local names = { "red", "blue" }
        local of = Base.make("enum", { names = names })

        table.insert(names, "green")

        local held = Base.cell(of).params.names :: any
        Expect.holds(held ~= nil, "an enum recorded no names")
        Expect.equal(#held, 2)
        Expect.throws(function()
            table.insert(held, "green")
        end)
    end),

    -- Two codecs that declare no parameters share one frozen empty table.
    Harness.case("cell.no-params-shared", function()
        local one = Base.cell(Base.make("bool"))
        local two = Base.cell(Base.make("f32"))
        Expect.holds(one.params == two.params, "two codecs with no parameters hold two tables")
        Expect.equal(next(one.params :: any), nil)
        Expect.throws(function()
            (one.params :: any).min = LOW
        end)
    end),

    -- One base reached three ways answers three codecs and stays what it was.
    Harness.case("cell.modifiers-answer-a-new-one", function()
        local base = int()
        local held = Base.cell(base)
        local made: { any } = { base:validate(above(FIRST)), base:newest(), base:as(up, down) }

        for index, one in made do
            Expect.holds(one ~= base, `the modifier at {index} answered the codec it was given`)
            Expect.equal(Base.cell(one).kind, held.kind)
        end
        Expect.equal(held.marker, "none")
        Expect.equal(#held.validates, 0)
    end),

    -- A chain of two appends: the first reason is the one reported.
    Harness.case("cell.checks-append", function()
        local one = int():validate(above(FIRST))
        local two = one:validate(above(SECOND))
        Expect.equal(answers(two, HIGH), { FIRST, SECOND })
        Expect.equal(answers(two, LOW), { "", "" })
        Expect.equal(answers(one, HIGH), { FIRST })
    end),

    Harness.case("cell.checks-frozen", function()
        local of = int():validate(above(FIRST))
        local held = Base.cell(of).validates
        Expect.throws(function()
            table.insert(held :: any, above(SECOND))
        end)
        Expect.equal(#held, 1)
    end),

    -- A second newest carries its own rate, never the first one's.
    Harness.case("cell.marker-carries-its-rate", function()
        local rated = int():newest(CEILING)
        Expect.equal(Base.cell(rated).marker, "newest")
        Expect.equal(Base.cell(rated).newestHz, CEILING)
        Expect.equal(Base.cell(rated:newest()).newestHz, nil)
    end),

    -- A rate that never opens a gate, or always does, is refused where it is written.
    Harness.case("cell.newest-refuses-a-dead-rate", function()
        for _, hz in RATES do
            Expect.throws(function()
                int():newest(hz)
            end, "takes a rate above zero")
        end
        Expect.equal(Base.cell(int():newest()).newestHz, nil)
    end),

    -- Nothing but a cell this vocabulary made answers true, not even a table wearing its fields.
    Harness.case("cell.made", function()
        Expect.equal(Base.made(Base.make("bool")), true)
        Expect.equal(Base.made(Base.make("bool"):validate(above(FIRST))), true)
        Expect.equal(Base.made({ kind = "bool", params = {}, validates = {} }), false)
        Expect.equal(Base.made({}), false)
        Expect.equal(Base.made(nil), false)
        Expect.equal(Base.made(CEILING), false)
        Expect.equal(Base.made("bool"), false)
    end),

    -- The two views of a codec are one table and never two.
    Harness.case("cell.two-views", function()
        local of = Base.make("array", { min = LOW, max = HIGH }, { element = Base.make("bool") })
        local held = Base.cell(of)
        Expect.holds(Base.codec(held) == of, "the two views answered two tables")
        Expect.equal(Base.made(Base.codec((held.children :: any).element)), true)
    end),

    -- Two transforms stacked: the second runs the first one's way up before its own and the first
    -- one's way down after its own.
    Harness.case("cell.as-composes", function()
        local of = int():as(function(n: number): number
            return n + 1
        end, function(n: number): number
            return n - 1
        end):as(up, down)

        local held = Base.cell(of)
        Expect.equal((held.lift :: any)(LOW), tostring(LOW + 1))
        Expect.equal((held.lower :: any)(tostring(LOW + 1)), LOW)
    end),

    -- A check declared before a transform is asked of the value underneath, and one declared after
    -- reads the transform's own value.
    Harness.case("cell.as-unlifts-a-check", function()
        local of = int():validate(above(FIRST)):as(up, down)
        Expect.equal(answers(of, tostring(HIGH)), { FIRST })
        Expect.equal(answers(of, tostring(LOW)), { "" })

        local after = of:validate(function(s: any): string?
            return if #s > 1 then SECOND else nil
        end)
        Expect.equal(answers(after, tostring(HIGH)), { FIRST, SECOND })
    end),
}
