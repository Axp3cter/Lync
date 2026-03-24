--!strict
--!native
-- Dense prefix-varint encoding with single-branch decode.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Constants -----------------------------------------------------------

local INLINE_MAX = 0xBF

-- Private -------------------------------------------------------------

local alloc   = Base.alloc
local band    = bit32.band
local bor     = bit32.bor
local rshift  = bit32.rshift
local writeu8  = buffer.writeu8
local writeu16 = buffer.writeu16
local writeu32 = buffer.writeu32
local readu8   = buffer.readu8
local readu16  = buffer.readu16
local readu32  = buffer.readu32

-- Public --------------------------------------------------------------

local Varint = {}

Varint.INLINE_MAX = INLINE_MAX

function Varint.write(ch: Types.ChannelState, value: number): ()
    if value < 0 or value > 0xFFFFFFFF or value % 1 ~= 0 then
        error(`[Lync] Varint: value must be an integer in [0, 4294967295], got {value}`)
    end

    local cursor = ch.cursor
    local b = ch.buff

    if value <= INLINE_MAX then
        if cursor + 1 > ch.size then alloc(ch, 1) end
        writeu8(b, cursor, value)
        ch.cursor = cursor + 1

    elseif value <= 8383 then
        if cursor + 2 > ch.size then alloc(ch, 2) end
        local adjusted = value - 192
        b = ch.buff -- alloc may have replaced the buffer
        writeu8(b, cursor, bor(0xC0, rshift(adjusted, 8)))
        writeu8(b, cursor + 1, band(adjusted, 0xFF))
        ch.cursor = cursor + 2

    elseif value <= 1056959 then
        if cursor + 3 > ch.size then alloc(ch, 3) end
        local adjusted = value - 8384
        b = ch.buff
        writeu8(b, cursor, bor(0xE0, rshift(adjusted, 16)))
        writeu16(b, cursor + 1, band(adjusted, 0xFFFF))
        ch.cursor = cursor + 3

    else
        if cursor + 5 > ch.size then alloc(ch, 5) end
        b = ch.buff
        writeu8(b, cursor, 0xF0)
        writeu32(b, cursor + 1, value)
        ch.cursor = cursor + 5
    end
end

function Varint.read(src: buffer, pos: number): (number, number)
    local b0 = readu8(src, pos)

    if b0 <= INLINE_MAX then
        return b0, 1
    elseif b0 <= 0xDF then
        return band(b0, 0x1F) * 256 + readu8(src, pos + 1) + 192, 2
    elseif b0 <= 0xEF then
        return band(b0, 0x0F) * 65536 + readu16(src, pos + 1) + 8384, 3
    else
        return readu32(src, pos + 1), 5
    end
end

function Varint.writeInline(ch: Types.ChannelState, value: number): ()
    local cursor = ch.cursor
    if cursor + 1 > ch.size then alloc(ch, 1) end
    writeu8(ch.buff, cursor, value)
    ch.cursor = cursor + 1
end

return table.freeze(Varint)
