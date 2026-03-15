--!strict
--!native
-- Compress.luau — Minimal LZSS compression. Only invoked on frames above threshold.

-- Constants --------------------------------------------------------------

local THRESHOLD = 128
local MIN_MATCH = 3
local MAX_MATCH = 18
local WINDOW_SIZE = 4096

local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift
local min = math.min
local max = math.max
local ceil = math.ceil

-- State ------------------------------------------------------------------

local _scratch = buffer.create (512)
local _scratchLen = 512

-- Private ----------------------------------------------------------------

local function ensureScratch (needed: number): ()
    if needed <= _scratchLen then
        return
    end

    _scratchLen = max (needed, _scratchLen * 2)
    _scratch = buffer.create (_scratchLen)
end

local function findMatch (src: buffer, pos: number, len: number): (number, number)
    local bestLen = MIN_MATCH - 1
    local bestOffset = 0
    local start = if pos > WINDOW_SIZE then pos - WINDOW_SIZE else 0
    local maxLen = min (MAX_MATCH, len - pos)

    if maxLen < MIN_MATCH then
        return 0, 0
    end

    local first = buffer.readu8 (src, pos)
    local candidate = start

    while candidate < pos do
        if buffer.readu8 (src, candidate) == first then
            local matchLen = 1
            while
                matchLen < maxLen
                and buffer.readu8 (src, candidate + matchLen)
                    == buffer.readu8 (src, pos + matchLen)
            do
                matchLen += 1
            end

            if matchLen > bestLen then
                bestLen = matchLen
                bestOffset = pos - candidate
                if bestLen == maxLen then
                    break
                end
            end
        end
        candidate += 1
    end

    return if bestLen < MIN_MATCH then 0 else bestOffset, if bestLen < MIN_MATCH then 0 else bestLen
end

-- Public -----------------------------------------------------------------

local Compress = {}

function Compress.pack (src: buffer): (buffer, boolean)
    local srcLen = buffer.len (src)
    if srcLen < THRESHOLD then
        return src, false
    end

    local worstCase = srcLen + ceil (srcLen / 8)
    ensureScratch (worstCase)

    local dst = _scratch
    local dstPos = 0
    local srcPos = 0

    while srcPos < srcLen do
        local flagPos = dstPos
        local flags = 0
        dstPos += 1

        for bit = 0, 7 do
            if srcPos >= srcLen then
                flags = bor (flags, lshift (1, bit))
                break
            end

            local offset, matchLen = findMatch (src, srcPos, srcLen)

            if matchLen >= MIN_MATCH then
                local lenCode = matchLen - MIN_MATCH
                buffer.writeu8 (dst, dstPos, band (offset, 0xFF))
                buffer.writeu8 (dst, dstPos + 1, bor (lshift (rshift (offset, 8), 4), lenCode))
                dstPos += 2
                srcPos += matchLen
            else
                flags = bor (flags, lshift (1, bit))
                buffer.writeu8 (dst, dstPos, buffer.readu8 (src, srcPos))
                dstPos += 1
                srcPos += 1
            end
        end

        buffer.writeu8 (dst, flagPos, flags)
    end

    if dstPos >= srcLen then
        return src, false
    end

    local out = buffer.create (dstPos)
    buffer.copy (out, 0, dst, 0, dstPos)
    return out, true
end

function Compress.unpack (src: buffer): buffer
    local srcLen = buffer.len (src)
    if srcLen == 0 then
        return src
    end

    local srcPos = 0
    local dstLen = srcLen * 2
    local dst = buffer.create (dstLen)
    local dstPos = 0

    while srcPos < srcLen do
        local flags = buffer.readu8 (src, srcPos)
        srcPos += 1

        for bit = 0, 7 do
            if srcPos >= srcLen then
                break
            end

            if dstPos + MAX_MATCH >= dstLen then
                dstLen *= 2
                local newBuf = buffer.create (dstLen)
                buffer.copy (newBuf, 0, dst, 0, dstPos)
                dst = newBuf
            end

            if band (flags, lshift (1, bit)) ~= 0 then
                buffer.writeu8 (dst, dstPos, buffer.readu8 (src, srcPos))
                srcPos += 1
                dstPos += 1
            else
                if srcPos + 1 >= srcLen then
                    break
                end

                local lo = buffer.readu8 (src, srcPos)
                local hi = buffer.readu8 (src, srcPos + 1)
                local offset = bor (lo, lshift (rshift (hi, 4), 8))
                local matchLen = band (hi, 0x0F) + MIN_MATCH
                srcPos += 2

                if offset == 0 or offset > dstPos then
                    break
                end

                local copyFrom = dstPos - offset
                for j = 0, matchLen - 1 do
                    buffer.writeu8 (dst, dstPos + j, buffer.readu8 (dst, copyFrom + j))
                end
                dstPos += matchLen
            end
        end
    end

    local out = buffer.create (dstPos)
    buffer.copy (out, 0, dst, 0, dstPos)
    return out
end

return table.freeze (Compress)
