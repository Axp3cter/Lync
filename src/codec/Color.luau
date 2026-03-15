--!strict
--!native
-- Color.luau — Color3 codec packed as 3 bytes (0-255 per channel, clamped).

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local round = math.round
local clamp = math.clamp

-- Public -----------------------------------------------------------------

local Color = {}

Color.color3 = table.freeze({
    _size = 3,
    write = function(ch: ChannelState, value: Color3): ()
        Channel.alloc(ch, 3)
        local b, c = ch.buff, ch.cursor
        buffer.writeu8(b, c,     round(clamp(value.R, 0, 1) * 255))
        buffer.writeu8(b, c + 1, round(clamp(value.G, 0, 1) * 255))
        buffer.writeu8(b, c + 2, round(clamp(value.B, 0, 1) * 255))
        ch.cursor = c + 3
    end,
    read = function(src: buffer, pos: number, _refs: { Instance }?): (Color3, number)
        return Color3.fromRGB(
            buffer.readu8(src, pos),
            buffer.readu8(src, pos + 1),
            buffer.readu8(src, pos + 2)
        ), 3
    end,
})

return table.freeze(Color)
