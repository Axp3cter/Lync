--!strict
--!native
-- Sidecar codec. Bypasses buffer serialization, uses Roblox remote refs.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

type ChannelState = Types.ChannelState

local alloc = Channel.alloc

return table.freeze({
    unknown = table.freeze({
        write = function(ch: ChannelState, value: any): ()
            local refs = ch.refs
            local idx = #refs + 1
            if idx > 65535 then
                error(`[Lync] Unknown ref overflow: {idx} exceeds u16 max`)
            end

            refs[idx] = value

            local c = ch.cursor
            if c + 2 > ch.size then
                alloc(ch, 2)
            end
            buffer.writeu16(ch.buff, c, idx)
            ch.cursor = c + 2
        end,
        read = function(src: buffer, pos: number, refs: { Instance }?): (any, number)
            if not refs then
                error("[Lync] Unknown read requires refs array")
            end

            local idx = buffer.readu16(src, pos)
            return refs[idx], 2
        end,
    }),
})
