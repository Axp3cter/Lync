--!strict
--!native
-- Vector.luau — Vector2 and Vector3 codecs.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local Vector = {}

Vector.vec2 = table.freeze ({
    write = function (ch: ChannelState, value: Vector2): ()
        Channel.alloc (ch, 8)
        local b, c = ch.buff, ch.cursor
        buffer.writef32 (b, c, value.X)
        buffer.writef32 (b, c + 4, value.Y)
        ch.cursor = c + 8
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector2, number)
        return Vector2.new (buffer.readf32 (src, pos), buffer.readf32 (src, pos + 4)), 8
    end,
})

Vector.vec3 = table.freeze ({
    write = function (ch: ChannelState, value: Vector3): ()
        Channel.alloc (ch, 12)
        local b, c = ch.buff, ch.cursor
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
