--!strict
--!native
-- LEB128 variable-length integer encoding and decoding.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState

local alloc = Channel.alloc

-- Constants -----------------------------------------------------------

local CONT = 0x80
local MASK = 0x7F
local MAX_BYTES = 5
local MAX_VALUE = 4294967295

local band = bit32.band
local bor = bit32.bor
local rshift = bit32.rshift
local lshift = bit32.lshift

-- Public --------------------------------------------------------------

local Varint = {}

function Varint.write(ch: ChannelState, value: number): ()
    if value < 0 or value > MAX_VALUE then
        error(`[Lync] Varint value out of range: {value}`)
    end

    -- Fast path: ~80%+ of real-world varints are single-byte(lengths, counts)
    if value < CONT then
        local c = ch.cursor
        if c + 1 > ch.size then
            alloc(ch, 1)
        end
        buffer.writeu8(ch.buff, c, value)
        ch.cursor = c + 1
        return
    end

    local c = ch.cursor
    if c + MAX_BYTES > ch.size then
        alloc(ch, MAX_BYTES)
    end
    local b = ch.buff

    while value >= CONT do
        buffer.writeu8(b, c, bor(band(value, MASK), CONT))
        value = rshift(value, 7)
        c += 1
    end

    buffer.writeu8(b, c, value)
    ch.cursor = c + 1
end

-- Reads rely on buffer.readu8 throwing on OOB. MAX_BYTES rejects malformed loops.
function Varint.read(src: buffer, pos: number): (number, number)
    local result = 0

    for offset = 0, MAX_BYTES - 1 do
        local byte = buffer.readu8(src, pos + offset)
        result = bor(result, lshift(band(byte, MASK), offset * 7))

        if band(byte, CONT) == 0 then
            return result, offset + 1
        end
    end

    error(`[Lync] Varint exceeds {MAX_BYTES} bytes at position {pos}`)
end

return table.freeze(Varint)
