--!strict
--!optimize 2
-- Color3 codec. 3 bytes, RGB u8 per channel, clamped.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local round = math.round
local clamp = math.clamp

-- Public --------------------------------------------------------------

local ColorCodec = {}

ColorCodec.color3 = Base.define(3,
    function(b: buffer, off: number, value: Color3): ()
        buffer.writeu8(b, off, round(clamp(value.R, 0, 1) * 255))
        buffer.writeu8(b, off + 1, round(clamp(value.G, 0, 1) * 255))
        buffer.writeu8(b, off + 2, round(clamp(value.B, 0, 1) * 255))
    end,
    function(b: buffer, off: number): Color3
        return Color3.fromRGB(
            buffer.readu8(b, off),
            buffer.readu8(b, off + 1),
            buffer.readu8(b, off + 2)
        )
    end,
    { _typeCheck = "Color3" }
)

return table.freeze(ColorCodec)
