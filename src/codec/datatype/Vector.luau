--!strict
--!native
-- Vector2 / Vector3 codecs. __call yields a quantized variant.

local Base = require(script.Parent.Parent.Base)
local Quantize = require(script.Parent.Parent.Parent.util.Quantize)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local clamp = math.clamp
local round = math.round

local function writeVec2(b: buffer, off: number, value: Vector2): ()
    writef32(b, off, value.X)
    writef32(b, off + 4, value.Y)
end

local function readVec2(b: buffer, off: number): Vector2
    return Vector2.new(readf32(b, off), readf32(b, off + 4))
end

local function writeVec3(b: buffer, off: number, value: Vector3): ()
    writef32(b, off, value.X)
    writef32(b, off + 4, value.Y)
    writef32(b, off + 8, value.Z)
end

local function readVec3(b: buffer, off: number): Vector3
    return Vector3.new(readf32(b, off), readf32(b, off + 4), readf32(b, off + 8))
end

local function quantizeVec2(
    _self,
    rangeMin: number,
    rangeMax: number,
    precision: number
): Types.InternalCodec<Vector2>
    -- Degenerate range: emit nothing, decode to the constant.
    if rangeMax - rangeMin == 0 then
        return Base.constant(Vector2.new(rangeMin, rangeMin))
    end

    local compBytes, wfn, rfn, scale, invScale, delta =
        Quantize.setup("Lync.vec2", rangeMin, rangeMax, precision)
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

local function quantizeVec3(
    _self,
    rangeMin: number,
    rangeMax: number,
    precision: number
): Types.InternalCodec<Vector3>
    if rangeMax - rangeMin == 0 then
        return Base.constant(Vector3.new(rangeMin, rangeMin, rangeMin))
    end

    local compBytes, wfn, rfn, scale, invScale, delta =
        Quantize.setup("Lync.vec3", rangeMin, rangeMax, precision)
    local totalSize = compBytes * 3
    local off2 = compBytes * 2

    return Base.define(totalSize, function(b: buffer, off: number, value: Vector3): ()
        wfn(b, off, round(clamp(value.X - rangeMin, 0, delta) * scale))
        wfn(b, off + compBytes, round(clamp(value.Y - rangeMin, 0, delta) * scale))
        wfn(b, off + off2, round(clamp(value.Z - rangeMin, 0, delta) * scale))
    end, function(b: buffer, off: number): Vector3
        return Vector3.new(
            rfn(b, off) * invScale + rangeMin,
            rfn(b, off + compBytes) * invScale + rangeMin,
            rfn(b, off + off2) * invScale + rangeMin
        )
    end, { _typeCheck = "Vector3", _min = rangeMin, _max = rangeMax })
end

-- Public -----------------------------------------------------------------

local VectorCodec = {}

VectorCodec.vec2 = table.freeze(setmetatable({
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
}, table.freeze({ __call = quantizeVec2 })))

VectorCodec.vec3 = table.freeze(setmetatable({
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
}, table.freeze({ __call = quantizeVec3 })))

return table.freeze(VectorCodec)
