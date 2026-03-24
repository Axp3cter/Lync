--!strict
--!optimize 2
-- NumberRange codec. 8 bytes: Min f32 + Max f32.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local NumberRangeCodec = {}

NumberRangeCodec.numberRange = Base.define(8,
    function(b: buffer, off: number, value: NumberRange): ()
        buffer.writef32(b, off, value.Min)
        buffer.writef32(b, off + 4, value.Max)
    end,
    function(b: buffer, off: number): NumberRange
        return NumberRange.new(
            buffer.readf32(b, off),
            buffer.readf32(b, off + 4)
        )
    end,
    { _typeCheck = "NumberRange" }
)

return table.freeze(NumberRangeCodec)
