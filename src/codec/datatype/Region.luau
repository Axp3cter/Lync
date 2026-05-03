--!strict
--!native
-- Region3 (24B) and Region3int16 (12B) codecs.

local Base = require(script.Parent.Parent.Base)
local Signed = require(script.Parent.Parent.primitive.Signed)

-- Private ----------------------------------------------------------------

local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeI16 = Signed.writeI16
local readi16 = buffer.readi16

-- Region3 has no Min/Max accessors; reconstruct from CFrame.Position +/- Size/2.
local function writeRegion3(b: buffer, off: number, value: Region3): ()
    local pos = value.CFrame.Position
    local half = value.Size * 0.5
    local minV = pos - half
    local maxV = pos + half
    writef32(b, off, minV.X)
    writef32(b, off + 4, minV.Y)
    writef32(b, off + 8, minV.Z)
    writef32(b, off + 12, maxV.X)
    writef32(b, off + 16, maxV.Y)
    writef32(b, off + 20, maxV.Z)
end

local function readRegion3(b: buffer, off: number): Region3
    return Region3.new(
        Vector3.new(readf32(b, off), readf32(b, off + 4), readf32(b, off + 8)),
        Vector3.new(readf32(b, off + 12), readf32(b, off + 16), readf32(b, off + 20))
    )
end

local function writeRegion3I16(b: buffer, off: number, value: Region3int16): ()
    local minV = value.Min
    local maxV = value.Max
    writeI16(b, off, minV.X)
    writeI16(b, off + 2, minV.Y)
    writeI16(b, off + 4, minV.Z)
    writeI16(b, off + 6, maxV.X)
    writeI16(b, off + 8, maxV.Y)
    writeI16(b, off + 10, maxV.Z)
end

local function readRegion3I16(b: buffer, off: number): Region3int16
    return Region3int16.new(
        Vector3int16.new(readi16(b, off), readi16(b, off + 2), readi16(b, off + 4)),
        Vector3int16.new(readi16(b, off + 6), readi16(b, off + 8), readi16(b, off + 10))
    )
end

-- Public -----------------------------------------------------------------

local Region = {}

Region.region3 = Base.define(24, writeRegion3, readRegion3, { _typeCheck = "Region3" })
Region.region3int16 =
    Base.define(12, writeRegion3I16, readRegion3I16, { _typeCheck = "Region3int16" })

return table.freeze(Region)
