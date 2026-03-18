--!strict
--!native
-- Region3(24B) and Region3int16(12B) codecs.

local Base = require(script.Parent.Parent.Base)

local function writeRegion3(b: buffer, o: number, v: Region3): ()
    local cf = v.CFrame
    local size = v.Size
    local halfSize = size * 0.5
    local pos = cf.Position
    local minV = pos - halfSize
    local maxV = pos + halfSize
    buffer.writef32(b, o, minV.X)
    buffer.writef32(b, o + 4, minV.Y)
    buffer.writef32(b, o + 8, minV.Z)
    buffer.writef32(b, o + 12, maxV.X)
    buffer.writef32(b, o + 16, maxV.Y)
    buffer.writef32(b, o + 20, maxV.Z)
end

local function readRegion3(b: buffer, o: number): Region3
    return Region3.new(
        Vector3.new(buffer.readf32(b, o), buffer.readf32(b, o + 4), buffer.readf32(b, o + 8)),
        Vector3.new(buffer.readf32(b, o + 12), buffer.readf32(b, o + 16), buffer.readf32(b, o + 20))
    )
end

return table.freeze({
    region3 = Base.define(24, writeRegion3, readRegion3),
    region3int16 = Base.define(12, function(b: buffer, o: number, v: Region3int16): ()
        local minV = v.Min
        local maxV = v.Max
        buffer.writei16(b, o, minV.X)
        buffer.writei16(b, o + 2, minV.Y)
        buffer.writei16(b, o + 4, minV.Z)
        buffer.writei16(b, o + 6, maxV.X)
        buffer.writei16(b, o + 8, maxV.Y)
        buffer.writei16(b, o + 10, maxV.Z)
    end, function(b: buffer, o: number): Region3int16
        return Region3int16.new(
            Vector3int16.new(
                buffer.readi16(b, o),
                buffer.readi16(b, o + 2),
                buffer.readi16(b, o + 4)
            ),
            Vector3int16.new(
                buffer.readi16(b, o + 6),
                buffer.readi16(b, o + 8),
                buffer.readi16(b, o + 10)
            )
        )
    end),
})
