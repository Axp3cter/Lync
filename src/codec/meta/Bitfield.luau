--!strict
--!native
-- Pack booleans, unsigned and signed integers at the bit level.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState
type Codec<T> = Types.Codec<T>

-- Constants --------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Private ----------------------------------------------------------------

type FieldSpec = {
    type: "bool" | "uint" | "int",
    width: number?,
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
    local sortedKeys = {} :: { string }

    for key in schema do
        table.insert (sortedKeys, key)
    end

    table.sort (sortedKeys)

    local count = #sortedKeys
    if count == 0 then
        error ("[Lync] Bitfield requires at least one field")
    end

    local keys = table.create (count) :: { string }
    local isBool = table.create (count) :: { boolean }
    local offsets = table.create (count) :: { number }
    local masks = table.create (count) :: { number }

    local hasSigned = false
    local signBits = nil :: { number }?
    local signExtends = nil :: { number }?

    local totalBits = 0
    for i = 1, count do
        local key = sortedKeys[i]
        local spec = schema[key]
        local specIsBool = spec.type == "bool"
        local specIsSigned = spec.type == "int"
        local width: number

        if specIsBool then
            width = 1
        else
            if not spec.width then
                error (`[Lync] Bitfield "{key}" requires a width`)
            end
            width = spec.width
            if width < 1 or width > 32 then
                error (`[Lync] Bitfield "{key}" width must be 1-32, got {width}`)
            end
        end

        if specIsSigned then
            hasSigned = true
        end

        keys[i] = key
        isBool[i] = specIsBool
        offsets[i] = totalBits
        masks[i] = lshift (1, width) - 1
        totalBits += width
    end

    if totalBits > 32 then
        error (`[Lync] Bitfield exceeds 32 bits: {totalBits}`)
    end

    -- Only build sign tables when at least one field is signed
    if hasSigned then
        signBits = table.create (count) :: { number }
        signExtends = table.create (count) :: { number }

        for i = 1, count do
            local spec = schema[sortedKeys[i]]
            if spec.type == "int" then
                (signBits :: { number })[i] = lshift (1, (spec.width :: number) - 1);
                (signExtends :: { number })[i] = lshift (1, spec.width :: number)
            else
                (signBits :: { number })[i] = 0
                (signExtends :: { number })[i] = 0
            end
        end

        table.freeze (signBits :: { number })
        table.freeze (signExtends :: { number })
    end

    table.freeze (keys)
    table.freeze (isBool)
    table.freeze (offsets)
    table.freeze (masks)

    local bytes = if totalBits <= 8 then 1 elseif totalBits <= 16 then 2 else 4
    local wfn, rfn = selectIO (bytes)

    -- Shared pack logic
    local function packValue (value: any): number
        local packed = 0
        for i = 1, count do
            local bits = if isBool[i]
                then (if value[keys[i]] then 1 else 0)
                else band (value[keys[i]], masks[i])
            packed = bor (packed, lshift (bits, offsets[i]))
        end
        return packed
    end

    -- Shared unpack logic
    local function unpackValue (packed: number): any
        local result = {}

        if hasSigned then
            local sb = signBits :: { number }
            local se = signExtends :: { number }

            for i = 1, count do
                local raw = band (rshift (packed, offsets[i]), masks[i])
                if isBool[i] then
                    result[keys[i]] = raw ~= 0
                elseif sb[i] > 0 and raw >= sb[i] then
                    result[keys[i]] = raw - se[i]
                else
                    result[keys[i]] = raw
                end
            end
        else
            for i = 1, count do
                local raw = band (rshift (packed, offsets[i]), masks[i])
                result[keys[i]] = if isBool[i] then raw ~= 0 else raw
            end
        end

        return result
    end

    return table.freeze ({
        _size = bytes,
        _directWrite = function (b: buffer, offset: number, value: any): ()
            wfn (b, offset, packValue (value))
        end,
        _directRead = function (b: buffer, offset: number): any
            return unpackValue (rfn (b, offset))
        end,
        write = function (ch: ChannelState, value: any): ()
            local c = ch.cursor
            if c + bytes > ch.size then
                alloc (ch, bytes)
            end
            wfn (ch.buff, c, packValue (value))
            ch.cursor = c + bytes
        end,
        read = function (src: buffer, pos: number, _refs: { Instance }?): (any, number)
            return unpackValue (rfn (src, pos)), bytes
        end,
    })
end

return table.freeze (Bitfield)
