--!strict
--!native
-- CFrame.luau — Axis-angle CFrame codec. Correct reconstruction, no gimbal lock.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local EPSILON = 1e-6

-- Public -----------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = table.freeze ({
    write = function (ch: ChannelState, value: CFrame): ()
        local position = value.Position
        local axis, angle = value:ToAxisAngle ()
        local scaledAxis = axis * angle

        Channel.alloc (ch, 24)
        local b, c = ch.buff, ch.cursor
        buffer.writef32 (b, c, position.X)
        buffer.writef32 (b, c + 4, position.Y)
        buffer.writef32 (b, c + 8, position.Z)
        buffer.writef32 (b, c + 12, scaledAxis.X)
        buffer.writef32 (b, c + 16, scaledAxis.Y)
        buffer.writef32 (b, c + 20, scaledAxis.Z)
        ch.cursor = c + 24
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        local px = buffer.readf32 (src, pos)
        local py = buffer.readf32 (src, pos + 4)
        local pz = buffer.readf32 (src, pos + 8)

        local rotation = Vector3.new (
            buffer.readf32 (src, pos + 12),
            buffer.readf32 (src, pos + 16),
            buffer.readf32 (src, pos + 20)
        )

        local angle = rotation.Magnitude
        local origin = CFrame.new (px, py, pz)

        return if angle < EPSILON
            then origin
            else origin * CFrame.fromAxisAngle (rotation * (1 / angle), angle),
            24
    end,
})

return table.freeze (CFrameCodec)
