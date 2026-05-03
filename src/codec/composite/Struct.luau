--!strict
--!native
-- Struct and deltaStruct codecs.

local Base = require(script.Parent.Parent.Base)
local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Shared = require(script.Parent.Shared)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local writeByte = Channel.writeByte
local writeu8 = buffer.writeu8
local readu8 = buffer.readu8
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift

local extractFields = Shared.extractFields
local packBools = Shared.packBools
local unpackBools = Shared.unpackBools
local rangeEqual = Shared.rangeEqual
local snapshot = Shared.snapshot
local acquireScratch = Shared.acquireScratch
local releaseScratch = Shared.releaseScratch
local allocDeltaId = Shared.allocDeltaId
local DELTA_UNCHANGED = Shared.DELTA_UNCHANGED
local DELTA_FULL_OFFSET = Shared.DELTA_FULL_OFFSET

local function buildFrozenSchema(
    dataKeys: { string },
    boolKeys: { string },
    schema: { [string]: Types.InternalCodec<any> }
): { [string]: Types.InternalCodec<any> }
    local frozen: { [string]: Types.InternalCodec<any> } = {}
    for i = 1, #dataKeys do
        local k = dataKeys[i]
        frozen[k] = schema[k]
    end
    for i = 1, #boolKeys do
        local k = boolKeys[i]
        frozen[k] = schema[k]
    end
    return table.freeze(frozen)
end

-- Public -----------------------------------------------------------------

local Struct = {}

function Struct.struct(schema: { [string]: Types.InternalCodec<any> }): Types.InternalCodec<any>
    local dataKeys, dataCodecs, boolKeys = extractFields(schema)
    local dataCount = #dataKeys
    local boolCount = #boolKeys
    local boolBytes = (boolCount + 7) // 8

    local allDirect, fixedSize = true, 0
    for i = 1, dataCount do
        local c = dataCodecs[i]
        if not c._size or not c._directWrite or not c._directRead then
            allDirect = false
            break
        end
        fixedSize += c._size
    end

    local totalFixed = fixedSize + boolBytes
    local frozenSchema = buildFrozenSchema(dataKeys, boolKeys, schema)

    if allDirect and dataCount > 0 then
        local offsets = table.create(dataCount)
        local directWrites = table.create(dataCount)
        local directReads = table.create(dataCount)
        local cursor = 0
        for i = 1, dataCount do
            local c = dataCodecs[i]
            offsets[i] = cursor
            directWrites[i] = c._directWrite
            directReads[i] = c._directRead
            cursor += c._size :: number
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
                if boolCount == 0 then
                    return
                end

                local boolOff = off + fixedSize
                local idx = 1
                for byteIdx = 0, boolBytes - 1 do
                    local packed = 0
                    local remaining = boolCount - idx + 1
                    local limit = if remaining >= 8 then 8 else remaining
                    for bit = 0, limit - 1 do
                        if value[boolKeys[idx]] then
                            packed = bor(packed, lshift(1, bit))
                        end
                        idx += 1
                    end
                    writeu8(b, boolOff + byteIdx, packed)
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
                if c + totalFixed > ch.size then
                    alloc(ch, totalFixed)
                end
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
        }) :: Types.InternalCodec<any>
    end

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
    }) :: Types.InternalCodec<any>
end

function Struct.deltaStruct(
    schema: { [string]: Types.InternalCodec<any> }
): Types.InternalCodec<any>
    local dataKeys, _dataCodecs, boolKeys = extractFields(schema)
    local segCount = #dataKeys + (if #boolKeys > 0 then 1 else 0)
    local FLAG_FULL = segCount + DELTA_FULL_OFFSET
    local deltaId = allocDeltaId()
    local frozenSchema = buildFrozenSchema(dataKeys, boolKeys, schema)
    local innerStruct = Struct.struct(schema)

    return table.freeze({
        _isDelta = true,
        _schema = frozenSchema,

        write = function(ch: Types.ChannelState, value: any): ()
            local cache = ch.deltas[deltaId]

            if not cache then
                writeByte(ch, FLAG_FULL)

                local scratch = acquireScratch()
                innerStruct.write(scratch, value)
                local snapLen = scratch.cursor

                ch.deltas[deltaId] = { raw = snapshot(scratch.buff, snapLen), len = snapLen }
                innerStruct.write(ch, value)
                releaseScratch()
                return
            end

            local scratch = acquireScratch()
            innerStruct.write(scratch, value)
            local scratchLen = scratch.cursor

            if
                scratchLen == cache.len
                and rangeEqual(scratch.buff, 0, cache.raw, 0, scratchLen)
            then
                writeByte(ch, DELTA_UNCHANGED)
                releaseScratch()
                return
            end

            writeByte(ch, FLAG_FULL)
            innerStruct.write(ch, value)

            cache.raw = snapshot(scratch.buff, scratchLen)
            cache.len = scratchLen
            releaseScratch()
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if readu8(src, pos) == DELTA_UNCHANGED then
                return nil, 1
            end
            local value, consumed = innerStruct.read(src, pos + 1, refs)
            return value, 1 + consumed
        end,
    }) :: Types.InternalCodec<any>
end

function Struct.partialStruct(codec: Types.InternalCodec<any>, optionalFn: (Types.InternalCodec<any>) -> Types.InternalCodec<any>): Types.InternalCodec<any>
	local schema = (codec :: any)._schema
	assert(schema, "Lync.partialStruct: codec must be a struct")
 
	local partialSchema: { [string]: Types.InternalCodec<any> } = {}
	for key, inner in schema do
		-- Recurse into nested structs
		if (inner :: any)._schema then
			partialSchema[key] = optionalFn(Struct.partialStruct(inner, optionalFn))
		else
			partialSchema[key] = optionalFn(inner)
		end
	end
 
	return Struct.struct(partialSchema)
end

return table.freeze(Struct)
