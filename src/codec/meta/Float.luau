--!strict
--!native
-- Fixed-point quantization codec. Maps a float range to u8/u16/u32.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local ceil = math.ceil
local clamp = math.clamp
local round = math.round
local maxN = math.max
local minN = math.min

-- Public -----------------------------------------------------------------

local Float = {}

function Float.float(
    rangeMin: number,
    rangeMax: number,
    precision: number
): Types.InternalCodec<number>
    if rangeMin > rangeMax then
        error(`[Lync] Lync.float: min ({rangeMin}) must be <= max ({rangeMax})`)
    end
    if precision <= 0 then
        error("[Lync] Lync.float: precision must be positive")
    end

    local delta = rangeMax - rangeMin
    if delta == 0 then
        return Base.constant(rangeMin)
    end

    local maxInt = minN(0xFFFFFFFF, maxN(1, ceil(delta / precision)))

    local compBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number
    if maxInt <= 0xFF then
        compBytes, wfn, rfn = 1, buffer.writeu8, buffer.readu8
    elseif maxInt <= 0xFFFF then
        compBytes, wfn, rfn = 2, buffer.writeu16, buffer.readu16
    else
        compBytes, wfn, rfn = 4, buffer.writeu32, buffer.readu32
    end

    local scale = maxInt / delta
    local invScale = delta / maxInt

    return Base.define(compBytes, function(b: buffer, off: number, value: number): ()
        wfn(b, off, round(clamp(value - rangeMin, 0, delta) * scale))
    end, function(b: buffer, off: number): number
        return rfn(b, off) * invScale + rangeMin
    end, { _min = rangeMin, _max = rangeMax, _typeCheck = "number" })
end

return table.freeze(Float)
