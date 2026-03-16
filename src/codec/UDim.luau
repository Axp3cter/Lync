--!strict
--!native
-- UDim (8B) and UDim2 (16B) codecs.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local UDimCodec = {}

UDimCodec.udim = table.freeze ({
    _size = 8,
    _directWrite = function (b: buffer, offset: number, value: UDim): ()
        buffer.writef32 (b, offset, value.Scale)
        buffer.writei32 (b, offset + 4, value.Offset)
    end,
    _directRead = function (b: buffer, offset: number): UDim
        return UDim.new (buffer.readf32 (b, offset), buffer.readi32 (b, offset + 4))
    end,
    write = function (ch: ChannelState, value: UDim): ()
        local c = ch.cursor
        if c + 8 > ch.size then
            alloc (ch, 8)
        end
        local b = ch.buff
        buffer.writef32 (b, c, value.Scale)
        buffer.writei32 (b, c + 4, value.Offset)
        ch.cursor = c + 8
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (UDim, number)
        return UDim.new (buffer.readf32 (src, pos), buffer.readi32 (src, pos + 4)), 8
    end,
})

UDimCodec.udim2 = table.freeze ({
    _size = 16,
    _directWrite = function (b: buffer, offset: number, value: UDim2): ()
        local x = value.X
        local y = value.Y
        buffer.writef32 (b, offset, x.Scale)
        buffer.writei32 (b, offset + 4, x.Offset)
        buffer.writef32 (b, offset + 8, y.Scale)
        buffer.writei32 (b, offset + 12, y.Offset)
    end,
    _directRead = function (b: buffer, offset: number): UDim2
        return UDim2.new (
            UDim.new (buffer.readf32 (b, offset), buffer.readi32 (b, offset + 4)),
            UDim.new (buffer.readf32 (b, offset + 8), buffer.readi32 (b, offset + 12))
        )
    end,
    write = function (ch: ChannelState, value: UDim2): ()
        local c = ch.cursor
        if c + 16 > ch.size then
            alloc (ch, 16)
        end
        local b = ch.buff
        local x = value.X
        local y = value.Y
        buffer.writef32 (b, c, x.Scale)
        buffer.writei32 (b, c + 4, x.Offset)
        buffer.writef32 (b, c + 8, y.Scale)
        buffer.writei32 (b, c + 12, y.Offset)
        ch.cursor = c + 16
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (UDim2, number)
        return UDim2.new (
            UDim.new (buffer.readf32 (src, pos), buffer.readi32 (src, pos + 4)),
            UDim.new (buffer.readf32 (src, pos + 8), buffer.readi32 (src, pos + 12))
        ),
            16
    end,
})

return table.freeze (UDimCodec)
