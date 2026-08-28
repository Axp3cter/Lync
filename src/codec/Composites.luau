--!strict
--!optimize 2
-- The composites: five that record a codec under a name, two that record names, and unknown.

local Base = require ("@src/codec/Base")
local Legality = require ("@src/codec/Legality")
local Log = require ("@src/kernel/Log")
local Types = require ("@src/Types")

local Composites = {}

-- Private -------------------------------------------------------------

-- A list of distinct names, answered in the one order two machines both arrive at.
local function labelled (kind: string, names: { string }): { string }
    if type (names) ~= "table" then
        Log.refuse (`{kind} takes a list of names, not a {typeof (names)}`)
    end
    if #names == 0 then Log.refuse (`{kind} takes at least one name`) end

    local seen = {}
    for index = 1, #names do
        local name = names[index]
        if type (name) ~= "string" then
            Log.refuse (`{kind} takes names, and the one at {index} is a {typeof (name)}`)
        end
        if seen[name] ~= nil then
            Log.refuse (`{kind} takes each name once, and {name} is twice`)
        end
        seen[name] = true
    end

    local held = table.clone (names)
    table.sort (held)
    return held
end

-- Public --------------------------------------------------------------

--[[
    The caller's own names, which are the only child names not chosen here. The table is taken as
    it comes, since a frozen one satisfies no indexer in this solver, so each field is asked what it
    is rather than the type above. No field at all is a record with nothing in it.
]]
function Composites.struct <S>(fields: S): Types.Codec<any>
    if type (fields) ~= "table" then
        Log.refuse (`struct takes a table of fields, not a {typeof (fields)}`)
    end

    for name, of in fields :: any do
        if type (name) ~= "string" then
            Log.refuse (`struct takes named fields, and {tostring (name)} is a {typeof (name)}`)
        end
        Legality.codec ("struct", name, of)
    end

    return Base.make ("struct", nil, fields :: any)
end

function Composites.array <T>(element: Types.Codec<T>, min: number, max: number): Types.Codec<{ T }>
    Legality.bare ("array", "element", element)
    Legality.counts ("array", min, max)

    return Base.make ("array", { min = min, max = max }, { element = element })
end

function Composites.map <K, V>(
    key: Types.Codec<K>,
    value: Types.Codec<V>,
    min: number,
    max: number
): Types.Codec<{ [K]: V }>
    Legality.bare ("map", "key", key)
    Legality.bare ("map", "value", value)
    Legality.counts ("map", min, max)

    return Base.make ("map", { min = min, max = max }, { key = key, value = value })
end

function Composites.optional <T>(inner: Types.Codec<T>): Types.Codec<T?>
    Legality.bare ("optional", "inner", inner)
    return Base.make ("optional", nil, { inner = inner })
end

--[[
    The tag rides inside the record rather than beside it, so every variant is a struct and none of
    them may already declare the field it is written into. One that did would have its own value
    overwritten going out and read back as the tag coming in.
]]
function Composites.tagged <V>(field: string, variants: V): Types.Codec<any>
    if type (field) ~= "string" or field == "" then
        Log.refuse (`tagged takes a field name, not "{tostring (field)}"`)
    end
    if type (variants) ~= "table" then
        Log.refuse (`tagged takes a table of variants, not a {typeof (variants)}`)
    end
    if next (variants :: any) == nil then Log.refuse ("tagged takes at least one variant") end

    for name, of in variants :: any do
        if type (name) ~= "string" then
            Log.refuse (`tagged takes named variants, and {tostring (name)} is a {typeof (name)}`)
        end
        Legality.codec ("tagged", name, of)

        if Base.cell (of).kind ~= "struct" then
            Log.refuse (`tagged takes a struct for {name}, not a {Base.cell (of).kind}`)
        end

        local held = Base.cell (of).children
        if held ~= nil and held[field] ~= nil then
            Log.refuse (`the variant {name} already declares {field}, which is the tag`)
        end
    end

    return Base.make ("tagged", { field = field }, variants :: any)
end

-- One of the names, by its place in the canonical order rather than in the order it was written.
function Composites.enum (names: { string }): Types.Codec<string>
    return Base.make ("enum", { names = labelled ("enum", names) })
end

-- One bit per name, in the same order, and a record of every one of them either way.
function Composites.bitfield (names: { string }): Types.Codec<{ [string]: boolean }>
    return Base.make ("bitfield", { names = labelled ("bitfield", names) })
end

--[[
    A value whose shape the schema does not state, spelled out as it is written. Everything else
    here says what it holds first, which is what buys the packing and the bound checks. This says
    only how much room it may take, and pays a tag beside every part of what it carries. Reach for
    it where the shape is genuinely somebody else's.
]]
function Composites.unknown (maxBytes: number): Types.Codec<any>
    Legality.counts ("unknown", 0, maxBytes)
    return Base.make ("unknown", { min = 0, max = maxBytes })
end

return table.freeze (Composites)
