--!strict
--!native
-- Varint.luau — LEB128 variable-length integer encoding and decoding.

local Channel = require (script.Parent.Channel)
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Constants --------------------------------------------------------------

local CONT = 0x80
local MASK = 0x7F
local MAX_BYTES = 5
local MAX_VALUE = 4294967295

local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Public -----------------------------------------------------------------

local Varint = {}

function Varint.write (ch: ChannelState, value: number): ()
    if value < 0 then
        error (`[Lync] Varint cannot encode negative value: {value}`)
    end
    if value > MAX_VALUE then
        error (`[Lync] Varint value exceeds u32 max: {value}`)
    end

    Channel.alloc (ch, MAX_BYTES)
    local b = ch.buff
    local c = ch.cursor

    while value >= CONT do
        buffer.writeu8 (b, c, bor (band (value, MASK), CONT))
        value = rshift (value, 7)
        c += 1
    end

    buffer.writeu8 (b, c, value)
    ch.cursor = c + 1
end

function Varint.read (src: buffer, pos: number): (number, number)
    local result = 0
    local shift = 0
    local offset = 0
    local len = buffer.len (src)

    repeat
        if pos + offset >= len then
            error (`[Lync] Varint exceeds buffer bounds at position {pos}`)
        end

        local byte = buffer.readu8 (src, pos + offset)
        result = bor (result, lshift (band (byte, MASK), shift))
        shift += 7
        offset += 1

        if offset > MAX_BYTES then
            error (`[Lync] Varint exceeds {MAX_BYTES} bytes at position {pos}`)
        end
    until band (byte, CONT) == 0

    return result, offset
end

return table.freeze (Varint)
