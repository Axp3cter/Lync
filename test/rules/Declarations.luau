--!strict
--!optimize 2
-- What a constructor will not take, and what it says about it.

local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

--[[
    A codec every check here nests inside whatever it is refusing, so a refusal is about the thing
    being declared rather than about what is under it.
]]
local function fine (): any return Lync.bool () end

--[[
    Two names, a number that is not a name, and a colour, kept here because a refusal is about the
    shape of what it was handed and every check wants the same shapes.
]]
const ONE = "one"
const TWO = "two"
const NOT_A_NAME = 5
const SHADE = Color3.new (1, 0, 0)

-- Built apart, so the call that refuses each one fits a line and reads as the one thing it does.
const NAMELESS: any = { [NOT_A_NAME] = Lync.struct ({}) }
const SHADOWING: any = { [TWO] = Lync.struct ({ [ONE] = fine () }) }
const PLAIN: any = { [ONE] = Lync.struct ({}) }

-- A precision no angle takes, and a count no array starts from.
const TOO_FINE = 1000
const BACKWARDS = -1

-- Types ---------------------------------------------------------------

-- One declaration that will not build, as the call that makes it and the words it must answer.
type Refused = {
    read what: string,
    read says: string,
    read make: () -> (),
}

-- Private -------------------------------------------------------------

--[[
    Every declaration in a list, held to refusing and to saying why.

    Each is asked on its own and named by what it does, so a list of a dozen reports the one that
    let something through rather than that the dozen did.
]]
local function refuses (held: { Refused })
    for _, one in held do
        local said = Expect.throws (one.make, one.says)
        Expect.holds (said ~= "", `{one.what} refused with nothing to read`)
    end
end

-- Public --------------------------------------------------------------

return {
    --[[
        A list of names that is not one, which `enum` and `bitfield` both take. The two share every
        rule because they share the list, so a rule holding for one and not the other would be two
        orders for one declaration.
    ]]
    Harness.case ("codec.names-legal", function ()
        refuses ({
            {
                what = "an enum of no list",
                says = "takes a list of names",
                make = function () Lync.enum (NOT_A_NAME :: any) end,
            },
            {
                what = "an enum of nothing",
                says = "at least one name",
                make = function () Lync.enum ({}) end,
            },
            {
                what = "an enum of a number",
                says = "takes names",
                make = function () Lync.enum ({ NOT_A_NAME :: any }) end,
            },
            {
                what = "an enum naming one thing twice",
                says = "each name once",
                make = function () Lync.enum ({ ONE, ONE }) end,
            },
            {
                what = "a bitfield of no list",
                says = "takes a list of names",
                make = function () Lync.bitfield (NOT_A_NAME :: any) end,
            },
            {
                what = "a bitfield of nothing",
                says = "at least one name",
                make = function () Lync.bitfield ({}) end,
            },
            {
                what = "a bitfield naming one thing twice",
                says = "each name once",
                make = function () Lync.bitfield ({ TWO, TWO }) end,
            },
        })
    end),

    --[[
        A record whose fields are not fields, and a union whose variants are not records. A struct
        takes named codecs and a tagged takes named structs, and the second is the stricter for a
        reason the wire decides: a variant is a record laid beside the tag that chose it.
    ]]
    Harness.case ("codec.records-legal", function ()
        refuses ({
            {
                what = "a struct of no table",
                says = "takes a table of fields",
                make = function () Lync.struct (NOT_A_NAME :: any) end,
            },
            {
                what = "a struct with a field under no name",
                says = "takes named fields",
                make = function () Lync.struct ({ [NOT_A_NAME] = fine () } :: any) end,
            },
            {
                what = "a struct whose field is not a codec",
                says = "takes a codec for",
                make = function () Lync.struct ({ [ONE] = NOT_A_NAME :: any }) end,
            },
            {
                what = "a tagged with no field name",
                says = "takes a field name",
                make = function () Lync.tagged (NOT_A_NAME :: any, PLAIN) end,
            },
            {
                what = "a tagged with no variants table",
                says = "takes a table of variants",
                make = function () Lync.tagged (ONE, NOT_A_NAME :: any) end,
            },
            {
                what = "a tagged with no variants",
                says = "at least one variant",
                make = function () Lync.tagged (ONE, {}) end,
            },
            {
                what = "a tagged with a variant under no name",
                says = "takes named variants",
                make = function () Lync.tagged (ONE, NAMELESS) end,
            },
            {
                what = "a tagged whose variant is not a record",
                says = "takes a struct for",
                make = function () Lync.tagged (ONE, { [TWO] = fine () }) end,
            },
            {
                what = "a variant declaring the tag itself",
                says = "which is the tag",
                make = function () Lync.tagged (ONE, SHADOWING) end,
            },
        })
    end),

    --[[
        A bound that is not a bound, asked of three kinds. A count is whole, starts at nothing and
        runs upward, and every counted kind takes the same three rules. A number's bounds are the
        looser pair, needing only to sit on the line and be in order.
    ]]
    Harness.case ("codec.bounds-legal", function ()
        refuses ({
            {
                what = "an int of fractional bounds",
                says = "takes whole bounds",
                make = function () Lync.int (0.5, 1) end,
            },
            {
                what = "an int of backwards bounds",
                says = "takes its bounds in order",
                make = function () Lync.int (1, 0) end,
            },
            {
                what = "a quant of bounds off the line",
                says = "takes bounds on the line",
                make = function () Lync.quant (0 / 0, 1, 1) end,
            },
            {
                what = "a quant of backwards bounds",
                says = "takes its bounds in order",
                make = function () Lync.quant (1, 0, 1) end,
            },
            {
                what = "a quant of no step",
                says = "takes a step above zero",
                make = function () Lync.quant (0, 1, 0) end,
            },
            {
                what = "an array of fractional counts",
                says = "takes whole bounds",
                make = function () Lync.array (fine (), 0.5, 1) end,
            },
            {
                what = "an array counted from under nothing",
                says = "takes bounds from zero up",
                make = function () Lync.array (fine (), BACKWARDS, 1) end,
            },
            {
                what = "an array counted backwards",
                says = "takes its bounds in order",
                make = function () Lync.array (fine (), 1, 0) end,
            },
            {
                what = "an array of no codec",
                says = "takes a codec for",
                make = function () Lync.array (NOT_A_NAME :: any, 0, 1) end,
            },
            {
                what = "an array of an optional",
                says = "takes no optional for",
                make = function () Lync.array (Lync.optional (fine ()), 0, 1) end,
            },
            {
                what = "a map of an optional key",
                says = "takes no optional for",
                make = function () Lync.map (Lync.optional (fine ()), fine (), 0, 1) end,
            },
            {
                what = "a struct of a field carrying nothing",
                says = "takes no empty for",
                make = function () Lync.struct ({ nudge = Lync.empty () }) end,
            },
            {
                what = "an array of nothings",
                says = "takes no empty for",
                make = function () Lync.array (Lync.empty (), 0, 1) end,
            },
            {
                what = "an optional nothing",
                says = "takes no empty for",
                make = function () Lync.optional (Lync.empty ()) end,
            },
        })
    end),

    --[[
        A datatype's parameters, which a caller reads off a design rather than off the shape of
        their data. A precision is an angle bounded by a whole turn, a radius and a step are lengths
        taking nothing at zero, and an axis of no length names nowhere.
    ]]
    Harness.case ("codec.datatypes-legal", function ()
        refuses ({
            {
                what = "an angle coarser than a turn",
                says = "takes a precision",
                make = function () Lync.angle (TOO_FINE) end,
            },
            {
                what = "a bounded vector of no radius",
                says = "takes a radius above zero",
                make = function () Lync.vec3.bounded (0, 1) end,
            },
            {
                what = "a bounded vector of no step",
                says = "takes a step above zero",
                make = function () Lync.vec3.bounded (1, 0) end,
            },
            {
                what = "an axis that is not a vector",
                says = "takes a Vector3",
                make = function () Lync.rotation.axis (NOT_A_NAME :: any, 1) end,
            },
            {
                what = "an axis of no length",
                says = "takes an axis with a direction",
                make = function () Lync.rotation.axis (Vector3.zero, 1) end,
            },
            {
                what = "a rotation finer than a turn",
                says = "takes a precision",
                make = function () Lync.rotation.quat (TOO_FINE) end,
            },
            {
                what = "a palette of no list",
                says = "takes a list of colours",
                make = function () Lync.color3.palette (NOT_A_NAME :: any) end,
            },
            {
                what = "a palette of nothing",
                says = "at least one colour",
                make = function () Lync.color3.palette ({}) end,
            },
            {
                what = "a palette of a number",
                says = "takes a colour at",
                make = function () Lync.color3.palette ({ NOT_A_NAME :: any }) end,
            },
            {
                what = "a palette holding one colour twice",
                says = "each colour once",
                make = function () Lync.color3.palette ({ SHADE, SHADE }) end,
            },
            {
                what = "an instance of no class name",
                says = "takes a class name",
                make = function () Lync.inst (NOT_A_NAME :: any) end,
            },
        })
    end),

    --[[
        An alphabet, which is the list rules a third time and over bytes. A string over one spends
        the bits its symbols need rather than eight a character, so a set that is not one is a width
        nobody can compute and a symbol twice is two codes for one byte.
    ]]
    Harness.case ("codec.text-legal", function ()
        refuses ({
            {
                what = "an alphabet that is not a string",
                says = "takes a symbol set",
                make = function () Lync.str.alphabet (NOT_A_NAME :: any, 1, 2) end,
            },
            {
                what = "an alphabet of no symbols",
                says = "at least one symbol",
                make = function () Lync.str.alphabet ("", 1, 2) end,
            },
            {
                what = "an alphabet holding one symbol twice",
                says = "each symbol once",
                make = function () Lync.str.alphabet ("aa", 1, 2) end,
            },
            {
                what = "a newest stream at no rate",
                says = "takes a rate above zero",
                make = function () fine ():newest (0) end,
            },
        })
    end),
}
