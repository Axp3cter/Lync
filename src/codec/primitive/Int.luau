--!strict
--!optimize 2
-- Smart integer codec. Auto-selects u8/u16/u32/i8/i16/i32 from range.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local floor = math.floor

-- Public --------------------------------------------------------------

local Int = {}

function Int.int(min: number, max: number): any
    if min > max then
        error(`[Lync] Lync.int: min ({min}) must be <= max ({max})`)
    end
    if floor(min) ~= min or floor(max) ~= max then
        error("[Lync] Lync.int: bounds must be integers")
    end

    local meta = {
        _min = min,
        _max = max,
        _isInteger = true,
        _typeCheck = "number",
    }

    if min >= 0 then
        -- Unsigned path
        if max <= 0xFF then
            return Base.define(1, buffer.writeu8, buffer.readu8, meta)
        elseif max <= 0xFFFF then
            return Base.define(2, buffer.writeu16, buffer.readu16, meta)
        elseif max <= 0xFFFFFFFF then
            return Base.define(4, buffer.writeu32, buffer.readu32, meta)
        end
    else
        -- Signed path: use unsigned write/read, interpret as signed
        if min >= -0x80 and max <= 0x7F then
            return Base.define(1, function(b: buffer, off: number, v: number): ()
                buffer.writeu8(b, off, if v < 0 then v + 0x100 else v)
            end, function(b: buffer, off: number): number
                local raw = buffer.readu8(b, off)
                return if raw >= 0x80 then raw - 0x100 else raw
            end, meta)
        elseif min >= -0x8000 and max <= 0x7FFF then
            return Base.define(2, function(b: buffer, off: number, v: number): ()
                buffer.writeu16(b, off, if v < 0 then v + 0x10000 else v)
            end, function(b: buffer, off: number): number
                local raw = buffer.readu16(b, off)
                return if raw >= 0x8000 then raw - 0x10000 else raw
            end, meta)
        elseif min >= -0x80000000 and max <= 0x7FFFFFFF then
            return Base.define(4, function(b: buffer, off: number, v: number): ()
                buffer.writeu32(b, off, if v < 0 then v + 0x100000000 else v)
            end, function(b: buffer, off: number): number
                local raw = buffer.readu32(b, off)
                return if raw >= 0x80000000 then raw - 0x100000000 else raw
            end, meta)
        end
    end

    error(`[Lync] Lync.int: range [{min}, {max}] exceeds i32 bounds`)
end

return table.freeze(Int)
