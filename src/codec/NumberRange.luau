--!strict
--!native
-- NumberRange codec packed as 2x f32 (min, max).

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local NumberRangeCodec = {}

NumberRangeCodec.numberRange = table.freeze ({
    _size = 8,
    _directWrite = function (b: buffer, offset: number, value: NumberRange): ()
        buffer.writef32 (b, offset, value.Min)
        buffer.writef32 (b, offset + 4, value.Max)
    end,
    _directRead = function (b: buffer, offset: number): NumberRange
        return NumberRange.new (buffer.readf32 (b, offset), buffer.readf32 (b, offset + 4))
    end,
    write = function (ch: ChannelState, value: NumberRange): ()
        local c = ch.cursor
        if c + 8 > ch.size then
            alloc (ch, 8)
        end
        local b = ch.buff
        buffer.writef32 (b, c, value.Min)
        buffer.writef32 (b, c + 4, value.Max)
        ch.cursor = c + 8
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (NumberRange, number)
        return NumberRange.new (buffer.readf32 (src, pos), buffer.readf32 (src, pos + 4)), 8
    end,
})

return table.freeze (NumberRangeCodec)
