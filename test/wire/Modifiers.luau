--!strict
--!optimize 2
-- What a caller layers on a codec: applied to the value, and never to the bytes.

local Lync = require ("@src")
local Types = require ("@src/Types")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")
local Turns = require ("@test/harness/Turns")

-- Constants -----------------------------------------------------------

const DEPTH = Generate.DEEP

-- A check that lets everything through, which is the half of a validate that changes nothing.
const PASSES: (any, Types.ValidateContext) -> string? = function () return nil end

-- The value the chain cases carry, and a codec that holds it in seven bits.
const CARRIED = 7
const HOLDS = Lync.int (0, 100)

-- Private -------------------------------------------------------------

--[[
    The one transform pair this file uses. It works for a value of any kind because it holds what it
    is given rather than looking at it, which is also what makes it visible: a lift that ran leaves
    a table where the wire carried a number, and one that did not leaves the number.
]]
local function wrap (value: any): any return { held = value } end
local function unwrap (held: any): any return held.held end

-- A check that turns everything away, with the reason it gives.
local function rejecting (why: string): (any, Types.ValidateContext) -> string?
    return function () return why end
end

--[[
    Every kind the vocabulary spells, at the simplest shape it has, with a value of that shape.
    Simplest rather than drawn, because what varies here is the wrapper and not the value: `as`
    holds whatever it is handed and a validate is a predicate over it, so a kind reached once is a
    kind reached, and ten thousand draws would be ten thousand instances of one claim.
]]
local function eachKind (run: (string, any, any) -> ())
    for _, at in Generate.KINDS do
        local shape = Generate.among (Rng.replay ({}), { at }, DEPTH)
        run (at, Generate.codec (shape), Generate.value (shape, Rng.replay ({})))
    end
end

-- Public --------------------------------------------------------------

return {
    --[[
        A modifier moves no layout. Neither may move a width or a promise of fixedness, and both
        would be believed if they did, since a word plan resolves from `fixed` and a frame reserves
        its room from `maxBytes`.
    ]]
    Harness.property ("codec.modifier-free", "kinds", function (rng: Rng.Rng)
        local shape = Generate.shape (rng, DEPTH)
        local base = Generate.codec (shape)

        local layered = {
            { of = "as", codec = base:as (wrap, unwrap) },
            { of = "validate", codec = base:validate (PASSES) },
        }

        local function alone (was: any, now: any, what: string)
            local wide = `{what} is {now.maxBytes} bytes of {was.maxBytes}`
            Expect.holds (now.maxBytes == was.maxBytes, wide)
            Expect.holds (now.fixed == was.fixed, `{what} is fixed {tostring (now.fixed)}`)
        end

        local bare = Turns.built (base)
        local nested = Turns.built (Lync.struct ({ f = base, keep = Lync.bool () }))

        for _, entry in layered do
            alone (bare, Turns.built (entry.codec), `{shape.at} under {entry.of}`)

            local held = Lync.struct ({ f = entry.codec, keep = Lync.bool () })
            alone (nested, Turns.built (held), `{shape.at} under {entry.of} in a struct`)
        end
    end),

    --[[
        `from` runs before the encode. The bytes a wrapped codec writes for a wrapped value are the
        bytes the codec beneath writes for the value inside, which is the whole of what "transforms
        never touch the wire" means from the writing side.
    ]]
    Harness.case ("codec.as-lowers", function ()
        eachKind (function (at: string, base: any, value: any)
            local of = Turns.built (base:as (wrap, unwrap))
            local plain = Turns.built (base)

            local got, want = Turns.text (of, wrap (value)), Turns.text (plain, value)
            if got == want then return end

            if #got ~= #want then
                Expect.holds (false, `{at} wrote {#got} bytes under as, and {#want} beneath it`)
                return
            end
            Expect.holds (false, `{at} wrote {#got} different bytes under as`)
        end)
    end),

    --[[
        `to` runs after the decode. What comes back is the lift applied to what the codec beneath
        answered, which is the same claim from the reading side and the one that says the two halves
        of a pair meet.
    ]]
    Harness.case ("codec.as-lifts", function ()
        eachKind (function (at: string, base: any, value: any)
            local plain = Turns.built (base)
            local of = Turns.built (base:as (wrap, unwrap))

            local bytes, size = Turns.wrote (plain, value)
            Expect.equal (Turns.read (of, bytes, size), wrap (Turns.read (plain, bytes, size)))
        end)
    end),

    --[[
        A check that answers nothing changes nothing. This is the case a caller writes far more
        often than the rejecting one, because a validate holds an invariant that almost always
        holds, and a wrapper that dropped a value it accepted would be a library losing traffic on
        its own quiet path.
    ]]
    Harness.case ("codec.validate-accepts", function ()
        eachKind (function (at: string, base: any, value: any)
            local plain = Turns.built (base)
            local of = Turns.built (base:validate (PASSES))

            local bytes, size = Turns.wrote (plain, value)
            Expect.equal (Turns.read (of, bytes, size), Turns.read (plain, bytes, size))
        end)
    end),

    --[[
        A validate is a decode-time check, so a value one would turn away still encodes, and encodes
        to the bytes it would have without it. The rule is what lets a check speak about the sender:
        a rate limit reads `ctx.last` and an ownership test reads `ctx.player`, and neither exists
        on the side doing the writing.
    ]]
    Harness.case ("codec.validate-decode-only", function ()
        eachKind (function (at: string, base: any, value: any)
            local plain = Turns.built (base)
            local of = Turns.built (base:validate (rejecting ("turned away")))

            local got, want = Turns.text (of, value), Turns.text (plain, value)
            Expect.holds (got == want, `{at} wrote different bytes under a validate`)

            local bytes, size = Turns.wrote (plain, value)
            Expect.throws (function () Turns.read (of, bytes, size) end)
        end)
    end),

    --[[
        Two checks on one chain, both turning the value away, and the first declared is the one
        reported. A caller greps their schema for that reason, so a chain reporting the last sends
        them to the wrong line.
    ]]
    Harness.case ("codec.validate-first-wins", function ()
        local bytes = (Turns.wrote (Turns.built (HOLDS), CARRIED))

        local function raised (first: string, second: string): any
            local of =
                Turns.built (HOLDS:validate (rejecting (first)):validate (rejecting (second)))
            local ok, thrown = pcall (of.read, bytes, 0, Turns.CTX)

            Expect.holds (not ok, `a chain rejecting {first} then {second} answered`)
            return thrown
        end

        local held = raised ("alpha", "beta")
        Expect.holds (Expect.alike (held, raised ("alpha", "gamma")), "the second reason decided")
        Expect.holds (not Expect.alike (held, raised ("delta", "beta")), "the first did not")
    end),

    --[[
        A chain applies every link at the position it was declared. A check after an `as` reads
        the lifted value and one before it reads what the wire carried, so a chain that reordered
        itself would hand a caller a table where they expected a number. Both orders are asked and
        what each check saw is recorded, since a chain running neither would still answer right.
    ]]
    Harness.case ("codec.modifier-chain", function ()
        local bytes, size = Turns.wrote (Turns.built (HOLDS), CARRIED)

        local seen: any = nil
        local function watch (value: any): string?
            seen = value
            return nil
        end

        local after = Turns.built (HOLDS:as (wrap, unwrap):validate (watch))
        seen = nil
        Expect.equal (Turns.read (after, bytes, size), wrap (CARRIED))
        Expect.equal (seen, wrap (CARRIED))

        local before = Turns.built (HOLDS:validate (watch):as (wrap, unwrap))
        seen = nil
        Expect.equal (Turns.read (before, bytes, size), wrap (CARRIED))
        Expect.equal (seen, CARRIED)
    end),

    --[[
        A check on a field of a record inside a record. A word dissolves the records it holds into
        one flat run of leaves, so reaching the value a check is about means walking back out
        through every key it was nested under, innermost last. A walk that stops one short, or runs
        the other way round, hands the check some other field's value and turns the frame away.
    ]]
    Harness.case ("codec.validate-nested", function ()
        local seen: { number } = {}
        local given: { Types.ValidateContext } = {}

        local watching = function (value: number, ctx: Types.ValidateContext): string?
            table.insert (seen, value)
            table.insert (given, ctx)
            return nil
        end

        local of = Turns.built (Lync.struct ({
            top = Lync.int (0, 100),
            inner = Lync.struct ({
                mid = Lync.int (0, 100),
                deep = Lync.struct ({ leaf = Lync.int (0, 100):validate (watching) }),
            }),
        }))

        local value = { top = 1, inner = { mid = 2, deep = { leaf = 3 } } }
        local bytes, size = Turns.wrote (of, value)

        Expect.equal (Turns.read (of, bytes, size), value)
        Expect.equal (seen, { 3 })
        Expect.holds (given[1] ~= nil, "a check two records deep was handed no context")
    end),

    --[[
        Two checks at two depths, each turning its own value away, and what each refusal says it
        was about. A refusal carries the path it happened at so a caller is sent to the line they
        wrote, and one carrying nothing, or carrying the same nothing as the other, leaves them
        with a turned-away frame and no field to look at.
    ]]
    Harness.case ("codec.validate-nested-names-where", function ()
        local function refusing (): (any, Types.ValidateContext) -> string?
            return function (): string? return "turned away" end
        end

        local function pathOf (codec: any, value: any): number
            local of = Turns.built (codec)
            local bytes, size = Turns.wrote (of, value)

            local ok, caught = pcall (Turns.read, of, bytes, size)
            Expect.holds (not ok, "a checked field was taken rather than turned away")
            Expect.holds (type (caught) == "table", `it threw {tostring (caught)}`)

            return ((caught :: any).facts :: any).pathId
        end

        local shallow =
            pathOf (Lync.struct ({ near = Lync.int (0, 100):validate (refusing ()) }), { near = 1 })
        local deep = pathOf (
            Lync.struct ({
                inner = Lync.struct ({ far = Lync.int (0, 100):validate (refusing ()) }),
            }),
            { inner = { far = 1 } }
        )

        Expect.holds (shallow ~= 0 and deep ~= 0, "a turned value said it was nowhere")
        Expect.holds (shallow ~= deep, `two fields were turned away under one path {shallow}`)
    end),

    --[[
        A check on an optional, run once for the value and not at all for the bit saying it is
        there. A presence bit is the frame answering whether a value follows rather than a value a
        caller declared anything about, so a check reaching it is asked about a truth the schema
        never mentions, and a caller counting their own calls sees one they did not make.
    ]]
    Harness.case ("codec.validate-runs-once-under-an-optional", function ()
        local ran = 0
        local of = Turns.built (Lync.optional (Lync.int (0, 3):validate (function (): string?
            ran += 1
            return nil
        end)))

        local bytes, size = Turns.wrote (of, 2)

        ran = 0
        Expect.equal (Turns.read (of, bytes, size), 2)
        Expect.equal (ran, 1)

        local absent, held = Turns.wrote (of, nil)

        ran = 0
        Expect.equal (Turns.read (of, absent, held), nil)
        Expect.equal (ran, 0)
    end),

    --[[
        Two optionals in one record, each reading the bit that is its own. The bits sit together
        ahead of the values a record carries, so a field reading the first of them answers whatever
        the field before it said, and a record where one is there and the other is not comes back
        with both or neither.
    ]]
    Harness.case ("codec.two-optionals-read-their-own-bits", function ()
        local of = Turns.built (Lync.struct ({
            near = Lync.optional (Lync.int (0, 3)),
            far = Lync.optional (Lync.int (0, 3)),
        }))

        for _, one in
            { { near = 1, far = 2 }, { near = 1 }, { far = 2 }, {} } :: { { [string]: number } }
        do
            local bytes, size = Turns.wrote (of, one)
            local back = Turns.read (of, bytes, size)

            Expect.equal (back.near, one.near)
            Expect.equal (back.far, one.far)
        end
    end),

    --[[
        A vector declared over a component codec, which is what its components are rather than the
        floats a vector is otherwise. A caller writing one is asking for three of what they named,
        so answering floats is three fields of thirty two bits where they declared a handful.
    ]]
    Harness.case ("codec.vector-takes-its-component", function ()
        local plain = Turns.built (Lync.vec3 ())
        local held = Turns.built (Lync.vec3 (Lync.int (0, 3)))

        Expect.holds (
            held.maxBytes < plain.maxBytes,
            `a vector of components cost {held.maxBytes} where floats cost {plain.maxBytes}`
        )
    end),
}
