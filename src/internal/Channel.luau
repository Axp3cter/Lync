--!strict
--!native
-- Per-channel buffer state with batching, delta cache, frame XOR.

local Types = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants -----------------------------------------------------------

local INITIAL_SIZE = 1024
local MAX_SIZE = 262144
local MAX_BATCH = 255

local min = math.min
local bxor = bit32.bxor
local band32 = bit32.band
local countlz = bit32.countlz
local lshift = bit32.lshift
local bor = bit32.bor
local rshift = bit32.rshift

local TS_NONE = 0
local TS_FRAME = 1
local TS_OFFSET = 2
local TS_FULL = 3

-- State ---------------------------------------------------------------

local _maxSize = MAX_SIZE

-- Packet name for overflow diagnostics. Not coroutine-safe: concurrent
-- serializers may overwrite before the error fires.
local _currentPacket = ""

-- Timestamp state updated once per flush via updateTimestamp().
local _frameCounter: number = 0
local _offsetMs: number = 0
local _clockTime: number = 0
local _anyTimestamp = false

-- Public --------------------------------------------------------------

local Channel = {}

-- Override the maximum buffer size. Call before start(). Range: 4096-1048576.
function Channel.setMaxSize(bytes: number): ()
    if bytes < 4096 or bytes > 1048576 then
        error(`[Lync] Channel max size must be 4096-1048576, got {bytes}`)
    end
    _maxSize = bytes
end

function Channel.getMaxSize(): number
    return _maxSize
end

function Channel.create(): ChannelState
    return {
        buff = buffer.create(INITIAL_SIZE),
        cursor = 0,
        size = INITIAL_SIZE,
        refs = {},
        lastId = -1,
        countPos = 0,
        itemCount = 0,
        deltas = {},
        prevDump = nil,
    }
end

-- Grows the channel buffer to fit the requested bytes. Power-of-two sizing.
function Channel.alloc(ch: ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then
        return
    end
    if needed > _maxSize then
        error(
            `[Lync] Channel overflow writing "{_currentPacket}": {needed} bytes > {_maxSize} max(call Channel.setMaxSize to raise)`
        )
    end

    local newSize = lshift(1, 32 - countlz(needed - 1))

    local newBuff = buffer.create(newSize)
    buffer.copy(newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

local alloc = Channel.alloc

-- Seals the open batch header and returns a snapshot of the buffer + refs.
function Channel.sealAndDump(ch: ChannelState): (buffer, { Instance })
    if ch.lastId >= 0 then
        buffer.writeu8(ch.buff, ch.countPos, ch.itemCount)
        ch.lastId = -1
        ch.countPos = 0
        ch.itemCount = 0
    end

    local cur = ch.cursor
    local out = buffer.create(cur)
    buffer.copy(out, 0, ch.buff, 0, cur)

    local refs = ch.refs
    return out, if #refs > 0 then table.clone(refs) else {}
end

-- Sets the packet name for overflow diagnostics.
function Channel.setCurrentPacket(name: string): ()
    _currentPacket = name
end

-- Called once per flush when any packet uses timestamps.
function Channel.updateTimestamp(frameCounter: number, offsetMs: number, clockTime: number): ()
    _frameCounter = frameCounter
    _offsetMs = offsetMs
    _clockTime = clockTime
end

-- Set once at define time when any packet uses timestamps.
function Channel.enableTimestamps(): ()
    _anyTimestamp = true
end

function Channel.hasTimestamps(): boolean
    return _anyTimestamp
end

-- Opens a batch header with optional timestamp. Returns nothing.
-- Timestamp is per-batch, not per-fire.
local function openBatch(ch: ChannelState, id: number, name: string, tsMode: number): ()
    if ch.lastId >= 0 then
        buffer.writeu8(ch.buff, ch.countPos, ch.itemCount)
    end

    _currentPacket = name
    local tsBytes = if tsMode == TS_FRAME
        then 1
        elseif tsMode == TS_OFFSET then 2
        elseif tsMode == TS_FULL then 8
        else 0
    alloc(ch, 2 + tsBytes)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.countPos = c + 1
    c += 2

    if tsMode == TS_FRAME then
        buffer.writeu8(ch.buff, c, _frameCounter)
        c += 1
    elseif tsMode == TS_OFFSET then
        buffer.writeu16(ch.buff, c, _offsetMs)
        c += 2
    elseif tsMode == TS_FULL then
        buffer.writef64(ch.buff, c, _clockTime)
        c += 8
    end

    ch.cursor = c
    ch.lastId = id
    ch.itemCount = 0
end

-- Writes a single value into the batch. Opens a new header on ID change or overflow.
function Channel.writeBatch(ch: ChannelState, reg: any, data: any): ()
    local id = reg.id
    if id ~= ch.lastId or ch.itemCount >= MAX_BATCH then
        openBatch(ch, id, reg.name, reg.timestampMode)
    end

    ch.itemCount += 1
    local codec = reg.codec
    codec.write(ch, data)
end

-- Appends pre-serialized bytes into a batch. Used by broadcast fan-out.
-- Timestamp is written once per batch header, not per item.
function Channel.writeBatchRaw(
    ch: ChannelState,
    reg: any,
    src: buffer,
    srcLen: number,
    srcRefs: { Instance }?
): ()
    local id = reg.id
    if id ~= ch.lastId or ch.itemCount >= MAX_BATCH then
        openBatch(ch, id, reg.name, reg.timestampMode)
    end

    ch.itemCount += 1

    if srcLen > 0 then
        alloc(ch, srcLen)
        buffer.copy(ch.buff, ch.cursor, src, 0, srcLen)
        ch.cursor += srcLen
    end

    if srcRefs then
        local refs = ch.refs
        table.move(srcRefs, 1, #srcRefs, #refs + 1, refs)
    end
end

local function sealOpen(ch: ChannelState): ()
    if ch.lastId >= 0 then
        buffer.writeu8(ch.buff, ch.countPos, ch.itemCount)
        ch.lastId = -1
        ch.countPos = 0
        ch.itemCount = 0
    end
end

--[[
    Writes a query frame. Seals any open batch, then writes:
        id(u8) + correlationId(varint) + status(u8)
    Status 0 = payload follows. Status 1 = nil response.
]]
function Channel.writeQuery(
    ch: ChannelState,
    id: number,
    name: string,
    correlationId: number,
    codec: any?,
    data: any?
): ()
    _currentPacket = name
    sealOpen(ch)

    alloc(ch, 2)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.cursor = c + 1

    -- Inline varint write to avoid circular dependency (Varint requires Channel)
    local v = correlationId
    if v < 0x80 then
        alloc(ch, 1)
        buffer.writeu8(ch.buff, ch.cursor, v)
        ch.cursor += 1
    else
        alloc(ch, 5)
        local b = ch.buff
        local vc = ch.cursor
        while v >= 0x80 do
            buffer.writeu8(b, vc, bor(band32(v, 0x7F), 0x80))
            v = rshift(v, 7)
            vc += 1
        end
        buffer.writeu8(b, vc, v)
        ch.cursor = vc + 1
    end

    local c2 = ch.cursor
    alloc(ch, 1)
    if codec then
        buffer.writeu8(ch.buff, c2, 0)
        ch.cursor = c2 + 1
        codec.write(ch, data)
    else
        buffer.writeu8(ch.buff, c2, 1)
        ch.cursor = c2 + 1
    end
end

-- XOR current frame against previous. Produces zero-heavy output for deflate.
function Channel.xorApply(current: buffer, previous: buffer?): buffer
    local curLen = buffer.len(current)
    if not previous then
        return current
    end

    local prevLen = buffer.len(previous :: buffer)
    if prevLen == 0 then
        return current
    end

    local result = buffer.create(curLen)
    local overlap = min(curLen, prevLen)
    local prev = previous :: buffer

    local aligned = band32(overlap, 0xFFFFFFFC)
    for i = 0, aligned - 4, 4 do
        buffer.writeu32(result, i, bxor(buffer.readu32(current, i), buffer.readu32(prev, i)))
    end

    for i = aligned, overlap - 1 do
        buffer.writeu8(result, i, bxor(buffer.readu8(current, i), buffer.readu8(prev, i)))
    end

    if curLen > overlap then
        buffer.copy(result, overlap, current, overlap, curLen - overlap)
    end

    return result
end

function Channel.reset(ch: ChannelState): ()
    ch.cursor = 0
    ch.lastId = -1
    ch.countPos = 0
    ch.itemCount = 0
    table.clear(ch.refs)
end

Channel.TS_NONE = TS_NONE
Channel.TS_FRAME = TS_FRAME
Channel.TS_OFFSET = TS_OFFSET
Channel.TS_FULL = TS_FULL

return table.freeze(Channel)
