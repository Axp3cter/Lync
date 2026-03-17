--!strict
--!native
-- NumberSequence and ColorSequence codecs with varint length prefix.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Parent.Types)
local Varint = require (script.Parent.Parent.primitive.Varint)

type ChannelState = Types.ChannelState

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local NS_STRIDE = 12
local CS_STRIDE = 7

local round = math.round
local clamp = math.clamp

-- Public -----------------------------------------------------------------

local Sequence = {}

Sequence.numberSequence = table.freeze ({
    write = function (ch: ChannelState, value: NumberSequence): ()
        local keypoints = value.Keypoints
        local count = #keypoints
        Varint.write (ch, count)

        if count == 0 then
            return
        end

        local totalBytes = count * NS_STRIDE
        local c = ch.cursor
        if c + totalBytes > ch.size then
            alloc (ch, totalBytes)
        end

        local b = ch.buff
        for i = 1, count do
            local kp = keypoints[i]
            buffer.writef32 (b, c, kp.Time)
            buffer.writef32 (b, c + 4, kp.Value)
            buffer.writef32 (b, c + 8, kp.Envelope)
            c += NS_STRIDE
        end

        ch.cursor = c
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (NumberSequence, number)
        local count, lenBytes = Varint.read (src, pos)
        local absPos = pos + lenBytes

        if count == 0 then
            return NumberSequence.new (0), lenBytes
        end

        local keypoints = table.create (count)
        for i = 1, count do
            keypoints[i] = NumberSequenceKeypoint.new (
                buffer.readf32 (src, absPos),
                buffer.readf32 (src, absPos + 4),
                buffer.readf32 (src, absPos + 8)
            )
            absPos += NS_STRIDE
        end

        return NumberSequence.new (keypoints), absPos - pos
    end,
})

Sequence.colorSequence = table.freeze ({
    write = function (ch: ChannelState, value: ColorSequence): ()
        local keypoints = value.Keypoints
        local count = #keypoints
        Varint.write (ch, count)

        if count == 0 then
            return
        end

        local totalBytes = count * CS_STRIDE
        local c = ch.cursor
        if c + totalBytes > ch.size then
            alloc (ch, totalBytes)
        end

        local b = ch.buff
        for i = 1, count do
            local kp = keypoints[i]
            local color = kp.Value
            buffer.writef32 (b, c, kp.Time)
            buffer.writeu8 (b, c + 4, round (clamp (color.R, 0, 1) * 255))
            buffer.writeu8 (b, c + 5, round (clamp (color.G, 0, 1) * 255))
            buffer.writeu8 (b, c + 6, round (clamp (color.B, 0, 1) * 255))
            c += CS_STRIDE
        end

        ch.cursor = c
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (ColorSequence, number)
        local count, lenBytes = Varint.read (src, pos)
        local absPos = pos + lenBytes

        if count == 0 then
            return ColorSequence.new (Color3.new ()), lenBytes
        end

        local keypoints = table.create (count)
        for i = 1, count do
            keypoints[i] = ColorSequenceKeypoint.new (
                buffer.readf32 (src, absPos),
                Color3.fromRGB (
                    buffer.readu8 (src, absPos + 4),
                    buffer.readu8 (src, absPos + 5),
                    buffer.readu8 (src, absPos + 6)
                )
            )
            absPos += CS_STRIDE
        end

        return ColorSequence.new (keypoints), absPos - pos
    end,
})

return table.freeze (Sequence)
