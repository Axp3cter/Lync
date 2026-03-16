--!strict
--!native
-- Axis-angle CFrame codec. Zero axis at identity for clean deltas.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

-- f32 machine epsilon ≈ 1.19e-7. Use 2× to absorb f32 round-trip noise.
local EPSILON = 2.4e-7

local sqrt = math.sqrt

-- Private ----------------------------------------------------------------

local function writeCFrame (b: buffer, c: number, value: CFrame): ()
    local position = value.Position
    local axis, angle = value:ToAxisAngle ()

    buffer.writef32 (b, c, position.X)
    buffer.writef32 (b, c + 4, position.Y)
    buffer.writef32 (b, c + 8, position.Z)

    if angle < EPSILON then
        buffer.writef32 (b, c + 12, 0)
        buffer.writef32 (b, c + 16, 0)
        buffer.writef32 (b, c + 20, 0)
    else
        buffer.writef32 (b, c + 12, axis.X * angle)
        buffer.writef32 (b, c + 16, axis.Y * angle)
        buffer.writef32 (b, c + 20, axis.Z * angle)
    end
end

local function readCFrame (b: buffer, pos: number): CFrame
    local px = buffer.readf32 (b, pos)
    local py = buffer.readf32 (b, pos + 4)
    local pz = buffer.readf32 (b, pos + 8)
    local rx = buffer.readf32 (b, pos + 12)
    local ry = buffer.readf32 (b, pos + 16)
    local rz = buffer.readf32 (b, pos + 20)

    local angle = sqrt (rx * rx + ry * ry + rz * rz)
    local origin = CFrame.new (px, py, pz)

    if angle < EPSILON then
        return origin
    end

    local inv = 1 / angle
    return origin * CFrame.fromAxisAngle (Vector3.new (rx * inv, ry * inv, rz * inv), angle)
end

-- Public -----------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = table.freeze ({
    _size = 24,
    _directWrite = writeCFrame,
    _directRead = readCFrame,
    write = function (ch: ChannelState, value: CFrame): ()
        local c = ch.cursor
        if c + 24 > ch.size then
            alloc (ch, 24)
        end
        writeCFrame (ch.buff, c, value)
        ch.cursor = c + 24
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        return readCFrame (src, pos), 24
    end,
})

return table.freeze (CFrameCodec)
