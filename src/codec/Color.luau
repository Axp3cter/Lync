--!strict
--!native
-- Color3 codec packed as 3 bytes (0-255 per channel, clamped).

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local round = math.round
local clamp = math.clamp

-- Public -----------------------------------------------------------------

local Color = {}

Color.color3 = table.freeze ({
    _size = 3,
    _directWrite = function (b: buffer, offset: number, value: Color3): ()
        buffer.writeu8 (b, offset, round (clamp (value.R, 0, 1) * 255))
        buffer.writeu8 (b, offset + 1, round (clamp (value.G, 0, 1) * 255))
        buffer.writeu8 (b, offset + 2, round (clamp (value.B, 0, 1) * 255))
    end,
    _directRead = function (b: buffer, offset: number): Color3
        return Color3.fromRGB (
            buffer.readu8 (b, offset),
            buffer.readu8 (b, offset + 1),
            buffer.readu8 (b, offset + 2)
        )
    end,
    write = function (ch: ChannelState, value: Color3): ()
        local c = ch.cursor
        if c + 3 > ch.size then
            alloc (ch, 3)
        end
        local b = ch.buff
        buffer.writeu8 (b, c, round (clamp (value.R, 0, 1) * 255))
        buffer.writeu8 (b, c + 1, round (clamp (value.G, 0, 1) * 255))
        buffer.writeu8 (b, c + 2, round (clamp (value.B, 0, 1) * 255))
        ch.cursor = c + 3
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Color3, number)
        return Color3.fromRGB (
            buffer.readu8 (src, pos),
            buffer.readu8 (src, pos + 1),
            buffer.readu8 (src, pos + 2)
        ),
            3
    end,
})

return table.freeze (Color)
