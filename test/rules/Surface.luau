--!strict
--!optimize 2
-- The surface as a caller finds it: what is on it, what shape each name is, and what it hands back.

local Lync = require ("@src")

local Expect = require ("@test/harness/Expect")
local Generate = require ("@test/harness/Generate")
local Harness = require ("@test/harness")
local Rng = require ("@test/harness/Rng")

-- Constants -----------------------------------------------------------

--[[
    The surface this suite says the library should offer, in the groups the entry module binds it
    in, each with what `typeof` answers for it. A name bound to the wrong thing passes a check that
    only looks for the name, so the shape is committed beside it.
]]
const SURFACE = table.freeze ({
    table.freeze ({
        role = "the lifecycle",
        kind = "function",
        codecs = false,
        names = table.freeze ({ "define", "start", "flush", "close", "stats" }),
    }),
    table.freeze ({
        role = "the definition builders",
        kind = "function",
        codecs = false,
        names = table.freeze ({ "packet", "query", "replicate", "group" }),
    }),
    table.freeze ({
        role = "the sentinels",
        kind = "table",
        codecs = false,
        names = table.freeze ({ "all", "none" }),
    }),
    table.freeze ({
        role = "the recipient builder",
        kind = "function",
        codecs = false,
        names = table.freeze ({ "except" }),
    }),
    table.freeze ({
        role = "the log",
        kind = "function",
        codecs = false,
        names = table.freeze ({ "onLog" }),
    }),
    table.freeze ({
        role = "the log's own connection",
        kind = "table",
        codecs = false,
        names = table.freeze ({ "console" }),
    }),
    table.freeze ({
        role = "the scalar codecs",
        kind = "function",
        codecs = true,
        names = table.freeze ({
            "bool",
            "int",
            "quant",
            "angle",
            "f32",
            "f64",
            "vlq",
            "vli",
            "buffer",
        }),
    }),
    table.freeze ({
        role = "the composite codecs",
        kind = "function",
        codecs = true,
        names = table.freeze ({
            "struct",
            "array",
            "map",
            "optional",
            "tagged",
            "enum",
            "bitfield",
        }),
    }),
    table.freeze ({
        role = "the datatype codecs",
        kind = "function",
        codecs = true,
        names = table.freeze ({ "vec2", "cframe", "inst" }),
    }),
    table.freeze ({
        role = "the codecs carrying forms of their own",
        kind = "table",
        codecs = true,
        names = table.freeze ({ "str", "vec3", "rotation", "color3" }),
    }),
})

--[[
    The forms the four member-carrying codecs offer, and whether calling the name is one of them.
    `rotation` is the odd one: it holds four forms and is not itself a form, where the other three
    answer a codec called directly as well as through a member.
]]
const CARRIERS = table.freeze ({
    table.freeze ({
        name = "str",
        calls = true,
        forms = table.freeze ({
            "alphabet",
            "alphanum",
            "base32",
            "base64",
            "digits",
            "hex",
        }),
    }),
    table.freeze ({
        name = "vec3",
        calls = true,
        forms = table.freeze ({ "unit", "bounded" }),
    }),
    table.freeze ({
        name = "rotation",
        calls = false,
        forms = table.freeze ({ "none", "axis", "direction", "quat" }),
    }),
    table.freeze ({
        name = "color3",
        calls = true,
        forms = table.freeze ({ "rgb565", "palette" }),
    }),
})

-- What the two counts above have to come to.
const NAMES = 37
const FORMS = 36

-- Codec constructors among the names, which is what the forms are counted from.
const CONSTRUCTORS = 23

const DEPTH = Generate.DEEP

-- Types ---------------------------------------------------------------

type Table = { [string]: unknown }

-- Private -------------------------------------------------------------

--[[
    The shapes a draw will not reach, built once. Every case below picks from them half the time
    rather than walking all four every case, so the deepest and widest codecs are covered inside the
    budget rather than beside it.
]]
const ADVERSARIES = table.freeze (Generate.adversaries ())

local function surface (): Table return Lync :: any end

-- Every name the committed surface holds, to the shape it holds it in.
local function wanted (): { [string]: string }
    local out = {}
    for _, part in SURFACE do
        for _, name in part.names do
            out[name] = part.kind
        end
    end
    return out
end

--[[
    Every codec the surface can spell, in the spelling a shape names it by: the constructor alone
    where calling it builds one, and the dotted form for each member. `rotation` drops out because
    calling it is not a form of it.
]]
local function spellings (): { [string]: boolean }
    local out = {}
    for _, part in SURFACE do
        if not part.codecs then continue end
        for _, name in part.names do
            out[name] = true
        end
    end

    for _, carrier in CARRIERS do
        if not carrier.calls then out[carrier.name] = nil end
        for _, form in carrier.forms do
            out[`{carrier.name}.{form}`] = true
        end
    end
    return out
end

local function counted (of: { [string]: any }): number
    local total = 0
    for _ in of do
        total += 1
    end
    return total
end

--[[
    Every value a table reaches, by its own keys and no further. `pairs` rather than generalized
    iteration on purpose: a codec that carries forms is a table with a call metamethod, and
    generalized iteration hands such a table to itself as an iterator and never comes back.
]]
local function walked (value: unknown, at: string, seen: { [any]: boolean }, found: { string })
    if typeof (value) == "integer" then
        table.insert (found, at)
        return
    end
    if typeof (value) ~= "table" then return end

    local held = value :: Table
    if seen[held] then return end
    seen[held] = true

    for key, nested in pairs (held) do
        walked (key, `{at} key {tostring (key)}`, seen, found)
        walked (nested, `{at}.{tostring (key)}`, seen, found)
    end
end

local function escaped (value: unknown, at: string): { string }
    local found = {}
    walked (value, at, {}, found)
    return found
end

-- Public --------------------------------------------------------------

return {
    --[[
        The exported table is the documented one, both ways round. A name the library offers and
        this list does not is a surface nobody agreed to, and a name this list holds and the library
        does not is a promise the documentation makes and the code does not keep.
    ]]
    Harness.case ("surface.documented", function ()
        local expected = wanted ()
        Expect.equal (counted (expected), NAMES)

        local held = surface ()
        for name, kind in expected do
            local value = held[name]
            if value == nil then Expect.holds (false, `the surface does not offer {name}`) end
            if typeof (value) ~= kind then
                Expect.holds (false, `{name} is a {typeof (value)} where a {kind} was documented`)
            end
        end

        for name in pairs (held) do
            if expected[name] ~= nil then continue end
            Expect.holds (false, `the surface offers {name}, which nothing documents`)
        end
    end),

    --[[
        The four codecs that carry forms of their own, and the thirty-six forms the twenty-three
        constructors come to between them. Each form is a function, and each carrier offers exactly
        the forms listed and no others, so a form added without a home here is caught where it is
        added rather than where it is first used.
    ]]
    Harness.case ("surface.forms", function ()
        local held = surface ()

        local named = 0
        for _, part in SURFACE do
            if part.codecs then
                named += #part.names
            end
        end
        Expect.equal (named, CONSTRUCTORS)

        local forms = CONSTRUCTORS
        for _, carrier in CARRIERS do
            local codec = held[carrier.name] :: Table

            if not carrier.calls then
                forms -= 1
                Expect.throws (function () (codec :: any) () end)
            end

            for _, form in carrier.forms do
                forms += 1
                if typeof (codec[form]) == "function" then continue end
                Expect.holds (false, `{carrier.name}.{form} is a {typeof (codec[form])}`)
            end

            local offered = 0
            for _ in pairs (codec) do
                offered += 1
            end
            Expect.equal (offered, #carrier.forms)
        end
        Expect.equal (forms, FORMS)
    end),

    --[[
        The vocabulary a suite draws from, against the vocabulary the surface offers. Every codec
        the surface spells is either one the generator draws or one it names as never drawn, and no
        codec is both.
    ]]
    Harness.case ("surface.vocabulary", function ()
        local spelled = spellings ()
        Expect.equal (counted (spelled), FORMS)

        local reached = {}
        for _, at in Generate.KINDS do
            Expect.holds (reached[at] == nil, `the generator draws {at} twice`)
            reached[at] = true
        end
        for _, at in Generate.UNGENERATED do
            Expect.holds (reached[at] == nil, `{at} is both drawn and named as undrawn`)
            reached[at] = true
        end

        for at in spelled do
            if reached[at] ~= nil then continue end
            Expect.holds (false, `the surface spells {at} and no suite builds it`)
        end
        for at in reached do
            if spelled[at] ~= nil then continue end
            Expect.holds (false, `the generator names {at}, which the surface does not spell`)
        end
    end),

    --[[
        The surface is a value, not a place to keep things. Binding a name onto it would make one
        caller's convenience another caller's surface, and rebinding one would make a library that
        behaves differently depending on what else in the game has loaded.
    ]]
    Harness.case ("surface.frozen", function ()
        Expect.equal (table.isfrozen (Lync :: any), true)
        Expect.throws (function () (Lync :: any).mine = 1 end)
        Expect.throws (function () (Lync :: any).define = nil end)
    end),

    --[[
        Every listener registration answers something to disconnect with. A responder does not,
        a definition having one and nothing to choose between. The log's default printer is a
        connection already, handed over rather than registered. Asked before anything is started,
        since a responder attached after `start` throws.
    ]]
    Harness.case ("surface.connections", function ()
        local function connects (what: string, value: unknown)
            if typeof (value) ~= "table" then
                Expect.holds (false, `{what} answered a {typeof (value)}`)
                return
            end

            local connection = value :: Table
            Expect.equal (typeof (connection.disconnect), "function")
            Expect.equal (typeof (connection.connected), "boolean")
        end

        connects ("onLog", Lync.onLog (function () end))
        connects ("console", Lync.console)

        local packet = Lync.packet (Lync.bool ())
        connects ("packet:onServer", packet:onServer (function () end))
        connects ("packet:onClient", packet:onClient (function () end))

        local set = Lync.replicate (Lync.struct ({ alive = Lync.bool () }))
        connects ("set:onAdded", set:onAdded (function () end))
        connects ("set:onChanged", set:onChanged (function () end))
        connects ("set:onRemoved", set:onRemoved (function () end))

        local query = Lync.query (Lync.bool (), Lync.bool ())
        Expect.equal (query:onServer (function () return true end), nil)
    end),

    --[[
        All three handles carry `describe`. What it prints is the descriptor walk's, and that needs
        a compiled schema, so this asks only that the member is there before anything is compiled. A
        handle that grew a describe at `start` would be a handle a caller could not read until the
        library was running, which is the opposite of what it is for.
    ]]
    Harness.case ("surface.describes", function ()
        local packet = Lync.packet (Lync.bool ())
        local query = Lync.query (Lync.bool (), Lync.bool ())
        local set = Lync.replicate (Lync.struct ({ alive = Lync.bool () }))

        Expect.equal (typeof ((packet :: any).describe), "function")
        Expect.equal (typeof ((query :: any).describe), "function")
        Expect.equal (typeof ((set :: any).describe), "function")
    end),

    --[[
        Nothing the surface holds is an integer. The library carries sixty-four bit values in the
        integer domain and a caller has no way to hold one: it will not add to a number, it compares
        equal to none, and it silently answers false rather than raising when it is asked to.
    ]]
    Harness.case ("surface.no-integer-escape", function ()
        local found = escaped (Lync, "Lync")
        if #found > 0 then
            Expect.holds (false, `an integer reached a caller at {table.concat (found, ", ")}`)
        end

        local group = Lync.group ()
        Expect.equal (#escaped (group, "group"), 0)
        Expect.equal (#escaped (Lync.except (group), "except"), 0)
    end),

    --[[
        Every codec the vocabulary can build, walked for the same thing. A codec is the one value a
        caller holds that the library built out of numbers it was given, so it is where a derived
        width or span would surface if one were ever computed in the wide domain and kept.
    ]]
    Harness.property ("surface.codecs", "kinds", function (rng: Rng.Rng)
        local at, codec
        if Rng.bool (rng) then
            local adversary = Rng.pick (rng, ADVERSARIES)
            at, codec = adversary.name, Generate.codec (adversary.shape)
        else
            local shape = Generate.shape (rng, DEPTH)
            at, codec = shape.at, Generate.codec (shape)
        end

        local found = escaped (codec, at)
        if #found == 0 then return end
        Expect.holds (false, `an integer reached a caller at {table.concat (found, ", ")}`)
    end),
}
