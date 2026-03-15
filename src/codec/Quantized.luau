--!strict
--!native
-- Quantized.luau — Fixed-point compression. Maps float ranges to integer ranges.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local clamp = math.clamp
local round = math.round
local ceil  = math.ceil
local max   = math.max

-- Private ----------------------------------------------------------------

local function selectIO(bytes: number): (
    (b: buffer, offset: number, v: number) -> (),
    (b: buffer, offset: number) -> number
)
    if bytes == 1 then return buffer.writeu8, buffer.readu8 end
    if bytes == 2 then return buffer.writeu16, buffer.readu16 end
    return buffer.writeu32, buffer.readu32
end

local function selectWidth(maxInt: number): number
    if maxInt <= 255 then return 1 end
    if maxInt <= 65535 then return 2 end
    return 4
end

-- Public -----------------------------------------------------------------

local Quantized = {}

function Quantized.float(minVal: number, maxVal: number, precision: number): Codec<number>
    if minVal > maxVal then error(`[Lync] Quantized: min ({minVal}) > max ({maxVal})`) end
    if precision <= 0 then error(`[Lync] Quantized: precision must be positive ({precision})`) end

    local delta = maxVal - minVal

    if delta == 0 then
        local bytes  = 1
        local wfn, _ = selectIO(bytes)
        return table.freeze({
            write = function(ch: ChannelState, _value: number): ()
                Channel.alloc(ch, bytes)
                wfn(ch.buff, ch.cursor, 0)
                ch.cursor += bytes
            end,
            read = function(_src: buffer, _pos: number, _refs: { Instance }?): (number, number)
                return minVal, bytes
            end,
        })
    end

    local maxInt   = max(1, ceil(delta / precision))
    local bytes    = selectWidth(maxInt)
    local wfn, rfn = selectIO(bytes)
    local invDelta = 1 / delta
    local scale    = delta / maxInt

    return table.freeze({
        write = function(ch: ChannelState, value: number): ()
            Channel.alloc(ch, bytes)
            wfn(ch.buff, ch.cursor, round(clamp((value - minVal) * invDelta, 0, 1) * maxInt))
            ch.cursor += bytes
        end,
        read = function(src: buffer, pos: number, _refs: { Instance }?): (number, number)
            return rfn(src, pos) * scale + minVal, bytes
        end,
    })
end

function Quantized.vec3(minVal: number, maxVal: number, precision: number): Codec<Vector3>
    if minVal > maxVal then error(`[Lync] Quantized: min ({minVal}) > max ({maxVal})`) end
    if precision <= 0 then error(`[Lync] Quantized: precision must be positive ({precision})`) end

    local delta = maxVal - minVal

    if delta == 0 then
        local val        = Vector3.new(minVal, minVal, minVal)
        local compBytes  = 1
        local totalBytes = 3
        local wfn, _     = selectIO(compBytes)
        return table.freeze({
            write = function(ch: ChannelState, _value: Vector3): ()
                Channel.alloc(ch, totalBytes)
                local b, c = ch.buff, ch.cursor
                wfn(b, c,     0)
                wfn(b, c + 1, 0)
                wfn(b, c + 2, 0)
                ch.cursor = c + totalBytes
            end,
            read = function(_src: buffer, _pos: number, _refs: { Instance }?): (Vector3, number)
                return val, totalBytes
            end,
        })
    end

    local maxInt     = max(1, ceil(delta / precision))
    local compBytes  = selectWidth(maxInt)
    local totalBytes = compBytes * 3
    local wfn, rfn   = selectIO(compBytes)
    local invDelta   = 1 / delta
    local scale      = delta / maxInt
    local stride2    = compBytes * 2

    return table.freeze({
        write = function(ch: ChannelState, value: Vector3): ()
            Channel.alloc(ch, totalBytes)
            local b, c = ch.buff, ch.cursor
            wfn(b, c,             round(clamp((value.X - minVal) * invDelta, 0, 1) * maxInt))
            wfn(b, c + compBytes, round(clamp((value.Y - minVal) * invDelta, 0, 1) * maxInt))
            wfn(b, c + stride2,   round(clamp((value.Z - minVal) * invDelta, 0, 1) * maxInt))
            ch.cursor = c + totalBytes
        end,
        read = function(src: buffer, pos: number, _refs: { Instance }?): (Vector3, number)
            return Vector3.new(
                rfn(src, pos)             * scale + minVal,
                rfn(src, pos + compBytes) * scale + minVal,
                rfn(src, pos + stride2)   * scale + minVal
            ), totalBytes
        end,
    })
end

return table.freeze(Quantized)
