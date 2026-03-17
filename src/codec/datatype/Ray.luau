--!strict
--!native
-- Ray codec. 24 bytes: origin vec3 + direction vec3.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    ray = Base.define (24, function (b: buffer, o: number, v: Ray): ()
        local origin = v.Origin
        local direction = v.Direction
        buffer.writef32 (b, o, origin.X)
        buffer.writef32 (b, o + 4, origin.Y)
        buffer.writef32 (b, o + 8, origin.Z)
        buffer.writef32 (b, o + 12, direction.X)
        buffer.writef32 (b, o + 16, direction.Y)
        buffer.writef32 (b, o + 20, direction.Z)
    end, function (b: buffer, o: number): Ray
        return Ray.new (
            Vector3.new (buffer.readf32 (b, o), buffer.readf32 (b, o + 4), buffer.readf32 (b, o + 8)),
            Vector3.new (
                buffer.readf32 (b, o + 12),
                buffer.readf32 (b, o + 16),
                buffer.readf32 (b, o + 20)
            )
        )
    end),
})
