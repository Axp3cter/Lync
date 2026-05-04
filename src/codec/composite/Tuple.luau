--!strict
--!native
-- Positional ordered codec. Like struct but indexed.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc

-- Public -----------------------------------------------------------------

local Tuple = {}

function Tuple.define(...: Types.InternalCodec<any>): Types.InternalCodec<any>
    local codecs = { ... }
    local count = #codecs
    Log.assert(count > 0, "requires at least one codec")

    -- Single pass: detect all-direct fast path + propagate _hasUnknown / _hasDelta.
    local allDirect, totalSize, hasUnknown = true, 0, false
    local hasDelta = false
    for i = 1, count do
        local c = codecs[i]
        if c._hasUnknown then
            hasUnknown = true
        end
        if Shared.containsDelta(c) then
            hasDelta = true
        end
        if allDirect then
            if c._size and c._directWrite and c._directRead then
                totalSize += c._size
            else
                allDirect = false
            end
        end
    end
    table.freeze(codecs)

    -- All-direct: pre-compute offsets so write/read avoids the cursor dance per element.
    if allDirect then
        local offsets = table.create(count)
        local directWrites = table.create(count)
        local directReads = table.create(count)
        local runningOffset = 0

        for i = 1, count do
            local c = codecs[i]
            offsets[i] = runningOffset
            directWrites[i] = c._directWrite
            directReads[i] = c._directRead
            runningOffset += c._size :: number
        end
        table.freeze(offsets)
        table.freeze(directWrites)
        table.freeze(directReads)

        local codec: Types.InternalCodec<any> = {
            _size = totalSize,
            _isTuple = true,
            _elements = codecs,

            _directWrite = function(b: buffer, off: number, value: any): ()
                for i = 1, count do
                    directWrites[i](b, off + offsets[i], value[i])
                end
            end,

            _directRead = function(b: buffer, off: number): any
                local result = table.create(count)
                for i = 1, count do
                    result[i] = directReads[i](b, off + offsets[i])
                end
                return result
            end,

            write = function(ch: Types.ChannelState, value: any): ()
                local cursor = ch.cursor
                if cursor + totalSize > ch.size then
                    alloc(ch, totalSize)
                end
                local b = ch.buff
                for i = 1, count do
                    directWrites[i](b, cursor + offsets[i], value[i])
                end
                ch.cursor = cursor + totalSize
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
                local result = table.create(count)
                for i = 1, count do
                    result[i] = directReads[i](src, pos + offsets[i])
                end
                return result, totalSize
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

    local codec: Types.InternalCodec<any> = {
        _isTuple = true,
        _elements = codecs,

        write = function(ch: Types.ChannelState, value: any): ()
            for i = 1, count do
                codecs[i].write(ch, value[i])
            end
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = table.create(count)
            local total = 0
            for i = 1, count do
                local v, consumed = codecs[i].read(src, pos + total, refs)
                if consumed == 0 then
                    Log.error(`element codec consumed 0 bytes at index {i}`)
                end
                result[i] = v
                total += consumed
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

return table.freeze(Tuple)
