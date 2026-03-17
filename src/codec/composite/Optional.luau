--!strict
--!native
-- Optional codec. 1 byte flag, value only if present.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

local alloc = Channel.alloc

-- Public -------------------------------------------------------------

local Optional = {}

function Optional.optional (inner: Codec<any>): Codec<any>
    local innerWrite = inner.write
    local innerRead = inner.read

    return table.freeze ({
        write = function (ch: ChannelState, value: any): ()
            local c = ch.cursor
            if c + 1 > ch.size then
                alloc (ch, 1)
            end
            if value == nil then
                buffer.writeu8 (ch.buff, c, 0)
                ch.cursor = c + 1
            else
                buffer.writeu8 (ch.buff, c, 1)
                ch.cursor = c + 1
                innerWrite (ch, value)
            end
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local flag = buffer.readu8 (src, pos)
            if flag == 0 then
                return nil, 1
            end

            local value, n = innerRead (src, pos + 1, refs)
            return value, 1 + n
        end,
    })
end

return table.freeze (Optional)
