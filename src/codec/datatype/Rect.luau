--!strict
--!native
-- Rect codec. 16 bytes: 4x f32.

local Base = require(script.Parent.Parent.Base)

return table.freeze({
    rect = Base.define(16, function(b: buffer, o: number, v: Rect): ()
        buffer.writef32(b, o, v.Min.X)
        buffer.writef32(b, o + 4, v.Min.Y)
        buffer.writef32(b, o + 8, v.Max.X)
        buffer.writef32(b, o + 12, v.Max.Y)
    end, function(b: buffer, o: number): Rect
        return Rect.new(
            buffer.readf32(b, o),
            buffer.readf32(b, o + 4),
            buffer.readf32(b, o + 8),
            buffer.readf32(b, o + 12)
        )
    end),
})
