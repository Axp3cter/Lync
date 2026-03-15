--!strict
--!native
-- Axis-angle CFrame codec. Zero axis at identity for clean deltas.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

-- f32 machine epsilon ≈ 1.19e-7. Use 2× to absorb f32 round-trip noise.
local EPSILON = 2.4e-7

local sqrt = math.sqrt

-- Public -----------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = table.freeze ({
    _size = 24,
    write = function (ch: ChannelState, value: CFrame): ()
        local position = value.Position
        local axis, angle = value:ToAxisAngle ()

        Channel.alloc (ch, 24)
        local b = ch.buff
        local c = ch.cursor
        buffer.writef32 (b, c, position.X)
        buffer.writef32 (b, c + 4, position.Y)
        buffer.writef32 (b, c + 8, position.Z)

        -- At identity rotation, axis is undefined. Write zeros to produce
        -- deterministic bytes for XOR delta compression.
        if angle < EPSILON then
            buffer.writef32 (b, c + 12, 0)
            buffer.writef32 (b, c + 16, 0)
            buffer.writef32 (b, c + 20, 0)
        else
            buffer.writef32 (b, c + 12, axis.X * angle)
            buffer.writef32 (b, c + 16, axis.Y * angle)
            buffer.writef32 (b, c + 20, axis.Z * angle)
        end

        ch.cursor = c + 24
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        local px = buffer.readf32 (src, pos)
        local py = buffer.readf32 (src, pos + 4)
        local pz = buffer.readf32 (src, pos + 8)
        local rx = buffer.readf32 (src, pos + 12)
        local ry = buffer.readf32 (src, pos + 16)
        local rz = buffer.readf32 (src, pos + 20)

        -- Compute magnitude from raw floats — no Vector3 allocation
        local angle = sqrt (rx * rx + ry * ry + rz * rz)
        local origin = CFrame.new (px, py, pz)

        if angle < EPSILON then
            return origin, 24
        end

        local inv = 1 / angle
        return origin * CFrame.fromAxisAngle (Vector3.new (rx * inv, ry * inv, rz * inv), angle), 24
    end,
})

return table.freeze (CFrameCodec)
