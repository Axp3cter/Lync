--!strict
--!native
-- Instance codec via sidecar reference array.

local Channel = require (script.Parent.Parent.core.Channel)
local alloc = Channel.alloc
local Types = require (script.Parent.Parent.Types)

type ChannelState = Types.ChannelState

-- Public -----------------------------------------------------------------

local InstanceCodec = {}

InstanceCodec.inst = table.freeze ({
    _size = 2,
    write = function (ch: ChannelState, value: Instance): ()
        local refs = ch.refs
        local idx = #refs + 1
        if idx > 65535 then
            error (`[Lync] Instance ref overflow: {idx} exceeds u16 max`)
        end

        refs[idx] = value

        local c = ch.cursor
        if c + 2 > ch.size then
            alloc (ch, 2)
        end
        buffer.writeu16 (ch.buff, c, idx)
        ch.cursor = c + 2
    end,
    read = function (src: buffer, pos: number, refs: { Instance }?): (Instance, number)
        local idx = buffer.readu16 (src, pos)
        if not refs then
            error ("[Lync] Instance read requires refs array")
        end

        local inst = refs[idx]
        if not inst then
            error (`[Lync] Instance ref index out of bounds: {idx}`)
        end

        return inst, 2
    end,
})

return table.freeze (InstanceCodec)
