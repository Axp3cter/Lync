--!strict
--!optimize 2
-- Discriminated union codec. u8 variant tag + variant payload.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local writeByte = Channel.writeByte
local readu8 = buffer.readu8

-- Public -----------------------------------------------------------------

local Tagged = {}

function Tagged.define(
    tagField: string,
    variants: { [string]: Types.InternalCodec<any> }
): Types.InternalCodec<any>
    if tagField == "" then
        error("[Lync] Lync.tagged: tagField cannot be empty")
    end

    local names: { string } = {}
    for name in variants do
        table.insert(names, name)
    end
    table.sort(names)

    local variantCount = #names
    if variantCount == 0 then
        error("[Lync] Lync.tagged: requires at least one variant")
    end
    if variantCount > 256 then
        error("[Lync] Lync.tagged: exceeds 256 variants")
    end

    local nameToTag: { [string]: number } = {}
    local tagToCodec = table.create(variantCount)
    local tagToName = table.create(variantCount)
    local hasUnknown = false

    for i = 1, variantCount do
        local name = names[i]
        local codec = variants[name]
        nameToTag[name] = i - 1
        tagToCodec[i] = codec
        tagToName[i] = name
        if codec._hasUnknown then
            hasUnknown = true
        end
    end

    table.freeze(nameToTag)
    table.freeze(tagToCodec)
    table.freeze(tagToName)

    local codec: Types.InternalCodec<any> = {
        _isTagged = true,
        _tagField = tagField,
        _variants = variants,

        write = function(ch: Types.ChannelState, value: any): ()
            local name = value[tagField]
            if name == nil then
                error(`[Lync] Tagged.write: missing tagField "{tagField}"`)
            end
            local tag = nameToTag[name]
            if tag == nil then
                error(`[Lync] Tagged.write: unknown variant "{name}"`)
            end

            writeByte(ch, tag)
            tagToCodec[tag + 1].write(ch, value)
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag = readu8(src, pos)
            local varCodec = tagToCodec[tag + 1]
            if not varCodec then
                error(`[Lync] Tagged.read: unknown tag {tag}`)
            end

            local data, consumed = varCodec.read(src, pos + 1, refs)
            if type(data) == "table" then
                data[tagField] = tagToName[tag + 1]
            end
            return data, 1 + consumed
        end,
    }
    if hasUnknown then
        codec._hasUnknown = true
    end
    return table.freeze(codec)
end

return table.freeze(Tagged)
