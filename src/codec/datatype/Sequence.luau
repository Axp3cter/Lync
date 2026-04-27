--!strict
--!optimize 2
-- NumberSequence (12B/keypoint) and ColorSequence (7B/keypoint) codecs.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Constants --------------------------------------------------------------

local NUMSEQ_KP_BYTES = 12
local COLSEQ_KP_BYTES = 7
local MAX_KEYPOINTS = 20

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local round = math.round
local clamp = math.clamp

local function writeNumberSequence(ch: Types.ChannelState, value: NumberSequence): ()
    local keypoints = value.Keypoints
    local count = #keypoints
    Varint.write(ch, count)
    if count == 0 then
        return
    end

    local bytes = count * NUMSEQ_KP_BYTES
    local cursor = ch.cursor
    if cursor + bytes > ch.size then
        alloc(ch, bytes)
    end
    local b = ch.buff

    local off = cursor
    for i = 1, count do
        local kp = keypoints[i]
        buffer.writef32(b, off, kp.Time)
        buffer.writef32(b, off + 4, kp.Value)
        buffer.writef32(b, off + 8, kp.Envelope)
        off += NUMSEQ_KP_BYTES
    end
    ch.cursor = cursor + bytes
end

local function readNumberSequence(
    src: buffer,
    pos: number,
    _refs: { Instance }?
): (NumberSequence, number)
    local count, lenBytes = Varint.read(src, pos)
    if count == 0 then
        return NumberSequence.new(0), lenBytes
    end
    if count > MAX_KEYPOINTS then
        error(
            `[Lync] NumberSequence.read: keypoint count {count} exceeds Roblox limit {MAX_KEYPOINTS}`
        )
    end

    local bytes = count * NUMSEQ_KP_BYTES
    local dataStart = pos + lenBytes
    if dataStart + bytes > buffer.len(src) then
        error("[Lync] NumberSequence.read: data exceeds buffer")
    end

    local keypoints = table.create(count)
    local off = dataStart
    for i = 1, count do
        keypoints[i] = NumberSequenceKeypoint.new(
            buffer.readf32(src, off),
            buffer.readf32(src, off + 4),
            buffer.readf32(src, off + 8)
        )
        off += NUMSEQ_KP_BYTES
    end
    return NumberSequence.new(keypoints), lenBytes + bytes
end

local function writeColorSequence(ch: Types.ChannelState, value: ColorSequence): ()
    local keypoints = value.Keypoints
    local count = #keypoints
    Varint.write(ch, count)
    if count == 0 then
        return
    end

    local bytes = count * COLSEQ_KP_BYTES
    local cursor = ch.cursor
    if cursor + bytes > ch.size then
        alloc(ch, bytes)
    end
    local b = ch.buff

    local off = cursor
    for i = 1, count do
        local kp = keypoints[i]
        local c = kp.Value
        buffer.writef32(b, off, kp.Time)
        buffer.writeu8(b, off + 4, round(clamp(c.R, 0, 1) * 255))
        buffer.writeu8(b, off + 5, round(clamp(c.G, 0, 1) * 255))
        buffer.writeu8(b, off + 6, round(clamp(c.B, 0, 1) * 255))
        off += COLSEQ_KP_BYTES
    end
    ch.cursor = cursor + bytes
end

local function readColorSequence(
    src: buffer,
    pos: number,
    _refs: { Instance }?
): (ColorSequence, number)
    local count, lenBytes = Varint.read(src, pos)
    if count == 0 then
        return ColorSequence.new(Color3.new()), lenBytes
    end
    if count > MAX_KEYPOINTS then
        error(
            `[Lync] ColorSequence.read: keypoint count {count} exceeds Roblox limit {MAX_KEYPOINTS}`
        )
    end

    local bytes = count * COLSEQ_KP_BYTES
    local dataStart = pos + lenBytes
    if dataStart + bytes > buffer.len(src) then
        error("[Lync] ColorSequence.read: data exceeds buffer")
    end

    local keypoints = table.create(count)
    local off = dataStart
    for i = 1, count do
        keypoints[i] = ColorSequenceKeypoint.new(
            buffer.readf32(src, off),
            Color3.fromRGB(
                buffer.readu8(src, off + 4),
                buffer.readu8(src, off + 5),
                buffer.readu8(src, off + 6)
            )
        )
        off += COLSEQ_KP_BYTES
    end
    return ColorSequence.new(keypoints), lenBytes + bytes
end

-- Public -----------------------------------------------------------------

local Sequence = {}

Sequence.numberSequence = table.freeze({
    _typeCheck = "NumberSequence",
    write = writeNumberSequence,
    read = readNumberSequence,
})

Sequence.colorSequence = table.freeze({
    _typeCheck = "ColorSequence",
    write = writeColorSequence,
    read = readColorSequence,
})

return table.freeze(Sequence)
