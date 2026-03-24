--!strict
--!optimize 2
-- Ray codec. 24 bytes: origin + direction as 6x f32.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local RayCodec = {}

RayCodec.ray = Base.define(24, function(b: buffer, off: number, value: Ray): ()
    local o = value.Origin
    local d = value.Direction
    buffer.writef32(b, off, o.X)
    buffer.writef32(b, off + 4, o.Y)
    buffer.writef32(b, off + 8, o.Z)
    buffer.writef32(b, off + 12, d.X)
    buffer.writef32(b, off + 16, d.Y)
    buffer.writef32(b, off + 20, d.Z)
end, function(b: buffer, off: number): Ray
    return Ray.new(
        Vector3.new(buffer.readf32(b, off), buffer.readf32(b, off + 4), buffer.readf32(b, off + 8)),
        Vector3.new(
            buffer.readf32(b, off + 12),
            buffer.readf32(b, off + 16),
            buffer.readf32(b, off + 20)
        )
    )
end, { _typeCheck = "Ray" })

return table.freeze(RayCodec)
