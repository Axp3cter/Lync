--!strict
--!optimize 2
-- The input factory: a random shape, the codec it builds, and values in and out of its domain.

local Codecs = require("@src/codec")
local Packet = require("@src/api/Packet")
local Protocol = require("@src/wire/Protocol")
local Query = require("@src/api/Query")
local Scalars = require("@src/codec/Scalars")
local Set = require("@src/api/Set")
local Types = require("@src/Types")

local Rng = require("@self/Rng")

local Generate = {}

-- Constants -----------------------------------------------------------

-- Bounds every drawn parameter sits inside. Small on purpose, since a failure is read by a person.
local WIDTH = 6
local SPAN = 8
local LENGTH = 12
local DEPTH = 3

-- The widest bits that still flow into a bit run, the widest an int may span, and how often an
-- int is drawn past the packing ceiling, as one draw in this many.
local PACKED = Protocol.BIT_CEILING
local WIDEST = 52
local BROAD = 4

-- Every kind, simplest first, since a draw of zero takes the first entry of any list here. That is
-- what makes an all-zero tape terminate: each choice resolves to its simplest option.
local LEAVES = table.freeze({
    "bool",
    "int",
    "quant",
    "angle",
    "f32",
    "f64",
    "vlq",
    "vli",
    "str",
    "str.alphabet",
    "buffer",
    "enum",
    "bitfield",
    "vec3.unit",
    "rotation.none",
    "rotation.quat",
    "color3",
    "color3.rgb565",
})

local COMPOSITES =
    table.freeze({ "optional", "array", "struct", "map", "tagged", "vec2", "vec3", "cframe" })

local ALL = table.freeze(table.move(COMPOSITES, 1, #COMPOSITES, #LEAVES + 1, table.clone(LEAVES)))

-- The constructors no case here builds: nothing to draw a value from, or nothing to draw at all.
local UNGENERATED = table.freeze({ "empty", "inst" })

-- The one kind with nothing outside it, since it writes no bits.
local TOTAL = "rotation.none"

local NUMBERS = table.freeze({ "int", "quant", "f32", "vlq" })
local POSITIONS = table.freeze({ "vec3" })
local ROTATIONS = table.freeze({ "rotation.none", "rotation.quat" })
local KEYS = table.freeze({ "int", "enum", "str.alphabet" })
local PARTS = table.freeze({ "int", "enum" })

-- Sets a drawn alphabet picks from, narrowest first. Their sizes are the point: one symbol costs
-- no bits, two cost one, and the widest does not divide the bit space.
local SETS = table.freeze({
    "a",
    "ab",
    "abcdefgh",
    "abcdefghijklmnop",
    "abcdefghijklmnopqrstuvwxyz0123456789",
})

local TURN = Scalars.TURN

-- Grids and precisions a drawn parameter comes from, coarsest first. Every step divides a whole
-- number of units, so a drawn range ends on a grid point.
-- A hair past half a step, for a reading drawn a float's width over the midpoint between two
-- steps, where the division that finds the step rounds the other way.
local NOISE = 1e-9

local STEPS = table.freeze({ 1, 0.5, 0.25, 0.1, 0.01 })
local DEGREES = table.freeze({ 10, 5, 1, 0.5 })

local EXACT = Protocol.EXACT
local RED = 2 ^ Protocol.RGB565_RED - 1
local GREEN = 2 ^ Protocol.RGB565_GREEN - 1
local BLUE = 2 ^ Protocol.RGB565_BLUE - 1

-- How many combinations of its children a shape is allowed to answer for.
local COMBINED = 512

local SCRATCH = buffer.create(8)

-- Types ---------------------------------------------------------------

-- A codec written down: the constructor as the surface spells it and the arguments it takes, so
-- a shape is plain data and the parameters that build the codec are the ones a value is drawn from.
export type Shape = {
    read at: string,
    read of: { Shape },
    read names: { string },
    read text: string,
    read min: number,
    read max: number,
    read step: number,
}

type Parts = {
    of: { Shape }?,
    names: { string }?,
    text: string?,
    min: number?,
    max: number?,
    step: number?,
}

-- One entry per constructor. `slack` absent means the kind carries its input through exactly.
-- Present, it answers by how much the kind rounds, or nil where the kind keeps less than it was
-- handed and the only identity is a re-encode.
type Kind = {
    read draw: (Rng.Rng, number) -> Shape,
    read build: (Shape) -> Types.Codec<any>,
    read inside: (Shape, Rng.Rng) -> any,
    read outside: (Shape, Rng.Rng) -> any,
    read slack: ((Shape) -> number?)?,
}

-- Private -------------------------------------------------------------

local function shaped(at: string, parts: Parts?): Shape
    local given: Parts = parts or {}
    return table.freeze({
        at = at,
        of = given.of or {},
        names = given.names or {},
        text = given.text or "",
        min = given.min or 0,
        max = given.max or 0,
        step = given.step or 0,
    })
end

-- A low and a high with low at or below high, both zero on an empty tape.
local function bounds(rng: Rng.Rng, cap: number): (number, number)
    local low = rng:int(0, cap)
    return low, rng:int(low, cap)
end

local function labels(count: number, prefix: string): { string }
    local out = table.create(count) :: { string }
    for index = 1, count do
        table.insert(out, `{prefix}{index}`)
    end
    return out
end

-- A float read off drawn bits and written back as one, since a platform may flush a subnormal on
-- the way in and keep it on the way out.
local function f32(rng: Rng.Rng): number
    buffer.writeu32(SCRATCH, 0, rng:next())
    buffer.writef32(SCRATCH, 0, buffer.readf32(SCRATCH, 0))
    return buffer.readf32(SCRATCH, 0)
end

local function f64(rng: Rng.Rng): number
    buffer.writeu32(SCRATCH, 0, rng:next())
    buffer.writeu32(SCRATCH, 4, rng:next())
    return buffer.readf64(SCRATCH, 0)
end

-- A direction drawn evenly over the sphere, which three drawn components are not.
local function direction(rng: Rng.Rng): Vector3
    local z = rng:number(-1, 1)
    local around = rng:number(0, 2 * math.pi)
    local radius = math.sqrt(math.max(0, 1 - z * z))
    return Vector3.new(radius * math.cos(around), radius * math.sin(around), z)
end

local function fine(rng: Rng.Rng, at: string): Shape
    return shaped(at, { step = rng:pick(DEGREES) })
end

local function turned(rng: Rng.Rng): CFrame
    return CFrame.fromAxisAngle(direction(rng), rng:number(0, 2 * math.pi))
end

local function letters(rng: Rng.Rng, shape: Shape, from: string): string
    local length = rng:int(shape.min, shape.max)
    local out = table.create(length) :: { string }
    for _ = 1, length do
        local at = rng:int(1, #from)
        table.insert(out, string.sub(from, at, at))
    end
    return table.concat(out)
end

-- A shape with any outer optional taken off, since the surface refuses one in a slot.
local function present(shape: Shape): Shape
    return if shape.at == "optional" then shape.of[1] else shape
end

-- One symbol outside the set, or one byte past the length when the set is all of it.
local function wrongLetters(shape: Shape, from: string): string
    if shape.max < 1 then return "\255" end
    return string.rep(string.sub(from, 1, 1), shape.max - 1) .. "\255"
end

-- How many distinct keys a key shape can take, so a map is built by counting rather than retrying.
local function domain(shape: Shape): number
    if shape.at == "int" then return shape.max - shape.min + 1 end
    if shape.at == "enum" then return #shape.names end
    return (#shape.text) ^ shape.max
end

-- The nth key a key shape can take: counting in its own base, widest first.
local function nth(shape: Shape, index: number): any
    local at = index % domain(shape)
    if shape.at == "int" then return shape.min + at end
    if shape.at == "enum" then return shape.names[at + 1] end
    local from = shape.text
    local base = #from
    local out = table.create(shape.max) :: { string }
    local left = at
    for _ = 1, shape.max do
        local digit = left % base
        left = (left - digit) / base
        table.insert(out, 1, string.sub(from, digit + 1, digit + 1))
    end
    return table.concat(out)
end

local function loosest(shapes: { Shape }): number?
    local found = 0
    for _, shape in shapes do
        local slack = Generate.slack(shape)
        if slack == nil then return nil end
        found = math.max(found, slack)
    end
    return found
end

-- The width of a single-precision step at the widest reading a component reaches, since the
-- engine's vectors hold their components as floats and a decoded grid point lands on the nearest.
local function single(shapes: { Shape }): number
    local reach = 0
    for _, shape in shapes do
        reach = math.max(reach, math.abs(shape.min), math.abs(shape.max))
        if shape.at == "angle" then reach = math.max(reach, TURN) end
    end
    return reach * 2 ^ -23
end

-- A composite's slack, widened by the float its components are held in.
local function floated(shapes: { Shape }): number?
    local base = loosest(shapes)
    return if base == nil then nil else base + single(shapes)
end

-- Every combination of the children's candidates, or one change at a time past the bound. The
-- product is counted out as a mixed radix rather than recursed into.
local function spread(of: { { any } }, build: ({ any }) -> any): { any }
    local reach = 1
    for _, candidates in of do
        reach *= #candidates
    end
    local firsts = {}
    for index, candidates in of do
        firsts[index] = candidates[1]
    end
    if reach > COMBINED then
        local out = { build(firsts) }
        for index, candidates in of do
            for pick = 2, #candidates do
                local chosen = table.clone(firsts)
                chosen[index] = candidates[pick]
                table.insert(out, build(chosen))
            end
        end
        return out
    end
    local out = table.create(reach) :: { any }
    for at = 0, reach - 1 do
        local chosen = table.clone(firsts)
        local held = at
        for index, candidates in of do
            chosen[index] = candidates[held % #candidates + 1]
            held //= #candidates
        end
        table.insert(out, build(chosen))
    end
    return out
end

-- A number at the width the engine keeps a datatype's components in, never further from zero.
local narrow = buffer.create(4)

local function narrowed(value: any): any
    if type(value) ~= "number" then return value end
    buffer.writef32(narrow, 0, value)
    local held = buffer.readf32(narrow, 0)
    if math.abs(held) <= math.abs(value) then return held end
    buffer.writef32(narrow, 0, value * (1 - 2 ^ -23))
    return buffer.readf32(narrow, 0)
end

local function widestOf(shapes: { Shape }): { { any } }
    local out = {}
    for index, shape in shapes do
        out[index] = Generate.widest(shape)
    end
    return out
end

-- The catalog ---------------------------------------------------------

local KINDS: { [string]: Kind } = {
    bool = {
        draw = function()
            return shaped("bool")
        end,
        build = function()
            return Codecs.bool()
        end,
        inside = function(_, rng)
            return rng:bool()
        end,
        outside = function()
            return 0
        end,
    },

    -- A width and then a span inside it, rather than a span drawn flat.
    int = {
        draw = function(rng)
            local low = rng:int(-1000, 1000)
            local broad = rng:int(0, BROAD - 1) == BROAD - 1
            local bits = if broad then rng:int(PACKED + 1, WIDEST) else rng:int(0, PACKED)
            return shaped("int", { min = low, max = low + rng:int(0, 2 ^ bits - 1) })
        end,
        build = function(shape)
            return Codecs.int(shape.min, shape.max)
        end,
        inside = function(shape, rng)
            return rng:int(shape.min, shape.max)
        end,
        outside = function(shape)
            return shape.max + 1
        end,
    },

    quant = {
        draw = function(rng)
            local low = rng:int(-1000, 1000)
            return shaped(
                "quant",
                { min = low, max = low + rng:int(1, 1000), step = rng:pick(STEPS) }
            )
        end,
        build = function(shape)
            return Codecs.quant(shape.min, shape.max, shape.step)
        end,
        inside = function(shape, rng)
            return rng:number(shape.min, shape.max)
        end,
        outside = function(shape)
            return shape.max + shape.step
        end,
        slack = function(shape)
            return shape.step / 2 + NOISE
        end,
    },

    -- Drawn short of the wrap, since a value rounding up to a whole turn decodes as none of one.
    angle = {
        draw = function(rng)
            return fine(rng, "angle")
        end,
        build = function(shape)
            return Codecs.angle(shape.step)
        end,
        inside = function(shape, rng)
            return rng:number(0, TURN - shape.step)
        end,
        outside = function()
            return "not a number"
        end,
        slack = function(shape)
            return shape.step / 2 + NOISE
        end,
    },

    f32 = {
        draw = function()
            return shaped("f32")
        end,
        build = function()
            return Codecs.f32()
        end,
        inside = function(_, rng)
            return f32(rng)
        end,
        outside = function()
            return "not a number"
        end,
    },

    f64 = {
        draw = function()
            return shaped("f64")
        end,
        build = function()
            return Codecs.f64()
        end,
        inside = function(_, rng)
            return f64(rng)
        end,
        outside = function()
            return "not a number"
        end,
    },

    vlq = {
        draw = function()
            return shaped("vlq")
        end,
        build = function()
            return Codecs.vlq()
        end,
        inside = function(_, rng)
            return rng:int(0, EXACT - 1)
        end,
        outside = function()
            return -1
        end,
    },

    vli = {
        draw = function()
            return shaped("vli")
        end,
        build = function()
            return Codecs.vli()
        end,
        inside = function(_, rng)
            local magnitude = rng:int(0, EXACT - 1)
            return if rng:bool() then -magnitude else magnitude
        end,
        outside = function()
            return EXACT
        end,
    },

    -- Any byte, since the bound is on length and an embedded NUL is inside the domain.
    str = {
        draw = function(rng)
            local low, high = bounds(rng, LENGTH)
            return shaped("str", { min = low, max = high })
        end,
        build = function(shape)
            return Codecs.str(shape.min, shape.max)
        end,
        inside = function(shape, rng)
            return buffer.tostring(rng:bytes(rng:int(shape.min, shape.max)))
        end,
        outside = function(shape)
            return string.rep("a", shape.max + 1)
        end,
    },

    ["str.alphabet"] = {
        draw = function(rng)
            local low, high = bounds(rng, LENGTH)
            return shaped("str.alphabet", { min = low, max = high, text = rng:pick(SETS) })
        end,
        build = function(shape)
            return Codecs.str.alphabet(shape.text, shape.min, shape.max)
        end,
        inside = function(shape, rng)
            return letters(rng, shape, shape.text)
        end,
        outside = function(shape)
            return wrongLetters(shape, shape.text)
        end,
    },

    buffer = {
        draw = function(rng)
            local low, high = bounds(rng, LENGTH)
            return shaped("buffer", { min = low, max = high })
        end,
        build = function(shape)
            return Codecs.buffer(shape.min, shape.max)
        end,
        inside = function(shape, rng)
            return rng:bytes(rng:int(shape.min, shape.max))
        end,
        outside = function(shape)
            return buffer.create(shape.max + 1)
        end,
    },

    enum = {
        draw = function(rng)
            return shaped("enum", { names = labels(rng:int(1, WIDTH), "n") })
        end,
        build = function(shape)
            return Codecs.enum(shape.names)
        end,
        inside = function(shape, rng)
            return rng:pick(shape.names)
        end,
        outside = function()
            return "n0"
        end,
    },

    -- A flag holding something that is not a truth, since an undeclared flag is not read at all.
    bitfield = {
        draw = function(rng)
            return shaped("bitfield", { names = labels(rng:int(1, WIDTH), "b") })
        end,
        build = function(shape)
            return Codecs.bitfield(shape.names)
        end,
        inside = function(shape, rng)
            local flags = {}
            for _, name in shape.names do
                flags[name] = rng:bool()
            end
            return flags
        end,
        outside = function(shape)
            local flags: { [string]: any } = {}
            for _, name in shape.names do
                flags[name] = false
            end
            flags[shape.names[1]] = "false"
            return flags
        end,
    },

    ["vec3.unit"] = {
        draw = function(rng)
            return fine(rng, "vec3.unit")
        end,
        build = function(shape)
            return Codecs.vec3.unit(shape.step)
        end,
        inside = function(_, rng)
            return direction(rng)
        end,
        outside = function()
            return 0
        end,
        slack = function(shape)
            return math.rad(shape.step)
        end,
    },

    ["rotation.none"] = {
        draw = function()
            return shaped("rotation.none")
        end,
        build = function()
            return Codecs.rotation.none()
        end,
        inside = function()
            return CFrame.identity
        end,
        outside = function()
            return 0
        end,
    },

    ["rotation.quat"] = {
        draw = function(rng)
            return fine(rng, "rotation.quat")
        end,
        build = function(shape)
            return Codecs.rotation.quat(shape.step)
        end,
        inside = function(_, rng)
            return turned(rng)
        end,
        outside = function()
            return 0
        end,
        slack = function(shape)
            return math.rad(shape.step)
        end,
    },

    color3 = {
        draw = function()
            return shaped("color3")
        end,
        build = function()
            return Codecs.color3()
        end,
        inside = function(_, rng)
            return Color3.new(f32(rng), f32(rng), f32(rng))
        end,
        outside = function()
            return 0
        end,
    },

    -- Drawn on the grid it decodes to, and declared as rounding anyway, since a caller handing it
    -- any other colour gets the nearest grid point.
    ["color3.rgb565"] = {
        draw = function()
            return shaped("color3.rgb565")
        end,
        build = function()
            return Codecs.color3.rgb565()
        end,
        inside = function(_, rng)
            local red = rng:int(0, RED) / RED
            local green = rng:int(0, GREEN) / GREEN
            return Color3.new(red, green, rng:int(0, BLUE) / BLUE)
        end,
        outside = function()
            return 0
        end,
        slack = function()
            return 1 / (2 * math.min(RED, GREEN, BLUE))
        end,
    },

    optional = {
        draw = function(rng, depth)
            return shaped("optional", { of = { present(Generate.shape(rng, depth - 1)) } })
        end,
        build = function(shape)
            return Codecs.optional(Generate.codec(shape.of[1]))
        end,
        inside = function(shape, rng)
            return if rng:bool() then nil else Generate.value(shape.of[1], rng)
        end,
        outside = function(shape, rng)
            return Generate.outside(shape.of[1], rng)
        end,
        slack = function(shape)
            return Generate.slack(shape.of[1])
        end,
    },

    array = {
        draw = function(rng, depth)
            local low, high = bounds(rng, SPAN)
            local of = { present(Generate.shape(rng, depth - 1)) }
            return shaped("array", { of = of, min = low, max = high })
        end,
        build = function(shape)
            return Codecs.array(Generate.codec(shape.of[1]), shape.min, shape.max)
        end,
        inside = function(shape, rng)
            local out = {}
            for _ = 1, rng:int(shape.min, shape.max) do
                table.insert(out, Generate.value(shape.of[1], rng))
            end
            return out
        end,
        outside = function(shape, rng)
            local out = {}
            for _ = 1, shape.max + 1 do
                table.insert(out, Generate.value(shape.of[1], rng))
            end
            return out
        end,
        slack = function(shape)
            return Generate.slack(shape.of[1])
        end,
    },

    -- A field the struct does not declare is the step outside.
    struct = {
        draw = function(rng, depth)
            local count = rng:int(1, WIDTH)
            local of = table.create(count) :: { Shape }
            for _ = 1, count do
                table.insert(of, Generate.shape(rng, depth - 1))
            end
            return shaped("struct", { of = of, names = labels(count, "f") })
        end,
        build = function(shape)
            local fields = {}
            for index, name in shape.names do
                fields[name] = Generate.codec(shape.of[index])
            end
            return Codecs.struct(fields)
        end,
        inside = function(shape, rng)
            local record = {}
            for index, name in shape.names do
                record[name] = Generate.value(shape.of[index], rng)
            end
            return record
        end,
        outside = function(shape, rng)
            local record = { f0 = true }
            for index, name in shape.names do
                record[name] = Generate.value(shape.of[index], rng)
            end
            return record
        end,
        slack = function(shape)
            return loosest(shape.of)
        end,
    },

    -- Entries are counted out rather than drawn and deduplicated, so a narrow key domain caps the
    -- size instead of hanging. One step outside is one entry past the bound, or one key outside
    -- the domain where the domain has no further key to give.
    map = {
        draw = function(rng, depth)
            local key = Generate.among(rng, KEYS, 0)
            local low, high = bounds(rng, math.min(SPAN, domain(key)))
            local of = { key, present(Generate.shape(rng, depth - 1)) }
            return shaped("map", { of = of, min = low, max = high })
        end,
        build = function(shape)
            local key = Generate.codec(shape.of[1])
            return Codecs.map(key, Generate.codec(shape.of[2]), shape.min, shape.max)
        end,
        inside = function(shape, rng)
            local count = rng:int(shape.min, shape.max)
            local from = rng:int(0, 1000)
            local entries = {}
            for index = 1, count do
                entries[nth(shape.of[1], from + index)] = Generate.value(shape.of[2], rng)
            end
            return entries
        end,
        outside = function(shape, rng)
            local key = shape.of[1]
            local entries = {}
            if domain(key) <= shape.max then
                entries[Generate.outside(key, rng)] = Generate.value(shape.of[2], rng)
                return entries
            end
            for index = 1, shape.max + 1 do
                entries[nth(key, index)] = Generate.value(shape.of[2], rng)
            end
            return entries
        end,
        slack = function(shape)
            return loosest(shape.of)
        end,
    },

    tagged = {
        draw = function(rng, depth)
            local count = rng:int(1, WIDTH)
            local of = table.create(count) :: { Shape }
            for _ = 1, count do
                table.insert(of, Generate.record(rng, depth - 1))
            end
            return shaped("tagged", { of = of, names = labels(count, "v"), text = "tag" })
        end,
        build = function(shape)
            local variants = {}
            for index, name in shape.names do
                variants[name] = Generate.codec(shape.of[index])
            end
            return Codecs.tagged(shape.text, variants)
        end,
        inside = function(shape, rng)
            local index = rng:int(1, #shape.names)
            local record = Generate.value(shape.of[index], rng)
            record[shape.text] = shape.names[index]
            return record
        end,
        outside = function(shape, rng)
            local record = Generate.value(shape.of[1], rng)
            record[shape.text] = "v0"
            return record
        end,
        slack = function(shape)
            return loosest(shape.of)
        end,
    },

    vec2 = {
        draw = function(rng, depth)
            if depth <= 0 or not rng:bool() then return shaped("vec2") end
            return shaped("vec2", { of = { Generate.among(rng, NUMBERS, depth - 1) } })
        end,
        build = function(shape)
            if shape.of[1] == nil then return Codecs.vec2() end
            return Codecs.vec2(Generate.codec(shape.of[1]))
        end,
        inside = function(shape, rng)
            local component = shape.of[1]
            if component == nil then return Vector2.new(f32(rng), f32(rng)) end
            return Vector2.new(Generate.value(component, rng), Generate.value(component, rng))
        end,
        outside = function()
            return 0
        end,
        slack = function(shape)
            return floated(shape.of)
        end,
    },

    vec3 = {
        draw = function(rng, depth)
            if depth <= 0 or not rng:bool() then return shaped("vec3") end
            return shaped("vec3", { of = { Generate.among(rng, NUMBERS, depth - 1) } })
        end,
        build = function(shape)
            if shape.of[1] == nil then return Codecs.vec3() end
            return Codecs.vec3(Generate.codec(shape.of[1]))
        end,
        inside = function(shape, rng)
            local component = shape.of[1]
            if component == nil then return Vector3.new(f32(rng), f32(rng), f32(rng)) end
            return Vector3.new(
                Generate.value(component, rng),
                Generate.value(component, rng),
                Generate.value(component, rng)
            )
        end,
        outside = function()
            return 0
        end,
        slack = function(shape)
            return floated(shape.of)
        end,
    },

    cframe = {
        draw = function(rng, depth)
            local position = Generate.among(rng, POSITIONS, depth - 1)
            local rotation = Generate.among(rng, ROTATIONS, depth - 1)
            return shaped("cframe", { of = { position, rotation } })
        end,
        build = function(shape)
            local position = Generate.codec(shape.of[1])
            return Codecs.cframe(position, Generate.codec(shape.of[2]))
        end,
        inside = function(shape, rng)
            local rotation = Generate.value(shape.of[2], rng) :: CFrame
            return rotation + Generate.value(shape.of[1], rng)
        end,
        outside = function()
            return 0
        end,
        slack = function(shape)
            return loosest(shape.of)
        end,
    },
}

-- Kinds whose encoded width turns on the value, and the values that widen one. Everything absent
-- encodes as wide for any value in its domain.
local WIDENS: { [string]: (Shape) -> { any } } = {
    vlq = function()
        return { EXACT - 1 }
    end,
    vli = function()
        return { -(EXACT - 1) }
    end,
    str = function(shape)
        return { string.rep("\255", shape.max) }
    end,
    buffer = function(shape)
        return { Rng.replay({}):bytes(shape.max) }
    end,
    ["str.alphabet"] = function(shape)
        return { string.rep(string.sub(shape.text, 1, 1), shape.max) }
    end,
    optional = function(shape)
        return Generate.widest(shape.of[1])
    end,
    array = function(shape)
        return spread(widestOf(shape.of), function(chosen)
            local out = table.create(shape.max) :: { any }
            for _ = 1, shape.max do
                table.insert(out, chosen[1])
            end
            return out
        end)
    end,
    map = function(shape)
        return spread(widestOf({ shape.of[2] }), function(chosen)
            local entries = {}
            for index = 1, shape.max do
                entries[nth(shape.of[1], index)] = chosen[1]
            end
            return entries
        end)
    end,
    struct = function(shape)
        return spread(widestOf(shape.of), function(chosen)
            local record = {}
            for index, name in shape.names do
                record[name] = chosen[index]
            end
            return record
        end)
    end,
    tagged = function(shape)
        local out = {}
        for index, name in shape.names do
            for _, record in Generate.widest(shape.of[index]) do
                local held = table.clone(record)
                held[shape.text] = name
                table.insert(out, held)
            end
        end
        return out
    end,
    vec2 = function(shape)
        if shape.of[1] == nil then return { Vector2.new(0, 0) } end
        return spread(widestOf(shape.of), function(chosen)
            local held = narrowed(chosen[1])
            return Vector2.new(held, held)
        end)
    end,
    vec3 = function(shape)
        if shape.of[1] == nil then return { Vector3.zero } end
        return spread(widestOf(shape.of), function(chosen)
            local held = narrowed(chosen[1])
            return Vector3.new(held, held, held)
        end)
    end,
    cframe = function(shape)
        return spread(widestOf(shape.of), function(chosen)
            return (chosen[2] :: CFrame) + (chosen[1] :: Vector3)
        end)
    end,
}

-- The four sizes a kind is asked for, floor first. Only a kind carrying a count or a presence bit
-- answers differently to each.
local SIZED = table.freeze({ "empty", "one", "typical", "widest" })

local function counted(shape: Shape, at: string): number
    if at == "empty" then return shape.min end
    return math.min(shape.max, shape.min + 1)
end

local SIZES: { [string]: (Shape, string, Rng.Rng) -> any } = {
    str = function(shape, at)
        return string.rep("a", counted(shape, at))
    end,
    buffer = function(shape, at)
        return buffer.create(counted(shape, at))
    end,
    ["str.alphabet"] = function(shape, at)
        return string.rep(string.sub(shape.text, 1, 1), counted(shape, at))
    end,
    optional = function(shape, at, rng)
        return if at == "empty" then nil else Generate.sized(shape.of[1], at, rng)
    end,
    array = function(shape, at, rng)
        local out = {}
        for _ = 1, counted(shape, at) do
            table.insert(out, Generate.sized(shape.of[1], at, rng))
        end
        return out
    end,
    map = function(shape, at, rng)
        local entries = {}
        for index = 1, counted(shape, at) do
            entries[nth(shape.of[1], index)] = Generate.sized(shape.of[2], at, rng)
        end
        return entries
    end,
    struct = function(shape, at, rng)
        local record = {}
        for index, name in shape.names do
            record[name] = Generate.sized(shape.of[index], at, rng)
        end
        return record
    end,
    tagged = function(shape, at, rng)
        local record = Generate.sized(shape.of[1], at, rng)
        record[shape.text] = shape.names[1]
        return record
    end,
    vec2 = function(shape, at, rng)
        if shape.of[1] == nil then return Vector2.zero end
        local component = Generate.sized(shape.of[1], at, rng)
        return Vector2.new(component, component)
    end,
    vec3 = function(shape, at, rng)
        if shape.of[1] == nil then return Vector3.zero end
        local component = Generate.sized(shape.of[1], at, rng)
        return Vector3.new(component, component, component)
    end,
    cframe = function(shape, at, rng)
        local rotation = Generate.sized(shape.of[2], at, rng) :: CFrame
        return rotation + Generate.sized(shape.of[1], at, rng)
    end,
}

-- Public --------------------------------------------------------------

Generate.KINDS = ALL
Generate.UNGENERATED = UNGENERATED
Generate.TOTAL = TOTAL
Generate.KEYED = PARTS
Generate.SIZED = SIZED

-- The depth a suite draws at, one past what a shape spends unasked, so a drawn tree reaches a
-- composite inside a composite and no further.
Generate.DEEP = DEPTH + 1

-- A random shape, composite while the depth lasts and a leaf after. A tape of zeros is `bool`.
function Generate.shape(rng: Rng.Rng, depth: number?): Shape
    local left = if depth ~= nil then depth else DEPTH
    return Generate.among(rng, if left > 0 then ALL else LEAVES, left)
end

-- A shape drawn from a named few, which is how a slot that takes only some kinds is filled.
function Generate.among(rng: Rng.Rng, from: { string }, depth: number): Shape
    return KINDS[rng:pick(from)].draw(rng, depth)
end

-- A record shape, which is what a set replicates.
function Generate.record(rng: Rng.Rng, depth: number?): Shape
    return KINDS.struct.draw(rng, if depth ~= nil then depth else DEPTH)
end

function Generate.codec(shape: Shape): Types.Codec<any>
    return KINDS[shape.at].build(shape)
end

-- A value the codec accepts, drawn from the parameters that built it.
function Generate.value(shape: Shape, rng: Rng.Rng): any
    return KINDS[shape.at].inside(shape, rng)
end

-- A value one step outside, which the codec throws on encode and drops on decode, except for
-- `TOTAL`, which has no outside and every suite expecting a refusal leaves out.
function Generate.outside(shape: Shape, rng: Rng.Rng): any
    return KINDS[shape.at].outside(shape, rng)
end

-- How far a decoded value may sit from the one encoded: zero when exact, nil when the kind keeps
-- less than it was handed. A composite answers for its widest child.
function Generate.slack(shape: Shape): number?
    local of = KINDS[shape.at].slack
    return if of == nil then 0 else of(shape)
end

-- A frame's bytes damaged one of the four ways a frame is damaged, with the way named.
function Generate.corrupted(rng: Rng.Rng, text: string, other: string?): (string, string)
    local ways = { "cut" }
    if #text > 0 then
        table.insert(ways, "flip")
        table.insert(ways, "swap")
    end
    if other ~= nil then table.insert(ways, "splice") end

    local way = rng:pick(ways)
    if way == "cut" then return string.sub(text, 1, rng:int(0, #text)), way end
    if way == "splice" then
        local held = other :: string
        local keep = rng:int(0, #text)
        return string.sub(text, 1, keep) .. string.sub(held, rng:int(1, #held + 1)), way
    end
    local at = rng:int(1, #text)
    local byte = string.byte(text, at)
    local moved = if way == "flip"
        then bit32.bxor(byte, bit32.lshift(1, rng:int(0, 7)))
        else rng:int(0, 255)
    return `{string.sub(text, 1, at - 1)}{string.char(moved)}{string.sub(text, at + 1)}`, way
end

-- A value at one of the four sizes: a collection at its floor, holding one, typical, or at its
-- ceiling, which a uniform draw reaches least.
function Generate.sized(shape: Shape, at: string, rng: Rng.Rng): any
    if at == "widest" then return Generate.widest(shape)[1] end
    if at == "typical" then return Generate.value(shape, rng) end
    local size = SIZES[shape.at]
    return if size == nil then Generate.value(shape, rng) else size(shape, at, rng)
end

-- Every value worth trying for the widest encoding a shape can produce.
function Generate.widest(shape: Shape): { any }
    local widen = WIDENS[shape.at]
    if widen ~= nil then return widen(shape) end
    return { Generate.value(shape, Rng.replay({})) }
end

-- A namespace of drawn definitions: packets, queries and sets over drawn shapes, under labels.
function Generate.definitions(rng: Rng.Rng, count: number?): { [string]: any }
    local out = {}
    for _, name in labels(count or rng:int(1, WIDTH), "d") do
        local pick = rng:int(1, 3)
        if pick == 1 then
            out[name] = Packet.new(Generate.codec(Generate.shape(rng)))
        elseif pick == 2 then
            local request = Generate.codec(Generate.shape(rng))
            out[name] = Query.new(request, Generate.codec(Generate.shape(rng)))
        else
            out[name] = Set.new(Generate.codec(Generate.record(rng)))
        end
    end
    return out
end

-- The shapes worth holding that a draw will not reach, each named.
function Generate.adversaries(): { { name: string, shape: Shape } }
    local deep = shaped("bool")
    for _ = 1, DEPTH * 2 do
        deep = shaped("array", { of = { deep }, min = 0, max = 2 })
    end
    local function wide(count: number, each: (number) -> Shape): Shape
        local of = table.create(count) :: { Shape }
        for index = 1, count do
            table.insert(of, each(index))
        end
        return shaped("struct", { of = of, names = labels(count, "f") })
    end
    local function flag()
        return shaped("bool")
    end
    local function maybe()
        return shaped("optional", { of = { shaped("bool") } })
    end
    local function mixed(index: number): Shape
        return if index % 2 == 0 then shaped("bool") else shaped("int", { min = 0, max = 1000 })
    end
    return {
        { name = "deepest", shape = deep },
        { name = "widest", shape = wide(WIDTH * 4, flag) },
        { name = "all-optional", shape = wide(WIDTH, maybe) },
        { name = "set-maximum", shape = wide(Protocol.MAX_FIELDS, mixed) },
    }
end

return table.freeze(Generate)
