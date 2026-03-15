--!strict
--!native
-- Compress.luau — LZSS compression with hash-probe match finder.

-- Constants --------------------------------------------------------------

local THRESHOLD   = 32
local MIN_MATCH   = 3
local MAX_MATCH   = 18
local WINDOW_SIZE = 4096
local HASH_BITS   = 12
local HASH_SIZE   = 4096
local HASH_EMPTY  = 0xFFFF

local band   = bit32.band
local bor    = bit32.bor
local bxor   = bit32.bxor
local lshift = bit32.lshift
local rshift = bit32.rshift
local min    = math.min
local max    = math.max
local ceil   = math.ceil

-- State ------------------------------------------------------------------

-- Shared scratch avoids per-call allocation. Safe because Luau is
-- single-threaded and pack is never called reentrantly.
local _scratch    = buffer.create(512)
local _scratchLen = 512

-- Hash table: 4096 entries × 2 bytes = 8KB. Persistent, cleared per call.
local _hashTable = buffer.create(HASH_SIZE * 2)

-- Private ----------------------------------------------------------------

local function ensureScratch(needed: number): ()
    if needed <= _scratchLen then return end

    _scratchLen = max(needed, _scratchLen * 2)
    _scratch    = buffer.create(_scratchLen)
end

local function hashThree(src: buffer, pos: number): number
    return band(
        bxor(buffer.readu8(src, pos), lshift(buffer.readu8(src, pos + 1), 4), lshift(buffer.readu8(src, pos + 2), 8)),
        HASH_SIZE - 1
    )
end

local function findMatch(src: buffer, pos: number, srcLen: number): (number, number)
    local remaining = srcLen - pos
    if remaining < MIN_MATCH then return 0, 0 end

    local h         = hashThree(src, pos)
    local slot      = h * 2
    local candidate = buffer.readu16(_hashTable, slot)

    -- Store current position in hash table
    buffer.writeu16(_hashTable, slot, pos)

    if candidate == HASH_EMPTY then return 0, 0 end

    local offset = pos - candidate
    if offset > WINDOW_SIZE or offset <= 0 then return 0, 0 end

    -- Verify first byte before extending
    if buffer.readu8(src, candidate) ~= buffer.readu8(src, pos) then return 0, 0 end

    local maxLen  = min(MAX_MATCH, remaining)
    local len     = 1
    while len < maxLen and buffer.readu8(src, candidate + len) == buffer.readu8(src, pos + len) do
        len += 1
    end

    return if len >= MIN_MATCH then offset else 0,
           if len >= MIN_MATCH then len else 0
end

-- Public -----------------------------------------------------------------

local Compress = {}

function Compress.pack(src: buffer): (buffer, boolean)
    local srcLen = buffer.len(src)
    if srcLen < THRESHOLD then return src, false end

    local worstCase = srcLen + ceil(srcLen / 8)
    ensureScratch(worstCase)

    -- Clear hash table
    buffer.fill(_hashTable, 0, 0xFF, HASH_SIZE * 2)

    local dst    = _scratch
    local dstPos = 0
    local srcPos = 0

    while srcPos < srcLen do
        local flagPos = dstPos
        local flags   = 0
        dstPos += 1

        for bit = 0, 7 do
            if srcPos >= srcLen then
                flags = bor(flags, lshift(1, bit))
                break
            end

            local offset, matchLen = findMatch(src, srcPos, srcLen)

            if matchLen >= MIN_MATCH then
                buffer.writeu8(dst, dstPos, band(offset, 0xFF))
                buffer.writeu8(dst, dstPos + 1, bor(lshift(rshift(offset, 8), 4), matchLen - MIN_MATCH))
                dstPos += 2
                srcPos += matchLen
            else
                flags = bor(flags, lshift(1, bit))
                buffer.writeu8(dst, dstPos, buffer.readu8(src, srcPos))
                dstPos += 1
                srcPos += 1
            end
        end

        buffer.writeu8(dst, flagPos, flags)
    end

    if dstPos >= srcLen then return src, false end

    local out = buffer.create(dstPos)
    buffer.copy(out, 0, dst, 0, dstPos)
    return out, true
end

function Compress.unpack(src: buffer): buffer
    local srcLen = buffer.len(src)
    if srcLen == 0 then return src end

    local srcPos = 0
    local cap    = srcLen * 2
    local dst    = buffer.create(cap)
    local dstPos = 0

    while srcPos < srcLen do
        local flags = buffer.readu8(src, srcPos)
        srcPos += 1

        for bit = 0, 7 do
            if srcPos >= srcLen then break end

            if dstPos + MAX_MATCH >= cap then
                cap *= 2
                local grown = buffer.create(cap)
                buffer.copy(grown, 0, dst, 0, dstPos)
                dst = grown
            end

            if band(flags, lshift(1, bit)) ~= 0 then
                buffer.writeu8(dst, dstPos, buffer.readu8(src, srcPos))
                srcPos += 1
                dstPos += 1
            else
                if srcPos + 1 >= srcLen then break end

                local lo       = buffer.readu8(src, srcPos)
                local hi       = buffer.readu8(src, srcPos + 1)
                local offset   = bor(lo, lshift(rshift(hi, 4), 8))
                local matchLen = band(hi, 0x0F) + MIN_MATCH
                srcPos += 2

                if offset == 0 or offset > dstPos then break end

                local copyFrom = dstPos - offset
                if offset >= matchLen then
                    buffer.copy(dst, dstPos, dst, copyFrom, matchLen)
                else
                    for j = 0, matchLen - 1 do
                        buffer.writeu8(dst, dstPos + j, buffer.readu8(dst, copyFrom + j))
                    end
                end
                dstPos += matchLen
            end
        end
    end

    local out = buffer.create(dstPos)
    buffer.copy(out, 0, dst, 0, dstPos)
    return out
end

return table.freeze(Compress)
