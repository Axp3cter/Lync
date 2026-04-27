--!strict
--!optimize 2
-- Instance codec via sidecar reference array.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local pushRef = Channel.pushRef
local readu16 = buffer.readu16

local function writeInstance(ch: Types.ChannelState, value: Instance): ()
    pushRef(ch, value)
end

local function readInstance(src: buffer, pos: number, refs: { Instance }?): (Instance, number)
    if not refs then
        error("[Lync] Instance.read: refs array is required")
    end

    local idx = readu16(src, pos)
    if idx < 1 or idx > #refs then
        error(`[Lync] Instance.read: ref index {idx} out of bounds`)
    end

    local inst = refs[idx]
    if typeof(inst) ~= "Instance" then
        error("[Lync] Instance.read: ref is not an Instance")
    end
    return inst, 2
end

-- Public -----------------------------------------------------------------

local InstanceCodec = {}

--[[
    No _directWrite/_directRead: write needs ch.refs, so structs/arrays
    cannot use the all-direct fast path with this codec.
]]
InstanceCodec.inst = table.freeze({
    _size = 2,
    _typeCheck = "Instance",
    write = writeInstance,
    read = readInstance,
})

return table.freeze(InstanceCodec)
