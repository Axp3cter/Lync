--!strict
--!native
-- map and deltaMap codecs.

local Base = require(script.Parent.Parent.Base)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private -------------------------------------------------------------

local alloc = Base.alloc
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8

local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual = Shared.rangeEqual
local allocDeltaId = Shared.allocDeltaId
local DELTA_UNCHANGED = Shared.DELTA_UNCHANGED

-- Public --------------------------------------------------------------

local Map = {}

function Map.map(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return table.freeze({
        write = function(ch: Types.ChannelState, value: any): ()
            -- Count entries
            local count = 0
            for _ in value do
                count += 1
            end

            Varint.write(ch, count)
            if count == 0 then
                return
            end

            -- Pre-alloc if both fixed size
            local kAny = keyCodec :: any
            local vAny = valueCodec :: any
            if kAny._size and vAny._size then
                local entrySize = kAny._size + vAny._size
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

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local count, lenBytes = Varint.read(src, pos)
            if maxCount and count > maxCount then
                error(`[Lync] Map: count {count} exceeds max {maxCount}`)
            end

            local result: { [any]: any } = {}
            local total = lenBytes

            for _ = 1, count do
                local k, kc = keyCodec.read(src, pos + total, refs)
                total += kc
                local v, vc = valueCodec.read(src, pos + total, refs)
                total += vc
                result[k] = v
            end

            return result, total
        end,
    } :: any)
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

        write = function(ch: Types.ChannelState, value: any): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                local cursor = ch.cursor
                if cursor + 1 > ch.size then
                    alloc(ch, 1)
                end
                writeu8(ch.buff, cursor, 3) -- FLAG_FULL
                ch.cursor = cursor + 1

                local scratch = acquireScratch()
                innerMap.write(scratch, value)
                local snapLen = scratch.cursor
                local snapBuf = buffer.create(snapLen)
                buffer.copy(snapBuf, 0, scratch.buff, 0, snapLen)

                ch.deltas[deltaId] = { raw = snapBuf, len = snapLen }
                innerMap.write(ch, value)
                releaseScratch()
                return
            end

            local scratch = acquireScratch()
            innerMap.write(scratch, value)
            local scratchLen = scratch.cursor
            local cachedLen = cache.len

            if
                scratchLen == cachedLen and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchLen)
            then
                local cursor = ch.cursor
                if cursor + 1 > ch.size then
                    alloc(ch, 1)
                end
                writeu8(ch.buff, cursor, DELTA_UNCHANGED)
                ch.cursor = cursor + 1
                releaseScratch()
                return
            end

            -- Changed: full re-send
            local cursor = ch.cursor
            if cursor + 1 > ch.size then
                alloc(ch, 1)
            end
            writeu8(ch.buff, cursor, 3) -- FLAG_FULL
            ch.cursor = cursor + 1
            innerMap.write(ch, value)

            local newBuf = buffer.create(scratchLen)
            buffer.copy(newBuf, 0, scratch.buff, 0, scratchLen)
            cache.raw = newBuf
            cache.len = scratchLen

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = readu8(src, pos)

            if flag == DELTA_UNCHANGED then
                return {} :: any, 1
            end

            local value, consumed = innerMap.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    } :: any)
end

return table.freeze(Map)
