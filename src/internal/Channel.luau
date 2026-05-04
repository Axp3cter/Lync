--!strict
--!native
-- Per-channel buffer state with MSB batch framing, XOR delta, timestamps.

local Base = require(script.Parent.Parent.codec.Base)
local Buf = require(script.Parent.Parent.util.Buffer)
local Constants = require(script.Parent.Parent.util.Constants)
local Log = require(script.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.codec.primitive.Varint)

-- Constants --------------------------------------------------------------

local TS_NONE = 0
local TS_FRAME = 1
local TS_OFFSET = 2
local TS_FULL = 3

local INITIAL_BUF = 1024
local HEADER_BYTE = 1
local U8_MAX = Constants.U8_MAX
local U16_MAX = Constants.U16_MAX
local MAX_BATCH_ITEMS = Constants.MAX_BATCH_ITEMS

-- 65.535s window so round((clock % win) * 1000) cannot overflow u16.
local OFFSET_WIN = 65.535

local TS_BYTES = table.freeze({
    [TS_NONE] = 0,
    [TS_FRAME] = 1,
    [TS_OFFSET] = 2,
    [TS_FULL] = 8,
})

-- State ------------------------------------------------------------------

local _timestampsEnabled = false
local _statsEnabled = false

-- Refreshed by updateTimestamp once per flush.
local _frameCounter = 0
local _offsetMs = 0
local _clock = 0.0

local EMPTY_REFS = table.freeze({}) :: { Instance }

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local ensure = Base.ensure
local band = bit32.band
local bufCopy = buffer.copy
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writef64 = buffer.writef64
local round = math.round
local osClock = os.clock

-- id is in [1, 127] (Registry.MAX_ID), so id + 128 == bor(FRAME_MSB, id).

--[[
    Single -> multi upgrade. Patches the previously-emitted single-item
    header, splices a 2-byte count cell after the timestamp, and shifts the
    payload right. Hot only when a packet fires twice in a row to the same
    channel without an intervening flush.
]]
local function upgradeSingleToMulti(ch: Types.ChannelState, regId: number, headerSize: number): ()
    local headerPos = ch.singlePos
    writeu8(ch.buff, headerPos, regId)

    local afterTs = headerPos + headerSize
    local cursor = ch.cursor
    local payloadLen = cursor - afterTs
    ensure(ch, 2)
    -- Re-bind: ensure() may have realloced the buffer.
    local b = ch.buff
    bufCopy(b, afterTs + 2, b, afterTs, payloadLen)

    ch.countPos = afterTs
    writeu16(b, afterTs, 0)
    ch.cursor = cursor + 2
    ch.singleMode = false
end

-- itemCount bump is left to the caller, AFTER the body write succeeds.
local function openOrUpgrade(ch: Types.ChannelState, reg: Types.Registration): ()
    if reg.id ~= ch.lastId or ch.itemCount >= MAX_BATCH_ITEMS then
        reg._openFn(ch, reg.id)
    elseif ch.singleMode then
        upgradeSingleToMulti(ch, reg.id, reg.headerSize)
    end
end

local function spliceEncoded(ch: Types.ChannelState, payload: buffer, payloadLen: number): ()
    local cursor = ch.cursor
    if cursor + payloadLen > ch.size then
        alloc(ch, payloadLen)
    end
    bufCopy(ch.buff, cursor, payload, 0, payloadLen)
    ch.cursor = cursor + payloadLen
end

--[[
    Hot-swapped by enableStats(). A throwing codec must rewind cursor + refs:
    the next flush sends `[0, ch.cursor)`, so a partial write past `cursor`
    desyncs the receiver from the truncation point onward.
]]
local writeBatchPlain: (Types.ChannelState, Types.Registration, any) -> ()
local writeBatchStats: (Types.ChannelState, Types.Registration, any) -> ()

local function rewindOnThrow(ch: Types.ChannelState, cursor: number, refCount: number): ()
    ch.cursor = cursor
    if ch.refCount > refCount then
        local refs = ch.refs
        for i = refCount + 1, ch.refCount do
            refs[i] = nil
        end
        ch.refCount = refCount
    end
end

writeBatchPlain = function(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    openOrUpgrade(ch, reg)
    local rewindCursor = ch.cursor
    local rewindRefCount = ch.refCount
    local ok, err = pcall(reg.codec.write, ch, data)
    if not ok then
        rewindOnThrow(ch, rewindCursor, rewindRefCount)
        error(err, 0)
    end
    ch.itemCount += 1
end

writeBatchStats = function(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    openOrUpgrade(ch, reg)
    local rewindCursor = ch.cursor
    local rewindRefCount = ch.refCount
    local ok, err = pcall(reg.codec.write, ch, data)
    if not ok then
        rewindOnThrow(ch, rewindCursor, rewindRefCount)
        error(err, 0)
    end
    ch.itemCount += 1
    reg.bytesSent += ch.cursor - rewindCursor
end

--[[
    Splice a pre-encoded payload into the channel. Used by Packet.broadcast
    to encode the codec output once per fanout instead of N times.
]]
local writeBatchEncodedPlain: (Types.ChannelState, Types.Registration, buffer, number) -> ()
local writeBatchEncodedStats: (Types.ChannelState, Types.Registration, buffer, number) -> ()

writeBatchEncodedPlain = function(
    ch: Types.ChannelState,
    reg: Types.Registration,
    payload: buffer,
    payloadLen: number
): ()
    openOrUpgrade(ch, reg)
    local rewindCursor = ch.cursor
    local ok, err = pcall(spliceEncoded, ch, payload, payloadLen)
    if not ok then
        ch.cursor = rewindCursor
        error(err, 0)
    end
    ch.itemCount += 1
end

writeBatchEncodedStats = function(
    ch: Types.ChannelState,
    reg: Types.Registration,
    payload: buffer,
    payloadLen: number
): ()
    openOrUpgrade(ch, reg)
    local rewindCursor = ch.cursor
    local ok, err = pcall(spliceEncoded, ch, payload, payloadLen)
    if not ok then
        ch.cursor = rewindCursor
        error(err, 0)
    end
    ch.itemCount += 1
    reg.bytesSent += payloadLen
end

-- Public -----------------------------------------------------------------

-- Module table is intentionally unfrozen: enableStats() hot-swaps writeBatch.
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

function Channel.writeByte(ch: Types.ChannelState, byte: number): ()
    local cursor = ch.cursor
    if cursor + HEADER_BYTE > ch.size then
        alloc(ch, HEADER_BYTE)
    end
    writeu8(ch.buff, cursor, byte)
    ch.cursor = cursor + HEADER_BYTE
end

-- Append `value` to the sidecar refs, write its 1-based u16 index.
function Channel.pushRef(ch: Types.ChannelState, value: any): ()
    local idx = ch.refCount + 1
    Log.assert(idx <= U16_MAX, "ref overflow, max 65535")
    ch.refs[idx] = value
    ch.refCount = idx

    local cursor = ch.cursor
    if cursor + 2 > ch.size then
        alloc(ch, 2)
    end
    writeu16(ch.buff, cursor, idx)
    ch.cursor = cursor + 2
end

--[[
    Per-flush reset. Preserves prevDump/prevDumpLen (XOR baseline) and
    ch.deltas (delta caches): both must outlive flushes for the same owner.
]]
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
    Full reset including XOR baseline and delta caches. Pool.acquire calls
    this so a recycled state cannot leak the previous owner's baseline.
]]
function Channel.fullReset(ch: Types.ChannelState): ()
    Channel.reset(ch)
    ch.prevDump = nil
    ch.prevDumpLen = 0
    if next(ch.deltas) ~= nil then
        table.clear(ch.deltas)
    end
end

--[[
    Per-mode openFn variants. Each seals the prior batch, writes the
    single-mode header [0x80 | id] + optional timestamp, and records the
    cursor so writeBatch can upgrade single -> multi later.
]]
local function makeOpenNoTs(name: string): (Types.ChannelState, number) -> ()
    return function(ch: Types.ChannelState, id: number): ()
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end
        ch.currentPacket = name
        ch.lastId = id
        ch.itemCount = 0
        local cursor = ch.cursor
        if cursor + 1 > ch.size then
            alloc(ch, 1)
        end
        writeu8(ch.buff, cursor, id + 128)
        ch.singleMode = true
        ch.singlePos = cursor
        ch.cursor = cursor + 1
    end
end

local function makeOpenFrameTs(name: string): (Types.ChannelState, number) -> ()
    return function(ch: Types.ChannelState, id: number): ()
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end
        ch.currentPacket = name
        ch.lastId = id
        ch.itemCount = 0
        local cursor = ch.cursor
        if cursor + 2 > ch.size then
            alloc(ch, 2)
        end
        local b = ch.buff
        writeu8(b, cursor, id + 128)
        writeu8(b, cursor + 1, _frameCounter)
        ch.singleMode = true
        ch.singlePos = cursor
        ch.cursor = cursor + 2
    end
end

local function makeOpenOffsetTs(name: string): (Types.ChannelState, number) -> ()
    return function(ch: Types.ChannelState, id: number): ()
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end
        ch.currentPacket = name
        ch.lastId = id
        ch.itemCount = 0
        local cursor = ch.cursor
        if cursor + 3 > ch.size then
            alloc(ch, 3)
        end
        local b = ch.buff
        writeu8(b, cursor, id + 128)
        writeu16(b, cursor + 1, _offsetMs)
        ch.singleMode = true
        ch.singlePos = cursor
        ch.cursor = cursor + 3
    end
end

local function makeOpenFullTs(name: string): (Types.ChannelState, number) -> ()
    return function(ch: Types.ChannelState, id: number): ()
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end
        ch.currentPacket = name
        ch.lastId = id
        ch.itemCount = 0
        local cursor = ch.cursor
        if cursor + 9 > ch.size then
            alloc(ch, 9)
        end
        local b = ch.buff
        writeu8(b, cursor, id + 128)
        writef64(b, cursor + 1, _clock)
        ch.singleMode = true
        ch.singlePos = cursor
        ch.cursor = cursor + 9
    end
end

function Channel.resolveOpenFn(
    timestampMode: number,
    name: string
): (ch: Types.ChannelState, id: number) -> ()
    if timestampMode == TS_NONE then
        return makeOpenNoTs(name)
    end
    if timestampMode == TS_FRAME then
        return makeOpenFrameTs(name)
    end
    if timestampMode == TS_OFFSET then
        return makeOpenOffsetTs(name)
    end
    return makeOpenFullTs(name)
end

Channel.writeBatch = writeBatchPlain
Channel.writeBatchEncoded = writeBatchEncodedPlain

--[[
    Every caller (Server.flushReliable / flushUnreliable, Client.flush)
    pre-checks `ch.cursor > 0`, so cursor here is always positive.
]]
function Channel.sealAndDump(ch: Types.ChannelState): (buffer, { Instance }, number, number)
    if ch.lastId >= 0 and not ch.singleMode then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end

    local cursor = ch.cursor
    local snapshot = buffer.create(cursor)
    bufCopy(snapshot, 0, ch.buff, 0, cursor)

    local refCount = ch.refCount
    local refs = if refCount > 0 then table.clone(ch.refs) else EMPTY_REFS
    return snapshot, refs, cursor, refCount
end

Channel.xorApply = Buf.xorApply

--[[
    Query frame. MSB on the id byte = nil response; cleared = payload follows.
    Correlation IDs are varint-encoded.
]]
function Channel.writeQuery(
    ch: Types.ChannelState,
    id: number,
    correlationId: number,
    codec: Types.InternalCodec<any>?,
    data: any,
    name: string?
): ()
    if ch.lastId >= 0 and not ch.singleMode then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    --[[
        lastId = -1 forces the next writeBatch to call _openFn (which resets
        singleMode). Every other reader of singleMode (writeQuery,
        sealAndDump) is gated by `lastId >= 0` first, so stamping singleMode
        here would never be observed before the next reset overwrites it.
    ]]
    ch.lastId = -1
    -- Without this, an alloc overflow inside the payload codec would log
    -- the previous packet's name (whichever _openFn last touched currentPacket).
    if name then
        ch.currentPacket = name
    end

    local hasPayload = codec ~= nil and data ~= nil
    local headerByte = if hasPayload then id else id + 128

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
    Base.setMaxSize(bytes)
end

function Channel.updateTimestamp(): ()
    _frameCounter = band(_frameCounter + 1, U8_MAX)
    local now = osClock()
    _offsetMs = round((now % OFFSET_WIN) * 1000)
    _clock = now
end

function Channel.enableTimestamps(): ()
    _timestampsEnabled = true
end

function Channel.hasTimestamps(): boolean
    return _timestampsEnabled
end

function Channel.enableStats(): ()
    _statsEnabled = true
    Channel.writeBatch = writeBatchStats
    Channel.writeBatchEncoded = writeBatchEncodedStats
end

function Channel.statsEnabled(): boolean
    return _statsEnabled
end

-- Module-level config + timestamp counters. Distinct from Channel.reset(ch).
function Channel.resetGlobals(): ()
    Base.reset()
    _timestampsEnabled = false
    _statsEnabled = false
    _frameCounter = 0
    _offsetMs = 0
    _clock = 0.0
    Channel.writeBatch = writeBatchPlain
    Channel.writeBatchEncoded = writeBatchEncodedPlain
end

return Channel
