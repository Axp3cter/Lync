--!strict
--!native
-- Ray codec packed as Origin Vec3 + Direction Vec3 (24 bytes).

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local RayCodec = {}

RayCodec.ray = table.freeze ({
    _size = 24,
    _directWrite = function (b: buffer, offset: number, value: Ray): ()
        local origin = value.Origin
        local direction = value.Direction
        buffer.writef32 (b, offset, origin.X)
        buffer.writef32 (b, offset + 4, origin.Y)
        buffer.writef32 (b, offset + 8, origin.Z)
        buffer.writef32 (b, offset + 12, direction.X)
        buffer.writef32 (b, offset + 16, direction.Y)
        buffer.writef32 (b, offset + 20, direction.Z)
    end,
    _directRead = function (b: buffer, offset: number): Ray
        return Ray.new (
            Vector3.new (
                buffer.readf32 (b, offset),
                buffer.readf32 (b, offset + 4),
                buffer.readf32 (b, offset + 8)
            ),
            Vector3.new (
                buffer.readf32 (b, offset + 12),
                buffer.readf32 (b, offset + 16),
                buffer.readf32 (b, offset + 20)
            )
        )
    end,
    write = function (ch: ChannelState, value: Ray): ()
        local c = ch.cursor
        if c + 24 > ch.size then
            alloc (ch, 24)
        end
        local b = ch.buff
        local origin = value.Origin
        local direction = value.Direction
        buffer.writef32 (b, c, origin.X)
        buffer.writef32 (b, c + 4, origin.Y)
        buffer.writef32 (b, c + 8, origin.Z)
        buffer.writef32 (b, c + 12, direction.X)
        buffer.writef32 (b, c + 16, direction.Y)
        buffer.writef32 (b, c + 20, direction.Z)
        ch.cursor = c + 24
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Ray, number)
        return Ray.new (
            Vector3.new (
                buffer.readf32 (src, pos),
                buffer.readf32 (src, pos + 4),
                buffer.readf32 (src, pos + 8)
            ),
            Vector3.new (
                buffer.readf32 (src, pos + 12),
                buffer.readf32 (src, pos + 16),
                buffer.readf32 (src, pos + 20)
            )
        ),
            24
    end,
})

return table.freeze (RayCodec)
