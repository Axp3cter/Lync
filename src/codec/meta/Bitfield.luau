--!strict
--!native
-- Sub-byte packed bool/uint/int fields. Up to 32 bits total per record.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

local TYPE_BOOL = 0
local TYPE_UINT = 1
local TYPE_INT = 2

-- Private ----------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- bit32.lshift(1, 32) wraps to 0; force all-ones in the 32-bit case.
local function widthMask(width: number): number
    if width >= 32 then
        return 0xFFFFFFFF
    end
    return lshift(1, width) - 1
end

-- Public -----------------------------------------------------------------

local Bitfield = {}

export type FieldSpec = { type: "bool" | "uint" | "int", width: number? }

function Bitfield.define(schema: { [string]: FieldSpec }): Types.InternalCodec<any>
    -- Sort field names so bit positions are stable across runs.
    local keys: { string } = {}
    for key in schema do
        table.insert(keys, key)
    end
    table.sort(keys)

    local fieldCount = #keys
    Log.assert(fieldCount > 0, "requires at least one field")

    local fieldKeys = table.create(fieldCount)
    local fieldTypes = table.create(fieldCount)
    local fieldOffsets = table.create(fieldCount)
    local fieldMasks = table.create(fieldCount)
    local fieldSignBit = table.create(fieldCount)
    local fieldSignExt = table.create(fieldCount)
    local totalBits = 0

    for i = 1, fieldCount do
        local key = keys[i]
        local spec = schema[key]
        fieldKeys[i] = key
        fieldOffsets[i] = totalBits

        if spec.type == "bool" then
            fieldTypes[i] = TYPE_BOOL
            fieldMasks[i] = 1
            fieldSignBit[i] = 0
            fieldSignExt[i] = 0
            totalBits += 1
        elseif spec.type == "uint" then
            local width = spec.width
            if not width or width < 1 or width > 32 then
                Log.error(`field "{key}" uint width must be 1-32`)
            end
            fieldTypes[i] = TYPE_UINT
            fieldMasks[i] = widthMask(width)
            fieldSignBit[i] = 0
            fieldSignExt[i] = 0
            totalBits += width
        elseif spec.type == "int" then
            local width = spec.width
            -- Min int width is 2: 1 bit can't represent both a sign and a value.
            if not width or width < 2 or width > 32 then
                Log.error(`field "{key}" int width must be 2-32`)
            end
            fieldTypes[i] = TYPE_INT
            fieldMasks[i] = widthMask(width)
            fieldSignBit[i] = 2 ^ (width - 1)
            fieldSignExt[i] = 2 ^ width
            totalBits += width
        else
            Log.error(`field "{key}" has unknown type "{spec.type}"`)
        end
    end

    if totalBits > 32 then
        Log.error(`total exceeds 32 bits ({totalBits})`)
    end

    -- Pick the narrowest u8/u16/u32 wire form.
    local wireBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number
    if totalBits <= 8 then
        wireBytes, wfn, rfn = 1, buffer.writeu8, buffer.readu8
    elseif totalBits <= 16 then
        wireBytes, wfn, rfn = 2, buffer.writeu16, buffer.readu16
    else
        wireBytes, wfn, rfn = 4, buffer.writeu32, buffer.readu32
    end

    table.freeze(fieldKeys)
    table.freeze(fieldTypes)
    table.freeze(fieldOffsets)
    table.freeze(fieldMasks)
    table.freeze(fieldSignBit)
    table.freeze(fieldSignExt)

    return Base.define(wireBytes, function(b: buffer, off: number, value: any): ()
        local packed = 0
        for i = 1, fieldCount do
            local v = value[fieldKeys[i]]
            local ft = fieldTypes[i]
            if ft == TYPE_BOOL then
                if v then
                    packed = bor(packed, lshift(1, fieldOffsets[i]))
                end
            elseif ft == TYPE_UINT then
                local mask = fieldMasks[i]
                if v < 0 or v > mask or v % 1 ~= 0 then
                    Log.error(`field "{fieldKeys[i]}" value {v} out of uint range [0, {mask}]`)
                end
                packed = bor(packed, lshift(v, fieldOffsets[i]))
            else
                local signBit = fieldSignBit[i]
                if v < -signBit or v >= signBit or v % 1 ~= 0 then
                    Log.error(
                        `field "{fieldKeys[i]}" value {v} out of int range [{-signBit}, {signBit - 1}]`
                    )
                end
                packed = bor(packed, lshift(band(v, fieldMasks[i]), fieldOffsets[i]))
            end
        end
        wfn(b, off, packed)
    end, function(b: buffer, off: number): any
        local packed = rfn(b, off)
        local result: { [string]: any } = {}
        for i = 1, fieldCount do
            local raw = band(rshift(packed, fieldOffsets[i]), fieldMasks[i])
            if fieldTypes[i] == TYPE_BOOL then
                result[fieldKeys[i]] = raw ~= 0
            elseif fieldTypes[i] == TYPE_INT then
                -- Sign-extend: subtract 2^width when the sign bit is set.
                result[fieldKeys[i]] = if raw >= fieldSignBit[i] then raw - fieldSignExt[i] else raw
            else
                result[fieldKeys[i]] = raw
            end
        end
        return result
    end)
end

return table.freeze(Bitfield)
