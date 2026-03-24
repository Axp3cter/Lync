--!strict
--!native
-- Half-precision float codec. 2 bytes, ±65504, ~3 decimal digits.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local frexp  = math.frexp
local ldexp  = math.ldexp
local round  = math.round
local huge   = math.huge

local function encode(value: number): number
    -- NaN
    if value ~= value then return 0x7E00 end

    -- Zero (both +0 and -0 map to positive zero)
    if value == 0 then return 0 end

    -- Sign extraction
    local sign = 0
    if value < 0 then
        sign = 0x8000
        value = -value
    end

    -- Overflow to infinity
    if value > 65504 then return bor(sign, 0x7C00) end

    -- Decompose via frexp: value = mantissa * 2^exponent, mantissa in [0.5, 1)
    local mantissa, exponent = frexp(value)
    local biasedExp = exponent + 14

    if biasedExp <= 0 then
        -- Subnormal: frac = round(mantissa * 2^(biasedExp + 10))
        local frac = round(ldexp(mantissa, biasedExp + 10))
        if frac >= 1024 then
            -- Rounds to minimum normal
            return bor(sign, 0x0400)
        end
        if frac <= 0 then return sign end
        return bor(sign, frac)
    end

    -- Normal: frac = round((mantissa * 2 - 1) * 1024)
    local frac = round((mantissa * 2 - 1) * 1024)

    -- Carry: mantissa rounding overflows into exponent
    if frac >= 1024 then
        frac = 0
        biasedExp += 1
    end

    -- Overflow after carry
    if biasedExp >= 31 then return bor(sign, 0x7C00) end

    return bor(sign, lshift(biasedExp, 10), frac)
end

local function decode(raw: number): number
    local sign = band(raw, 0x8000)
    local exp  = band(rshift(raw, 10), 0x1F)
    local frac = band(raw, 0x03FF)

    local value: number

    if exp == 0 then
        -- Zero or subnormal
        value = if frac == 0 then 0 else ldexp(frac, -24)
    elseif exp == 31 then
        -- Infinity or NaN
        value = if frac == 0 then huge else 0 / 0
    else
        -- Normal: (frac + 1024) * 2^(exp - 25)
        value = ldexp(frac + 1024, exp - 25)
    end

    return if sign ~= 0 then -value else value
end

-- Public --------------------------------------------------------------

local Float16 = {}

Float16.f16 = Base.define(2,
    function(b: buffer, off: number, value: number): ()
        buffer.writeu16(b, off, encode(value))
    end,
    function(b: buffer, off: number): number
        return decode(buffer.readu16(b, off))
    end,
    { _typeCheck = "number" }
)

return table.freeze(Float16)
