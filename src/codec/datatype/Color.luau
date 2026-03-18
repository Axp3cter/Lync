--!strict
--!native
-- Color3 codec. 3 bytes, 0-255 per channel, clamped.

local Base = require(script.Parent.Parent.Base)

local round = math.round
local clamp = math.clamp

return table.freeze({
    color3 = Base.define(3, function(b: buffer, o: number, v: Color3): ()
        buffer.writeu8(b, o, round(clamp(v.R, 0, 1) * 255))
        buffer.writeu8(b, o + 1, round(clamp(v.G, 0, 1) * 255))
        buffer.writeu8(b, o + 2, round(clamp(v.B, 0, 1) * 255))
    end, function(b: buffer, o: number): Color3
        return Color3.fromRGB(buffer.readu8(b, o), buffer.readu8(b, o + 1), buffer.readu8(b, o + 2))
    end),
})
