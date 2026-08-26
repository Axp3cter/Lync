--!strict
--!optimize 2
--[[
    The shape factory held to reaching its whole vocabulary, which the kind matrix assumes it does.
]]

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    Draws a check takes before reading what came out. A shape is picked from a list of thirty, so
    this is enough for every one of them many times over and a kind that never appears is one the
    factory cannot reach rather than one it did not get round to.
]]
const DRAWS = 2000

-- Fixed, so a red is the factory having changed rather than a run having been unlucky.
const SEED = 20260825

-- Deep enough for a composite to hold a composite, which is what `DEEP` is the one home of.
const DEEP = Generate.DEEP

-- Bytes a corruption is handed, which is what it is for: a frame, rather than a shape's own text.
const RUN = 24

-- Private -------------------------------------------------------------

-- Every kind a call named over the draws above, by the name a shape carries.
local function reached (call: (Rng.Rng) -> Generate.Shape): { [string]: boolean }
    local of = Rng.new (SEED)
    local seen: { [string]: boolean } = {}

    for _ = 1, DRAWS do
        seen[call (of).at] = true
    end
    return seen
end

-- Every kind standing anywhere in a shape, so a composite answers for what it holds as well.
local function within (shape: Generate.Shape, into: { [string]: boolean })
    into[shape.at] = true
    for _, held in shape.of do
        within (held, into)
    end
end

-- Public --------------------------------------------------------------

return {
    --[[
        The claim the kind matrix rests on. A factory answering one constructor makes ten thousand
        cases into one, and the vocabulary it is held to is its own published list rather than a
        second copy written here.
    ]]
    Harness.case ("generate.among-reaches-every-kind", function ()
        local seen = reached (function (of) return Generate.among (of, Generate.KINDS, DEEP) end)

        for _, kind in Generate.KINDS do
            Expect.holds (seen[kind] == true, `{DRAWS} draws never answered {kind}`)
        end
    end),

    -- And answers nothing that is not in the list it was handed.
    Harness.case ("generate.among-stays-in-its-list", function ()
        local held: { [string]: boolean } = {}
        for _, kind in Generate.KEYED do
            held[kind] = true
        end

        local seen = reached (function (of) return Generate.among (of, Generate.KEYED, DEEP) end)
        for kind in seen do
            Expect.holds (held[kind] == true, `a draw from the keyed list answered {kind}`)
        end
    end),

    --[[
        The constructors this factory deliberately never builds. Each is left out for its own reason
        and the list is the one home of that, so a draw reaching one is the list gone stale.
    ]]
    Harness.case ("generate.leaves-the-ungenerated-alone", function ()
        local skipped: { [string]: boolean } = {}
        for _, kind in Generate.UNGENERATED do
            skipped[kind] = true
        end

        local of = Rng.new (SEED)
        for _ = 1, DRAWS do
            local held: { [string]: boolean } = {}
            within (Generate.shape (of, DEEP), held)

            for kind in held do
                Expect.holds (not skipped[kind], `a drawn shape reached {kind}`)
            end
        end
    end),

    --[[
        A shape drawn at depth reaches a composite holding a composite. A factory that answered
        leaves only would pass every roundtrip there is and ask nothing about nesting.
    ]]
    Harness.case ("generate.reaches-a-nested-composite", function ()
        local of = Rng.new (SEED)
        local deepest = 0

        for _ = 1, DRAWS do
            local function depth (shape: Generate.Shape): number
                local most = 0
                for _, held in shape.of do
                    most = math.max (most, depth (held))
                end
                return most + 1
            end
            deepest = math.max (deepest, depth (Generate.shape (of, DEEP)))
        end

        Expect.holds (deepest >= 3, `{DRAWS} draws reached a depth of {deepest}`)
    end),

    --[[
        What a shape is for besides its name: a value inside its domain and one a step outside.
        Whether the one encodes and the other does not is a claim about encoding and is asked of
        it. What is asked here is that the factory draws two different things for the two.
    ]]
    Harness.case ("generate.values-differ-inside-and-out", function ()
        local of = Rng.new (SEED)

        for _ = 1, DRAWS do
            local shape = Generate.among (of, Generate.KINDS, 0)
            if shape.at == Generate.TOTAL then continue end

            local inside = Generate.value (shape, of)
            local outside = Generate.outside (shape, of)
            Expect.holds (
                not Expect.alike (inside, outside),
                `{shape.at} drew one value for inside and outside`
            )
        end
    end),

    -- A record is a struct with fields in it, which is what a set replicates.
    Harness.case ("generate.record-has-fields", function ()
        local of = Rng.new (SEED)

        for _ = 1, DRAWS do
            local shape = Generate.record (of)
            Expect.equal (shape.at, "struct")
            Expect.holds (#shape.names > 0, "a drawn record carries no fields")
            Expect.equal (#shape.names, #shape.of)
        end
    end),

    --[[
        The curated shapes, which are the ones a random draw is unlikely to reach: the deepest
        nesting, the widest struct, the all-optional, the sixty-four-field worst case.
    ]]
    Harness.case ("generate.adversaries-are-distinct", function ()
        local held = Generate.adversaries ()
        Expect.holds (#held > 0, "the curated shapes are none")

        local named: { [string]: boolean } = {}
        for _, one in held do
            Expect.holds (not named[one.name], `{one.name} is named twice`)
            named[one.name] = true
        end
    end),

    --[[
        A corruption reaches every way it has of making one. Cutting nothing off the end is a legal
        way and answers the text it was handed, so what is wrong is not one draw coming back whole
        but a factory that only ever answers that.
    ]]
    Harness.case ("generate.corrupted-reaches-its-ways", function ()
        local of = Rng.new (SEED)
        local ways: { [string]: boolean } = {}
        local moved = false

        for _ = 1, DRAWS do
            local held = Rng.bytes (of, RUN)
            local was = buffer.readstring (held, 0, RUN)
            local now, way =
                Generate.corrupted (of, was, buffer.readstring (Rng.bytes (of, RUN), 0, RUN))

            ways[way] = true
            if now ~= was then moved = true end
        end

        Expect.holds (moved, `{DRAWS} corruptions all came back whole`)
        for _, way in { "cut", "flip", "swap", "splice" } do
            Expect.holds (ways[way] == true, `{DRAWS} corruptions never {way}`)
        end
    end),
}
