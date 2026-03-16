--!strict
--!native
-- Variable-length string codec with varint length prefix.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)
local Varint = require (script.Parent.Varint)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local String = {}

String.string = table.freeze ({
    write = function (ch: ChannelState, value: string): ()
        local len = #value

        if len < 128 then
            local total = 1 + len
            local c = ch.cursor
            if c + total > ch.size then
                alloc (ch, total)
            end
            local b = ch.buff
            buffer.writeu8 (b, c, len)
            if len > 0 then
                buffer.writestring (b, c + 1, value)
            end
            ch.cursor = c + total
        else
            Varint.write (ch, len)
            local c = ch.cursor
            if c + len > ch.size then
                alloc (ch, len)
            end
            buffer.writestring (ch.buff, c, value)
            ch.cursor = c + len
        end
    end,
    read = function (src: buffer, pos: number, _refs: { Instance }?): (string, number)
        local len, lenBytes = Varint.read (src, pos)
        if len == 0 then
            return "", lenBytes
        end

        local remaining = buffer.len (src) - pos - lenBytes
        if len > remaining then
            error (`[Lync] String length exceeds buffer: {len} > {remaining}`)
        end

        return buffer.readstring (src, pos + lenBytes, len), lenBytes + len
    end,
})

return table.freeze (String)
