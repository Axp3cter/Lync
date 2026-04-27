--!strict
--!native
-- Per-channel buffer state with MSB batch framing, XOR delta, timestamps.

local Types = require(script.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.codec.primitive.Varint)

-- Constants --------------------------------------------------------------

local TS_NONE = 0
local TS_FRAME = 1
local TS_OFFSET = 2
local TS_FULL = 3

local DEFAULT_MAX = 262144
local INITIAL_BUF = 1024
local FRAME_MASK = 0xFF
local OFFSET_WIN = 65.536

-- State ------------------------------------------------------------------

local _maxSize = DEFAULT_MAX
local _anyTimestamp = false
local _statsEnabled = false
local _frameCounter = 0
local _offsetMs = 0
local _clock = 0.0

local EMPTY_REFS = table.freeze({}) :: { Instance }

-- Private ----------------------------------------------------------------

local countlz = bit32.countlz
local lshift = bit32.lshift
local band = bit32.band
local bxor = bit32.bxor
local bor = bit32.bor
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32
local writef64 = buffer.writef64
local readu8 = buffer.readu8
local readu32 = buffer.readu32
local round = math.round
local minN = math.min

local function alloc(ch: Types.ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then
        return
    end
    if needed > _maxSize then
        local name = ch.currentPacket
        if name then
            error(`[Lync] Channel.alloc("{name}"): buffer overflow ({needed}B, max {_maxSize}B)`)
        end
        error(`[Lync] Channel.alloc: buffer overflow ({needed}B, max {_maxSize}B)`)
    end
    local newSize = lshift(1, 32 - countlz(needed - 1))
    local newBuff = buffer.create(newSize)
    buffer.copy(newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

local function tsBytes(mode: number): number
    if mode == TS_NONE then
        return 0
    end
    if mode == TS_FRAME then
        return 1
    end
    if mode == TS_OFFSET then
        return 2
    end
    return 8
end

local function writeTimestamp(b: buffer, off: number, mode: number): ()
    if mode == TS_FRAME then
        writeu8(b, off, _frameCounter)
    elseif mode == TS_OFFSET then
        writeu16(b, off, _offsetMs)
    elseif mode == TS_FULL then
        writef64(b, off, _clock)
    end
end

-- Public -----------------------------------------------------------------

local Channel = {}

Channel.TS_NONE = TS_NONE
Channel.TS_FRAME = TS_FRAME
Channel.TS_OFFSET = TS_OFFSET
Channel.TS_FULL = TS_FULL

function Channel.create(): Types.ChannelState
    return {
        buff = buffer.create(INITIAL_BUF),
        cursor = 0,
        size = INITIAL_BUF,
        refs = {},
        refCount = 0,
        lastId = -1,
        countPos = -1,
        itemCount = 0,
        singleMode = false,
        singlePos = 0,
        deltas = {},
        prevDump = nil,
        prevDumpLen = 0,
        currentPacket = nil,
    }
end

function Channel.alloc(ch: Types.ChannelState, bytes: number): ()
    if bytes > 0 then
        alloc(ch, bytes)
    end
end

--[[
    Write a single byte at the cursor and advance. Centralizes the
    ubiquitous `if cursor + 1 > size then alloc(ch, 1) end; writeu8(...);
    cursor += 1` pattern.
]]
function Channel.writeByte(ch: Types.ChannelState, byte: number): ()
    local cursor = ch.cursor
    if cursor + 1 > ch.size then
        alloc(ch, 1)
    end
    writeu8(ch.buff, cursor, byte)
    ch.cursor = cursor + 1
end

--[[
    Push `value` into the channel's sidecar refs array, write its
    1-based index as a u16 to the buffer, advance cursor. Returns the
    index. Used by the Instance and Unknown codecs.
]]
function Channel.pushRef(ch: Types.ChannelState, value: any): number
    local idx = ch.refCount + 1
    if idx > 0xFFFF then
        error("[Lync] Channel.pushRef: ref overflow (>65535)")
    end
    ch.refs[idx] = value
    ch.refCount = idx

    local cursor = ch.cursor
    if cursor + 2 > ch.size then
        alloc(ch, 2)
    end
    writeu16(ch.buff, cursor, idx)
    ch.cursor = cursor + 2
    return idx
end

function Channel.reset(ch: Types.ChannelState): ()
    ch.cursor = 0
    ch.lastId = -1
    ch.countPos = -1
    ch.itemCount = 0
    ch.singleMode = false
    ch.singlePos = 0
    ch.currentPacket = nil
    if ch.refCount > 0 then
        table.clear(ch.refs)
        ch.refCount = 0
    end
end

--[[
    Resolve the batch-open closure for a given timestamp mode and packet
    name. The returned function:
      - seals the previous batch (writing the deferred multi-mode count),
      - writes the single-mode header [0x80 | id] + optional timestamp,
      - records cursor position so writeBatch can upgrade single->multi later.
]]
function Channel.resolveOpenFn(
    timestampMode: number,
    name: string
): (ch: Types.ChannelState, id: number) -> ()
    local headerLen = 1 + tsBytes(timestampMode)

    return function(ch: Types.ChannelState, id: number): ()
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end

        ch.currentPacket = name
        ch.lastId = id
        ch.itemCount = 0

        local cursor = ch.cursor
        if cursor + headerLen > ch.size then
            alloc(ch, headerLen)
        end
        local b = ch.buff
        writeu8(b, cursor, bor(0x80, id))
        writeTimestamp(b, cursor + 1, timestampMode)

        ch.singleMode = true
        ch.singlePos = cursor
        ch.cursor = cursor + headerLen
    end
end

--[[
    Write one item into the current batch. Handles single->multi mode
    upgrade when a second item lands on the same packet ID: clears the
    header byte's MSB, then memmoves payload right by 2 to insert the
    deferred u16 count between the timestamp and first payload.
]]
function Channel.writeBatch(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    if reg.id ~= ch.lastId or ch.itemCount >= 0xFFFF then
        reg._openFn(ch, reg.id)
    elseif ch.singleMode then
        local headerPos = ch.singlePos
        local b = ch.buff
        writeu8(b, headerPos, reg.id)

        local afterTs = headerPos + reg.headerSize
        local cursor = ch.cursor
        local payloadLen = cursor - afterTs
        if cursor + 2 > ch.size then
            alloc(ch, 2)
        end
        local b2 = ch.buff

        if payloadLen > 0 then
            buffer.copy(b2, afterTs + 2, b2, afterTs, payloadLen)
        end

        ch.countPos = afterTs
        writeu16(b2, afterTs, 0)
        ch.cursor = cursor + 2
        ch.singleMode = false
    end

    ch.itemCount += 1
    reg.codec.write(ch, data)
end

function Channel.sealAndDump(ch: Types.ChannelState): (buffer, { Instance }, number, number)
    if ch.lastId >= 0 and not ch.singleMode and ch.countPos >= 0 then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end

    local cursor = ch.cursor
    local snapshot = buffer.create(cursor)
    if cursor > 0 then
        buffer.copy(snapshot, 0, ch.buff, 0, cursor)
    end

    local refCount = ch.refCount
    local refs = if refCount > 0 then table.clone(ch.refs) else EMPTY_REFS
    return snapshot, refs, cursor, refCount
end

--[[
    XOR `current` against `previous`, returning a fresh buffer of curLen
    bytes. When `previous` is nil, returns `current` unchanged.
]]
function Channel.xorApply(
    current: buffer,
    curLen: number,
    previous: buffer?,
    prevLen: number
): buffer
    if not previous then
        return current
    end

    local result = buffer.create(curLen)
    local overlap = minN(curLen, prevLen)
    local prev = previous

    local aligned = band(overlap, -4)
    local i = 0
    while i < aligned do
        writeu32(result, i, bxor(readu32(current, i), readu32(prev, i)))
        i += 4
    end
    while i < overlap do
        writeu8(result, i, bxor(readu8(current, i), readu8(prev, i)))
        i += 1
    end
    if curLen > overlap then
        buffer.copy(result, overlap, current, overlap, curLen - overlap)
    end
    return result
end

--[[
    Write a query frame. MSB on the id byte signals nil response;
    cleared means a payload follows. Correlation IDs are varint-encoded.
]]
function Channel.writeQuery(
    ch: Types.ChannelState,
    id: number,
    correlationId: number,
    codec: Types.InternalCodec<any>?,
    data: any
): ()
    if ch.lastId >= 0 and not ch.singleMode and ch.countPos >= 0 then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    ch.lastId = -1
    ch.singleMode = false

    local hasPayload = codec ~= nil and data ~= nil
    local headerByte = if hasPayload then id else bor(0x80, id)

    local cursor = ch.cursor
    if cursor + 1 > ch.size then
        alloc(ch, 1)
    end
    writeu8(ch.buff, cursor, headerByte)
    ch.cursor = cursor + 1

    Varint.write(ch, correlationId)
    if hasPayload then
        (codec :: Types.InternalCodec<any>).write(ch, data)
    end
end

-- Configuration ----------------------------------------------------------

function Channel.setMaxSize(bytes: number): ()
    _maxSize = bytes
end

function Channel.updateTimestamp(): ()
    _frameCounter = band(_frameCounter + 1, FRAME_MASK)
    _offsetMs = round((os.clock() % OFFSET_WIN) * 1000)
    _clock = os.clock()
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

return table.freeze(Channel)
