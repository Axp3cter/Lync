--!strict
--!native
-- Shared helpers for composite codecs: delta flags, scratch pool, bool packing.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Constants -----------------------------------------------------------

local DELTA_UNCHANGED    = 0
local DELTA_FULL_OFFSET  = 1
local DELTA_MULTI_OFFSET = 2

-- State ---------------------------------------------------------------

local _nextDeltaId = 0
local _scratchDepth = 0
local _scratchStack: { Types.ChannelState } = {}

-- Private -------------------------------------------------------------

local alloc  = Base.alloc
local band   = bit32.band
local bor    = bit32.bor
local bxor   = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift

local readu8  = buffer.readu8
local readu32 = buffer.readu32
local writeu8 = buffer.writeu8

-- Public --------------------------------------------------------------

local Shared = {}

Shared.DELTA_UNCHANGED    = DELTA_UNCHANGED
Shared.DELTA_FULL_OFFSET  = DELTA_FULL_OFFSET
Shared.DELTA_MULTI_OFFSET = DELTA_MULTI_OFFSET

function Shared.allocDeltaId(): number
    _nextDeltaId += 1
    return _nextDeltaId
end

function Shared.acquireScratch(): Types.ChannelState
    _scratchDepth += 1
    local ch = _scratchStack[_scratchDepth]
    if not ch then
        ch = {
            buff = buffer.create(1024),
            cursor = 0,
            size = 1024,
            refs = {},
            refCount = 0,
            lastId = -1,
            countPos = 0,
            itemCount = 0,
            singleMode = false,
            singlePos = 0,
            deltas = {},
            prevDump = nil,
            prevDumpLen = 0,
            currentPacket = nil,
        }
        _scratchStack[_scratchDepth] = ch
    else
        ch.cursor = 0
        ch.refCount = 0
    end
    return ch
end

function Shared.releaseScratch(): ()
    _scratchDepth -= 1
end

function Shared.rangeEqual(
    a: buffer,
    offA: number,
    b: buffer,
    offB: number,
    len: number
): boolean
    -- u32 chunks
    local aligned = len - (len % 4)
    local i = 0
    while i < aligned do
        if bxor(readu32(a, offA + i), readu32(b, offB + i)) ~= 0 then
            return false
        end
        i += 4
    end

    -- u8 remainder
    while i < len do
        if readu8(a, offA + i) ~= readu8(b, offB + i) then
            return false
        end
        i += 1
    end

    return true
end

function Shared.extractFields(
    schema: { [string]: Types.InternalCodec<any> }
): ({ string }, { Types.InternalCodec<any> }, { string })
    local dataKeys: { string }                    = {}
    local dataCodecs: { Types.InternalCodec<any> } = {}
    local boolKeys: { string }                    = {}

    for key, codec in schema do
        if (codec :: any)._isBool then
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

    for i = 1, #dataKeys do
        dataCodecs[i] = schema[dataKeys[i]]
    end

    table.freeze(dataKeys)
    table.freeze(dataCodecs)
    table.freeze(boolKeys)

    return dataKeys, dataCodecs, boolKeys
end

function Shared.packBools(
    ch: Types.ChannelState,
    value: any,
    boolKeys: { string },
    boolCount: number
): ()
    local byteCount = (boolCount + 7) // 8
    local cursor = ch.cursor
    if cursor + byteCount > ch.size then alloc(ch, byteCount) end
    local b = ch.buff

    local idx = 1
    for byteIdx = 0, byteCount - 1 do
        local packed = 0
        local limit = if idx + 8 <= boolCount + 1 then 8 else boolCount - idx + 1
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
    result: any
): number
    local byteCount = (boolCount + 7) // 8
    local idx = 1

    for byteIdx = 0, byteCount - 1 do
        local byte = readu8(src, pos + byteIdx)
        local limit = if idx + 8 <= boolCount + 1 then 8 else boolCount - idx + 1
        for bit = 0, limit - 1 do
            result[boolKeys[idx]] = band(byte, lshift(1, bit)) ~= 0
            idx += 1
        end
    end

    return byteCount
end

return table.freeze(Shared)
