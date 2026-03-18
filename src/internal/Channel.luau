--!strict
--!native
-- Per-channel buffer state with batching, delta cache, frame XOR.

local Types = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants -----------------------------------------------------------

local INITIAL_SIZE = 1024
local MAX_SIZE = 262144
local MAX_BATCH = 65535

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
local _currentPacket = ""

-- Timestamp state updated once per flush via updateTimestamp().
local _frameCounter: number = 0
local _offsetMs: number = 0
local _clockTime: number = 0
local _anyTimestamp = false

-- Stats gating. Default off; set via Lync.enableStats().
local _statsEnabled = false

-- Public --------------------------------------------------------------

local Channel = {}

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
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
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

function Channel.setCurrentPacket(name: string): ()
    _currentPacket = name
end

function Channel.updateTimestamp(frameCounter: number, offsetMs: number, clockTime: number): ()
    _frameCounter = frameCounter
    _offsetMs = offsetMs
    _clockTime = clockTime
end

function Channel.enableTimestamps(): ()
    _anyTimestamp = true
end

function Channel.hasTimestamps(): boolean
    return _anyTimestamp
end

function Channel.enableStats(): ()
    _statsEnabled = true
end

function Channel.statsEnabled(): boolean
    return _statsEnabled
end

-- Batch opener: no timestamp variant. Resolved at define time via reg._openFn (#2)
local function openBatchPlain(ch: ChannelState, id: number, name: string): ()
    if ch.lastId >= 0 then
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    _currentPacket = name
    alloc(ch, 3)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.countPos = c + 1
    ch.cursor = c + 3
    ch.lastId = id
    ch.itemCount = 0
end

local function openBatchFrame(ch: ChannelState, id: number, name: string): ()
    if ch.lastId >= 0 then
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    _currentPacket = name
    alloc(ch, 4)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.countPos = c + 1
    buffer.writeu8(ch.buff, c + 3, _frameCounter)
    ch.cursor = c + 4
    ch.lastId = id
    ch.itemCount = 0
end

local function openBatchOffset(ch: ChannelState, id: number, name: string): ()
    if ch.lastId >= 0 then
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    _currentPacket = name
    alloc(ch, 5)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.countPos = c + 1
    buffer.writeu16(ch.buff, c + 3, _offsetMs)
    ch.cursor = c + 5
    ch.lastId = id
    ch.itemCount = 0
end

local function openBatchFull(ch: ChannelState, id: number, name: string): ()
    if ch.lastId >= 0 then
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    _currentPacket = name
    alloc(ch, 11)
    local c = ch.cursor
    buffer.writeu8(ch.buff, c, id)
    ch.countPos = c + 1
    buffer.writef64(ch.buff, c + 3, _clockTime)
    ch.cursor = c + 11
    ch.lastId = id
    ch.itemCount = 0
end

-- Returns the correct openBatch function for a given timestamp mode.
function Channel.resolveOpenFn(tsMode: number): (ch: ChannelState, id: number, name: string) -> ()
    if tsMode == TS_FRAME then
        return openBatchFrame
    elseif tsMode == TS_OFFSET then
        return openBatchOffset
    elseif tsMode == TS_FULL then
        return openBatchFull
    end
    return openBatchPlain
end

-- Writes a single value into the batch. Zero branching on the hot path.
function Channel.writeBatch(ch: ChannelState, reg: any, data: any): ()
    local id = reg.id
    if id ~= ch.lastId or ch.itemCount >= MAX_BATCH then
        reg._openFn(ch, id, reg.name)
    end

    ch.itemCount += 1
    reg.codec.write(ch, data)
end

-- Appends pre-serialized bytes into a batch. Used by broadcast fan-out.
function Channel.writeBatchRaw(
    ch: ChannelState,
    reg: any,
    src: buffer,
    srcLen: number,
    srcRefs: { Instance }?
): ()
    local id = reg.id
    if id ~= ch.lastId or ch.itemCount >= MAX_BATCH then
        reg._openFn(ch, id, reg.name)
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
        buffer.writeu16(ch.buff, ch.countPos, ch.itemCount)
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

-- Conditional refs clear (#6)
function Channel.reset(ch: ChannelState): ()
    ch.cursor = 0
    ch.lastId = -1
    ch.countPos = 0
    ch.itemCount = 0
    if #ch.refs > 0 then
        table.clear(ch.refs)
    end
end

Channel.TS_NONE = TS_NONE
Channel.TS_FRAME = TS_FRAME
Channel.TS_OFFSET = TS_OFFSET
Channel.TS_FULL = TS_FULL

return table.freeze(Channel)
