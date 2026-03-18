--!strict
--!native
-- Vector2(8B) and Vector3(12B) codecs.

local Base = require(script.Parent.Parent.Base)

return table.freeze({
    vec2 = Base.define(8, function(b: buffer, o: number, v: Vector2): ()
        buffer.writef32(b, o, v.X)
        buffer.writef32(b, o + 4, v.Y)
    end, function(b: buffer, o: number): Vector2
        return Vector2.new(buffer.readf32(b, o), buffer.readf32(b, o + 4))
    end),
    vec3 = Base.define(12, function(b: buffer, o: number, v: Vector3): ()
        buffer.writef32(b, o, v.X)
        buffer.writef32(b, o + 4, v.Y)
        buffer.writef32(b, o + 8, v.Z)
    end, function(b: buffer, o: number): Vector3
        return Vector3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8))
    end),
})
