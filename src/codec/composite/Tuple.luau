--!strict
--!native
-- Positional ordered codec. Like struct but indexed, not keyed.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>
type InternalCodec<T> = Types.InternalCodec<T>

local alloc = Channel.alloc

-- Public -------------------------------------------------------------

local Tuple = {}

function Tuple.define (...: Codec<any>): Codec<{ any }>
    local codecs = { ... }
    local count = #codecs
    if count == 0 then
        error ("[Lync] Tuple requires at least one codec")
    end

    table.freeze (codecs)

    local canDirect = true
    local totalSize: number = 0
    local directWrites = table.create (count) :: { any }
    local directReads = table.create (count) :: { any }
    local fieldSizes = table.create (count) :: { number }

    for i = 1, count do
        local internal = codecs[i] :: InternalCodec<any>
        local size = internal._size
        local dw = internal._directWrite
        local dr = internal._directRead

        if size and dw and dr then
            fieldSizes[i] = size
            directWrites[i] = dw
            directReads[i] = dr
            totalSize += size
        else
            canDirect = false
            if size then
                totalSize += size
            else
                totalSize = nil :: any
            end
            break
        end
    end

    -- Recompute totalSize for generic path if direct failed partway
    if not canDirect then
        totalSize = 0 :: any
        for i = 1, count do
            local size = (codecs[i] :: InternalCodec<any>)._size
            if size then
                totalSize = (totalSize :: number) + size
            else
                totalSize = nil :: any
                break
            end
        end
    end

    if canDirect then
        table.freeze (directWrites)
        table.freeze (directReads)
        table.freeze (fieldSizes)

        local function directWriteBody (b: buffer, c: number, value: { any }): ()
            for i = 1, count do
                directWrites[i] (b, c, value[i])
                c += fieldSizes[i]
            end
        end

        local function directReadBody (b: buffer, pos: number): { any }
            local result = table.create (count)
            local c = pos
            for i = 1, count do
                result[i] = directReads[i] (b, c)
                c += fieldSizes[i]
            end
            return result
        end

        return table.freeze ({
            _size = totalSize,
            _directWrite = directWriteBody,
            _directRead = directReadBody,
            write = function (ch: ChannelState, value: { any }): ()
                local c = ch.cursor
                if c + totalSize > ch.size then
                    alloc (ch, totalSize)
                end
                directWriteBody (ch.buff, c, value)
                ch.cursor = c + totalSize
            end,
            read = function (src: buffer, pos: number, _refs: { Instance }?): ({ any }, number)
                return directReadBody (src, pos), totalSize
            end,
        })
    end

    local writeFns = table.create (count) :: { any }
    local readFns = table.create (count) :: { any }
    for i = 1, count do
        writeFns[i] = codecs[i].write
        readFns[i] = codecs[i].read
    end
    table.freeze (writeFns)
    table.freeze (readFns)

    local hasFixedTotal = totalSize ~= nil

    return table.freeze ({
        _size = totalSize,
        write = function (ch: ChannelState, value: { any }): ()
            if hasFixedTotal then
                alloc (ch, totalSize :: number)
            end
            for i = 1, count do
                writeFns[i] (ch, value[i])
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local result = table.create (count)
            local absPos = pos

            for i = 1, count do
                local value, n = readFns[i] (src, absPos, refs)
                result[i] = value
                absPos += n
            end

            return result, absPos - pos
        end,
    })
end

return table.freeze (Tuple)
