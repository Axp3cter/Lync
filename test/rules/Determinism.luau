--!strict
--!optimize 2
-- The first law: a schema's identity is a function of the schema and of nothing else.

local Compile = require ("@src/shape/Compile")
local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Serial = require ("@src/shape/Serial")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")
local Wide = require ("@src/kernel/Wide")

-- Constants -----------------------------------------------------------

-- The namespace every build here is made under, which is part of what is hashed.
const UNDER = "determinism"

--[[
    Names in the two orders a caller could write them. Enum names and bitfield names are lists, so
    their order is the caller's and not a table's, which makes them the one place a reordering can
    be performed exactly rather than hoped for.
]]
const NAMES = table.freeze ({ "alpha", "beta", "gamma", "delta" })
const REVERSED = table.freeze ({ "delta", "gamma", "beta", "alpha" })

-- Field names a record is built from, in the two orders they are inserted in.
const FIELDS = table.freeze ({ "one", "two", "three", "four", "five" })

-- Private -------------------------------------------------------------

local function reversed (of: { string }): { string }
    local out = table.create (#of) :: { string }
    for index = #of, 1, -1 do
        table.insert (out, of[index])
    end
    return out
end

--[[
    A record of the given field names, every field the same codec so the names are the only thing
    that differs between two of them.
]]
local function record (order: { string }): any
    local of = {}
    for _, name in order do
        of[name] = Lync.bool ()
    end
    return Lync.struct (of)
end

--[[
    Where each name is written in a descriptor, as the position of its binding. A name that does not
    appear answers nothing, which reads as a fault at the line that asked.
]]
local function placed (text: string, name: string): number?
    local at = string.find (text, `"{name}"=`, 1, true)
    if at ~= nil then return at end
    return (string.find (text, `{name}=`, 1, true))
end

--[[
    Every name written in the order the names sort in, which is what a canonical walk means for
    anything a caller declared as table keys. Asked directly rather than by writing the schema
    twice, since this runtime walks a table by its keys and two insertions would walk alike.
]]
local function sorted (what: string, text: string, names: { string })
    local order = table.clone (names)
    table.sort (order)

    local last = 0
    for _, name in order do
        local at = placed (text, name)
        if at == nil then
            Expect.holds (false, `{what} does not write {name}: {text}`)
            return
        end
        if at < last then
            Expect.holds (false, `{what} writes {name} out of order: {text}`)
            return
        end
        last = at
    end
end

-- The definitions of a namespace, inserted in the order given.
local function namespace (order: { string }, build: (string) -> any): { [string]: any }
    local out = {}
    for _, name in order do
        out[name] = build (name)
    end
    return out
end

local function built (specs: { [string]: any }): any return Compile.build (UNDER, specs) end

--[[
    Two builds of one schema, written two ways, held to one identity. The descriptor is compared
    before the hash, since the hash is a fold of it and a difference in the text says which part of
    the walk moved. The digests go through `Wide.same`, an equals on two of them being a question
    about which table they are.
]]
local function agree (what: string, left: any, right: any)
    if left.descriptor ~= right.descriptor then
        Expect.holds (false, `{what}\n  {left.descriptor}\n  {right.descriptor}`)
        return
    end
    if Wide.same (left.hash, right.hash) then return end
    Expect.holds (
        false,
        `{what} agreed on text and not on hash: {Wide.text (left.hash)}`
            .. ` and {Wide.text (right.hash)}`
    )
end

-- Public --------------------------------------------------------------

return {
    --[[
        One schema compiled twice is one identity, which is the weakest form of the law and the one
        everything else rests on. A compiler consulting anything outside the schema fails here
        first.
    ]]
    Harness.case ("det.two-compiles", function ()
        local specs = namespace (
            NAMES,
            function (name)
                return Lync.packet (Lync.struct ({ [name] = Lync.bool (), at = Lync.f32 () }))
            end
        )

        local once, twice = built (specs), built (specs)
        agree ("two compiles of one schema", once, twice)

        local folded = Wide.text (Serial.hash (once.descriptor))
        local carried = Wide.text (once.hash)
        if folded ~= carried then
            Expect.holds (false, `the schema carries {carried} and its text folds to {folded}`)
            return
        end

        local other = built ({ lone = Lync.packet (Lync.f32 ()) })
        Expect.holds (other.descriptor ~= once.descriptor, "two schemas wrote one descriptor")
        if not Wide.same (other.hash, once.hash) then return end
        Expect.holds (false, `two schemas hashed alike at {carried}`)
    end),

    --[[
        Reordering the source moves nothing. Five orders can leak, and each is here because a walk
        that read it would be right until the day somebody rearranged a literal for readability and
        every client stopped joining.
    ]]
    Harness.case ("det.source-order", function ()
        local defs = built (namespace (REVERSED, function () return Lync.packet (Lync.bool ()) end))
        sorted ("a namespace", defs.descriptor, NAMES)
        agree (
            "definitions inserted in two orders",
            built (namespace (NAMES, function () return Lync.packet (Lync.bool ()) end)),
            defs
        )

        local fields = built ({ only = Lync.packet (record (reversed (FIELDS))) })
        sorted ("a record", fields.descriptor, FIELDS)
        agree (
            "a record's fields inserted in two orders",
            built ({ only = Lync.packet (record (FIELDS)) }),
            fields
        )

        local function variants (order: { string }): any
            local of = {}
            for _, name in order do
                of[name] = Lync.struct ({ [name] = Lync.bool () })
            end
            return Lync.tagged ("kind", of)
        end
        local tagged = built ({ only = Lync.packet (variants (REVERSED)) })
        sorted ("a tagged", tagged.descriptor, NAMES)
        agree (
            "a tagged's variants inserted in two orders",
            built ({ only = Lync.packet (variants (NAMES)) }),
            tagged
        )

        agree (
            "an enum's names written in two orders",
            built ({ only = Lync.packet (Lync.enum (NAMES)) }),
            built ({ only = Lync.packet (Lync.enum (REVERSED)) })
        )

        agree (
            "a bitfield's names written in two orders",
            built ({ only = Lync.packet (Lync.bitfield (NAMES)) }),
            built ({ only = Lync.packet (Lync.bitfield (REVERSED)) })
        )
    end),

    --[[
        Behaviour is not layout and the descriptor holds layout, so two schemas differing only in
        what a validate rejects put the same bytes on the wire and hash as one. Folding a function
        in would give two servers running one build two hashes. The count is in, since a validate
        is a decode-time check the other machine runs too.
    ]]
    Harness.case ("det.behaviour-excluded", function ()
        local base = Lync.int (0, 100)

        agree (
            "two validates with different bodies",
            built ({ only = Lync.packet (base:validate (function () return nil end)) }),
            built ({ only = Lync.packet (base:validate (function () return "no" end)) })
        )

        agree (
            "two transforms with different maps",
            built ({
                only = Lync.packet (base:as (function (v) return v end, function (v) return v end)),
            }),
            built ({
                only = Lync.packet (
                    base:as (function (v) return -v end, function (v) return -v end)
                ),
            })
        )

        local plain = built ({ only = Lync.packet (base) })
        local checked = built ({ only = Lync.packet (base:validate (function () return nil end)) })
        if plain.descriptor == checked.descriptor then
            Expect.holds (false, `a validate left no mark: {plain.descriptor}`)
        end
        Expect.holds (not Wide.same (plain.hash, checked.hash), "a validate left the hash alone")
    end),

    --[[
        The version is the descriptor's first component, so the hash binds it without a byte on the
        wire. A build against a moved protocol fails every handshake it meets, which is what makes a
        wire change a deployment error rather than a corruption.
    ]]
    Harness.case ("det.hash-binds-version", function ()
        local one = built ({ only = Lync.packet (Lync.bool ()) })
        local opening = `{Protocol.VERSION}:`

        if string.sub (one.descriptor, 1, #opening) ~= opening then
            Expect.holds (false, `the descriptor does not open with {opening}: {one.descriptor}`)
            return
        end

        local moved = `{Protocol.VERSION + 1}:{string.sub (one.descriptor, #opening + 1)}`
        local after = Serial.hash (moved)

        if not Wide.same (after, one.hash) then return end
        Expect.holds (false, `a moved version left the hash at {Wide.text (one.hash)}`)
    end),

    --[[
        Any namespace a caller can build, built twice. The cases above name the five orders a person
        would think to reorder, and this is the answer to the question they cannot settle: whether
        the walk is order-free everywhere, or only where somebody remembered to look.
    ]]
    Harness.property ("det.any-schema", "schemas", function (rng: Rng.Rng)
        local specs = Generate.definitions (rng)

        local once, twice = built (specs), built (specs)
        agree ("a drawn namespace built twice", once, twice)

        Expect.equal (Wide.text (Serial.hash (once.descriptor)), Wide.text (once.hash))
    end),
}
