--!strict
--!optimize 2
-- Struct, deltaStruct, deltaArray, array, map, optional.

local Baseline = require (script.Parent.Parent.core.Baseline)
local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)
local Varint = require (script.Parent.Varint)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local ceil = math.ceil
local min = math.min

local FLAG_DELTA = 0
local FLAG_FULL = 1
local FLAG_UNCHANGED = 2

-- State ------------------------------------------------------------------

local _nextDeltaId = 1
local _scratchStack = {} :: { ChannelState }
local _scratchDepth = 0

-- Private ----------------------------------------------------------------

local function acquireScratch (): ChannelState
    _scratchDepth += 1
    local scratch = _scratchStack[_scratchDepth]
    if not scratch then
        scratch = Channel.create ()
        _scratchStack[_scratchDepth] = scratch
    end
    scratch.cursor = 0
    table.clear (scratch.refs)
    return scratch
end

local function releaseScratch (): ()
    _scratchDepth -= 1
end

type DeltaCache = {
    raw: buffer,
    bounds: { number },
    total: number,
}

local function rangeEqual (a: buffer, offA: number, b: buffer, offB: number, len: number): boolean
    local aligned = band (len, 0xFFFFFFFC)
    for i = 0, aligned - 4, 4 do
        if buffer.readu32 (a, offA + i) ~= buffer.readu32 (b, offB + i) then
            return false
        end
    end

    for i = aligned, len - 1 do
        if buffer.readu8 (a, offA + i) ~= buffer.readu8 (b, offB + i) then
            return false
        end
    end

    return true
end

--[[
    Extract sorted data-field keys/codecs and sorted bool keys from a schema.
    Returns parallel arrays (keys + codecs indexed together) and bool keys.
]]
local function extractFields (
    schema: { [string]: Codec<any> }
): ({ string }, { Codec<any> }, { string })
    local dataKeys = {} :: { string }
    local dataCodecs = {} :: { Codec<any> }
    local boolKeys = {} :: { string }

    for key, codec in schema do
        if (codec :: any)._isBool then
            table.insert (boolKeys, key)
        else
            table.insert (dataKeys, key)
        end
    end

    table.sort (dataKeys)
    table.sort (boolKeys)

    if #dataKeys == 0 and #boolKeys == 0 then
        error ("[Lync] Struct requires at least one field")
    end

    for i = 1, #dataKeys do
        dataCodecs[i] = schema[dataKeys[i]]
    end

    table.freeze (dataKeys)
    table.freeze (dataCodecs)
    table.freeze (boolKeys)

    return dataKeys, dataCodecs, boolKeys
end

local function packBools (ch: ChannelState, boolKeys: { string }, boolCount: number, value: any): ()
    local boolByteCount = ceil (boolCount / 8)
    Channel.alloc (ch, boolByteCount)
    local b = ch.buff
    local c = ch.cursor

    for byteIdx = 0, boolByteCount - 1 do
        local packed = 0
        local base = byteIdx * 8
        local limit = min (8, boolCount - base)

        for bit = 0, limit - 1 do
            if value[boolKeys[base + bit + 1]] then
                packed = bor (packed, lshift (1, bit))
            end
        end

        buffer.writeu8 (b, c + byteIdx, packed)
    end

    ch.cursor = c + boolByteCount
end

local function unpackBools (
    src: buffer,
    pos: number,
    boolKeys: { string },
    boolCount: number,
    result: any
): number
    local boolByteCount = ceil (boolCount / 8)

    for byteIdx = 0, boolByteCount - 1 do
        local byte = buffer.readu8 (src, pos + byteIdx)
        local base = byteIdx * 8
        local limit = min (8, boolCount - base)

        for bit = 0, limit - 1 do
            result[boolKeys[base + bit + 1]] = band (byte, lshift (1, bit)) ~= 0
        end
    end

    return boolByteCount
end

-- Public -----------------------------------------------------------------

local Composite = {}

function Composite.struct (schema: { [string]: Codec<any> }): Codec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields (schema)

    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolByteCount = ceil (boolCount / 8)

    local fixedSize = boolByteCount
    local isAllFixed = true
    for i = 1, dataCount do
        local size = (dataCodecs[i] :: any)._size
        if size then
            fixedSize += size
        else
            isAllFixed = false
        end
    end

    local hasBools = boolCount > 0

    return table.freeze ({
        _size = if isAllFixed then fixedSize else nil,

        write = function (ch: ChannelState, value: any): ()
            if isAllFixed then
                Channel.alloc (ch, fixedSize)
            end

            for i = 1, dataCount do
                dataCodecs[i].write (ch, value[dataKeys[i]])
            end

            if hasBools then
                packBools (ch, boolKeys, boolCount, value)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = {}
            local absPos = pos

            for i = 1, dataCount do
                local value, n = dataCodecs[i].read (src, absPos, refs)
                result[dataKeys[i]] = value
                absPos += n
            end

            if hasBools then
                absPos += unpackBools (src, absPos, boolKeys, boolCount, result)
            end

            return result, absPos - pos
        end,
    })
end

function Composite.deltaStruct (schema: { [string]: Codec<any> }): Codec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields (schema)

    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolByteCount = ceil (boolCount / 8)
    local segCount = dataCount + (if boolCount > 0 then 1 else 0)
    local bitmaskBytes = ceil (segCount / 8)
    local deltaId = _nextDeltaId
    _nextDeltaId += 1

    -- Scratch bounds reused every frame (only cloned into cache)
    local _scratchBounds = table.create (segCount + 1) :: { number }
    _scratchBounds[1] = 0

    return table.freeze ({
        _isDelta = true,

        write = function (ch: ChannelState, value: any): ()
            local cache = ch.deltas[deltaId] :: DeltaCache?
            local scratch = acquireScratch ()

            local bounds = _scratchBounds
            bounds[1] = 0

            for i = 1, dataCount do
                dataCodecs[i].write (scratch, value[dataKeys[i]])
                bounds[i + 1] = scratch.cursor
            end

            if boolCount > 0 then
                packBools (scratch, boolKeys, boolCount, value)
                bounds[segCount + 1] = scratch.cursor
            end

            local scratchTotal = scratch.cursor

            -- FLAG_FULL: first frame, no cache exists yet
            if not cache then
                Channel.alloc (ch, 1 + scratchTotal)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                buffer.copy (ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal

            -- FLAG_UNCHANGED: entire buffer is byte-identical to cache
            elseif
                scratchTotal == cache.total
                and rangeEqual (scratch.buff, 0, cache.raw, 0, scratchTotal)
            then
                Channel.alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_UNCHANGED)
                ch.cursor += 1
                releaseScratch ()
                return

            -- FLAG_DELTA: per-segment dirty mask + dirty payloads
            elseif bitmaskBytes == 1 then
                local mask = 0
                local cacheRaw = cache.raw
                local cacheBds = cache.bounds

                for i = 1, segCount do
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff
                    local oldOff = cacheBds[i]
                    local oldLen = cacheBds[i + 1] - oldOff

                    if
                        newLen ~= oldLen
                        or not rangeEqual (scratch.buff, newOff, cacheRaw, oldOff, newLen)
                    then
                        mask = bor (mask, lshift (1, i - 1))
                    end
                end

                Channel.alloc (ch, 2)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                buffer.writeu8 (ch.buff, ch.cursor + 1, mask)
                ch.cursor += 2

                for i = 1, segCount do
                    if band (mask, lshift (1, i - 1)) ~= 0 then
                        local newOff = bounds[i]
                        local newLen = bounds[i + 1] - newOff
                        Channel.alloc (ch, newLen)
                        buffer.copy (ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                        ch.cursor += newLen
                    end
                end
            else
                local maskBuf = table.create (bitmaskBytes, 0)
                local cacheRaw = cache.raw
                local cacheBds = cache.bounds

                for i = 1, segCount do
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff
                    local oldOff = cacheBds[i]
                    local oldLen = cacheBds[i + 1] - oldOff

                    if
                        newLen ~= oldLen
                        or not rangeEqual (scratch.buff, newOff, cacheRaw, oldOff, newLen)
                    then
                        local bitIdx = i - 1
                        local byteIdx = bitIdx // 8 + 1
                        maskBuf[byteIdx] = bor (maskBuf[byteIdx], lshift (1, bitIdx % 8))
                    end
                end

                Channel.alloc (ch, 1 + bitmaskBytes)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                ch.cursor += 1

                local maskStart = ch.cursor
                for byteIdx = 1, bitmaskBytes do
                    buffer.writeu8 (ch.buff, maskStart + byteIdx - 1, maskBuf[byteIdx])
                end
                ch.cursor = maskStart + bitmaskBytes

                for i = 1, segCount do
                    local bitIdx = i - 1
                    local byteIdx = bitIdx // 8 + 1
                    if band (maskBuf[byteIdx], lshift (1, bitIdx % 8)) ~= 0 then
                        local newOff = bounds[i]
                        local newLen = bounds[i + 1] - newOff
                        Channel.alloc (ch, newLen)
                        buffer.copy (ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                        ch.cursor += newLen
                    end
                end
            end

            -- Cache update (shared by FLAG_FULL and FLAG_DELTA)
            local rawBuf = buffer.create (scratchTotal)
            buffer.copy (rawBuf, 0, scratch.buff, 0, scratchTotal)

            local cacheBounds = table.clone (bounds)
            table.freeze (cacheBounds)
            ch.deltas[deltaId] = {
                raw = rawBuf,
                bounds = cacheBounds,
                total = scratchTotal,
            } :: DeltaCache

            releaseScratch ()
        end,

        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = buffer.readu8 (src, pos)
            local absPos = pos + 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache (deltaId) :: any
                return if cache then table.clone (cache) else {}, 1
            end

            if flag == FLAG_FULL then
                local result = {}

                for i = 1, dataCount do
                    local val, n = dataCodecs[i].read (src, absPos, refs)
                    result[dataKeys[i]] = val
                    absPos += n
                end

                if boolCount > 0 then
                    absPos += unpackBools (src, absPos, boolKeys, boolCount, result)
                end

                Baseline.setCache (deltaId, result)
                return result, absPos - pos
            end

            local cache = Baseline.getCache (deltaId) :: any
            local result = if cache then table.clone (cache) else {}

            local maskStart = absPos
            absPos += bitmaskBytes

            for i = 1, segCount do
                local bitIdx = i - 1
                local byte = buffer.readu8 (src, maskStart + (bitIdx // 8))

                if band (byte, lshift (1, bitIdx % 8)) ~= 0 then
                    if i <= dataCount then
                        local val, n = dataCodecs[i].read (src, absPos, refs)
                        result[dataKeys[i]] = val
                        absPos += n
                    else
                        absPos += unpackBools (src, absPos, boolKeys, boolCount, result)
                    end
                end
            end

            Baseline.setCache (deltaId, result)
            return result, absPos - pos
        end,
    })
end

function Composite.deltaArray (element: Codec<any>): Codec<{ any }>
    local deltaId = _nextDeltaId
    _nextDeltaId += 1

    return table.freeze ({
        _isDelta = true,

        write = function (ch: ChannelState, value: { any }): ()
            local len = #value
            local cache = ch.deltas[deltaId] :: { raw: buffer, bounds: { number }, len: number }?
            local scratch = acquireScratch ()

            local bounds = table.create (len + 1)
            bounds[1] = 0
            for i = 1, len do
                element.write (scratch, value[i])
                bounds[i + 1] = scratch.cursor
            end
            local scratchTotal = scratch.cursor

            if not cache or cache.len ~= len then
                Channel.alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                Varint.write (ch, len)

                Channel.alloc (ch, scratchTotal)
                buffer.copy (ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal
            else
                local cacheRaw = cache.raw
                local cacheBds = cache.bounds
                local dirty = table.create (len)
                local dirtyN = 0

                for i = 1, len do
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff
                    local oldOff = cacheBds[i]
                    local oldLen = cacheBds[i + 1] - oldOff

                    if
                        newLen ~= oldLen
                        or not rangeEqual (scratch.buff, newOff, cacheRaw, oldOff, newLen)
                    then
                        dirtyN += 1
                        dirty[dirtyN] = i
                    end
                end

                if dirtyN == 0 then
                    Channel.alloc (ch, 1)
                    buffer.writeu8 (ch.buff, ch.cursor, FLAG_UNCHANGED)
                    ch.cursor += 1
                    releaseScratch ()
                    return
                end

                Channel.alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                ch.cursor += 1
                Varint.write (ch, dirtyN)

                for j = 1, dirtyN do
                    local i = dirty[j]
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff

                    Varint.write (ch, i - 1)
                    Channel.alloc (ch, newLen)
                    buffer.copy (ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                    ch.cursor += newLen
                end
            end

            -- Cache update (shared by FLAG_FULL and FLAG_DELTA)
            local rawBuf = buffer.create (scratchTotal)
            buffer.copy (rawBuf, 0, scratch.buff, 0, scratchTotal)

            table.freeze (bounds)
            ch.deltas[deltaId] = { raw = rawBuf, bounds = bounds, len = len }
            releaseScratch ()
        end,

        read = function (src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local flag = buffer.readu8 (src, pos)
            local absPos = pos + 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache (deltaId)
                return if cache then table.clone (cache) else {}, 1
            end

            if flag == FLAG_FULL then
                local len, lenBytes = Varint.read (src, absPos)
                absPos += lenBytes

                local result = table.create (len)
                for i = 1, len do
                    local val, n = element.read (src, absPos, refs)
                    result[i] = val
                    absPos += n
                end

                Baseline.setCache (deltaId, result)
                return result, absPos - pos
            end

            local cache = Baseline.getCache (deltaId) :: { any }?
            local result = if cache then table.clone (cache) else {}

            local dirtyN, dnBytes = Varint.read (src, absPos)
            absPos += dnBytes

            for _ = 1, dirtyN do
                local idx, idxBytes = Varint.read (src, absPos)
                absPos += idxBytes

                local val, n = element.read (src, absPos, refs)
                result[idx + 1] = val
                absPos += n
            end

            Baseline.setCache (deltaId, result)
            return result, absPos - pos
        end,
    })
end

function Composite.array (element: Codec<any>): Codec<{ any }>
    return table.freeze ({
        write = function (ch: ChannelState, value: { any }): ()
            local len = #value
            Varint.write (ch, len)
            for i = 1, len do
                element.write (ch, value[i])
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read (src, pos)

            local result = table.create (len)
            local absPos = pos + lenBytes

            for i = 1, len do
                local value, n = element.read (src, absPos, refs)
                result[i] = value
                absPos += n
            end

            return result, absPos - pos
        end,
    })
end

function Composite.map (keyCodec: Codec<any>, valueCodec: Codec<any>): Codec<{ [any]: any }>
    return table.freeze ({
        write = function (ch: ChannelState, value: { [any]: any }): ()
            local count = 0
            for _ in value do
                count += 1
            end

            Varint.write (ch, count)

            for k, v in value do
                keyCodec.write (ch, k)
                valueCodec.write (ch, v)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read (src, pos)

            local result = {}
            local absPos = pos + lenBytes

            for _ = 1, count do
                local k, kn = keyCodec.read (src, absPos, refs)
                absPos += kn
                local v, vn = valueCodec.read (src, absPos, refs)
                absPos += vn
                result[k] = v
            end

            return result, absPos - pos
        end,
    })
end

function Composite.optional (inner: Codec<any>): Codec<any>
    return table.freeze ({
        write = function (ch: ChannelState, value: any): ()
            Channel.alloc (ch, 1)
            buffer.writeu8 (ch.buff, ch.cursor, if value ~= nil then 1 else 0)
            ch.cursor += 1
            if value ~= nil then
                inner.write (ch, value)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            if buffer.readu8 (src, pos) == 0 then
                return nil, 1
            end

            local value, n = inner.read (src, pos + 1, refs)
            return value, 1 + n
        end,
    })
end

return table.freeze (Composite)
