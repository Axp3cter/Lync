--!strict
--!optimize 2
-- Range-typed integer codec. Picks the narrowest u8/u16/u32/i8/i16/i32 form.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Signed = require(script.Parent.Signed)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local floor = math.floor
local writeI8 = Signed.writeI8
local writeI16 = Signed.writeI16
local writeI32 = Signed.writeI32

-- Public -----------------------------------------------------------------

local Int = {}

function Int.int(min: number, max: number): Types.InternalCodec<number>
    if min > max then
        Log.error(`min ({min}) must be <= max ({max})`)
    end
    Log.assert(floor(min) == min and floor(max) == max, "bounds must be integers")

    local meta = {
        _min = min,
        _max = max,
        _isInteger = true,
        _typeCheck = "number",
    }

    if min >= 0 then
        if max <= 0xFF then
            return Base.define(1, buffer.writeu8, buffer.readu8, meta)
        end
        if max <= 0xFFFF then
            return Base.define(2, buffer.writeu16, buffer.readu16, meta)
        end
        if max <= 0xFFFFFFFF then
            return Base.define(4, buffer.writeu32, buffer.readu32, meta)
        end
    else
        if min >= -0x80 and max <= 0x7F then
            return Base.define(1, writeI8, buffer.readi8, meta)
        end
        if min >= -0x8000 and max <= 0x7FFF then
            return Base.define(2, writeI16, buffer.readi16, meta)
        end
        if min >= -0x80000000 and max <= 0x7FFFFFFF then
            return Base.define(4, writeI32, buffer.readi32, meta)
        end
    end

    Log.error(`range [{min}, {max}] exceeds i32 bounds`)
end

return table.freeze(Int)
