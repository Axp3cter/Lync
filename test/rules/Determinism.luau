--!strict
--!optimize 2
-- The first law: a schema's identity is a function of the schema and of nothing else.

local Codecs = require("@src/codec")
local Compile = require("@src/shape/Compile")
local Packet = require("@src/api/Packet")
local Serial = require("@src/shape/Serial")
local Wide = require("@src/kernel/Wide")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

-- The namespace every build here is made under, which is part of what is hashed.
local UNDER = "determinism"

-- Names in the two orders a caller could write them. Enum and bitfield names are lists, so their
-- order is the caller's and the one place a reordering can be performed exactly.
local NAMES = table.freeze({ "alpha", "beta", "gamma", "delta" })
local REVERSED = table.freeze({ "delta", "gamma", "beta", "alpha" })

-- Field names a record is built from, in the two orders they are inserted in.
local FIELDS = table.freeze({ "one", "two", "three", "four", "five" })

-- Private -------------------------------------------------------------

local function reversed(of: { string }): { string }
    local out = table.create(#of) :: { string }
    for index = #of, 1, -1 do
        table.insert(out, of[index])
    end
    return out
end

-- A record of the given field names, every field the same codec so the names are the only thing
-- that differs between two of them.
local function record(order: { string }): any
    local of = {}
    for _, name in order do
        of[name] = Codecs.bool()
    end
    return Codecs.struct(of)
end

-- A union of the given variant names, each a record of one field under the same name.
local function variants(order: { string }): any
    local of = {}
    for _, name in order do
        of[name] = Codecs.struct({ [name] = Codecs.bool() })
    end
    return Codecs.tagged("kind", of)
end

-- Where each name is written in a descriptor, as the position of its binding.
local function placed(text: string, name: string): number?
    local at = string.find(text, `"{name}"=`, 1, true)
    if at ~= nil then return at end
    return (string.find(text, `{name}=`, 1, true))
end

-- Every name written in the order the names sort in, which is what a canonical walk means for
-- anything a caller declared as table keys.
local function sorted(what: string, text: string, names: { string })
    local order = table.clone(names)
    table.sort(order)
    local last = 0
    for _, name in order do
        local at = placed(text, name)
        Expect.holds(at ~= nil, `{what} does not write {name}: {text}`)
        Expect.holds((at :: number) >= last, `{what} writes {name} out of order: {text}`)
        last = at :: number
    end
end

-- The definitions of a namespace, inserted in the order given.
local function namespace(order: { string }, build: (string) -> any): { [string]: any }
    local out = {}
    for _, name in order do
        out[name] = build(name)
    end
    return out
end

local function built(specs: { [string]: any }): any
    return Compile.build(UNDER, specs)
end

local function lone(codec: any): any
    return built({ only = Packet.new(codec) })
end

-- Two builds of one schema, written two ways, held to one identity. The descriptor is compared
-- before the hash, since a difference in the text says which part of the walk moved.
local function agree(what: string, left: any, right: any)
    Expect.holds(
        left.descriptor == right.descriptor,
        `{what}\n  {left.descriptor}\n  {right.descriptor}`
    )
    local hashes = `{Wide.toHex(left.hash)} and {Wide.toHex(right.hash)}`
    Expect.holds(Wide.eq(left.hash, right.hash), `{what} agreed on text and not on hash: {hashes}`)
end

-- Public --------------------------------------------------------------

return {
    -- One schema compiled twice is one identity, which is the weakest form of the law and the one
    -- everything else rests on.
    Harness.case("det.two-compiles", function()
        local specs = namespace(NAMES, function(name: string): any
            return Packet.new(Codecs.struct({ [name] = Codecs.bool(), at = Codecs.f32() }))
        end)
        local once, twice = built(specs), built(specs)
        agree("two compiles of one schema", once, twice)

        local folded = Wide.toHex(Serial.hash(once.descriptor))
        local carried = Wide.toHex(once.hash)
        Expect.holds(
            folded == carried,
            `the schema carries {carried} and its text folds to {folded}`
        )

        local other = lone(Codecs.f32())
        Expect.holds(other.descriptor ~= once.descriptor, "two schemas wrote one descriptor")
        Expect.holds(not Wide.eq(other.hash, once.hash), `two schemas hashed alike at {carried}`)
    end),

    -- Reordering the source moves nothing, in the five places an order can leak.
    Harness.case("det.source-order", function()
        local function flag(): any
            return Packet.new(Codecs.bool())
        end
        local defs = built(namespace(REVERSED, flag))
        sorted("a namespace", defs.descriptor, NAMES)
        agree("definitions inserted in two orders", built(namespace(NAMES, flag)), defs)

        local fields = lone(record(reversed(FIELDS)))
        sorted("a record", fields.descriptor, FIELDS)
        agree("a record's fields inserted in two orders", lone(record(FIELDS)), fields)

        local tagged = lone(variants(REVERSED))
        sorted("a tagged", tagged.descriptor, NAMES)
        agree("a tagged's variants inserted in two orders", lone(variants(NAMES)), tagged)

        agree(
            "an enum's names written in two orders",
            lone(Codecs.enum(NAMES)),
            lone(Codecs.enum(REVERSED))
        )
        agree(
            "a bitfield's names written in two orders",
            lone(Codecs.bitfield(NAMES)),
            lone(Codecs.bitfield(REVERSED))
        )
    end),

    -- Behaviour is not layout and the descriptor holds layout, so two schemas differing only in
    -- what a validate rejects hash as one. The count is in, since a validate is a decode-time
    -- check the other machine runs too.
    Harness.case("det.behaviour-excluded", function()
        local base = Codecs.int(0, 100)
        local function passes(): string?
            return nil
        end
        local function refuses(): string?
            return "no"
        end
        local function same(v: number): number
            return v
        end
        local function negated(v: number): number
            return -v
        end

        agree(
            "two validates with different bodies",
            lone(base:validate(passes)),
            lone(base:validate(refuses))
        )
        agree(
            "two transforms with different maps",
            lone(base:as(same, same)),
            lone(base:as(negated, negated))
        )

        local plain = lone(base)
        local checked = lone(base:validate(passes))
        Expect.holds(
            plain.descriptor ~= checked.descriptor,
            `a validate left no mark: {plain.descriptor}`
        )
        Expect.holds(not Wide.eq(plain.hash, checked.hash), "a validate left the hash alone")
    end),

    -- Any namespace a caller can build, built twice: whether the walk is order-free everywhere,
    -- or only where somebody remembered to look.
    Harness.property("det.any-schema", "schemas", function(rng: Rng.Rng)
        local specs = Generate.definitions(rng)
        local once, twice = built(specs), built(specs)
        agree("a drawn namespace built twice", once, twice)
        Expect.equal(Wide.toHex(Serial.hash(once.descriptor)), Wide.toHex(once.hash))
    end),
}
