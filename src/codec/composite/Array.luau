--!strict
--!native
-- array() and deltaArray(). Bool elements are bit-packed.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local allocDeltaId = Shared.allocDeltaId
local boolBytes = Shared.boolBytes
local packBoolArray = Shared.packBoolArray
local unpackBoolArray = Shared.unpackBoolArray
local varintRead = Varint.read
local varintWrite = Varint.write

-- Bit-packed bool element fast path: 1 bit per entry instead of 1 byte.
local function makeBoolArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return {
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { boolean }): ()
            local len = #value
            varintWrite(ch, len)
            packBoolArray(ch, value, len)
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): ({ boolean }, number)
            local len, lenBytes = varintRead(src, pos)
            if maxCount and len > maxCount then
                Log.error(`count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local byteCount = boolBytes(len)
            local dataStart = pos + lenBytes
            if dataStart + byteCount > buffer.len(src) then
                Log.error(`payload {byteCount}B exceeds remaining buffer`)
            end
            local result = table.create(len, false)
            unpackBoolArray(src, dataStart, len, result)
            return result, lenBytes + byteCount
        end,
    }
end

-- Fixed-size element fast path: single alloc + tight loop calling _direct fns.
local function makeDirectArray(
    element: Types.InternalCodec<any>,
    elemSize: number,
    elemDW: (b: buffer, off: number, value: any) -> (),
    elemDR: (b: buffer, off: number) -> any,
    maxCount: number?
): Types.InternalCodec<any>
    return {
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { any }): ()
            local len = #value
            varintWrite(ch, len)
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
            local len, lenBytes = varintRead(src, pos)
            if maxCount and len > maxCount then
                Log.error(`count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local payloadBytes = len * elemSize
            local dataStart = pos + lenBytes
            if payloadBytes > buffer.len(src) - dataStart then
                Log.error(`payload {payloadBytes}B exceeds remaining buffer`)
            end

            local result = table.create(len)
            local off = dataStart
            for i = 1, len do
                result[i] = elemDR(src, off)
                off += elemSize
            end
            return result, lenBytes + payloadBytes
        end,
    }
end

-- Generic fallback: variable-size or composite element codec.
local function makeGenericArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return {
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { any }): ()
            local len = #value
            varintWrite(ch, len)
            for i = 1, len do
                element.write(ch, value[i])
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = varintRead(src, pos)
            if maxCount and len > maxCount then
                Log.error(`count {len} exceeds max {maxCount}`)
            end
            if len == 0 then
                return {}, lenBytes
            end

            local result = table.create(len)
            local total = lenBytes
            for i = 1, len do
                local v, consumed = element.read(src, pos + total, refs)
                if consumed == 0 then
                    Log.error(`element codec consumed 0 bytes at index {i}`)
                end
                result[i] = v
                total += consumed
            end
            return result, total
        end,
    }
end

-- Public -----------------------------------------------------------------

local Array = {}

function Array.array(element: Types.InternalCodec<any>, maxCount: number?): Types.InternalCodec<any>
    local codec: Types.InternalCodec<any>
    if element._isBool then
        codec = makeBoolArray(element, maxCount)
    else
        local elemSize = element._size
        local elemDW = element._directWrite
        local elemDR = element._directRead
        if elemSize and elemDW and elemDR then
            codec = makeDirectArray(element, elemSize, elemDW, elemDR, maxCount)
        else
            codec = makeGenericArray(element, maxCount)
        end
    end
    if element._hasUnknown then
        codec._hasUnknown = true
    end
    return table.freeze(codec)
end

--[[
    UNCHANGED-or-FULL delta. Useful only when contents AND order are stable
    across frames; for unstable lists, plain array() avoids a 1-byte tax on
    every frame the byte-equality cache misses.
]]
function Array.deltaArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return Shared.makeUnchangedOrFullDelta(Array.array(element, maxCount), allocDeltaId(), Baseline)
end

return table.freeze(Array)
