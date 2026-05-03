--!strict
--!native
-- NumberSequence (12B/keypoint) and ColorSequence (7B/keypoint) codecs.

local Base = require(script.Parent.Parent.Base)
local Constants = require(script.Parent.Parent.Parent.util.Constants)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Constants --------------------------------------------------------------

local NUMSEQ_KP_BYTES = 12
local COLSEQ_KP_BYTES = 7
local MAX_KEYPOINTS = 20

-- Private ----------------------------------------------------------------

local U8_MAX = Constants.U8_MAX
local alloc = Base.alloc
local writef32 = buffer.writef32
local readf32 = buffer.readf32
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local round = math.round
local clamp = math.clamp
local varintRead = Varint.read
local varintWrite = Varint.write

--[[
    Common write prelude: count cap check, varint count, payload alloc.
    Returns (cursor, b) for the per-keypoint writer; (nil, nil) when count
    is 0 so callers short-circuit.
]]
local function beginSeqWrite(
    ch: Types.ChannelState,
    label: string,
    count: number,
    kpBytes: number
): (number?, buffer?)
    if count > MAX_KEYPOINTS then
        Log.error(`{label}.write: keypoint count {count} exceeds Roblox limit {MAX_KEYPOINTS}`)
    end
    varintWrite(ch, count)
    if count == 0 then
        return nil, nil
    end

    local bytes = count * kpBytes
    local cursor = ch.cursor
    if cursor + bytes > ch.size then
        alloc(ch, bytes)
    end
    ch.cursor = cursor + bytes
    return cursor, ch.buff
end

--[[
    Common read prelude: varint count, cap check, bounds check. Returns
    (count, dataStart, lenBytes) for the per-keypoint reader; (0, _, lenBytes)
    when payload is empty.
]]
local function beginSeqRead(
    src: buffer,
    pos: number,
    label: string,
    kpBytes: number
): (number, number, number)
    local count, lenBytes = varintRead(src, pos)
    if count == 0 then
        return 0, pos + lenBytes, lenBytes
    end
    if count > MAX_KEYPOINTS then
        Log.error(`{label}.read: keypoint count {count} exceeds Roblox limit {MAX_KEYPOINTS}`)
    end

    local bytes = count * kpBytes
    local dataStart = pos + lenBytes
    if dataStart + bytes > buffer.len(src) then
        Log.error(`{label}.read: payload {bytes}B exceeds remaining buffer`)
    end
    return count, dataStart, lenBytes
end

local function writeNumberSequence(ch: Types.ChannelState, value: NumberSequence): ()
    local keypoints = value.Keypoints
    local count = #keypoints
    local cursor, b = beginSeqWrite(ch, "NumberSequence", count, NUMSEQ_KP_BYTES)
    if not cursor then
        return
    end
    local off = cursor :: number
    local buf = b :: buffer
    for i = 1, count do
        local kp = keypoints[i]
        writef32(buf, off, kp.Time)
        writef32(buf, off + 4, kp.Value)
        writef32(buf, off + 8, kp.Envelope)
        off += NUMSEQ_KP_BYTES
    end
end

local function readNumberSequence(
    src: buffer,
    pos: number,
    _refs: { Instance }?
): (NumberSequence, number)
    local count, dataStart, lenBytes = beginSeqRead(src, pos, "NumberSequence", NUMSEQ_KP_BYTES)
    if count == 0 then
        return NumberSequence.new(0), lenBytes
    end

    local keypoints = table.create(count)
    local off = dataStart
    for i = 1, count do
        keypoints[i] = NumberSequenceKeypoint.new(
            readf32(src, off),
            readf32(src, off + 4),
            readf32(src, off + 8)
        )
        off += NUMSEQ_KP_BYTES
    end
    return NumberSequence.new(keypoints), lenBytes + count * NUMSEQ_KP_BYTES
end

local function writeColorSequence(ch: Types.ChannelState, value: ColorSequence): ()
    local keypoints = value.Keypoints
    local count = #keypoints
    local cursor, b = beginSeqWrite(ch, "ColorSequence", count, COLSEQ_KP_BYTES)
    if not cursor then
        return
    end
    local off = cursor :: number
    local buf = b :: buffer
    for i = 1, count do
        local kp = keypoints[i]
        local c = kp.Value
        writef32(buf, off, kp.Time)
        writeu8(buf, off + 4, round(clamp(c.R, 0, 1) * U8_MAX))
        writeu8(buf, off + 5, round(clamp(c.G, 0, 1) * U8_MAX))
        writeu8(buf, off + 6, round(clamp(c.B, 0, 1) * U8_MAX))
        off += COLSEQ_KP_BYTES
    end
end

local function readColorSequence(
    src: buffer,
    pos: number,
    _refs: { Instance }?
): (ColorSequence, number)
    local count, dataStart, lenBytes = beginSeqRead(src, pos, "ColorSequence", COLSEQ_KP_BYTES)
    if count == 0 then
        return ColorSequence.new(Color3.new()), lenBytes
    end

    local keypoints = table.create(count)
    local off = dataStart
    for i = 1, count do
        keypoints[i] = ColorSequenceKeypoint.new(
            readf32(src, off),
            Color3.fromRGB(readu8(src, off + 4), readu8(src, off + 5), readu8(src, off + 6))
        )
        off += COLSEQ_KP_BYTES
    end
    return ColorSequence.new(keypoints), lenBytes + count * COLSEQ_KP_BYTES
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
