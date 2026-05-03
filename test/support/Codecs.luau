--!strict
--!optimize 2
-- Codec catalog. Drives parametrized round-trip, validate, wire, and
-- property suites. Adding a new codec means adding one entry here and
-- the suites below pick it up automatically.

local Lync = require(script.Parent.Parent.Parent)

-- Public types -----------------------------------------------------------

export type Entry = {
    name: string,
    category: "primitive" | "datatype" | "composite" | "meta",
    codec: any,
    --[[
        valid     : sample inputs that must round-trip cleanly
        invalid   : values Gate.validate must reject (with the codec)
        compare   : how to assert "decoded matches input" (approximate for
                    quantized codecs, exact otherwise)
        canonical : optional reference input for wire-pinning
        bytes     : optional reference output for wire-pinning
        generate  : random valid input given an RNG
        wireSize  : if fixed, the exact byte count
    ]]
    valid: { any },
    invalid: { any }?,
    compare: (a: any, b: any) -> boolean,
    canonical: any?,
    bytes: { number }?,
    generate: ((rng: any) -> any)?,
    wireSize: number?,
}

-- Private ----------------------------------------------------------------

local function exact(a: any, b: any): boolean
    return a == b
end

--[[
    Relative-tolerance compare. f32 has ~7 decimal digits of mantissa, so
    absolute tolerance breaks for any value above ~1e3. Use relative
    tolerance with an absolute floor for values near zero.
]]
local function nearF32(a: number, b: number): boolean
    if a == b then
        return true
    end
    if a ~= a or b ~= b then
        return a ~= a and b ~= b
    end
    local mag = math.max(math.abs(a), math.abs(b))
    if mag < 1 then
        return math.abs(a - b) < 1e-4
    end
    return math.abs(a - b) / mag < 1e-5
end

local function nearF64(a: number, b: number): boolean
    if a == b then
        return true
    end
    if a ~= a or b ~= b then
        return a ~= a and b ~= b
    end
    local mag = math.max(math.abs(a), math.abs(b))
    if mag < 1 then
        return math.abs(a - b) < 1e-12
    end
    return math.abs(a - b) / mag < 1e-12
end

local function nearF16(a: number, b: number): boolean
    if a ~= a and b ~= b then
        return true
    end
    if math.abs(b) > 65504 then
        return math.abs(a) > 65504 and ((a > 0) == (b > 0))
    end
    if math.abs(b) < 1 then
        return math.abs(a - b) < 1e-3
    end
    return math.abs(a - b) / math.abs(b) < 1e-2
end

local function vec2Near(a: Vector2, b: Vector2): boolean
    return nearF32(a.X, b.X) and nearF32(a.Y, b.Y)
end

local function vec3Near(a: Vector3, b: Vector3): boolean
    return nearF32(a.X, b.X) and nearF32(a.Y, b.Y) and nearF32(a.Z, b.Z)
end

local function vec2Int16Eq(a: Vector2int16, b: Vector2int16): boolean
    return a.X == b.X and a.Y == b.Y
end

local function vec3Int16Eq(a: Vector3int16, b: Vector3int16): boolean
    return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end

local function color3Near(a: Color3, b: Color3): boolean
    return math.abs(a.R - b.R) < 1 / 200
        and math.abs(a.G - b.G) < 1 / 200
        and math.abs(a.B - b.B) < 1 / 200
end

local function cframeNear(a: CFrame, b: CFrame): boolean
    if not vec3Near(a.Position, b.Position) then
        return false
    end
    -- Basis-vector compare avoids gimbal lock and Euler wrap discontinuities.
    return (a.RightVector - b.RightVector).Magnitude < 1e-3
        and (a.UpVector - b.UpVector).Magnitude < 1e-3
        and (a.LookVector - b.LookVector).Magnitude < 1e-3
end

--[[
    Compare CFrames by basis vectors instead of Euler angles. Euler is
    discontinuous at gimbal lock and wraps modulo 2*pi, which causes
    spurious mismatches near pi-related angles. Basis vectors are smooth.
    Tolerance 0.02 corresponds to roughly 1.15 degrees of angular drift,
    well within the smallest-three quantization budget (10 bits per axis).
]]
local function cframeCompressedNear(a: CFrame, b: CFrame): boolean
    if not vec3Near(a.Position, b.Position) then
        return false
    end
    return (a.RightVector - b.RightVector).Magnitude < 0.02
        and (a.UpVector - b.UpVector).Magnitude < 0.02
        and (a.LookVector - b.LookVector).Magnitude < 0.02
end

local function udimEq(a: UDim, b: UDim): boolean
    return nearF32(a.Scale, b.Scale) and a.Offset == b.Offset
end

local function udim2Eq(a: UDim2, b: UDim2): boolean
    return udimEq(a.X, b.X) and udimEq(a.Y, b.Y)
end

local function numberRangeNear(a: NumberRange, b: NumberRange): boolean
    return nearF32(a.Min, b.Min) and nearF32(a.Max, b.Max)
end

local function rectNear(a: Rect, b: Rect): boolean
    return vec2Near(a.Min, b.Min) and vec2Near(a.Max, b.Max)
end

local function rayNear(a: Ray, b: Ray): boolean
    return vec3Near(a.Origin, b.Origin) and vec3Near(a.Direction, b.Direction)
end

local function region3Near(a: Region3, b: Region3): boolean
    return vec3Near(a.CFrame.Position, b.CFrame.Position) and vec3Near(a.Size, b.Size)
end

local function region3Int16Eq(a: Region3int16, b: Region3int16): boolean
    return vec3Int16Eq(a.Min, b.Min) and vec3Int16Eq(a.Max, b.Max)
end

local function numberSequenceNear(a: NumberSequence, b: NumberSequence): boolean
    if #a.Keypoints ~= #b.Keypoints then
        return false
    end
    for i = 1, #a.Keypoints do
        local ka, kb = a.Keypoints[i], b.Keypoints[i]
        if
            not (
                nearF32(ka.Time, kb.Time)
                and nearF32(ka.Value, kb.Value)
                and nearF32(ka.Envelope, kb.Envelope)
            )
        then
            return false
        end
    end
    return true
end

local function colorSequenceNear(a: ColorSequence, b: ColorSequence): boolean
    if #a.Keypoints ~= #b.Keypoints then
        return false
    end
    for i = 1, #a.Keypoints do
        local ka, kb = a.Keypoints[i], b.Keypoints[i]
        if not (nearF32(ka.Time, kb.Time) and color3Near(ka.Value, kb.Value)) then
            return false
        end
    end
    return true
end

local function bufferEq(a: buffer, b: buffer): boolean
    local la, lb = buffer.len(a), buffer.len(b)
    if la ~= lb then
        return false
    end
    for i = 0, la - 1 do
        if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
            return false
        end
    end
    return true
end

local nan = 0 / 0

-- Public -----------------------------------------------------------------

local Catalog = {}

local list: { Entry } = {
    -- Primitives -----------------------------------------------------

    {
        name = "bool",
        category = "primitive",
        codec = Lync.bool,
        valid = { true, false },
        invalid = { 0, 1, "true", nil, {}, nan },
        compare = exact,
        canonical = true,
        bytes = { 0x01 },
        wireSize = 1,
        generate = function(rng): boolean
            return rng:bool()
        end,
    },
    {
        name = "u8",
        category = "primitive",
        codec = Lync.int(0, 255),
        valid = { 0, 1, 127, 128, 254, 255 },
        invalid = { -1, 256, 1.5, "5", true, nil, nan, math.huge },
        compare = exact,
        canonical = 42,
        bytes = { 0x2A },
        wireSize = 1,
        generate = function(rng): number
            return rng:int(0, 255)
        end,
    },
    {
        name = "u16",
        category = "primitive",
        codec = Lync.int(0, 65535),
        valid = { 0, 1, 255, 256, 65534, 65535 },
        invalid = { -1, 65536, 1.5, "5", true, nan },
        compare = exact,
        canonical = 0x1234,
        bytes = { 0x34, 0x12 },
        wireSize = 2,
        generate = function(rng): number
            return rng:int(0, 65535)
        end,
    },
    {
        name = "u32",
        category = "primitive",
        codec = Lync.int(0, 0xFFFFFFFF),
        valid = { 0, 1, 65535, 65536, 0x7FFFFFFF, 0xFFFFFFFF },
        invalid = { -1, 1.5, "5", nan, math.huge },
        compare = exact,
        canonical = 0x12345678,
        bytes = { 0x78, 0x56, 0x34, 0x12 },
        wireSize = 4,
        generate = function(rng): number
            return rng:int(0, 0xFFFFFFFF)
        end,
    },
    {
        name = "i8",
        category = "primitive",
        codec = Lync.int(-128, 127),
        valid = { -128, -1, 0, 1, 127 },
        invalid = { -129, 128, 1.5, "5", nan },
        compare = exact,
        canonical = -1,
        bytes = { 0xFF },
        wireSize = 1,
        generate = function(rng): number
            return rng:int(-128, 127)
        end,
    },
    {
        name = "i16",
        category = "primitive",
        codec = Lync.int(-32768, 32767),
        valid = { -32768, -1, 0, 1, 32767 },
        invalid = { -32769, 32768, 1.5, "5", nan },
        compare = exact,
        canonical = -2,
        bytes = { 0xFE, 0xFF },
        wireSize = 2,
        generate = function(rng): number
            return rng:int(-32768, 32767)
        end,
    },
    {
        name = "i32",
        category = "primitive",
        codec = Lync.int(-2147483648, 2147483647),
        valid = { -2147483648, -1, 0, 1, 2147483647 },
        invalid = { 1.5, "5", nan },
        compare = exact,
        canonical = -1,
        bytes = { 0xFF, 0xFF, 0xFF, 0xFF },
        wireSize = 4,
        generate = function(rng): number
            return rng:int(-0x80000000, 0x7FFFFFFF)
        end,
    },
    {
        name = "f16",
        category = "primitive",
        codec = Lync.f16,
        valid = { 0, 1, -1, 0.5, 100.5, -42.25, 65504, -65504 },
        invalid = { "x", true, nil },
        compare = nearF16,
        wireSize = 2,
        generate = function(rng): number
            return rng:float(-1000, 1000)
        end,
    },
    {
        name = "f32",
        category = "primitive",
        codec = Lync.f32,
        valid = { 0, 1, -1, math.pi, 1e10, -1e10, 1e-10 },
        invalid = { "x", true, nil, nan, math.huge },
        compare = nearF32,
        wireSize = 4,
        generate = function(rng): number
            return rng:float(-1e6, 1e6)
        end,
    },
    {
        name = "f64",
        category = "primitive",
        codec = Lync.f64,
        valid = { 0, 1, -1, math.pi, 1e100, -1e-100 },
        invalid = { "x", true, nil, nan, math.huge },
        compare = nearF64,
        wireSize = 8,
        generate = function(rng): number
            return rng:float(-1e9, 1e9)
        end,
    },

    -- Datatypes ------------------------------------------------------

    {
        name = "vec2",
        category = "datatype",
        codec = Lync.vec2,
        valid = {
            Vector2.zero,
            Vector2.new(1.5, -3.25),
            Vector2.new(10000, -10000),
        },
        invalid = { 1, "x", true, nil, Vector3.zero },
        compare = vec2Near,
        wireSize = 8,
        generate = function(rng): Vector2
            return Vector2.new(rng:float(-1000, 1000), rng:float(-1000, 1000))
        end,
    },
    {
        name = "vec3",
        category = "datatype",
        codec = Lync.vec3,
        valid = {
            Vector3.zero,
            Vector3.new(1, 2, 3),
            Vector3.new(-100, -200, -300),
        },
        invalid = { 1, "x", true, Vector2.zero },
        compare = vec3Near,
        wireSize = 12,
        generate = function(rng): Vector3
            return Vector3.new(
                rng:float(-1000, 1000),
                rng:float(-1000, 1000),
                rng:float(-1000, 1000)
            )
        end,
    },
    {
        name = "vec2int16",
        category = "datatype",
        codec = Lync.vec2int16,
        valid = {
            Vector2int16.new(0, 0),
            Vector2int16.new(100, -200),
            Vector2int16.new(-32768, 32767),
        },
        invalid = { Vector2.zero, 1, "x" },
        compare = vec2Int16Eq,
        wireSize = 4,
        generate = function(rng): Vector2int16
            return Vector2int16.new(rng:int(-32768, 32767), rng:int(-32768, 32767))
        end,
    },
    {
        name = "vec3int16",
        category = "datatype",
        codec = Lync.vec3int16,
        valid = {
            Vector3int16.new(0, 0, 0),
            Vector3int16.new(10, -20, 30),
            Vector3int16.new(-32768, 0, 32767),
        },
        invalid = { Vector3.zero, 1, "x" },
        compare = vec3Int16Eq,
        wireSize = 6,
        generate = function(rng): Vector3int16
            return Vector3int16.new(
                rng:int(-32768, 32767),
                rng:int(-32768, 32767),
                rng:int(-32768, 32767)
            )
        end,
    },
    {
        name = "color3",
        category = "datatype",
        codec = Lync.color3,
        valid = {
            Color3.fromRGB(0, 0, 0),
            Color3.fromRGB(255, 255, 255),
            Color3.fromRGB(128, 64, 32),
        },
        invalid = { 1, "x", Vector3.zero },
        compare = color3Near,
        wireSize = 3,
        generate = function(rng): Color3
            return Color3.fromRGB(rng:int(0, 255), rng:int(0, 255), rng:int(0, 255))
        end,
    },
    {
        name = "cframe",
        category = "datatype",
        codec = Lync.cframe,
        valid = {
            CFrame.new(),
            CFrame.new(10, 20, 30),
            CFrame.new(0, 0, 0) * CFrame.Angles(0.5, 1.0, 0.3),
        },
        invalid = { 1, "x", Vector3.zero },
        compare = cframeNear,
        wireSize = 24,
        generate = function(rng): CFrame
            return CFrame.new(rng:float(-100, 100), rng:float(-100, 100), rng:float(-100, 100))
                * CFrame.Angles(rng:float(-3, 3), rng:float(-3, 3), rng:float(-3, 3))
        end,
    },
    {
        name = "cframeCompressed",
        category = "datatype",
        codec = Lync.cframe(),
        valid = {
            CFrame.new(),
            CFrame.new(5, 10, 15),
            CFrame.new(1, 2, 3) * CFrame.Angles(2.5, 0, 0),
        },
        invalid = { 1, "x", Vector3.zero },
        compare = cframeCompressedNear,
        wireSize = 16,
        generate = function(rng): CFrame
            return CFrame.new(rng:float(-100, 100), rng:float(-100, 100), rng:float(-100, 100))
                * CFrame.Angles(rng:float(-2, 2), rng:float(-2, 2), rng:float(-2, 2))
        end,
    },
    {
        name = "udim",
        category = "datatype",
        codec = Lync.udim,
        valid = {
            UDim.new(0, 0),
            UDim.new(0.5, 100),
            UDim.new(1, -50),
        },
        invalid = { 1, "x", Vector3.zero },
        compare = udimEq,
        wireSize = 8,
        generate = function(rng): UDim
            return UDim.new(rng:float(-1, 1), rng:int(-100000, 100000))
        end,
    },
    {
        name = "udim2",
        category = "datatype",
        codec = Lync.udim2,
        valid = {
            UDim2.new(),
            UDim2.new(UDim.new(0.5, 10), UDim.new(1, 20)),
            UDim2.new(UDim.new(0, -100), UDim.new(0, -200)),
        },
        invalid = { 1, "x" },
        compare = udim2Eq,
        wireSize = 16,
        generate = function(rng): UDim2
            return UDim2.new(
                UDim.new(rng:float(-1, 1), rng:int(-1000, 1000)),
                UDim.new(rng:float(-1, 1), rng:int(-1000, 1000))
            )
        end,
    },
    {
        name = "numberRange",
        category = "datatype",
        codec = Lync.numberRange,
        valid = {
            NumberRange.new(0, 100),
            NumberRange.new(-50, 50),
            NumberRange.new(42, 42),
        },
        invalid = { 1, "x" },
        compare = numberRangeNear,
        wireSize = 8,
        generate = function(rng): NumberRange
            local min = rng:float(-100, 100)
            local max = min + rng:float(0, 100)
            return NumberRange.new(min, max)
        end,
    },
    {
        name = "rect",
        category = "datatype",
        codec = Lync.rect,
        valid = {
            Rect.new(0, 0, 0, 0),
            Rect.new(10, 20, 100, 200),
            Rect.new(-50, -50, 50, 50),
        },
        invalid = { 1, "x" },
        compare = rectNear,
        wireSize = 16,
        generate = function(rng): Rect
            return Rect.new(
                rng:float(-100, 100),
                rng:float(-100, 100),
                rng:float(-100, 100),
                rng:float(-100, 100)
            )
        end,
    },
    {
        name = "ray",
        category = "datatype",
        codec = Lync.ray,
        valid = {
            Ray.new(Vector3.zero, Vector3.yAxis),
            Ray.new(Vector3.new(1, 2, 3), Vector3.new(0, 1, 0)),
            Ray.new(Vector3.zero, Vector3.new(-1, -1, -1)),
        },
        invalid = { 1, "x" },
        compare = rayNear,
        wireSize = 24,
        generate = function(rng): Ray
            return Ray.new(
                Vector3.new(rng:float(-100, 100), rng:float(-100, 100), rng:float(-100, 100)),
                Vector3.new(rng:float(-1, 1), rng:float(-1, 1), rng:float(-1, 1))
            )
        end,
    },
    {
        name = "region3",
        category = "datatype",
        codec = Lync.region3,
        valid = {
            Region3.new(Vector3.new(-10, -10, -10), Vector3.new(10, 10, 10)),
            Region3.new(Vector3.zero, Vector3.new(50, 50, 50)),
        },
        invalid = { 1, "x" },
        compare = region3Near,
        wireSize = 24,
        generate = function(rng): Region3
            local min = Vector3.new(rng:float(-100, 0), rng:float(-100, 0), rng:float(-100, 0))
            local max = min + Vector3.new(rng:float(1, 100), rng:float(1, 100), rng:float(1, 100))
            return Region3.new(min, max)
        end,
    },
    {
        name = "region3int16",
        category = "datatype",
        codec = Lync.region3int16,
        valid = {
            Region3int16.new(Vector3int16.new(-10, -20, -30), Vector3int16.new(10, 20, 30)),
            Region3int16.new(Vector3int16.new(-32768, 0, 0), Vector3int16.new(32767, 0, 0)),
        },
        invalid = { 1, "x" },
        compare = region3Int16Eq,
        wireSize = 12,
        generate = function(rng): Region3int16
            local minX = rng:int(-32768, 32767)
            local minY = rng:int(-32768, 32767)
            local minZ = rng:int(-32768, 32767)
            return Region3int16.new(
                Vector3int16.new(minX, minY, minZ),
                Vector3int16.new(
                    math.min(32767, minX + rng:int(0, 100)),
                    math.min(32767, minY + rng:int(0, 100)),
                    math.min(32767, minZ + rng:int(0, 100))
                )
            )
        end,
    },
    {
        name = "numberSequence",
        category = "datatype",
        codec = Lync.numberSequence,
        valid = {
            NumberSequence.new(0.5),
            NumberSequence.new({
                NumberSequenceKeypoint.new(0, 0),
                NumberSequenceKeypoint.new(1, 1),
            }),
            NumberSequence.new({
                NumberSequenceKeypoint.new(0, 5, 2),
                NumberSequenceKeypoint.new(0.5, 7, 1),
                NumberSequenceKeypoint.new(1, 10, 3),
            }),
        },
        invalid = { 1, "x" },
        compare = numberSequenceNear,
        generate = nil,
    },
    {
        name = "colorSequence",
        category = "datatype",
        codec = Lync.colorSequence,
        valid = {
            ColorSequence.new(Color3.fromRGB(255, 0, 0)),
            ColorSequence.new({
                ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 0, 0)),
                ColorSequenceKeypoint.new(1, Color3.fromRGB(0, 0, 255)),
            }),
        },
        invalid = { 1, "x" },
        compare = colorSequenceNear,
        generate = nil,
    },
    {
        name = "string",
        category = "datatype",
        codec = Lync.string,
        valid = {
            "",
            "hello",
            string.rep("x", 191),
            string.rep("y", 192),
            "abc\0def\0ghi",
        },
        invalid = { 1, true, nil, {} },
        compare = exact,
        canonical = "hi",
        bytes = { 0x02, 0x68, 0x69 },
        generate = function(rng): string
            return rng:string(rng:int(0, 200))
        end,
    },
    {
        name = "buffer",
        category = "datatype",
        codec = Lync.buff,
        valid = {
            buffer.create(0),
            buffer.create(4),
            buffer.create(191),
            buffer.create(192),
        },
        invalid = { 1, "x", true, nil, {} },
        compare = bufferEq,
        generate = function(rng): buffer
            return rng:bytes(rng:int(0, 200))
        end,
    },
}

Catalog.list = list

local byName: { [string]: Entry } = {}
for _, entry in list do
    byName[entry.name] = entry
end
Catalog.byName = byName

function Catalog.byCategory(category: string): { Entry }
    local out: { Entry } = {}
    for _, entry in list do
        if entry.category == category then
            table.insert(out, entry)
        end
    end
    return out
end

return table.freeze(Catalog)
