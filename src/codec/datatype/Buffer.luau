--!strict
--!native
-- Raw buffer codec with dense-prefix-varint length prefix.

local Base = require(script.Parent.Parent.Base)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private ----------------------------------------------------------------

local alloc = Base.alloc
local INLINE_MAX = Varint.INLINE_MAX

local function writeBuffer(ch: Types.ChannelState, value: buffer): ()
    local len = buffer.len(value)
    local cursor = ch.cursor

    -- Single-byte length fast path skips the full varint encode.
    if len <= INLINE_MAX then
        if cursor + 1 + len > ch.size then
            alloc(ch, 1 + len)
        end
        local b = ch.buff
        buffer.writeu8(b, cursor, len)
        buffer.copy(b, cursor + 1, value, 0, len)
        ch.cursor = cursor + 1 + len
        return
    end

    Varint.write(ch, len)
    cursor = ch.cursor
    if cursor + len > ch.size then
        alloc(ch, len)
    end
    buffer.copy(ch.buff, cursor, value, 0, len)
    ch.cursor = cursor + len
end

local function readBuffer(src: buffer, pos: number, _refs: { Instance }?): (buffer, number)
    local len, lenBytes = Varint.readLengthPrefix(src, pos)
    if len == 0 then
        return buffer.create(0), lenBytes
    end

    local dataStart = pos + lenBytes
    if dataStart + len > buffer.len(src) then
        Log.error(`length {len}B exceeds remaining buffer`)
    end

    local out = buffer.create(len)
    buffer.copy(out, 0, src, dataStart, len)
    return out, lenBytes + len
end

-- Public -----------------------------------------------------------------

local BufferCodec = {}

BufferCodec.buff = table.freeze({
    _typeCheck = "buffer",
    write = writeBuffer,
    read = readBuffer,
})

return table.freeze(BufferCodec)
