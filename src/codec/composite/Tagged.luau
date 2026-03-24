--!strict
--!optimize 2
-- Discriminated union codec. u8 variant tag + variant payload.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local alloc   = Base.alloc
local writeu8 = buffer.writeu8
local readu8  = buffer.readu8

-- Public --------------------------------------------------------------

local Tagged = {}

function Tagged.define(
    tagField: string,
    variants: { [string]: Types.InternalCodec<any> }
): Types.InternalCodec<any>
    if tagField == "" then error("[Lync] Lync.tagged: tagField cannot be empty") end

    local names: { string } = {}
    for name in variants do
        table.insert(names, name)
    end
    table.sort(names)

    local variantCount = #names
    if variantCount == 0 then error("[Lync] Lync.tagged: requires at least one variant") end
    if variantCount > 256 then error("[Lync] Lync.tagged: exceeds 256 variants") end

    -- Build lookup tables
    local nameToTag: { [string]: number } = {}
    local tagToCodec = table.create(variantCount)
    local tagToName  = table.create(variantCount)
    local hasUnknown = false

    for i = 1, variantCount do
        local name = names[i]
        local codec = variants[name]
        nameToTag[name] = i - 1
        tagToCodec[i] = codec
        tagToName[i] = name
        if (codec :: any)._hasUnknown then hasUnknown = true end
    end

    table.freeze(nameToTag)
    table.freeze(tagToCodec)
    table.freeze(tagToName)

    local codec: any = {
        write = function(ch: Types.ChannelState, value: any): ()
            local name = value[tagField]
            if name == nil then
                error(`[Lync] Tagged: missing tagField "{tagField}" in value`)
            end

            local tag = nameToTag[name]
            if tag == nil then
                error(`[Lync] Tagged: unknown variant "{name}"`)
            end

            local cursor = ch.cursor
            if cursor + 1 > ch.size then alloc(ch, 1) end
            writeu8(ch.buff, cursor, tag)
            ch.cursor = cursor + 1

            tagToCodec[tag + 1].write(ch, value)
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag = readu8(src, pos)
            local varCodec = tagToCodec[tag + 1]
            if not varCodec then
                error(`[Lync] Tagged: unknown tag {tag}`)
            end

            local name = tagToName[tag + 1]
            local data, consumed = varCodec.read(src, pos + 1, refs)

            -- Caller needs the tag field to discriminate the union
            if type(data) == "table" then
                data[tagField] = name
            end

            return data, 1 + consumed
        end,
    }

    if hasUnknown then codec._hasUnknown = true end
    return table.freeze(codec)
end

return table.freeze(Tagged)
