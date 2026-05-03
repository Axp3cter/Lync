--!strict
--!native
-- Bypass codec. Stashes the value in the channel sidecar refs (no schema).

local Channel = require(script.Parent.Parent.Parent.internal.Channel)
local Log = require(script.Parent.Parent.Parent.util.Log)
local Types = require(script.Parent.Parent.Parent.Types)

-- Private ----------------------------------------------------------------

local pushRef = Channel.pushRef
local readu16 = buffer.readu16

local function writeUnknown(ch: Types.ChannelState, value: any): ()
    pushRef(ch, value)
end

local function readUnknown(src: buffer, pos: number, refs: { Instance }?): (any, number)
    local r = refs
    if not r then
        Log.error("refs array is required")
    end
    local idx = readu16(src, pos)
    if idx < 1 or idx > #r then
        Log.error(`ref index {idx} out of bounds`)
    end
    return r[idx], 2
end

-- Public -----------------------------------------------------------------

local Unknown = {}

-- _hasUnknown propagates upward so containers warn when used without validate.
Unknown.unknown = table.freeze({
    _hasUnknown = true,
    write = writeUnknown,
    read = readUnknown,
})

return table.freeze(Unknown)
