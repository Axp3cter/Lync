--!strict
--!native
-- Color3 codec. 3 bytes (R/G/B u8 per channel), clamped to [0, 1].

local Base = require(script.Parent.Parent.Base)
local Constants = require(script.Parent.Parent.Parent.util.Constants)

-- Private ----------------------------------------------------------------

local U8_MAX = Constants.U8_MAX
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local round = math.round
local clamp = math.clamp

local function writeColor3(b: buffer, off: number, value: Color3): ()
    writeu8(b, off, round(clamp(value.R, 0, 1) * U8_MAX))
    writeu8(b, off + 1, round(clamp(value.G, 0, 1) * U8_MAX))
    writeu8(b, off + 2, round(clamp(value.B, 0, 1) * U8_MAX))
end

local function readColor3(b: buffer, off: number): Color3
    return Color3.fromRGB(readu8(b, off), readu8(b, off + 1), readu8(b, off + 2))
end

-- Public -----------------------------------------------------------------

local Color = {}

Color.color3 = Base.define(3, writeColor3, readColor3, { _typeCheck = "Color3" })

return table.freeze(Color)
