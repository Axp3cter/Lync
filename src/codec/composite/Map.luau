--!strict
--!native
-- map() and deltaMap(). Keys sorted at encode for stable wire bytes.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- State ------------------------------------------------------------------

--[[
    Depth-stacked key scratch. A nested Map.write (Map<K, Map<K2, V>>) would
    clobber a single shared array mid-iteration; the stack gives each frame
    its own slot. Mirrors Shared.acquireScratch / releaseScratch.
]]
local _keyStacks: { { any } } = {}
local _keyDepth = 0

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local allocDeltaId = Shared.allocDeltaId

local function acquireKeys(): { any }
    _keyDepth += 1
    local keys = _keyStacks[_keyDepth]
    if keys then
        return keys
    end
    keys = {}
    _keyStacks[_keyDepth] = keys
    return keys
end

local function releaseKeys(): ()
    _keyDepth -= 1
end

-- Module-level so the mixed-type sort path doesn't allocate a closure per write.
local function tostringLess(a: any, b: any): boolean
    return tostring(a) < tostring(b)
end

-- Public -----------------------------------------------------------------

local Map = {}

function Map.map(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    local fixedKey = keyCodec._size
    local fixedValue = valueCodec._size
    local hasUnknown = keyCodec._hasUnknown or valueCodec._hasUnknown

    --[[
        Numbers and strings sort by `<` directly; everything else (Instance,
        vector, mixed-type via Auto) routes through tostring. Pinned at codec
        creation so writes don't re-sniff the key type.
    ]]
    local typeCheck = keyCodec._typeCheck
    local canSortDirect = typeCheck == "number" or typeCheck == "string"

    local codec: Types.InternalCodec<any> = {
        _isMap = true,
        _keyCodec = keyCodec,
        _valueCodec = valueCodec,
        _maxCount = maxCount,

        --[[
            Sort keys for deterministic wire layout. Without this, two
            structurally-equal maps yield different byte sequences across
            frames, which breaks every downstream byte-equality cache (the
            XOR baseline and deltaMap).
        ]]
        write = function(ch: Types.ChannelState, value: { [any]: any }): ()
            if typeof(value) ~= "table" then
                Log.error(`expected table, got {typeof(value)}`)
            end

            local keys = acquireKeys()
            local count = 0
            for k in value do
                count += 1
                keys[count] = k
            end

            -- Drop tail entries from the prior reuse so table.sort sees only `count` items.
            local prevTail = #keys
            for i = count + 1, prevTail do
                keys[i] = nil
            end

            Varint.write(ch, count)
            if count == 0 then
                releaseKeys()
                return
            end

            if canSortDirect then
                table.sort(keys :: { any })
            else
                table.sort(keys, tostringLess)
            end

            -- Single alloc when both halves are fixed-size.
            if fixedKey and fixedValue then
                local entrySize = fixedKey + fixedValue
                local cursor = ch.cursor
                if cursor + count * entrySize > ch.size then
                    alloc(ch, count * entrySize)
                end
            end

            for i = 1, count do
                local k = keys[i]
                keyCodec.write(ch, k)
                valueCodec.write(ch, value[k])
                keys[i] = nil
            end
            releaseKeys()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read(src, pos)
            if maxCount and count > maxCount then
                Log.error(`count {count} exceeds max {maxCount}`)
            end

            -- Fixed-size: reject corrupt counts before per-entry decode.
            if fixedKey and fixedValue and count > 0 then
                local entrySize = fixedKey + fixedValue
                local dataStart = pos + lenBytes
                local payloadBytes = count * entrySize
                if payloadBytes > buffer.len(src) - dataStart then
                    Log.error(`payload {payloadBytes}B exceeds remaining buffer`)
                end
            end

            local result: { [any]: any } = {}
            local total = lenBytes
            for i = 1, count do
                local k, kc = keyCodec.read(src, pos + total, refs)
                if kc == 0 then
                    Log.error(`truncated key at index {i}`)
                end
                total += kc
                local v, vc = valueCodec.read(src, pos + total, refs)
                if vc == 0 then
                    Log.error(`truncated value at index {i}`)
                end
                total += vc
                result[k] = v
            end
            return result, total
        end,
    }
    if hasUnknown then
        codec._hasUnknown = true
    end
    return table.freeze(codec)
end

function Map.deltaMap(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    return Shared.makeUnchangedOrFullDelta(
        Map.map(keyCodec, valueCodec, maxCount),
        allocDeltaId(),
        Baseline
    )
end

return table.freeze(Map)
