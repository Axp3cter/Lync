--!strict
--!optimize 2
-- Rect codec. 16 bytes: 4x f32.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local RectCodec = {}

RectCodec.rect = Base.define(16,
    function(b: buffer, off: number, value: Rect): ()
        buffer.writef32(b, off, value.Min.X)
        buffer.writef32(b, off + 4, value.Min.Y)
        buffer.writef32(b, off + 8, value.Max.X)
        buffer.writef32(b, off + 12, value.Max.Y)
    end,
    function(b: buffer, off: number): Rect
        return Rect.new(
            buffer.readf32(b, off),
            buffer.readf32(b, off + 4),
            buffer.readf32(b, off + 8),
            buffer.readf32(b, off + 12)
        )
    end,
    { _typeCheck = "Rect" }
)

return table.freeze(RectCodec)
