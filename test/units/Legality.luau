--!strict
--!optimize 2
--[[
    What a constructor will take: the tests every one of them makes of a parameter or a child.
]]

local Base = require ("@src/codec/Base")
local Legality = require ("@src/codec/Legality")
local Lync = require ("@src")
local Scalars = require ("@src/codec/Scalars")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- The kind and the place a refusal names, which every one of these tests is handed.
const KIND: Base.Kind = "array"
const AT = "its element"

-- A legal count range, so a case about an illegal one has something to hold it against.
const LOW = 0
const HIGH = 4

-- A whole turn, read from the module that declares it rather than spelled a second time here.
const TURN = Scalars.TURN

-- A precision an ordinary schema asks for, which is inside the bound at both ends.
const FINE = 1

-- Types ---------------------------------------------------------------

type Numbers = { number }

-- One constructor that takes an angular precision, named so a failure says which took a bad one.
type Precise = { read what: string, read make: (number) -> any }

-- Private -------------------------------------------------------------

-- The numbers that are on the line, and the four readings that are no place on one at all.
const ON_THE_LINE: Numbers = table.freeze ({ 0, 1, -1, 0.5, -0.5, 2 ^ 52, -(2 ^ 52) })
const NOWHERE: Numbers = table.freeze ({ 0 / 0, 1 / 0, -1 / 0, -(0 / 0) })

-- Every constructor that takes a precision in degrees, which is one bound spelled in two modules.
const PRECISE: { Precise } = table.freeze ({
    table.freeze ({ what = "angle", make = function (of: number): any return Lync.angle (of) end }),
    table.freeze ({
        what = "vec3.unit",
        make = function (of: number): any return Lync.vec3.unit (of) end,
    }),
    table.freeze ({
        what = "rotation.axis",
        make = function (of: number): any return Lync.rotation.axis (Vector3.yAxis, of) end,
    }),
    table.freeze ({
        what = "rotation.direction",
        make = function (of: number): any return Lync.rotation.direction (of) end,
    }),
    table.freeze ({
        what = "rotation.quat",
        make = function (of: number): any return Lync.rotation.quat (of) end,
    }),
})

-- The words a refusal gave, or nothing where the call came back.
local function refused (call: () -> ()): string?
    local ok, thrown = pcall (call)
    return if ok then nil else tostring (thrown)
end

-- Public --------------------------------------------------------------

return {
    --[[
        A number on the line, asked of a numeric string as well as of a number. The string is the
        one a checker cannot stop and the arithmetic downstream would take, which
        is why the test starts by asking what it is rather than by comparing it.
    ]]
    Harness.case ("legality.finite", function ()
        for _, value in ON_THE_LINE do
            Expect.holds (Legality.finite (value), `{value} is a number and was refused`)
        end

        for _, value in NOWHERE do
            Expect.equal (Legality.finite (value), false)
        end

        for _, value in { "1", true, {}, nil } do
            Expect.equal (Legality.finite (value :: any), false)
        end
    end),

    --[[
        The property the pair of comparisons rests on, asked of itself before the test that rests
        on it. Held here because a reader can check a test against the rule and never against the
        platform, and it is the platform this half is about.
    ]]
    Harness.case ("legality.finite-refuses-no-number", function ()
        local held = 0 / 0

        -- Neither comparison holds against it, which is the property the pair rests on.
        Expect.equal (held > -math.huge, false)
        Expect.equal (held < math.huge, false)
        Expect.equal (Legality.finite (held), false)
    end),

    --[[
        Whole, and on the line with it. An infinity and a NaN both leave a NaN behind in the modulo,
        so the one test answers about both without either of them being named.
    ]]
    Harness.case ("legality.whole", function ()
        for _, value in { 0, 1, -1, 2 ^ 52, -(2 ^ 52) } do
            Expect.holds (Legality.whole (value), `{value} is whole and was refused`)
        end

        for _, value in { 0.5, -0.5, 1e-9 } do
            Expect.equal (Legality.whole (value), false)
        end

        for _, value in NOWHERE do
            Expect.equal (Legality.whole (value), false)
        end

        Expect.equal (Legality.whole ("2" :: any), false)
    end),

    --[[
        The three ranges a caller writes that are legal and read as though they might not be: a
        floor of none, a ceiling of none, and two bounds that meet. Asked because each is a range
        somebody would guard against, and a guard on any of them would refuse a legal schema.
    ]]
    Harness.case ("legality.counts", function ()
        Legality.counts (KIND, 0, 0)
        Legality.counts (KIND, 0, HIGH)
        Legality.counts (KIND, HIGH, HIGH)
    end),

    --[[
        The three ways a count range is wrong, each with words that name which. A caller reading
        `takes whole bounds` and one reading `takes its bounds in order` are looking at two
        different mistakes, and one sentence for both would send half of them to the wrong line.
    ]]
    Harness.case ("legality.counts-refuses", function ()
        local fractional = refused (function () Legality.counts (KIND, 0, 1.5) end)
        Expect.holds (fractional ~= nil, "a fractional bound was taken")
        Expect.holds (string.find (fractional :: string, "whole bounds", 1, true) ~= nil, "it said")

        local below = refused (function () Legality.counts (KIND, -1, HIGH) end)
        Expect.holds (below ~= nil, "a bound below zero was taken")
        Expect.holds (string.find (below :: string, "from zero up", 1, true) ~= nil, "it said")

        local backwards = refused (function () Legality.counts (KIND, HIGH, LOW) end)
        Expect.holds (backwards ~= nil, "bounds the wrong way round were taken")
        Expect.holds (string.find (backwards :: string, "in order", 1, true) ~= nil, "it said")
    end),

    --[[
        What is not checked is how large a count may be. A bound past what a frame holds is a fact
        about the wire, and this layer cannot see the wire, so the start refuses that one and this
        takes it.
    ]]
    Harness.case ("legality.counts-takes-any-size", function ()
        Legality.counts (KIND, 0, 2 ^ 40)
        Legality.counts (KIND, 2 ^ 40, 2 ^ 40)
    end),

    --[[
        A child has to be a codec, and the refusal names what arrived. Asked with the value a
        caller meant to describe, since that is the thing they hand over by mistake.
    ]]
    Harness.case ("legality.codec", function ()
        Legality.codec (KIND, AT, Lync.bool ())
        Legality.codec (KIND, AT, Lync.int (LOW, HIGH))

        for _, value in { 1, "bool", true, {} } do
            local said = refused (function () Legality.codec (KIND, AT, value :: any) end)
            Expect.holds (said ~= nil, `{typeof (value)} was taken as a codec`)
            Expect.holds (string.find (said :: string, AT, 1, true) ~= nil, "it named no place")
            Expect.holds (string.find (said :: string, typeof (value), 1, true) ~= nil, "nor what")
        end
    end),

    --[[
        The child test, asked of what it takes and of the one thing it does not. Which children
        are refused and why is settled where the test lives, so what is held here is that the
        refusal happens at all and that the ordinary children go through untouched.
    ]]
    Harness.case ("legality.bare", function ()
        Legality.bare (KIND, AT, Lync.bool ())
        Legality.bare (KIND, AT, Lync.struct ({ a = Lync.bool () }))

        local maybe = Lync.optional (Lync.bool ())
        local said = refused (function () Legality.bare (KIND, AT, maybe) end)

        Expect.holds (said ~= nil, "an optional was taken where a slot is already absent")
        Expect.holds (string.find (said :: string, "no optional", 1, true) ~= nil, "it said none")
    end),

    --[[
        A bare child is a codec first, so the two refusals do not overlap and neither hides the
        other. Something that is no codec at all reaches the codec test rather than being asked
        whether it is an optional, which is a question about a value that has no kind.
    ]]
    Harness.case ("legality.bare-is-a-codec-first", function ()
        local said = refused (function () Legality.bare (KIND, AT, 1 :: any) end)

        Expect.holds (said ~= nil, "a number was taken as a bare child")
        Expect.holds (string.find (said :: string, "takes a codec", 1, true) ~= nil, "it said")
    end),

    --[[
        The angular precision bound at both of its ends, which is the one range in the vocabulary
        open at the bottom and closed at the top. A whole turn is one point and every reading
        decodes to zero, which is degenerate and is not wrong, and no precision at all is no grid.
    ]]
    Harness.case ("legality.precision-ends", function ()
        Lync.angle (TURN)
        Lync.angle (FINE)

        local turns = "takes a precision from zero to"
        Expect.throws (function () Lync.angle (0) end, turns)
        Expect.throws (function () Lync.angle (TURN + FINE) end, turns)
    end),

    --[[
        The same bound asked of every constructor that takes one. Four read it through one test and
        the fifth spells it itself, which is how the two could come apart, so what this holds is
        that a precision means the same thing wherever the surface takes one.
    ]]
    Harness.case ("legality.precision-everywhere", function ()
        for _, one in PRECISE do
            one.make (TURN)
            one.make (FINE)

            for _, bad in { 0, -FINE, TURN + FINE, 0 / 0, 1 / 0 } do
                local said = refused (function () one.make (bad) end)
                Expect.holds (said ~= nil, `{one.what} took a precision of {bad}`)
                local named = string.find (said :: string, "precision", 1, true) ~= nil
                Expect.holds (named, `{one.what} refused {bad} and said "{said}"`)
            end
        end
    end),

    --[[
        A struct field is the exception and asks for a codec rather than a bare one, because a
        record names what it is missing. So the surface takes an optional there and takes it nowhere
        else, which is the pair this asks about from the constructors themselves.
    ]]
    Harness.case ("legality.optional-where-a-record-names-it", function ()
        local maybe = Lync.optional (Lync.bool ())

        Lync.struct ({ held = maybe })

        Expect.throws (function () Lync.array (maybe, LOW, HIGH) end, "no optional for element")
        Expect.throws (
            function () Lync.map (Lync.int (LOW, HIGH), maybe, LOW, HIGH) end,
            "no optional for value"
        )
        Expect.throws (function () Lync.optional (maybe) end, "no optional for inner")
    end),
}
