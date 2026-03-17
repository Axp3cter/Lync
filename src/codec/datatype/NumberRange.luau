--!strict
--!native
-- NumberRange codec. 8 bytes: min f32 + max f32.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    numberRange = Base.define (8, function (b: buffer, o: number, v: NumberRange): ()
        buffer.writef32 (b, o, v.Min)
        buffer.writef32 (b, o + 4, v.Max)
    end, function (b: buffer, o: number): NumberRange
        return NumberRange.new (buffer.readf32 (b, o), buffer.readf32 (b, o + 4))
    end),
})
