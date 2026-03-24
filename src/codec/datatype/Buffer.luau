--!strict
--!optimize 2
-- Raw buffer codec with dense-prefix-varint length prefix.

local Base = require(script.Parent.Parent.Base)
local Types = require(script.Parent.Parent.Parent.Types)
local Varint = require(script.Parent.Parent.primitive.Varint)

-- Private -------------------------------------------------------------

local alloc = Base.alloc
local INLINE = Varint.INLINE_MAX

-- Public --------------------------------------------------------------

local BufferCodec = {}

BufferCodec.buff = table.freeze({
    _typeCheck = "buffer",

    write = function(ch: Types.ChannelState, value: buffer): ()
        local len = buffer.len(value)
        local cursor = ch.cursor

        if len <= INLINE then
            if cursor + 1 + len > ch.size then
                alloc(ch, 1 + len)
            end
            local b = ch.buff
            buffer.writeu8(b, cursor, len)
            if len > 0 then
                buffer.copy(b, cursor + 1, value, 0, len)
            end
            ch.cursor = cursor + 1 + len
        else
            Varint.write(ch, len)
            cursor = ch.cursor
            if cursor + len > ch.size then
                alloc(ch, len)
            end
            buffer.copy(ch.buff, cursor, value, 0, len)
            ch.cursor = cursor + len
        end
    end,

    read = function(src: buffer, pos: number, _refs: { Instance }?): (buffer, number)
        local b0 = buffer.readu8(src, pos)
        local len: number
        local lenBytes: number

        if b0 <= INLINE then
            len = b0
            lenBytes = 1
        else
            len, lenBytes = Varint.read(src, pos)
        end

        if len == 0 then
            return buffer.create(0), lenBytes
        end

        local dataStart = pos + lenBytes
        if dataStart + len > buffer.len(src) then
            error("[Lync] Buffer: length exceeds remaining buffer")
        end

        local out = buffer.create(len)
        buffer.copy(out, 0, src, dataStart, len)
        return out, lenBytes + len
    end,
} :: any)

return table.freeze(BufferCodec)
