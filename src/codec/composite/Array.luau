--!strict
--!native
-- array and deltaArray codecs.

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

local Array = {}

function Array.deltaArray (element: Codec<any>, maxCount: number?): Codec<{ any }>
    local deltaId = Shared.allocDeltaId ()

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

                if maxCount and len > maxCount then
                    error (`[Lync] Array count {len} exceeds max {maxCount}`)
                end

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

function Array.array (element: Codec<any>, maxCount: number?): Codec<{ any }>
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

                if maxCount and len > maxCount then
                    error (`[Lync] Array count {len} exceeds max {maxCount}`)
                end

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

            if maxCount and len > maxCount then
                error (`[Lync] Array count {len} exceeds max {maxCount}`)
            end

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

return table.freeze (Array)
