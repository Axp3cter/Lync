--!strict
--!native
-- Fixed-point quantization codec. Maps float ranges to integer ranges.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local ceil  = math.ceil
local clamp = math.clamp
local round = math.round
local max   = math.max
local min   = math.min

-- Public --------------------------------------------------------------

local Float = {}

function Float.float(rangeMin: number, rangeMax: number, precision: number): any
    if rangeMin > rangeMax then
        error(`[Lync] Lync.float: min ({rangeMin}) must be <= max ({rangeMax})`)
    end
    if precision <= 0 then
        error("[Lync] Lync.float: precision must be positive")
    end

    local delta = rangeMax - rangeMin

    -- Constant value: zero bytes
    if delta == 0 then
        return Base.zero()
    end

    local maxInt = min(0xFFFFFFFF, max(1, ceil(delta / precision)))

    local compBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number

    if maxInt <= 0xFF then
        compBytes = 1
        wfn = buffer.writeu8
        rfn = buffer.readu8
    elseif maxInt <= 0xFFFF then
        compBytes = 2
        wfn = buffer.writeu16
        rfn = buffer.readu16
    else
        compBytes = 4
        wfn = buffer.writeu32
        rfn = buffer.readu32
    end

    local scale    = maxInt / delta
    local invScale = delta / maxInt

    return Base.define(compBytes,
        function(b: buffer, off: number, value: number): ()
            wfn(b, off, round(clamp(value - rangeMin, 0, delta) * scale))
        end,
        function(b: buffer, off: number): number
            return rfn(b, off) * invScale + rangeMin
        end,
        { _min = rangeMin, _max = rangeMax, _typeCheck = "number" }
    )
end

return table.freeze(Float)
