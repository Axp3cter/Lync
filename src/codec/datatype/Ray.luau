--!strict
--!native
-- Ray codec. 24B: Origin (3x f32) + Direction (3x f32).

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local writef32 = buffer.writef32
local readf32 = buffer.readf32

local function writeRay(b: buffer, off: number, value: Ray): ()
    local o = value.Origin
    local d = value.Direction
    writef32(b, off, o.X)
    writef32(b, off + 4, o.Y)
    writef32(b, off + 8, o.Z)
    writef32(b, off + 12, d.X)
    writef32(b, off + 16, d.Y)
    writef32(b, off + 20, d.Z)
end

local function readRay(b: buffer, off: number): Ray
    return Ray.new(
        Vector3.new(readf32(b, off), readf32(b, off + 4), readf32(b, off + 8)),
        Vector3.new(readf32(b, off + 12), readf32(b, off + 16), readf32(b, off + 20))
    )
end

-- Public -----------------------------------------------------------------

local RayCodec = {}

RayCodec.ray = Base.define(24, writeRay, readRay, { _typeCheck = "Ray" })

return table.freeze(RayCodec)
