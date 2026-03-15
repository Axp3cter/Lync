--!strict
--!optimize 2
-- Composite.luau — Struct, array, map, and optional composite codecs.

local Channel = require(script.Parent.Parent.core.Channel)
local Varint  = require(script.Parent.Parent.core.Varint)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Private ----------------------------------------------------------------

type Field = {
    key:   string,
    codec: Codec<any>,
}

-- Public -----------------------------------------------------------------

local Composite = {}

function Composite.struct(schema: { [string]: Codec<any> }): Codec<any>
    local fields = {} :: { Field }
    for key, codec in schema do
        table.insert(fields, { key = key, codec = codec })
    end
    table.sort(fields, function(a: Field, b: Field): boolean return a.key < b.key end)

    if #fields == 0 then error("[Lync] Struct requires at least one field") end

    table.freeze(fields)

    local count = #fields

    return table.freeze({
        write = function(ch: ChannelState, value: any): ()
            for i = 1, count do
                local field = fields[i]
                field.codec.write(ch, value[field.key])
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            local result = {}
            local total  = 0

            for i = 1, count do
                local field    = fields[i]
                local value, n = field.codec.read(src, pos + total, refs)
                result[field.key] = value
                total += n
            end

            return result, total
        end,
    })
end

function Composite.array(element: Codec<any>): Codec<{ any }>
    return table.freeze({
        write = function(ch: ChannelState, value: { any }): ()
            local len = #value
            Varint.write(ch, len)
            for i = 1, len do
                element.write(ch, value[i])
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): ({ any }, number)
            local len, lenBytes = Varint.read(src, pos)

            local result = table.create(len)
            local total  = lenBytes

            for i = 1, len do
                local value, n = element.read(src, pos + total, refs)
                result[i] = value
                total += n
            end

            return result, total
        end,
    })
end

function Composite.map(keyCodec: Codec<any>, valueCodec: Codec<any>): Codec<{ [any]: any }>
    return table.freeze({
        write = function(ch: ChannelState, value: { [any]: any }): ()
            local count = 0
            for _ in value do
                count += 1
            end

            Varint.write(ch, count)
            for k, v in value do
                keyCodec.write(ch, k)
                valueCodec.write(ch, v)
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): ({ [any]: any }, number)
            local count, lenBytes = Varint.read(src, pos)

            local result = {}
            local total  = lenBytes

            for _ = 1, count do
                local k, kn = keyCodec.read(src, pos + total, refs)
                total += kn
                local v, vn = valueCodec.read(src, pos + total, refs)
                total += vn
                result[k] = v
            end

            return result, total
        end,
    })
end

function Composite.optional(inner: Codec<any>): Codec<any>
    return table.freeze({
        write = function(ch: ChannelState, value: any): ()
            local isPresent = value ~= nil
            Channel.alloc(ch, 1)
            buffer.writeu8(ch.buff, ch.cursor, if isPresent then 1 else 0)
            ch.cursor += 1
            if isPresent then
                inner.write(ch, value)
            end
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if buffer.readu8(src, pos) == 0 then return nil, 1 end

            local value, n = inner.read(src, pos + 1, refs)
            return value, 1 + n
        end,
    })
end

return table.freeze(Composite)
