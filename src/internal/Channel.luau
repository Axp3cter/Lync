--!strict
--!native
-- Per-channel buffer state with MSB batch framing, XOR, timestamps.

local Types = require(script.Parent.Parent.Types)

-- Constants -----------------------------------------------------------

local TS_NONE = 0
local TS_FRAME = 1
local TS_OFFSET = 2
local TS_FULL = 3

local DEFAULT_MAX = 262144
local EMPTY_REFS = table.freeze({})

-- State ---------------------------------------------------------------

local _maxSize = DEFAULT_MAX
local _anyTimestamp = false
local _statsEnabled = false
local _frameCounter = 0
local _offsetMs = 0
local _clock = 0.0

-- Private -------------------------------------------------------------

local countlz = bit32.countlz
local lshift = bit32.lshift
local bxor = bit32.bxor
local bor = bit32.bor
local band = bit32.band
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writef64 = buffer.writef64
local readu8 = buffer.readu8
local readu32 = buffer.readu32
local round = math.round
local min = math.min

local function alloc(ch: Types.ChannelState, bytes: number): ()
    local needed = ch.cursor + bytes
    if needed <= ch.size then
        return
    end
    if needed > _maxSize then
        error(
            if ch.currentPacket
                then `[Lync] Channel: buffer overflow ({needed}B, max {_maxSize}B) in "{ch.currentPacket}"`
                else `[Lync] Channel: buffer overflow ({needed}B, max {_maxSize}B)`
        )
    end
    local newSize = lshift(1, 32 - countlz(needed - 1))
    local newBuff = buffer.create(newSize)
    buffer.copy(newBuff, 0, ch.buff, 0, ch.cursor)
    ch.buff = newBuff
    ch.size = newSize
end

-- Public --------------------------------------------------------------

local Channel = {}

Channel.TS_NONE = TS_NONE
Channel.TS_FRAME = TS_FRAME
Channel.TS_OFFSET = TS_OFFSET
Channel.TS_FULL = TS_FULL

function Channel.create(): Types.ChannelState
    return {
        buff = buffer.create(1024),
        cursor = 0,
        size = 1024,
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
    alloc(ch, bytes)
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
    Resolves the batch-open function for a given timestamp mode.
    The returned function handles MSB single-item framing:
      First item: writes [0x80 | id] (single mode, no count).
      Second item: upgrades to multi mode with u16 count.
]]
function Channel.resolveOpenFn(
    timestampMode: number,
    name: string
): (ch: Types.ChannelState, id: number) -> ()
    if timestampMode == TS_NONE then
        return function(ch: Types.ChannelState, id: number): ()
            -- Seal previous batch
            if ch.lastId >= 0 and not ch.singleMode then
                writeu16(ch.buff, ch.countPos, ch.itemCount)
            end
            ch.currentPacket = name
            ch.lastId = id
            ch.itemCount = 0

            -- Write single-mode header: [1IIIIIII]
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, cursor, bor(0x80, id))
            ch.singleMode = true
            ch.singlePos = cursor
            ch.cursor = cursor + 1
        end
    elseif timestampMode == TS_FRAME then
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
            writeu8(b, cursor, bor(0x80, id))
            writeu8(b, cursor + 1, _frameCounter)
            ch.singleMode = true
            ch.singlePos = cursor
            ch.cursor = cursor + 2
        end
    elseif timestampMode == TS_OFFSET then
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
            writeu8(b, cursor, bor(0x80, id))
            writeu16(b, cursor + 1, _offsetMs)
            ch.singleMode = true
            ch.singlePos = cursor
            ch.cursor = cursor + 3
        end
    else -- TS_FULL
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
            writeu8(b, cursor, bor(0x80, id))
            writef64(b, cursor + 1, _clock)
            ch.singleMode = true
            ch.singlePos = cursor
            ch.cursor = cursor + 9
        end
    end
end

--[[
    Writes one item into a batch. Handles MSB single→multi upgrade.
]]
function Channel.writeBatch(ch: Types.ChannelState, reg: Types.Registration, data: any): ()
    if reg.id ~= ch.lastId or ch.itemCount >= 0xFFFF then
        reg._openFn(ch, reg.id)
    elseif ch.singleMode then
        --[[
            Second item for same packet: upgrade to multi mode.
            Rewrite header byte to clear MSB, insert u16 count after.
        ]]
        local b = ch.buff
        local headerPos = ch.singlePos
        writeu8(b, headerPos, reg.id) -- MSB cleared = multi-item mode

        local tsBytes = reg.headerSize - 1
        local afterTs = headerPos + 1 + tsBytes

        --[[
            Upgrading from single→multi requires inserting 2 bytes (u16 count)
            between the timestamp and the first item's payload, shifting
            existing data right by 2.
        ]]
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
        writeu16(b2, afterTs, 0) -- placeholder u16; sealAndDump writes final count
        ch.cursor = cursor + 2
        ch.singleMode = false
    end

    ch.itemCount += 1
    reg.codec.write(ch, data)
end

--[[
    Seals the current batch and returns a snapshot for transmission.
]]
function Channel.sealAndDump(ch: Types.ChannelState): (buffer, { Instance }, number, number)
    -- Multi-item batches need their count finalized before transmission
    if ch.lastId >= 0 and not ch.singleMode and ch.countPos >= 0 then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end

    local cursor = ch.cursor
    local snapshot = buffer.create(cursor)
    buffer.copy(snapshot, 0, ch.buff, 0, cursor)

    local refs: { Instance }
    local refCount = ch.refCount
    if refCount > 0 then
        refs = table.clone(ch.refs)
    else
        refs = EMPTY_REFS :: any
    end

    return snapshot, refs, cursor, refCount
end

--[[
    XOR current frame against previous for deflate-friendly output.
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
    local overlap = min(curLen, prevLen)
    local prev = previous :: buffer

    -- u32 chunks
    local aligned = overlap - (overlap % 4)
    local i = 0
    while i < aligned do
        buffer.writeu32(result, i, bxor(readu32(current, i), readu32(prev, i)))
        i += 4
    end

    -- u8 remainder of overlap
    while i < overlap do
        writeu8(result, i, bxor(readu8(current, i), readu8(prev, i)))
        i += 1
    end

    -- Excess bytes (current longer than previous)
    if curLen > overlap then
        buffer.copy(result, overlap, current, overlap, curLen - overlap)
    end

    return result
end

--[[
    Writes a query frame with MSB encoding for nil-status.
    MSB set = nil response, MSB clear = payload follows.
]]
function Channel.writeQuery(
    ch: Types.ChannelState,
    id: number,
    correlationId: number,
    codec: Types.InternalCodec<any>?,
    data: any
): ()
    -- Queries are standalone frames, so close any open packet batch first
    if ch.lastId >= 0 and not ch.singleMode and ch.countPos >= 0 then
        writeu16(ch.buff, ch.countPos, ch.itemCount)
    end
    ch.lastId = -1
    ch.singleMode = false

    if codec and data ~= nil then
        local cursor = ch.cursor
        if cursor + 1 > ch.size then
            alloc(ch, 1)
        end
        writeu8(ch.buff, cursor, id)
        ch.cursor = cursor + 1

        -- Inlined varint avoids the function call overhead for correlation IDs
        if correlationId <= 0xBF then
            local c2 = ch.cursor
            if c2 + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, c2, correlationId)
            ch.cursor = c2 + 1
        elseif correlationId <= 8383 then
            local c2 = ch.cursor
            if c2 + 2 > ch.size then
                alloc(ch, 2)
            end
            local adjusted = correlationId - 192
            writeu8(ch.buff, c2, bor(0xC0, band(adjusted // 256, 0x1F)))
            writeu8(ch.buff, c2 + 1, band(adjusted, 0xFF))
            ch.cursor = c2 + 2
        else
            local c2 = ch.cursor
            if c2 + 5 > ch.size then
                alloc(ch, 5)
            end
            writeu8(ch.buff, c2, 0xF0)
            buffer.writeu32(ch.buff, c2 + 1, correlationId)
            ch.cursor = c2 + 5
        end

        codec.write(ch, data)
    else
        -- MSB set signals nil response to the reader
        local cursor = ch.cursor
        if cursor + 1 > ch.size then
            alloc(ch, 1)
        end
        writeu8(ch.buff, cursor, bor(0x80, id))
        ch.cursor = cursor + 1

        if correlationId <= 0xBF then
            local c2 = ch.cursor
            if c2 + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, c2, correlationId)
            ch.cursor = c2 + 1
        elseif correlationId <= 8383 then
            local c2 = ch.cursor
            if c2 + 2 > ch.size then
                alloc(ch, 2)
            end
            local adjusted = correlationId - 192
            writeu8(ch.buff, c2, bor(0xC0, band(adjusted // 256, 0x1F)))
            writeu8(ch.buff, c2 + 1, band(adjusted, 0xFF))
            ch.cursor = c2 + 2
        else
            local c2 = ch.cursor
            if c2 + 5 > ch.size then
                alloc(ch, 5)
            end
            writeu8(ch.buff, c2, 0xF0)
            buffer.writeu32(ch.buff, c2 + 1, correlationId)
            ch.cursor = c2 + 5
        end
    end
end

-- Configuration -------------------------------------------------------

function Channel.setMaxSize(bytes: number): ()
    _maxSize = bytes
end

function Channel.updateTimestamp(): ()
    _frameCounter = (_frameCounter + 1) % 256
    _offsetMs = round((os.clock() % 65.536) * 1000)
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
