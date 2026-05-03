--!strict
--!native
-- Vector2int16 (4B) and Vector3int16 (6B) codecs.

local Base = require(script.Parent.Parent.Base)
local Signed = require(script.Parent.Parent.primitive.Signed)

-- Private ----------------------------------------------------------------

local writeI16 = Signed.writeI16
local readi16 = buffer.readi16

local function writeVec2I16(b: buffer, off: number, value: Vector2int16): ()
    writeI16(b, off, value.X)
    writeI16(b, off + 2, value.Y)
end

local function readVec2I16(b: buffer, off: number): Vector2int16
    return Vector2int16.new(readi16(b, off), readi16(b, off + 2))
end

local function writeVec3I16(b: buffer, off: number, value: Vector3int16): ()
    writeI16(b, off, value.X)
    writeI16(b, off + 2, value.Y)
    writeI16(b, off + 4, value.Z)
end

local function readVec3I16(b: buffer, off: number): Vector3int16
    return Vector3int16.new(readi16(b, off), readi16(b, off + 2), readi16(b, off + 4))
end

-- Public -----------------------------------------------------------------

local IntVector = {}

IntVector.vec2int16 = Base.define(4, writeVec2I16, readVec2I16, { _typeCheck = "Vector2int16" })
IntVector.vec3int16 = Base.define(6, writeVec3I16, readVec3I16, { _typeCheck = "Vector3int16" })

return table.freeze(IntVector)
