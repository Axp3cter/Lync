--!strict
--!native
-- Vector2int16 (4B) and Vector3int16 (6B) codecs.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    vec2int16 = Base.define (4, function (b: buffer, o: number, v: Vector2int16): ()
        buffer.writei16 (b, o, v.X)
        buffer.writei16 (b, o + 2, v.Y)
    end, function (b: buffer, o: number): Vector2int16
        return Vector2int16.new (buffer.readi16 (b, o), buffer.readi16 (b, o + 2))
    end),
    vec3int16 = Base.define (6, function (b: buffer, o: number, v: Vector3int16): ()
        buffer.writei16 (b, o, v.X)
        buffer.writei16 (b, o + 2, v.Y)
        buffer.writei16 (b, o + 4, v.Z)
    end, function (b: buffer, o: number): Vector3int16
        return Vector3int16.new (
            buffer.readi16 (b, o),
            buffer.readi16 (b, o + 2),
            buffer.readi16 (b, o + 4)
        )
    end),
})
