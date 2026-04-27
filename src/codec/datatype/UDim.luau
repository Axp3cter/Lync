--!strict
--!optimize 2
-- UDim (8 bytes) and UDim2 (16 bytes) codecs. Scale is f32, Offset is i32.

local Base = require(script.Parent.Parent.Base)
local Signed = require(script.Parent.Parent.primitive.Signed)

-- Private ----------------------------------------------------------------

local writeI32 = Signed.writeI32
local readi32 = buffer.readi32

local function writeUDim(b: buffer, off: number, value: UDim): ()
    buffer.writef32(b, off, value.Scale)
    writeI32(b, off + 4, value.Offset)
end

local function readUDim(b: buffer, off: number): UDim
    return UDim.new(buffer.readf32(b, off), readi32(b, off + 4))
end

local function writeUDim2(b: buffer, off: number, value: UDim2): ()
    local x, y = value.X, value.Y
    buffer.writef32(b, off, x.Scale)
    writeI32(b, off + 4, x.Offset)
    buffer.writef32(b, off + 8, y.Scale)
    writeI32(b, off + 12, y.Offset)
end

local function readUDim2(b: buffer, off: number): UDim2
    return UDim2.new(
        UDim.new(buffer.readf32(b, off), readi32(b, off + 4)),
        UDim.new(buffer.readf32(b, off + 8), readi32(b, off + 12))
    )
end

-- Public -----------------------------------------------------------------

local UDimCodec = {}

UDimCodec.udim = Base.define(8, writeUDim, readUDim, { _typeCheck = "UDim" })
UDimCodec.udim2 = Base.define(16, writeUDim2, readUDim2, { _typeCheck = "UDim2" })

return table.freeze(UDimCodec)
