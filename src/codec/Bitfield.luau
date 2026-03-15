--!strict
--!native
-- Bitfield.luau — Pack booleans and small integers at the bit level.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T>     = Types.Codec<T>

-- Constants --------------------------------------------------------------

local band   = bit32.band
local bor    = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Private ----------------------------------------------------------------

type FieldSpec = {
    type:  "bool" | "uint",
    width: number?,
}

local function selectIO(bytes: number): (
    (b: buffer, offset: number, v: number) -> (),
    (b: buffer, offset: number) -> number
)
    if bytes == 1 then return buffer.writeu8, buffer.readu8 end
    if bytes == 2 then return buffer.writeu16, buffer.readu16 end
    return buffer.writeu32, buffer.readu32
end

local function sortByKey(a: { key: string }, b: { key: string }): boolean
    return a.key < b.key
end

-- Public -----------------------------------------------------------------

local Bitfield = {}

function Bitfield.define(schema: { [string]: FieldSpec }): Codec<any>
    local raw = {} :: { { key: string, isBool: boolean, width: number } }

    for key, spec in schema do
        local isBool = spec.type == "bool"
        local width: number

        if isBool then
            width = 1
        else
            if not spec.width then error(`[Lync] Bitfield uint "{key}" requires a width`) end
            width = spec.width
            if width < 1 or width > 32 then
                error(`[Lync] Bitfield uint "{key}" width must be 1-32 ({width})`)
            end
        end

        table.insert(raw, { key = key, isBool = isBool, width = width })
    end

    table.sort(raw, sortByKey)

    local count  = #raw
    if count == 0 then error("[Lync] Bitfield requires at least one field") end

    -- Build flat parallel arrays for zero-indirection hot path
    local keys    = table.create(count) :: { string }
    local isBool  = table.create(count) :: { boolean }
    local offsets = table.create(count) :: { number }
    local masks   = table.create(count) :: { number }

    local totalBits = 0
    for i = 1, count do
        local field  = raw[i]
        keys[i]    = field.key
        isBool[i]  = field.isBool
        offsets[i] = totalBits
        masks[i]   = lshift(1, field.width) - 1
        totalBits += field.width
    end

    if totalBits > 32 then error(`[Lync] Bitfield exceeds 32 bits ({totalBits})`) end

    table.freeze(keys)
    table.freeze(isBool)
    table.freeze(offsets)
    table.freeze(masks)

    local bytes    = if totalBits <= 8 then 1 elseif totalBits <= 16 then 2 else 4
    local wfn, rfn = selectIO(bytes)

    return table.freeze({
        _size = bytes,
        write = function(ch: ChannelState, value: any): ()
            local packed = 0
            for i = 1, count do
                local bits = if isBool[i]
                    then (if value[keys[i]] then 1 else 0)
                    else band(value[keys[i]], masks[i])
                packed = bor(packed, lshift(bits, offsets[i]))
            end

            Channel.alloc(ch, bytes)
            wfn(ch.buff, ch.cursor, packed)
            ch.cursor += bytes
        end,
        read = function(src: buffer, pos: number, _refs: { Instance }?): (any, number)
            local packed = rfn(src, pos)
            local result = {}

            for i = 1, count do
                local raw = band(rshift(packed, offsets[i]), masks[i])
                result[keys[i]] = if isBool[i] then raw ~= 0 else raw
            end

            return result, bytes
        end,
    })
end

return table.freeze(Bitfield)
