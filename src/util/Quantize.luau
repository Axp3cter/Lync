--!strict
--!optimize 2
-- Fixed-point range quantizer setup shared by float and vector codecs.

local Log = require(script.Parent.Log)

-- Private ----------------------------------------------------------------

local ceil = math.ceil
local maxN = math.max
local minN = math.min

local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

--[[
    24-bit wire form. Splits into u16 + u8 since the buffer API has no native
    u24. Saves 1 byte over u32 for ranges needing 17–24 bits of precision.
]]
local function writeu24(b: buffer, off: number, value: number): ()
    writeu16(b, off, band(value, 0xFFFF))
    writeu8(b, off + 2, band(rshift(value, 16), 0xFF))
end

local function readu24(b: buffer, off: number): number
    return bor(readu16(b, off), lshift(readu8(b, off + 2), 16))
end

-- Public -----------------------------------------------------------------

local Quantize = {}

--[[
    Pick the narrowest u8/u16/u24/u32 wire form for [rangeMin, rangeMax] at
    `precision`. Returns (compBytes, wfn, rfn, scale, invScale, delta).
    `apiName` shows in error messages so callers see their public surface.
]]
function Quantize.setup(
    apiName: string,
    rangeMin: number,
    rangeMax: number,
    precision: number
): (
    number,
    (buffer, number, number) -> (),
    (buffer, number) -> number,
    number,
    number,
    number
)
    if rangeMin >= rangeMax then
        Log.error(`{apiName}: min ({rangeMin}) must be < max ({rangeMax})`)
    end
    if precision <= 0 then
        Log.error(`{apiName}: precision must be positive, got {precision}`)
    end

    local delta = rangeMax - rangeMin
    -- Clamp to [1, U32_MAX] so wire-form selection has a valid value.
    local maxInt = minN(0xFFFFFFFF, maxN(1, ceil(delta / precision)))

    local compBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number
    if maxInt <= 0xFF then
        compBytes, wfn, rfn = 1, buffer.writeu8, buffer.readu8
    elseif maxInt <= 0xFFFF then
        compBytes, wfn, rfn = 2, buffer.writeu16, buffer.readu16
    elseif maxInt <= 0xFFFFFF then
        compBytes, wfn, rfn = 3, writeu24, readu24
    else
        compBytes, wfn, rfn = 4, buffer.writeu32, buffer.readu32
    end

    return compBytes, wfn, rfn, maxInt / delta, delta / maxInt, delta
end

return table.freeze(Quantize)
