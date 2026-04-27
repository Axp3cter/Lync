--!strict
--!native
-- Dense prefix varint. Single-branch decode, range up to 2^32 - 1.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)

-- Constants --------------------------------------------------------------

--[[
    Wire layout (first byte determines length):
      0x00..0xBF  1 byte   value = b0                         [0..191]
      0xC0..0xDF  2 bytes  value = (b0 & 0x1F)<<8 | b1 + 192  [192..8383]
      0xE0..0xEF  3 bytes  value = (b0 & 0x0F)<<16 | u16 + 8384 [8384..1056959]
      0xF0..0xFF  5 bytes  value = u32                        [..0xFFFFFFFF]
]]
local INLINE_MAX = 0xBF
local TWO_MAX = 8383
local THREE_MAX = 1056959
local TWO_BIAS = 192
local THREE_BIAS = 8384

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local writeu8 = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32
local readu8 = buffer.readu8
local readu16 = buffer.readu16
local readu32 = buffer.readu32

-- Public -----------------------------------------------------------------

local Varint = {}

Varint.INLINE_MAX = INLINE_MAX

function Varint.write(ch: Types.ChannelState, value: number): ()
    if value < 0 or value > 0xFFFFFFFF or value % 1 ~= 0 then
        error(`[Lync] Varint.write: value must be an integer in [0, 4294967295], got {value}`)
    end

    local cursor = ch.cursor

    if value <= INLINE_MAX then
        if cursor + 1 > ch.size then
            alloc(ch, 1)
        end
        writeu8(ch.buff, cursor, value)
        ch.cursor = cursor + 1
        return
    end

    if value <= TWO_MAX then
        if cursor + 2 > ch.size then
            alloc(ch, 2)
        end
        local adjusted = value - TWO_BIAS
        local b = ch.buff
        writeu8(b, cursor, bor(0xC0, rshift(adjusted, 8)))
        writeu8(b, cursor + 1, band(adjusted, 0xFF))
        ch.cursor = cursor + 2
        return
    end

    if value <= THREE_MAX then
        if cursor + 3 > ch.size then
            alloc(ch, 3)
        end
        local adjusted = value - THREE_BIAS
        local b = ch.buff
        writeu8(b, cursor, bor(0xE0, rshift(adjusted, 16)))
        writeu16(b, cursor + 1, band(adjusted, 0xFFFF))
        ch.cursor = cursor + 3
        return
    end

    if cursor + 5 > ch.size then
        alloc(ch, 5)
    end
    local b = ch.buff
    writeu8(b, cursor, 0xF0)
    writeu32(b, cursor + 1, value)
    ch.cursor = cursor + 5
end

function Varint.read(src: buffer, pos: number): (number, number)
    local b0 = readu8(src, pos)
    if b0 <= INLINE_MAX then
        return b0, 1
    end
    if b0 <= 0xDF then
        return band(b0, 0x1F) * 256 + readu8(src, pos + 1) + TWO_BIAS, 2
    end
    if b0 <= 0xEF then
        return band(b0, 0x0F) * 65536 + readu16(src, pos + 1) + THREE_BIAS, 3
    end
    return readu32(src, pos + 1), 5
end

-- Encode a value already known to fit in INLINE_MAX (single byte).
function Varint.writeInline(ch: Types.ChannelState, value: number): ()
    local cursor = ch.cursor
    if cursor + 1 > ch.size then
        alloc(ch, 1)
    end
    writeu8(ch.buff, cursor, value)
    ch.cursor = cursor + 1
end

--[[
    Decode a length prefix that uses the single-byte fast path for
    lengths in [0, INLINE_MAX] and the full varint encoding above that.
    Used by Buffer, String, and Auto's string branch.
]]
function Varint.readLengthPrefix(src: buffer, pos: number): (number, number)
    local b0 = readu8(src, pos)
    if b0 <= INLINE_MAX then
        return b0, 1
    end
    return Varint.read(src, pos)
end

return table.freeze(Varint)
