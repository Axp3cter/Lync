--!strict
--!native
-- struct and deltaStruct codecs with single-field delta shortcut.

local Types  = require(script.Parent.Parent.Parent.Types)
local Base   = require(script.Parent.Parent.Base)
local Shared = require(script.Parent.Shared)

-- Private -------------------------------------------------------------

local alloc       = Base.alloc
local writeu8     = buffer.writeu8
local readu8      = buffer.readu8
local extractFields = Shared.extractFields
local packBools     = Shared.packBools
local unpackBools   = Shared.unpackBools
local rangeEqual    = Shared.rangeEqual
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local allocDeltaId   = Shared.allocDeltaId

local DELTA_UNCHANGED    = Shared.DELTA_UNCHANGED
local DELTA_FULL_OFFSET  = Shared.DELTA_FULL_OFFSET
local DELTA_MULTI_OFFSET = Shared.DELTA_MULTI_OFFSET

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift

-- Public --------------------------------------------------------------

local Struct = {}

function Struct.struct(schema: { [string]: Types.InternalCodec<any> }): Types.InternalCodec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)
    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolBytes = (boolCount + 7) // 8

    -- Check all-direct path
    local allDirect = true
    local fixedSize = 0

    for i = 1, dataCount do
        local c = dataCodecs[i] :: any
        if not c._size or not c._directWrite or not c._directRead then
            allDirect = false
            break
        end
        fixedSize += c._size
    end

    local totalFixed = fixedSize + boolBytes

    -- Freeze schema for Gate
    local frozenSchema: { [string]: Types.InternalCodec<any> } = {}
    for key, codec in schema do
        frozenSchema[key] = codec
    end
    table.freeze(frozenSchema)

    if allDirect and dataCount > 0 then
        -- Precompute offsets
        local offsets      = table.create(dataCount)
        local directWrites = table.create(dataCount)
        local directReads  = table.create(dataCount)
        local cursor = 0

        for i = 1, dataCount do
            local c = dataCodecs[i] :: any
            offsets[i] = cursor
            directWrites[i] = c._directWrite
            directReads[i] = c._directRead
            cursor += c._size
        end

        table.freeze(offsets)
        table.freeze(directWrites)
        table.freeze(directReads)

        return table.freeze({
            _size = totalFixed,
            _schema = frozenSchema,

            _directWrite = function(b: buffer, off: number, value: any): ()
                for i = 1, dataCount do
                    directWrites[i](b, off + offsets[i], value[dataKeys[i]])
                end
                -- Bool packing inline for direct path
                if boolCount > 0 then
                    local boolOff = off + fixedSize
                    local idx = 1
                    local byteCount = boolBytes
                    for byteIdx = 0, byteCount - 1 do
                        local packed = 0
                        local limit = if idx + 8 <= boolCount + 1 then 8 else boolCount - idx + 1
                        for bit = 0, limit - 1 do
                            if value[boolKeys[idx]] then
                                packed = bor(packed, lshift(1, bit))
                            end
                            idx += 1
                        end
                        buffer.writeu8(b, boolOff + byteIdx, packed)
                    end
                end
            end,

            _directRead = function(b: buffer, off: number): any
                local result: { [string]: any } = {}
                for i = 1, dataCount do
                    result[dataKeys[i]] = directReads[i](b, off + offsets[i])
                end
                if boolCount > 0 then
                    unpackBools(b, off + fixedSize, boolKeys, boolCount, result)
                end
                return result
            end,

            write = function(ch: Types.ChannelState, value: any): ()
                local c = ch.cursor
                if c + totalFixed > ch.size then alloc(ch, totalFixed) end
                local b = ch.buff
                for i = 1, dataCount do
                    directWrites[i](b, c + offsets[i], value[dataKeys[i]])
                end
                ch.cursor = c + fixedSize
                if boolCount > 0 then
                    packBools(ch, value, boolKeys, boolCount)
                end
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
                local result: { [string]: any } = {}
                for i = 1, dataCount do
                    result[dataKeys[i]] = directReads[i](src, pos + offsets[i])
                end
                if boolCount > 0 then
                    unpackBools(src, pos + fixedSize, boolKeys, boolCount, result)
                end
                return result, totalFixed
            end,
        } :: any)
    end

    -- Generic path
    return table.freeze({
        _schema = frozenSchema,

        write = function(ch: Types.ChannelState, value: any): ()
            for i = 1, dataCount do
                dataCodecs[i].write(ch, value[dataKeys[i]])
            end
            if boolCount > 0 then
                packBools(ch, value, boolKeys, boolCount)
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result: { [string]: any } = {}
            local total = 0
            for i = 1, dataCount do
                local v, consumed = dataCodecs[i].read(src, pos + total, refs)
                result[dataKeys[i]] = v
                total += consumed
            end
            if boolCount > 0 then
                total += unpackBools(src, pos + total, boolKeys, boolCount, result)
            end
            return result, total
        end,
    } :: any)
end

function Struct.deltaStruct(schema: { [string]: Types.InternalCodec<any> }): Types.InternalCodec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)
    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolBytes = (boolCount + 7) // 8
    local segCount  = dataCount + (if boolCount > 0 then 1 else 0)
    local maskBytes = (segCount + 7) // 8
    local deltaId   = allocDeltaId()

    -- Freeze schema for Gate
    local frozenSchema: { [string]: Types.InternalCodec<any> } = {}
    for key, codec in schema do
        frozenSchema[key] = codec
    end
    table.freeze(frozenSchema)

    --[[
        Flag encoding with single-field shortcut:
          0            = UNCHANGED
          1..segCount  = single dirty segment index
          segCount + 1 = FULL
          segCount + 2 = MULTI dirty
    ]]
    local FLAG_FULL  = segCount + DELTA_FULL_OFFSET
    local FLAG_MULTI = segCount + DELTA_MULTI_OFFSET

    -- Inner struct codec for full serialization
    local innerStruct = Struct.struct(schema)

    return table.freeze({
        _isDelta = true,
        _schema = frozenSchema,

        write = function(ch: Types.ChannelState, value: any): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                -- First frame: FLAG_FULL + full payload
                local cursor = ch.cursor
                if cursor + 1 > ch.size then alloc(ch, 1) end
                writeu8(ch.buff, cursor, FLAG_FULL)
                ch.cursor = cursor + 1

                -- Serialize to scratch for caching
                local scratch = acquireScratch()
                innerStruct.write(scratch, value)

                -- Snapshot scratch bytes as the baseline for future comparison
                local snapLen = scratch.cursor
                local snapBuf = buffer.create(snapLen)
                buffer.copy(snapBuf, 0, scratch.buff, 0, snapLen)

                ch.deltas[deltaId] = {
                    raw = snapBuf,
                    len = snapLen,
                }

                innerStruct.write(ch, value)
                releaseScratch()
                return
            end

            -- Compare current serialization against cached baseline
            local scratch = acquireScratch()
            innerStruct.write(scratch, value)

            local scratchBuf = scratch.buff
            local scratchLen = scratch.cursor
            local cachedBuf  = cache.raw
            local cachedLen  = cache.len

            -- Byte-for-byte match means no fields changed
            if scratchLen == cachedLen and rangeEqual(scratchBuf, 0, cachedBuf, 0, scratchLen) then
                local cursor = ch.cursor
                if cursor + 1 > ch.size then alloc(ch, 1) end
                writeu8(ch.buff, cursor, DELTA_UNCHANGED)
                ch.cursor = cursor + 1
                releaseScratch()
                return
            end

            --[[
                Changed but not unchanged: full re-send. Per-segment delta
                tracking is deferred to a future version.
            ]]
            local cursor = ch.cursor
            if cursor + 1 > ch.size then alloc(ch, 1) end
            writeu8(ch.buff, cursor, FLAG_FULL)
            ch.cursor = cursor + 1
            innerStruct.write(ch, value)

            -- Update cache
            local newBuf = buffer.create(scratchLen)
            buffer.copy(newBuf, 0, scratchBuf, 0, scratchLen)
            cache.raw = newBuf
            cache.len = scratchLen

            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = readu8(src, pos)

            if flag == DELTA_UNCHANGED then
                -- Return cached value (caller must have baseline)
                return nil, 1
            end

            if flag == FLAG_FULL then
                local value, consumed = innerStruct.read(src, pos + 1, refs)
                return value, 1 + consumed
            end

            -- For now, treat any other flag as full (future: per-segment delta)
            local value, consumed = innerStruct.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    } :: any)
end

return table.freeze(Struct)
