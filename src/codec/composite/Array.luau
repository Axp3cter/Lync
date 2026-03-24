--!strict
--!native
-- array and deltaArray codecs.

local Types  = require(script.Parent.Parent.Parent.Types)
local Base   = require(script.Parent.Parent.Base)
local Varint = require(script.Parent.Parent.primitive.Varint)
local Shared = require(script.Parent.Shared)

-- Private -------------------------------------------------------------

local alloc   = Base.alloc
local writeu8 = buffer.writeu8
local readu8  = buffer.readu8
local band    = bit32.band
local bor     = bit32.bor
local lshift  = bit32.lshift

local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual     = Shared.rangeEqual
local allocDeltaId   = Shared.allocDeltaId

local DELTA_UNCHANGED    = Shared.DELTA_UNCHANGED
local DELTA_FULL_OFFSET  = Shared.DELTA_FULL_OFFSET
local DELTA_MULTI_OFFSET = Shared.DELTA_MULTI_OFFSET

-- Public --------------------------------------------------------------

local Array = {}

function Array.array(element: Types.InternalCodec<any>, maxCount: number?): Types.InternalCodec<any>
    local elemAny = element :: any

    -- Bool array: bitpacked
    if elemAny._isBool then
        return table.freeze({
            write = function(ch: Types.ChannelState, value: { any }): ()
                local len = #value
                Varint.write(ch, len)
                if len == 0 then return end

                local byteCount = (len + 7) // 8
                local cursor = ch.cursor
                if cursor + byteCount > ch.size then alloc(ch, byteCount) end
                local b = ch.buff

                local idx = 1
                for byteIdx = 0, byteCount - 1 do
                    local packed = 0
                    local limit = if idx + 8 <= len + 1 then 8 else len - idx + 1
                    for bit = 0, limit - 1 do
                        if value[idx] then
                            packed = bor(packed, lshift(1, bit))
                        end
                        idx += 1
                    end
                    writeu8(b, cursor + byteIdx, packed)
                end
                ch.cursor = cursor + byteCount
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): ({ boolean }, number)
                local len, lenBytes = Varint.read(src, pos)
                if maxCount and len > maxCount then
                    error(`[Lync] Array: count {len} exceeds max {maxCount}`)
                end
                if len == 0 then return {}, lenBytes end

                local byteCount = (len + 7) // 8
                local dataStart = pos + lenBytes
                local result = table.create(len)
                local idx = 1

                for byteIdx = 0, byteCount - 1 do
                    local byte = readu8(src, dataStart + byteIdx)
                    local limit = if idx + 8 <= len + 1 then 8 else len - idx + 1
                    for bit = 0, limit - 1 do
                        result[idx] = band(byte, lshift(1, bit)) ~= 0
                        idx += 1
                    end
                end

                return result, lenBytes + byteCount
            end,
        } :: any)
    end

    -- Direct array: element has _size + _directWrite + _directRead
    local elemSize = elemAny._size
    local elemDW   = elemAny._directWrite
    local elemDR   = elemAny._directRead

    if elemSize and elemDW and elemDR then
        return table.freeze({
            write = function(ch: Types.ChannelState, value: { any }): ()
                local len = #value
                Varint.write(ch, len)
                if len == 0 then return end

                local payloadBytes = len * elemSize
                local cursor = ch.cursor
                if cursor + payloadBytes > ch.size then alloc(ch, payloadBytes) end
                local b = ch.buff

                for i = 1, len do
                    elemDW(b, cursor + (i - 1) * elemSize, value[i])
                end
                ch.cursor = cursor + payloadBytes
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): ({ any }, number)
                local len, lenBytes = Varint.read(src, pos)
                if maxCount and len > maxCount then
                    error(`[Lync] Array: count {len} exceeds max {maxCount}`)
                end
                if len == 0 then return {}, lenBytes end

                local payloadBytes = len * elemSize
                local dataStart = pos + lenBytes

                -- Safety cap
                local remaining = buffer.len(src) - dataStart
                if payloadBytes > remaining then
                    len = remaining // elemSize
                    payloadBytes = len * elemSize
                end

                local result = table.create(len)
                for i = 1, len do
                    result[i] = elemDR(src, dataStart + (i - 1) * elemSize)
                end

                return result, lenBytes + payloadBytes
            end,
        } :: any)
    end

    -- Generic array
    return table.freeze({
        write = function(ch: Types.ChannelState, value: { any }): ()
            local len = #value
            Varint.write(ch, len)
            for i = 1, len do
                element.write(ch, value[i])
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read(src, pos)
            if maxCount and len > maxCount then
                error(`[Lync] Array: count {len} exceeds max {maxCount}`)
            end
            if len == 0 then return {}, lenBytes end

            local result = table.create(len)
            local total = lenBytes
            for i = 1, len do
                local v, consumed = element.read(src, pos + total, refs)
                result[i] = v
                total += consumed
            end

            return result, total
        end,
    } :: any)
end

function Array.deltaArray(element: Types.InternalCodec<any>, maxCount: number?): Types.InternalCodec<any>
    local deltaId = allocDeltaId()
    local innerArray = Array.array(element, maxCount)

    return table.freeze({
        _isDelta = true,

        write = function(ch: Types.ChannelState, value: { any }): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                -- First frame: full
                local cursor = ch.cursor
                if cursor + 1 > ch.size then alloc(ch, 1) end
                writeu8(ch.buff, cursor, 1) -- FLAG_FULL (len+1 where len=0 for first)
                ch.cursor = cursor + 1

                local scratch = acquireScratch()
                innerArray.write(scratch, value)
                local snapLen = scratch.cursor
                local snapBuf = buffer.create(snapLen)
                buffer.copy(snapBuf, 0, scratch.buff, 0, snapLen)

                ch.deltas[deltaId] = { raw = snapBuf, len = snapLen }
                innerArray.write(ch, value)
                releaseScratch()
                return
            end

            -- Compare against cache
            local scratch = acquireScratch()
            innerArray.write(scratch, value)
            local scratchLen = scratch.cursor
            local cachedLen  = cache.len

            if scratchLen == cachedLen and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchLen) then
                local cursor = ch.cursor
                if cursor + 1 > ch.size then alloc(ch, 1) end
                writeu8(ch.buff, cursor, DELTA_UNCHANGED)
                ch.cursor = cursor + 1
                releaseScratch()
                return
            end

            -- Changed: full re-send
            local cursor = ch.cursor
            if cursor + 1 > ch.size then alloc(ch, 1) end
            writeu8(ch.buff, cursor, 1)
            ch.cursor = cursor + 1
            innerArray.write(ch, value)

            local newBuf = buffer.create(scratchLen)
            buffer.copy(newBuf, 0, scratch.buff, 0, scratchLen)
            cache.raw = newBuf
            cache.len = scratchLen

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local flag = readu8(src, pos)

            if flag == DELTA_UNCHANGED then
                return {} :: any, 1
            end

            local value, consumed = innerArray.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    } :: any)
end

return table.freeze(Array)
