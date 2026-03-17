--!strict
--!native
-- Raw buffer codec with varint length prefix.

local Channel = require (script.Parent.Parent.Parent.internal.Channel)
local Types = require (script.Parent.Parent.Parent.Types)
local Varint = require (script.Parent.Parent.primitive.Varint)

type ChannelState = Types.ChannelState

local alloc = Channel.alloc

-- Public -------------------------------------------------------------

local Buffer = {}

Buffer.buff = table.freeze ({
    write = function (ch: ChannelState, value: buffer): ()
        local len = buffer.len (value)
        Varint.write (ch, len)
        local c = ch.cursor
        if c + len > ch.size then
            alloc (ch, len)
        end
        buffer.copy (ch.buff, c, value, 0, len)
        ch.cursor = c + len
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (buffer, number)
        local len, lenBytes = Varint.read (src, pos)
        if len == 0 then
            return buffer.create (0), lenBytes
        end

        local remaining = buffer.len (src) - pos - lenBytes
        if len > remaining then
            error (`[Lync] Buffer length exceeds remaining: {len} > {remaining}`)
        end

        local out = buffer.create (len)
        buffer.copy (out, 0, src, pos + lenBytes, len)
        return out, lenBytes + len
    end,
})

return table.freeze (Buffer)
