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
    Delta flag space, shared across deltaStruct/deltaArray/deltaMap:
      0    UNCHANGED  (decoder reuses cache)
      1    FULL       (full payload follows)
    Struct's per-segment scheme uses [1..segCount] as a single-dirty-segment
    index, then segCount + DELTA_FULL_OFFSET / + DELTA_MULTI_OFFSET.
]]
local DELTA_UNCHANGED = 0
local DELTA_FULL = 1
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
local rangeEqual = Buf.rangeEqual
local snapshot = Buf.snapshot

-- Public -----------------------------------------------------------------

local Shared = {}

Shared.DELTA_UNCHANGED = DELTA_UNCHANGED
Shared.DELTA_FULL_OFFSET = DELTA_FULL_OFFSET
Shared.DELTA_MULTI_OFFSET = DELTA_MULTI_OFFSET
Shared.rangeEqual = rangeEqual
Shared.snapshot = snapshot

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
    acquire) works without aliasing.
]]
function Shared.acquireScratch(): Types.ChannelState
    _scratchDepth += 1
    local ch = _scratchStack[_scratchDepth]
    if ch then
        ch.cursor = 0
        ch.refCount = 0
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

    local idx = 1
    local b = ch.buff
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

--[[
    Integer-indexed bool-array pack. Split from packBools to skip the
    per-bit string-key getter on the bool-array hot path.
]]
function Shared.packBoolArray(ch: Types.ChannelState, value: { boolean }, count: number): ()
    if count == 0 then
        return
    end

    local byteCount = (count + 7) // 8
    local cursor = ch.cursor
    if cursor + byteCount > ch.size then
        alloc(ch, byteCount)
    end

    local idx = 1
    local b = ch.buff
    for byteIdx = 0, byteCount - 1 do
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

-- Fills `result[1..count]` in place.
function Shared.unpackBoolArray(
    src: buffer,
    pos: number,
    count: number,
    result: { boolean }
): number
    if count == 0 then
        return 0
    end

    local byteCount = (count + 7) // 8
    local idx = 1
    for byteIdx = 0, byteCount - 1 do
        local byte = readu8(src, pos + byteIdx)
        local remaining = count - idx + 1
        local limit = if remaining >= 8 then 8 else remaining
        for bit = 0, limit - 1 do
            result[idx] = band(byte, lshift(1, bit)) ~= 0
            idx += 1
        end
    end
    return byteCount
end

--[[
    Build a byte-equality delta codec around any inner codec. Wire:
      [DELTA_UNCHANGED]                       1 byte
      [DELTA_FULL]  <inner-encoded payload>   1 + N bytes
    Used by deltaArray and deltaMap. The FULL path encodes once into scratch
    then bufCopies into the channel — avoids a double encode.
]]
function Shared.makeUnchangedOrFullDelta(
    inner: Types.InternalCodec<any>,
    deltaId: number,
    Baseline: {
        getCache: (number) -> any,
        setCache: (number, any) -> (),
    }
): Types.InternalCodec<any>
    return table.freeze({
        _isDelta = true,

        write = function(ch: Types.ChannelState, value: any): ()
            local scratch = Shared.acquireScratch()
            inner.write(scratch, value)
            local scratchLen = scratch.cursor

            local cache = ch.deltas[deltaId]
            if
                cache
                and scratchLen == cache.len
                and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchLen)
            then
                local cursor = ch.cursor
                if cursor + 1 > ch.size then
                    alloc(ch, 1)
                end
                writeu8(ch.buff, cursor, DELTA_UNCHANGED)
                ch.cursor = cursor + 1
                Shared.releaseScratch()
                return
            end

            local cursor = ch.cursor
            if cursor + 1 + scratchLen > ch.size then
                alloc(ch, 1 + scratchLen)
            end
            local b = ch.buff
            writeu8(b, cursor, DELTA_FULL)
            if scratchLen > 0 then
                bufCopy(b, cursor + 1, scratch.buff, 0, scratchLen)
            end
            ch.cursor = cursor + 1 + scratchLen

            local snap = snapshot(scratch.buff, scratchLen)
            if cache then
                cache.raw = snap
                cache.len = scratchLen
            else
                ch.deltas[deltaId] = { raw = snap, len = scratchLen }
            end
            Shared.releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if readu8(src, pos) == DELTA_UNCHANGED then
                local cached = Baseline.getCache(deltaId)
                if not cached then
                    Log.error("UNCHANGED flag before any FULL frame; baseline missing")
                end
                return cached, 1
            end
            local value, consumed = inner.read(src, pos + 1, refs)
            Baseline.setCache(deltaId, value)
            return value, 1 + consumed
        end,
    })
end

return table.freeze(Shared)
