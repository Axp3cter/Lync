--!strict
--!optimize 2
-- Rect codec. 16 bytes: 4x f32 (Min.X, Min.Y, Max.X, Max.Y).

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local function writeRect(b: buffer, off: number, value: Rect): ()
    buffer.writef32(b, off, value.Min.X)
    buffer.writef32(b, off + 4, value.Min.Y)
    buffer.writef32(b, off + 8, value.Max.X)
    buffer.writef32(b, off + 12, value.Max.Y)
end

local function readRect(b: buffer, off: number): Rect
    return Rect.new(
        buffer.readf32(b, off),
        buffer.readf32(b, off + 4),
        buffer.readf32(b, off + 8),
        buffer.readf32(b, off + 12)
    )
end

-- Public -----------------------------------------------------------------

local RectCodec = {}

RectCodec.rect = Base.define(16, writeRect, readRect, { _typeCheck = "Rect" })

return table.freeze(RectCodec)
