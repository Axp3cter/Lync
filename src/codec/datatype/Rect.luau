--!strict
--!native
-- Rect codec. 16B: 4x f32 (Min.X, Min.Y, Max.X, Max.Y).

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local writef32 = buffer.writef32
local readf32 = buffer.readf32

local function writeRect(b: buffer, off: number, value: Rect): ()
    local minV = value.Min
    local maxV = value.Max
    writef32(b, off, minV.X)
    writef32(b, off + 4, minV.Y)
    writef32(b, off + 8, maxV.X)
    writef32(b, off + 12, maxV.Y)
end

local function readRect(b: buffer, off: number): Rect
    return Rect.new(readf32(b, off), readf32(b, off + 4), readf32(b, off + 8), readf32(b, off + 12))
end

-- Public -----------------------------------------------------------------

local RectCodec = {}

RectCodec.rect = Base.define(16, writeRect, readRect, { _typeCheck = "Rect" })

return table.freeze(RectCodec)
