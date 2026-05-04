--!strict
--!native
-- Discriminated union codec. u8 variant tag + variant payload.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Shared = require(script.Parent.Parent.composite.Shared)
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
    Log.assert(tagField ~= "", "tagField cannot be empty")

    -- Sort variant names so the wire-form tag id is stable across runs.
    local names: { string } = {}
    for name in variants do
        table.insert(names, name)
    end
    table.sort(names)

    local variantCount = #names
    Log.assert(variantCount > 0, "requires at least one variant")
    if variantCount > 256 then
        Log.error(`exceeds 256 variants ({variantCount})`)
    end

    local nameToTag: { [string]: number } = {}
    local tagToCodec = table.create(variantCount)
    local hasUnknown = false
    local hasDelta = false

    for i = 1, variantCount do
        local name = names[i]
        local codec = variants[name]
        nameToTag[name] = i - 1
        tagToCodec[i] = codec
        if codec._hasUnknown then
            hasUnknown = true
        end
        if Shared.containsDelta(codec) then
            hasDelta = true
        end
    end

    table.freeze(names)
    table.freeze(nameToTag)
    table.freeze(tagToCodec)

    local codec: Types.InternalCodec<any> = {
        _isTagged = true,
        _tagField = tagField,
        _variants = variants,

        write = function(ch: Types.ChannelState, value: any): ()
            local name = value[tagField]
            if name == nil then
                Log.error(`missing tagField "{tagField}"`)
            end
            local tag = nameToTag[name]
            if tag == nil then
                Log.error(`unknown variant "{name}"`)
            end

            writeByte(ch, tag)
            tagToCodec[tag + 1].write(ch, value)
        end,

        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local tag = readu8(src, pos)
            local varCodec = tagToCodec[tag + 1]
            if not varCodec then
                Log.error(`unknown tag {tag}`)
            end

            local data, consumed = varCodec.read(src, pos + 1, refs)
            -- Re-attach the discriminator so callers can dispatch on it.
            if typeof(data) == "table" then
                data[tagField] = names[tag + 1]
            end
            return data, 1 + consumed
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

return table.freeze(Tagged)
