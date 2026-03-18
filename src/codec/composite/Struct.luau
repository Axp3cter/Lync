--!strict
--!native
-- struct and deltaStruct codecs.

local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
type InternalCodec<T> = Types.InternalCodec<T>

local alloc = Channel.alloc
local extractFields = Shared.extractFields
local packBools = Shared.packBools
local unpackBools = Shared.unpackBools
local rangeEqual = Shared.rangeEqual
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch

local FLAG_DELTA = Shared.FLAG_DELTA
local FLAG_FULL = Shared.FLAG_FULL
local FLAG_UNCHANGED = Shared.FLAG_UNCHANGED

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local ceil = math.ceil
local min = math.min

type DeltaCache = {
    raw: buffer,
    bounds: { number },
    total: number,
}

-- Public --------------------------------------------------------------

local Struct = {}

function Struct.struct(schema: { [string]: Codec<any> }): Codec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)

    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolByteCount = ceil(boolCount / 8)
    local hasBools = boolCount > 0

    local canDirect = true
    local fixedSize = boolByteCount
    local isAllFixed = true

    local directWrites = table.create(dataCount) :: { any }
    local directReads = table.create(dataCount) :: { any }
    local fieldSizes = table.create(dataCount) :: { number }

    for i = 1, dataCount do
        local codec = dataCodecs[i] :: InternalCodec<any>
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

    if canDirect and isAllFixed then
        table.freeze(directWrites)
        table.freeze(directReads)
        table.freeze(fieldSizes)

        local function directWriteBody(b: buffer, c: number, value: any): ()
            for i = 1, dataCount do
                directWrites[i](b, c, value[dataKeys[i]])
                c += fieldSizes[i]
            end
            if hasBools then
                for byteIdx = 0, boolByteCount - 1 do
                    local packed = 0
                    local base = byteIdx * 8
                    local limit = min(8, boolCount - base)
                    for bit = 0, limit - 1 do
                        if value[boolKeys[base + bit + 1]] then
                            packed = bor(packed, lshift(1, bit))
                        end
                    end
                    buffer.writeu8(b, c + byteIdx, packed)
                end
            end
        end

        local function directReadBody(b: buffer, pos: number): any
            local result = {}
            local c = pos
            for i = 1, dataCount do
                result[dataKeys[i]] = directReads[i](b, c)
                c += fieldSizes[i]
            end
            if hasBools then
                for byteIdx = 0, boolByteCount - 1 do
                    local byte = buffer.readu8(b, c + byteIdx)
                    local base = byteIdx * 8
                    local limit = min(8, boolCount - base)
                    for bit = 0, limit - 1 do
                        result[boolKeys[base + bit + 1]] = band(byte, lshift(1, bit)) ~= 0
                    end
                end
            end
            return result
        end

        return table.freeze({
            _size = fixedSize,
            _directWrite = directWriteBody,
            _directRead = directReadBody,

            write = function(ch: ChannelState, value: any): ()
                local c = ch.cursor
                if c + fixedSize > ch.size then
                    alloc(ch, fixedSize)
                end
                directWriteBody(ch.buff, c, value)
                ch.cursor = c + fixedSize
            end,
            read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
                return directReadBody(src, pos), fixedSize
            end,
        })
    end

    local writeFns = table.create(dataCount) :: { any }
    local readFns = table.create(dataCount) :: { any }
    for i = 1, dataCount do
        writeFns[i] = dataCodecs[i].write
        readFns[i] = dataCodecs[i].read
    end
    table.freeze(writeFns)
    table.freeze(readFns)

    return table.freeze({
        _size = if isAllFixed then fixedSize else nil,

        write = function(ch: ChannelState, value: any): ()
            if isAllFixed then
                alloc(ch, fixedSize)
            end

            for i = 1, dataCount do
                writeFns[i](ch, value[dataKeys[i]])
            end

            if hasBools then
                packBools(ch, boolKeys, boolCount, value)
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = {}
            local absPos = pos

            for i = 1, dataCount do
                local value, n = readFns[i](src, absPos, refs)
                result[dataKeys[i]] = value
                absPos += n
            end

            if hasBools then
                absPos += unpackBools(src, absPos, boolKeys, boolCount, result)
            end

            return result, absPos - pos
        end,
    })
end

function Struct.deltaStruct(schema: { [string]: Codec<any> }): Codec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)

    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolByteCount = ceil(boolCount / 8)
    local segCount = dataCount + (if boolCount > 0 then 1 else 0)
    local bitmaskBytes = ceil(segCount / 8)
    local deltaId = Shared.allocDeltaId()

    -- Scratch bounds reused every frame(only cloned into cache)
    local _scratchBounds = table.create(segCount + 1) :: { number }
    _scratchBounds[1] = 0

    local writeFns = table.create(dataCount) :: { any }
    local readFns = table.create(dataCount) :: { any }
    for i = 1, dataCount do
        writeFns[i] = dataCodecs[i].write
        readFns[i] = dataCodecs[i].read
    end
    table.freeze(writeFns)
    table.freeze(readFns)

    local scratchDirect = true
    local scratchDirectWrites = table.create(dataCount) :: { any }
    local scratchFieldSizes = table.create(dataCount) :: { number }
    local scratchFieldOffsets = table.create(dataCount) :: { number }
    local scratchDataTotal = 0

    for i = 1, dataCount do
        local codec = dataCodecs[i] :: InternalCodec<any>
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

    return table.freeze({
        _isDelta = true,

        write = function(ch: ChannelState, value: any): ()
            local cache = ch.deltas[deltaId] :: DeltaCache?
            local scratch = acquireScratch()

            local bounds = _scratchBounds
            bounds[1] = 0

            if scratchDirect then
                if not scratchSkipAlloc then
                    alloc(scratch, scratchTotalFixed)
                end
                local b = scratch.buff

                for i = 1, dataCount do
                    scratchDirectWrites[i](b, scratchFieldOffsets[i], value[dataKeys[i]])
                    bounds[i + 1] = scratchFieldOffsets[i] + scratchFieldSizes[i]
                end
                scratch.cursor = scratchDataTotal

                if boolCount > 0 then
                    packBools(scratch, boolKeys, boolCount, value)
                    bounds[segCount + 1] = scratch.cursor
                end
            else
                for i = 1, dataCount do
                    writeFns[i](scratch, value[dataKeys[i]])
                    bounds[i + 1] = scratch.cursor
                end

                if boolCount > 0 then
                    packBools(scratch, boolKeys, boolCount, value)
                    bounds[segCount + 1] = scratch.cursor
                end
            end

            local scratchTotal = scratch.cursor

            -- FLAG_FULL: first frame, no cache exists yet
            if not cache then
                alloc(ch, 1 + scratchTotal)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_FULL)
                ch.cursor += 1
                buffer.copy(ch.buff, ch.cursor, scratch.buff, 0, scratchTotal)
                ch.cursor += scratchTotal

            -- FLAG_UNCHANGED: entire buffer is byte-identical to cache
            elseif
                scratchTotal == cache.total
                and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchTotal)
            then
                alloc(ch, 1)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_UNCHANGED)
                ch.cursor += 1
                releaseScratch()
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
                        or not rangeEqual(scratch.buff, newOff, cacheRaw, oldOff, newLen)
                    then
                        mask = bor(mask, lshift(1, i - 1))
                    end
                end

                alloc(ch, 2)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_DELTA)
                buffer.writeu8(ch.buff, ch.cursor + 1, mask)
                ch.cursor += 2

                for i = 1, segCount do
                    if band(mask, lshift(1, i - 1)) ~= 0 then
                        local newOff = bounds[i]
                        local newLen = bounds[i + 1] - newOff
                        alloc(ch, newLen)
                        buffer.copy(ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                        ch.cursor += newLen
                    end
                end
            else
                local maskBuf = table.create(bitmaskBytes, 0)
                local cacheRaw = cache.raw
                local cacheBds = cache.bounds

                for i = 1, segCount do
                    local newOff = bounds[i]
                    local newLen = bounds[i + 1] - newOff
                    local oldOff = cacheBds[i]
                    local oldLen = cacheBds[i + 1] - oldOff

                    if
                        newLen ~= oldLen
                        or not rangeEqual(scratch.buff, newOff, cacheRaw, oldOff, newLen)
                    then
                        local bitIdx = i - 1
                        local byteIdx = bitIdx // 8 + 1
                        maskBuf[byteIdx] = bor(maskBuf[byteIdx], lshift(1, bitIdx % 8))
                    end
                end

                alloc(ch, 1 + bitmaskBytes)
                buffer.writeu8(ch.buff, ch.cursor, FLAG_DELTA)
                ch.cursor += 1

                local maskStart = ch.cursor
                for byteIdx = 1, bitmaskBytes do
                    buffer.writeu8(ch.buff, maskStart + byteIdx - 1, maskBuf[byteIdx])
                end
                ch.cursor = maskStart + bitmaskBytes

                for i = 1, segCount do
                    local bitIdx = i - 1
                    local byteIdx = bitIdx // 8 + 1
                    if band(maskBuf[byteIdx], lshift(1, bitIdx % 8)) ~= 0 then
                        local newOff = bounds[i]
                        local newLen = bounds[i + 1] - newOff
                        alloc(ch, newLen)
                        buffer.copy(ch.buff, ch.cursor, scratch.buff, newOff, newLen)
                        ch.cursor += newLen
                    end
                end
            end

            local rawBuf = buffer.create(scratchTotal)
            buffer.copy(rawBuf, 0, scratch.buff, 0, scratchTotal)

            local cacheBounds = table.clone(bounds)
            table.freeze(cacheBounds)
            ch.deltas[deltaId] = {
                raw = rawBuf,
                bounds = cacheBounds,
                total = scratchTotal,
            } :: DeltaCache

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = buffer.readu8(src, pos)
            local absPos = pos + 1

            if flag == FLAG_UNCHANGED then
                local cache = Baseline.getCache(deltaId) :: any
                return if cache then table.clone(cache) else {}, 1
            end

            if flag == FLAG_FULL then
                local result = {}

                for i = 1, dataCount do
                    local val, n = readFns[i](src, absPos, refs)
                    result[dataKeys[i]] = val
                    absPos += n
                end

                if boolCount > 0 then
                    absPos += unpackBools(src, absPos, boolKeys, boolCount, result)
                end

                Baseline.setCache(deltaId, result)
                return result, absPos - pos
            end

            local cache = Baseline.getCache(deltaId) :: any
            local result = if cache then table.clone(cache) else {}

            local maskStart = absPos
            absPos += bitmaskBytes

            for i = 1, segCount do
                local bitIdx = i - 1
                local byte = buffer.readu8(src, maskStart + (bitIdx // 8))

                if band(byte, lshift(1, bitIdx % 8)) ~= 0 then
                    if i <= dataCount then
                        local val, n = readFns[i](src, absPos, refs)
                        result[dataKeys[i]] = val
                        absPos += n
                    else
                        absPos += unpackBools(src, absPos, boolKeys, boolCount, result)
                    end
                end
            end

            Baseline.setCache(deltaId, result)
            return result, absPos - pos
        end,
    })
end

return table.freeze(Struct)
