--!strict
--!native
-- Map and deltaMap codecs.

local Base = require(script.Parent.Parent.Base)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local readu8 = buffer.readu8

local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual = Shared.rangeEqual
local snapshot = Shared.snapshot
local allocDeltaId = Shared.allocDeltaId
local DELTA_UNCHANGED = Shared.DELTA_UNCHANGED
local DELTA_FULL = Shared.DELTA_FULL

-- Public -----------------------------------------------------------------

local Map = {}

function Map.map(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    local fixedKey = keyCodec._size
    local fixedValue = valueCodec._size

    return table.freeze({
        _isMap = true,
        _keyCodec = keyCodec,
        _valueCodec = valueCodec,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { [any]: any }): ()
            local count = 0
            for _ in value do
                count += 1
            end

            Varint.write(ch, count)
            if count == 0 then
                return
            end

            if fixedKey and fixedValue then
                local entrySize = fixedKey + fixedValue
                local cursor = ch.cursor
                if cursor + count * entrySize > ch.size then
                    alloc(ch, count * entrySize)
                end
            end

            for k, v in value do
                keyCodec.write(ch, k)
                valueCodec.write(ch, v)
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read(src, pos)
            if maxCount and count > maxCount then
                error(`[Lync] Map.read: count {count} exceeds max {maxCount}`)
            end

            local result: { [any]: any } = {}
            local total = lenBytes
            for i = 1, count do
                local k, kc = keyCodec.read(src, pos + total, refs)
                total += kc
                local v, vc = valueCodec.read(src, pos + total, refs)
                total += vc
                if kc == 0 and vc == 0 then
                    error(`[Lync] Map.read: zero-byte entry at index {i}`)
                end
                result[k] = v
            end
            return result, total
        end,
    })
end

function Map.deltaMap(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    local deltaId = allocDeltaId()
    local innerMap = Map.map(keyCodec, valueCodec, maxCount)

    return table.freeze({
        _isDelta = true,

        write = function(ch: Types.ChannelState, value: { [any]: any }): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                writeByte(ch, DELTA_FULL)

                local scratch = acquireScratch()
                innerMap.write(scratch, value)
                local snapLen = scratch.cursor

                ch.deltas[deltaId] = { raw = snapshot(scratch.buff, snapLen), len = snapLen }
                innerMap.write(ch, value)
                releaseScratch()
                return
            end

            local scratch = acquireScratch()
            innerMap.write(scratch, value)
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
            innerMap.write(ch, value)

            cache.raw = snapshot(scratch.buff, scratchLen)
            cache.len = scratchLen
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            if readu8(src, pos) == DELTA_UNCHANGED then
                return {}, 1
            end
            local value, consumed = innerMap.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    })
end

return table.freeze(Map)
