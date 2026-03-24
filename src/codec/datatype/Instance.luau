--!strict
--!optimize 2
-- Instance codec via sidecar reference array.

local Types = require(script.Parent.Parent.Parent.Types)
local Base  = require(script.Parent.Parent.Base)

-- Private -------------------------------------------------------------

local alloc    = Base.alloc
local writeu16 = buffer.writeu16
local readu16  = buffer.readu16

-- Public --------------------------------------------------------------

local InstanceCodec = {}

-- No _directWrite/_directRead: write needs ch.refs, so structs can't use the all-direct path
InstanceCodec.inst = table.freeze({
    _size = 2,
    _typeCheck = "Instance",

    write = function(ch: Types.ChannelState, value: Instance): ()
        local idx = ch.refCount + 1
        if idx > 0xFFFF then
            error("[Lync] Instance: ref overflow (>65535)")
        end

        ch.refs[idx] = value
        ch.refCount = idx

        local cursor = ch.cursor
        if cursor + 2 > ch.size then alloc(ch, 2) end
        writeu16(ch.buff, cursor, idx)
        ch.cursor = cursor + 2
    end,

    read = function(src: buffer, pos: number, refs: { Instance }?): (Instance, number)
        if not refs then
            error("[Lync] Instance: read requires refs array")
        end

        local idx = readu16(src, pos)
        if idx < 1 or idx > #refs then
            error(`[Lync] Instance: ref index {idx} out of bounds`)
        end

        local inst = refs[idx]
        if typeof(inst) ~= "Instance" then
            error("[Lync] Instance: invalid ref (expected Instance)")
        end

        return inst, 2
    end,
} :: any)

return table.freeze(InstanceCodec)
