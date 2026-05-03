--!strict
--!native
-- Per-channel buffer state with MSB batch framing, XOR delta, timestamps.

local Base      = require(script.Parent.Parent.codec.Base)
local Buf       = require(script.Parent.Parent.util.Buffer)
local Constants = require(script.Parent.Parent.util.Constants)
local Log       = require(script.Parent.Parent.util.Log)
local Types     = require(script.Parent.Parent.Types)
local Varint    = require(script.Parent.Parent.codec.primitive.Varint)

-- Constants --------------------------------------------------------------

local TS_NONE   = 0
local TS_FRAME  = 1
local TS_OFFSET = 2
local TS_FULL   = 3

local INITIAL_BUF     = 1024
local HEADER_BYTE     = 1
local FRAME_MSB       = Constants.FRAME_MSB
local U8_MAX          = Constants.U8_MAX
local U16_MAX         = Constants.U16_MAX
local MAX_BATCH_ITEMS = Constants.MAX_BATCH_ITEMS

-- 65.535s window so round((clock % win) * 1000) cannot overflow u16.
local OFFSET_WIN = 65.535

local TS_BYTES = table.freeze({
    [TS_NONE]   = 0,
    [TS_FRAME]  = 1,
    [TS_OFFSET] = 2,
    [TS_FULL]   = 8,
})

-- State ------------------------------------------------------------------

local _timestampsEnabled = false
local _statsEnabled      = false

-- Refreshed by updateTimestamp once per flush.
local _frameCounter = 0
local _offsetMs     = 0
local _clock        = 0.0

local EMPTY_REFS = table.freeze({}) :: { Instance }

-- Private ----------------------------------------------------------------

local alloc    = Base.alloc
local band     = bit32.band
local bor      = bit32.bor
local bufCopy  = buffer.copy
local writeu8  = buffer.writeu8
local writeu16 = buffer.writeu16
local writef64 = buffer.writef64
local round    = math.round
local osClock  = os.clock

local function ensure(ch: Types.ChannelState, n: number): ()
    if ch.cursor + n > ch.size then
        alloc(ch, n)
    end
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

--[[
    Single -> multi upgrade. Patches the previously-emitted single-item
    header, splices a 2-byte count cell after the timestamp, and shifts the
    payload right. Hot only when a packet fires twice in a row to the same
    channel without an intervening flush.
]]
local function upgradeSingleToMulti(ch: Types.ChannelState, regId: number, headerSize: number): ()
    local headerPos = ch.singlePos
    writeu8(ch.buff, headerPos, regId)

    local afterTs    = headerPos + headerSize
    local cursor     = ch.cursor
    local payloadLen = cursor - afterTs
    ensure(ch, 2)
    -- Re-bind: ensure() may have realloced the buffer.
    local b = ch.buff

    if payloadLen > 0 then
        bufCopy(b, afterTs + 2, b, afterTs, payloadLen)
    end

    ch.countPos = afterTs
    writeu16(b, afterTs, 0)
    ch.cursor     = cursor + 2
    ch.singleMode = false
end

--[[
    Two writeBatch implementations, swapped at startup by enableStats(). For
    high-rate channels this saves ~1 register read + 1 compare + 1 jump per
    item versus branching on `_statsEnabled` inside the loop.
]]
local writeBatchPlain: (Types.ChannelState, Types.Registration, any) -> ()
local writeBatchStats: (Types.ChannelState, Types.Registration, any) -> ()

writeBatchPlain = function(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    if reg.id ~= ch.lastId or ch.itemCount >= MAX_BATCH_ITEMS then
        reg._openFn(ch, reg.id)
    elseif ch.singleMode then
        upgradeSingleToMulti(ch, reg.id, reg.headerSize)
    end
    ch.itemCount += 1
    reg.codec.write(ch, data)
end

writeBatchStats = function(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    if reg.id ~= ch.lastId or ch.itemCount >= MAX_BATCH_ITEMS then
        reg._openFn(ch, reg.id)
    elseif ch.singleMode then
        upgradeSingleToMulti(ch, reg.id, reg.headerSize)
    end
    ch.itemCount += 1
    local before = ch.cursor
    reg.codec.write(ch, data)
    reg.bytesSent += ch.cursor - before
end

-- Public -----------------------------------------------------------------

-- Module table is intentionally unfrozen: enableStats() hot-swaps writeBatch.
local Channel = {}

Channel.TS_NONE   = TS_NONE
Channel.TS_FRAME  = TS_FRAME
Channel.TS_OFFSET = TS_OFFSET
Channel.TS_FULL   = TS_FULL

function Channel.create(): Types.ChannelState
    return {
        buff          = buffer.create(INITIAL_BUF),
        cursor        = 0,
        size          = INITIAL_BUF,
        refs          = {},
        refCount      = 0,
        lastId        = -1,
        countPos      = -1,
        itemCount     = 0,
        singleMode    = false,
        singlePos     = 0,
        deltas        = {},
        prevDump      = nil,
        prevDumpLen   = 0,
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
    ch.refCount  = idx

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
    ch.cursor        = 0
    ch.lastId        = -1
    ch.countPos      = -1
    ch.itemCount     = 0
    ch.singleMode    = false
    ch.singlePos     = 0
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
    ch.prevDump    = nil
    ch.prevDumpLen = 0
    table.clear(ch.deltas)
end

--[[
    Resolve the batch-open closure for a given timestamp mode and packet
    name. Returned function seals the prior batch, writes the single-mode
    header [0x80 | id] + optional timestamp, and records the cursor so
    writeBatch can upgrade single -> multi later.
]]
function Channel.resolveOpenFn(
    timestampMode: number,
    name: string
): (ch: Types.ChannelState, id: number) -> ()
    local headerLen = HEADER_BYTE + TS_BYTES[timestampMode]

    return function(ch: Types.ChannelState, id: number): ()
        --[[
            Inline sealCount: this is the only call site that can take the
            multi-mode branch on a non-fresh channel.
        ]]
        if ch.lastId >= 0 and not ch.singleMode then
            writeu16(ch.buff, ch.countPos, ch.itemCount)
        end

        ch.currentPacket = name
        ch.lastId        = id
        ch.itemCount     = 0

        local cursor = ch.cursor
        if cursor + headerLen > ch.size then
            alloc(ch, headerLen)
        end
        local b = ch.buff
        writeu8(b, cursor, bor(FRAME_MSB, id))
        writeTimestamp(b, cursor + 1, timestampMode)

        ch.singleMode = true
        ch.singlePos  = cursor
        ch.cursor     = cursor + headerLen
    end
end

Channel.writeBatch = writeBatchPlain

--[[
    Every caller (Server.flushReliable / flushUnreliable, Client.flush)
    pre-checks `ch.cursor > 0`, so cursor here is always positive.
]]
function Channel.sealAndDump(ch: Types.ChannelState): (buffer, { Instance }, number, number)
    if ch.lastId >= 0 and not ch.singleMode then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end

    local cursor   = ch.cursor
    local snapshot = buffer.create(cursor)
    bufCopy(snapshot, 0, ch.buff, 0, cursor)

    local refCount = ch.refCount
    local refs     = if refCount > 0 then table.clone(ch.refs) else EMPTY_REFS
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
    data: any
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

    local hasPayload = codec ~= nil and data ~= nil
    local headerByte = if hasPayload then id else bor(FRAME_MSB, id)

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
    local now     = osClock()
    _offsetMs     = round((now % OFFSET_WIN) * 1000)
    _clock        = now
end

function Channel.enableTimestamps(): ()
    _timestampsEnabled = true
end

function Channel.hasTimestamps(): boolean
    return _timestampsEnabled
end

function Channel.enableStats(): ()
    _statsEnabled      = true
    Channel.writeBatch = writeBatchStats
end

function Channel.statsEnabled(): boolean
    return _statsEnabled
end

-- Module-level config + timestamp counters. Distinct from Channel.reset(ch).
function Channel.resetGlobals(): ()
    Base.reset()
    _timestampsEnabled = false
    _statsEnabled      = false
    _frameCounter      = 0
    _offsetMs          = 0
    _clock             = 0.0
    Channel.writeBatch = writeBatchPlain
end

return Channel
