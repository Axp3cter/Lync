--!strict
--!native
-- Shared helpers for composite codecs: delta flags, scratch pool, struct field extraction, bool packing.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState

local alloc = Channel.alloc

-- Constants ----------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local ceil = math.ceil
local min = math.min

local FLAG_DELTA = 0
local FLAG_FULL = 1
local FLAG_UNCHANGED = 2

-- State --------------------------------------------------------------

local _nextDeltaId = 1
local _scratchStack = {} :: { ChannelState }
local _scratchDepth = 0

-- Public -------------------------------------------------------------

local Shared = {
    FLAG_DELTA = FLAG_DELTA,
    FLAG_FULL = FLAG_FULL,
    FLAG_UNCHANGED = FLAG_UNCHANGED,
}

function Shared.allocDeltaId (): number
    local id = _nextDeltaId
    _nextDeltaId += 1
    return id
end

function Shared.acquireScratch (): ChannelState
    _scratchDepth += 1
    local scratch = _scratchStack[_scratchDepth]
    if not scratch then
        scratch = Channel.create ()
        _scratchStack[_scratchDepth] = scratch
    end
    scratch.cursor = 0
    table.clear (scratch.refs)
    return scratch
end

function Shared.releaseScratch (): ()
    _scratchDepth -= 1
end

function Shared.rangeEqual (a: buffer, offA: number, b: buffer, offB: number, len: number): boolean
    local aligned = band (len, 0xFFFFFFFC)
    for i = 0, aligned - 4, 4 do
        if buffer.readu32 (a, offA + i) ~= buffer.readu32 (b, offB + i) then
            return false
        end
    end

    for i = aligned, len - 1 do
        if buffer.readu8 (a, offA + i) ~= buffer.readu8 (b, offB + i) then
            return false
        end
    end

    return true
end

function Shared.extractFields (schema: { [string]: any }): ({ string }, { any }, { string })
    local dataKeys = {} :: { string }
    local dataCodecs = {} :: { any }
    local boolKeys = {} :: { string }

    for key, codec in schema do
        if codec._isBool then
            table.insert (boolKeys, key)
        else
            table.insert (dataKeys, key)
        end
    end

    table.sort (dataKeys)
    table.sort (boolKeys)

    if #dataKeys == 0 and #boolKeys == 0 then
        error ("[Lync] Struct requires at least one field")
    end

    for i = 1, #dataKeys do
        dataCodecs[i] = schema[dataKeys[i]]
    end

    table.freeze (dataKeys)
    table.freeze (dataCodecs)
    table.freeze (boolKeys)

    return dataKeys, dataCodecs, boolKeys
end

function Shared.packBools (ch: ChannelState, boolKeys: { string }, boolCount: number, value: any): ()
    local boolByteCount = ceil (boolCount / 8)
    alloc (ch, boolByteCount)
    local b = ch.buff
    local c = ch.cursor

    for byteIdx = 0, boolByteCount - 1 do
        local packed = 0
        local base = byteIdx * 8
        local limit = min (8, boolCount - base)

        for bit = 0, limit - 1 do
            if value[boolKeys[base + bit + 1]] then
                packed = bor (packed, lshift (1, bit))
            end
        end

        buffer.writeu8 (b, c + byteIdx, packed)
    end

    ch.cursor = c + boolByteCount
end

function Shared.unpackBools (
    src: buffer,
    pos: number,
    boolKeys: { string },
    boolCount: number,
    result: any
): number
    local boolByteCount = ceil (boolCount / 8)

    for byteIdx = 0, boolByteCount - 1 do
        local byte = buffer.readu8 (src, pos + byteIdx)
        local base = byteIdx * 8
        local limit = min (8, boolCount - base)

        for bit = 0, limit - 1 do
            result[boolKeys[base + bit + 1]] = band (byte, lshift (1, bit)) ~= 0
        end
    end

    return boolByteCount
end

return table.freeze (Shared)
