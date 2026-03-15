--!strict
--!native
-- Enum.luau — String enum codec. Maps values to u8 indices at definition time.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Public -----------------------------------------------------------------

local EnumCodec = {}

function EnumCodec.define (...: string): Codec<string>
    local values = { ... }
    local count = #values
    if count == 0 then
        error ("[Lync] Enum requires at least one value")
    end
    if count > 256 then
        error (`[Lync] Enum exceeds 256 values ({count})`)
    end

    local toIndex = {} :: { [string]: number }
    local toValue = table.create (count) :: { string }

    for i, value in values do
        if toIndex[value] ~= nil then
            error (`[Lync] Duplicate enum value: {value}`)
        end
        toIndex[value] = i - 1
        toValue[i] = value
    end

    table.freeze (toIndex)
    table.freeze (toValue)

    return table.freeze ({
        write = function (ch: ChannelState, value: string): ()
            local idx = toIndex[value]
            if idx == nil then
                error (`[Lync] Invalid enum value: {value}`)
            end

            Channel.alloc (ch, 1)
            buffer.writeu8 (ch.buff, ch.cursor, idx)
            ch.cursor += 1
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (string, number)
            local idx = buffer.readu8 (src, pos)
            local value = toValue[idx + 1]
            if value == nil then
                error (`[Lync] Invalid enum index: {idx}`)
            end

            return value, 1
        end,
    })
end

return table.freeze (EnumCodec)
