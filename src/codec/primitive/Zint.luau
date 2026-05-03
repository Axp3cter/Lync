--!strict
--!native
-- Signed varint via zigzag mapping. Small magnitudes pack in 1 byte.

local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Constants --------------------------------------------------------------

--[[
    Zigzag fold maps signed values onto unsigned varint space:
      n >= 0  -> 2n
      n < 0   -> -2n - 1
    Inverse: low bit selects sign, shift down 1 bit.

    Wire ranges (using Varint dense form):
      1 byte: [-96, 95]
      2 bytes: [-4192, 4191]
      3 bytes: [-528480, 528479]
      5 bytes: full i32
]]
local I32_MIN = -0x80000000
local I32_MAX = 0x7FFFFFFF

-- Private ----------------------------------------------------------------

local floor = math.floor
local band = bit32.band
local varintWrite = Varint.write
local varintRead = Varint.read

-- Signed -> unsigned. Hot path; called per write of every delta scalar.
local function encode(value: number): number
    if value >= 0 then
        return value * 2
    end
    return value * -2 - 1
end

-- Inverse of encode. Even -> n/2; odd -> -((n+1)/2). Branchless on the half.
local function decode(raw: number): number
    local low = band(raw, 1)
    local half = (raw - low) / 2
    return if low == 1 then -half - 1 else half
end

-- Public -----------------------------------------------------------------

local Zint = {}

Zint.encode = encode
Zint.decode = decode

--[[
    Variable-length signed integer in [I32_MIN, I32_MAX]. Optional [min, max]
    bounds gate input at write time so out-of-range payloads error early
    rather than corrupting downstream decoders.
]]
function Zint.zint(min: number?, max: number?): Types.InternalCodec<number>
    local lo = min or I32_MIN
    local hi = max or I32_MAX
    if lo > hi then
        Log.error(`min ({lo}) must be <= max ({hi})`)
    end
    if floor(lo) ~= lo or floor(hi) ~= hi then
        Log.error("bounds must be integers")
    end
    if lo < I32_MIN or hi > I32_MAX then
        Log.error(`range [{lo}, {hi}] exceeds i32 bounds`)
    end

    return table.freeze({
        _typeCheck = "number",
        _isInteger = true,
        _min = lo,
        _max = hi,

        write = function(ch: Types.ChannelState, value: number): ()
            if value < lo or value > hi then
                Log.error(`value {value} out of range [{lo}, {hi}]`)
            end
            if floor(value) ~= value then
                Log.error(`value {value} must be an integer`)
            end
            varintWrite(ch, encode(value))
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): (number, number)
            local raw, consumed = varintRead(src, pos)
            if consumed == 0 then
                Log.error("truncated zint")
            end
            return decode(raw), consumed
        end,
    }) :: Types.InternalCodec<number>
end

return table.freeze(Zint)
