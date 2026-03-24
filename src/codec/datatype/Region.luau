--!strict
--!optimize 2
-- Region3 (24 bytes) and Region3int16 (12 bytes) codecs.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local function writeI16(b: buffer, off: number, v: number): ()
    buffer.writeu16(b, off, if v < 0 then v + 0x10000 else v)
end

local function readI16(b: buffer, off: number): number
    local raw = buffer.readu16(b, off)
    return if raw >= 0x8000 then raw - 0x10000 else raw
end

-- Public --------------------------------------------------------------

local RegionCodec = {}

RegionCodec.region3 = Base.define(24,
    function(b: buffer, off: number, value: Region3): ()
        local pos = value.CFrame.Position
        local half = value.Size * 0.5
        local minV = pos - half
        local maxV = pos + half
        buffer.writef32(b, off, minV.X)
        buffer.writef32(b, off + 4, minV.Y)
        buffer.writef32(b, off + 8, minV.Z)
        buffer.writef32(b, off + 12, maxV.X)
        buffer.writef32(b, off + 16, maxV.Y)
        buffer.writef32(b, off + 20, maxV.Z)
    end,
    function(b: buffer, off: number): Region3
        return Region3.new(
            Vector3.new(
                buffer.readf32(b, off),
                buffer.readf32(b, off + 4),
                buffer.readf32(b, off + 8)
            ),
            Vector3.new(
                buffer.readf32(b, off + 12),
                buffer.readf32(b, off + 16),
                buffer.readf32(b, off + 20)
            )
        )
    end,
    { _typeCheck = "Region3" }
)

RegionCodec.region3int16 = Base.define(12,
    function(b: buffer, off: number, value: Region3int16): ()
        local minV = value.Min
        local maxV = value.Max
        writeI16(b, off, minV.X)
        writeI16(b, off + 2, minV.Y)
        writeI16(b, off + 4, minV.Z)
        writeI16(b, off + 6, maxV.X)
        writeI16(b, off + 8, maxV.Y)
        writeI16(b, off + 10, maxV.Z)
    end,
    function(b: buffer, off: number): Region3int16
        return Region3int16.new(
            Vector3int16.new(readI16(b, off), readI16(b, off + 2), readI16(b, off + 4)),
            Vector3int16.new(readI16(b, off + 6), readI16(b, off + 8), readI16(b, off + 10))
        )
    end,
    { _typeCheck = "Region3int16" }
)

return table.freeze(RegionCodec)
