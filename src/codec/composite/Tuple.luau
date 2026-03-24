--!strict
--!optimize 2
-- Positional ordered codec. Like struct but indexed, not keyed.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local alloc = Base.alloc

-- Public --------------------------------------------------------------

local Tuple = {}

function Tuple.define(...: Types.InternalCodec<any>): Types.InternalCodec<any>
    local codecs = { ... }
    local count = #codecs
    if count == 0 then error("[Lync] Lync.tuple: requires at least one codec") end

    -- Check if all codecs are direct
    local allDirect = true
    local totalSize = 0
    local hasUnknown = false

    for i = 1, count do
        local c = codecs[i] :: any
        if c._hasUnknown then hasUnknown = true end
        if not c._size or not c._directWrite or not c._directRead then
            allDirect = false
        else
            totalSize += c._size
        end
    end

    table.freeze(codecs)

    if allDirect then
        -- Build precomputed offsets
        local offsets = table.create(count)
        local directWrites = table.create(count)
        local directReads  = table.create(count)
        local cursor = 0

        for i = 1, count do
            local c = codecs[i] :: any
            offsets[i] = cursor
            directWrites[i] = c._directWrite
            directReads[i] = c._directRead
            cursor += c._size
        end

        table.freeze(offsets)
        table.freeze(directWrites)
        table.freeze(directReads)

        local codec: any = {
            _size = totalSize,

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
                local c = ch.cursor
                if c + totalSize > ch.size then alloc(ch, totalSize) end
                local b = ch.buff
                for i = 1, count do
                    directWrites[i](b, c + offsets[i], value[i])
                end
                ch.cursor = c + totalSize
            end,

            read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
                local result = table.create(count)
                for i = 1, count do
                    result[i] = directReads[i](src, pos + offsets[i])
                end
                return result, totalSize
            end,
        }

        if hasUnknown then codec._hasUnknown = true end
        return table.freeze(codec)
    end

    -- Generic path
    local codec: any = {
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
                result[i] = v
                total += consumed
            end
            return result, total
        end,
    }

    if hasUnknown then codec._hasUnknown = true end
    return table.freeze(codec)
end

return table.freeze(Tuple)
