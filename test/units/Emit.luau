--!strict
--!optimize 2
-- The emitter as a whole: a lowered tree to one pair, and checks collected on the way back up.

local Base = require("@src/codec/Base")
local Catalog = require("@src/kernel/Catalog")
local Codecs = require("@src/codec")
local Emit = require("@src/shape/emit")
local Ir = require("@src/shape/Ir")
local Lower = require("@src/shape/Lower")
local Serial = require("@src/shape/Serial")
local Types = require("@src/Types")

local Expect = require("@test/harness/Expect")
local Harness = require("@test/harness")

local ROOM = 512
local CTX: Types.ValidateContext = table.freeze({ player = nil, now = 7, last = nil })

type Built = { write: Ir.Write, read: Ir.Read, paths: Serial.Interner, side: Ir.Sidecar }

local function built(of: any): Built
    local paths, expected = Serial.interner(), Serial.interner()
    local shape = Lower.of(Base.cell(of), "root", { paths = paths, expected = expected })
    local side: Ir.Sidecar = { refs = {}, slotOf = {}, bears = false }
    local write, read = Emit.root(shape, { paths = paths, expected = expected, sidecar = side })
    return { write = write, read = read, paths = paths, side = side }
end

local function through(of: Built, value: any): any
    local b = buffer.create(ROOM)
    local after = of.write(b, 0, value)
    local got, back = of.read(b, 0, CTX)
    Expect.equal(got, after)
    return back
end

-- What a read of the value rejected under, and the facts it carried.
local function dropped(of: Built, value: any): (Catalog.Code?, any)
    local b = buffer.create(ROOM)
    of.write(b, 0, value)
    local ok, why = pcall(of.read, b, 0, CTX)
    if ok then return nil, nil end
    return (why :: any).code, (why :: any).facts
end

local function above(top: number): Base.Validate
    return function(value: any): string?
        return if value > top then `above {top}` else nil
    end
end

local EVERYTHING = Codecs.struct({
    hp = Codecs.int(0, 100),
    alive = Codecs.bool(),
    name = Codecs.str(0, 8),
    tags = Codecs.array(Codecs.enum({ "a", "b", "c" }), 0, 4),
    scores = Codecs.map(Codecs.str(1, 4), Codecs.int(0, 10), 0, 4),
    maybe = Codecs.optional(Codecs.vec3()),
    at = Codecs.cframe(Codecs.vec3(), Codecs.rotation.quat(1)),
    kind = Codecs.tagged("kind", {
        hit = Codecs.struct({ amount = Codecs.int(0, 9) }),
        say = Codecs.struct({ text = Codecs.str(0, 4) }),
    }),
    who = Codecs.inst("BasePart"),
    inner = Codecs.struct({ near = Codecs.bool(), far = Codecs.f32() }),
})

return {
    -- Every kind of node under one root, out and back through the one pair.
    Harness.case("emit.everything", function()
        local of = built(EVERYTHING)
        local part = Instance.new("Part")
        local value: any = {
            hp = 77,
            alive = true,
            name = "kraken",
            tags = { "c", "a" },
            scores = { one = 1, two = 2 },
            maybe = Vector3.new(1, 2, 3),
            at = CFrame.new(4, 5, 6),
            kind = { kind = "say", text = "hi" },
            who = part,
            inner = { near = false, far = 0.5 },
        }
        local back = through(of, value)
        Expect.equal(back.who, part)
        back.who = nil
        value.who = nil
        Expect.holds(back.at.Position:FuzzyEq(value.at.Position), `at came back {back.at}`)
        back.at = nil
        value.at = nil
        Expect.equal(back, value)
        Expect.equal(of.side.bears, true)
    end),

    -- A check turns a value away where it is read, under the code and the reason, and never
    -- moves what is written.
    Harness.case("emit.validate", function()
        local plain = built(Codecs.int(0, 100))
        local of = built(Codecs.int(0, 100):validate(above(50)))
        Expect.equal(through(of, 50), 50)
        local b, other = buffer.create(ROOM), buffer.create(ROOM)
        Expect.equal(of.write(b, 0, 60), plain.write(other, 0, 60))
        Expect.equal(buffer.readu8(b, 0), buffer.readu8(other, 0))

        local code, facts = dropped(of, 60)
        Expect.equal(code, Catalog.VALIDATE)
        Expect.equal(facts.reason, "above 50")
        Expect.equal(of.paths.texts[facts.pathId], "root")
        Expect.equal(facts.at, 1)

        -- The context reaches the check as it was handed to the read.
        local seen: any = nil
        local watching = built(Codecs.int(0, 100):validate(function(_v: any, ctx: any)
            seen = ctx
            return nil
        end))
        through(watching, 1)
        Expect.equal(seen, CTX)
    end),

    -- Two checks on one chain, both turning the value away, and the first declared is reported.
    Harness.case("emit.validate-first-wins", function()
        local function reason(first: string, second: string): string
            local of = built(Codecs.int(0, 9)
                :validate(function()
                    return first
                end)
                :validate(function()
                    return second
                end))
            local _, facts = dropped(of, 1)
            return facts.reason
        end
        Expect.equal(reason("alpha", "beta"), "alpha")
        Expect.equal(reason("delta", "beta"), "delta")
    end),

    -- A check on a field packed into a word is collected once the record is whole, naming the
    -- field's own path, through a dissolved record as well as on the record itself.
    Harness.case("emit.validate-in-a-word", function()
        local of = built(Codecs.struct({
            hp = Codecs.int(0, 100):validate(above(50)),
            inner = Codecs.struct({ far = Codecs.int(0, 7):validate(above(3)) }),
            name = Codecs.str(0, 4),
        }))
        local fine = { hp = 10, inner = { far = 1 }, name = "ok" }
        Expect.equal(through(of, fine), fine)

        local code, facts = dropped(of, { hp = 60, inner = { far = 1 }, name = "ok" })
        Expect.equal(code, Catalog.VALIDATE)
        Expect.equal(of.paths.texts[facts.pathId], "root.hp")
        code, facts = dropped(of, { hp = 1, inner = { far = 7 }, name = "ok" })
        Expect.equal(code, Catalog.VALIDATE)
        Expect.equal(of.paths.texts[facts.pathId], "root.inner.far")

        -- A reason parked by one payload never leaks into the next.
        Expect.equal(through(of, fine), fine)
    end),
}
