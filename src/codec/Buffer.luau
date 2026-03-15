--!strict
--!native
-- Raw buffer codec with varint length prefix.

local Channel = require(script.Parent.Parent.core.Channel)
local Varint  = require(script.Parent.Varint)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local Buffer = {}

Buffer.buff = table.freeze({
    write = function(ch: ChannelState, value: buffer): ()
        local len = buffer.len(value)
        Varint.write(ch, len)
        if len > 0 then
            Channel.alloc(ch, len)
            buffer.copy(ch.buff, ch.cursor, value, 0, len)
            ch.cursor += len
        end
    end,
    read = function(src: buffer, pos: number, _refs: { Instance }?): (buffer, number)
        local len, lenBytes = Varint.read(src, pos)
        if len == 0 then return buffer.create(0), lenBytes end

        local remaining = buffer.len(src) - pos - lenBytes
        if len > remaining then
            error(`[Lync] Buffer length {len} exceeds remaining buffer ({remaining})`)
        end

        local out = buffer.create(len)
        buffer.copy(out, 0, src, pos + lenBytes, len)
        return out, lenBytes + len
    end,
})

return table.freeze(Buffer)
