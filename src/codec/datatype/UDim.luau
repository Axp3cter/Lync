--!strict
--!native
-- UDim (8B) and UDim2 (16B) codecs.

local Base = require (script.Parent.Parent.Base)

return table.freeze ({
    udim = Base.define (8, function (b: buffer, o: number, v: UDim): ()
        buffer.writef32 (b, o, v.Scale)
        buffer.writei32 (b, o + 4, v.Offset)
    end, function (b: buffer, o: number): UDim
        return UDim.new (buffer.readf32 (b, o), buffer.readi32 (b, o + 4))
    end),
    udim2 = Base.define (16, function (b: buffer, o: number, v: UDim2): ()
        local x = v.X
        local y = v.Y
        buffer.writef32 (b, o, x.Scale)
        buffer.writei32 (b, o + 4, x.Offset)
        buffer.writef32 (b, o + 8, y.Scale)
        buffer.writei32 (b, o + 12, y.Offset)
    end, function (b: buffer, o: number): UDim2
        return UDim2.new (
            UDim.new (buffer.readf32 (b, o), buffer.readi32 (b, o + 4)),
            UDim.new (buffer.readf32 (b, o + 8), buffer.readi32 (b, o + 12))
        )
    end),
})
