--!strict
--!native
-- Array and deltaArray codecs. Bool elements are bit-packed.

local Base = require(script.Parent.Parent.Base)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift

local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual = Shared.rangeEqual
local snapshot = Shared.snapshot
local allocDeltaId = Shared.allocDeltaId
local DELTA_UNCHANGED = Shared.DELTA_UNCHANGED
local DELTA_FULL = Shared.DELTA_FULL

local function makeBoolArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return table.freeze({
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { boolean }): ()
            local len = #value
            Varint.write(ch, len)
            if len == 0 then
                return
            end

            local byteCount = (len + 7) // 8
            local cursor = ch.cursor
            if cursor + byteCount > ch.size then
                alloc(ch, byteCount)
            end
            local b = ch.buff

            local idx = 1
            for byteIdx = 0, byteCount - 1 do
                local packed = 0
                local remaining = len - idx + 1
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
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): ({ boolean }, number)
            local len, lenBytes = Varint.read(src, pos)
            if maxCount and len > maxCount then
                error(`[Lync] Array.read: count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local byteCount = (len + 7) // 8
            local dataStart = pos + lenBytes
            local result = table.create(len)

            local idx = 1
            for byteIdx = 0, byteCount - 1 do
                local byte = readu8(src, dataStart + byteIdx)
                local remaining = len - idx + 1
                local limit = if remaining >= 8 then 8 else remaining
                for bit = 0, limit - 1 do
                    result[idx] = band(byte, lshift(1, bit)) ~= 0
                    idx += 1
                end
            end
            return result, lenBytes + byteCount
        end,
    })
end

local function makeDirectArray(
    element: Types.InternalCodec<any>,
    elemSize: number,
    elemDW: (b: buffer, off: number, value: any) -> (),
    elemDR: (b: buffer, off: number) -> any,
    maxCount: number?
): Types.InternalCodec<any>
    return table.freeze({
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { any }): ()
            local len = #value
            Varint.write(ch, len)
            if len == 0 then
                return
            end

            local payloadBytes = len * elemSize
            local cursor = ch.cursor
            if cursor + payloadBytes > ch.size then
                alloc(ch, payloadBytes)
            end
            local b = ch.buff

            local off = cursor
            for i = 1, len do
                elemDW(b, off, value[i])
                off += elemSize
            end
            ch.cursor = cursor + payloadBytes
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read(src, pos)
            if maxCount and len > maxCount then
                error(`[Lync] Array.read: count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local payloadBytes = len * elemSize
            local dataStart = pos + lenBytes
            local remaining = buffer.len(src) - dataStart
            if payloadBytes > remaining then
                len = remaining // elemSize
                payloadBytes = len * elemSize
            end

            local result = table.create(len)
            local off = dataStart
            for i = 1, len do
                result[i] = elemDR(src, off)
                off += elemSize
            end
            return result, lenBytes + payloadBytes
        end,
    })
end

local function makeGenericArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return table.freeze({
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

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
                error(`[Lync] Array.read: count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local result = table.create(len)
            local total = lenBytes
            for i = 1, len do
                local v, consumed = element.read(src, pos + total, refs)
                if consumed == 0 then
                    error(`[Lync] Array.read: element codec consumed 0 bytes at index {i}`)
                end
                result[i] = v
                total += consumed
            end
            return result, total
        end,
    })
end

-- Public -----------------------------------------------------------------

local Array = {}

function Array.array(element: Types.InternalCodec<any>, maxCount: number?): Types.InternalCodec<any>
    if element._isBool then
        return makeBoolArray(element, maxCount)
    end

    local elemSize = element._size
    local elemDW = element._directWrite
    local elemDR = element._directRead
    if elemSize and elemDW and elemDR then
        return makeDirectArray(element, elemSize, elemDW, elemDR, maxCount)
    end

    return makeGenericArray(element, maxCount)
end

function Array.deltaArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    local deltaId = allocDeltaId()
    local innerArray = Array.array(element, maxCount)

    return table.freeze({
        _isDelta = true,

        write = function(ch: Types.ChannelState, value: { any }): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                writeByte(ch, DELTA_FULL)

                local scratch = acquireScratch()
                innerArray.write(scratch, value)
                local snapLen = scratch.cursor

                ch.deltas[deltaId] = { raw = snapshot(scratch.buff, snapLen), len = snapLen }
                innerArray.write(ch, value)
                releaseScratch()
                return
            end

            local scratch = acquireScratch()
            innerArray.write(scratch, value)
            local scratchLen = scratch.cursor

            if
                scratchLen == cache.len
                and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchLen)
            then
                writeByte(ch, DELTA_UNCHANGED)
                releaseScratch()
                return
            end

            writeByte(ch, DELTA_FULL)
            innerArray.write(ch, value)

            cache.raw = snapshot(scratch.buff, scratchLen)
            cache.len = scratchLen
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            if readu8(src, pos) == DELTA_UNCHANGED then
                return {}, 1
            end
            local value, consumed = innerArray.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    })
end

return table.freeze(Array)
