--!strict
--!native
-- CFrame codec with __call for smallest-three compressed variant.

local Base = require(script.Parent.Parent.Base)

-- Constants -----------------------------------------------------------

local EPSILON    = 2.4e-7
local EPSILON_SQ = EPSILON * EPSILON
local SQRT       = math.sqrt
local COS        = math.cos
local SIN        = math.sin
local ABS        = math.abs
local ROUND      = math.round
local ACOS       = math.acos

-- Smallest-three quantization constants
local INV_SQRT2  = 1 / SQRT(2)
local Q_SCALE    = 1023 / (2 * INV_SQRT2)
local Q_INV      = (2 * INV_SQRT2) / 1023

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Private: Lossless axis-angle (24 bytes) -----------------------------

local function writeLossless(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    buffer.writef32(b, off, pos.X)
    buffer.writef32(b, off + 4, pos.Y)
    buffer.writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    if angle < EPSILON then
        buffer.writef32(b, off + 12, 0)
        buffer.writef32(b, off + 16, 0)
        buffer.writef32(b, off + 20, 0)
    else
        buffer.writef32(b, off + 12, axis.X * angle)
        buffer.writef32(b, off + 16, axis.Y * angle)
        buffer.writef32(b, off + 20, axis.Z * angle)
    end
end

local function readLossless(b: buffer, off: number): CFrame
    local px = buffer.readf32(b, off)
    local py = buffer.readf32(b, off + 4)
    local pz = buffer.readf32(b, off + 8)
    local rx = buffer.readf32(b, off + 12)
    local ry = buffer.readf32(b, off + 16)
    local rz = buffer.readf32(b, off + 20)

    local sqLen = rx * rx + ry * ry + rz * rz
    if sqLen < EPSILON_SQ then
        return CFrame.new(px, py, pz)
    end

    local angle = SQRT(sqLen)
    local inv = 1 / angle
    return CFrame.new(px, py, pz)
        * CFrame.fromAxisAngle(Vector3.new(rx * inv, ry * inv, rz * inv), angle)
end

-- Private: Smallest-three compressed (16 bytes) -----------------------

local function writeCompressed(b: buffer, off: number, value: CFrame): ()
    -- Position: 3x f32
    local pos = value.Position
    buffer.writef32(b, off, pos.X)
    buffer.writef32(b, off + 4, pos.Y)
    buffer.writef32(b, off + 8, pos.Z)

    --[[
        Convert CFrame rotation to quaternion via axis-angle.
        Then apply smallest-three: drop the largest component,
        quantize the other three into 10 bits each, pack into u32.
    ]]
    local axis, angle = value:ToAxisAngle()
    local halfAngle = angle * 0.5
    local s = SIN(halfAngle)
    local qx = axis.X * s
    local qy = axis.Y * s
    local qz = axis.Z * s
    local qw = COS(halfAngle)

    -- Find largest component
    local ax, ay, az, aw = ABS(qx), ABS(qy), ABS(qz), ABS(qw)
    local largest = 3
    local maxVal = aw

    if ax > maxVal then largest = 0; maxVal = ax end
    if ay > maxVal then largest = 1; maxVal = ay end
    if az > maxVal then largest = 2; maxVal = az end

    -- Negate quaternion if largest component is negative
    local sign: number
    if largest == 0 then
        sign = if qx < 0 then -1 else 1
    elseif largest == 1 then
        sign = if qy < 0 then -1 else 1
    elseif largest == 2 then
        sign = if qz < 0 then -1 else 1
    else
        sign = if qw < 0 then -1 else 1
    end
    qx *= sign
    qy *= sign
    qz *= sign
    qw *= sign

    -- Select the three smallest components
    local a, b2, c: number
    if largest == 0 then
        a, b2, c = qy, qz, qw
    elseif largest == 1 then
        a, b2, c = qx, qz, qw
    elseif largest == 2 then
        a, b2, c = qx, qy, qw
    else
        a, b2, c = qx, qy, qz
    end

    -- Quantize from [-1/sqrt(2), 1/sqrt(2)] to [0, 1023]
    local qa = ROUND((a + INV_SQRT2) * Q_SCALE)
    local qb = ROUND((b2 + INV_SQRT2) * Q_SCALE)
    local qc = ROUND((c + INV_SQRT2) * Q_SCALE)

    -- Clamp to [0, 1023]
    qa = if qa < 0 then 0 elseif qa > 1023 then 1023 else qa
    qb = if qb < 0 then 0 elseif qb > 1023 then 1023 else qb
    qc = if qc < 0 then 0 elseif qc > 1023 then 1023 else qc

    -- Pack: [index:2][a:10][b:10][c:10] = 32 bits
    local packed = bor(lshift(largest, 30), lshift(qa, 20), lshift(qb, 10), qc)
    buffer.writeu32(b, off + 12, packed)
end

local function readCompressed(b: buffer, off: number): CFrame
    local px = buffer.readf32(b, off)
    local py = buffer.readf32(b, off + 4)
    local pz = buffer.readf32(b, off + 8)

    local packed = buffer.readu32(b, off + 12)
    local largest = rshift(packed, 30)
    local qa = band(rshift(packed, 20), 0x3FF)
    local qb = band(rshift(packed, 10), 0x3FF)
    local qc = band(packed, 0x3FF)

    -- Dequantize from [0, 1023] to [-1/sqrt(2), 1/sqrt(2)]
    local a = qa * Q_INV - INV_SQRT2
    local b2 = qb * Q_INV - INV_SQRT2
    local c = qc * Q_INV - INV_SQRT2

    -- Reconstruct largest component
    local sqSum = a * a + b2 * b2 + c * c
    local d = SQRT(if sqSum < 1 then 1 - sqSum else 0)

    -- Place components
    local qx, qy, qz, qw: number
    if largest == 0 then
        qx, qy, qz, qw = d, a, b2, c
    elseif largest == 1 then
        qx, qy, qz, qw = a, d, b2, c
    elseif largest == 2 then
        qx, qy, qz, qw = a, b2, d, c
    else
        qx, qy, qz, qw = a, b2, c, d
    end

    -- Build CFrame from position + quaternion
    local origin = CFrame.new(px, py, pz)
    if qx * qx + qy * qy + qz * qz < EPSILON_SQ then
        return origin
    end

    -- Convert quaternion to axis-angle for CFrame construction
    local len = SQRT(qx * qx + qy * qy + qz * qz)
    local angle = 2 * ACOS(if qw > 1 then 1 elseif qw < -1 then -1 else qw)
    local inv = 1 / len
    return origin * CFrame.fromAxisAngle(
        Vector3.new(qx * inv, qy * inv, qz * inv),
        angle
    )
end

-- __call factory for compressed variant
local function compressedFactory(_self: any): any
    return Base.define(16, writeCompressed, readCompressed, {
        _typeCheck = "CFrame",
    })
end

-- Public --------------------------------------------------------------

local CFrameCodec = {}

CFrameCodec.cframe = setmetatable({
    _size = 24,
    _directWrite = writeLossless,
    _directRead = readLossless,
    _typeCheck = "CFrame",

    write = function(ch: Types.ChannelState, value: CFrame): ()
        local cursor = ch.cursor
        if cursor + 24 > ch.size then alloc(ch, 24) end
        writeLossless(ch.buff, cursor, value)
        ch.cursor = cursor + 24
    end,

    read = function(src: buffer, pos: number, _refs: { Instance }?): (CFrame, number)
        return readLossless(src, pos), 24
    end,
} :: any, { __call = compressedFactory })

return table.freeze(CFrameCodec)
