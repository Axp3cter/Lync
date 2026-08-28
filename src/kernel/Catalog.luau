--!strict
--!optimize 2
--[[
    Every diagnosis the library can reach, as the code a caller branches on and the line it reads.

    One home, a code being part of the surface: two spellings of one is a caller's branch that
    quietly stops matching.
]]

local Catalog = {}

-- Types ---------------------------------------------------------------

--[[
    A site raising a code with no row here does not compile, which is the half of a closed
    catalogue a type checker can hold on its own.
]]
export type Code =
    "drop.tag"
    | "drop.defid"
    | "drop.count"
    | "drop.varint"
    | "drop.pad"
    | "drop.map-order"
    | "drop.sidecar"
    | "drop.bounds"
    | "drop.section"
    | "drop.validate"
    | "drop.hello"
    | "drop.unready"
    | "drop.mismatch"

--[[
    The template is prose and may be reworded in any release. The keys are what a caller may hold
    to, each reaching `data` under its own name.
]]
export type Entry = {
    read template: string,
    read keys: { string },
}

-- Public --------------------------------------------------------------

-- Every code, under the name a raising site reaches it by.
Catalog.TAG = "drop.tag" :: Code
Catalog.DEFID = "drop.defid" :: Code
Catalog.COUNT = "drop.count" :: Code
Catalog.VARINT = "drop.varint" :: Code
Catalog.PAD = "drop.pad" :: Code
Catalog.MAP_ORDER = "drop.map-order" :: Code
Catalog.SIDECAR = "drop.sidecar" :: Code
Catalog.BOUNDS = "drop.bounds" :: Code
Catalog.SECTION = "drop.section" :: Code
Catalog.VALIDATE = "drop.validate" :: Code
Catalog.HELLO = "drop.hello" :: Code
Catalog.UNREADY = "drop.unready" :: Code
Catalog.MISMATCH = "drop.mismatch" :: Code

--[[
    Every row, and the whole of what a drop can be. The first seven are shape violations, six of
    them saying the field, what the schema wanted and what the bytes had, since there are only
    three things to say. The last six are about a frame rather than a field and name no path. A
    section is one row, since its ways of failing are settled phrases nobody should branch on.
]]
Catalog.entries = table.freeze ({
    [Catalog.TAG] = table.freeze ({
        template = "{path} expected {expected}, got {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.COUNT] = table.freeze ({
        template = "{path} expected a count within {expected}, got {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.VARINT] = table.freeze ({
        template = "{path} expected {expected}, got a varint that {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.PAD] = table.freeze ({
        template = "{path} expected nothing but zeroes after {expected}, got {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.MAP_ORDER] = table.freeze ({
        template = "{path} expected a key above {expected}, got {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.SIDECAR] = table.freeze ({
        template = "{path} expected {expected}, got an instance of {got}",
        keys = table.freeze ({ "path", "expected", "got" }),
    }),
    [Catalog.VALIDATE] = table.freeze ({
        template = "{path} was turned away: {reason}",
        keys = table.freeze ({ "path", "reason" }),
    }),

    [Catalog.BOUNDS] = table.freeze ({
        template = "a frame ran past the bytes it arrived with, and said {said}",
        keys = table.freeze ({ "said" }),
    }),
    [Catalog.SECTION] = table.freeze ({
        template = "a state section is not one this definition could have written, and said {said}",
        keys = table.freeze ({ "said" }),
    }),
    [Catalog.DEFID] = table.freeze ({
        template = "a frame named definition {id}, and this namespace has {count}",
        keys = table.freeze ({ "id", "count" }),
    }),
    [Catalog.HELLO] = table.freeze ({
        template = "the handshake lane carried something that is no hello",
        keys = table.freeze ({}),
    }),
    [Catalog.UNREADY] = table.freeze ({
        template = "a frame arrived before this client was told it could send one",
        keys = table.freeze ({}),
    }),
    [Catalog.MISMATCH] = table.freeze ({
        template = "this namespace hashes {ours} and the other machine says {theirs}",
        keys = table.freeze ({ "ours", "theirs" }),
    }),
}) :: { [Code]: Entry }

return table.freeze (Catalog)
