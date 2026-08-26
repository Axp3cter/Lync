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
}
