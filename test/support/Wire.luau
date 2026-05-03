--!strict
--!optimize 2
-- Wire-format helpers: bytes <-> buffer, hex dump, byte slicing.

-- Public -----------------------------------------------------------------

local Wire = {}

function Wire.bufferFromBytes(bytes: { number }): buffer
    local len = #bytes
    local b = buffer.create(len)
    for i = 1, len do
        buffer.writeu8(b, i - 1, bytes[i])
    end
    return b
end

function Wire.bytesFromBuffer(b: buffer, len: number?): { number }
    local n = len or buffer.len(b)
    local out = table.create(n)
    for i = 0, n - 1 do
        out[i + 1] = buffer.readu8(b, i)
    end
    return out
end

function Wire.toHex(b: buffer, len: number?): string
    local n = len or buffer.len(b)
    local parts = table.create(n)
    for i = 0, n - 1 do
        parts[i + 1] = string.format("%02X", buffer.readu8(b, i))
    end
    return table.concat(parts, " ")
end

function Wire.bufferEqual(a: buffer, aLen: number, b: buffer, bLen: number): boolean
    if aLen ~= bLen then
        return false
    end
    for i = 0, aLen - 1 do
        if buffer.readu8(a, i) ~= buffer.readu8(b, i) then
            return false
        end
    end
    return true
end

function Wire.slice(b: buffer, offset: number, len: number): buffer
    local out = buffer.create(len)
    if len > 0 then
        buffer.copy(out, 0, b, offset, len)
    end
    return out
end

return table.freeze(Wire)
