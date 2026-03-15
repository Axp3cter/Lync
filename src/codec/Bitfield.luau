--!strict
--!native
-- Bitfield.luau — Pack booleans and small integers at the bit level.

local Channel = require (script.Parent.Parent.core.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Private ----------------------------------------------------------------

type FieldSpec = {
    type: "bool" | "uint",
    width: number?,
}

type Resolved = {
    key: string,
    isBool: boolean,
    width: number,
    offset: number,
    mask: number,
}

local function selectIO (bytes: number): ((b: buffer, offset: number, v: number) -> (), (
    b: buffer,
    offset: number
) -> number)
    if bytes == 1 then
        return buffer.writeu8, buffer.readu8
    end
    if bytes == 2 then
        return buffer.writeu16, buffer.readu16
    end
    return buffer.writeu32, buffer.readu32
end

-- Public -----------------------------------------------------------------

local Bitfield = {}

function Bitfield.define (schema: { [string]: FieldSpec }): Codec<any>
    local fields = {} :: { Resolved }
    local offset = 0

    for key, spec in schema do
        local isBool = spec.type == "bool"
        local width: number

        if isBool then
            width = 1
        else
            if not spec.width then
                error (`[Lync] Bitfield uint "{key}" requires a width`)
            end
            width = spec.width
            if width < 1 or width > 32 then
                error (`[Lync] Bitfield uint "{key}" width must be 1-32 ({width})`)
            end
        end

        table.insert (fields, {
            key = key,
            isBool = isBool,
            width = width,
            offset = 0,
            mask = lshift (1, width) - 1,
        })
    end

    table.sort (fields, function (a: Resolved, b: Resolved): boolean
        return a.key < b.key
    end)

    for _, field in fields do
        field.offset = offset
        offset += field.width
    end

    if offset == 0 then
        error ("[Lync] Bitfield requires at least one field")
    end
    if offset > 32 then
        error (`[Lync] Bitfield exceeds 32 bits ({offset})`)
    end

    table.freeze (fields)

    local count = #fields
    local bytes = if offset <= 8 then 1 elseif offset <= 16 then 2 else 4
    local wfn, rfn = selectIO (bytes)

    return table.freeze ({
        write = function (ch: ChannelState, value: any): ()
            local packed = 0
            for i = 1, count do
                local field = fields[i]
                local bits = if field.isBool
                    then (if value[field.key] then 1 else 0)
                    else band (value[field.key], field.mask)
                packed = bor (packed, lshift (bits, field.offset))
            end

            Channel.alloc (ch, bytes)
            wfn (ch.buff, ch.cursor, packed)
            ch.cursor += bytes
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
            local packed = rfn (src, pos)
            local result = table.create (count)

            for i = 1, count do
                local field = fields[i]
                local raw = band (rshift (packed, field.offset), field.mask)
                result[field.key] = if field.isBool then raw == 1 else raw
            end

            return result, bytes
        end,
    })
end

return table.freeze (Bitfield)
