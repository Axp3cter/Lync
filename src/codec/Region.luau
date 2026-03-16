--!strict
--!native
-- Region3 (24B) and Region3int16 (12B) codecs.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Private ----------------------------------------------------------------

local function writeRegion3 (b: buffer, offset: number, value: Region3): ()
    local cf = value.CFrame
    local size = value.Size
    local halfSize = size * 0.5
    local pos = cf.Position
    local minV = pos - halfSize
    local maxV = pos + halfSize
    buffer.writef32 (b, offset, minV.X)
    buffer.writef32 (b, offset + 4, minV.Y)
    buffer.writef32 (b, offset + 8, minV.Z)
    buffer.writef32 (b, offset + 12, maxV.X)
    buffer.writef32 (b, offset + 16, maxV.Y)
    buffer.writef32 (b, offset + 20, maxV.Z)
end

local function readRegion3 (b: buffer, offset: number): Region3
    return Region3.new (
        Vector3.new (
            buffer.readf32 (b, offset),
            buffer.readf32 (b, offset + 4),
            buffer.readf32 (b, offset + 8)
        ),
        Vector3.new (
            buffer.readf32 (b, offset + 12),
            buffer.readf32 (b, offset + 16),
            buffer.readf32 (b, offset + 20)
        )
    )
end

-- Public -----------------------------------------------------------------

local Region = {}

Region.region3 = table.freeze ({
    _size = 24,
    _directWrite = writeRegion3,
    _directRead = readRegion3,
    write = function (ch: ChannelState, value: Region3): ()
        local c = ch.cursor
        if c + 24 > ch.size then
            alloc (ch, 24)
        end
        writeRegion3 (ch.buff, c, value)
        ch.cursor = c + 24
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Region3, number)
        return readRegion3 (src, pos), 24
    end,
})

Region.region3int16 = table.freeze ({
    _size = 12,
    _directWrite = function (b: buffer, offset: number, value: Region3int16): ()
        local minV = value.Min
        local maxV = value.Max
        buffer.writei16 (b, offset, minV.X)
        buffer.writei16 (b, offset + 2, minV.Y)
        buffer.writei16 (b, offset + 4, minV.Z)
        buffer.writei16 (b, offset + 6, maxV.X)
        buffer.writei16 (b, offset + 8, maxV.Y)
        buffer.writei16 (b, offset + 10, maxV.Z)
    end,
    _directRead = function (b: buffer, offset: number): Region3int16
        return Region3int16.new (
            Vector3int16.new (
                buffer.readi16 (b, offset),
                buffer.readi16 (b, offset + 2),
                buffer.readi16 (b, offset + 4)
            ),
            Vector3int16.new (
                buffer.readi16 (b, offset + 6),
                buffer.readi16 (b, offset + 8),
                buffer.readi16 (b, offset + 10)
            )
        )
    end,
    write = function (ch: ChannelState, value: Region3int16): ()
        local c = ch.cursor
        if c + 12 > ch.size then
            alloc (ch, 12)
        end
        local b = ch.buff
        local minV = value.Min
        local maxV = value.Max
        buffer.writei16 (b, c, minV.X)
        buffer.writei16 (b, c + 2, minV.Y)
        buffer.writei16 (b, c + 4, minV.Z)
        buffer.writei16 (b, c + 6, maxV.X)
        buffer.writei16 (b, c + 8, maxV.Y)
        buffer.writei16 (b, c + 10, maxV.Z)
        ch.cursor = c + 12
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (Region3int16, number)
        return Region3int16.new (
            Vector3int16.new (
                buffer.readi16 (src, pos),
                buffer.readi16 (src, pos + 2),
                buffer.readi16 (src, pos + 4)
            ),
            Vector3int16.new (
                buffer.readi16 (src, pos + 6),
                buffer.readi16 (src, pos + 8),
                buffer.readi16 (src, pos + 10)
            )
        ),
            12
    end,
})

return table.freeze (Region)
