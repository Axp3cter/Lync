--!strict
--!optimize 2
-- NumberSequence and ColorSequence codecs with varint count.

local Types  = require(script.Parent.Parent.Parent.Types)
local Base   = require(script.Parent.Parent.Base)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private -------------------------------------------------------------

local alloc = Base.alloc
local round = math.round
local clamp = math.clamp

-- Public --------------------------------------------------------------

local SequenceCodec = {}

SequenceCodec.numberSequence = table.freeze({
    _typeCheck = "NumberSequence",

    write = function(ch: Types.ChannelState, value: NumberSequence): ()
        local keypoints = value.Keypoints
        local count = #keypoints
        Varint.write(ch, count)

        if count == 0 then return end

        local bytes = count * 12
        local cursor = ch.cursor
        if cursor + bytes > ch.size then alloc(ch, bytes) end
        local b = ch.buff

        for i = 1, count do
            local kp = keypoints[i]
            local off = cursor + (i - 1) * 12
            buffer.writef32(b, off, kp.Time)
            buffer.writef32(b, off + 4, kp.Value)
            buffer.writef32(b, off + 8, kp.Envelope)
        end

        ch.cursor = cursor + bytes
    end,

    read = function(src: buffer, pos: number, _refs: { Instance }?): (NumberSequence, number)
        local count, lenBytes = Varint.read(src, pos)
        if count == 0 then return NumberSequence.new(0), lenBytes end

        local bytes = count * 12
        local dataStart = pos + lenBytes
        if dataStart + bytes > buffer.len(src) then
            error("[Lync] NumberSequence: data exceeds buffer")
        end

        local keypoints = table.create(count)
        for i = 1, count do
            local off = dataStart + (i - 1) * 12
            keypoints[i] = NumberSequenceKeypoint.new(
                buffer.readf32(src, off),
                buffer.readf32(src, off + 4),
                buffer.readf32(src, off + 8)
            )
        end

        return NumberSequence.new(keypoints), lenBytes + bytes
    end,
} :: any)

SequenceCodec.colorSequence = table.freeze({
    _typeCheck = "ColorSequence",

    write = function(ch: Types.ChannelState, value: ColorSequence): ()
        local keypoints = value.Keypoints
        local count = #keypoints
        Varint.write(ch, count)

        if count == 0 then return end

        local bytes = count * 7
        local cursor = ch.cursor
        if cursor + bytes > ch.size then alloc(ch, bytes) end
        local b = ch.buff

        for i = 1, count do
            local kp = keypoints[i]
            local off = cursor + (i - 1) * 7
            local c = kp.Value
            buffer.writef32(b, off, kp.Time)
            buffer.writeu8(b, off + 4, round(clamp(c.R, 0, 1) * 255))
            buffer.writeu8(b, off + 5, round(clamp(c.G, 0, 1) * 255))
            buffer.writeu8(b, off + 6, round(clamp(c.B, 0, 1) * 255))
        end

        ch.cursor = cursor + bytes
    end,

    read = function(src: buffer, pos: number, _refs: { Instance }?): (ColorSequence, number)
        local count, lenBytes = Varint.read(src, pos)
        if count == 0 then
            return ColorSequence.new(Color3.new()), lenBytes
        end

        local bytes = count * 7
        local dataStart = pos + lenBytes
        if dataStart + bytes > buffer.len(src) then
            error("[Lync] ColorSequence: data exceeds buffer")
        end

        local keypoints = table.create(count)
        for i = 1, count do
            local off = dataStart + (i - 1) * 7
            keypoints[i] = ColorSequenceKeypoint.new(
                buffer.readf32(src, off),
                Color3.fromRGB(
                    buffer.readu8(src, off + 4),
                    buffer.readu8(src, off + 5),
                    buffer.readu8(src, off + 6)
                )
            )
        end

        return ColorSequence.new(keypoints), lenBytes + bytes
    end,
} :: any)

return table.freeze(SequenceCodec)
