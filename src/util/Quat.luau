--!strict
--!native
-- Smallest-three quaternion packing into a single u32 for rotation wire forms.

-- Constants --------------------------------------------------------------

local INV_SQRT2 = 1 / math.sqrt(2)
local Q_SCALE = 1023 / (2 * INV_SQRT2)
local Q_INV = (2 * INV_SQRT2) / 1023
local EPSILON_SQ = 5.76e-14

-- Private ----------------------------------------------------------------

local abs = math.abs
local clamp = math.clamp
local round = math.round
local sin = math.sin
local cos = math.cos
local acos = math.acos
local sqrt = math.sqrt
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Public -----------------------------------------------------------------

local Quat = {}

--[[
    Quaternion from a CFrame's rotation portion. Returns (qx, qy, qz, qw)
    so callers can pack without rebuilding the conversion table.
]]
function Quat.fromCFrame(cf: CFrame): (number, number, number, number)
    local axis, angle = cf:ToAxisAngle()
    local h = angle * 0.5
    local s = sin(h)
    return axis.X * s, axis.Y * s, axis.Z * s, cos(h)
end

--[[
    Pack a unit quaternion into a single u32:
      [largest:2][a:10][b:10][c:10]
    Drops the largest |component|; reconstructed from the other three with
    the constraint qx²+qy²+qz²+qw² = 1. Forces the dropped value
    non-negative so the +sqrt path on decode yields the correct sign.
]]
function Quat.pack(qx: number, qy: number, qz: number, qw: number): number
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

    local a: number, b: number, c: number
    if largest == 0 then
        if qx < 0 then
            qy, qz, qw = -qy, -qz, -qw
        end
        a, b, c = qy, qz, qw
    elseif largest == 1 then
        if qy < 0 then
            qx, qz, qw = -qx, -qz, -qw
        end
        a, b, c = qx, qz, qw
    elseif largest == 2 then
        if qz < 0 then
            qx, qy, qw = -qx, -qy, -qw
        end
        a, b, c = qx, qy, qw
    else
        if qw < 0 then
            qx, qy, qz = -qx, -qy, -qz
        end
        a, b, c = qx, qy, qz
    end

    local qa = clamp(round((a + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qb = clamp(round((b + INV_SQRT2) * Q_SCALE), 0, 1023)
    local qc = clamp(round((c + INV_SQRT2) * Q_SCALE), 0, 1023)
    return bor(lshift(largest, 30), lshift(qa, 20), lshift(qb, 10), qc)
end

-- Reverse Quat.pack into a rotation-only CFrame. Identity for near-zero magnitudes.
function Quat.unpack(packed: number): CFrame
    local largest = rshift(packed, 30)
    local qa = band(rshift(packed, 20), 0x3FF)
    local qb = band(rshift(packed, 10), 0x3FF)
    local qc = band(packed, 0x3FF)

    local a = qa * Q_INV - INV_SQRT2
    local b = qb * Q_INV - INV_SQRT2
    local c = qc * Q_INV - INV_SQRT2

    local sqSum = a * a + b * b + c * c
    local d = sqrt(if sqSum < 1 then 1 - sqSum else 0)

    local qx: number, qy: number, qz: number, qw: number
    if largest == 0 then
        qx, qy, qz, qw = d, a, b, c
    elseif largest == 1 then
        qx, qy, qz, qw = a, d, b, c
    elseif largest == 2 then
        qx, qy, qz, qw = a, b, d, c
    else
        qx, qy, qz, qw = a, b, c, d
    end

    local sqLen = qx * qx + qy * qy + qz * qz
    if sqLen < EPSILON_SQ then
        return CFrame.identity
    end
    local angle = 2 * acos(clamp(qw, -1, 1))
    local inv = 1 / sqrt(sqLen)
    return CFrame.fromAxisAngle(Vector3.new(qx * inv, qy * inv, qz * inv), angle)
end

return table.freeze(Quat)
