--!strict
--!optimize 2
-- Tagged.luau — Discriminated union codec. u8 variant tag + variant payload.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Public -----------------------------------------------------------------

local Tagged = {}

--[[
    Read injects data[tagField] = variantName into the decoded table.
    Variant codecs MUST return a mutable table (not frozen). All built-in
    codecs (struct, deltaStruct, etc.) satisfy this.
]]
function Tagged.define(tagField: string, variants: { [string]: Codec<any> }): Codec<any>
    if #tagField == 0 then error("[Lync] Tagged union tagField must not be empty") end

    local names = {} :: { string }
    for name in variants do
        if #name == 0 then error("[Lync] Tagged union variant name must not be empty") end
        table.insert(names, name)
    end
    table.sort(names)

    local count = #names
    if count == 0 then error("[Lync] Tagged union requires at least one variant") end
    if count > 256 then error(`[Lync] Tagged union exceeds 256 variants ({count})`) end

    local nameToTag = {} :: { [string]: number }
    local tagCodecs = table.create(count) :: { Codec<any> }
    local tagNames  = table.create(count) :: { string }
    local tagSizes  = table.create(count) :: { number? }

    local uniformSize: number? = nil
    local isUniform = true

    for i, name in names do
        nameToTag[name] = i
        tagCodecs[i]    = variants[name]
        tagNames[i]     = name

        local size = (variants[name] :: any)._size
        tagSizes[i] = size

        if i == 1 then
            uniformSize = size
        elseif size ~= uniformSize then
            isUniform = false
        end
    end

    table.freeze(nameToTag)
    table.freeze(tagCodecs)
    table.freeze(tagNames)
    table.freeze(tagSizes)

    -- If all variants have the same fixed size, the tagged codec has a fixed size too
    local fixedSize: number? = if isUniform and uniformSize then 1 + uniformSize else nil

    return table.freeze({
        _size = fixedSize,

        write = function(ch: ChannelState, value: any): ()
            local tag = nameToTag[value[tagField]]
            if not tag then error(`[Lync] Unknown variant: {value[tagField]}`) end

            -- Batch alloc: 1 tag byte + variant payload if size is known
            local variantSize = tagSizes[tag]
            if variantSize then
                Channel.alloc(ch, 1 + variantSize)
            else
                Channel.alloc(ch, 1)
            end

            buffer.writeu8(ch.buff, ch.cursor, tag - 1)
            ch.cursor += 1
            tagCodecs[tag].write(ch, value)
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag  = buffer.readu8(src, pos) + 1
            local name = tagNames[tag]
            if not name then error(`[Lync] Unknown variant index: {tag - 1}`) end

            local data, bytes = tagCodecs[tag].read(src, pos + 1, refs)

            if type(data) == "table" then
                data[tagField] = name
            end

            return data, 1 + bytes
        end,
    })
end

return table.freeze(Tagged)
