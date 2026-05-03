--!strict
--!native
-- CFrame codec. Default lossless (24B); __call yields smallest-three quat (16B).

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local EPSILON = 2.4e-7
local EPSILON_SQ = EPSILON * EPSILON

local INV_SQRT2 = 1 / math.sqrt(2)
local Q_SCALE = 1023 / (2 * INV_SQRT2)
local Q_INV = (2 * INV_SQRT2) / 1023

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeu32 = buffer.writeu32
local readu32 = buffer.readu32

local sqrt = math.sqrt
local cos = math.cos
local sin = math.sin
local abs = math.abs
local round = math.round
local acos = math.acos
local clamp = math.clamp

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

local function writeLossless(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    writef32(b, off, pos.X)
    writef32(b, off + 4, pos.Y)
    writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    if angle < EPSILON then
        writef32(b, off + 12, 0)
        writef32(b, off + 16, 0)
        writef32(b, off + 20, 0)
        return
    end
    writef32(b, off + 12, axis.X * angle)
    writef32(b, off + 16, axis.Y * angle)
    writef32(b, off + 20, axis.Z * angle)
end

local function readLossless(b: buffer, off: number): CFrame
    local px = readf32(b, off)
    local py = readf32(b, off + 4)
    local pz = readf32(b, off + 8)
    local rx = readf32(b, off + 12)
    local ry = readf32(b, off + 16)
    local rz = readf32(b, off + 20)

    local sqLen = rx * rx + ry * ry + rz * rz
    if sqLen < EPSILON_SQ then
        return CFrame.new(px, py, pz)
    end

    local angle = sqrt(sqLen)
    local inv = 1 / angle
    return CFrame.new(px, py, pz)
        * CFrame.fromAxisAngle(Vector3.new(rx * inv, ry * inv, rz * inv), angle)
end

--[[
    Compressed wire (16B):
      [0..11]  position 3x f32
      [12..15] packed [largest:2][a:10][b:10][c:10] (smallest-three quat)
]]
local function writeCompressed(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    writef32(b, off, pos.X)
    writef32(b, off + 4, pos.Y)
    writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    local h = angle * 0.5
    local s = sin(h)
    local qx = axis.X * s
    local qy = axis.Y * s
    local qz = axis.Z * s
    local qw = cos(h)

    -- Smallest-three: drop the largest |component|; track index alongside maxVal.
    local ax, ay, az, aw = abs(qx), abs(qy), abs(qz), abs(qw)
    local largest, maxVal = 3, aw
    if ax > maxVal then
        largest, maxVal = 0, ax
    end
    if ay > maxVal then
        largest, maxVal = 1, ay
    end
    if az > maxVal then
        largest, maxVal = 2, az
    end

    --[[
        Force the dropped component non-negative so the decoder's
        +sqrt(1 - a^2 - b^2 - c^2) reconstructs the right sign. Dispatch on
        `largest` instead of building a 4-element table per call.
    ]]
    local a: number, bComp: number, c: number
    if largest == 0 then
        if qx < 0 then
            qy, qz, qw = -qy, -qz, -qw
        end
        a, bComp, c = qy, qz, qw
    elseif largest == 1 then
        if qy < 0 then
            qx, qz, qw = -qx, -qz, -qw
        end
        a, bComp, c = qx, qz, qw
    elseif largest == 2 then
        if qz < 0 then
            qx, qy, qw = -qx, -qy, -qw
        end
        a, bComp, c = qx, qy, qw
    else
        if qw < 0 then
            qx, qy, qz = -qx, -qy, -qz
        end
        a, bComp, c = qx, qy, qz
    end

    local qa = clamp(round((a + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qb = clamp(round((bComp + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qc = clamp(round((c + INV_SQRT2) * Q_SCALE), 0, 1023)

    writeu32(b, off + 12, bor(lshift(largest, 30), lshift(qa, 20), lshift(qb, 10), qc))
end

local function readCompressed(b: buffer, off: number): CFrame
    local px = readf32(b, off)
    local py = readf32(b, off + 4)
    local pz = readf32(b, off + 8)

    local packed = readu32(b, off + 12)
    local largest = rshift(packed, 30)
    local qa = band(rshift(packed, 20), 0x3FF)
    local qb = band(rshift(packed, 10), 0x3FF)
    local qc = band(packed, 0x3FF)

    local a = qa * Q_INV - INV_SQRT2
    local bComp = qb * Q_INV - INV_SQRT2
    local c = qc * Q_INV - INV_SQRT2

    local sqSum = a * a + bComp * bComp + c * c
    local d = sqrt(if sqSum < 1 then 1 - sqSum else 0)

    -- Mirror encoder: dropped index gets `d`, others receive (a, bComp, c).
    local qx: number, qy: number, qz: number, qw: number
    if largest == 0 then
        qx, qy, qz, qw = d, a, bComp, c
    elseif largest == 1 then
        qx, qy, qz, qw = a, d, bComp, c
    elseif largest == 2 then
        qx, qy, qz, qw = a, bComp, d, c
    else
        qx, qy, qz, qw = a, bComp, c, d
    end

    local origin = CFrame.new(px, py, pz)
    local sqLen = qx * qx + qy * qy + qz * qz
    if sqLen < EPSILON_SQ then
        return origin
    end

    local angle = 2 * acos(clamp(qw, -1, 1))
    local inv = 1 / sqrt(sqLen)
    return origin * CFrame.fromAxisAngle(Vector3.new(qx * inv, qy * inv, qz * inv), angle)
end

local function compressedFactory(_self): Types.InternalCodec<CFrame>
    return Base.define(16, writeCompressed, readCompressed, { _typeCheck = "CFrame" })
end

-- Public -----------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = table.freeze(setmetatable({
    _size = 24,
    _directWrite = writeLossless,
    _directRead = readLossless,
    _typeCheck = "CFrame",
    write = function(ch: Types.ChannelState, value: CFrame): ()
        local cursor = ch.cursor
        if cursor + 24 > ch.size then
            alloc(ch, 24)
        end
        writeLossless(ch.buff, cursor, value)
        ch.cursor = cursor + 24
    end,
    read = function(src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        return readLossless(src, pos), 24
    end,
}, table.freeze({ __call = compressedFactory })))

return table.freeze(CFrameCodec)
