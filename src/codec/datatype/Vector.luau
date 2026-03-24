--!strict
--!optimize 2
-- Vector2 and Vector3 codecs with __call for quantized variants.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local ceil = math.ceil
local clamp = math.clamp
local round = math.round
local max = math.max
local min = math.min

--[[
    Shared quantization setup used by both vec2/vec3 __call and Float.luau.
    Returns compBytes, writeFn, readFn, scale, invScale.
]]
local function quantizeSetup(
    rangeMin: number,
    rangeMax: number,
    precision: number
): (
    number,
    (buffer, number, number) -> (),
    (buffer, number) -> number,
    number,
    number
)
    if rangeMin > rangeMax then
        error("[Lync] Lync.vec2/vec3: min must be <= max")
    end
    if precision <= 0 then
        error("[Lync] Lync.vec2/vec3: precision must be positive")
    end

    local delta = rangeMax - rangeMin
    local maxInt = min(0xFFFFFFFF, max(1, ceil(delta / precision)))

    local compBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number

    if maxInt <= 0xFF then
        compBytes = 1
        wfn = buffer.writeu8
        rfn = buffer.readu8
    elseif maxInt <= 0xFFFF then
        compBytes = 2
        wfn = buffer.writeu16
        rfn = buffer.readu16
    else
        compBytes = 4
        wfn = buffer.writeu32
        rfn = buffer.readu32
    end

    local scale = maxInt / delta
    local invScale = delta / maxInt
    return compBytes, wfn, rfn, scale, invScale
end

-- Vec2 ----------------------------------------------------------------

local function writeVec2(b: buffer, off: number, value: Vector2): ()
    buffer.writef32(b, off, value.X)
    buffer.writef32(b, off + 4, value.Y)
end

local function readVec2(b: buffer, off: number): Vector2
    return Vector2.new(buffer.readf32(b, off), buffer.readf32(b, off + 4))
end

local function quantizeVec2(_self: any, rangeMin: number, rangeMax: number, precision: number): any
    local delta = rangeMax - rangeMin
    if delta == 0 then
        local constant = Vector2.new(rangeMin, rangeMin)
        return Base.zero() :: any -- constant value, zero bytes
    end

    local compBytes, wfn, rfn, scale, invScale = quantizeSetup(rangeMin, rangeMax, precision)
    local totalSize = compBytes * 2

    return Base.define(totalSize, function(b: buffer, off: number, value: Vector2): ()
        wfn(b, off, round(clamp(value.X - rangeMin, 0, delta) * scale))
        wfn(b, off + compBytes, round(clamp(value.Y - rangeMin, 0, delta) * scale))
    end, function(b: buffer, off: number): Vector2
        return Vector2.new(
            rfn(b, off) * invScale + rangeMin,
            rfn(b, off + compBytes) * invScale + rangeMin
        )
    end, { _typeCheck = "Vector2", _min = rangeMin, _max = rangeMax })
end

-- Vec3 ----------------------------------------------------------------

local function writeVec3(b: buffer, off: number, value: Vector3): ()
    buffer.writef32(b, off, value.X)
    buffer.writef32(b, off + 4, value.Y)
    buffer.writef32(b, off + 8, value.Z)
end

local function readVec3(b: buffer, off: number): Vector3
    return Vector3.new(
        buffer.readf32(b, off),
        buffer.readf32(b, off + 4),
        buffer.readf32(b, off + 8)
    )
end

local function quantizeVec3(_self: any, rangeMin: number, rangeMax: number, precision: number): any
    local delta = rangeMax - rangeMin
    if delta == 0 then
        return Base.zero() :: any
    end

    local compBytes, wfn, rfn, scale, invScale = quantizeSetup(rangeMin, rangeMax, precision)
    local totalSize = compBytes * 3

    return Base.define(totalSize, function(b: buffer, off: number, value: Vector3): ()
        wfn(b, off, round(clamp(value.X - rangeMin, 0, delta) * scale))
        wfn(b, off + compBytes, round(clamp(value.Y - rangeMin, 0, delta) * scale))
        wfn(b, off + compBytes * 2, round(clamp(value.Z - rangeMin, 0, delta) * scale))
    end, function(b: buffer, off: number): Vector3
        return Vector3.new(
            rfn(b, off) * invScale + rangeMin,
            rfn(b, off + compBytes) * invScale + rangeMin,
            rfn(b, off + compBytes * 2) * invScale + rangeMin
        )
    end, { _typeCheck = "Vector3", _min = rangeMin, _max = rangeMax })
end

-- Public --------------------------------------------------------------

local VectorCodec = {}

VectorCodec.vec2 = setmetatable(
    {
        _size = 8,
        _directWrite = writeVec2,
        _directRead = readVec2,
        _typeCheck = "Vector2",

        write = function(ch: Types.ChannelState, value: Vector2): ()
            local cursor = ch.cursor
            if cursor + 8 > ch.size then
                alloc(ch, 8)
            end
            writeVec2(ch.buff, cursor, value)
            ch.cursor = cursor + 8
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (Vector2, number)
            return readVec2(src, pos), 8
        end,
    } :: any,
    { __call = quantizeVec2 }
)

VectorCodec.vec3 = setmetatable(
    {
        _size = 12,
        _directWrite = writeVec3,
        _directRead = readVec3,
        _typeCheck = "Vector3",

        write = function(ch: Types.ChannelState, value: Vector3): ()
            local cursor = ch.cursor
            if cursor + 12 > ch.size then
                alloc(ch, 12)
            end
            writeVec3(ch.buff, cursor, value)
            ch.cursor = cursor + 12
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (Vector3, number)
            return readVec3(src, pos), 12
        end,
    } :: any,
    { __call = quantizeVec3 }
)

VectorCodec.quantizeSetup = quantizeSetup

return table.freeze(VectorCodec)
