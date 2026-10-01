--!strict
--!optimize 2
-- The surface as a caller finds it: what is on it, what shape each name is, and what it hands back.

local Lync = require("@src")

local Expect = require("@test/harness/Expect")
local Generate = require("@test/harness/Generate")
local Harness = require("@test/harness")
local Rng = require("@test/harness/Rng")

type Table = { [string]: unknown }

type Part = {
    read role: string,
    read kind: string,
    read codecs: boolean,
    read names: { string },
}

type Carrier = { read name: string, read calls: boolean, read forms: { string } }

local function part(role: string, kind: string, codecs: boolean, names: { string }): Part
    return table.freeze({ role = role, kind = kind, codecs = codecs, names = table.freeze(names) })
end

local function carrier(name: string, calls: boolean, forms: { string }): Carrier
    return table.freeze({ name = name, calls = calls, forms = table.freeze(forms) })
end

-- The surface this suite says the library should offer, in the groups the entry module binds it
-- in, each with what `typeof` answers for it, since a name bound to the wrong thing passes a check
-- that only looks for the name.
local SURFACE: { Part } = table.freeze({
    part("the lifecycle", "function", false, { "define", "start", "flush", "close" }),
    part("the definition builders", "function", false, { "packet", "query", "replicate", "group" }),
    part("the sentinels", "table", false, { "all", "none" }),
    part("the recipient builder", "function", false, { "except" }),
    part("the standalone codec", "function", false, { "encode", "decode" }),
    part("the log", "function", false, { "onLog" }),
    part("the log's own connection", "table", false, { "console" }),
    part("the scalar codecs", "function", true, {
        "empty",
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
    part("the composite codecs", "function", true, {
        "struct",
        "array",
        "map",
        "optional",
        "tagged",
        "enum",
        "bitfield",
    }),
    part("the datatype codecs", "function", true, { "vec2", "cframe", "inst" }),
    part("the codecs carrying forms of their own", "table", true, {
        "str",
        "vec3",
        "rotation",
        "color3",
    }),
})

-- The forms the four member-carrying codecs offer, and whether calling the name is one of them.
-- `rotation` holds two forms and is not itself a form.
local CARRIERS: { Carrier } = table.freeze({
    carrier("str", true, { "alphabet" }),
    carrier("vec3", true, { "unit" }),
    carrier("rotation", false, { "none", "quat" }),
    carrier("color3", true, { "rgb565" }),
})

-- What the names, the codec constructors among them, and the forms they come to have to count to.
local NAMES = 39
local CONSTRUCTORS = 24
local FORMS = 28

local DEPTH = Generate.DEEP

-- The shapes a draw will not reach, built once, which the codec property picks from half the time.
local ADVERSARIES = table.freeze(Generate.adversaries())

-- Private -------------------------------------------------------------

local function surface(): Table
    return Lync :: any
end

-- Every name the committed surface holds, to the shape it holds it in.
local function wanted(): { [string]: string }
    local out = {}
    for _, held in SURFACE do
        for _, name in held.names do
            out[name] = held.kind
        end
    end
    return out
end

-- Every codec the surface can spell, in the spelling a shape names it by: the constructor alone
-- where calling it builds one, and the dotted form for each member.
local function spellings(): { [string]: boolean }
    local out = {}
    for _, held in SURFACE do
        if not held.codecs then continue end
        for _, name in held.names do
            out[name] = true
        end
    end
    for _, held in CARRIERS do
        if not held.calls then out[held.name] = nil end
        for _, form in held.forms do
            out[`{held.name}.{form}`] = true
        end
    end
    return out
end

local function counted(of: { [string]: any }): number
    local total = 0
    for _ in of do
        total += 1
    end
    return total
end

-- Every value a table reaches, by its own keys and no further. `pairs` on purpose: a codec that
-- carries forms is a table with a call metamethod, and generalized iteration would hand such a
-- table to itself as an iterator.
local function walked(value: unknown, at: string, seen: { [any]: boolean }, found: { string })
    if typeof(value) == "integer" then
        table.insert(found, at)
        return
    end
    if typeof(value) ~= "table" then return end
    local held = value :: Table
    if seen[held] then return end
    seen[held] = true
    for key, nested in pairs(held) do
        walked(key, `{at} key {tostring(key)}`, seen, found)
        walked(nested, `{at}.{tostring(key)}`, seen, found)
    end
end

-- Where an integer reached a caller through `value`, which is nowhere.
local function escaped(value: unknown, at: string): { string }
    local found = {}
    walked(value, at, {}, found)
    return found
end

local function noEscape(value: unknown, at: string)
    local found = escaped(value, at)
    Expect.holds(#found == 0, `an integer reached a caller at {table.concat(found, ", ")}`)
end

-- Public --------------------------------------------------------------

return {
    -- The exported table is the documented one, both ways round.
    Harness.case("surface.documented", function()
        local expected = wanted()
        Expect.equal(counted(expected), NAMES)

        local held = surface()
        for name, kind in expected do
            local value = held[name]
            Expect.holds(value ~= nil, `the surface does not offer {name}`)
            local shape = typeof(value)
            Expect.holds(shape == kind, `{name} is a {shape} where a {kind} was documented`)
        end
        for name in pairs(held) do
            Expect.holds(
                expected[name] ~= nil,
                `the surface offers {name}, which nothing documents`
            )
        end
    end),

    -- The four codecs that carry forms of their own: each form is a function, and each carrier
    -- offers exactly the forms listed and no others.
    Harness.case("surface.forms", function()
        local held = surface()
        local named = 0
        for _, one in SURFACE do
            if one.codecs then
                named += #one.names
            end
        end
        Expect.equal(named, CONSTRUCTORS)

        local forms = CONSTRUCTORS
        for _, one in CARRIERS do
            local codec = held[one.name] :: Table
            if not one.calls then
                forms -= 1
                Expect.throws(function()
                    (codec :: any)()
                end)
            end
            for _, form in one.forms do
                forms += 1
                local shape = typeof(codec[form])
                Expect.holds(shape == "function", `{one.name}.{form} is a {shape}`)
            end
            local offered = 0
            for _ in pairs(codec) do
                offered += 1
            end
            Expect.equal(offered, #one.forms)
        end
        Expect.equal(forms, FORMS)
    end),

    -- The vocabulary a suite draws from, against the vocabulary the surface offers: every codec
    -- the surface spells is either drawn or named as never drawn, and no codec is both.
    Harness.case("surface.vocabulary", function()
        local spelled = spellings()
        Expect.equal(counted(spelled), FORMS)

        local reached = {}
        for _, at in Generate.KINDS do
            Expect.holds(reached[at] == nil, `the generator draws {at} twice`)
            reached[at] = true
        end
        for _, at in Generate.UNGENERATED do
            Expect.holds(reached[at] == nil, `{at} is both drawn and named as undrawn`)
            reached[at] = true
        end
        for at in spelled do
            Expect.holds(reached[at] ~= nil, `the surface spells {at} and no suite builds it`)
        end
        for at in reached do
            Expect.holds(
                spelled[at] ~= nil,
                `the generator names {at}, which the surface does not spell`
            )
        end
    end),

    -- The surface is a value, not a place to keep things.
    Harness.case("surface.frozen", function()
        Expect.equal(table.isfrozen(Lync :: any), true)
        Expect.throws(function()
            (Lync :: any).mine = 1
        end)
        Expect.throws(function()
            (Lync :: any).define = nil
        end)
    end),

    -- Every listener registration answers something to disconnect with. A responder does not, a
    -- definition having one and nothing to choose between.
    Harness.case("surface.connections", function()
        local function connects(what: string, value: unknown)
            Expect.holds(typeof(value) == "table", `{what} answered a {typeof(value)}`)
            local connection = value :: Table
            Expect.equal(typeof(connection.disconnect), "function")
            Expect.equal(typeof(connection.connected), "boolean")
        end

        connects("onLog", Lync.onLog(function() end))
        connects("console", Lync.console)

        local packet = Lync.packet(Lync.bool())
        connects("packet:onServer", packet:onServer(function() end))
        connects("packet:onClient", packet:onClient(function() end))

        local set = Lync.replicate(Lync.struct({ alive = Lync.bool() }))
        connects("set:onAdded", set:onAdded(function() end))
        connects("set:onChanged", set:onChanged(function() end))
        connects("set:onRemoved", set:onRemoved(function() end))

        local query = Lync.query(Lync.bool(), Lync.bool())
        Expect.equal(
            query:onServer(function()
                return true
            end),
            nil
        )
    end),

    -- All three handles carry `describe` before anything is compiled.
    Harness.case("surface.describes", function()
        local packet = Lync.packet(Lync.bool())
        local query = Lync.query(Lync.bool(), Lync.bool())
        local set = Lync.replicate(Lync.struct({ alive = Lync.bool() }))
        Expect.equal(typeof((packet :: any).describe), "function")
        Expect.equal(typeof((query :: any).describe), "function")
        Expect.equal(typeof((set :: any).describe), "function")
    end),

    -- Nothing the surface holds is an integer, since a caller has no way to hold one.
    Harness.case("surface.no-integer-escape", function()
        noEscape(Lync, "Lync")
        local group = Lync.group()
        noEscape(group, "group")
        noEscape(Lync.except(group), "except")
    end),

    -- Every codec the vocabulary can build, walked for the same thing, since a codec is where a
    -- derived width or span would surface if one were ever kept in the wide domain.
    Harness.property("surface.codecs", "kinds", function(rng: Rng.Rng)
        if rng:bool() then
            local adversary = rng:pick(ADVERSARIES)
            noEscape(Generate.codec(adversary.shape), adversary.name)
        else
            local shape = Generate.shape(rng, DEPTH)
            noEscape(Generate.codec(shape), shape.at)
        end
    end),
}
