--!strict
--!native
-- array() and deltaArray(). Bool elements are bit-packed.

local Base = require(script.Parent.Parent.Base)
local Baseline = require(script.Parent.Parent.Parent.internal.Baseline)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Constants --------------------------------------------------------------

-- deltaArray wire flags. Distinct from Shared's struct/map flag spaces.
local DA_UNCHANGED = 0
local DA_FULL = 1
local DA_PATCH = 2

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local ensure = Base.ensure
local allocDeltaId = Shared.allocDeltaId
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local rangeEqual = Shared.rangeEqual
local copyToBuf = Shared.copyToBuf
local containsDelta = Shared.containsDelta
local enforceMaxCount = Shared.enforceMaxCount
local boolBytes = Shared.boolBytes
local packBoolArray = Shared.packBoolArray
local unpackBoolArray = Shared.unpackBoolArray
local varintRead = Varint.read
local varintWrite = Varint.write
local varintLength = Varint.length
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local bufCopy = buffer.copy
local bufLen = buffer.len

type DeltaArrayEntry = { eBuf: buffer, eLen: number }

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
            packBoolArray(ch, value, len, if len > 0 then boolBytes(len) else 0)
        end,

        read = function(src: buffer, pos: number, _refs: { Instance }?): ({ boolean }, number)
            local len, lenBytes = varintRead(src, pos)
            enforceMaxCount(len, maxCount)
            if len == 0 then
                return {}, lenBytes
            end

            local byteCount = boolBytes(len)
            local dataStart = pos + lenBytes
            if dataStart + byteCount > bufLen(src) then
                Log.error(`payload {byteCount}B exceeds remaining buffer`)
            end
            local result = table.create(len, false)
            unpackBoolArray(src, dataStart, len, result, byteCount)
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
            enforceMaxCount(len, maxCount)
            if len == 0 then
                return {}, lenBytes
            end

            local payloadBytes = len * elemSize
            local dataStart = pos + lenBytes
            if payloadBytes > bufLen(src) - dataStart then
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
            enforceMaxCount(len, maxCount)
            if len == 0 then
                return {}, lenBytes
            end
            -- Every element occupies at least 1 byte; len > remaining is
            -- unambiguously corrupt and would OOM table.create otherwise.
            if len > bufLen(src) - (pos + lenBytes) then
                Log.error(`array length {len} exceeds remaining buffer`)
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
    if containsDelta(element) then
        codec._hasDelta = true
    end
    return table.freeze(codec)
end

--[[
    Per-index deltaArray. Wire:
      [0] UNCHANGED  (1 byte)
      [1] FULL       <count varint> <element bytes ...>
      [2] PATCH      <newLen varint> <changeCount varint>
                     <(idx varint, element bytes) ...>

    Length shrinkage is implicit in newLen — entries past newLen drop from
    the cached map. Length growth: appended indices show up as changes.
    Reordered lists tend to mark every index changed; the writer falls back
    to FULL when changeCount * 2 >= newLen since PATCH index varints eat
    any savings past that ratio.
]]
function Array.deltaArray(
    element: Types.InternalCodec<any>,
    maxCount: number?
): Types.InternalCodec<any>
    -- Inner delta would chain-diff across elements within a frame, not across frames.
    if containsDelta(element) then
        Log.error("deltaArray element cannot contain delta state")
    end

    local deltaId = allocDeltaId()
    local inner = Array.array(element, maxCount)

    --[[
        Encode each element into `scratch` and capture per-index byte ranges.
        Returns the array length plus parallel arrays of offset/length so the
        diff path can compare and emit individual entries without re-encoding.
    ]]
    local function encodePerIdx(
        scratch: Types.ChannelState,
        value: { any }
    ): (number, { number }, { number })
        local len = #value
        enforceMaxCount(len, maxCount)
        local off = table.create(len)
        local elen = table.create(len)
        for i = 1, len do
            local before = scratch.cursor
            element.write(scratch, value[i])
            off[i] = before
            elen[i] = scratch.cursor - before
        end
        return len, off, elen
    end

    return table.freeze({
        _isDelta = true,
        _isArray = true,
        _element = element,
        _maxCount = maxCount,

        write = function(ch: Types.ChannelState, value: { any }): ()
            if typeof(value) ~= "table" then
                Log.error(`expected table, got {typeof(value)}`)
            end

            local cache = ch.deltas[deltaId] :: any
            local scratch = acquireScratch()
            local len, off, elen = encodePerIdx(scratch, value)
            local scratchBuf = scratch.buff

            -- First frame: emit FULL using the per-index scratch bytes.
            if not cache then
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DA_FULL)
                ch.cursor += 1
                varintWrite(ch, len)
                local payloadLen = scratch.cursor
                ensure(ch, payloadLen)
                bufCopy(ch.buff, ch.cursor, scratchBuf, 0, payloadLen)
                ch.cursor += payloadLen

                local perIdx: { [number]: DeltaArrayEntry } = {}
                for i = 1, len do
                    local n = elen[i]
                    perIdx[i] = { eBuf = copyToBuf(nil, scratchBuf, off[i], n), eLen = n }
                end
                ch.deltas[deltaId] = { perIdx = perIdx, length = len } :: any
                releaseScratch()
                return
            end

            local cachedPerIdx = cache.perIdx :: { [number]: DeltaArrayEntry }
            local cachedLen = cache.length :: number

            -- Find changed indices in the overlap; appended indices count as changed.
            local changed: { number } = {}
            local changedCount = 0
            local overlap = if len < cachedLen then len else cachedLen
            for i = 1, overlap do
                local entry = cachedPerIdx[i]
                local n = elen[i]
                if
                    not entry
                    or n ~= entry.eLen
                    or not rangeEqual(scratchBuf, off[i], entry.eBuf, 0, n)
                then
                    changedCount += 1
                    changed[changedCount] = i
                end
            end
            for i = overlap + 1, len do
                changedCount += 1
                changed[changedCount] = i
            end

            if changedCount == 0 and len == cachedLen then
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DA_UNCHANGED)
                ch.cursor += 1
                releaseScratch()
                return
            end

            -- Pick FULL vs PATCH on actual byte cost. Both share `1 + varintLength(len)`
            -- so it cancels: compare PATCH's index-header overhead + changed payload
            -- against FULL's full payload.
            local fullPayload = scratch.cursor
            local patchPayload = varintLength(changedCount)
            for i = 1, changedCount do
                local idx = changed[i]
                patchPayload += varintLength(idx) + elen[idx]
            end

            if patchPayload < fullPayload then
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DA_PATCH)
                ch.cursor += 1
                varintWrite(ch, len)
                varintWrite(ch, changedCount)
                for i = 1, changedCount do
                    local idx = changed[i]
                    varintWrite(ch, idx)
                    local n = elen[idx]
                    ensure(ch, n)
                    bufCopy(ch.buff, ch.cursor, scratchBuf, off[idx], n)
                    ch.cursor += n
                end
            else
                ensure(ch, 1)
                writeu8(ch.buff, ch.cursor, DA_FULL)
                ch.cursor += 1
                varintWrite(ch, len)
                ensure(ch, fullPayload)
                bufCopy(ch.buff, ch.cursor, scratchBuf, 0, fullPayload)
                ch.cursor += fullPayload
            end

            -- Update cache: refresh changed (and appended), drop truncated.
            for i = 1, changedCount do
                local idx = changed[i]
                local n = elen[idx]
                local entry = cachedPerIdx[idx]
                if entry then
                    entry.eBuf = copyToBuf(entry.eBuf, scratchBuf, off[idx], n)
                    entry.eLen = n
                else
                    cachedPerIdx[idx] = { eBuf = copyToBuf(nil, scratchBuf, off[idx], n), eLen = n }
                end
            end
            for i = len + 1, cachedLen do
                cachedPerIdx[i] = nil
            end
            cache.length = len

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            if pos >= bufLen(src) then
                Log.error("truncated deltaArray header")
            end
            local flag = readu8(src, pos)

            if flag == DA_UNCHANGED then
                local cached = Baseline.getCache(deltaId)
                if cached == nil then
                    Log.error("UNCHANGED flag before any FULL frame; baseline missing")
                end
                return cached, 1
            end

            if flag == DA_FULL then
                local value, consumed = inner.read(src, pos + 1, refs)
                Baseline.setCache(deltaId, value)
                return value, 1 + consumed
            end

            if flag == DA_PATCH then
                local cached = Baseline.getCache(deltaId)
                if cached == nil then
                    Log.error("deltaArray PATCH before any FULL frame; baseline missing")
                end
                --[[
                    Capture the cached length BEFORE clone+mutate; #result
                    becomes unreliable once we set entries at appended indices
                    past the original boundary.
                ]]
                local cachedLen = #cached
                local result: { any } = table.clone(cached)
                local total = 1

                local newLen, lLen = varintRead(src, pos + total)
                if lLen == 0 then
                    Log.error("truncated deltaArray length")
                end
                enforceMaxCount(newLen, maxCount, "newLen")
                total += lLen

                local changeCount, cLen = varintRead(src, pos + total)
                if cLen == 0 then
                    Log.error("truncated deltaArray change count")
                end
                if changeCount > newLen then
                    Log.error(`deltaArray changeCount {changeCount} exceeds newLen {newLen}`)
                end
                total += cLen

                -- The writer marks every appended index (cachedLen+1 .. newLen)
                -- as changed; the reader must enforce this so the wire can't
                -- ship a holey baseline that breaks #result downstream.
                local appendedNeeded = if newLen > cachedLen then newLen - cachedLen else 0
                local appendedSeen = 0

                for _ = 1, changeCount do
                    local idx, iLen = varintRead(src, pos + total)
                    if iLen == 0 then
                        Log.error("truncated deltaArray index")
                    end
                    if idx < 1 or idx > newLen then
                        Log.error(`deltaArray index {idx} out of range [1, {newLen}]`)
                    end
                    if idx > cachedLen then
                        appendedSeen += 1
                    end
                    total += iLen
                    local v, vc = element.read(src, pos + total, refs)
                    if vc == 0 then
                        Log.error("truncated deltaArray element")
                    end
                    total += vc
                    result[idx] = v
                end

                if appendedSeen ~= appendedNeeded then
                    Log.error(
                        `deltaArray PATCH grew length to {newLen} but only {appendedSeen}/{appendedNeeded} appended indices supplied`
                    )
                end

                for i = newLen + 1, cachedLen do
                    result[i] = nil
                end

                Baseline.setCache(deltaId, result)
                return result, total
            end

            Log.error(`invalid deltaArray flag {flag}`)
        end,
    }) :: Types.InternalCodec<any>
end

return table.freeze(Array)
