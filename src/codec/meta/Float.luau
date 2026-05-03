--!strict
--!native
-- Fixed-point float quantizer. Maps a float range to u8/u16/u32.

local Base = require(script.Parent.Parent.Base)
local Quantize = require(script.Parent.Parent.Parent.util.Quantize)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local clamp = math.clamp
local round = math.round

-- Public -----------------------------------------------------------------

local Float = {}

function Float.float(
    rangeMin: number,
    rangeMax: number,
    precision: number
): Types.InternalCodec<number>
    -- Degenerate range: emit nothing, decode to the constant.
    if rangeMax - rangeMin == 0 then
        return Base.constant(rangeMin)
    end

    local compBytes, wfn, rfn, scale, invScale, delta =
        Quantize.setup("Lync.float", rangeMin, rangeMax, precision)

    return Base.define(compBytes, function(b: buffer, off: number, value: number): ()
        wfn(b, off, round(clamp(value - rangeMin, 0, delta) * scale))
    end, function(b: buffer, off: number): number
        return rfn(b, off) * invScale + rangeMin
    end, { _min = rangeMin, _max = rangeMax, _typeCheck = "number" })
end

return table.freeze(Float)
