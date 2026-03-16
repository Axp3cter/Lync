--!strict
--!native
-- Struct, deltaStruct, deltaArray, deltaMap, array, map, optional.

local Baseline = require (script.Parent.Parent.core.Baseline)
local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
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
    alloc (ch, boolByteCount)
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
    local hasBools = boolCount > 0

    -- Check if all data fields support direct buffer writes.

    local canDirect = true
    local fixedSize = boolByteCount
    local isAllFixed = true

    local directWrites = table.create (dataCount) :: { any }
    local directReads = table.create (dataCount) :: { any }
    local fieldSizes = table.create (dataCount) :: { number }

    for i = 1, dataCount do
        local codec = dataCodecs[i] :: any
        local size = codec._size
        local dw = codec._directWrite
        local dr = codec._directRead

        if size then
            fixedSize += size
            fieldSizes[i] = size
        else
            isAllFixed = false
            canDirect = false
        end

        if not (dw and dr and size) then
            canDirect = false
        else
            directWrites[i] = dw
            directReads[i] = dr
        end
    end

    -- Specialized path: all fields have known size and direct buffer access.
    if canDirect and isAllFixed then
        table.freeze (directWrites)
        table.freeze (directReads)
        table.freeze (fieldSizes)

        local function directWriteBody (b: buffer, c: number, value: any): ()
            for i = 1, dataCount do
                directWrites[i] (b, c, value[dataKeys[i]])
                c += fieldSizes[i]
            end
            if hasBools then
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
            end
        end

        local function directReadBody (b: buffer, pos: number): any
            local result = {}
            local c = pos
            for i = 1, dataCount do
                result[dataKeys[i]] = directReads[i] (b, c)
                c += fieldSizes[i]
            end
            if hasBools then
                for byteIdx = 0, boolByteCount - 1 do
                    local byte = buffer.readu8 (b, c + byteIdx)
                    local base = byteIdx * 8
                    local limit = min (8, boolCount - base)
                    for bit = 0, limit - 1 do
                        result[boolKeys[base + bit + 1]] = band (byte, lshift (1, bit)) ~= 0
                    end
                end
            end
            return result
        end

        return table.freeze ({
            _size = fixedSize,
            _directWrite = directWriteBody,
            _directRead = directReadBody,

            write = function (ch: ChannelState, value: any): ()
                local c = ch.cursor
                if c + fixedSize > ch.size then
                    alloc (ch, fixedSize)
                end
                directWriteBody (ch.buff, c, value)
                ch.cursor = c + fixedSize
            end,
            read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
                return directReadBody (src, pos), fixedSize
            end,
        })
    end

    -- Generic fallback: variable-size fields or missing _directWrite.
    -- Extract write/read functions into parallel arrays at define time.
    local writeFns = table.create (dataCount) :: { any }
    local readFns = table.create (dataCount) :: { any }
    for i = 1, dataCount do
        writeFns[i] = dataCodecs[i].write
        readFns[i] = dataCodecs[i].read
    end
    table.freeze (writeFns)
    table.freeze (readFns)

    return table.freeze ({
        _size = if isAllFixed then fixedSize else nil,

        write = function (ch: ChannelState, value: any): ()
            if isAllFixed then
                alloc (ch, fixedSize)
            end

            for i = 1, dataCount do
                writeFns[i] (ch, value[dataKeys[i]])
            end

            if hasBools then
                packBools (ch, boolKeys, boolCount, value)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = {}
            local absPos = pos

            for i = 1, dataCount do
                local value, n = readFns[i] (src, absPos, refs)
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

    -- Extract write/read functions at define time.
    local writeFns = table.create (dataCount) :: { any }
    local readFns = table.create (dataCount) :: { any }
    for i = 1, dataCount do
        writeFns[i] = dataCodecs[i].write
        readFns[i] = dataCodecs[i].read
    end
    table.freeze (writeFns)
    table.freeze (readFns)

    -- Check if all fields support direct buffer writes into scratch.
    local scratchDirect = true
    local scratchDirectWrites = table.create (dataCount) :: { any }
    local scratchFieldSizes = table.create (dataCount) :: { number }
    local scratchFieldOffsets = table.create (dataCount) :: { number }
    local scratchDataTotal = 0

    for i = 1, dataCount do
        local codec = dataCodecs[i] :: any
        local size = codec._size
        local dw = codec._directWrite
        if size and dw then
            scratchDirectWrites[i] = dw
            scratchFieldSizes[i] = size
            scratchFieldOffsets[i] = scratchDataTotal
            scratchDataTotal += size
        else
            scratchDirect = false
            break
        end
    end

    local scratchTotalFixed = scratchDataTotal + boolByteCount

    -- Skip scratch alloc at runtime when the total fits in the initial
    -- 1024-byte scratch buffer.
    local scratchSkipAlloc = scratchDirect and scratchTotalFixed <= 1024

    return table.freeze ({
        _isDelta = true,

        write = function (ch: ChannelState, value: any): ()
            local cache = ch.deltas[deltaId] :: DeltaCache?
            local scratch = acquireScratch ()

            local bounds = _scratchBounds
            bounds[1] = 0

            -- Scratch write: direct path when all fields support it
            if scratchDirect then
                if not scratchSkipAlloc then
                    alloc (scratch, scratchTotalFixed)
                end
                local b = scratch.buff

                for i = 1, dataCount do
                    scratchDirectWrites[i] (b, scratchFieldOffsets[i], value[dataKeys[i]])
                    bounds[i + 1] = scratchFieldOffsets[i] + scratchFieldSizes[i]
                end
                scratch.cursor = scratchDataTotal

                if boolCount > 0 then
                    packBools (scratch, boolKeys, boolCount, value)
                    bounds[segCount + 1] = scratch.cursor
                end
            else
                for i = 1, dataCount do
                    writeFns[i] (scratch, value[dataKeys[i]])
                    bounds[i + 1] = scratch.cursor
                end

                if boolCount > 0 then
                    packBools (scratch, boolKeys, boolCount, value)
                    bounds[segCount + 1] = scratch.cursor
                end
            end

            local scratchTotal = scratch.cursor

            -- FLAG_FULL: first frame, no cache exists yet
            if not cache then
                alloc (ch, 1 + scratchTotal)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                buffer.copy (ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal

            -- FLAG_UNCHANGED: entire buffer is byte-identical to cache
            elseif
                scratchTotal == cache.total
                and rangeEqual (scratch.buff, 0, cache.raw, 0, scratchTotal)
            then
                alloc (ch, 1)
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

                alloc (ch, 2)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                buffer.writeu8 (ch.buff, ch.cursor + 1, mask)
                ch.cursor += 2

                for i = 1, segCount do
                    if band (mask, lshift (1, i - 1)) ~= 0 then
                        local newOff = bounds[i]
                        local newLen = bounds[i + 1] - newOff
                        alloc (ch, newLen)
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

                alloc (ch, 1 + bitmaskBytes)
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
                        alloc (ch, newLen)
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
                    local val, n = readFns[i] (src, absPos, refs)
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
                        local val, n = readFns[i] (src, absPos, refs)
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

    -- Extract write/read functions at define time.
    local writeElement = element.write
    local readElement = element.read

    -- Check if element supports direct buffer writes into scratch.
    local elemSize = (element :: any)._size :: number?
    local elemDirect = (element :: any)._directWrite
    local elemDRead = (element :: any)._directRead

    return table.freeze ({
        _isDelta = true,

        write = function (ch: ChannelState, value: { any }): ()
            local len = #value
            local cache = ch.deltas[deltaId] :: { raw: buffer, bounds: { number }, len: number }?
            local scratch = acquireScratch ()

            local bounds = table.create (len + 1)
            bounds[1] = 0

            -- Scratch write: direct path when element supports it
            if elemDirect and elemSize then
                local totalBytes = len * elemSize
                alloc (scratch, totalBytes)
                local b = scratch.buff
                local c = 0
                for i = 1, len do
                    elemDirect (b, c, value[i])
                    c += elemSize
                    bounds[i + 1] = c
                end
                scratch.cursor = totalBytes
            else
                for i = 1, len do
                    writeElement (scratch, value[i])
                    bounds[i + 1] = scratch.cursor
                end
            end

            local scratchTotal = scratch.cursor

            if not cache or cache.len ~= len then
                alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                Varint.write (ch, len)

                alloc (ch, scratchTotal)
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
                    alloc (ch, 1)
                    buffer.writeu8 (ch.buff, ch.cursor, FLAG_UNCHANGED)
                    ch.cursor += 1
                    releaseScratch ()
                    return
                end

                alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                ch.cursor += 1
                Varint.write (ch, dirtyN)

                for j = 1, dirtyN do
                    local i = dirty[j]
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff

                    Varint.write (ch, i - 1)
                    alloc (ch, newLen)
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

                -- Direct read path
                if elemDRead and elemSize then
                    for i = 1, len do
                        result[i] = elemDRead (src, absPos)
                        absPos += elemSize
                    end
                else
                    for i = 1, len do
                        local val, n = readElement (src, absPos, refs)
                        result[i] = val
                        absPos += n
                    end
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

                if elemDRead and elemSize then
                    result[idx + 1] = elemDRead (src, absPos)
                    absPos += elemSize
                else
                    local val, n = readElement (src, absPos, refs)
                    result[idx + 1] = val
                    absPos += n
                end
            end

            Baseline.setCache (deltaId, result)
            return result, absPos - pos
        end,
    })
end

function Composite.array (element: Codec<any>): Codec<{ any }>
    local elementSize = (element :: any)._size :: number?
    local directWrite = (element :: any)._directWrite
    local directRead = (element :: any)._directRead

    -- Specialized path: element has known size + direct buffer access.
    -- Writes the entire array with a single alloc and cursor update.
    if elementSize and directWrite and directRead then
        return table.freeze ({
            write = function (ch: ChannelState, value: { any }): ()
                local len = #value
                Varint.write (ch, len)
                if len == 0 then
                    return
                end

                local totalBytes = len * elementSize
                local c = ch.cursor
                if c + totalBytes > ch.size then
                    alloc (ch, totalBytes)
                end

                local b = ch.buff
                for i = 1, len do
                    directWrite (b, c, value[i])
                    c += elementSize
                end
                ch.cursor = c
            end,
            read = function (src: buffer, pos: number, _refs: { Instance }?): ({ any }, number)
                local len, lenBytes = Varint.read (src, pos)

                local result = table.create (len)
                local c = pos + lenBytes

                for i = 1, len do
                    result[i] = directRead (src, c)
                    c += elementSize
                end

                return result, c - pos
            end,
        })
    end

    -- Generic fallback: variable-size or no direct access.
    local writeElement = element.write
    local readElement = element.read

    return table.freeze ({
        write = function (ch: ChannelState, value: { any }): ()
            local len = #value
            Varint.write (ch, len)
            if elementSize and len > 0 then
                alloc (ch, len * elementSize)
            end
            for i = 1, len do
                writeElement (ch, value[i])
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read (src, pos)

            local result = table.create (len)
            local absPos = pos + lenBytes

            for i = 1, len do
                local value, n = readElement (src, absPos, refs)
                result[i] = value
                absPos += n
            end

            return result, absPos - pos
        end,
    })
end

function Composite.map (keyCodec: Codec<any>, valueCodec: Codec<any>): Codec<{ [any]: any }>
    local keySize = (keyCodec :: any)._size :: number?
    local valSize = (valueCodec :: any)._size :: number?
    local keyDWrite = (keyCodec :: any)._directWrite
    local valDWrite = (valueCodec :: any)._directWrite
    local keyDRead = (keyCodec :: any)._directRead
    local valDRead = (valueCodec :: any)._directRead

    -- Specialized path: both key and value have fixed size + direct access
    if keySize and valSize and keyDWrite and valDWrite and keyDRead and valDRead then
        local entrySize = keySize + valSize

        return table.freeze ({
            write = function (ch: ChannelState, value: { [any]: any }): ()
                local count = 0
                for _ in value do
                    count += 1
                end

                Varint.write (ch, count)

                if count > 0 then
                    local totalBytes = count * entrySize
                    local c = ch.cursor
                    if c + totalBytes > ch.size then
                        alloc (ch, totalBytes)
                    end

                    local b = ch.buff
                    for k, v in value do
                        keyDWrite (b, c, k)
                        valDWrite (b, c + keySize, v)
                        c += entrySize
                    end
                    ch.cursor = c
                end
            end,
            read = function (
                src: buffer,
                pos: number,
                _refs: { Instance }?
            ): ({ [any]: any }, number)
                local count, lenBytes = Varint.read (src, pos)

                local result = {}
                local c = pos + lenBytes

                for _ = 1, count do
                    local k = keyDRead (src, c)
                    local v = valDRead (src, c + keySize)
                    result[k] = v
                    c += entrySize
                end

                return result, c - pos
            end,
        })
    end

    -- Extract write/read functions at define time.
    local writeKey = keyCodec.write
    local writeVal = valueCodec.write
    local readKey = keyCodec.read
    local readVal = valueCodec.read

    return table.freeze ({
        write = function (ch: ChannelState, value: { [any]: any }): ()
            local count = 0
            for _ in value do
                count += 1
            end

            Varint.write (ch, count)

            for k, v in value do
                writeKey (ch, k)
                writeVal (ch, v)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read (src, pos)

            local result = {}
            local absPos = pos + lenBytes

            for _ = 1, count do
                local k, kn = readKey (src, absPos, refs)
                absPos += kn
                local v, vn = readVal (src, absPos, refs)
                absPos += vn
                result[k] = v
            end

            return result, absPos - pos
        end,
    })
end

--[[
    Delta map: tracks per-key changes between frames.
    First frame sends all entries (FLAG_FULL). Subsequent frames send only
    upserts (new or changed key-value pairs) and removes (deleted keys).
    If nothing changed, sends a single FLAG_UNCHANGED byte.

    Wire format:
        FLAG_FULL:      u8(1) + varint(count) + [key+value ...]
        FLAG_UNCHANGED: u8(2)
        FLAG_DELTA:     u8(0) + varint(upsertN) + [key+value ...] + varint(removeN) + [key ...]
]]
function Composite.deltaMap (keyCodec: Codec<any>, valueCodec: Codec<any>): Codec<{ [any]: any }>
    local deltaId = _nextDeltaId
    _nextDeltaId += 1

    -- Extract write/read functions at define time.
    local writeKey = keyCodec.write
    local writeVal = valueCodec.write
    local readKey = keyCodec.read
    local readVal = valueCodec.read

    -- Check if key/value support direct buffer writes into scratch.
    local keySize = (keyCodec :: any)._size :: number?
    local valSize = (valueCodec :: any)._size :: number?
    local keyDWrite = (keyCodec :: any)._directWrite
    local valDWrite = (valueCodec :: any)._directWrite
    local keyDRead = (keyCodec :: any)._directRead
    local valDRead = (valueCodec :: any)._directRead
    local scratchDirect = keySize and valSize and keyDWrite and valDWrite
    local entrySize = if keySize and valSize then keySize + valSize else nil

    return table.freeze ({
        _isDelta = true,

        write = function (ch: ChannelState, value: { [any]: any }): ()
            local scratch = acquireScratch ()

            type EntryBounds = { keyOff: number, keyLen: number, valOff: number, valLen: number }

            local entries = {} :: { EntryBounds }
            local keyLookup = {} :: { [string]: number }
            local entryCount = 0

            if scratchDirect then
                -- Direct scratch write: write key+value straight to buffer
                for k, v in value do
                    entryCount += 1
                    local c = scratch.cursor
                    alloc (scratch, entrySize :: number)
                    local b = scratch.buff
                    keyDWrite (b, c, k)
                    valDWrite (b, c + (keySize :: number), v)
                    scratch.cursor = c + (entrySize :: number)

                    entries[entryCount] = {
                        keyOff = c,
                        keyLen = keySize :: number,
                        valOff = c + (keySize :: number),
                        valLen = valSize :: number,
                    }

                    local keyId = buffer.readstring (b, c, keySize :: number)
                    keyLookup[keyId] = entryCount
                end
            else
                for k, v in value do
                    entryCount += 1
                    local keyStart = scratch.cursor
                    writeKey (scratch, k)
                    local keyEnd = scratch.cursor
                    writeVal (scratch, v)
                    local valEnd = scratch.cursor

                    entries[entryCount] = {
                        keyOff = keyStart,
                        keyLen = keyEnd - keyStart,
                        valOff = keyEnd,
                        valLen = valEnd - keyEnd,
                    }

                    local keyId = buffer.readstring (scratch.buff, keyStart, keyEnd - keyStart)
                    keyLookup[keyId] = entryCount
                end
            end

            local scratchTotal = scratch.cursor

            type DeltaMapCache = {
                raw: buffer,
                entries: { EntryBounds },
                keyLookup: { [string]: number },
                count: number,
            }

            local cache = ch.deltas[deltaId] :: DeltaMapCache?

            -- FLAG_FULL: no cache yet
            if not cache then
                alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                Varint.write (ch, entryCount)

                if scratchTotal > 0 then
                    alloc (ch, scratchTotal)
                    buffer.copy (ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                    ch.cursor += scratchTotal
                end
            else
                -- Diff against cache
                local cacheRaw = cache.raw
                local cacheEntries = cache.entries
                local cacheLookup = cache.keyLookup

                local upsertKeys = {} :: { number }
                local upsertN = 0

                for keyId, idx in keyLookup do
                    local oldIdx = cacheLookup[keyId]
                    if not oldIdx then
                        upsertN += 1
                        upsertKeys[upsertN] = idx
                    else
                        local newE = entries[idx]
                        local oldE = cacheEntries[oldIdx]
                        if
                            newE.valLen ~= oldE.valLen
                            or not rangeEqual (
                                scratch.buff,
                                newE.valOff,
                                cacheRaw,
                                oldE.valOff,
                                newE.valLen
                            )
                        then
                            upsertN += 1
                            upsertKeys[upsertN] = idx
                        end
                    end
                end

                local removeKeyIds = {} :: { string }
                local removeN = 0

                for keyId in cacheLookup do
                    if not keyLookup[keyId] then
                        removeN += 1
                        removeKeyIds[removeN] = keyId
                    end
                end

                if upsertN == 0 and removeN == 0 then
                    alloc (ch, 1)
                    buffer.writeu8 (ch.buff, ch.cursor, FLAG_UNCHANGED)
                    ch.cursor += 1
                    releaseScratch ()
                    return
                end

                alloc (ch, 1)
                buffer.writeu8 (ch.buff, ch.cursor, FLAG_DELTA)
                ch.cursor += 1

                Varint.write (ch, upsertN)
                for i = 1, upsertN do
                    local e = entries[upsertKeys[i]]
                    local totalLen = e.keyLen + e.valLen
                    alloc (ch, totalLen)
                    buffer.copy (ch.buff, ch.cursor, scratch.buff, e.keyOff, totalLen)
                    ch.cursor += totalLen
                end

                Varint.write (ch, removeN)
                for i = 1, removeN do
                    local keyId = removeKeyIds[i]
                    local oldIdx = cacheLookup[keyId]
                    local oldE = cacheEntries[oldIdx]
                    alloc (ch, oldE.keyLen)
                    buffer.copy (ch.buff, ch.cursor, cacheRaw, oldE.keyOff, oldE.keyLen)
                    ch.cursor += oldE.keyLen
                end
            end

            local rawBuf = buffer.create (scratchTotal)
            if scratchTotal > 0 then
                buffer.copy (rawBuf, 0, scratch.buff, 0, scratchTotal)
            end

            ch.deltas[deltaId] = {
                raw = rawBuf,
                entries = entries,
                keyLookup = keyLookup,
                count = entryCount,
            }

            releaseScratch ()
        end,

        read = function (src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local flag = buffer.readu8 (src, pos)
            local absPos = pos + 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache (deltaId)
                return if cache then table.clone (cache) else {}, 1
            end

            if flag == FLAG_FULL then
                local count, lenBytes = Varint.read (src, absPos)
                absPos += lenBytes

                local result = {}

                if keyDRead and valDRead and keySize and valSize then
                    for _ = 1, count do
                        local k = keyDRead (src, absPos)
                        local v = valDRead (src, absPos + keySize)
                        result[k] = v
                        absPos += entrySize :: number
                    end
                else
                    for _ = 1, count do
                        local k, kn = readKey (src, absPos, refs)
                        absPos += kn
                        local v, vn = readVal (src, absPos, refs)
                        absPos += vn
                        result[k] = v
                    end
                end

                Baseline.setCache (deltaId, result)
                return result, absPos - pos
            end

            local cache = Baseline.getCache (deltaId) :: { [any]: any }?
            local result = if cache then table.clone (cache) else {}

            local upsertN, unBytes = Varint.read (src, absPos)
            absPos += unBytes

            for _ = 1, upsertN do
                local k, kn = readKey (src, absPos, refs)
                absPos += kn
                local v, vn = readVal (src, absPos, refs)
                absPos += vn
                result[k] = v
            end

            local removeN, rnBytes = Varint.read (src, absPos)
            absPos += rnBytes

            for _ = 1, removeN do
                local k, kn = readKey (src, absPos, refs)
                absPos += kn
                result[k] = nil
            end

            Baseline.setCache (deltaId, result)
            return result, absPos - pos
        end,
    })
end

function Composite.optional (inner: Codec<any>): Codec<any>
    local innerSize = (inner :: any)._size :: number?
    local innerDWrite = (inner :: any)._directWrite
    local innerDRead = (inner :: any)._directRead

    -- Specialized path: inner has fixed size + direct access
    if innerSize and innerDWrite and innerDRead then
        local presentSize = 1 + innerSize

        return table.freeze ({
            write = function (ch: ChannelState, value: any): ()
                local c = ch.cursor
                if value ~= nil then
                    if c + presentSize > ch.size then
                        alloc (ch, presentSize)
                    end
                    local b = ch.buff
                    buffer.writeu8 (b, c, 1)
                    innerDWrite (b, c + 1, value)
                    ch.cursor = c + presentSize
                else
                    if c + 1 > ch.size then
                        alloc (ch, 1)
                    end
                    buffer.writeu8 (ch.buff, c, 0)
                    ch.cursor = c + 1
                end
            end,
            read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
                if buffer.readu8 (src, pos) == 0 then
                    return nil, 1
                end
                return innerDRead (src, pos + 1), presentSize
            end,
        })
    end

    -- Generic fallback: extract inner write/read
    local writeInner = inner.write
    local readInner = inner.read

    return table.freeze ({
        write = function (ch: ChannelState, value: any): ()
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc (ch, 1)
            end
            buffer.writeu8 (ch.buff, c, if value ~= nil then 1 else 0)
            ch.cursor = c + 1
            if value ~= nil then
                writeInner (ch, value)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            if buffer.readu8 (src, pos) == 0 then
                return nil, 1
            end

            local value, n = readInner (src, pos + 1, refs)
            return value, 1 + n
        end,
    })
end

return table.freeze (Composite)
