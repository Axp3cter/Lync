--!strict
--!optimize 2
-- Positional ordered codec. Like struct but indexed, not keyed.

local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Public -----------------------------------------------------------------

local Tuple = {}

function Tuple.define (...: Codec<any>): Codec<{ any }>
    local codecs = { ... }
    local count = #codecs
    if count == 0 then
        error ("[Lync] Tuple requires at least one codec")
    end

    table.freeze (codecs)

    local totalSize: number? = 0
    for i = 1, count do
        local size = (codecs[i] :: any)._size
        if size then
            totalSize = (totalSize :: number) + size
        else
            totalSize = nil
            break
        end
    end

    return table.freeze ({
        _size = totalSize,
        write = function (ch: ChannelState, value: { any }): ()
            for i = 1, count do
                codecs[i].write (ch, value[i])
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local result = table.create (count)
            local absPos = pos

            for i = 1, count do
                local value, n = codecs[i].read (src, absPos, refs)
                result[i] = value
                absPos += n
            end

            return result, absPos - pos
        end,
    })
end

return table.freeze (Tuple)
