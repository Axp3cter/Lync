--!strict
--!native
-- Fixed-point compression. Maps float ranges to integer ranges.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local clamp = math.clamp
local round = math.round
local ceil = math.ceil
local min = math.min
local max = math.max

local U32_MAX = 4294967295

-- Private ----------------------------------------------------------------

local function selectIO (bytes: number): ((b: buffer, offset: number, v: number) -> (), (
    b: buffer,
    offset: number
) -> number)
    if bytes == 1 then
        return buffer.writeu8, buffer.readu8
    end
    if bytes == 2 then
        return buffer.writeu16, buffer.readu16
    end
    return buffer.writeu32, buffer.readu32
end

local function selectWidth (maxInt: number): number
    if maxInt <= 255 then
        return 1
    end
    if maxInt <= 65535 then
        return 2
    end
    return 4
end

-- Public -----------------------------------------------------------------

local Quantized = {}

-- Shared validation and precomputation for both float and vec3 quantizers.
local function setup (minVal: number, maxVal: number, precision: number)
    if minVal > maxVal then
        error (`[Lync] Quantized min > max: {minVal} > {maxVal}`)
    end
    if precision <= 0 then
        error (`[Lync] Quantized precision must be positive: {precision}`)
    end

    local delta = maxVal - minVal
    if delta == 0 then
        return nil
    end

    local maxInt = min (U32_MAX, max (1, ceil (delta / precision)))
    local bytes = selectWidth (maxInt)
    local wfn, rfn = selectIO (bytes)
    local invDelta = 1 / delta
    local invMaxInt = delta / maxInt

    return delta, maxInt, bytes, wfn, rfn, invDelta, invMaxInt
end

function Quantized.float (minVal: number, maxVal: number, precision: number): Codec<number>
    local delta, maxInt, bytes, wfn, rfn, invDelta, invMaxInt = setup (minVal, maxVal, precision)
    if not delta then
        return table.freeze ({
            _size = 0,
            write = function (_ch: ChannelState, _value: number): () end,
            read = function (_src: buffer, _pos: number, _refs: { Instance }?): (number, number)
                return minVal, 0
            end,
        })
    end

    return table.freeze ({
        _size = bytes,
        write = function (ch: ChannelState, value: number): ()
            Channel.alloc (ch, bytes)
            wfn (ch.buff, ch.cursor, round (clamp ((value - minVal) * invDelta, 0, 1) * maxInt))
            ch.cursor += bytes
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (number, number)
            return rfn (src, pos) * invMaxInt + minVal, bytes
        end,
    })
end

function Quantized.vec3 (minVal: number, maxVal: number, precision: number): Codec<Vector3>
    local delta, maxInt, compBytes, wfn, rfn, invDelta, invMaxInt =
        setup (minVal, maxVal, precision)
    if not delta then
        local val = Vector3.new (minVal, minVal, minVal)
        return table.freeze ({
            _size = 0,
            write = function (_ch: ChannelState, _value: Vector3): () end,
            read = function (_src: buffer, _pos: number, _refs: { Instance }?): (Vector3, number)
                return val, 0
            end,
        })
    end

    local totalBytes = compBytes * 3
    local stride = compBytes
    local stride2 = compBytes * 2

    return table.freeze ({
        _size = totalBytes,
        write = function (ch: ChannelState, value: Vector3): ()
            Channel.alloc (ch, totalBytes)
            local b, c = ch.buff, ch.cursor
            wfn (b, c, round (clamp ((value.X - minVal) * invDelta, 0, 1) * maxInt))
            wfn (b, c + stride, round (clamp ((value.Y - minVal) * invDelta, 0, 1) * maxInt))
            wfn (b, c + stride2, round (clamp ((value.Z - minVal) * invDelta, 0, 1) * maxInt))
            ch.cursor = c + totalBytes
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (Vector3, number)
            return Vector3.new (
                rfn (src, pos) * invMaxInt + minVal,
                rfn (src, pos + stride) * invMaxInt + minVal,
                rfn (src, pos + stride2) * invMaxInt + minVal
            ),
                totalBytes
        end,
    })
end

return table.freeze (Quantized)
