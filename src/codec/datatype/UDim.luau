--!strict
--!optimize 2
-- UDim (8 bytes) and UDim2 (16 bytes) codecs.

local Base = require(script.Parent.Parent.Base)

-- Public --------------------------------------------------------------

local UDimCodec = {}

UDimCodec.udim = Base.define(8, function(b: buffer, off: number, value: UDim): ()
    buffer.writef32(b, off, value.Scale)
    buffer.writeu32(
        b,
        off + 4,
        if value.Offset < 0 then value.Offset + 0x100000000 else value.Offset
    )
end, function(b: buffer, off: number): UDim
    local rawOff = buffer.readu32(b, off + 4)
    return UDim.new(
        buffer.readf32(b, off),
        if rawOff >= 0x80000000 then rawOff - 0x100000000 else rawOff
    )
end, { _typeCheck = "UDim" })

UDimCodec.udim2 = Base.define(16, function(b: buffer, off: number, value: UDim2): ()
    local x = value.X
    local y = value.Y
    buffer.writef32(b, off, x.Scale)
    buffer.writeu32(b, off + 4, if x.Offset < 0 then x.Offset + 0x100000000 else x.Offset)
    buffer.writef32(b, off + 8, y.Scale)
    buffer.writeu32(b, off + 12, if y.Offset < 0 then y.Offset + 0x100000000 else y.Offset)
end, function(b: buffer, off: number): UDim2
    local xOff = buffer.readu32(b, off + 4)
    local yOff = buffer.readu32(b, off + 12)
    return UDim2.new(
        UDim.new(buffer.readf32(b, off), if xOff >= 0x80000000 then xOff - 0x100000000 else xOff),
        UDim.new(
            buffer.readf32(b, off + 8),
            if yOff >= 0x80000000 then yOff - 0x100000000 else yOff
        )
    )
end, { _typeCheck = "UDim2" })

return table.freeze(UDimCodec)
