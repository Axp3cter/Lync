--!strict
--!native
-- map() and deltaMap(). Keys sorted at encode for stable wire bytes.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Constants --------------------------------------------------------------

-- deltaMap wire flags. Distinct from Shared's struct/array flag spaces.
local DM_UNCHANGED = 0
local DM_FULL = 1
local DM_DIFF = 2

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
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual = Shared.rangeEqual
local copyToBuf = Shared.copyToBuf
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local bufCopy = buffer.copy
local bufLen = buffer.len
local varintRead = Varint.read
local varintWrite = Varint.write

type DeltaMapEntry = { kBuf: buffer, kLen: number, vBuf: buffer, vLen: number }

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

local function ensure(ch: Types.ChannelState, n: number): ()
    if ch.cursor + n > ch.size then
        alloc(ch, n)
    end
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
    local hasDelta = keyCodec._isDelta
        or keyCodec._hasDelta
        or valueCodec._isDelta
        or valueCodec._hasDelta

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

            varintWrite(ch, count)
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
                ensure(ch, count * (fixedKey + fixedValue))
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
            local count, lenBytes = varintRead(src, pos)
            if maxCount and count > maxCount then
                Log.error(`count {count} exceeds max {maxCount}`)
            end

            -- Fixed-size: reject corrupt counts before per-entry decode.
            if fixedKey and fixedValue and count > 0 then
                local payloadBytes = count * (fixedKey + fixedValue)
                if payloadBytes > bufLen(src) - (pos + lenBytes) then
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
    if hasDelta then
        codec._hasDelta = true
    end
    return table.freeze(codec)
end

--[[
    Per-key deltaMap. Wire:
      [0] UNCHANGED  (1 byte)
      [1] FULL       <count varint> <(k,v) pairs ...>
      [2] DIFF       <removeCount varint> <removed key bytes ...>
                     <changeCount varint> <(k,v) pair bytes ...>

    Cache: per-key encoded value bytes for byte-equality diffing plus per-key
    encoded key bytes so removed-key emission doesn't re-encode the key codec
    for keys that no longer live in the map.
]]
function Map.deltaMap(
    keyCodec: Types.InternalCodec<any>,
    valueCodec: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    local deltaId = allocDeltaId()
    local typeCheck = keyCodec._typeCheck
    local canSortDirect = typeCheck == "number" or typeCheck == "string"
    local inner = Map.map(keyCodec, valueCodec, maxCount)

    --[[
        Encode each (key, value) pair into `scratch` and capture per-pair byte
        ranges. Returns the sorted-keys list plus four parallel arrays of
        offset/length so the diff path can compare and emit individual entries
        without re-encoding.
    ]]
    local function encodePerKey(
        scratch: Types.ChannelState,
        value: { [any]: any }
    ): ({ any }, { number }, { number }, { number }, { number })
        local keys = acquireKeys()
        local count = 0
        for k in value do
            count += 1
            keys[count] = k
        end
        local prevTail = #keys
        for i = count + 1, prevTail do
            keys[i] = nil
        end
        if canSortDirect then
            table.sort(keys :: { any })
        else
            table.sort(keys, tostringLess)
        end

        local kOff = table.create(count)
        local kLen = table.create(count)
        local vOff = table.create(count)
        local vLen = table.create(count)

        for i = 1, count do
            local k = keys[i]
            local before = scratch.cursor
            keyCodec.write(scratch, k)
            local mid = scratch.cursor
            kOff[i] = before
            kLen[i] = mid - before
            valueCodec.write(scratch, value[k])
            vOff[i] = mid
            vLen[i] = scratch.cursor - mid
        end
        return keys, kOff, kLen, vOff, vLen
    end

    return table.freeze({
        _isDelta = true,
        _isMap = true,
        _keyCodec = keyCodec,
        _valueCodec = valueCodec,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { [any]: any }): ()
            if typeof(value) ~= "table" then
                Log.error(`expected table, got {typeof(value)}`)
            end

            local cache = ch.deltas[deltaId] :: any
            local scratch = acquireScratch()
            local keys, kOff, kLen, vOff, vLen = encodePerKey(scratch, value)
            local count = #keys
            local scratchBuf = scratch.buff

            -- First frame: emit FULL. Per-key scratch bytes are exactly the inner map payload.
            if not cache then
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DM_FULL)
                ch.cursor += 1
                varintWrite(ch, count)
                local payloadLen = scratch.cursor
                if payloadLen > 0 then
                    ensure(ch, payloadLen)
                    bufCopy(ch.buff, ch.cursor, scratchBuf, 0, payloadLen)
                    ch.cursor += payloadLen
                end

                local perKey: { [any]: DeltaMapEntry } = {}
                for i = 1, count do
                    local kbLen = kLen[i]
                    local vbLen = vLen[i]
                    perKey[keys[i]] = {
                        kBuf = copyToBuf(nil, scratchBuf, kOff[i], kbLen),
                        kLen = kbLen,
                        vBuf = copyToBuf(nil, scratchBuf, vOff[i], vbLen),
                        vLen = vbLen,
                    }
                end
                ch.deltas[deltaId] = { perKey = perKey } :: any

                for i = 1, count do
                    keys[i] = nil
                end
                releaseKeys()
                releaseScratch()
                return
            end

            -- Diff against cache.
            local cachedPerKey = cache.perKey :: { [any]: DeltaMapEntry }

            local seen: { [any]: boolean } = {}
            local changed: { number } = {}
            local changedCount = 0
            for i = 1, count do
                local k = keys[i]
                seen[k] = true
                local entry = cachedPerKey[k]
                local newLen = vLen[i]
                if
                    not entry
                    or newLen ~= entry.vLen
                    or not rangeEqual(scratchBuf, vOff[i], entry.vBuf, 0, newLen)
                then
                    changedCount += 1
                    changed[changedCount] = i
                end
            end

            local removed: { any } = {}
            local removedCount = 0
            for k in cachedPerKey do
                if not seen[k] then
                    removedCount += 1
                    removed[removedCount] = k
                end
            end

            if removedCount == 0 and changedCount == 0 then
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DM_UNCHANGED)
                ch.cursor += 1

                for i = 1, count do
                    keys[i] = nil
                end
                releaseKeys()
                releaseScratch()
                return
            end

            -- Sort removed keys for deterministic wire (XOR baseline benefit).
            if canSortDirect then
                table.sort(removed :: { any })
            else
                table.sort(removed, tostringLess)
            end

            ensure(ch, 1)
            writeu8(ch.buff, ch.cursor, DM_DIFF)
            ch.cursor += 1

            varintWrite(ch, removedCount)
            for i = 1, removedCount do
                local entry = cachedPerKey[removed[i]]
                local n = entry.kLen
                ensure(ch, n)
                if n > 0 then
                    bufCopy(ch.buff, ch.cursor, entry.kBuf, 0, n)
                end
                ch.cursor += n
            end

            varintWrite(ch, changedCount)
            for i = 1, changedCount do
                local idx = changed[i]
                local kbLen = kLen[idx]
                local vbLen = vLen[idx]
                local total = kbLen + vbLen
                ensure(ch, total)
                if kbLen > 0 then
                    bufCopy(ch.buff, ch.cursor, scratchBuf, kOff[idx], kbLen)
                end
                if vbLen > 0 then
                    bufCopy(ch.buff, ch.cursor + kbLen, scratchBuf, vOff[idx], vbLen)
                end
                ch.cursor += total
            end

            -- Update cache: drop removed, refresh changed, leave untouched in place.
            for i = 1, removedCount do
                cachedPerKey[removed[i]] = nil
            end
            for i = 1, changedCount do
                local idx = changed[i]
                local k = keys[idx]
                local kbLen = kLen[idx]
                local vbLen = vLen[idx]
                local entry = cachedPerKey[k]
                if entry then
                    entry.kBuf = copyToBuf(entry.kBuf, scratchBuf, kOff[idx], kbLen)
                    entry.kLen = kbLen
                    entry.vBuf = copyToBuf(entry.vBuf, scratchBuf, vOff[idx], vbLen)
                    entry.vLen = vbLen
                else
                    cachedPerKey[k] = {
                        kBuf = copyToBuf(nil, scratchBuf, kOff[idx], kbLen),
                        kLen = kbLen,
                        vBuf = copyToBuf(nil, scratchBuf, vOff[idx], vbLen),
                        vLen = vbLen,
                    }
                end
            end

            for i = 1, count do
                keys[i] = nil
            end
            releaseKeys()
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            if pos >= bufLen(src) then
                Log.error("truncated deltaMap header")
            end
            local flag = readu8(src, pos)

            if flag == DM_UNCHANGED then
                local cached = Baseline.getCache(deltaId)
                if cached == nil then
                    Log.error("UNCHANGED flag before any FULL frame; baseline missing")
                end
                return cached, 1
            end

            if flag == DM_FULL then
                local value, consumed = inner.read(src, pos + 1, refs)
                Baseline.setCache(deltaId, value)
                return value, 1 + consumed
            end

            if flag == DM_DIFF then
                local cached = Baseline.getCache(deltaId)
                if cached == nil then
                    Log.error("deltaMap DIFF before any FULL frame; baseline missing")
                end
                local result: { [any]: any } = table.clone(cached)
                local total = 1

                local removeCount, rcLen = varintRead(src, pos + total)
                if rcLen == 0 then
                    Log.error("truncated deltaMap remove count")
                end
                total += rcLen
                for _ = 1, removeCount do
                    local k, kc = keyCodec.read(src, pos + total, refs)
                    if kc == 0 then
                        Log.error("truncated deltaMap removed key")
                    end
                    total += kc
                    result[k] = nil
                end

                local changeCount, ccLen = varintRead(src, pos + total)
                if ccLen == 0 then
                    Log.error("truncated deltaMap change count")
                end
                total += ccLen
                for _ = 1, changeCount do
                    local k, kc = keyCodec.read(src, pos + total, refs)
                    if kc == 0 then
                        Log.error("truncated deltaMap changed key")
                    end
                    total += kc
                    local v, vc = valueCodec.read(src, pos + total, refs)
                    if vc == 0 then
                        Log.error("truncated deltaMap changed value")
                    end
                    total += vc
                    result[k] = v
                end

                Baseline.setCache(deltaId, result)
                return result, total
            end

            Log.error(`invalid deltaMap flag {flag}`)
        end,
    }) :: Types.InternalCodec<any>
end

return table.freeze(Map)
