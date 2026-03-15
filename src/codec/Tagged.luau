--!strict
--!optimize 2
-- Tagged.luau — Discriminated union codec. u8 variant tag + variant payload.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Public -----------------------------------------------------------------

local Tagged = {}

function Tagged.define (tagField: string, variants: { [string]: Codec<any> }): Codec<any>
    if #tagField == 0 then
        error ("[Lync] Tagged union tagField must not be empty")
    end

    local names = {} :: { string }
    for name in variants do
        if #name == 0 then
            error ("[Lync] Tagged union variant name must not be empty")
        end
        table.insert (names, name)
    end
    table.sort (names)

    if #names == 0 then
        error ("[Lync] Tagged union requires at least one variant")
    end
    if #names > 256 then
        error (`[Lync] Tagged union exceeds 256 variants ({#names})`)
    end

    local nameToTag = {} :: { [string]: number }
    local tagCodecs = table.create (#names) :: { Codec<any> }
    local tagNames = table.create (#names) :: { string }

    for i, name in names do
        nameToTag[name] = i
        tagCodecs[i] = variants[name]
        tagNames[i] = name
    end

    table.freeze (nameToTag)
    table.freeze (tagCodecs)
    table.freeze (tagNames)

    return table.freeze ({
        write = function (ch: ChannelState, value: any): ()
            local tag = nameToTag[value[tagField]]
            if not tag then
                error (`[Lync] Unknown variant: {value[tagField]}`)
            end

            Channel.alloc (ch, 1)
            buffer.writeu8 (ch.buff, ch.cursor, tag - 1)
            ch.cursor += 1
            tagCodecs[tag].write (ch, value)
        end,
        read = function (src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag = buffer.readu8 (src, pos) + 1
            local name = tagNames[tag]
            if not name then
                error (`[Lync] Unknown variant index: {tag - 1}`)
            end

            local data, bytes = tagCodecs[tag].read (src, pos + 1, refs)

            if data ~= nil then
                data[tagField] = name
            end

            return data, 1 + bytes
        end,
    })
end

return table.freeze (Tagged)
