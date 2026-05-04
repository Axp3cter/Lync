--!strict
--!native
-- Shared composite-codec helpers: delta flags, scratch pool, bool packing.

local Base = require(script.Parent.Parent.Base)
local Buf = require(script.Parent.Parent.Parent.util.Buffer)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

--[[
    Delta flag base shared by deltaStruct's per-segment scheme:
      0    UNCHANGED
      1..segCount             single dirty segment k
      segCount + FULL_OFFSET  FULL payload
      segCount + MULTI_OFFSET MULTI: bitmap + dirty segs in order
    deltaArray and deltaMap manage their own flag spaces.
]]
local DELTA_UNCHANGED = 0
local DELTA_FULL_OFFSET = 1
local DELTA_MULTI_OFFSET = 2

-- State ------------------------------------------------------------------

local _nextDeltaId = 0
local _scratchDepth = 0
local _scratchStack: { Types.ChannelState } = {}

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local readu8 = buffer.readu8
local writeu8 = buffer.writeu8
local bufCopy = buffer.copy
local bufLen = buffer.len
local rangeEqual = Buf.rangeEqual
local snapshot = Buf.snapshot

--[[
    Reuse `existing` when it's already large enough, else snapshot via
    Buf.snapshot. Avoids per-write buffer allocations on delta caches that
    hover at a stable size.
]]
local function copyToBuf(existing: buffer?, src: buffer, srcOff: number, len: number): buffer
    if existing and bufLen(existing) >= len then
        bufCopy(existing, 0, src, srcOff, len)
        return existing
    end
    return snapshot(src, len, srcOff)
end

-- Update a `{raw, len}` cache shape from scratch bytes; reuses raw via copyToBuf.
local function refreshCache(cache: any, src: buffer, len: number): ()
    cache.raw = copyToBuf(cache.raw, src, 0, len)
    cache.len = len
end

-- Public -----------------------------------------------------------------

local Shared = {}

Shared.DELTA_UNCHANGED = DELTA_UNCHANGED
Shared.DELTA_FULL_OFFSET = DELTA_FULL_OFFSET
Shared.DELTA_MULTI_OFFSET = DELTA_MULTI_OFFSET
Shared.rangeEqual = rangeEqual
Shared.snapshot = snapshot
Shared.refreshCache = refreshCache
Shared.copyToBuf = copyToBuf

-- True when `c` itself is a delta codec OR contains one in its tree.
function Shared.containsDelta(c: Types.InternalCodec<any>): boolean
    return c._isDelta == true or c._hasDelta == true
end

-- Common bounds check for variable-length container codecs.
function Shared.enforceMaxCount(len: number, maxCount: number?, label: string?): ()
    if maxCount and len > maxCount then
        Log.error(`{label or "count"} {len} exceeds max {maxCount}`)
    end
end

function Shared.allocDeltaId(): number
    _nextDeltaId += 1
    return _nextDeltaId
end

-- 8 bools per byte.
function Shared.boolBytes(n: number): number
    return (n + 7) // 8
end

--[[
    Stack-based scratch ChannelState pool. Re-entrant codec serialization
    (a codec writing into scratch that triggers another codec's scratch
    acquire) works without aliasing. Full scrub on reuse so any codec that
    reads framing fields (lastId/singleMode/itemCount/countPos) on scratch
    sees a clean state, not stale bytes from the previous owner.
]]
function Shared.acquireScratch(): Types.ChannelState
    _scratchDepth += 1
    local ch = _scratchStack[_scratchDepth]
    if ch then
        ch.cursor = 0
        ch.refCount = 0
        ch.lastId = -1
        ch.countPos = -1
        ch.itemCount = 0
        ch.singleMode = false
        ch.singlePos = 0
        ch.currentPacket = nil
        if next(ch.deltas) ~= nil then
            table.clear(ch.deltas)
        end
        return ch
    end
    ch = Channel.create()
    _scratchStack[_scratchDepth] = ch
    return ch
end

function Shared.releaseScratch(): ()
    _scratchDepth -= 1
end

--[[
    Reset module-private state. Called by Sandbox in tests so that a thrown
    codec.write (which skips releaseScratch and leaves depth inflated) can't
    leak into the next test's scratch acquisition. Also resets the deltaId
    counter so test ordering doesn't bleed.
]]
function Shared.reset(): ()
    _scratchDepth = 0
    _nextDeltaId = 0
    for i = 1, #_scratchStack do
        local ch = _scratchStack[i]
        ch.cursor = 0
        ch.refCount = 0
        if ch.refCount > 0 then
            table.clear(ch.refs)
        end
        table.clear(ch.deltas)
    end
end

--[[
    Split a struct schema into (dataKeys, dataCodecs, boolKeys), each sorted
    alphabetically for deterministic wire layout.
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

    Log.assert(#dataKeys > 0 or #boolKeys > 0, "requires at least one field")

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

-- `byteCount` is `(boolCount + 7) // 8`; callers with it cached pass it through.
function Shared.packBools(
    ch: Types.ChannelState,
    value: { [string]: any },
    boolKeys: { string },
    boolCount: number,
    byteCount: number?
): ()
    if boolCount == 0 then
        return
    end

    local bc = byteCount or (boolCount + 7) // 8
    local cursor = ch.cursor
    if cursor + bc > ch.size then
        alloc(ch, bc)
    end

    local idx = 1
    local b = ch.buff
    for byteIdx = 0, bc - 1 do
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

    ch.cursor = cursor + bc
end

--[[
    Integer-indexed bool-array pack. Split from packBools to skip the
    per-bit string-key getter on the bool-array hot path.
]]
function Shared.packBoolArray(
    ch: Types.ChannelState,
    value: { boolean },
    count: number,
    byteCount: number?
): ()
    if count == 0 then
        return
    end

    local bc = byteCount or (count + 7) // 8
    local cursor = ch.cursor
    if cursor + bc > ch.size then
        alloc(ch, bc)
    end

    local idx = 1
    local b = ch.buff
    for byteIdx = 0, bc - 1 do
        local packed = 0
        local remaining = count - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            if value[idx] then
                packed = bor(packed, lshift(1, bit))
            end
            idx += 1
        end
        writeu8(b, cursor + byteIdx, packed)
    end

    ch.cursor = cursor + bc
end

function Shared.unpackBools(
    src: buffer,
    pos: number,
    boolKeys: { string },
    boolCount: number,
    result: { [string]: any },
    byteCount: number?
): number
    if boolCount == 0 then
        return 0
    end

    local bc = byteCount or (boolCount + 7) // 8
    local idx = 1
    for byteIdx = 0, bc - 1 do
        local byte = readu8(src, pos + byteIdx)
        local remaining = boolCount - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            result[boolKeys[idx]] = band(byte, lshift(1, bit)) ~= 0
            idx += 1
        end
    end
    return bc
end

-- Fills `result[1..count]` in place.
function Shared.unpackBoolArray(
    src: buffer,
    pos: number,
    count: number,
    result: { boolean },
    byteCount: number?
): number
    if count == 0 then
        return 0
    end

    local bc = byteCount or (count + 7) // 8
    local idx = 1
    for byteIdx = 0, bc - 1 do
        local byte = readu8(src, pos + byteIdx)
        local remaining = count - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            result[idx] = band(byte, lshift(1, bit)) ~= 0
            idx += 1
        end
    end
    return bc
end

return table.freeze(Shared)
