--!strict
--!native
-- Sub-byte packing. 1 to 32 bits across bool/uint/int fields.

local Base = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

-- Field type constants
local TYPE_BOOL = 0
local TYPE_UINT = 1
local TYPE_INT = 2

-- Public --------------------------------------------------------------

local Bitfield = {}

function Bitfield.define(schema: { [string]: { type: string, width: number? } }): any
    -- Collect and sort keys alphabetically
    local keys = {}
    for key in schema do
        table.insert(keys, key)
    end
    table.sort(keys)

    if #keys == 0 then
        error("[Lync] Lync.bitfield: requires at least one field")
    end

    local fieldCount = #keys
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
                error(`[Lync] Lync.bitfield: field "{key}" uint width must be 1-32`)
            end
            fieldTypes[i] = TYPE_UINT
            fieldMasks[i] = lshift(1, width) - 1
            fieldSignBit[i] = 0
            fieldSignExt[i] = 0
            totalBits += width
        elseif spec.type == "int" then
            local width = spec.width
            if not width or width < 2 or width > 32 then
                error(`[Lync] Lync.bitfield: field "{key}" int width must be 2-32`)
            end
            fieldTypes[i] = TYPE_INT
            fieldMasks[i] = lshift(1, width) - 1
            fieldSignBit[i] = lshift(1, width - 1)
            fieldSignExt[i] = lshift(1, width)
            totalBits += width
        else
            error(`[Lync] Lync.bitfield: unknown field type "{spec.type}"`)
        end
    end

    if totalBits > 32 then
        error(`[Lync] Lync.bitfield: total exceeds 32 bits ({totalBits})`)
    end

    -- Determine wire size
    local wireBytes: number
    local wfn: (buffer, number, number) -> ()
    local rfn: (buffer, number) -> number

    if totalBits <= 8 then
        wireBytes = 1
        wfn = buffer.writeu8
        rfn = buffer.readu8
    elseif totalBits <= 16 then
        wireBytes = 2
        wfn = buffer.writeu16
        rfn = buffer.readu16
    else
        wireBytes = 4
        wfn = buffer.writeu32
        rfn = buffer.readu32
    end

    -- Freeze all descriptor arrays
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
            if fieldTypes[i] == TYPE_BOOL then
                if v then
                    packed = bor(packed, lshift(1, fieldOffsets[i]))
                end
            else
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
                if raw >= fieldSignBit[i] then
                    result[fieldKeys[i]] = raw - fieldSignExt[i]
                else
                    result[fieldKeys[i]] = raw
                end
            else
                result[fieldKeys[i]] = raw
            end
        end

        return result
    end)
end

return table.freeze(Bitfield)
