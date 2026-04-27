--!strict
--!native
-- Shared helpers for composite codecs: delta flags, scratch pool, bool packing.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

--[[
    Delta encoding flag space, shared across deltaStruct/deltaArray/deltaMap:
      0    UNCHANGED  : sender skipped this entry, decoder reuses cache
      1    FULL       : full payload follows
      2..  reserved   : per-segment / per-key delta encodings (future)

    Struct's per-segment scheme uses [1..segCount] as "single dirty
    segment index" then segCount + DELTA_FULL_OFFSET for full and
    segCount + DELTA_MULTI_OFFSET for multi-dirty bitmap.
]]
local DELTA_UNCHANGED = 0
local DELTA_FULL = 1
local DELTA_FULL_OFFSET = 1
local DELTA_MULTI_OFFSET = 2

local INITIAL_SCRATCH = 1024

-- State ------------------------------------------------------------------

local _nextDeltaId = 0
local _scratchDepth = 0
local _scratchStack: { Types.ChannelState } = {}

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local band = bit32.band
local bor = bit32.bor
local bxor = bit32.bxor
local lshift = bit32.lshift
local readu8 = buffer.readu8
local readu32 = buffer.readu32
local writeu8 = buffer.writeu8

local function newScratch(): Types.ChannelState
    return {
        buff = buffer.create(INITIAL_SCRATCH),
        cursor = 0,
        size = INITIAL_SCRATCH,
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

-- Public -----------------------------------------------------------------

local Shared = {}

Shared.DELTA_UNCHANGED = DELTA_UNCHANGED
Shared.DELTA_FULL = DELTA_FULL
Shared.DELTA_FULL_OFFSET = DELTA_FULL_OFFSET
Shared.DELTA_MULTI_OFFSET = DELTA_MULTI_OFFSET

function Shared.allocDeltaId(): number
    _nextDeltaId += 1
    return _nextDeltaId
end

--[[
    Acquire a scratch ChannelState. Stack-based so re-entrant codec
    serialization (a codec writing into scratch that triggers another
    codec's scratch acquire) works without aliasing.
]]
function Shared.acquireScratch(): Types.ChannelState
    _scratchDepth += 1
    local ch = _scratchStack[_scratchDepth]
    if ch then
        ch.cursor = 0
        ch.refCount = 0
        return ch
    end
    ch = newScratch()
    _scratchStack[_scratchDepth] = ch
    return ch
end

function Shared.releaseScratch(): ()
    _scratchDepth -= 1
end

function Shared.rangeEqual(a: buffer, offA: number, b: buffer, offB: number, len: number): boolean
    local aligned = band(len, -4)
    local i = 0
    while i < aligned do
        if bxor(readu32(a, offA + i), readu32(b, offB + i)) ~= 0 then
            return false
        end
        i += 4
    end
    while i < len do
        if readu8(a, offA + i) ~= readu8(b, offB + i) then
            return false
        end
        i += 1
    end
    return true
end

function Shared.snapshot(src: buffer, len: number): buffer
    local out = buffer.create(len)
    if len > 0 then
        buffer.copy(out, 0, src, 0, len)
    end
    return out
end

--[[
    Split a struct schema into (dataKeys, dataCodecs, boolKeys), all
    sorted alphabetically for deterministic wire layout.
]]
function Shared.extractFields(
    schema: { [string]: Types.InternalCodec<any> }
): ({ string }, { Types.InternalCodec<any> }, { string })
    local dataKeys: { string } = {}
    local boolKeys: { string } = {}

    for key, codec in schema do
        if codec._isBool then
            table.insert(boolKeys, key)
        else
            table.insert(dataKeys, key)
        end
    end

    if #dataKeys == 0 and #boolKeys == 0 then
        error("[Lync] Lync.struct: requires at least one field")
    end

    table.sort(dataKeys)
    table.sort(boolKeys)

    local dataCount = #dataKeys
    local dataCodecs = table.create(dataCount)
    for i = 1, dataCount do
        dataCodecs[i] = schema[dataKeys[i]]
    end

    table.freeze(dataKeys)
    table.freeze(dataCodecs)
    table.freeze(boolKeys)
    return dataKeys, dataCodecs, boolKeys
end

function Shared.packBools(
    ch: Types.ChannelState,
    value: { [string]: any },
    boolKeys: { string },
    boolCount: number
): ()
    if boolCount == 0 then
        return
    end

    local byteCount = (boolCount + 7) // 8
    local cursor = ch.cursor
    if cursor + byteCount > ch.size then
        alloc(ch, byteCount)
    end
    local b = ch.buff

    local idx = 1
    for byteIdx = 0, byteCount - 1 do
        local packed = 0
        local remaining = boolCount - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            if value[boolKeys[idx]] then
                packed = bor(packed, lshift(1, bit))
            end
            idx += 1
        end
        writeu8(b, cursor + byteIdx, packed)
    end

    ch.cursor = cursor + byteCount
end

function Shared.unpackBools(
    src: buffer,
    pos: number,
    boolKeys: { string },
    boolCount: number,
    result: { [string]: any }
): number
    if boolCount == 0 then
        return 0
    end

    local byteCount = (boolCount + 7) // 8
    local idx = 1
    for byteIdx = 0, byteCount - 1 do
        local byte = readu8(src, pos + byteIdx)
        local remaining = boolCount - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            result[boolKeys[idx]] = band(byte, lshift(1, bit)) ~= 0
            idx += 1
        end
    end
    return byteCount
end

return table.freeze(Shared)
