--!strict
--!optimize 2
-- The composite constructors: what each records, and the arguments each turns away.

local Base = require("@src/codec/Base")
local Composites = require("@src/codec/Composites")
local Scalars = require("@src/codec/Scalars")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local LOW = 0
local HIGH = 4
local ONE = "one"
local TWO = "two"
local NOT_A_NAME = 7

type Refusal = { what: string, says: string, make: () -> () }

local function fine()
    return Scalars.int(LOW, HIGH)
end

local function refuses(list: { Refusal })
    for _, entry in list do
        local said = Expect.throws(entry.make)
        Expect.holds(string.find(said, entry.says, 1, true) ~= nil, `{entry.what} said "{said}"`)
    end
end

local function children(of: any): { [string]: any }
    return Base.cell(of).children :: any
end

return {
    -- A record holds its fields under the caller's names, and an optional may sit in one.
    Harness.case("composites.struct", function()
        local of = Composites.struct({ a = fine(), b = Composites.optional(fine()) })
        Expect.equal(Base.cell(of).kind, "struct")
        Expect.equal(Base.cell(children(of).a).kind, "int")
        Expect.equal(Base.cell(children(of).b).kind, "optional")
        Expect.equal(Base.cell(Composites.struct({})).kind, "struct")
    end),

    -- The enum and bitfield share one list and every rule about it.
    Harness.case("composites.names-legal", function()
        refuses({
            {
                what = "an enum of no list",
                says = "takes a list of names",
                make = function()
                    Composites.enum(NOT_A_NAME :: any)
                end,
            },
            {
                what = "an enum of nothing",
                says = "at least one name",
                make = function()
                    Composites.enum({})
                end,
            },
            {
                what = "an enum of a number",
                says = "takes names",
                make = function()
                    Composites.enum({ NOT_A_NAME :: any })
                end,
            },
            {
                what = "an enum naming one thing twice",
                says = "each name once",
                make = function()
                    Composites.enum({ ONE, ONE })
                end,
            },
            {
                what = "a bitfield of no list",
                says = "takes a list of names",
                make = function()
                    Composites.bitfield(NOT_A_NAME :: any)
                end,
            },
            {
                what = "a bitfield of nothing",
                says = "at least one name",
                make = function()
                    Composites.bitfield({})
                end,
            },
            {
                what = "a bitfield naming one thing twice",
                says = "each name once",
                make = function()
                    Composites.bitfield({ TWO, TWO })
                end,
            },
        })
    end),

    -- Names are recorded sorted, so the order written never reaches the wire.
    Harness.case("composites.names-are-sorted", function()
        local names = { TWO, ONE, "three" }
        Expect.equal(Base.cell(Composites.enum(names)).params.names, { ONE, "three", TWO })
        Expect.equal(Base.cell(Composites.bitfield(names)).params.names, { ONE, "three", TWO })
        Expect.equal(names, { TWO, ONE, "three" })
    end),

    Harness.case("composites.records-legal", function()
        local plain = { [ONE] = Composites.struct({ [TWO] = fine() }) }
        local nameless = { [NOT_A_NAME] = Composites.struct({}) }
        local shadowing = { [TWO] = Composites.struct({ [ONE] = fine() }) }
        refuses({
            {
                what = "a struct of no table",
                says = "takes a table of fields",
                make = function()
                    Composites.struct(NOT_A_NAME :: any)
                end,
            },
            {
                what = "a struct with a field under no name",
                says = "takes named fields",
                make = function()
                    Composites.struct({ [NOT_A_NAME] = fine() } :: any)
                end,
            },
            {
                what = "a struct whose field is not a codec",
                says = "takes a codec for",
                make = function()
                    Composites.struct({ [ONE] = NOT_A_NAME :: any })
                end,
            },
            {
                what = "a tagged with no field name",
                says = "takes a field name",
                make = function()
                    Composites.tagged(NOT_A_NAME :: any, plain)
                end,
            },
            {
                what = "a tagged with no variants table",
                says = "takes a table of variants",
                make = function()
                    Composites.tagged(ONE, NOT_A_NAME :: any)
                end,
            },
            {
                what = "a tagged with no variants",
                says = "at least one variant",
                make = function()
                    Composites.tagged(ONE, {})
                end,
            },
            {
                what = "a tagged with a variant under no name",
                says = "takes named variants",
                make = function()
                    Composites.tagged(ONE, nameless :: any)
                end,
            },
            {
                what = "a tagged whose variant is not a record",
                says = "takes a struct for",
                make = function()
                    Composites.tagged(ONE, { [TWO] = fine() })
                end,
            },
            {
                what = "a variant declaring the tag itself",
                says = "which is the tag",
                make = function()
                    Composites.tagged(ONE, shadowing)
                end,
            },
        })

        local of = Composites.tagged(ONE, plain)
        Expect.equal(Base.cell(of).kind, "tagged")
        Expect.equal(Base.cell(of).params.field, ONE)
        Expect.equal(Base.cell(children(of)[ONE]).kind, "struct")
    end),

    -- An optional is taken in a struct field and nowhere else.
    Harness.case("composites.optional-where-a-record-names-it", function()
        local maybe = Composites.optional(fine())
        Composites.struct({ held = maybe })
        Expect.throws(function()
            Composites.array(maybe, LOW, HIGH)
        end, "no optional for element")
        Expect.throws(function()
            Composites.map(fine(), maybe, LOW, HIGH)
        end, "no optional for value")
        Expect.throws(function()
            Composites.map(maybe, fine(), LOW, HIGH)
        end, "no optional for key")
        Expect.throws(function()
            Composites.optional(maybe)
        end, "no optional for inner")
    end),

    -- The counted composites record their bounds and children, under one count rule.
    Harness.case("composites.counted", function()
        local list = Composites.array(fine(), LOW, HIGH)
        Expect.equal(Base.cell(list).kind, "array")
        Expect.equal(Base.cell(list).params.max, HIGH)
        Expect.equal(Base.cell(children(list).element).kind, "int")

        local dict = Composites.map(fine(), Scalars.bool(), LOW, HIGH)
        Expect.equal(Base.cell(dict).kind, "map")
        Expect.equal(Base.cell(children(dict).key).kind, "int")
        Expect.equal(Base.cell(children(dict).value).kind, "bool")

        Expect.throws(function()
            Composites.array(fine(), HIGH, LOW)
        end, "in order")
        Expect.throws(function()
            Composites.map(fine(), fine(), -1, HIGH)
        end, "from zero up")
        Expect.throws(function()
            Composites.array(Scalars.empty(), LOW, HIGH)
        end, "no empty")
    end),
}
