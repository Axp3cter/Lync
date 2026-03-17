--!strict
--!native
-- map and deltaMap codecs.

local Baseline = require (script.Parent.Parent.Parent.internal.Baseline)
local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc
local Shared = require (script.Parent.Shared)
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
local Varint = require (script.Parent.Parent.primitive.Varint)

local rangeEqual = Shared.rangeEqual
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch

local FLAG_DELTA = Shared.FLAG_DELTA
local FLAG_FULL = Shared.FLAG_FULL
local FLAG_UNCHANGED = Shared.FLAG_UNCHANGED

-- Public -----------------------------------------------------------------

local Map = {}

function Map.map (
    keyCodec: Codec<any>,
    valueCodec: Codec<any>,
    maxCount: number?
): Codec<{ [any]: any }>
    local keySize = (keyCodec :: any)._size :: number?
    local valSize = (valueCodec :: any)._size :: number?
    local keyDWrite = (keyCodec :: any)._directWrite
    local valDWrite = (valueCodec :: any)._directWrite
    local keyDRead = (keyCodec :: any)._directRead
    local valDRead = (valueCodec :: any)._directRead

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

                if maxCount and count > maxCount then
                    error (`[Lync] Map count {count} exceeds max {maxCount}`)
                end

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

            if maxCount and count > maxCount then
                error (`[Lync] Map count {count} exceeds max {maxCount}`)
            end

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

-- Delta map: tracks per-key changes. First frame is full, then upserts + removes only.
--
-- Wire format:
--   FLAG_FULL:      u8(1) + varint(count) + [key+value ...]
--   FLAG_UNCHANGED: u8(2)
--   FLAG_DELTA:     u8(0) + varint(upsertN) + [key+value ...] + varint(removeN) + [key ...]
function Map.deltaMap (
    keyCodec: Codec<any>,
    valueCodec: Codec<any>,
    maxCount: number?
): Codec<{ [any]: any }>
    local deltaId = Shared.allocDeltaId ()

    local writeKey = keyCodec.write
    local writeVal = valueCodec.write
    local readKey = keyCodec.read
    local readVal = valueCodec.read

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

                if maxCount and count > maxCount then
                    error (`[Lync] Map count {count} exceeds max {maxCount}`)
                end

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

            local removeN, rmBytes = Varint.read (src, absPos)
            absPos += rmBytes

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

return table.freeze (Map)
