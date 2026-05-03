--!strict
--!native
-- IEEE 754 binary16 codec. 2 bytes, +/-65504 finite range, ~3 decimal digits.

local Base = require(script.Parent.Parent.Base)

-- Constants --------------------------------------------------------------

local MAX_FINITE = 65504
local NAN_BITS = 0x7E00
local INF_BITS = 0x7C00

-- Private ----------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local frexp = math.frexp
local ldexp = math.ldexp
local round = math.round
local huge = math.huge
local isnan = math.isnan

local function encode(value: number): number
    if isnan(value) then
        return NAN_BITS
    end
    if value == 0 then
        return 0
    end

    local sign = 0
    if value < 0 then
        sign = 0x8000
        value = -value
    end

    if value > MAX_FINITE then
        return bor(sign, INF_BITS)
    end

    local mantissa, exponent = frexp(value)
    local biasedExp = exponent + 14

    -- Subnormal: shift mantissa into the 10-bit fraction with the implicit bit gone.
    if biasedExp <= 0 then
        local frac = round(ldexp(mantissa, biasedExp + 10))
        if frac >= 1024 then
            return bor(sign, 0x0400)
        end
        if frac <= 0 then
            return sign
        end
        return bor(sign, frac)
    end

    local frac = round((mantissa * 2 - 1) * 1024)
    -- Rounding can carry into the exponent; absorb it.
    if frac >= 1024 then
        frac = 0
        biasedExp += 1
    end

    if biasedExp >= 31 then
        return bor(sign, INF_BITS)
    end

    return bor(sign, lshift(biasedExp, 10), frac)
end

local function decode(raw: number): number
    local sign = band(raw, 0x8000)
    local exp = band(rshift(raw, 10), 0x1F)
    local frac = band(raw, 0x03FF)

    local value: number
    if exp == 0 then
        value = if frac == 0 then 0 else ldexp(frac, -24)
    elseif exp == 31 then
        value = if frac == 0 then huge else 0 / 0
    else
        value = ldexp(frac + 1024, exp - 25)
    end

    return if sign ~= 0 then -value else value
end

-- Public -----------------------------------------------------------------

local Float16 = {}

Float16.f16 = Base.define(2, function(b: buffer, off: number, value: number): ()
    buffer.writeu16(b, off, encode(value))
end, function(b: buffer, off: number): number
    return decode(buffer.readu16(b, off))
end, { _typeCheck = "number" })

return table.freeze(Float16)
