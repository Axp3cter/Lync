--!strict
--!native
-- Half-precision float codec. 2 bytes, ±65504, ~3 decimal digits.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local MAX_HALF = 65504
local BIAS = 15
local EXP_MAX = 31
local MANT_BITS = 10
local MANT_SCALE = 1024
local SIGN_BIT = 0x8000
local INF_BITS = 0x7C00
local NAN_BITS = 0x7E00

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local frexp = math.frexp
local ldexp = math.ldexp
local round = math.round
local abs = math.abs
local huge = math.huge

-- Private ----------------------------------------------------------------

local function encode (value: number): number
    if value ~= value then
        return NAN_BITS
    end
    if value == 0 then
        return 0
    end

    local sign = 0
    if value < 0 then
        sign = SIGN_BIT
        value = -value
    end

    if value > MAX_HALF then
        return bor (sign, INF_BITS)
    end

    local mantissa, exponent = frexp (value)
    exponent += 14

    local bits: number
    if exponent <= 0 then
        local shift = exponent + MANT_BITS - 1
        if shift < 0 then
            return sign
        end
        bits = round (mantissa * lshift (1, shift))
    elseif exponent >= EXP_MAX then
        bits = INF_BITS
    else
        bits = bor (lshift (exponent, MANT_BITS), round ((mantissa * 2 - 1) * MANT_SCALE))
    end

    return bor (sign, bits)
end

local function decode (packed: number): number
    local exponent = band (rshift (packed, MANT_BITS), 0x1F)
    local mantissa = band (packed, 0x03FF)

    local result: number
    if exponent == 0 then
        result = if mantissa == 0 then 0 else ldexp (mantissa / MANT_SCALE, 1 - BIAS)
    elseif exponent == EXP_MAX then
        result = if mantissa == 0 then huge else 0 / 0
    else
        result = ldexp (mantissa / MANT_SCALE + 1, exponent - BIAS)
    end

    -- Single sign application
    return if band (packed, SIGN_BIT) ~= 0 then -result else result
end

-- Public -----------------------------------------------------------------

local Float16 = {}

Float16.f16 = table.freeze ({
    _size = 2,
    write = function (ch: ChannelState, value: number): ()
        Channel.alloc (ch, 2)
        buffer.writeu16 (ch.buff, ch.cursor, encode (value))
        ch.cursor += 2
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (number, number)
        return decode (buffer.readu16 (src, pos)), 2
    end,
})

return table.freeze (Float16)
