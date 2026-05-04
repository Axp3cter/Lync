--!strict
--!native
-- struct() and deltaStruct(). Bool fields bit-pack into a tail block.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readu32 = buffer.readu32
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local countrz = bit32.countrz

-- 1/2/4-byte direct writes; 3-byte case splits into u16 + u8 (no native u24).
local function writeBitmap(b: buffer, off: number, mask: number, bitmapBytes: number): ()
    if bitmapBytes == 1 then
        writeu8(b, off, mask)
    elseif bitmapBytes == 2 then
        writeu16(b, off, mask)
    elseif bitmapBytes == 4 then
        writeu32(b, off, mask)
    else
        writeu16(b, off, band(mask, 0xFFFF))
        writeu8(b, off + 2, band(rshift(mask, 16), 0xFF))
    end
end

local function readBitmap(b: buffer, off: number, bitmapBytes: number): number
    if bitmapBytes == 1 then
        return readu8(b, off)
    elseif bitmapBytes == 2 then
        return readu16(b, off)
    elseif bitmapBytes == 4 then
        return readu32(b, off)
    end
    return bor(readu16(b, off), lshift(readu8(b, off + 2), 16))
end

local extractFields = Shared.extractFields
local packBools = Shared.packBools
local unpackBools = Shared.unpackBools
local rangeEqual = Shared.rangeEqual
local snapshot = Shared.snapshot
local refreshCache = Shared.refreshCache
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local allocDeltaId = Shared.allocDeltaId
local DELTA_UNCHANGED = Shared.DELTA_UNCHANGED
local DELTA_FULL_OFFSET = Shared.DELTA_FULL_OFFSET
local DELTA_MULTI_OFFSET = Shared.DELTA_MULTI_OFFSET

local function buildFrozenSchema(
    dataKeys: { string },
    boolKeys: { string },
    schema: { [string]: Types.InternalCodec<any> }
): { [string]: Types.InternalCodec<any> }
    local frozen: { [string]: Types.InternalCodec<any> } = {}
    for i = 1, #dataKeys do
        local k = dataKeys[i]
        frozen[k] = schema[k]
    end
    for i = 1, #boolKeys do
        local k = boolKeys[i]
        frozen[k] = schema[k]
    end
    return table.freeze(frozen)
end

-- Public -----------------------------------------------------------------

local Struct = {}

function Struct.struct(schema: { [string]: Types.InternalCodec<any> }): Types.InternalCodec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)
    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolBytes = Shared.boolBytes(boolCount)

    -- Single pass: detect all-direct fast-write path + propagate _hasUnknown / _hasDelta.
    local allDirect, fixedSize = true, 0
    local hasUnknown = false
    local hasDelta = false
    for i = 1, dataCount do
        local c = dataCodecs[i]
        if c._hasUnknown then
            hasUnknown = true
        end
        if Shared.containsDelta(c) then
            hasDelta = true
        end
        if allDirect then
            if c._size and c._directWrite and c._directRead then
                fixedSize += c._size
            else
                allDirect = false
            end
        end
    end

    local totalFixed = fixedSize + boolBytes
    local frozenSchema = buildFrozenSchema(dataKeys, boolKeys, schema)

    if allDirect and dataCount > 0 then
        local offsets = table.create(dataCount)
        local directWrites = table.create(dataCount)
        local directReads = table.create(dataCount)
        local runningOffset = 0
        for i = 1, dataCount do
            local c = dataCodecs[i]
            offsets[i] = runningOffset
            directWrites[i] = c._directWrite
            directReads[i] = c._directRead
            runningOffset += c._size :: number
        end
        table.freeze(offsets)
        table.freeze(directWrites)
        table.freeze(directReads)

        local codec: Types.InternalCodec<any> = {
            _size = totalFixed,
            _schema = frozenSchema,

            _directWrite = function(b: buffer, off: number, value: any): ()
                for i = 1, dataCount do
                    directWrites[i](b, off + offsets[i], value[dataKeys[i]])
                end
                if boolCount == 0 then
                    return
                end

                -- Inline bool packing to avoid the cursor-based packBools call.
                local boolOff = off + fixedSize
                local idx = 1
                for byteIdx = 0, boolBytes - 1 do
                    local packed = 0
                    local remaining = boolCount - idx + 1
                    local limit = if remaining >= 8 then 8 else remaining
                    for bit = 0, limit - 1 do
                        if value[boolKeys[idx]] then
                            packed = bor(packed, lshift(1, bit))
                        end
                        idx += 1
                    end
                    writeu8(b, boolOff + byteIdx, packed)
                end
            end,

            _directRead = function(b: buffer, off: number): any
                local result: { [string]: any } = {}
                for i = 1, dataCount do
                    result[dataKeys[i]] = directReads[i](b, off + offsets[i])
                end
                if boolCount > 0 then
                    unpackBools(b, off + fixedSize, boolKeys, boolCount, result, boolBytes)
                end
                return result
            end,

            write = function(ch: Types.ChannelState, value: any): ()
                local cursor = ch.cursor
                if cursor + totalFixed > ch.size then
                    alloc(ch, totalFixed)
                end
                local b = ch.buff
                for i = 1, dataCount do
                    directWrites[i](b, cursor + offsets[i], value[dataKeys[i]])
                end
                ch.cursor = cursor + fixedSize
                if boolCount > 0 then
                    packBools(ch, value, boolKeys, boolCount, boolBytes)
                end
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
                local result: { [string]: any } = {}
                for i = 1, dataCount do
                    result[dataKeys[i]] = directReads[i](src, pos + offsets[i])
                end
                if boolCount > 0 then
                    unpackBools(src, pos + fixedSize, boolKeys, boolCount, result, boolBytes)
                end
                return result, totalFixed
            end,
        }
        if hasUnknown then
            codec._hasUnknown = true
        end
        if hasDelta then
            codec._hasDelta = true
        end
        return table.freeze(codec)
    end

    local codec: Types.InternalCodec<any> = {
        _schema = frozenSchema,

        write = function(ch: Types.ChannelState, value: any): ()
            for i = 1, dataCount do
                dataCodecs[i].write(ch, value[dataKeys[i]])
            end
            if boolCount > 0 then
                packBools(ch, value, boolKeys, boolCount, boolBytes)
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result: { [string]: any } = {}
            local total = 0
            for i = 1, dataCount do
                local v, consumed = dataCodecs[i].read(src, pos + total, refs)
                result[dataKeys[i]] = v
                total += consumed
            end
            if boolCount > 0 then
                total += unpackBools(src, pos + total, boolKeys, boolCount, result, boolBytes)
            end
            return result, total
        end,
    }
    if hasUnknown then
        codec._hasUnknown = true
    end
    if hasDelta then
        codec._hasDelta = true
    end
    return table.freeze(codec)
end

--[[
    Per-field delta encoder. Splits a struct into segments (one per data
    field, plus one for the packed-bool block if any) and emits only changed
    segments. Wire flag byte:
      0                              UNCHANGED (reuse cache)
      [1 .. segCount]                single segment k changed
      segCount + DELTA_FULL_OFFSET   FULL payload
      segCount + DELTA_MULTI_OFFSET  MULTI: bitmap + dirty segs in order
]]
function Struct.deltaStruct(
    schema: { [string]: Types.InternalCodec<any> }
): Types.InternalCodec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)
    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local hasBoolSeg = boolCount > 0
    local segCount = dataCount + (if hasBoolSeg then 1 else 0)
    local FLAG_FULL = segCount + DELTA_FULL_OFFSET
    local FLAG_MULTI = segCount + DELTA_MULTI_OFFSET
    local boolSegIdx = segCount

    if FLAG_MULTI > 0xFF then
        Log.error(`too many segments ({segCount}); flag byte would overflow`)
    end
    if segCount > 32 then
        Log.error(`dirty bitmask is u32, segCount {segCount} exceeds 32`)
    end

    local deltaId = allocDeltaId()
    local innerStruct = Struct.struct(schema)
    -- Reuse innerStruct's frozen schema; avoids a second buildFrozenSchema.
    local frozenSchema = innerStruct._schema :: { [string]: Types.InternalCodec<any> }

    -- All-direct + fixed-size: segment offsets/lengths are statically known.
    local allDirect = dataCount > 0
    local fixedSize = 0
    for i = 1, dataCount do
        local c = dataCodecs[i]
        if not c._size or not c._directWrite or not c._directRead then
            allDirect = false
            break
        end
        fixedSize += c._size :: number
    end

    local boolBytes = Shared.boolBytes(boolCount)
    local bitmapBytes = Shared.boolBytes(segCount)

    local staticSegOff: { number }? = nil
    local staticSegLen: { number }? = nil
    if allDirect then
        local off = 0
        local segOff = table.create(segCount)
        local segLen = table.create(segCount)
        for i = 1, dataCount do
            segOff[i] = off
            segLen[i] = dataCodecs[i]._size :: number
            off += dataCodecs[i]._size :: number
        end
        if hasBoolSeg then
            segOff[boolSegIdx] = off
            segLen[boolSegIdx] = boolBytes
        end
        staticSegOff = table.freeze(segOff)
        staticSegLen = table.freeze(segLen)
    end

    -- Apply one segment's bytes onto `target`. Returns bytes consumed.
    local function applySegmentRead(
        target: { [string]: any },
        segIdx: number,
        src: buffer,
        pos: number,
        refs: { Instance }?
    ): number
        if hasBoolSeg and segIdx == boolSegIdx then
            return unpackBools(src, pos, boolKeys, boolCount, target, boolBytes)
        end
        local v, consumed = dataCodecs[segIdx].read(src, pos, refs)
        target[dataKeys[segIdx]] = v
        return consumed
    end

    -- Splice `src[srcOff..srcOff+len)` into the channel's main buffer.
    local function writeBytes(ch: Types.ChannelState, src: buffer, srcOff: number, len: number): ()
        if len == 0 then
            return
        end
        local cursor = ch.cursor
        if cursor + len > ch.size then
            alloc(ch, len)
        end
        buffer.copy(ch.buff, cursor, src, srcOff, len)
        ch.cursor = cursor + len
    end

    return table.freeze({
        _isDelta = true,
        _schema = frozenSchema,

        write = function(ch: Types.ChannelState, value: any): ()
            local scratch = acquireScratch()
            local segOff: { number }, segLen: { number }

            if staticSegOff then
                -- Bulk write via innerStruct, constant offsets.
                innerStruct.write(scratch, value)
                segOff = staticSegOff :: { number }
                segLen = staticSegLen :: { number }
            else
                segOff = table.create(segCount)
                segLen = table.create(segCount)
                local prev = 0
                for i = 1, dataCount do
                    dataCodecs[i].write(scratch, value[dataKeys[i]])
                    local cur = scratch.cursor
                    segOff[i] = prev
                    segLen[i] = cur - prev
                    prev = cur
                end
                if hasBoolSeg then
                    packBools(scratch, value, boolKeys, boolCount, boolBytes)
                    segOff[boolSegIdx] = prev
                    segLen[boolSegIdx] = scratch.cursor - prev
                end
            end

            local scratchLen = scratch.cursor
            local cache = ch.deltas[deltaId]

            if not cache then
                writeByte(ch, FLAG_FULL)
                writeBytes(ch, scratch.buff, 0, scratchLen)
                --[[
                    Variable-size case stores fresh segOff/segLen by ref;
                    static case stores the module-level frozen tables.
                ]]
                ch.deltas[deltaId] = {
                    raw = snapshot(scratch.buff, scratchLen),
                    len = scratchLen,
                    segOff = segOff,
                    segLen = segLen,
                } :: any
                releaseScratch()
                return
            end

            local cacheRaw = cache.raw
            local cacheOff = (cache :: any).segOff :: { number }
            local cacheLen = (cache :: any).segLen :: { number }

            local dirtyMask = 0
            local dirtyCount = 0
            for i = 1, segCount do
                local newLen = segLen[i]
                if
                    newLen ~= cacheLen[i]
                    or not rangeEqual(scratch.buff, segOff[i], cacheRaw, cacheOff[i], newLen)
                then
                    dirtyMask = bor(dirtyMask, lshift(1, i - 1))
                    dirtyCount += 1
                end
            end

            if dirtyCount == 0 then
                writeByte(ch, DELTA_UNCHANGED)
                releaseScratch()
                return
            end

            if dirtyCount == segCount then
                writeByte(ch, FLAG_FULL)
                writeBytes(ch, scratch.buff, 0, scratchLen)
            elseif dirtyCount == 1 then
                local segIdx = countrz(dirtyMask) + 1
                writeByte(ch, segIdx)
                writeBytes(ch, scratch.buff, segOff[segIdx], segLen[segIdx])
            else
                writeByte(ch, FLAG_MULTI)
                local cursor = ch.cursor
                if cursor + bitmapBytes > ch.size then
                    alloc(ch, bitmapBytes)
                end
                writeBitmap(ch.buff, cursor, dirtyMask, bitmapBytes)
                ch.cursor = cursor + bitmapBytes
                for i = 1, segCount do
                    if band(dirtyMask, lshift(1, i - 1)) ~= 0 then
                        writeBytes(ch, scratch.buff, segOff[i], segLen[i])
                    end
                end
            end

            refreshCache(cache, scratch.buff, scratchLen);
            (cache :: any).segOff = segOff;
            (cache :: any).segLen = segLen
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = readu8(src, pos)

            if flag == DELTA_UNCHANGED then
                local cached = Baseline.getCache(deltaId)
                if not cached then
                    Log.error("UNCHANGED flag before any FULL frame; baseline missing")
                end
                return cached, 1
            end

            if flag == FLAG_FULL then
                local value, consumed = innerStruct.read(src, pos + 1, refs)
                Baseline.setCache(deltaId, value)
                return value, 1 + consumed
            end

            if flag <= segCount then
                local cached = Baseline.getCache(deltaId)
                if cached == nil then
                    Log.error(
                        `per-field update (seg {flag}) before any FULL frame; baseline missing`
                    )
                end
                local newValue = table.clone(cached)
                local consumed = applySegmentRead(newValue, flag, src, pos + 1, refs)
                Baseline.setCache(deltaId, newValue)
                return newValue, 1 + consumed
            end

            if flag == FLAG_MULTI then
                local cached = Baseline.getCache(deltaId)
                if not cached then
                    Log.error("multi-field update before any FULL frame")
                end
                local newValue = table.clone(cached)
                local mask = readBitmap(src, pos + 1, bitmapBytes)
                local total = 1 + bitmapBytes
                for i = 1, segCount do
                    if band(mask, lshift(1, i - 1)) ~= 0 then
                        local consumed = applySegmentRead(newValue, i, src, pos + total, refs)
                        total += consumed
                    end
                end
                Baseline.setCache(deltaId, newValue)
                return newValue, total
            end

            Log.error(`invalid delta flag {flag}`)
        end,
    }) :: Types.InternalCodec<any>
end

return table.freeze(Struct)
