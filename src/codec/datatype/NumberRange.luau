--!strict
--!optimize 2
-- NumberRange codec. 8 bytes: Min f32 + Max f32.

local Base = require(script.Parent.Parent.Base)

-- Private ----------------------------------------------------------------

local function writeNumberRange(b: buffer, off: number, value: NumberRange): ()
    buffer.writef32(b, off, value.Min)
    buffer.writef32(b, off + 4, value.Max)
end

local function readNumberRange(b: buffer, off: number): NumberRange
    local minV = buffer.readf32(b, off)
    local maxV = buffer.readf32(b, off + 4)
    -- NumberRange.new requires min <= max; swap on corruption rather than throw.
    if minV > maxV then
        minV, maxV = maxV, minV
    end
    return NumberRange.new(minV, maxV)
end

-- Public -----------------------------------------------------------------

local NumberRangeCodec = {}

NumberRangeCodec.numberRange = Base.define(8, writeNumberRange, readNumberRange, {
    _typeCheck = "NumberRange",
})

return table.freeze(NumberRangeCodec)
