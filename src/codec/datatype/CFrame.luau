--!strict
--!native
-- CFrame codec with __call factory for smallest-three quaternion compression.

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
    buffer.writef32(b, off, pos.X)
    buffer.writef32(b, off + 4, pos.Y)
    buffer.writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    if angle < EPSILON then
        buffer.writef32(b, off + 12, 0)
        buffer.writef32(b, off + 16, 0)
        buffer.writef32(b, off + 20, 0)
        return
    end
    buffer.writef32(b, off + 12, axis.X * angle)
    buffer.writef32(b, off + 16, axis.Y * angle)
    buffer.writef32(b, off + 20, axis.Z * angle)
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

    local angle = sqrt(sqLen)
    local inv = 1 / angle
    return CFrame.new(px, py, pz)
        * CFrame.fromAxisAngle(Vector3.new(rx * inv, ry * inv, rz * inv), angle)
end

--[[
    Compressed wire layout (16 bytes total):
      [0..11]  position 3x f32
      [12..15] packed [largest:2][a:10][b:10][c:10] — smallest-three quat
]]
local function writeCompressed(b: buffer, off: number, value: CFrame): ()
    local pos = value.Position
    buffer.writef32(b, off, pos.X)
    buffer.writef32(b, off + 4, pos.Y)
    buffer.writef32(b, off + 8, pos.Z)

    local axis, angle = value:ToAxisAngle()
    local h = angle * 0.5
    local s = sin(h)
    local qx = axis.X * s
    local qy = axis.Y * s
    local qz = axis.Z * s
    local qw = cos(h)

    local ax, ay, az, aw = abs(qx), abs(qy), abs(qz), abs(qw)
    local largest, maxVal = 3, aw
    if ax > maxVal then
        largest, maxVal = 0, ax
    end
    if ay > maxVal then
        largest, maxVal = 1, ay
    end
    if az > maxVal then
        largest = 2
    end

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
    qx, qy, qz, qw = qx * sign, qy * sign, qz * sign, qw * sign

    local a, bComp, c: number
    if largest == 0 then
        a, bComp, c = qy, qz, qw
    elseif largest == 1 then
        a, bComp, c = qx, qz, qw
    elseif largest == 2 then
        a, bComp, c = qx, qy, qw
    else
        a, bComp, c = qx, qy, qz
    end

    local qa = clamp(round((a + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qb = clamp(round((bComp + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qc = clamp(round((c + INV_SQRT2) * Q_SCALE), 0, 1023)

    buffer.writeu32(b, off + 12, bor(lshift(largest, 30), lshift(qa, 20), lshift(qb, 10), qc))
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

    local a = qa * Q_INV - INV_SQRT2
    local bComp = qb * Q_INV - INV_SQRT2
    local c = qc * Q_INV - INV_SQRT2

    local sqSum = a * a + bComp * bComp + c * c
    local d = sqrt(if sqSum < 1 then 1 - sqSum else 0)

    local qx, qy, qz, qw: number
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
    if qx * qx + qy * qy + qz * qz < EPSILON_SQ then
        return origin
    end

    local len = sqrt(qx * qx + qy * qy + qz * qz)
    local angle = 2 * acos(clamp(qw, -1, 1))
    local inv = 1 / len
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
