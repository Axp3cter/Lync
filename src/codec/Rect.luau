--!strict
--!native
-- Rect codec packed as 4x f32 (Min.X, Min.Y, Max.X, Max.Y).

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local RectCodec = {}

RectCodec.rect = table.freeze ({
    _size = 16,
    _directWrite = function (b: buffer, offset: number, value: Rect): ()
        buffer.writef32 (b, offset, value.Min.X)
        buffer.writef32 (b, offset + 4, value.Min.Y)
        buffer.writef32 (b, offset + 8, value.Max.X)
        buffer.writef32 (b, offset + 12, value.Max.Y)
    end,
    _directRead = function (b: buffer, offset: number): Rect
        return Rect.new (
            buffer.readf32 (b, offset),
            buffer.readf32 (b, offset + 4),
            buffer.readf32 (b, offset + 8),
            buffer.readf32 (b, offset + 12)
        )
    end,
    write = function (ch: ChannelState, value: Rect): ()
        local c = ch.cursor
        if c + 16 > ch.size then
            alloc (ch, 16)
        end
        local b = ch.buff
        buffer.writef32 (b, c, value.Min.X)
        buffer.writef32 (b, c + 4, value.Min.Y)
        buffer.writef32 (b, c + 8, value.Max.X)
        buffer.writef32 (b, c + 12, value.Max.Y)
        ch.cursor = c + 16
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Rect, number)
        return Rect.new (
            buffer.readf32 (src, pos),
            buffer.readf32 (src, pos + 4),
            buffer.readf32 (src, pos + 8),
            buffer.readf32 (src, pos + 12)
        ),
            16
    end,
})

return table.freeze (RectCodec)
