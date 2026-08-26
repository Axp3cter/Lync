--!strict
--!optimize 2
--[[
    The codec cell alone: what a constructor freezes into one, and what a modifier does to one.
]]

local Base = require ("@src/codec/Base")
local Lync = require ("@src")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")
local Turns = require ("@test/harness/Turns")

-- Constants -----------------------------------------------------------

-- A bound every codec here is built with, since none of these cases is about a bound.
const LOW = 0
const HIGH = 10

-- The value a check turns away above, which is inside that bound so both answers are reachable.
const CEILING = 5

-- What each of the two refusals says, in words nothing else in this file uses.
const FIRST = "the first check said no"
const SECOND = "the second check said no"

-- Readings a gate would never open at, or never close at, which is every one that is not a rate.
const RATES = table.freeze ({ 0, -1, -0.5, math.huge, -math.huge, 0 / 0 })

-- Types ---------------------------------------------------------------

type Check = (value: any, ctx: Types.ValidateContext) -> string?

-- Private -------------------------------------------------------------

-- A check that turns away anything above the ceiling, named so a chain can say which one spoke.
local function above (said: string): Check
    return function (value: any): string? return if value > CEILING then said else nil end
end

-- The words every check on a codec gives back for one value, in the order they were declared.
local function answers (of: Types.Codec<any>, value: any): { string }
    local out = {}
    for _, check in Base.cell (of).validates do
        table.insert (out, check (value, Turns.CTX) or "")
    end
    return out
end

-- One up and one down, which is the pair every case about a transform here is built from.
local function up (n: number): string return tostring (n) end

local function down (s: string): number return tonumber (s) :: number end

-- Public --------------------------------------------------------------

return {
    --[[
        A declaration is a value, so nothing can be written onto one after it is made. That is what
        lets a codec be shared between two definitions and between two namespaces without either of
        them being able to move what the other declared.
    ]]
    Harness.case ("cell.frozen", function ()
        local of = Lync.int (LOW, HIGH)

        Expect.throws (function () (of :: any).kind = "bool" end)
        Expect.throws (function () (of :: any).marker = "newest" end)
        Expect.throws (function () (of :: any).mine = true end)
    end),

    --[[
        The table a composite was handed, changed after the declaration was made. A caller builds
        one and may keep it, and a schema that moved afterwards would be a schema the hash both
        machines agreed on no longer describes, so what the cell holds is a copy of its own.
    ]]
    Harness.case ("cell.children-copied", function ()
        local fields: { [string]: any } = { flag = Lync.bool () }
        local of = Lync.struct (fields)

        fields.second = Lync.bool ()
        fields.flag = nil

        local held = Base.cell (of).children
        Expect.holds (held ~= nil, "a struct recorded no children")
        Expect.holds ((held :: any).flag ~= nil, "the field the struct was declared with is gone")
        Expect.equal ((held :: any).second, nil)
    end),

    --[[
        The same the other way in, for a parameter that is a list rather than a child. A palette
        reaches a constructor from the caller exactly as a field table does, so what a cell holds is
        copied for the same reason, and the copy is frozen so nothing reaches into it either.
    ]]
    Harness.case ("cell.list-params-copied", function ()
        local colors = { Color3.new (1, 0, 0), Color3.new (0, 1, 0) }
        local of = Lync.color3.palette (colors)

        table.insert (colors, Color3.new (0, 0, 1))

        local held = Base.cell (of).params.colors
        Expect.holds (held ~= nil, "a palette recorded no colours")
        Expect.equal (#(held :: any), 2)
        Expect.throws (function () table.insert (held :: any, Color3.new (0, 0, 1)) end)
    end),

    --[[
        Two codecs that declare no parameters, which share one table. Two frozen empty tables cannot
        be told apart by anything downstream, so a second one would be an allocation per declaration
        buying a difference nobody can read.
    ]]
    Harness.case ("cell.no-params-shared", function ()
        local one = Base.cell (Lync.bool ())
        local two = Base.cell (Lync.f32 ())

        Expect.holds (one.params == two.params, "two codecs with no parameters hold two tables")
        Expect.equal (next (one.params :: any), nil)
        Expect.throws (function () (one.params :: any).min = LOW end)
    end),

    --[[
        One base reached four ways, held to answering four codecs and staying what it was. A caller
        builds a base once and declares from it several times, so a modifier writing into it would
        make the fourth declaration depend on the order the other three were written in.
    ]]
    Harness.case ("cell.modifiers-answer-a-new-one", function ()
        local base = Lync.int (LOW, HIGH)
        local held = Base.cell (base)

        local made: { any } = {
            base:validate (above (FIRST)),
            base:monotonic (),
            base:newest (),
            base:as (up, down),
        }

        for index, one in made do
            Expect.holds (one ~= base, `the modifier at {index} answered the codec it was given`)
            Expect.equal (Base.cell (one).kind, held.kind)
        end

        Expect.equal (held.marker, "none")
        Expect.equal (#held.validates, 0)
    end),

    --[[
        A chain of two, both turning the same value away, which is the arrangement that tells an
        append from a replace. The first reason is the one reported: a
        chain that replaced would answer the second alone and one that prepended would reverse them.
    ]]
    Harness.case ("cell.checks-append", function ()
        local one = Lync.int (LOW, HIGH):validate (above (FIRST))
        local two = one:validate (above (SECOND))

        Expect.equal (answers (two, HIGH), { FIRST, SECOND })
        Expect.equal (answers (two, LOW), { "", "" })

        -- And the codec the second was built from still carries the one check it was declared with.
        Expect.equal (answers (one, HIGH), { FIRST })
    end),

    --[[
        The array of checks is frozen with the cell it is on, so a caller holding a codec cannot
        append to what it already carries. What that rules out is two machines holding one
        declaration and turning each other's payloads away over a difference the
        descriptor has no way to say.
    ]]
    Harness.case ("cell.checks-frozen", function ()
        local of = Lync.int (LOW, HIGH):validate (above (FIRST))
        local held = Base.cell (of).validates

        Expect.throws (function () table.insert (held :: any, above (SECOND)) end)
        Expect.equal (#held, 1)
    end),

    --[[
        A marker declared after a rated one carries no rate of its own. What that rules out is a
        second `newest` inheriting the first one's, which two machines would hash alike and only
        one of them would act on.
    ]]
    Harness.case ("cell.marker-carries-its-rate", function ()
        local rated = Lync.int (LOW, HIGH):newest (CEILING)
        Expect.equal (Base.cell (rated).newestHz, CEILING)

        Expect.equal (Base.cell (rated:monotonic ()).newestHz, nil)
        Expect.equal (Base.cell (rated:monotonic ():newest ()).newestHz, nil)
        Expect.equal (Base.cell (rated:newest ()).newestHz, nil)
    end),

    --[[
        A rate that never opens a gate, or always does, turned away where it is written. Refused
        at the declaration because neither is visible afterwards: the traffic a place sees looks
        like a rate somebody asked for.
    ]]
    Harness.case ("cell.newest-refuses-a-dead-rate", function ()
        for _, hz in RATES do
            Expect.throws (
                function () Lync.int (LOW, HIGH):newest (hz) end,
                "takes a rate above zero"
            )
        end

        -- No rate at all is the declared form rather than a mistake, since the gate is optional.
        Expect.equal (Base.cell (Lync.int (LOW, HIGH):newest ()).newestHz, nil)
    end),

    --[[
        Asked of a table wearing the same fields a cell has, which is the one thing a shape test
        would let through. Nothing but a cell this vocabulary made answers true.
    ]]
    Harness.case ("cell.made", function ()
        Expect.equal (Base.made (Lync.bool ()), true)
        Expect.equal (Base.made (Lync.bool ():validate (above (FIRST))), true)

        Expect.equal (Base.made ({ kind = "bool", params = {}, validates = {} }), false)
        Expect.equal (Base.made ({}), false)
        Expect.equal (Base.made (nil), false)
        Expect.equal (Base.made (CEILING), false)
        Expect.equal (Base.made ("bool"), false)
    end),

    --[[
        The two views of a codec, which are one table and never two. Everything above the compile
        path reads the public type and everything inside it reads the cell, and the pair of casts is
        what lets a walk that took a cell apart build the child back into what a constructor takes.
    ]]
    Harness.case ("cell.two-views", function ()
        local of = Lync.array (Lync.bool (), LOW, HIGH)
        local held = Base.cell (of)

        Expect.holds (Base.codec (held) == of, "the two views answered two tables")

        local child = (held.children :: any).element
        Expect.equal (Base.made (Base.codec (child)), true)
    end),

    --[[
        Two transforms stacked, each way round. A pair is adopted whole where there is none beneath
        it and composed where there is, so what a second one has to do is run the first one's way up
        before its own and the first one's way down after its own.
    ]]
    Harness.case ("cell.as-composes", function ()
        local of = Lync.int (LOW, HIGH)
            :as (
                function (n: number): number return n + 1 end,
                function (n: number): number return n - 1 end
            )
            :as (up, down)

        local held = Base.cell (of)
        Expect.equal ((held.lift :: any) (LOW), tostring (LOW + 1))
        Expect.equal ((held.lower :: any) (tostring (LOW + 1)), LOW)
    end),

    --[[
        A check declared before a transform, asked of the value the transform answers. What the
        check was written against is the value underneath, so the way back is run before it rather
        than remembered: `from` has to invert `to` for the codec to round trip at all, so there is
        nothing to remember that `from` does not already say.
    ]]
    Harness.case ("cell.as-unlifts-a-check", function ()
        local of = Lync.int (LOW, HIGH):validate (above (FIRST)):as (up, down)

        Expect.equal (answers (of, tostring (HIGH)), { FIRST })
        Expect.equal (answers (of, tostring (LOW)), { "" })

        -- A check declared after the transform reads the transform's own value untouched.
        local after = of:validate (
            function (s: any): string? return if #s > 1 then SECOND else nil end
        )
        Expect.equal (answers (after, tostring (HIGH)), { FIRST, SECOND })
    end),
}
