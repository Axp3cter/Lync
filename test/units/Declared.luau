--!strict
--!optimize 2
--[[
    What a declaration has to be before a namespace will carry it, which is read off the shape a
    caller declared rather than off the codec under it. A codec legal on its own is what every one
    of these is built out of, so what is refused here is the declaration and not the codec.
]]

local Legality = require ("@src/shape/Legality")
local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Harness = require ("@test/harness")

-- Constants -----------------------------------------------------------

-- What a set is named by, which a refusal reads back so a caller is sent to their own line.
const SET = "roster"

-- A step a turn does not divide into a whole number of, which is what an angle may not take.
const ASKEW = 7

-- A name holding what a descriptor separates its own names with, which no definition may.
const MARKED = "holds;a;mark"

-- Where a declaration says it was written, which every refusal carries.
const AT = table.freeze ({ file = "Origin", line = 1 })

-- Private -------------------------------------------------------------

-- One set declared over the codec given, which is the whole of what a set is declared as.
local function replicating (of: any): any
    return { kind = "set" :: "set", of = of, keyField = nil, at = AT }
end

-- Public --------------------------------------------------------------

return {
    --[[
        A record of no fields, replicated. A set says what changed by naming fields, so one with
        none has nothing it could ever say and nothing a receiver could ever be told, and the
        empty struct under it is a legal codec that a packet would carry without complaint.
    ]]
    Harness.case ("declared.set-of-no-fields", function ()
        Legality.definition (SET, replicating (Lync.struct ({ held = Lync.bool () })))

        local said = Expect.throws (
            function () Legality.definition (SET, replicating (Lync.struct ({}))) end,
            "no fields"
        )

        Expect.holds (string.find (said, SET, 1, true) ~= nil, `it named no set: {said}`)
    end),

    --[[
        A field counted more finely than the grid it sits on can spell. An angle whose step does
        not divide a turn lands its last point somewhere other than the first, so two machines
        rounding the same reading would answer two indices, and a set is the one place that is a
        difference somebody reads rather than a value somebody sent.
    ]]
    Harness.case ("declared.set-of-an-imprecise-field", function ()
        local said = Expect.throws (
            function ()
                Legality.definition (SET, replicating (Lync.struct ({ spun = Lync.angle (ASKEW) })))
            end,
            "divide a turn"
        )

        Expect.holds (string.find (said, SET, 1, true) ~= nil, `it named no set: {said}`)
    end),

    --[[
        A definition named what a descriptor separates its own names with. What one machine writes
        its schema out as is what the other reads back to decide the two agree, so a name holding
        a separator is one the far side reads as two names and a schema the two never agree on.
        Read off the name rather than off what it was declared over, which every kind shares.
    ]]
    Harness.case ("declared.refuses-a-name-it-cannot-spell", function ()
        local held = replicating (Lync.struct ({ held = Lync.bool () }))
        Legality.definition (SET, held)

        local said = Expect.throws (
            function () Legality.definition (MARKED, held) end,
            "separates its own names with"
        )

        Expect.holds (string.find (said, MARKED, 1, true) ~= nil, `it named no definition: {said}`)
    end),
}
