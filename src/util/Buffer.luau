--!strict
--!native
-- Word-aligned XOR and equality helpers for Channel and composite deltas.

-- Private ----------------------------------------------------------------

local band = bit32.band
local bxor = bit32.bxor
local readu8 = buffer.readu8
local readu32 = buffer.readu32
local writeu8 = buffer.writeu8
local writeu32 = buffer.writeu32
local bufCopy = buffer.copy
local bufCreate = buffer.create
local minN = math.min

-- Public -----------------------------------------------------------------

local Buf = {}

-- 8-byte unrolled compare; 4-byte step then byte tail for remainder.
function Buf.rangeEqual(a: buffer, offA: number, b: buffer, offB: number, len: number): boolean
    local aligned8 = band(len, -8)
    local i = 0
    while i < aligned8 do
        if
            readu32(a, offA + i) ~= readu32(b, offB + i)
            or readu32(a, offA + i + 4) ~= readu32(b, offB + i + 4)
        then
            return false
        end
        i += 8
    end
    if i + 4 <= len then
        if readu32(a, offA + i) ~= readu32(b, offB + i) then
            return false
        end
        i += 4
    end
    while i < len do
        if readu8(a, offA + i) ~= readu8(b, offB + i) then
            return false
        end
        i += 1
    end
    return true
end

function Buf.snapshot(src: buffer, len: number, srcOff: number?): buffer
    local out = bufCreate(len)
    bufCopy(out, 0, src, srcOff or 0, len)
    return out
end

--[[
    XOR `current` against `previous` into a fresh curLen buffer. Returns
    `current` unchanged when previous is nil so first-frame callers don't
    branch. Overlap is 8-byte unrolled; tail is bulk-copied.
]]
function Buf.xorApply(current: buffer, curLen: number, previous: buffer?, prevLen: number?): buffer
    if not previous then
        return current
    end
    local pLen = prevLen or 0

    local result = bufCreate(curLen)
    local overlap = minN(curLen, pLen)

    local aligned8 = band(overlap, -8)
    local i = 0
    while i < aligned8 do
        writeu32(result, i, bxor(readu32(current, i), readu32(previous, i)))
        writeu32(result, i + 4, bxor(readu32(current, i + 4), readu32(previous, i + 4)))
        i += 8
    end
    if i + 4 <= overlap then
        writeu32(result, i, bxor(readu32(current, i), readu32(previous, i)))
        i += 4
    end
    while i < overlap do
        writeu8(result, i, bxor(readu8(current, i), readu8(previous, i)))
        i += 1
    end
    if curLen > overlap then
        bufCopy(result, overlap, current, overlap, curLen - overlap)
    end
    return result
end

return table.freeze(Buf)
