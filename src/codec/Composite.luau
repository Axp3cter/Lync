--!strict
--!optimize 2
-- Struct, deltaStruct, deltaArray, array, map, optional.

local Baseline = require(script.Parent.Parent.core.Baseline)
local Channel  = require(script.Parent.Parent.core.Channel)
local Varint   = require(script.Parent.Varint)
local Types    = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local ceil   = math.ceil
local min    = math.min

local FLAG_DELTA     = 0
local FLAG_FULL      = 1
local FLAG_UNCHANGED = 2

-- State ------------------------------------------------------------------

local _nextDeltaId  = 1
local _scratchStack = {} :: { ChannelState }
local _scratchDepth = 0

-- Private ----------------------------------------------------------------

local function acquireScratch(): ChannelState
    _scratchDepth += 1
    local scratch = _scratchStack[_scratchDepth]
    if not scratch then
        scratch = Channel.create()
        _scratchStack[_scratchDepth] = scratch
    end
    scratch.cursor = 0
    table.clear(scratch.refs)
    return scratch
end

local function releaseScratch(): ()
    _scratchDepth -= 1
end

type Field = {
    key:   string,
    codec: Codec<any>,
}

type DeltaCache = {
    raw:    buffer,
    bounds: { number },
    total:  number,
}

local function rangeEqual(a: buffer, offA: number, b: buffer, offB: number, len: number): boolean
    if len <= 0 then return true end

    local aligned = len - len % 4
    for i = 0, aligned - 4, 4 do
        if buffer.readu32(a, offA + i) ~= buffer.readu32(b, offB + i) then return false end
    end

    for i = aligned, len - 1 do
        if buffer.readu8(a, offA + i) ~= buffer.readu8(b, offB + i) then return false end
    end

    return true
end

-- Shared field extraction used by both struct and deltaStruct.
local function extractFields(schema: { [string]: Codec<any> }): ({ Field }, { string })
    local dataFields = {} :: { Field }
    local boolKeys   = {} :: { string }

    for key, codec in schema do
        if (codec :: any)._isBool then
            table.insert(boolKeys, key)
        else
            table.insert(dataFields, { key = key, codec = codec })
        end
    end

    table.sort(dataFields, function(a: Field, b: Field): boolean return a.key < b.key end)
    table.sort(boolKeys)

    if #dataFields == 0 and #boolKeys == 0 then
        error("[Lync] Schema requires at least one field")
    end

    table.freeze(dataFields)
    table.freeze(boolKeys)

    return dataFields, boolKeys
end

local function packBools(ch: ChannelState, boolKeys: { string }, boolCount: number, value: any): ()
    local boolByteCount = ceil(boolCount / 8)
    Channel.alloc(ch, boolByteCount)
    local b = ch.buff
    local c = ch.cursor

    for byteIdx = 0, boolByteCount - 1 do
        local packed = 0
        local base   = byteIdx * 8
        local limit  = min(8, boolCount - base)

        for bit = 0, limit - 1 do
            if value[boolKeys[base + bit + 1]] then
                packed = bor(packed, lshift(1, bit))
            end
        end

        buffer.writeu8(b, c + byteIdx, packed)
    end

    ch.cursor = c + boolByteCount
end

local function unpackBools(src: buffer, pos: number, boolKeys: { string }, boolCount: number, result: any): number
    local boolByteCount = ceil(boolCount / 8)

    for byteIdx = 0, boolByteCount - 1 do
        local byte  = buffer.readu8(src, pos + byteIdx)
        local base  = byteIdx * 8
        local limit = min(8, boolCount - base)

        for bit = 0, limit - 1 do
            result[boolKeys[base + bit + 1]] = band(byte, lshift(1, bit)) ~= 0
        end
    end

    return boolByteCount
end

-- Public -----------------------------------------------------------------

local Composite = {}

function Composite.struct(schema: { [string]: Codec<any> }): Codec<any>
    local dataFields, boolKeys = extractFields(schema)

    local dataCount     = #dataFields
    local boolCount     = #boolKeys
    local boolByteCount = ceil(boolCount / 8)
    local totalFields   = dataCount + boolCount

    local fixedSize    = boolByteCount
    local isAllFixed   = true
    for i = 1, dataCount do
        local size = (dataFields[i].codec :: any)._size
        if size then
            fixedSize += size
        else
            isAllFixed = false
        end
    end

    return table.freeze({
        _size = if isAllFixed then fixedSize else nil,

        write = function(ch: ChannelState, value: any): ()
            if isAllFixed then
                Channel.alloc(ch, fixedSize)
            end

            for i = 1, dataCount do
                local field = dataFields[i]
                field.codec.write(ch, value[field.key])
            end

            if boolCount > 0 then
                packBools(ch, boolKeys, boolCount, value)
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = table.create(totalFields)
            local total  = 0

            for i = 1, dataCount do
                local field    = dataFields[i]
                local value, n = field.codec.read(src, pos + total, refs)
                result[field.key] = value
                total += n
            end

            if boolCount > 0 then
                total += unpackBools(src, pos + total, boolKeys, boolCount, result)
            end

            return result, total
        end,
    })
end

function Composite.deltaStruct(schema: { [string]: Codec<any> }): Codec<any>
    local dataFields, boolKeys = extractFields(schema)

    local dataCount     = #dataFields
    local boolCount     = #boolKeys
    local hasBools      = boolCount > 0
    local boolByteCount = if hasBools then ceil(boolCount / 8) else 0
    local segCount      = dataCount + (if hasBools then 1 else 0)
    local bitmaskBytes  = ceil(segCount / 8)
    local totalFields   = dataCount + boolCount
    local deltaId       = _nextDeltaId
    _nextDeltaId += 1

    return table.freeze({
        _isDelta = true,

        write = function(ch: ChannelState, value: any): ()
            local cache   = ch.deltas[deltaId] :: DeltaCache?
            local scratch = acquireScratch()

            local bounds = table.create(segCount + 1)
            bounds[1] = 0

            for i = 1, dataCount do
                dataFields[i].codec.write(scratch, value[dataFields[i].key])
                bounds[i + 1] = scratch.cursor
            end

            if hasBools then
                packBools(scratch, boolKeys, boolCount, value)
                bounds[segCount + 1] = scratch.cursor
            end

            local scratchTotal = scratch.cursor

            if not cache then
                Channel.alloc(ch, 1 + scratchTotal)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                buffer.copy(ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal

                local rawBuf = buffer.create(scratchTotal)
                buffer.copy(rawBuf, 0, scratch.buff, 0, scratchTotal)

                -- Reuse bounds directly — already 0-based offsets
                table.freeze(bounds)
                ch.deltas[deltaId] = {
                    raw    = rawBuf,
                    bounds = bounds,
                    total  = scratchTotal,
                } :: DeltaCache

                releaseScratch()
                return
            end

            local cacheRaw   = cache.raw
            local cacheBds   = cache.bounds
            local dirtyCount = 0
            local maskBytes  = table.create(bitmaskBytes, 0)

            for i = 1, segCount do
                local newOff = bounds[i]
                local newLen = bounds[i + 1] - newOff
                local oldOff = cacheBds[i]
                local oldLen = cacheBds[i + 1] - oldOff

                if newLen ~= oldLen or not rangeEqual(scratch.buff, newOff, cacheRaw, oldOff, newLen) then
                    dirtyCount += 1
                    local bitIdx  = i - 1
                    local byteIdx = bitIdx // 8 + 1
                    maskBytes[byteIdx] = bor(maskBytes[byteIdx], lshift(1, bitIdx % 8))
                end
            end

            if dirtyCount == 0 then
                Channel.alloc(ch, 1)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_UNCHANGED)
                ch.cursor += 1
                releaseScratch()
                return
            end

            Channel.alloc(ch, 1 + bitmaskBytes)
            buffer.writeu8(ch.buff, ch.cursor, FLAG_DELTA)
            ch.cursor += 1

            local maskStart = ch.cursor
            for byteIdx = 1, bitmaskBytes do
                buffer.writeu8(ch.buff, maskStart + byteIdx - 1, maskBytes[byteIdx])
            end
            ch.cursor = maskStart + bitmaskBytes

            for i = 1, segCount do
                local bitIdx  = i - 1
                local byteIdx = bitIdx // 8 + 1
                if band(maskBytes[byteIdx], lshift(1, bitIdx % 8)) ~= 0 then
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff
                    Channel.alloc(ch, newLen)
                    buffer.copy(ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                    ch.cursor += newLen
                end
            end

            local rawBuf = buffer.create(scratchTotal)
            buffer.copy(rawBuf, 0, scratch.buff, 0, scratchTotal)

            table.freeze(bounds)
            ch.deltas[deltaId] = {
                raw    = rawBuf,
                bounds = bounds,
                total  = scratchTotal,
            } :: DeltaCache

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag  = buffer.readu8(src, pos)
            local total = 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache(deltaId) :: any
                return if cache then table.clone(cache) else {}, total
            end

            if flag == FLAG_FULL then
                local result = table.create(totalFields)

                for i = 1, dataCount do
                    local val, n = dataFields[i].codec.read(src, pos + total, refs)
                    result[dataFields[i].key] = val
                    total += n
                end

                if hasBools then
                    total += unpackBools(src, pos + total, boolKeys, boolCount, result)
                end

                Baseline.setCache(deltaId, result)
                return result, total
            end

            local cache  = Baseline.getCache(deltaId) :: any
            local result = if cache then table.clone(cache) else {}

            local maskStart = pos + total
            total += bitmaskBytes

            for i = 1, segCount do
                local bitIdx = i - 1
                local byte   = buffer.readu8(src, maskStart + (bitIdx // 8))

                if band(byte, lshift(1, bitIdx % 8)) ~= 0 then
                    if i <= dataCount then
                        local val, n = dataFields[i].codec.read(src, pos + total, refs)
                        result[dataFields[i].key] = val
                        total += n
                    else
                        total += unpackBools(src, pos + total, boolKeys, boolCount, result)
                    end
                end
            end

            Baseline.setCache(deltaId, result)
            return result, total
        end,
    })
end

function Composite.deltaArray(element: Codec<any>): Codec<{ any }>
    local deltaId = _nextDeltaId
    _nextDeltaId += 1

    return table.freeze({
        _isDelta = true,

        write = function(ch: ChannelState, value: { any }): ()
            local len     = #value
            local cache   = ch.deltas[deltaId] :: { raw: buffer, bounds: { number }, len: number }?
            local scratch = acquireScratch()

            local bounds = table.create(len + 1)
            bounds[1] = 0
            for i = 1, len do
                element.write(scratch, value[i])
                bounds[i + 1] = scratch.cursor
            end
            local scratchTotal = scratch.cursor

            if not cache or cache.len ~= len then
                Channel.alloc(ch, 1)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                Varint.write(ch, len)

                Channel.alloc(ch, scratchTotal)
                buffer.copy(ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal

                local rawBuf = buffer.create(scratchTotal)
                buffer.copy(rawBuf, 0, scratch.buff, 0, scratchTotal)

                table.freeze(bounds)
                ch.deltas[deltaId] = { raw = rawBuf, bounds = bounds, len = len }

                releaseScratch()
                return
            end

            local cacheRaw = cache.raw
            local cacheBds = cache.bounds
            local dirty    = table.create(len)
            local dirtyN   = 0

            for i = 1, len do
                local newOff = bounds[i]
                local newLen = bounds[i + 1] - newOff
                local oldOff = cacheBds[i]
                local oldLen = cacheBds[i + 1] - oldOff

                if newLen ~= oldLen or not rangeEqual(scratch.buff, newOff, cacheRaw, oldOff, newLen) then
                    dirtyN += 1
                    dirty[dirtyN] = i
                end
            end

            if dirtyN == 0 then
                Channel.alloc(ch, 1)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_UNCHANGED)
                ch.cursor += 1
                releaseScratch()
                return
            end

            Channel.alloc(ch, 1)
            buffer.writeu8(ch.buff, ch.cursor, FLAG_DELTA)
            ch.cursor += 1
            Varint.write(ch, dirtyN)

            for j = 1, dirtyN do
                local i      = dirty[j]
                local newOff = bounds[i]
                local newLen = bounds[i + 1] - newOff

                Varint.write(ch, i - 1)
                Channel.alloc(ch, newLen)
                buffer.copy(ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                ch.cursor += newLen
            end

            local rawBuf = buffer.create(scratchTotal)
            buffer.copy(rawBuf, 0, scratch.buff, 0, scratchTotal)

            table.freeze(bounds)
            ch.deltas[deltaId] = { raw = rawBuf, bounds = bounds, len = len }
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local flag  = buffer.readu8(src, pos)
            local total = 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache(deltaId)
                return if cache then table.clone(cache) else {}, total
            end

            if flag == FLAG_FULL then
                local len, lenBytes = Varint.read(src, pos + total)
                total += lenBytes

                local result = table.create(len)
                for i = 1, len do
                    local val, n = element.read(src, pos + total, refs)
                    result[i] = val
                    total += n
                end

                Baseline.setCache(deltaId, result)
                return result, total
            end

            local cache  = Baseline.getCache(deltaId) :: { any }?
            local result = if cache then table.clone(cache) else {}

            local dirtyN, dnBytes = Varint.read(src, pos + total)
            total += dnBytes

            for _ = 1, dirtyN do
                local idx, idxBytes = Varint.read(src, pos + total)
                total += idxBytes

                local val, n = element.read(src, pos + total, refs)
                result[idx + 1] = val
                total += n
            end

            Baseline.setCache(deltaId, result)
            return result, total
        end,
    })
end

function Composite.array(element: Codec<any>): Codec<{ any }>
    return table.freeze({
        write = function(ch: ChannelState, value: { any }): ()
            local len = #value
            Varint.write(ch, len)
            for i = 1, len do
                element.write(ch, value[i])
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read(src, pos)

            local result = table.create(len)
            local total  = lenBytes

            for i = 1, len do
                local value, n = element.read(src, pos + total, refs)
                result[i] = value
                total += n
            end

            return result, total
        end,
    })
end

function Composite.map(keyCodec: Codec<any>, valueCodec: Codec<any>): Codec<{ [any]: any }>
    return table.freeze({
        -- Single traversal: serialize KV pairs to scratch counting as we go,
        -- then write count + copy scratch bytes to channel.
        write = function(ch: ChannelState, value: { [any]: any }): ()
            local scratch = acquireScratch()
            local count   = 0

            for k, v in value do
                count += 1
                keyCodec.write(scratch, k)
                valueCodec.write(scratch, v)
            end

            Varint.write(ch, count)

            local scratchLen = scratch.cursor
            if scratchLen > 0 then
                Channel.alloc(ch, scratchLen)
                buffer.copy(ch.buff, ch.cursor, scratch.buff, 0, scratchLen)
                ch.cursor += scratchLen
            end

            releaseScratch()
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read(src, pos)

            local result = {}
            local total  = lenBytes

            for _ = 1, count do
                local k, kn = keyCodec.read(src, pos + total, refs)
                total += kn
                local v, vn = valueCodec.read(src, pos + total, refs)
                total += vn
                result[k] = v
            end

            return result, total
        end,
    })
end

function Composite.optional(inner: Codec<any>): Codec<any>
    return table.freeze({
        write = function(ch: ChannelState, value: any): ()
            Channel.alloc(ch, 1)
            if value ~= nil then
                buffer.writeu8(ch.buff, ch.cursor, 1)
                ch.cursor += 1
                inner.write(ch, value)
            else
                buffer.writeu8(ch.buff, ch.cursor, 0)
                ch.cursor += 1
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if buffer.readu8(src, pos) == 0 then return nil, 1 end

            local value, n = inner.read(src, pos + 1, refs)
            return value, 1 + n
        end,
    })
end

return table.freeze(Composite)
