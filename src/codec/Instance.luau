--!strict
--!optimize 2
-- Instance.luau — Instance codec via sidecar reference array.

local Channel = require(script.Parent.Parent.core.Channel)
local Types   = require(script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local InstanceCodec = {}

InstanceCodec.inst = table.freeze({
    write = function(ch: ChannelState, value: Instance): ()
        local refs = ch.refs
        local idx  = #refs + 1
        refs[idx]  = value
        if idx > 65535 then error(`[Lync] Instance ref overflow: {idx} exceeds u16 max`) end

        Channel.alloc(ch, 2)
        buffer.writeu16(ch.buff, ch.cursor, idx)
        ch.cursor += 2
    end,
    read = function(src: buffer, pos: number, refs: { Instance }?): (Instance, number)
        local idx = buffer.readu16(src, pos)
        if not refs then error("[Lync] Instance codec: refs array is nil") end
        if not refs[idx] then error(`[Lync] Instance codec: invalid ref index {idx}`) end

        return refs[idx], 2
    end,
})

return table.freeze(InstanceCodec)
