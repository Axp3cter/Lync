--!strict
--!optimize 2
-- The input factory: a random shape, the codec it builds, and values in and out of its domain.

local Lync = require ("@src")
local Protocol = require ("@src/wire/Protocol")
local Rng = require ("@self/Rng")
local Scalars = require ("@src/codec/Scalars")

local Generate = {}

-- Constants -----------------------------------------------------------

--[[
    Bounds every drawn parameter sits inside. Small on purpose: a failure is read by a person, and a
    hundred-field struct that fails for the reason a two-field one does is a worse report of the
    same bug. The shapes that have to be large are curated rather than drawn, and live in
    `adversaries`.
]]
const WIDTH = 6
const SPAN = 8
const LENGTH = 12
const DEPTH = 3

--[[
    The widest bits an int may span, and the widest that still flows into a bit run beside its
    neighbours.
]]
const PACKED = Protocol.BIT_CEILING
const WIDEST = 52

-- How often an int is drawn past the packing ceiling, as one draw in this many.
const BROAD = 4

--[[
    Every kind, simplest first, because a draw of zero takes the first entry of any list here. That
    is the termination argument for an all-zero tape, which the minimizer replays past the end of
    every candidate it tries: each choice resolves to its simplest option, and no simplest option is
    a composite.
]]
const LEAVES = table.freeze ({
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
    "vec3.bounded",
    "rotation.none",
    "rotation.axis",
    "rotation.direction",
    "rotation.quat",
    "color3",
    "color3.rgb565",
    "color3.palette",
})

const COMPOSITES = table.freeze ({
    "optional",
    "array",
    "struct",
    "map",
    "tagged",
    "vec2",
    "vec3",
    "cframe",
})

const ALL =
    table.freeze (table.move (COMPOSITES, 1, #COMPOSITES, #LEAVES + 1, table.clone (LEAVES)))

-- The constructors no case here builds, each for its own reason.
const UNGENERATED = table.freeze ({
    "inst",
    "str.alphanum",
    "str.base32",
    "str.base64",
    "str.digits",
    "str.hex",
})

--[[
    The one kind with nothing outside it. `rotation.none` writes zero bits, so no value it is handed
    reaches a buffer and nothing about one can be wrong on the wire. `outside` still answers for it,
    because what a caller would be mistaken to pass is a real question, and every suite that turns
    that answer into an expected refusal has to leave this kind out.
]]
const TOTAL = "rotation.none"

-- What a numeric component, a position and a rotation may be.
const NUMBERS = table.freeze ({ "int", "quant", "f32", "vlq" })
const POSITIONS = table.freeze ({ "vec3", "vec3.bounded" })
const ROTATIONS =
    table.freeze ({ "rotation.none", "rotation.axis", "rotation.direction", "rotation.quat" })

-- What a map's key may be, which is a scalar that sorts.
const KEYS = table.freeze ({ "int", "enum", "str.alphabet" })

-- What a set may partition by, which is narrower and for a reason the wire gives.
const PARTS = table.freeze ({ "int", "enum" })

--[[
    Sets a drawn alphabet picks from, narrowest first. Their sizes are the point rather than their
    letters: one symbol costs no bits at all, two cost one, and the rest sit either side of a whole
    number of bits so a set that does not divide the space is drawn as often as one that does.
]]
const SETS = table.freeze ({
    "a",
    "ab",
    "abcdefgh",
    "abcdefghijklmnop",
    "abcdefghijklmnopqrstuvwxyz0123456789",
})

-- A whole turn in degrees, which is what an angular range stops one precision short of.
const TURN = Scalars.TURN

--[[
    Grids and precisions a drawn parameter comes from, coarsest first. Every step divides a whole
    number of units, so a drawn range ends on a grid point and the `slack` these kinds declare
    holds. A step that leaves a remainder is a separate question and is drawn by nothing here.
]]
const STEPS = table.freeze ({ 1, 0.5, 0.25, 0.1, 0.01 })
const DEGREES = table.freeze ({ 10, 5, 1, 0.5 })
const AXES = table.freeze ({ Vector3.xAxis, Vector3.yAxis, Vector3.zAxis })

const EXACT = Protocol.EXACT

--[[
    A colour packed into sixteen bits lands each channel on a grid of as many steps as its width
    allows. The widths are a wire layout, so they are read from the protocol rather than written
    here: a generator holding its own copy draws a channel the codec rounds and calls the rounding a
    bug in the codec, which is the same reason the preset alphabets above are left undrawn.
]]
const RED = 2 ^ Protocol.RGB565_RED - 1
const GREEN = 2 ^ Protocol.RGB565_GREEN - 1
const BLUE = 2 ^ Protocol.RGB565_BLUE - 1

-- Where a float is assembled from the words a generator draws.
const SCRATCH = buffer.create (8)

-- Types ---------------------------------------------------------------

--[[
    A codec written down: the constructor, as the surface spells it, and the arguments it takes.
    Every parameter is a number, a name list, or a child shape, so a shape is plain data a corpus
    line rebuilds, and the parameters that build the codec are the ones a conforming value is drawn
    from.
]]
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

--[[
    One entry per constructor. `slack` absent means the kind carries its input through exactly.
    Present means it rounds, and answers by how much, or nil when the kind keeps less than it was
    handed. A direction keeps no roll, and there the only identity is a re-encode, which a caller
    compares instead.
]]
type Kind = {
    read draw: (Rng.Rng, number) -> Shape,
    read build: (Shape) -> Lync.Codec<any>,
    read inside: (Shape, Rng.Rng) -> any,
    read outside: (Shape, Rng.Rng) -> any,
    read slack: ((Shape) -> number?)?,
}

-- Private -------------------------------------------------------------

local function shaped (at: string, parts: Parts?): Shape
    local given: Parts = parts or {}
    return table.freeze ({
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
local function bounds (rng: Rng.Rng, cap: number): (number, number)
    local low = Rng.int (rng, 0, cap)
    return low, Rng.int (rng, low, cap)
end

local function labels (count: number, prefix: string): { string }
    local out = table.create (count) :: { string }
    for index = 1, count do
        table.insert (out, `{prefix}{index}`)
    end
    return out
end

--[[
    A float read off drawn bits and written back as one, since a platform may flush a subnormal on
    the way in and keep it on the way out, and a pattern surviving only the read is a value no `f32`
    write carries.
]]
local function f32 (rng: Rng.Rng): number
    buffer.writeu32 (SCRATCH, 0, Rng.next (rng))
    buffer.writef32 (SCRATCH, 0, buffer.readf32 (SCRATCH, 0))

    return buffer.readf32 (SCRATCH, 0)
end

local function f64 (rng: Rng.Rng): number
    buffer.writeu32 (SCRATCH, 0, Rng.next (rng))
    buffer.writeu32 (SCRATCH, 4, Rng.next (rng))
    return buffer.readf64 (SCRATCH, 0)
end

-- A direction drawn evenly over the sphere, which three drawn components are not.
local function direction (rng: Rng.Rng): Vector3
    local z = Rng.number (rng, -1, 1)
    local around = Rng.number (rng, 0, 2 * math.pi)
    local radius = math.sqrt (math.max (0, 1 - z * z))
    return Vector3.new (radius * math.cos (around), radius * math.sin (around), z)
end

-- A shape carrying only a precision, which is all the angular kinds are drawn from.
local function fine (rng: Rng.Rng, at: string): Shape
    return shaped (at, { step = Rng.pick (rng, DEGREES) })
end

local function turned (rng: Rng.Rng): CFrame
    return CFrame.fromAxisAngle (direction (rng), Rng.number (rng, 0, 2 * math.pi))
end

local function letters (rng: Rng.Rng, shape: Shape, from: string): string
    local length = Rng.int (rng, shape.min, shape.max)
    local out = table.create (length) :: { string }
    for _ = 1, length do
        local at = Rng.int (rng, 1, #from)
        table.insert (out, string.sub (from, at, at))
    end
    return table.concat (out)
end

--[[
    A shape with any outer optional taken off, because the surface refuses one in a slot and a
    generator that drew one would be drawing a schema that never builds. A struct field may still
    be optional, because a record names what it is missing.
]]
local function present (shape: Shape): Shape
    if shape.at == "optional" then return shape.of[1] end
    return shape
end

-- One symbol outside the set, or one byte past the length when the set is all of it.
local function wrongLetters (shape: Shape, from: string): string
    if shape.max < 1 then return "\255" end
    return string.rep (string.sub (from, 1, 1), shape.max - 1) .. "\255"
end

-- Every colour a palette of that size holds, built the same way both times.
local function palette (size: number): { Color3 }
    local out = table.create (size) :: { Color3 }
    for index = 1, size do
        table.insert (out, Color3.fromHSV ((index - 1) / size, 1, 1))
    end
    return out
end

--[[
    How many distinct keys a key shape can take, at or below the truth for the three kinds a key may
    be: a map draws distinct keys by counting rather than by retrying, so a key domain narrower than
    the entry count would otherwise be a draw that never finishes.
]]
local function domain (shape: Shape): number
    if shape.at == "int" then return shape.max - shape.min + 1 end
    if shape.at == "enum" then return #shape.names end
    return (#shape.text) ^ shape.max
end

-- The nth key a key shape can take: counting in its own base, widest first.
local function nth (shape: Shape, index: number): any
    local at = index % domain (shape)
    if shape.at == "int" then return shape.min + at end
    if shape.at == "enum" then return shape.names[at + 1] end

    local from = shape.text
    local base = #from
    local out = table.create (shape.max) :: { string }
    local left = at
    for _ = 1, shape.max do
        local digit = left % base
        left = (left - digit) / base
        table.insert (out, 1, string.sub (from, digit + 1, digit + 1))
    end
    return table.concat (out)
end

local function loosest (shapes: { Shape }): number?
    local found = 0
    for _, shape in shapes do
        local slack = Generate.slack (shape)
        if slack == nil then return nil end
        if slack > found then found = slack end
    end
    return found
end

-- How many combinations of its children a shape is allowed to answer for.
const COMBINED = 512

-- Every combination of the children's candidates, or as near to one as the bound allows.
local function spread (of: { { any } }, build: ({ any }) -> any): { any }
    local reach = 1
    for _, candidates in of do
        reach *= #candidates
    end

    local firsts = {}
    for index, candidates in of do
        firsts[index] = candidates[1]
    end

    if reach > COMBINED then
        local out = { build (firsts) }
        for index, candidates in of do
            for pick = 2, #candidates do
                local chosen = table.clone (firsts)
                chosen[index] = candidates[pick]
                table.insert (out, build (chosen))
            end
        end
        return out
    end

    --[[
        The product counted out rather than recursed into. Each combination is one number read as a
        mixed radix, the digits being one child apiece, so the walk is flat however deep the shape
        is and every combination is reached exactly once.
    ]]
    local out = table.create (reach) :: { any }
    for at = 0, reach - 1 do
        local chosen = table.clone (firsts)
        local held = at

        for index, candidates in of do
            chosen[index] = candidates[held % #candidates + 1]
            held //= #candidates
        end
        table.insert (out, build (chosen))
    end
    return out
end

--[[
    A number at the width the engine keeps a datatype's components in, never further from zero. A
    component at the top of its domain, rounded outward into a float32, is a value that domain no
    longer holds and the encoder is right to turn away.
]]
local narrow = buffer.create (4)

local function narrowed (value: any): any
    if type (value) ~= "number" then return value end

    buffer.writef32 (narrow, 0, value)
    local held = buffer.readf32 (narrow, 0)
    if math.abs (held) <= math.abs (value) then return held end

    buffer.writef32 (narrow, 0, value * (1 - 2 ^ -23))
    return buffer.readf32 (narrow, 0)
end

local function widestOf (shapes: { Shape }): { { any } }
    local out = {}
    for index, shape in shapes do
        out[index] = Generate.widest (shape)
    end
    return out
end

-- The catalog ---------------------------------------------------------

const KINDS: { [string]: Kind } = {
    bool = {
        draw = function () return shaped ("bool") end,
        build = function () return Lync.bool () end,
        inside = function (_, rng) return Rng.bool (rng) end,
        outside = function () return 0 end,
    },

    -- A width and then a span inside it, rather than a span drawn flat.
    int = {
        draw = function (rng)
            local low = Rng.int (rng, -1000, 1000)

            local broad = Rng.int (rng, 0, BROAD - 1) == BROAD - 1
            local bits = if broad
                then Rng.int (rng, PACKED + 1, WIDEST)
                else Rng.int (rng, 0, PACKED)

            return shaped ("int", { min = low, max = low + Rng.int (rng, 0, 2 ^ bits - 1) })
        end,
        build = function (shape) return Lync.int (shape.min, shape.max) end,
        inside = function (shape, rng) return Rng.int (rng, shape.min, shape.max) end,
        outside = function (shape) return shape.max + 1 end,
    },

    quant = {
        draw = function (rng)
            local low = Rng.int (rng, -1000, 1000)
            local step = Rng.pick (rng, STEPS)
            return shaped ("quant", { min = low, max = low + Rng.int (rng, 1, 1000), step = step })
        end,
        build = function (shape) return Lync.quant (shape.min, shape.max, shape.step) end,
        inside = function (shape, rng) return Rng.number (rng, shape.min, shape.max) end,
        outside = function (shape) return shape.max + shape.step end,
        slack = function (shape) return shape.step / 2 end,
    },

    --[[
        Drawn short of the wrap, because a value rounding up to a whole turn decodes as none of
        one and the comparison a caller makes is not cyclic. The wrap itself is a named case in the
        suite, where the answer is written down.
    ]]
    angle = {
        draw = function (rng) return fine (rng, "angle") end,
        build = function (shape) return Lync.angle (shape.step) end,
        inside = function (shape, rng) return Rng.number (rng, 0, TURN - shape.step) end,
        outside = function () return "not a number" end,
        slack = function (shape) return shape.step / 2 end,
    },

    f32 = {
        draw = function () return shaped ("f32") end,
        build = function () return Lync.f32 () end,
        inside = function (_, rng) return f32 (rng) end,
        outside = function () return "not a number" end,
    },

    f64 = {
        draw = function () return shaped ("f64") end,
        build = function () return Lync.f64 () end,
        inside = function (_, rng) return f64 (rng) end,
        outside = function () return "not a number" end,
    },

    vlq = {
        draw = function () return shaped ("vlq") end,
        build = function () return Lync.vlq () end,
        inside = function (_, rng) return Rng.int (rng, 0, EXACT - 1) end,
        outside = function () return -1 end,
    },

    -- Magnitude and sign apart, because the signed span alone is wider than a draw.
    vli = {
        draw = function () return shaped ("vli") end,
        build = function () return Lync.vli () end,
        inside = function (_, rng)
            local magnitude = Rng.int (rng, 0, EXACT - 1)
            return if Rng.bool (rng) then -magnitude else magnitude
        end,
        outside = function () return EXACT end,
    },

    str = {
        draw = function (rng)
            local low, high = bounds (rng, LENGTH)
            return shaped ("str", { min = low, max = high })
        end,
        build = function (shape) return Lync.str (shape.min, shape.max) end,
        --[[
            Any byte, because the bound is on length: an embedded NUL and a sequence no UTF-8
            decoder accepts are both inside the domain, and a generator drawing printable text would
            never say so.
        ]]
        inside = function (shape, rng)
            local length = Rng.int (rng, shape.min, shape.max)
            local out = table.create (length) :: { string }
            for _ = 1, length do
                table.insert (out, string.char (Rng.int (rng, 0, 255)))
            end
            return table.concat (out)
        end,
        outside = function (shape) return string.rep ("a", shape.max + 1) end,
    },

    ["str.alphabet"] = {
        draw = function (rng)
            local low, high = bounds (rng, LENGTH)
            return shaped ("str.alphabet", { min = low, max = high, text = Rng.pick (rng, SETS) })
        end,
        build = function (shape) return Lync.str.alphabet (shape.text, shape.min, shape.max) end,
        inside = function (shape, rng) return letters (rng, shape, shape.text) end,
        outside = function (shape) return wrongLetters (shape, shape.text) end,
    },

    buffer = {
        draw = function (rng)
            local low, high = bounds (rng, LENGTH)
            return shaped ("buffer", { min = low, max = high })
        end,
        build = function (shape) return Lync.buffer (shape.min, shape.max) end,
        inside = function (shape, rng)
            local length = Rng.int (rng, shape.min, shape.max)
            return Rng.bytes (rng, length)
        end,
        outside = function (shape) return buffer.create (shape.max + 1) end,
    },

    enum = {
        draw = function (rng)
            return shaped ("enum", { names = labels (Rng.int (rng, 1, WIDTH), "n") })
        end,
        build = function (shape) return Lync.enum (shape.names) end,
        inside = function (shape, rng) return Rng.pick (rng, shape.names) end,
        outside = function () return "n0" end,
    },

    bitfield = {
        draw = function (rng)
            return shaped ("bitfield", { names = labels (Rng.int (rng, 1, WIDTH), "b") })
        end,
        build = function (shape) return Lync.bitfield (shape.names) end,
        inside = function (shape, rng)
            local flags = {}
            for _, name in shape.names do
                flags[name] = Rng.bool (rng)
            end
            return flags
        end,
        --[[
            A flag holding something that is not a truth, rather than a flag the declaration never
            named. Every keyed kind here ignores a key it did not declare, uniformly and by design:
            an encode reads the fields it named and walks nothing else, so an undeclared flag is not
            one step outside a bitfield, it is not there at all.
        ]]
        outside = function (shape)
            local flags: { [string]: any } = {}
            for _, name in shape.names do
                flags[name] = false
            end
            flags[shape.names[1]] = "false"
            return flags
        end,
    },

    ["vec3.unit"] = {
        draw = function (rng) return fine (rng, "vec3.unit") end,
        build = function (shape) return Lync.vec3.unit (shape.step) end,
        inside = function (_, rng) return direction (rng) end,
        outside = function () return 0 end,
        slack = function (shape) return math.rad (shape.step) end,
    },

    --[[
        The magnitude rides a grid of `step` and the direction rides the precision that grid
        implies, so a component is out by half a step plus max times the arc `step / max` subtends,
        which is a step and a half.
    ]]
    ["vec3.bounded"] = {
        draw = function (rng)
            local step = Rng.pick (rng, STEPS)
            return shaped ("vec3.bounded", { max = step * Rng.int (rng, 1, 1000), step = step })
        end,
        build = function (shape) return Lync.vec3.bounded (shape.max, shape.step) end,
        inside = function (shape, rng)
            return direction (rng) * Rng.number (rng, 0, shape.max - shape.step)
        end,
        outside = function (shape) return Vector3.xAxis * (shape.max * 2) end,
        slack = function (shape) return shape.step * 1.5 end,
    },

    ["rotation.none"] = {
        draw = function () return shaped ("rotation.none") end,
        build = function () return Lync.rotation.none () end,
        inside = function () return CFrame.identity end,
        outside = function () return 0 end,
    },

    --[[
        Drawn about the codec's own axis, which is the only turn it carries, and short of the wrap
        for the reason `angle` is: the protocol makes this one `angle(p)`, so its turn stops a
        precision short of the whole and a draw past that decodes to the identity rather than to
        itself.
    ]]
    ["rotation.axis"] = {
        draw = function (rng)
            local axis = fine (rng, "rotation.axis")
            return shaped ("rotation.axis", { min = Rng.int (rng, 1, #AXES), step = axis.step })
        end,
        build = function (shape) return Lync.rotation.axis (AXES[shape.min], shape.step) end,
        inside = function (shape, rng)
            local turn = Rng.number (rng, 0, math.rad (TURN - shape.step))
            return CFrame.fromAxisAngle (AXES[shape.min], turn)
        end,
        outside = function () return 0 end,
        slack = function (shape) return math.rad (shape.step) end,
    },

    ["rotation.direction"] = {
        draw = function (rng) return fine (rng, "rotation.direction") end,
        build = function (shape) return Lync.rotation.direction (shape.step) end,
        inside = function (_, rng) return turned (rng) end,
        outside = function () return 0 end,
        slack = function () return nil end,
    },

    ["rotation.quat"] = {
        draw = function (rng) return fine (rng, "rotation.quat") end,
        build = function (shape) return Lync.rotation.quat (shape.step) end,
        inside = function (_, rng) return turned (rng) end,
        outside = function () return 0 end,
        slack = function (shape) return math.rad (shape.step) end,
    },

    color3 = {
        draw = function () return shaped ("color3") end,
        build = function () return Lync.color3 () end,
        inside = function (_, rng) return Color3.new (f32 (rng), f32 (rng), f32 (rng)) end,
        outside = function () return 0 end,
    },

    --[[
        Five bits, six, and five. A drawn channel lands on the grid it decodes to, which is a
        convenience of the draw and not a promise of the codec: a caller handing it any other colour
        gets the nearest grid point, so the kind rounds and declares how far. Drawing on the grid
        and declaring no rounding would make the suite pass on the one input that cannot show it.
    ]]
    ["color3.rgb565"] = {
        draw = function () return shaped ("color3.rgb565") end,
        build = function () return Lync.color3.rgb565 () end,
        inside = function (_, rng)
            local red = Rng.int (rng, 0, RED) / RED
            local green = Rng.int (rng, 0, GREEN) / GREEN
            return Color3.new (red, green, Rng.int (rng, 0, BLUE) / BLUE)
        end,
        outside = function () return 0 end,
        slack = function () return 1 / (2 * math.min (RED, GREEN, BLUE)) end,
    },

    ["color3.palette"] = {
        draw = function (rng)
            local size = Rng.int (rng, 1, WIDTH)
            return shaped ("color3.palette", { min = size })
        end,
        build = function (shape) return Lync.color3.palette (palette (shape.min)) end,
        inside = function (shape, rng) return Rng.pick (rng, palette (shape.min)) end,
        -- Every palette member is fully saturated, so a washed colour is in none of them.
        outside = function () return Color3.new (0.123, 0.456, 0.789) end,
    },

    optional = {
        draw = function (rng, depth)
            return shaped ("optional", { of = { present (Generate.shape (rng, depth - 1)) } })
        end,
        build = function (shape) return Lync.optional (Generate.codec (shape.of[1])) end,
        inside = function (shape, rng)
            if Rng.bool (rng) then return nil end
            return Generate.value (shape.of[1], rng)
        end,
        outside = function (shape, rng) return Generate.outside (shape.of[1], rng) end,
        slack = function (shape) return Generate.slack (shape.of[1]) end,
    },

    array = {
        draw = function (rng, depth)
            local low, high = bounds (rng, SPAN)
            local of = { present (Generate.shape (rng, depth - 1)) }
            return shaped ("array", { of = of, min = low, max = high })
        end,
        build = function (shape)
            return Lync.array (Generate.codec (shape.of[1]), shape.min, shape.max)
        end,
        inside = function (shape, rng)
            local count = Rng.int (rng, shape.min, shape.max)
            local out = table.create (count) :: { any }
            for _ = 1, count do
                table.insert (out, Generate.value (shape.of[1], rng))
            end
            return out
        end,
        outside = function (shape, rng)
            local out = table.create (shape.max + 1) :: { any }
            for _ = 1, shape.max + 1 do
                table.insert (out, Generate.value (shape.of[1], rng))
            end
            return out
        end,
        slack = function (shape) return Generate.slack (shape.of[1]) end,
    },

    struct = {
        draw = function (rng, depth)
            local count = Rng.int (rng, 1, WIDTH)
            local of = table.create (count) :: { Shape }
            for _ = 1, count do
                table.insert (of, Generate.shape (rng, depth - 1))
            end
            return shaped ("struct", { of = of, names = labels (count, "f") })
        end,
        build = function (shape)
            local fields = {}
            for index, name in shape.names do
                fields[name] = Generate.codec (shape.of[index])
            end
            return Lync.struct (fields)
        end,
        inside = function (shape, rng)
            local record = {}
            for index, name in shape.names do
                record[name] = Generate.value (shape.of[index], rng)
            end
            return record
        end,
        -- A field the struct does not declare, which is the throw the row names.
        outside = function (shape, rng)
            local record = { f0 = true }
            for index, name in shape.names do
                record[name] = Generate.value (shape.of[index], rng)
            end
            return record
        end,
        slack = function (shape) return loosest (shape.of) end,
    },

    --[[
        Entries are counted out rather than drawn and deduplicated: the nth key of a shape is a pure
        function of n, so a map of any legal size is built in one pass and a narrow key domain caps
        the size instead of hanging.
    ]]
    map = {
        draw = function (rng, depth)
            local key = Generate.among (rng, KEYS, 0)
            local low, high = bounds (rng, math.min (SPAN, domain (key)))
            local of = { key, present (Generate.shape (rng, depth - 1)) }
            return shaped ("map", { of = of, min = low, max = high })
        end,
        build = function (shape)
            local key = Generate.codec (shape.of[1])
            return Lync.map (key, Generate.codec (shape.of[2]), shape.min, shape.max)
        end,
        inside = function (shape, rng)
            local count = Rng.int (rng, shape.min, shape.max)
            local from = Rng.int (rng, 0, 1000)

            local entries = {}
            for index = 1, count do
                entries[nth (shape.of[1], from + index)] = Generate.value (shape.of[2], rng)
            end
            return entries
        end,
        --[[
            One entry past the bound. Where the key domain is no wider than the bound and has no
            further key to give, it is one key outside the domain, the same step out by the only
            door left.
        ]]
        outside = function (shape, rng)
            local key = shape.of[1]
            local entries = {}
            if domain (key) <= shape.max then
                entries[Generate.outside (key, rng)] = Generate.value (shape.of[2], rng)
                return entries
            end

            for index = 1, shape.max + 1 do
                entries[nth (key, index)] = Generate.value (shape.of[2], rng)
            end
            return entries
        end,
        slack = function (shape) return loosest (shape.of) end,
    },

    tagged = {
        draw = function (rng, depth)
            local count = Rng.int (rng, 1, WIDTH)
            local of = table.create (count) :: { Shape }
            for _ = 1, count do
                table.insert (of, Generate.record (rng, depth - 1))
            end
            return shaped ("tagged", { of = of, names = labels (count, "v"), text = "tag" })
        end,
        build = function (shape)
            local variants = {}
            for index, name in shape.names do
                variants[name] = Generate.codec (shape.of[index])
            end
            return Lync.tagged (shape.text, variants)
        end,
        inside = function (shape, rng)
            local index = Rng.int (rng, 1, #shape.names)
            local record = Generate.value (shape.of[index], rng)
            record[shape.text] = shape.names[index]
            return record
        end,
        outside = function (shape, rng)
            local record = Generate.value (shape.of[1], rng)
            record[shape.text] = "v0"
            return record
        end,
        slack = function (shape) return loosest (shape.of) end,
    },

    vec2 = {
        draw = function (rng, depth)
            if depth <= 0 or not Rng.bool (rng) then return shaped ("vec2") end
            return shaped ("vec2", { of = { Generate.among (rng, NUMBERS, depth - 1) } })
        end,
        build = function (shape)
            if shape.of[1] == nil then return Lync.vec2 () end
            return Lync.vec2 (Generate.codec (shape.of[1]))
        end,
        inside = function (shape, rng)
            local component = shape.of[1]
            if component == nil then return Vector2.new (f32 (rng), f32 (rng)) end
            return Vector2.new (Generate.value (component, rng), Generate.value (component, rng))
        end,
        outside = function () return 0 end,
        slack = function (shape) return loosest (shape.of) end,
    },

    vec3 = {
        draw = function (rng, depth)
            if depth <= 0 or not Rng.bool (rng) then return shaped ("vec3") end
            return shaped ("vec3", { of = { Generate.among (rng, NUMBERS, depth - 1) } })
        end,
        build = function (shape)
            if shape.of[1] == nil then return Lync.vec3 () end
            return Lync.vec3 (Generate.codec (shape.of[1]))
        end,
        inside = function (shape, rng)
            local component = shape.of[1]
            if component == nil then return Vector3.new (f32 (rng), f32 (rng), f32 (rng)) end
            return Vector3.new (
                Generate.value (component, rng),
                Generate.value (component, rng),
                Generate.value (component, rng)
            )
        end,
        outside = function () return 0 end,
        slack = function (shape) return loosest (shape.of) end,
    },

    cframe = {
        draw = function (rng, depth)
            local position = Generate.among (rng, POSITIONS, depth - 1)
            local rotation = Generate.among (rng, ROTATIONS, depth - 1)
            return shaped ("cframe", { of = { position, rotation } })
        end,
        build = function (shape)
            local position = Generate.codec (shape.of[1])
            return Lync.cframe (position, Generate.codec (shape.of[2]))
        end,
        inside = function (shape, rng)
            local rotation = Generate.value (shape.of[2], rng) :: CFrame
            return rotation + Generate.value (shape.of[1], rng)
        end,
        outside = function () return 0 end,
        slack = function (shape) return loosest (shape.of) end,
    },
}

--[[
    Kinds whose encoded width turns on the value, and the value that widens one. Everything absent
    from this table encodes as wide for any value in its domain, so its widest is whatever an empty
    tape draws.
]]
const WIDENS: { [string]: (Shape) -> { any } } = {
    vlq = function () return { EXACT - 1 } end,
    vli = function () return { -(EXACT - 1) } end,
    str = function (shape) return { string.rep ("\255", shape.max) } end,
    buffer = function (shape) return { Rng.bytes (Rng.replay ({}), shape.max) } end,

    ["str.alphabet"] = function (shape)
        return { string.rep (string.sub (shape.text, 1, 1), shape.max) }
    end,

    optional = function (shape) return Generate.widest (shape.of[1]) end,

    array = function (shape)
        return spread (widestOf (shape.of), function (chosen)
            local out = table.create (shape.max) :: { any }
            for _ = 1, shape.max do
                table.insert (out, chosen[1])
            end
            return out
        end)
    end,

    map = function (shape)
        return spread (widestOf ({ shape.of[2] }), function (chosen)
            local entries = {}
            for index = 1, shape.max do
                entries[nth (shape.of[1], index)] = chosen[1]
            end
            return entries
        end)
    end,

    struct = function (shape)
        return spread (widestOf (shape.of), function (chosen)
            local record = {}
            for index, name in shape.names do
                record[name] = chosen[index]
            end
            return record
        end)
    end,

    tagged = function (shape)
        local out = {}
        for index, name in shape.names do
            for _, record in Generate.widest (shape.of[index]) do
                local held = table.clone (record)
                held[shape.text] = name
                table.insert (out, held)
            end
        end
        return out
    end,

    vec2 = function (shape)
        if shape.of[1] == nil then return { Vector2.new (0, 0) } end
        return spread (widestOf (shape.of), function (chosen)
            local held = narrowed (chosen[1])
            return Vector2.new (held, held)
        end)
    end,

    vec3 = function (shape)
        if shape.of[1] == nil then return { Vector3.zero } end
        return spread (widestOf (shape.of), function (chosen)
            local held = narrowed (chosen[1])
            return Vector3.new (held, held, held)
        end)
    end,

    cframe = function (shape)
        return spread (
            widestOf (shape.of),
            function (chosen) return (chosen[2] :: CFrame) + (chosen[1] :: Vector3) end
        )
    end,
}

--[[
    The four sizes a kind is asked for, floor first. Only a kind carrying a count or a presence bit
    answers differently to each, and only those are listed below: everything absent from the table
    has one size and answers a drawn value whichever is asked for.
]]
const SIZED = table.freeze ({ "empty", "one", "typical", "widest" })

-- How many a collection holds at a size, never past the bound the shape declares.
local function counted (shape: Shape, at: string): number
    if at == "empty" then return shape.min end
    return math.min (shape.max, shape.min + 1)
end

const SIZES: { [string]: (Shape, string, Rng.Rng) -> any } = {
    str = function (shape, at) return string.rep ("a", counted (shape, at)) end,
    buffer = function (shape, at) return buffer.create (counted (shape, at)) end,

    ["str.alphabet"] = function (shape, at)
        return string.rep (string.sub (shape.text, 1, 1), counted (shape, at))
    end,

    optional = function (shape, at, rng)
        if at == "empty" then return nil end
        return Generate.sized (shape.of[1], at, rng)
    end,

    array = function (shape, at, rng)
        local out = {}
        for _ = 1, counted (shape, at) do
            table.insert (out, Generate.sized (shape.of[1], at, rng))
        end
        return out
    end,

    map = function (shape, at, rng)
        local entries = {}
        for index = 1, counted (shape, at) do
            entries[nth (shape.of[1], index)] = Generate.sized (shape.of[2], at, rng)
        end
        return entries
    end,

    struct = function (shape, at, rng)
        local record = {}
        for index, name in shape.names do
            record[name] = Generate.sized (shape.of[index], at, rng)
        end
        return record
    end,

    tagged = function (shape, at, rng)
        local record = Generate.sized (shape.of[1], at, rng)
        record[shape.text] = shape.names[1]
        return record
    end,

    vec2 = function (shape, at, rng)
        if shape.of[1] == nil then return Vector2.zero end
        local component = Generate.sized (shape.of[1], at, rng)
        return Vector2.new (component, component)
    end,

    vec3 = function (shape, at, rng)
        if shape.of[1] == nil then return Vector3.zero end
        local component = Generate.sized (shape.of[1], at, rng)
        return Vector3.new (component, component, component)
    end,

    cframe = function (shape, at, rng)
        local rotation = Generate.sized (shape.of[2], at, rng) :: CFrame
        return rotation + Generate.sized (shape.of[1], at, rng)
    end,
}

-- Public --------------------------------------------------------------

-- Every constructor a shape can name, and the one it never will.
Generate.KINDS = ALL
Generate.UNGENERATED = UNGENERATED
Generate.TOTAL = TOTAL

--[[
    The kinds a set may partition by, which a caller needs to pick that field out of a drawn record.
    Exported rather than restated at the caller, because what a key may be is a fact about this
    vocabulary and this module is where the vocabulary lives.
]]
Generate.KEYED = PARTS

-- The four sizes `sized` answers, floor first, so an empty tape asks for the emptiest.
Generate.SIZED = SIZED

--[[
    The depth a suite draws at, one past what a shape spends unasked, so a drawn tree reaches a
    composite inside a composite and no further. Deeper buys a longer failing tape rather than a
    shape a schema had not already reached. Five suites picked it apart before this held it.
]]
Generate.DEEP = DEPTH + 1

--[[
    A random shape, composite while the depth lasts and a leaf after. The depth bound is what keeps
    a tape of any words finite. A tape of zeros stops at the first draw, which is `bool`.
]]
function Generate.shape (rng: Rng.Rng, depth: number?): Shape
    local left = if depth ~= nil then depth else DEPTH
    return Generate.among (rng, if left > 0 then ALL else LEAVES, left)
end

--[[
    A shape drawn from a named few, which is how a slot that takes only some kinds is filled: a
    numeric component, a position, a rotation, a map key.
]]
function Generate.among (rng: Rng.Rng, from: { string }, depth: number): Shape
    return KINDS[Rng.pick (rng, from)].draw (rng, depth)
end

-- A record shape, which is what a set replicates and what a schema fuzzer starts from.
function Generate.record (rng: Rng.Rng, depth: number?): Shape
    return KINDS.struct.draw (rng, if depth ~= nil then depth else DEPTH)
end

function Generate.codec (shape: Shape): Lync.Codec<any>
    local kind = KINDS[shape.at]
    return kind.build (shape)
end

-- A value the codec accepts, drawn from the parameters that built it.
function Generate.value (shape: Shape, rng: Rng.Rng): any
    local kind = KINDS[shape.at]
    return kind.inside (shape, rng)
end

--[[
    A value one step outside, which the codec throws on encode and drops on decode. One kind is the
    exception and cannot be otherwise, and it is `TOTAL` above: what `outside` answers for it is
    what a caller would be mistaken to pass, and a suite turning that into an expected refusal reads
    `TOTAL` and leaves it out.
]]
function Generate.outside (shape: Shape, rng: Rng.Rng): any
    local kind = KINDS[shape.at]
    return kind.outside (shape, rng)
end

--[[
    How far a decoded value may sit from the one encoded: zero when the kind is exact, and nil when
    the kind keeps less than it was handed, where the only identity is a re-encode. A composite
    answers for its widest child.
]]
function Generate.slack (shape: Shape): number?
    local of = KINDS[shape.at].slack
    if of == nil then return 0 end
    return of (shape)
end

--[[
    A frame's bytes, damaged one of the four ways a frame is damaged, with the way named so a
    failure says which. Bytes rather than a buffer, because each is a cut, a splice or a
    substitution.
]]
function Generate.corrupted (rng: Rng.Rng, text: string, other: string?): (string, string)
    local ways = { "cut" }
    if #text > 0 then
        table.insert (ways, "flip")
        table.insert (ways, "swap")
    end
    if other ~= nil then table.insert (ways, "splice") end

    local way = Rng.pick (rng, ways)
    if way == "cut" then return string.sub (text, 1, Rng.int (rng, 0, #text)), way end

    if way == "splice" then
        local held = other :: string
        local keep = Rng.int (rng, 0, #text)
        return string.sub (text, 1, keep) .. string.sub (held, Rng.int (rng, 1, #held + 1)), way
    end

    local at = Rng.int (rng, 1, #text)
    local byte = string.byte (text, at)
    local moved = if way == "flip"
        then bit32.bxor (byte, bit32.lshift (1, Rng.int (rng, 0, 7)))
        else Rng.int (rng, 0, 255)

    return `{string.sub (text, 1, at - 1)}{string.char (moved)}{string.sub (text, at + 1)}`, way
end

--[[
    A value at one of the four sizes a kind can be asked for. A uniform draw lands in the middle of
    every range it touches, so the sizes a length check is written for are the ones it reaches
    least: a collection at its floor, a collection holding exactly one, and a collection at its
    ceiling.
]]
function Generate.sized (shape: Shape, at: string, rng: Rng.Rng): any
    if at == "widest" then return Generate.widest (shape)[1] end
    if at == "typical" then return Generate.value (shape, rng) end

    local size = SIZES[shape.at]
    if size == nil then return Generate.value (shape, rng) end
    return size (shape, at, rng)
end

--[[
    Every value worth trying for the widest encoding a shape can produce. A bound no input reaches
    is a bound nobody computed, and only the parameters a shape was drawn from say what attains it.
]]
function Generate.widest (shape: Shape): { any }
    local widen = WIDENS[shape.at]
    if widen ~= nil then return widen (shape) end
    return { Generate.value (shape, Rng.replay ({})) }
end

--[[
    A namespace's worth of definitions, drawn, keyed the way `define` takes them. All three kinds
    come up, because a compiler answers for all three and two of its rules are about which kind a
    thing is rather than about the codec inside it. A packet is drawn first on the simplest choice,
    so an empty tape opens a namespace holding one packet of one boolean.
]]
function Generate.definitions (rng: Rng.Rng, count: number?): { [string]: any }
    local wanted = if count ~= nil then count else Rng.int (rng, 1, WIDTH)
    local out = {}

    for _, name in labels (wanted, "d") do
        local pick = Rng.int (rng, 1, 3)
        if pick == 1 then
            out[name] = Lync.packet (Generate.codec (Generate.shape (rng)))
            continue
        end
        if pick == 2 then
            local request = Generate.codec (Generate.shape (rng))
            out[name] = Lync.query (request, Generate.codec (Generate.shape (rng)))
            continue
        end
        out[name] = Lync.replicate (Generate.codec (Generate.record (rng)))
    end
    return out
end

--[[
    The shapes worth holding that a draw will not reach: the deepest nesting, the widest struct, one
    where every field may be absent, and the sixty-four a set is capped at. Each is named, because a
    failure reading "adversary 3" costs a person the same look every time.
]]
function Generate.adversaries (): { { name: string, shape: Shape } }
    local deep = shaped ("bool")
    for _ = 1, DEPTH * 2 do
        deep = shaped ("array", { of = { deep }, min = 0, max = 2 })
    end

    local function wide (count: number, each: (number) -> Shape): Shape
        local of = table.create (count) :: { Shape }
        for index = 1, count do
            table.insert (of, each (index))
        end
        return shaped ("struct", { of = of, names = labels (count, "f") })
    end

    local function flag () return shaped ("bool") end
    local function maybe () return shaped ("optional", { of = { shaped ("bool") } }) end
    local function mixed (index: number): Shape
        if index % 2 == 0 then return shaped ("bool") end
        return shaped ("int", { min = 0, max = 1000 })
    end

    return {
        { name = "deepest", shape = deep },
        { name = "widest", shape = wide (WIDTH * 4, flag) },
        { name = "all-optional", shape = wide (WIDTH, maybe) },
        { name = "set-maximum", shape = wide (Protocol.MAX_FIELDS, mixed) },
    }
end

return table.freeze (Generate)
