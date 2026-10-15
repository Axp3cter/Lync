--!strict
--!optimize 2
-- What a caller layers on a codec: applied to the value, and never to the bytes.

local Codecs = require("@src/codec")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")
local Turns = require("@test/harness/Turns")

local DEPTH = Generate.DEEP

-- A check that lets everything through, which is the half of a validate that changes nothing.
local PASSES: (any, Types.ValidateContext) -> string? = function()
    return nil
end

-- The value the chain cases carry, and a codec that holds it in seven bits.
local CARRIED = 7
local HOLDS = Codecs.int(0, 100)

-- The one transform pair this file uses. It holds what it is given rather than looking at it,
-- which is also what makes it visible: a lift that ran leaves a table where the wire carried a
-- number.
local function wrap(value: any): any
    return { held = value }
end

local function unwrap(held: any): any
    return held.held
end

local function rejecting(why: string): (any, Types.ValidateContext) -> string?
    return function()
        return why
    end
end

-- Every kind at the simplest shape it has, with a value of that shape. What varies here is the
-- wrapper and not the value, so a kind reached once is a kind reached.
local function eachKind(run: (string, any, any) -> ())
    for _, at in Generate.KINDS do
        local shape = Generate.among(Rng.replay({}), { at }, DEPTH)
        run(at, Generate.codec(shape), Generate.value(shape, Rng.replay({})))
    end
end

return {
    -- A modifier moves no layout: neither the width nor the promise of fixedness, alone or in a
    -- record, since a word plan resolves from one and a frame reserves room from the other.
    Harness.property("codec.modifier-free", "kinds", function(rng: Rng.Rng)
        local shape = Generate.shape(rng, DEPTH)
        local base = Generate.codec(shape)
        local layered = {
            { of = "as", codec = base:as(wrap, unwrap) },
            { of = "validate", codec = base:validate(PASSES) },
        }
        local function alone(was: any, now: any, what: string)
            Expect.holds(
                now.maxBytes == was.maxBytes,
                `{what} is {now.maxBytes} bytes of {was.maxBytes}`
            )
            Expect.holds(now.fixed == was.fixed, `{what} is fixed {tostring(now.fixed)}`)
        end
        local bare = Turns.built(base)
        local nested = Turns.built(Codecs.struct({ f = base, keep = Codecs.bool() }))
        for _, entry in layered do
            alone(bare, Turns.built(entry.codec), `{shape.at} under {entry.of}`)
            local held = Codecs.struct({ f = entry.codec, keep = Codecs.bool() })
            alone(nested, Turns.built(held), `{shape.at} under {entry.of} in a struct`)
        end
    end),

    -- `from` runs before the encode and `to` after the decode: the bytes a wrapped codec writes
    -- for a wrapped value are the bytes beneath, and what comes back is the lift of what the codec
    -- beneath answered.
    Harness.case("codec.as-lowers-and-lifts", function()
        eachKind(function(at: string, base: any, value: any)
            local of = Turns.built(base:as(wrap, unwrap))
            local plain = Turns.built(base)
            local got, want = Turns.text(of, wrap(value)), Turns.text(plain, value)
            Expect.holds(got == want, `{at} wrote {#got} bytes under as against {#want} beneath it`)
            local bytes, size = Turns.wrote(plain, value)
            Expect.equal(Turns.read(of, bytes, size), wrap(Turns.read(plain, bytes, size)))
        end)
    end),

    -- A check that answers nothing changes nothing, and a validate is a decode-time check, so a
    -- value one would turn away still encodes to the same bytes and is refused only when read.
    Harness.case("codec.validate-decode-only", function()
        eachKind(function(at: string, base: any, value: any)
            local plain = Turns.built(base)
            local bytes, size = Turns.wrote(plain, value)
            local passing = Turns.built(base:validate(PASSES))
            Expect.equal(Turns.read(passing, bytes, size), Turns.read(plain, bytes, size))

            local of = Turns.built(base:validate(rejecting("turned away")))
            Expect.holds(
                Turns.text(of, value) == Turns.text(plain, value),
                `{at} wrote other bytes`
            )
            Expect.throws(function()
                Turns.read(of, bytes, size)
            end)
        end)
    end),

    -- Two checks on one chain both turning the value away, and the first declared is reported.
    Harness.case("codec.validate-first-wins", function()
        local bytes = (Turns.wrote(Turns.built(HOLDS), CARRIED))
        local function raised(first: string, second: string): any
            local of = Turns.built(HOLDS:validate(rejecting(first)):validate(rejecting(second)))
            local ok, thrown = pcall(of.read, bytes, 0, Turns.CTX)
            Expect.holds(not ok, `a chain rejecting {first} then {second} answered`)
            return thrown
        end
        local held = raised("alpha", "beta")
        Expect.holds(Expect.alike(held, raised("alpha", "gamma")), "the second reason decided")
        Expect.holds(not Expect.alike(held, raised("delta", "beta")), "the first did not")
    end),

    -- A chain applies every link at the position it was declared: a check after an `as` reads the
    -- lifted value and one before it reads what the wire carried.
    Harness.case("codec.modifier-chain", function()
        local bytes, size = Turns.wrote(Turns.built(HOLDS), CARRIED)
        local seen: any = nil
        local function watch(value: any): string?
            seen = value
            return nil
        end
        local after = Turns.built(HOLDS:as(wrap, unwrap):validate(watch))
        Expect.equal(Turns.read(after, bytes, size), wrap(CARRIED))
        Expect.equal(seen, wrap(CARRIED))
        seen = nil
        local before = Turns.built(HOLDS:validate(watch):as(wrap, unwrap))
        Expect.equal(Turns.read(before, bytes, size), wrap(CARRIED))
        Expect.equal(seen, CARRIED)
    end),

    -- A check on a field two records deep is handed that field's value and a context, and two
    -- checks at two depths refuse under paths of their own.
    Harness.case("codec.validate-nested", function()
        local seen: { number } = {}
        local given: { Types.ValidateContext } = {}
        local function watching(value: number, ctx: Types.ValidateContext): string?
            table.insert(seen, value)
            table.insert(given, ctx)
            return nil
        end
        local of = Turns.built(Codecs.struct({
            top = Codecs.int(0, 100),
            inner = Codecs.struct({
                mid = Codecs.int(0, 100),
                deep = Codecs.struct({ leaf = Codecs.int(0, 100):validate(watching) }),
            }),
        }))
        local value = { top = 1, inner = { mid = 2, deep = { leaf = 3 } } }
        local bytes, size = Turns.wrote(of, value)
        Expect.equal(Turns.read(of, bytes, size), value)
        Expect.equal(seen, { 3 })
        Expect.holds(given[1] ~= nil, "a check two records deep was handed no context")

        local function pathOf(codec: any, held: any): number
            local built = Turns.built(codec)
            local wrote, count = Turns.wrote(built, held)
            local ok, caught = pcall(Turns.read, built, wrote, count)
            Expect.holds(not ok, "a checked field was taken rather than turned away")
            Expect.holds(type(caught) == "table", `it threw {tostring(caught)}`)
            return ((caught :: any).facts :: any).pathId
        end
        local refusing = rejecting("turned away")
        local checked = Codecs.int(0, 100):validate(refusing)
        local shallow = pathOf(Codecs.struct({ near = checked }), { near = 1 })
        local deep = pathOf(
            Codecs.struct({ inner = Codecs.struct({ far = checked }) }),
            { inner = { far = 1 } }
        )
        Expect.holds(shallow ~= 0 and deep ~= 0, "a turned value said it was nowhere")
        Expect.holds(shallow ~= deep, `two fields were turned away under one path {shallow}`)
    end),

    -- A check on an optional runs once for the value and not at all for the presence bit, and two
    -- optionals in one record each read the bit that is their own.
    Harness.case("codec.optionals", function()
        local ran = 0
        local of = Turns.built(Codecs.optional(Codecs.int(0, 3):validate(function(): string?
            ran += 1
            return nil
        end)))
        local bytes, size = Turns.wrote(of, 2)
        ran = 0
        Expect.equal(Turns.read(of, bytes, size), 2)
        Expect.equal(ran, 1)
        local absent, held = Turns.wrote(of, nil)
        ran = 0
        Expect.equal(Turns.read(of, absent, held), nil)
        Expect.equal(ran, 0)

        local pair = Turns.built(Codecs.struct({
            near = Codecs.optional(Codecs.int(0, 3)),
            far = Codecs.optional(Codecs.int(0, 3)),
        }))
        for _, one in
            { { near = 1, far = 2 }, { near = 1 }, { far = 2 }, {} } :: { { [string]: number } }
        do
            local wrote, count = Turns.wrote(pair, one)
            local back = Turns.read(pair, wrote, count)
            Expect.equal(back.near, one.near)
            Expect.equal(back.far, one.far)
        end
    end),

    -- A vector declared over a component codec costs what three of that component cost, not three
    -- floats of thirty two bits.
    Harness.case("codec.vector-takes-its-component", function()
        local plain = Turns.built(Codecs.vec3())
        local held = Turns.built(Codecs.vec3(Codecs.int(0, 3)))
        Expect.holds(
            held.maxBytes < plain.maxBytes,
            `components cost {held.maxBytes} of {plain.maxBytes}`
        )
    end),
}
