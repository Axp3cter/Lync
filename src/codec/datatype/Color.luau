--!strict
--!optimize 2
-- Color3 codec. 3 bytes, R/G/B u8 per channel, clamped to [0, 1].

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local round = math.round
local clamp = math.clamp

local function writeColor3(b: buffer, off: number, value: Color3): ()
    buffer.writeu8(b, off, round(clamp(value.R, 0, 1) * 255))
    buffer.writeu8(b, off + 1, round(clamp(value.G, 0, 1) * 255))
    buffer.writeu8(b, off + 2, round(clamp(value.B, 0, 1) * 255))
end

local function readColor3(b: buffer, off: number): Color3
    return Color3.fromRGB(
        buffer.readu8(b, off),
        buffer.readu8(b, off + 1),
        buffer.readu8(b, off + 2)
    )
end

-- Public -----------------------------------------------------------------

local Color = {}

Color.color3 = Base.define(3, writeColor3, readColor3, { _typeCheck = "Color3" })

return table.freeze(Color)
