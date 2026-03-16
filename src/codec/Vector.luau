--!strict
--!native
-- Vector2 and Vector3 codecs.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local Vector = {}

Vector.vec2 = table.freeze ({
    _size = 8,
    _directWrite = function (b: buffer, offset: number, value: Vector2): ()
        buffer.writef32 (b, offset, value.X)
        buffer.writef32 (b, offset + 4, value.Y)
    end,
    _directRead = function (b: buffer, offset: number): Vector2
        return Vector2.new (buffer.readf32 (b, offset), buffer.readf32 (b, offset + 4))
    end,
    write = function (ch: ChannelState, value: Vector2): ()
        local c = ch.cursor
        if c + 8 > ch.size then
            alloc (ch, 8)
        end
        local b = ch.buff
        buffer.writef32 (b, c, value.X)
        buffer.writef32 (b, c + 4, value.Y)
        ch.cursor = c + 8
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector2, number)
        return Vector2.new (buffer.readf32 (src, pos), buffer.readf32 (src, pos + 4)), 8
    end,
})

Vector.vec3 = table.freeze ({
    _size = 12,
    _directWrite = function (b: buffer, offset: number, value: Vector3): ()
        buffer.writef32 (b, offset, value.X)
        buffer.writef32 (b, offset + 4, value.Y)
        buffer.writef32 (b, offset + 8, value.Z)
    end,
    _directRead = function (b: buffer, offset: number): Vector3
        return Vector3.new (
            buffer.readf32 (b, offset),
            buffer.readf32 (b, offset + 4),
            buffer.readf32 (b, offset + 8)
        )
    end,
    write = function (ch: ChannelState, value: Vector3): ()
        local c = ch.cursor
        if c + 12 > ch.size then
            alloc (ch, 12)
        end
        local b = ch.buff
        buffer.writef32 (b, c, value.X)
        buffer.writef32 (b, c + 4, value.Y)
        buffer.writef32 (b, c + 8, value.Z)
        ch.cursor = c + 12
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector3, number)
        return Vector3.new (
            buffer.readf32 (src, pos),
            buffer.readf32 (src, pos + 4),
            buffer.readf32 (src, pos + 8)
        ),
            12
    end,
})

return table.freeze (Vector)
