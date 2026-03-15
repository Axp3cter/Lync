--!strict
--!native
-- Variable-length string codec with varint length prefix.

local Channel = require(script.Parent.Parent.core.Channel)
local Varint  = require(script.Parent.Varint)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local String = {}

String.string = table.freeze({
    write = function(ch: ChannelState, value: string): ()
        local len = #value
        Varint.write(ch, len)
        if len > 0 then
            Channel.alloc(ch, len)
            buffer.writestring(ch.buff, ch.cursor, value)
            ch.cursor += len
        end
    end,
    read = function(src: buffer, pos: number, _refs: { Instance }?): (string, number)
        local len, lenBytes = Varint.read(src, pos)
        if len == 0 then return "", lenBytes end

        local remaining = buffer.len(src) - pos - lenBytes
        if len > remaining then
            error(`[Lync] String length {len} exceeds remaining buffer ({remaining})`)
        end

        return buffer.readstring(src, pos + lenBytes, len), lenBytes + len
    end,
})

return table.freeze(String)
