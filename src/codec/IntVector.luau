--!strict
--!native
-- Vector2int16 and Vector3int16 codecs.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local IntVector = {}

IntVector.vec2int16 = table.freeze ({
    _size = 4,
    _directWrite = function (b: buffer, offset: number, value: Vector2int16): ()
        buffer.writei16 (b, offset, value.X)
        buffer.writei16 (b, offset + 2, value.Y)
    end,
    _directRead = function (b: buffer, offset: number): Vector2int16
        return Vector2int16.new (buffer.readi16 (b, offset), buffer.readi16 (b, offset + 2))
    end,
    write = function (ch: ChannelState, value: Vector2int16): ()
        local c = ch.cursor
        if c + 4 > ch.size then
            alloc (ch, 4)
        end
        local b = ch.buff
        buffer.writei16 (b, c, value.X)
        buffer.writei16 (b, c + 2, value.Y)
        ch.cursor = c + 4
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector2int16, number)
        return Vector2int16.new (buffer.readi16 (src, pos), buffer.readi16 (src, pos + 2)), 4
    end,
})

IntVector.vec3int16 = table.freeze ({
    _size = 6,
    _directWrite = function (b: buffer, offset: number, value: Vector3int16): ()
        buffer.writei16 (b, offset, value.X)
        buffer.writei16 (b, offset + 2, value.Y)
        buffer.writei16 (b, offset + 4, value.Z)
    end,
    _directRead = function (b: buffer, offset: number): Vector3int16
        return Vector3int16.new (
            buffer.readi16 (b, offset),
            buffer.readi16 (b, offset + 2),
            buffer.readi16 (b, offset + 4)
        )
    end,
    write = function (ch: ChannelState, value: Vector3int16): ()
        local c = ch.cursor
        if c + 6 > ch.size then
            alloc (ch, 6)
        end
        local b = ch.buff
        buffer.writei16 (b, c, value.X)
        buffer.writei16 (b, c + 2, value.Y)
        buffer.writei16 (b, c + 4, value.Z)
        ch.cursor = c + 6
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector3int16, number)
        return Vector3int16.new (
            buffer.readi16 (src, pos),
            buffer.readi16 (src, pos + 2),
            buffer.readi16 (src, pos + 4)
        ),
            6
    end,
})

return table.freeze (IntVector)
