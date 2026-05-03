--!strict
--!native
-- Instance codec via the channel's sidecar reference array.

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local pushRef = Channel.pushRef
local readu16 = buffer.readu16

local function writeInstance(ch: Types.ChannelState, value: Instance): ()
    pushRef(ch, value)
end

local function readInstance(src: buffer, pos: number, refs: { Instance }?): (Instance, number)
    local r = refs
    if not r then
        Log.error("refs array is required")
    end

    local idx = readu16(src, pos)
    if idx < 1 or idx > #r then
        Log.error(`ref index {idx} out of bounds`)
    end

    --[[
        Crafted clients can name a slot we never wrote; reject non-Instances.
        Unknown codec skips this since it can legitimately hold any sidecar value.
    ]]
    local inst = r[idx]
    if typeof(inst) ~= "Instance" then
        Log.error("ref is not an Instance")
    end
    return inst, 2
end

-- Public -----------------------------------------------------------------

local InstanceCodec = {}

-- No _directWrite/_directRead: write needs ch.refs (no fast path).
InstanceCodec.inst = table.freeze({
    _size = 2,
    _typeCheck = "Instance",
    write = writeInstance,
    read = readInstance,
})

return table.freeze(InstanceCodec)
