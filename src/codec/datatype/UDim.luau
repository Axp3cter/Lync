--!strict
--!native
-- UDim (8B) and UDim2 (16B) codecs. Scale = f32, Offset = i32.

local Base = require(script.Parent.Parent.Base)
local Signed = require(script.Parent.Parent.primitive.Signed)

-- Private ----------------------------------------------------------------

local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeI32 = Signed.writeI32
local readi32 = buffer.readi32

local function writeUDim(b: buffer, off: number, value: UDim): ()
    writef32(b, off, value.Scale)
    writeI32(b, off + 4, value.Offset)
end

local function readUDim(b: buffer, off: number): UDim
    return UDim.new(readf32(b, off), readi32(b, off + 4))
end

local function writeUDim2(b: buffer, off: number, value: UDim2): ()
    local x, y = value.X, value.Y
    writef32(b, off, x.Scale)
    writeI32(b, off + 4, x.Offset)
    writef32(b, off + 8, y.Scale)
    writeI32(b, off + 12, y.Offset)
end

local function readUDim2(b: buffer, off: number): UDim2
    return UDim2.new(
        UDim.new(readf32(b, off), readi32(b, off + 4)),
        UDim.new(readf32(b, off + 8), readi32(b, off + 12))
    )
end

-- Public -----------------------------------------------------------------

local UDimCodec = {}

UDimCodec.udim = Base.define(8, writeUDim, readUDim, { _typeCheck = "UDim" })
UDimCodec.udim2 = Base.define(16, writeUDim2, readUDim2, { _typeCheck = "UDim2" })

return table.freeze(UDimCodec)
