--!strict
--!optimize 2
-- Vector2int16 (4 bytes) and Vector3int16 (6 bytes) codecs.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local function writeI16(b: buffer, off: number, v: number): ()
    buffer.writeu16(b, off, if v < 0 then v + 0x10000 else v)
end

local function readI16(b: buffer, off: number): number
    local raw = buffer.readu16(b, off)
    return if raw >= 0x8000 then raw - 0x10000 else raw
end

-- Public --------------------------------------------------------------

local IntVectorCodec = {}

IntVectorCodec.vec2int16 = Base.define(4, function(b: buffer, off: number, value: Vector2int16): ()
    writeI16(b, off, value.X)
    writeI16(b, off + 2, value.Y)
end, function(b: buffer, off: number): Vector2int16
    return Vector2int16.new(readI16(b, off), readI16(b, off + 2))
end, { _typeCheck = "Vector2int16" })

IntVectorCodec.vec3int16 = Base.define(6, function(b: buffer, off: number, value: Vector3int16): ()
    writeI16(b, off, value.X)
    writeI16(b, off + 2, value.Y)
    writeI16(b, off + 4, value.Z)
end, function(b: buffer, off: number): Vector3int16
    return Vector3int16.new(readI16(b, off), readI16(b, off + 2), readI16(b, off + 4))
end, { _typeCheck = "Vector3int16" })

return table.freeze(IntVectorCodec)
